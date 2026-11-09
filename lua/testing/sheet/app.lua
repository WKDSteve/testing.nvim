---@module 'testing.sheet.app'
---@brief The program a test sheet runs against: named in the sheet, described in `.testing.lua`, started for one run.
---@description
--- A sheet is data and starts nothing; it names an app (`app = "demo-hub"`). How that app starts is the project's
--- `.testing.lua`, which runs under the trust gate anyway:
---
---   sheets = {
---     browser = { playwright_dir = "tools/page-check", channel = "chrome" },
---     apps = {
---       ["demo-hub"] = {
---         build = { "cargo", "build", "-p", "pult-hub", "--example", "demo-hub", "--locked" },
---         run = { "target/debug/examples/demo-hub.exe" },
---         env = { PULT_PORT = "0", PULT_CONFIG_DIR = "${temp}" },
---         ready = { stdout = "^http", as = "link", timeout_ms = 30000 },
---       },
---     },
---   }
---
--- `build` and `run` are argv lists, never a shell. Both run in the project root. `${temp}` is a folder of this run,
--- gone afterwards, so the user's real settings stay untouched. `ready` waits for a line on the app's stdout that
--- matches the Lua pattern; `as` makes that line available to the sheet as `${link}` in an `open` step. That is all a
--- sheet can do with it: it fills in fixed names, it runs no Lua.

local M = {}

M.BUILD_MS = 600000
M.READY_MS = 30000
M.STOP_MS = 2000
---How long a program with a window is watched for ending at once (a second instance that hands over).
M.EARLY_MS = 1500

---Fill in `${name}`; an unknown name is an error, not an empty string.
---@param text string
---@param vars table<string, string>
---@return string|nil text, string|nil err
function M.expand(text, vars)
  local missing
  local out = text:gsub("%${([%w_]+)}", function(name)
    local v = vars[name]
    if v == nil then
      missing = name
      return ""
    end
    return v
  end)
  if missing then
    return nil, ("unknown ${%s}"):format(missing)
  end
  return out, nil
end

---@param v any
---@return boolean
local function is_argv(v)
  if type(v) ~= "table" or #v == 0 then
    return false
  end
  for k, s in pairs(v) do
    if type(k) ~= "number" or type(s) ~= "string" or s == "" then
      return false
    end
  end
  return true
end

---`build` is one argv or a list of argvs (a step after the other: the interface of a page, then the program that embeds it).
---@param v any
---@return boolean
local function is_build(v)
  if is_argv(v) then
    return true
  end
  if type(v) ~= "table" or #v == 0 then
    return false
  end
  for k, argv in pairs(v) do
    if type(k) ~= "number" or not is_argv(argv) then
      return false
    end
  end
  return true
end

---The steps of a build as a list of argvs, whichever form it was written in.
---@param build string[]|string[][]
---@return string[][]
local function build_steps(build)
  if type(build[1]) == "table" then
    return build
  end
  return { build }
end

---What is wrong with the description of an app.
---@param spec any
---@return string|nil err
function M.check(spec)
  if type(spec) ~= "table" then
    return "must be a table"
  end
  for k in pairs(spec) do
    if
      k ~= "build"
      and k ~= "run"
      and k ~= "env"
      and k ~= "ready"
      and k ~= "window"
      and k ~= "ended_early"
    then
      return "unknown field " .. tostring(k)
    end
  end
  if not is_argv(spec.run) then
    return "run must be a list of strings (an argv, no shell)"
  end
  if spec.build ~= nil and not is_build(spec.build) then
    return "build must be a list of strings (an argv, no shell) or a list of such lists"
  end
  if spec.env ~= nil then
    if type(spec.env) ~= "table" then
      return "env must be a table of strings"
    end
    for k, v in pairs(spec.env) do
      if type(k) ~= "string" or type(v) ~= "string" then
        return "env must be a table of strings"
      end
    end
  end
  if spec.window ~= nil and (type(spec.window) ~= "string" or spec.window == "") then
    return "window must be a part of the title"
  end
  if spec.ended_early ~= nil and (type(spec.ended_early) ~= "string" or spec.ended_early == "") then
    return "ended_early must be a text"
  end
  if spec.ready ~= nil then
    local r = spec.ready
    if type(r) ~= "table" or type(r.stdout) ~= "string" or r.stdout == "" then
      return "ready needs stdout, a Lua pattern"
    end
    if r.as ~= nil and (type(r.as) ~= "string" or not r.as:match("^[%w_]+$") or r.as == "temp") then
      return "ready.as must be a name (letters, digits, _), not temp"
    end
    if
      r.timeout_ms ~= nil
      and (type(r.timeout_ms) ~= "number" or r.timeout_ms < 1 or r.timeout_ms > M.BUILD_MS)
    then
      return "ready.timeout_ms must be a number of milliseconds"
    end
    local ok = pcall(string.find, "", r.stdout)
    if not ok then
      return "ready.stdout is not a Lua pattern"
    end
  end
  return nil
