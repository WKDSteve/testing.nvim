-- @cache-env TESTING_PROC_WATCH
---@module 'testing.sheet.proc_watch'
---@brief The processes and console windows of a desktop or webview sheet's app, by app-proc-watch: a `procs` step.
---@description
--- A desktop sheet with a `procs = "clean"` step runs its app under app-proc-watch (a PowerShell 7 tool of the author's
--- tasks-vault, `TOOLS/scripts/app-proc-watch/app-proc-watch.ps1`, named by `$TESTING_PROC_WATCH`) in attach mode: it
--- watches the app's process from its start on (a webview sheet: the driver process, whose tauri-driver starts
--- the app). The step ends that watch (`-StopFile`) and reads its verdict: no shell
--- (cmd, powershell, ...) as a descendant of the app and no console window, up to that step. A later `procs` step
--- watches again from there. Without the tool, pwsh or Windows the sheet is a reported skip, never green; on the
--- workstation too (process snapshots there can read as an attack to an EDR).
---
--- Attach mode polls (10 ms): a child that starts and ends between two scans is not seen. What the tool reports goes
--- into the failure line as it stands; nothing here reads another process's memory.

local M = {}

---How long the tool may take to say it watches (pwsh starts and compiles its watcher).
M.READY_MS = 30000
---How long it may take to write its verdict after the stop file.
M.VERDICT_MS = 30000
---The longest a watch runs: the phase of the tool, in seconds.
M.MAX_SECONDS = 3600

---@param getenv? fun(name: string): string|nil
---@return string[]|nil argv The start of the tool's command line, or nil and the reason of a skip.
---@return string|nil skip
function M.find(getenv)
  getenv = getenv or vim.uv.os_getenv
  if not require("testing.platform").is_windows() then
    return nil, "app-proc-watch measures on Windows only"
  end
  local workstation = require("testing.machine").is_workstation(getenv)
  if workstation ~= false then
    return nil,
      "app-proc-watch does not run on the workstation (process snapshots there can read as an attack)"
  end
  local script = getenv("TESTING_PROC_WATCH")
  if not script or script == "" then
    return nil, "app-proc-watch is not named ($TESTING_PROC_WATCH: the path of app-proc-watch.ps1)"
  end
  if vim.fn.filereadable(script) ~= 1 then
    return nil, ("$TESTING_PROC_WATCH %s is no file"):format(script)
  end
  local pwsh = vim.fn.exepath("pwsh")
  if pwsh == "" then
    return nil, "app-proc-watch needs PowerShell 7 (pwsh) on the PATH"
  end
  return { pwsh, "-NoProfile", "-NonInteractive", "-File", script }, nil
end

