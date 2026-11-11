---@module 'testing.sheet.driver_rpc'
---@brief Engine "rpc" of a test sheet as a driver: a child editor per size, one step at a time, in this process.
---@description
--- The other engines are processes that speak `testing-sheet-driver/1`; this one needs no process of its own, the
--- child editor is one already (`testing.rpc`). A driver is what `testing.sheet.session` steps through:
---
---   open_size(size)  start the target for one size; nil, or { failure = line } or { skip = reason }
---   run(step, n)     one step; { reason = why } when it failed, { raised = err } when it raised, else {}
---   close_size()     the target of this size goes away
---   close()          everything goes away; safe to call twice

local M = {}

-- `config = "user"`: one call and the start of a child on the user's whole config (measured: the first draw of a
-- config with 50 plugins took 6 s on Windows)
M.USER_CALL_TIMEOUT_MS = 30000
M.USER_BOOT_TIMEOUT_MS = 60000

-- What answers a prompt, by its name (`testing.rpc.PROMPTS`).
M.ANSWERS = {
  ["hit-enter"] = '{ input = "<CR>" }',
  more = '{ input = "q" } (or " " for the next page)',
  confirm = '{ input = "<letter of a choice>" } (or "<Esc>")',
}

---The failure of a step that ran into a prompt of the child: which prompt, and how a sheet answers it.
---@param prompt string `hit-enter`, `more` or `confirm`
---@return string
function M.prompt_failure(prompt)
  return ("the child shows a %s prompt; answer it with %s (a step { prompt = %q } waits for it)"):format(
    prompt,
    M.ANSWERS[prompt] or '{ input = "<CR>" }',
    prompt
  )
end

---@param v any
---@return string
local function shown(v)
  local s = vim.inspect(v)
  return #s > 200 and (s:sub(1, 200) .. "...") or s
end

---Run one step; returns nil or the reason it failed, and what a `shot` made (`{ shot = path }`) or why it was skipped
---(`{ skip = why }`).
---@param child table testing.rpc handle
---@param step Testing.Sheet.Step
---@param ctx { sheet: Testing.Sheet, size: table, root: string, opts: table, snapshots: string[], cancelled: fun(): boolean, screen: fun(): table }
---@return string|nil
---@return { shot?: string, skip?: string, measure?: Testing.Sheet.Measure }|nil
local function run_step(child, step, ctx)
  if step.keys then
    -- an error the keys caused (`E492: Not an editor command`) fails the step; feed itself never raises
    child.lua("vim.v.errmsg = ''")
    child.feed(step.keys)
    local msg = child.lua_get("vim.v.errmsg")
    if msg ~= nil and msg ~= "" and not step.ignore_errmsg then
      return "the keys caused an error: " .. msg
    end
  elseif step.input then
    child.input(step.input)
  elseif step.lua then
    child.lua(step.lua)
  elseif step.settle then
    local idle, why = child.settle(step.settle)
    if not idle then
      return why or "not idle"
    end
  elseif step.prompt then
    -- asked through `nvim_get_mode`, which the editor answers in a prompt too: no call waits behind it
    local timeout = step.timeout or require("testing.sheet").DEFAULT_WAIT_MS
    local deadline = vim.uv.hrtime() + timeout * 1e6
    local rpc = require("testing.rpc")
    while true do
      local mode = child.prompt()
      local shown_now = mode and rpc.PROMPTS[mode]
      if shown_now == step.prompt then
        break
      end
      if ctx.cancelled() then
        return "aborted"
      end
      if vim.uv.hrtime() >= deadline then
        return ("no %s prompt after %d ms%s"):format(
          step.prompt,
          timeout,
          shown_now and (" (the child shows a " .. shown_now .. " prompt)") or ""
        )
      end
      vim.wait(20)
    end
  elseif step.wait then
    -- a loop of its own: every poll is an RPC call that waits with `vim.wait` itself, and a
    -- `vim.wait` inside the condition of another one does not keep the outer deadline
    local timeout = step.timeout or require("testing.sheet").DEFAULT_WAIT_MS
    local deadline = vim.uv.hrtime() + timeout * 1e6
    local last
    while true do
      last = child.lua_get(step.wait)
      if last then
        break
      end
      if ctx.cancelled() then
        return "aborted"
      end
      if vim.uv.hrtime() >= deadline then
        return ("still %s after %d ms"):format(shown(last), timeout)
      end
      vim.wait(20)
    end
  elseif step.measure then
    -- `runs` times, the median counts: one reading under load would make the check flutter
    local sheet = require("testing.sheet")
    local values = {}
    for i = 1, step.runs or 1 do
      local v = child.lua_get(step.measure)
      if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return ("%s: got %s, not a number"):format(step.name, shown(v))
      end
      values[i] = v
    end
    local m = {
      name = step.name,
      value = sheet.median(values),
      values = values,
      unit = step.unit,
      min = step.min,
      max = step.max,
    }
    local text = sheet.measure_text(m)
    if step.max and m.value > step.max then
      return ("%s: above the max"):format(text), { measure = m }
    end
    if step.min and m.value < step.min then
      return ("%s: below the min"):format(text), { measure = m }
    end
    return nil, { measure = m }
  elseif step.expect then
    local v = child.lua_get(step.expect)
    if not v then
      return "got " .. shown(v)
    end
  elseif step.restart then
    -- as a person does: quit (VimLeavePre runs), start again on what the first editor left in the sandbox
    child.restart({
      quit = true,
      keep_sandbox = true,
      args = M.command_line(step.args or ctx.sheet.args, ctx.size) or {},
    })
    -- the UI first again: the editor lays out its windows for the size of its UI
    child.screen()
  elseif step.screen then
    local name = ("%s.%dx%d"):format(step.screen, ctx.size.cols, ctx.size.rows)
    local res = require("testing.screen").compare(name, ctx.screen(), {
      root = ctx.root,
      file = ctx.sheet.path,
      masks = step.masks,
      cursor = step.cursor,
      mode = step.mode,
      groups = step.groups,
      update = ctx.opts.update,
      ci = ctx.opts.ci,
    })
    ctx.snapshots[#ctx.snapshots + 1] = res.message
    if not res.ok then
      return res.message
    end
  elseif step.hl then
    local resolved
    if step.hl.group then
      -- the UI names the group a link ends in: follow the links of the group asked for, in the child
      resolved = child.lua(M.RESOLVE_GROUP, step.hl.group)
      if resolved == nil then
        return ("there is no highlight group %s"):format(step.hl.group)
      end
    end
    return require("testing.screen").hl_check(ctx.screen(), step.hl, resolved)
  elseif step.shot then
    -- the screen drawn as a page and photographed by the browser engine (`testing.sheet.shot`); without it a skip
    local path, failure, skip = require("testing.sheet.shot").take(child.screen(), {
      sheet = ctx.sheet,
      size = ctx.size,
      root = ctx.root,
      name = step.shot,
      out_dir = ctx.opts.out_dir,
      browser = ctx.opts.browser,
    })
    if skip then
      return nil, { skip = skip }
    end
    if failure then
      return failure
    end
    return nil, { shot = path }
  end
  return nil
end

-- In the child: the group `...` ends in after its links, nil when it is not defined.
M.RESOLVE_GROUP = [[
local name = ...
if vim.fn.hlexists(name) == 0 then
  return nil
end
for _ = 1, 100 do
  local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = name, create = false })
  if not ok or type(def) ~= "table" or not def.link then
    return name
  end
  name = def.link
end
return name
]]