end

---The `sheets` section of the project's `.testing.lua`; {} without one. Runs that file: the caller has passed the
---trust gate (a command) or runs the project's code anyway (a spec).
---@param root string
---@return table sheets, string|nil err
function M.config(root)
  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    return {}, loaded.error
  end
  local sheets = loaded.config.sheets
  return type(sheets) == "table" and sheets or {}, nil
end

---A program named by a path runs from the project root; a bare name comes from the PATH.
---@param program string
---@param root string
---@return string
local function resolve(program, root)
  if not program:find("[/\\]") or program:match("^%a:[/\\]") or program:match("^[/\\]") then
    -- A bare name on Windows: the system's search takes `.exe` only, so `pnpm` (a `pnpm.cmd` shim) was never found.
    -- `exepath` reads PATHEXT like the shell does; the name stays when nothing is found (the start then says so).
    if not program:find("[/\\]") and require("testing.platform").is_windows() then
      local found = vim.fn.exepath(program)
      if found ~= "" then
        return found
      end
    end
    return program
  end
  return root .. "/" .. program
end

---A batch file runs through `cmd.exe`, which reads its arguments again: a quote, `%`, `&`, `|`, `<`, `>`, `^` or a line
---break in one of them would be taken for the shell's own. What a `.testing.lua` writes for it is checked, not quoted.
---@param argv string[]
---@return string|nil err
local function batch_args_ok(argv)
  if not argv[1]:lower():match("%.[cb][ma][dt]$") then
    return nil
  end
  for i = 2, #argv do
    if argv[i]:find('[%"%%&|<>%^\r\n]') then
      return ("argument %d of %s has a character that cmd.exe would read as its own: %q"):format(
        i,
        argv[1],
        argv[i]
      )
    end
  end
  return nil
end

---@param argv string[]
---@param vars table<string, string>
---@return string[]|nil argv, string|nil err
local function expand_all(argv, vars)
  local out = {}
  for i, a in ipairs(argv) do
    local e, err = M.expand(a, vars)
    if not e then
      return nil, err
    end
    out[i] = e
  end
  return out, nil
end

---@class Testing.Sheet.App
---@field vars table<string, string> What a sheet may fill in: `temp`, and the name of `ready.as`.
---@field pid integer
---@field window? string A part of the title of its window.
---@field stop fun() The whole process tree and the folder go away. Safe to call twice.

