---@module 'testing.sheet.live'
-- @cache-env CI
---@brief Live sheets: an rpc sheet with real keys and network, run only on purpose (`testing sheets run --live`).
---@description
--- A sheet is no live check by default: its child editor gets no secret (the allowlisted environment of
--- `testing.child.env`) and no sheet reaches a real service. Some live checks only make sense against one (the
--- `stop_reason` of a real model, a translation service). A sheet that says so names what it needs:
---
---   live = {
---     env = { "ANTHROPIC_API_KEY" },          -- the variables it gets, nothing else of the environment
---     hosts = { "api.anthropic.com" },        -- the only hosts it may reach
---     cost = "about 0.01 USD: one short request per model",
---   }
---
--- * It runs only with `testing sheets run --live`: never in the suite, never in `sheets step`, never where `CI` is
---   set (also with `--live`). Without `--live`, or without one of its variables, it is a reported skip.
--- * Its child gets the named variables, and a guard (`testing.guard.process_net`, mode error) that lets the network
---   reach the named hosts only; `curl` is let through when every URL of its arguments names one of them. Anything
---   else it starts or reaches is blocked and fails the step. A safety net, not a sandbox: what a started program does
---   on its own is not seen.
--- * The values never leave the run: every failure line, every screen of a step and every snapshot compare sees them
---   masked (`<NAME>` padded to the length of the value), so they reach no task block, no note and no snapshot file.
---   A live sheet takes no `shot` (a picture cannot be masked).
--- * `cost` is said before the sheet runs.

local M = {}

---The most variables and hosts a live sheet names.
M.MAX = 10
---The most bytes of `cost`.
M.MAX_COST = 300
---A value shorter than this is not masked: it would mask ordinary text (and is no key).
M.MIN_SECRET = 6
---The HTTP clients the guard lets through to the named hosts.
M.HTTP_CLIENTS = { "curl" }

---@class Testing.Sheet.Live
---@field env string[]
---@field hosts string[]
---@field cost string

---@param v any
---@param pattern string
---@param what string
---@return string|nil
local function names(v, pattern, what)
  if type(v) ~= "table" or not vim.islist(v) or #v == 0 or #v > M.MAX then
    return ("a list of 1 to %d %s"):format(M.MAX, what)
  end
  for _, x in ipairs(v) do
    if type(x) ~= "string" or not x:match(pattern) or #x > 200 then
      return ("%s: %s"):format(what, vim.inspect(x))
    end
  end
  return nil
end

---Why `live` is not a live block, nil when it is.
---@param live any
---@param engine string
---@param steps table[]
---@return string|nil
function M.check(live, engine, steps)
  if type(live) ~= "table" then
    return "live must be a table { env, hosts, cost }"
  end
  for k in pairs(live) do
    if k ~= "env" and k ~= "hosts" and k ~= "cost" then
      return "live: unknown field " .. tostring(k)
    end
  end
  local eerr = names(live.env, "^[%a_][%w_]*$", "environment variable names")
  if eerr then
    return "live.env: " .. eerr
  end
  local herr = names(live.hosts, "^[%w][%w.-]*$", "host names")
  if herr then
    return "live.hosts: " .. herr
  end
  for _, name in ipairs(live.env) do
    if require("testing.child.env").is_denied(name) then
      return "live.env: " .. name .. " points at the editor that runs the tests"
    end
  end
  if type(live.cost) ~= "string" or vim.trim(live.cost) == "" or #live.cost > M.MAX_COST then
    return ("live.cost: what a run costs, a text of 1 to %d bytes"):format(M.MAX_COST)
  end
  if engine ~= "rpc" then
    return "live belongs to an rpc sheet"
  end
  for i, step in ipairs(steps or {}) do
    if step.shot then
      return ("steps[%d]: a live sheet takes no shot (a picture cannot be masked)"):format(i)
    end
  end
  return nil
end

