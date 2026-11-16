-- TESTS/testing/sheet_procs_spec.lua -- the `procs` step of a desktop sheet (`testing.sheet.proc_watch`): its shape, the
-- verdict of app-proc-watch as a failure line, the skip without the tool, a run with a watcher in memory that speaks the
-- tool's files (green and red), and, where `$TESTING_PROC_WATCH` names the real tool, the real watch of a real process:
-- a child that runs `cmd /c` must be red, one that does not must be green.
-- @cache-allow time processes
-- @cache-env TESTING_PROC_WATCH NVIM_MACHINE_ROLE
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local pw = require("testing.sheet.proc_watch")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-procs"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function write(rel, text)
    local p = root .. "/" .. rel
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end
  local nvim = vim.v.progpath:gsub("\\", "/")
  write("fake_app.lua", "vim.wait(120000)\n")
  write(".testing.lua", "return { sheets = { apps = " .. vim.inspect({
    window = { run = { nvim, "--headless", "-u", "NONE", "-l", "fake_app.lua" }, window = "demo" },
  }) .. " } }\n")
  local fake_driver = write(
    "fake_driver.lua",
    [[
while true do
  local line = io.stdin:read("*l")
  if not line then break end
  local cmd = vim.json.decode(line)
  io.stdout:write(vim.json.encode({ schema = "testing-sheet-driver/1", ok = true }), "\n")
  io.stdout:flush()
  if cmd.cmd == "close" then break end
end
]]
  )
  -- the files of app-proc-watch: a ready file at once, the verdict once the stop file is there; what it finds comes
  -- from a file beside it, the process it was told to watch goes to a log there
  local fake_watch = write(
    "fake_watch.lua",
    [==[
local a = {}
for i = 1, #_G.arg do
  if _G.arg[i]:sub(1, 1) == "-" then a[_G.arg[i]] = _G.arg[i + 1] end
end
local root = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local function put(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local log = assert(io.open(root .. "/watch.log", "ab")); log:write(a["-ProcessId"], "\n"); log:close()
put(a["-ReadyFile"], a["-ProcessId"])
vim.wait(60000, function() return vim.uv.fs_stat(a["-StopFile"]) ~= nil end, 20)
local found = io.open(root .. "/watch.finds", "rb")
local verdict = { clean = true, console_window = "no", shell_descendants = {} }
if found then
  local what = found:read("*a"); found:close()
  if what == "shell" then
    verdict = { clean = false, console_window = "no",
      shell_descendants = { { name = "cmd.exe", pid = 7, command_line = "cmd /c start out.mp4" } } }
  end
end
put(a["-OutDir"] .. "/procs.json", "\239\187\191" .. vim.json.encode({ verdict = verdict, windows = {} }))
]==]
  )
  local function opts()
    return {
      root = root,
      driver_argv = { nvim, "--headless", "-u", "NONE", "-l", fake_driver },
      proc_watch_argv = { nvim, "--headless", "-u", "NONE", "-l", fake_watch },
      driver_margin_ms = 20000,
      driver_stop_ms = 2000,
    }
  end
  local function desktop(steps)
    return assert(
      sheet.validate({ id = "d.p", title = "T", engine = "desktop", app = "window", steps = steps })
    )
  end

  -- 1. the shape ---------------------------------------------------------------------------------------------------------
  do
    desktop({ { procs = "clean" }, { wait = "a" }, { procs = "clean" } })
    local _, bad = sheet.validate({
      id = "x",
      title = "T",
      engine = "desktop",
      app = "a",
      steps = { { procs = "dirty" } },
    })
    has(bad, '.procs: "clean"', "procs knows one verdict")
    local _, rpc = sheet.validate({ id = "x", title = "T", steps = { { procs = "clean" } } })
    has(rpc, "procs is not a step of a rpc sheet", "procs is for a desktop sheet only")
    local _, t = sheet.validate({
      id = "x",
      title = "T",
      engine = "desktop",
      app = "a",
      steps = { { procs = "clean", timeout = 5 } },
    })
    has(t, "timeout belongs", "procs takes no timeout")
  end

  -- 2. the verdict as a line, and when there is no tool ----------------------------------------------------------------
  do
    eq(pw.judge({ verdict = { clean = true } }), nil, "clean is no reason")
    local why = pw.judge({
      verdict = {
        clean = false,
        console_window = "yes",
        shell_descendants = { { name = "cmd.exe", pid = 12, command_line = 'cmd /c "start x"' } },
      },
      windows = {
        {
          console = true,
          class = "ConsoleWindowClass",
          title = "C:\\x\ncmd",
          process = "conhost.exe",
        },
      },
    })
    has(why, 'shell cmd.exe (PID 12): cmd /c "start x"', "a shell is named with its command line")
    has(why, "console window: yes", "... and the console window")
    has(
      why,
      "ConsoleWindowClass 'C:\\x cmd' of conhost.exe",
      "... with its class, title and program"
    )
    ok(not why:find("\n"), "... on one line")
    has(pw.judge({}), "no verdict", "a result without a verdict is a reason")
    -- JSON null comes as vim.NIL, which is true in Lua: no abort, no list
    eq(
      pw.judge({
        aborted = vim.NIL,
        windows = vim.NIL,
        verdict = { clean = false, console_window = vim.NIL, shell_descendants = vim.NIL },
      }),
      "not clean",
      "a null is neither an abort nor a finding"
    )

    local env =
      { NVIM_MACHINE_ROLE = "workstation", TESTING_PROC_WATCH = root .. "/fake_watch.lua" }
    local function getenv(k)
      return env[k]
    end
    if require("testing.platform").is_windows() then
      local argv, skip = pw.find(getenv)
      eq(argv, nil, "no watch on the workstation")
      has(skip, "workstation", "... says so")
      env.NVIM_MACHINE_ROLE = nil
      env.TESTING_PROC_WATCH = nil
      has(
        select(2, pw.find(getenv)),
        "$TESTING_PROC_WATCH",
        "without the tool named: a skip that names the variable"
      )
      env.TESTING_PROC_WATCH = root .. "/missing.ps1"
      has(select(2, pw.find(getenv)), "is no file", "a named tool that is not there")
    else
      local argv, skip = pw.find(getenv)
      eq(argv, nil, "no watch off Windows")
      has(skip, "Windows only", "... says so")
    end

    -- a sheet with a procs step and no tool is a skip, never green
    local o = opts()
    o.proc_watch_argv = nil
    local saved = vim.env.TESTING_PROC_WATCH
    vim.env.TESTING_PROC_WATCH = nil
    local res = sheet.run(desktop({ { wait = "a" }, { procs = "clean" } }), o)
    vim.env.TESTING_PROC_WATCH = saved
    eq(res.status, "skip", "without app-proc-watch the sheet is a skip")
  end

  -- 3. a run: green, then red with the finding -------------------------------------------------------------------------
  do
    os.remove(root .. "/watch.log")
    os.remove(root .. "/watch.finds")
    local s = desktop({ { wait = "a" }, { procs = "clean" }, { click = "b" }, { procs = "clean" } })
    local res = sheet.run(s, opts())
    eq({ res.status, res.failures }, { "pass", {} }, "a clean watch: green")
    local log = root .. "/watch.log"
    local pids = vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
    eq(#pids, 3, "a watch from the start, one after each procs step")
    ok(tonumber(pids[1]) and tonumber(pids[1]) > 0, "... of the app's process")
    eq(pids[2], pids[1], "... the same process each time")

    write("watch.finds", "shell")
    res = sheet.run(s, opts())
    eq(res.status, "fail", "a shell under the app: red")
    has(
      res.failures[1],
      "step 2, procs clean: shell cmd.exe (PID 7): cmd /c start out.mp4",
      "the line names the step and what was found"
    )
    os.remove(root .. "/watch.finds")
  end

  -- 4. the real tool on a real process (only where it is named) ----------------------------------------------------------
  local argv, skip = pw.find()
  if not argv then
    print("note: sheet_procs_spec part 4 not run: " .. tostring(skip))
  else
    local pwsh = vim.fn.exepath("pwsh")
    local function child(script)
      local trigger = vim.fn.tempname()
      local proc = vim.system({
        pwsh,
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        script:gsub("TRIGGER", trigger),
      })
      return proc, trigger
    end
    local function judged(script)
      local proc, trigger = child(script)
      local w, err = pw.start(argv, proc.pid)
      ok(w ~= nil, "the real tool watches: " .. tostring(err))
      if not w then
        proc:kill(9)
        return nil
      end
      local f = assert(io.open(trigger, "w"))
      f:write("go")
      f:close()
      vim.wait(4000)
      local reason, verr = w.verdict()
      proc:kill(9)
      os.remove(trigger)
      eq(verr, nil, "the real tool wrote its verdict")
      return reason
    end
    local wait = "while (-not (Test-Path 'TRIGGER')) { Start-Sleep -Milliseconds 50 }; "
    local red = judged(wait .. "cmd /c 'ping -n 2 127.0.0.1 > nul'; Start-Sleep 60")
    has(red, "shell cmd.exe", "a child that runs cmd /c: red, cmd named")
    local green = judged(wait .. "Start-Sleep 60")
    eq(green, nil, "a child that runs no shell: clean")
  end

  vim.fn.delete(root, "rf")
end
