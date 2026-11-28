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
---
--- `prepare` (an argv or a list of them, like `build`) runs after the folder of the run exists and before the app
--- starts, with `${temp}` filled in: what the app should find there (a settings file, a recording). `start = "link"`
--- starts the program the way a link or a double click does on Windows: no standard handles and a parent without a
--- console (`testing/sheet/link_start.lua`), so a window program shows its errors in a message box. There is no
--- stdout then, so it takes no `ready`. `cleanup` (like `prepare`) runs after the app has ended and before its folder
--- is removed: for what it left outside its process tree, such as a window another program opened for it.

local M = {}

M.BUILD_MS = 600000
---The longest a build may be given with `build_timeout_ms` (a release build of a Tauri app takes minutes).
M.BUILD_MAX_MS = 3600000
---How much earlier than its limit a step that ended with exit 124 still counts as ended by the limit.
M.TIMEOUT_SLACK_MS = 50
M.READY_MS = 30000
M.STOP_MS = 2000

---How long `stop` waits for the end of an app it killed.
M.KILL_WAIT_MS = 5000
---How long a program with a window is watched for ending at once (a second instance that hands over).
M.EARLY_MS = 1500
---How long the steps of `cleanup` may take together.
M.CLEANUP_MS = 60000
---How long the starter of `start = "link"` may take to say the pid of the program.
M.LINK_MS = 15000

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