---Build and start an app, wait until it is ready.
---@param name string
---@param root string
---@param opts? { cancelled?: fun(): boolean }
---@return Testing.Sheet.App|nil app, string|nil err, string|nil skip Why the sheet is a skip, not a failure.
function M.start(name, root, opts)
  opts = opts or {}
  local sheets, cerr = M.config(root)
  if cerr then
    return nil, cerr
  end
  local spec = type(sheets.apps) == "table" and sheets.apps[name] or nil
  if spec == nil then
    return nil, ("no app %s in sheets.apps of %s/.testing.lua"):format(name, root)
  end
  local bad = M.check(spec)
  if bad then
    return nil, ("sheets.apps[%q]: %s"):format(name, bad)
  end

  if spec.build then
    for n, step in ipairs(build_steps(spec.build)) do
      local argv = vim.deepcopy(step)
      argv[1] = resolve(argv[1], root)
      local which = type(spec.build[1]) == "table" and (" (step %d)"):format(n) or ""
      local berr = batch_args_ok(argv)
      if berr then
        return nil, ("its build%s was not started: %s"):format(which, berr)
      end
      local ok, obj = pcall(vim.system, argv, { cwd = root, text = true })
      if not ok then
        return nil, ("its build%s did not start: %s"):format(which, tostring(obj))
      end
      local done = obj:wait(M.BUILD_MS)
      if done.code ~= 0 then
        local why = vim.trim(done.stderr ~= "" and done.stderr or done.stdout or ""):sub(-300)
        return nil, ("its build%s failed (exit %d): %s"):format(which, done.code, why)
      end
    end
  end

  local temp = vim.fs.normalize(vim.fn.tempname()) .. "-app"
  vim.fn.mkdir(temp, "p")
  local vars = { temp = temp }
  local proc
  local exit_code
  local stopped = false

  local function stop()
    if stopped then
      return
    end
    stopped = true
    if proc then
      -- closed stdin first, for a program that ends on it; then the tree, whatever it has started
      pcall(proc.write, proc, nil)
      vim.wait(M.STOP_MS, function()
        return exit_code ~= nil
      end, 20)
      if exit_code == nil then
        require("testing.child").kill_tree({ pid = proc.pid })
        pcall(proc.kill, proc, 9)
      end
    end
    pcall(vim.fn.delete, temp, "rf")
  end

  local argv, aerr = expand_all(spec.run, vars)
  if not argv then
    stop()
    return nil, aerr
  end
  argv[1] = resolve(argv[1], root)
  local env = {}
  for k, v in pairs(spec.env or {}) do
    local e, eerr = M.expand(v, vars)
    if not e then
      stop()
      return nil, ("env %s: %s"):format(k, eerr)
    end
    env[k] = e
  end

  local lines, partial, stderr = {}, "", {}
  local ok, obj = pcall(vim.system, argv, {
    cwd = root,
    env = env,
    stdin = true,
    text = false,
    stdout = function(_, data)
      if data then
        partial = partial .. data
        for line in partial:gmatch("([^\n]*)\n") do
          lines[#lines + 1] = line
        end
        partial = partial:match("([^\n]*)$") or ""
      end
    end,
    stderr = function(_, data)
      if data and #stderr < 50 then
        stderr[#stderr + 1] = data
      end
    end,
  }, function(done)
    exit_code = done.code
  end)
  if not ok then
    stop()
    return nil, "it did not start: " .. tostring(obj)
  end
  proc = obj

  -- a program that hands over to one already running ends at once with success: `ended_early` says what that means
  local function ended_early()
    if exit_code == 0 and spec.ended_early then
      return spec.ended_early
    end
    return nil
  end

  if spec.window and not spec.ready then
    vim.wait(M.EARLY_MS, function()
      return exit_code ~= nil
    end, 20)
    if exit_code ~= nil then
      local skip = ended_early()
      stop()
      return nil,
        ("it ended (exit %d) before its window: %s"):format(
          exit_code,
          vim.trim(table.concat(stderr)):sub(1, 300)
        ),
        skip
    end
  end

  if spec.ready then
    local timeout = spec.ready.timeout_ms or M.READY_MS
    local cancelled = opts.cancelled or function()
      return false
    end
    local matched
    vim.wait(timeout, function()
      for _, line in ipairs(lines) do
        if line:find(spec.ready.stdout) then
          matched = vim.trim(line)
          return true
        end
      end
      return exit_code ~= nil or cancelled()
    end, 20)
    if not matched then
      local skip = ended_early()
      local why = exit_code ~= nil
          and ("it ended (exit %d) before it was ready: %s"):format(
            exit_code,
            vim.trim(table.concat(stderr)):sub(1, 300)
          )
        or cancelled() and "aborted"
        or ("no line matched %q in %d ms"):format(spec.ready.stdout, timeout)
      stop()
      return nil, why, skip
    end
    if spec.ready.as then
      vars[spec.ready.as] = matched
    end
  end
  return { vars = vars, stop = stop, pid = proc.pid, window = spec.window }, nil
end

---The steps with the `${names}` of the app filled in. Only `open` takes them.
---@param step Testing.Sheet.Step
---@param vars table<string, string>
---@return Testing.Sheet.Step|nil step, string|nil err
function M.expand_step(step, vars)
  if not step.open then
    return step, nil
  end
  local open, err = M.expand(step.open, vars)
  if not open then
    return nil, err
  end
  local copy = vim.deepcopy(step)
  copy.open = open
  return copy, nil
end

return M