---What the verdict of one watch says against the step: nil when clean, else one line with what was found.
---@param result table The JSON of app-proc-watch.
---@return string|nil reason
function M.judge(result)
  local v = type(result) == "table" and result.verdict or nil
  if type(v) ~= "table" then
    return "app-proc-watch wrote no verdict"
  end
  if v.clean == true then
    return nil
  end
  -- a list of the JSON, or none: a null (vim.NIL, which is true) is no list
  local function list(x)
    return type(x) == "table" and x or {}
  end
  local found = {}
  for _, s in ipairs(list(v.shell_descendants)) do
    found[#found + 1] = ("shell %s (PID %s): %s"):format(
      tostring(s.name),
      tostring(s.pid),
      tostring(s.command_line or "?")
    )
  end
  if type(v.console_window) == "string" and v.console_window ~= "no" then
    found[#found + 1] = ("console window: %s"):format(tostring(v.console_window))
  end
  for _, w in ipairs(list(result.windows)) do
    if type(w) == "table" and w.console == true then
      found[#found + 1] = ("window %s '%s' of %s"):format(
        tostring(w.class),
        tostring(w.title),
        tostring(w.process)
      )
    end
  end
  for _, u in ipairs(list(v.unknown_descendants)) do
    found[#found + 1] = ("a descendant PID %s ended before its name could be read"):format(
      tostring(u.pid)
    )
  end
  if type(result.aborted) == "string" then
    found[#found + 1] = "the watch was aborted: " .. tostring(result.aborted)
  end
  if #found == 0 then
    found[1] = "not clean"
  end
  -- one line: the failure line of a sheet keeps only its first line
  return (table.concat(found, "; "):gsub("%s+", " "))
end

---@class Testing.Sheet.ProcWatch
---@field verdict fun(): string|nil, string|nil Ends the watch: nil when clean, else the reason; second the error.
---@field stop fun() Ends the watch without a verdict. Safe to call twice.

---Starts a watch of process `pid` and waits until it runs.
---@param argv string[] From `find`.
---@param pid integer
---@param opts? { cancelled?: (fun(): boolean), ready_ms?: integer, verdict_ms?: integer }
---@return Testing.Sheet.ProcWatch|nil watch, string|nil err
function M.start(argv, pid, opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local stop_file, ready_file = dir .. "/stop", dir .. "/ready"
  local cmd = vim.list_extend(vim.deepcopy(argv), {
    "-ProcessId",
    tostring(pid),
    "-Label",
    "procs",
    "-Phases",
    ("watch:%d"):format(M.MAX_SECONDS),
    "-OutDir",
    dir,
    "-StopFile",
    stop_file,
    "-ReadyFile",
    ready_file,
    "-Quiet",
  })
  local exit_code
  local errs = {}
  local ok, proc = pcall(vim.system, cmd, {
    text = true,
    stdout = false,
    stderr = function(_, data)
      if data and #errs < 20 then
        errs[#errs + 1] = data
      end
    end,
  }, function(done)
    exit_code = done.code
  end)
  if not ok then
    vim.fn.delete(dir, "rf")
    return nil, "app-proc-watch did not start: " .. tostring(proc)
  end
  local function why()
    return vim.trim(table.concat(errs)):gsub("%s+", " "):sub(1, 300)
  end
  vim.wait(opts.ready_ms or M.READY_MS, function()
    return exit_code ~= nil
      or vim.fn.filereadable(ready_file) == 1
      or (opts.cancelled and opts.cancelled())
  end, 50)
  if vim.fn.filereadable(ready_file) ~= 1 then
    pcall(proc.kill, proc, 9)
    vim.fn.delete(dir, "rf")
    if exit_code ~= nil then
      return nil, ("app-proc-watch ended (exit %d) before it watched: %s"):format(exit_code, why())
    end
    return nil, "app-proc-watch did not start to watch in time"
  end

  local W = {}
  local done = false
  local function finish()
    local f = io.open(stop_file, "w")
    if f then
      f:write("stop")
      f:close()
    end
    vim.wait(opts.verdict_ms or M.VERDICT_MS, function()
      return exit_code ~= nil
    end, 50)
    if exit_code == nil then
      pcall(proc.kill, proc, 9)
    end
  end

  function W.verdict()
    if done then
      return nil, "the watch is over"
    end
    done = true
    finish()
    local text = vim.fn.filereadable(dir .. "/procs.json") == 1
        and table.concat(vim.fn.readfile(dir .. "/procs.json"), "\n")
      or nil
    vim.fn.delete(dir, "rf")
    if not text then
      return nil,
        ("app-proc-watch wrote no result (exit %s): %s"):format(tostring(exit_code), why())
    end
    -- PowerShell writes UTF-8 with a byte order mark
    local decoded, result = pcall(vim.json.decode, (text:gsub("^\239\187\191", "")))
    if not decoded then
      return nil, "app-proc-watch wrote no JSON: " .. tostring(result)
    end
    return M.judge(result), nil
  end

  function W.stop()
    if done then
      return
    end
    done = true
    finish()
    vim.fn.delete(dir, "rf")
  end

  return W, nil
end

return M