---Did `obj:wait(limit)` end the step? `wait` kills a step past its limit and says exit 124; a step that exits 124 by
---itself does so well before. The timer of `wait` may fire a little before the clock of the caller says `limit`, so
---the last `TIMEOUT_SLACK_MS` count as reached. No result at all: the killed step did not even end within a second
---wait of `limit` (a busy machine), which is the limit too.
---@param done vim.SystemCompleted|nil What `wait` returned.
---@param elapsed_ms number
---@param limit integer
---@return boolean
function M.timed_out(done, elapsed_ms, limit)
  return done == nil or (done.code == 124 and elapsed_ms + M.TIMEOUT_SLACK_MS >= limit)
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
      and k ~= "prepare"
      and k ~= "cleanup"
      and k ~= "start"
      and k ~= "window_ms"
      and k ~= "build_timeout_ms"
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
  if spec.prepare ~= nil and not is_build(spec.prepare) then
    return "prepare must be a list of strings (an argv, no shell) or a list of such lists"
  end
  if spec.cleanup ~= nil and not is_build(spec.cleanup) then
    return "cleanup must be a list of strings (an argv, no shell) or a list of such lists"
  end
  if spec.start ~= nil and spec.start ~= "link" then
    return 'start must be "link" (or left out)'
  end
  if spec.start == "link" and spec.ready ~= nil then
    return 'start = "link" gives the program no stdout: it takes no ready'
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
  if
    spec.window_ms ~= nil
    and (
      type(spec.window_ms) ~= "number"
      or spec.window_ms % 1 ~= 0
      or spec.window_ms < 1
      or spec.window_ms > M.BUILD_MS
    )
  then
    return "window_ms must be a whole number of milliseconds"
  end
  if
    spec.build_timeout_ms ~= nil
    and (
      type(spec.build_timeout_ms) ~= "number"
      or spec.build_timeout_ms % 1 ~= 0
      or spec.build_timeout_ms < 1
      or spec.build_timeout_ms > M.BUILD_MAX_MS
    )
  then
    return ("build_timeout_ms must be a whole number of milliseconds, at most %d"):format(
      M.BUILD_MAX_MS
    )
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
---A bare name on Windows: the system's search takes `.exe` only, so `pnpm` (a `pnpm.cmd` shim) was never found. The
---extensions a process can start (`.com`, `.exe`, `.bat`, `.cmd`) are tried in the order of PATHEXT, because a bare
---`exepath("pnpm")` answers the extensionless shell script that sits beside the shim, which Windows cannot run. The name
---stays when nothing is found (the start then says so); a name with an extension of its own is looked up as it is.
---@param program string
---@return string
local function find_launchable(program)
  local launchable = { [".com"] = true, [".exe"] = true, [".bat"] = true, [".cmd"] = true }
  if launchable[(program:match("%.[^.]+$") or ""):lower()] then
    local found = vim.fn.exepath(program)
    return found ~= "" and found or program
  end
  local exts = {}
  for ext in (vim.env.PATHEXT or ""):gmatch("[^;]+") do
    if launchable[ext:lower()] then
      exts[#exts + 1] = ext:lower()
    end
  end
  if #exts == 0 then
    exts = { ".com", ".exe", ".bat", ".cmd" }
  end
  for _, ext in ipairs(exts) do
    local found = vim.fn.exepath(program .. ext)
    if found ~= "" then
      return found
    end
  end
  return program
end

local function resolve(program, root)
  if not program:find("[/\\]") or program:match("^%a:[/\\]") or program:match("^[/\\]") then
    if not program:find("[/\\]") and require("testing.platform").is_windows() then
      return find_launchable(program)
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

---Run the steps of `prepare` or `cleanup` in the project root, `${temp}` filled in; the first that fails ends it.
---@param steps string[]|string[][]
---@param root string
---@param vars table<string, string>
---@param label? string `prepare` (default) or `cleanup`.
---@param ms? integer How long each step may take.
---@return string|nil err
local function run_prepare(steps, root, vars, label, ms)
  label = label or "prepare"
  for n, step in ipairs(build_steps(steps)) do
    local which = label .. (type(steps[1]) == "table" and (" (step %d)"):format(n) or "")
    local argv, xerr = expand_all(step, vars)
    if not argv then
      return ("its %s: %s"):format(which, xerr)
    end
    argv[1] = resolve(argv[1], root)
    local berr = batch_args_ok(argv)
    if berr then
      return ("its %s was not started: %s"):format(which, berr)
    end
    local ok, obj = pcall(vim.system, argv, { cwd = root, text = true })
    if not ok then
      return ("its %s did not start: %s"):format(which, tostring(obj))
    end
    local limit = ms or M.BUILD_MS
    local began = vim.uv.hrtime()
    local done = obj:wait(limit)
    if M.timed_out(done, (vim.uv.hrtime() - began) / 1e6, limit) then
      return ("its %s did not finish in %s s"):format(which, tostring(limit / 1000))
    end
    if done.code ~= 0 then
      local why = vim.trim(done.stderr ~= "" and done.stderr or done.stdout or ""):sub(-300)
      return ("its %s failed (exit %d): %s"):format(which, done.code, why)
    end
  end
  return nil
end

---The starter script of `start = "link"`: the one beside this file, so that it is of the same version (another
---copy of testing.nvim on the runtimepath may be older or newer); the runtimepath only when that one is not there.
---@return string
function M.starter()
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/link_start.lua"
  if vim.uv.fs_stat(here) then
    return here
  end
  return vim.api.nvim_get_runtime_file("lua/testing/sheet/link_start.lua", false)[1] or here
end

---The argv that starts `argv` the way a link does (`start = "link"`, Windows): the starter script in an editor of
---its own, which says the pid of the program on its stdout. Elsewhere the program itself.
---@param argv string[]
---@return string[] argv, boolean through Whether the starter stands between.
local function link_argv(argv)
  if not require("testing.platform").is_windows() then
    return argv, false
  end
  local starter = M.starter()
  local out = { vim.v.progpath, "--clean", "-l", starter }
  vim.list_extend(out, argv)
  return out, true
end

---End an app with everything it started. On Windows the process table is walked from the root down
---(`testing.child.winproc`); `testing.child.kill_tree` takes a handle of its own children only (it needs their libuv
---handle), so for the process of an app it found no root and ended nothing below it. While the root is not ended its
---handle stays open, so its pid cannot go to another process in between.
---@param proc vim.SystemObj|table
local function kill_app_tree(proc)
  local function kill_root()
    return (pcall(proc.kill, proc, 9))
  end
  if require("testing.platform").is_windows() then
    local winproc = require("testing.child.winproc")
    local w = winproc.load()
    if w and winproc.kill_trees(w, { { pid = proc.pid, kill = kill_root } }) then
      return
    end
  end
  require("testing.child").kill_tree({ pid = proc.pid })
  kill_root()
end

---@class Testing.Sheet.App
---@field vars table<string, string> What a sheet may fill in: `temp`, and the name of `ready.as`.
---@field pid? integer Not with `prepare_only`.
---@field window? string A part of the title of its window.
---@field window_ms? integer How long the desktop engine waits for that window (its driver's default: 30 s).
---@field stop fun() The whole process tree and the folder go away. Safe to call twice.
---@field ended? fun(): boolean Has the app's process ended (its exit seen)? Not with `prepare_only`.
---@field argv? string[] With `prepare_only`: the program and its arguments, filled in, the program resolved.
---@field env? table<string, string> With `prepare_only`: its environment, filled in.

---Build and start an app, wait until it is ready.
---@param name string
---@param root string
---With `prepare_only` the app is built and its argv and env are filled in, but another program starts it (the webview
---engine: tauri-driver starts the app it drives); `stop` then only removes the folder of the run.
---@param opts? { prepare_only?: boolean, cancelled?: fun(): boolean }
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
      local limit = spec.build_timeout_ms or M.BUILD_MS
      local began = vim.uv.hrtime()
      local done = obj:wait(limit)
      -- `wait` ends a build that runs too long with exit 124; a build that says 124 itself returns before the limit
      if M.timed_out(done, (vim.uv.hrtime() - began) / 1e6, limit) then
        return nil,
          ("its build%s did not finish in %s s (sheets.apps[%q].build_timeout_ms, default %d)"):format(
            which,
            tostring(limit / 1000),
            name,
            M.BUILD_MS
          )
      end
      if done.code ~= 0 then
        local why = vim.trim(done.stderr ~= "" and done.stderr or done.stdout or ""):sub(-300)
        return nil, ("its build%s failed (exit %d): %s"):format(which, done.code, why)
      end
    end
  end

  local temp = vim.fs.normalize(vim.fn.tempname()) .. "-app"
  vim.fn.mkdir(temp, "p")
  local vars = { temp = temp }
  if spec.prepare then
    local perr = run_prepare(spec.prepare, root, vars)
    if perr then
      pcall(vim.fn.delete, temp, "rf")
      return nil, perr
    end
  end
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
        kill_app_tree(proc)
        -- on every way, not only the walk of the Windows process table (which waits per process): the fallback
        -- (`testing.child.kill_tree` and a kill of the root, the only way off Windows) returned while the app still
        -- held its ports, and the app of the next sheet found them taken
        vim.wait(M.KILL_WAIT_MS, function()
          return exit_code ~= nil
        end, 20)
      end
    end
    -- what the app left outside its tree (a window another program opened for it): best effort, never a failure
    if spec.cleanup then
      pcall(run_prepare, spec.cleanup, root, vars, "cleanup", M.CLEANUP_MS)
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
  if opts.prepare_only then
    return {
      vars = vars,
      stop = stop,
      argv = argv,
      env = env,
      window = spec.window,
      window_ms = spec.window_ms,
    },
      nil
  end

  -- `start = "link"`: the starter stands between, detached so that the program finds no console of a parent
  local through = false
  if spec.start == "link" then
    argv, through = link_argv(argv)
  end

  local lines, partial, stderr = {}, "", {}
  local ok, obj = pcall(vim.system, argv, {
    cwd = root,
    env = env,
    detach = through or nil,
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
  local pid = proc.pid

  if through then
    local said
    vim.wait(M.LINK_MS, function()
      for _, line in ipairs(lines) do
        said = said or tonumber(line:match("^pid (%d+)%s*$"))
      end
      return said ~= nil or exit_code ~= nil
    end, 20)
    if not said then
      stop()
      return nil,
        ("its starter (start = link) said no pid%s: %s"):format(
          exit_code and (" (exit %d)"):format(exit_code) or "",
          vim.trim(table.concat(stderr)):sub(1, 300)
        )
    end
    pid = said
  end

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
  return {
    vars = vars,
    stop = stop,
    ended = function()
      return exit_code ~= nil
    end,
    pid = pid,
    window = spec.window,
    window_ms = spec.window_ms,
  },
    nil
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