---The command line of a start: the sheet's (or a restart's) arguments after one that gives the editor the sheet's
---size, as a terminal does. What they run at startup (`+LastSession`) lays its windows out for that size; without
---it the editor starts at 80x24 and the UI attached afterwards scales the layout. Nil without arguments.
---@param args string[]|nil
---@param size { rows: integer, cols: integer }
---@return string[]|nil
function M.command_line(args, size)
  if not args or #args == 0 then
    return nil
  end
  return vim.list_extend(
    { "--cmd", ("set lines=%d columns=%d"):format(size.rows, size.cols) },
    args
  )
end

---@class Testing.Sheet.DriverContext
---@field root string The project root (normalized).
---@field snapshots string[] Where the messages of the screen steps go.
---@field cancelled fun(): boolean

---@param s Testing.Sheet
---@param opts table As `testing.sheet.run`; `capture_screen` adds the screen text to each step's answer.
---@param ctx Testing.Sheet.DriverContext
---@return table driver
function M.new(s, opts, ctx)
  local minit = s.minit or require("testing.sheet").DEFAULT_MINIT
  -- absolute: a drive (`C:/`, `C:\`), a POSIX root or a UNC path in either slash style
  if not minit:match("^%a:[/\\]") and not minit:match("^[/\\]") then
    minit = ctx.root .. "/" .. minit
  end
  local D = {}
  local child, size
  -- a live sheet: the values of its variables, masked wherever the run shows something (`testing.sheet.live`)
  local live = s.live and require("testing.sheet.live") or nil
  local mask = function(text)
    return text
  end
  local blocked_seen = 0

  ---@param new_size { rows: integer, cols: integer }
  ---@return { failure?: string, skip?: string }|nil
  function D.open_size(new_size)
    size = new_size
    local tag = ("%dx%d"):format(size.cols, size.rows)
    local live_env, live_guard
    if live then
      local getenv = opts.getenv or vim.uv.os_getenv
      local why = live.gate(s, opts, getenv)
      if why then
        return { skip = why }
      end
      live_env = live.values(s, getenv)
      mask = live.masker(live_env)
      live_guard = live.guard_config(s)
      blocked_seen = 0
    end
    local user
    if s.config == "user" then
      -- the user's installed config, read only; where there is none (CI) the sheet is a skip, never green
      local why
      user, why = require("testing.child.user_config").locate(opts.getenv)
      if not user then
        return { skip = why }
      end
    end
    local spawn = vim.tbl_extend("force", {
      root = ctx.root,
      minit = not user and minit or nil,
      user_config = user,
      -- a real config with all its plugins starts and draws slower than a minimal init
      call_timeout_ms = user and M.USER_CALL_TIMEOUT_MS or nil,
      boot_timeout_ms = user and M.USER_BOOT_TIMEOUT_MS or nil,
      size = size,
      -- a live child: its network guard lets it reach the named hosts only
      guard = live_guard or false,
      extra_env = live_env,
      -- a call behind a prompt fails at once and says so, `screen` reads the prompt from the UI
      watch_prompts = true,
      args = M.command_line(s.args, size),
    }, opts.spawn or {})
    -- a spawn that raises is a failure of this size, not an error out of `run` (expect hands the
    -- verdict to the harness, it must not throw past it)
    local spawned, c, err = pcall(require("testing.rpc").spawn, spawn)
    if not spawned then
      c, err = nil, c
    end
    if not c then
      return { failure = ("%s: the child did not start: %s"):format(tag, tostring(err)) }
    end
    child = c
    local answer
    local ok, perr = pcall(function()
      -- attach the UI first: the editor lays out windows (floats too) for the size of its UI
      child.screen()
      if live then
        -- the guard watches while a case is open: the whole size is one
        child.guard.begin_case({ id = s.id, name = s.title })
      end
      for _, req in ipairs(s.requires or {}) do
        local met, rerr = pcall(child.lua_get, req.lua)
        if not met then
          answer = {
            failure = ("%s: requires %q raised: %s"):format(tag, req.lua, tostring(rerr)),
          }
          return
        end
        if not rerr then
          answer = { skip = req.reason }
          return
        end
      end
    end)
    if not ok then
      answer = { failure = mask(("%s: %s"):format(tag, tostring(perr))) }
    end
    if answer then
      D.close_size()
    end
    return answer
  end

  ---@param step Testing.Sheet.Step
  ---@return { reason?: string, raised?: string, screen?: string[], shot?: string, skip?: string, measure?: Testing.Sheet.Measure }
  function D.run(step)
    local ok, why, made = pcall(run_step, child, step, {
      sheet = s,
      size = size,
      root = ctx.root,
      opts = opts,
      snapshots = ctx.snapshots,
      cancelled = ctx.cancelled,
      -- what a screen, hl or snapshot step sees: masked in a live sheet
      screen = function()
        local shot = child.screen()
        return live and live.mask_screen(shot, mask) or shot
      end,
    })
    local out = {}
    local prompt = not ok and require("testing.rpc").prompt_of(why)
    if prompt then
      -- no crash: the child waits for an answer, and the sheet should say which
      out.reason = M.prompt_failure(prompt)
    elseif not ok then
      out.raised = tostring(why)
    elseif why then
      out.reason = why
    elseif made then
      out.shot, out.skip = made.shot, made.skip
    end
    -- a measure that broke its bound is a failure, and its value is still a result
    if ok and made and made.measure then
      out.measure = made.measure
    end
    if live and not out.raised and not out.reason then
      out.reason = D.blocked()
    end
    -- E3: what the child shows after the step; a stepped run only, the suite never pays for it, and a screen
    -- that cannot be read says nothing about the step
    if opts.capture_screen and not out.raised then
      local got, screen = pcall(child.screen)
      if got and type(screen) == "table" then
        out.screen = vim.tbl_map(mask, screen.lines)
      end
    end
    out.reason, out.raised = mask(out.reason), mask(out.raised)
    return out
  end

  ---What a live child started or reached that its sheet did not name, since the last step; nil when nothing.
  ---@return string|nil
  function D.blocked()
    local got, res = pcall(child.guard.collect)
    local findings = got and type(res) == "table" and res.findings or {}
    local lines = {}
    for i = blocked_seen + 1, #findings do
      local f = findings[i]
      if f.id == "network.blocked" or f.id == "process.spawn_blocked" then
        lines[#lines + 1] = tostring(f.message)
      end
    end
    blocked_seen = #findings
    if #lines == 0 then
      return nil
    end
    return "the live sheet reached what it does not name (live.hosts): "
      .. table.concat(lines, "; ")
  end

  function D.close_size()
    if child then
      pcall(child.kill)
      child = nil
    end
  end

  D.close = D.close_size

  return D
end

return M