---Why a live sheet does not run here, nil when it does: only with `--live` (`opts.live`), never with `CI`, and only
---with every variable it names.
---@param s Testing.Sheet
---@param opts { live?: boolean }
---@param getenv fun(name: string): string|nil
---@return string|nil
function M.gate(s, opts, getenv)
  local live = s.live --[[@as Testing.Sheet.Live]]
  if (getenv("CI") or "") ~= "" then
    return "a live sheet (real keys and network) never runs on CI"
  end
  if not opts.live then
    return ("a live sheet (real keys and network, cost: %s): runs only with `testing sheets run --live`"):format(
      live.cost
    )
  end
  local missing = {}
  for _, name in ipairs(live.env) do
    if (getenv(name) or "") == "" then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return ("%s not set: the live sheet is skipped"):format(table.concat(missing, ", "))
  end
  return nil
end

---The variables of the live sheet with their values (only those that are set).
---@param s Testing.Sheet
---@param getenv fun(name: string): string|nil
---@return table<string, string>
function M.values(s, getenv)
  local out = {}
  for _, name in ipairs(s.live.env) do
    local v = getenv(name)
    if v and v ~= "" then
      out[name] = v
    end
  end
  return out
end

---What stands for a value: `<NAME>` padded with `*` to its length (a screen keeps its columns), only `*` for a
---value shorter than the name.
---@param name string
---@param value string
---@return string
function M.mask_of(name, value)
  local tag = "<" .. name .. ">"
  if #tag > #value then
    return ("*"):rep(#value)
  end
  return tag .. ("*"):rep(#value - #tag)
end

---A function that masks the values in a text: every whole value, and a piece of one (at least `MIN_SECRET` bytes)
---at the end or the start of the text, where a screen row cut it.
---@param values table<string, string>
---@return fun(text: any): any
function M.masker(values)
  local list = {}
  for name, v in pairs(values) do
    if #v >= M.MIN_SECRET then
      list[#list + 1] = { name = name, value = v, mask = M.mask_of(name, v) }
    end
  end
  -- the longest first: a value that contains another is masked whole
  table.sort(list, function(a, b)
    return #a.value > #b.value
  end)
  return function(text)
    if type(text) ~= "string" or #list == 0 then
      return text
    end
    for _, e in ipairs(list) do
      text = text:gsub(vim.pesc(e.value), (e.mask:gsub("%%", "%%%%")))
      for n = #e.value - 1, M.MIN_SECRET, -1 do
        local head, tail = e.value:sub(1, n), e.value:sub(-n)
        if text:sub(-n) == head then
          text = text:sub(1, -n - 1) .. ("*"):rep(n)
          break
        end
        if text:sub(1, n) == tail then
          text = ("*"):rep(n) .. text:sub(n + 1)
          break
        end
      end
    end
    return text
  end
end

---A screen of `child.screen()` with the values masked in its rows and text. A masked row keeps its length; its cells
---are masked with it where it is one byte per cell (a key is ASCII), else they are blanked.
---@param shot table
---@param mask fun(text: any): any
---@return table
function M.mask_screen(shot, mask)
  if type(shot) ~= "table" then
    return shot
  end
  for r, line in ipairs(shot.lines or {}) do
    local masked = mask(line)
    if masked ~= line then
      shot.lines[r] = masked
      local cells = shot.cells and shot.cells[r]
      if type(cells) == "table" then
        for c = 1, #cells do
          cells[c] = #masked == #cells and masked:sub(c, c) or " "
        end
      end
    end
  end
  shot.text = mask(shot.text)
  return shot
end

---The guard of a live child: every guard off but the network, which reaches the named hosts only.
---@param s Testing.Sheet
---@return table
function M.guard_config(s)
  local off = {}
  for _, name in ipairs(require("testing.guard.config").ORDER) do
    off[name] = "off"
  end
  off.process_net = {
    mode = "error",
    allow_exec = {},
    allow_hosts = vim.deepcopy(s.live.hosts),
    allow_http_exec = vim.deepcopy(M.HTTP_CLIENTS),
  }
  return { guards = off }
end

---What is said before a live sheet runs.
---@param s Testing.Sheet
---@return string
function M.notice(s)
  return ("live sheet %s: real keys (%s) and network (%s); cost: %s"):format(
    s.id,
    table.concat(s.live.env, ", "),
    table.concat(s.live.hosts, ", "),
    s.live.cost
  )
end

return M
