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

---@param v any
---@return string
local function shown(v)
  local s = vim.inspect(v)
  return #s > 200 and (s:sub(1, 200) .. "...") or s
end

---Run one step; returns nil or the reason it failed.
---@param child table testing.rpc handle
---@param step Testing.Sheet.Step
---@param ctx { sheet: Testing.Sheet, size: table, root: string, opts: table, snapshots: string[], cancelled: fun(): boolean }
---@return string|nil
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
    local res = require("testing.screen").compare(name, child.screen(), {
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
    return require("testing.screen").hl_check(child.screen(), step.hl, resolved)
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

  ---@param new_size { rows: integer, cols: integer }
  ---@return { failure?: string, skip?: string }|nil
  function D.open_size(new_size)
    size = new_size
    local tag = ("%dx%d"):format(size.cols, size.rows)
    local spawn = vim.tbl_extend("force", {
      root = ctx.root,
      minit = minit,
      size = size,
      guard = false,
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
      answer = { failure = ("%s: %s"):format(tag, tostring(perr)) }
    end
    if answer then
      D.close_size()
    end
    return answer
  end

  ---@param step Testing.Sheet.Step
  ---@return { reason?: string, raised?: string, screen?: string[] }
  function D.run(step)
    local ok, why = pcall(run_step, child, step, {
      sheet = s,
      size = size,
      root = ctx.root,
      opts = opts,
      snapshots = ctx.snapshots,
      cancelled = ctx.cancelled,
    })
    local out = {}
    if not ok then
      out.raised = tostring(why)
    elseif why then
      out.reason = why
    end
    -- E3: what the child shows after the step; a stepped run only, the suite never pays for it, and a screen
    -- that cannot be read says nothing about the step
    if opts.capture_screen and not out.raised then
      local got, screen = pcall(child.screen)
      if got and type(screen) == "table" then
        out.screen = screen.lines
      end
    end
    return out
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
