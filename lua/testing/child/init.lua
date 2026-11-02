---@module 'testing.child'
-- @cache-allow env
---@brief Driver of ONE child editor that runs ONE spec file: argv, sandbox, environment, start, hard kill.
---@description
--- `testing.child` is the process half of per-file isolation (concept D.3 / D.9, `host = "c"|"l"`).
--- The pool that runs many children and merges what they report is `testing.run.isolated`; the code
--- that runs inside the child is `testing.child.boot`.
---
--- WHAT A CHILD IS
---   nvim -n -i NONE --headless -u NORC -c "lua ...dofile(boot)"      host "c" (the default)
---   nvim -n -i NONE --headless -u NORC -l <boot.lua>                 host "l"
---
---   `-u NORC`: no init file, but the editor's own runtime plugins load (netrw, matchit, ...) as
---   they do under plenary's `-u minimal_init` and under `--clean`; `-u NONE` would leave a spec
---   that calls `:Explore` or relies on `filetype plugin indent on` alone with a different editor.
---
---   * started with an argv LIST by `vim.uv.spawn` (never a shell string: SEC-01) and an explicit working
---     directory, the project root (SEC-02). `lib.nvim.system.job` has no `cwd`/`env`/`kill` options,
---     and `vim.system` only completes when the pipes reach end-of-file (an orphan of the spec can
---     hold them for ever), so this is the one place that talks to libuv directly: the child is done
---     when its PROCESS ended plus a short drain (`DRAIN_MS`);
---   * host `c` starts the way plenary's `PlenaryBustedFile` host does: the spec runs from a `-c`
---     command, so `v:vim_did_enter` is 0, `expand('<cword>')` and `expand('<cfile>')` work and a
---     buffer context exists. Host `l` is `nvim -l` (`vim_did_enter` is 1, no buffer context). The
---     command line is CONSTANT: the variable parts travel in `$TESTING_CHILD_JOB` (a JSON file) and
---     `$TESTING_CHILD_BOOT`, so no user text is ever parsed as a command;
---   * stdin is the null device: a spec that asks a question never blocks the run (`boot` also
---     answers `input()`/`inputlist()`/`confirm()` with "cancelled");
---   * the environment is an allowlist (`testing.child.env`) plus the determinism variables (`LANG`/`LC_ALL=C.UTF-8`, `TZ=UTC`, opt out with `deterministic = false`) plus the sandbox: `XDG_*` and the temp
---     variables point into one directory below the parent's temp dir, so `stdpath('data'|'state'|
---     'cache'|'config')` and `tempname()` of a spec never touch the user's real ones. The sandbox
---     is deleted when the child is done. `HOME`/`USERPROFILE` stay the user's (git needs the
---     identity) unless `isolate_home` (`--isolate-home`) points them into the sandbox too;
---   * the run's dependencies are on the child's runtimepath (`rtp`, `rtp_prepend` of the job).
---
--- KILLING. A timeout kills the whole process TREE: a spec that spawned helpers (language servers,
--- `nvim --headless` workers) must not leave them behind. Windows: the process table is read first
--- (one `powershell.exe` call, constant argv), then `taskkill /PID <pid> /T /F` (its exit code is
--- checked: a failure kills the root at once), then every descendant of the snapshot is ended by pid
--- (a double-hop orphan, whose parent died before the snapshot, escapes: see README.md "Killing"). POSIX: the child is started
--- detached (own process group); the root is frozen (SIGSTOP), its descendants are read from one
--- `ps` call, the group and every descendant get SIGKILL (a `jobstart`ed helper has a process group of
--- its own, the group kill alone would miss it). If the OS call fails the root is killed
--- directly. A parent that is itself killed cannot clean up after itself (documented limit).
--- A grandchild a spec left behind AFTER the child ended normally is killed on POSIX (the process
--- group outlives its leader); on Windows it is not (no job objects from Lua; documented limit), but
--- it can no longer delay the run or turn a green file into a timeout. A process that is still there
--- `REAP_MS` after the kill is abandoned (`abandon`): reported as ended, never waited for again.

local env_mod = require("testing.child.env")

local M = {}

local is_windows = require("testing.platform").is_windows()

---The platform switch of the kill path (a spec flips it to drive the Windows branch from anywhere).
M.platform = { windows = is_windows }

---Directory of this checkout's boot file.
---@return string
function M.boot_path()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.normalize(here)) .. "/boot.lua"
end

---Constant `-c` command of host `c`: runs the boot file named by `$TESTING_CHILD_BOOT`; a raise
---before the boot's own error handling ends the child with exit code 4 instead of leaving the editor
---waiting for input.
---@type string
M.HOST_C_COMMAND =
  "lua local ok, e = pcall(dofile, vim.env.TESTING_CHILD_BOOT); if not ok then io.stderr:write('testing child: ' .. tostring(e) .. '\\n'); os.exit(4) end"

---@class Testing.Child.Timeouts
---@field case_ms? integer
---@field file_ms? integer

---@class Testing.Child.Spec
---@field entry table The discovered file (`path`, `rel`, `dialect`, ...); serialized into the job.
---@field root string Project root: the working directory and the base of `entry.rel`.
---@field kind? "cases"|"script"|"list" Default "cases"; "list" only lists the cases of the file (`testing.child.runner.list`).
---@field host? "c"|"l" Default "c".
---@field rtp_prepend? string[] Directories put first on the child's runtimepath.
---@field rtp? string[] Directories appended to the child's runtimepath.
---@field filetype? boolean `filetype plugin indent on` (default true).
---@field disable_first_run? boolean Set lib.nvim's first-run opt-out in the child before `minit` (default true).
---@field minit? string Absolute path of the project's minimal init, run in the child before the spec.
---@field assertions? "error"|"warn" What a case without assertions is (`testing.policy`).
---@field selector? { filter?: string[], tags?: string[], exclude_tags?: string[] }
---@field lf_ids? string[] `--lf`: the only case ids of this file that may run.
---@field timeouts? Testing.Child.Timeouts Soft (in-child) timeouts.
---@field seed? integer
---@field script_args? string[]
---@field env_allow? string[] Extra environment names (see `testing.child.env`).
---@field extra_env? table<string, string> Variables the driver sets itself (the `$<NAME>_DIR` of the resolved dependencies: a spec that starts an editor of its own finds them too).
---@field parent_env? table<string, string> Replaces `vim.fn.environ()` (specs).
---@field nvim? string Executable (default `vim.v.progpath`).
---@field base? string Directory below which the sandbox is created (default: the parent's temp dir).
---@field name? string Sandbox directory name (default unique).
---@field deterministic? boolean `LANG`/`LC_ALL=C.UTF-8` and `TZ=UTC` are set (default true; `false`: the parent's are passed on).
---@field isolate_home? boolean `HOME`/`USERPROFILE`/`APPDATA`/`LOCALAPPDATA` point into the sandbox, `HOMEDRIVE`/`HOMEPATH` are removed (default false: the user's home, git needs the identity).
---@field guard? table Configuration of the guard layer (`testing.run.options.guard_config`, JSON-safe): installed in the child for the file (`testing.child.runner`). Nil: no guards.
---@field trace? boolean A child that times out or dies leaves a trace artifact (default true; the parent writes it, the job only carries the choice).

---@class Testing.Child.Plan
---@field argv string[]
---@field cwd string
---@field env table<string, string>
---@field dropped_env string[] Names of the parent environment that were not passed on.
---@field sandbox string Absolute directory that holds everything of this child.
---@field dirs table<string, string> Sandbox sub-directories (`config`, `data`, `state`, `cache`, `run`, `tmp`).
---@field job_file string
---@field fragment string
---@field job table The job table (what `job_file` will contain).
---@field host "c"|"l"
---@field detached boolean POSIX: started as a process-group leader (killed as a group).

local seq = 0

---@param s string
---@return string
local function native(s)
  if is_windows then
    return (s:gsub("/", "\\"))
  end
  return s
end

---Parent's temp directory: the dirname of `tempname()`. It is the parent's own (and is removed with
---it); the IR's `<TMP>` placeholder is that same directory, so sandbox paths in a message are
---normalized like any other temp path.
---@return string
local function parent_tmp()
  return (vim.fs.normalize(vim.fs.dirname(vim.fn.tempname())):gsub("/+$", ""))
end

---The long form of an existing directory on Windows. The parent's `TEMP` there is often the 8.3 short
---form (`C:\Users\STEFAN~1\...`), and `vim.fn.glob()` finds nothing below a path with a short-name
---component, so a sandbox (`TEMP`/`TMP`/`TMPDIR`/XDG) built from it breaks every spec that globs below
---`tempname()`. `fs_realpath` returns the on-disk long name. POSIX keeps the spelling it was given: a
---symlinked temp dir does not break `glob`, and resolving it (macOS `/var` -> `/private/var`) would
---only move the sandbox. A directory that does not exist (yet) is returned unchanged.
---@param dir string
---@return string
local function long_form(dir)
  if not is_windows then
    return dir
  end
  local real = vim.uv.fs_realpath(dir)
  if type(real) ~= "string" or real == "" then
    return dir
  end
  return (real:gsub("\\", "/"):gsub("/+$", ""))
end

---@class Testing.Child.Environment
---@field env table<string, string>
---@field dropped_env string[]
---@field sandbox string
---@field dirs table<string, string>

---The sandbox directory, the sanitized environment, the determinism variables and the sandbox
---variables of a child (shared by the per-file child and the RPC driver `testing.rpc`). Pure apart
---from reading the environment and a counter: nothing is created.
---@param spec { parent_env?: table<string, string>, env_allow?: string[], extra_env?: table<string, string>, deterministic?: boolean, isolate_home?: boolean, base?: string, name?: string }
---@return Testing.Child.Environment
function M.environment(spec)
  seq = seq + 1
  local base = long_form(spec.base or parent_tmp())
  local name = spec.name or ("testing-child-%d-%d"):format(vim.fn.getpid(), seq)
  local sandbox = (base:gsub("\\", "/"):gsub("/+$", "")) .. "/" .. name
  local dirs, sandbox_vars, drop =
    env_mod.sandbox_env(sandbox, { isolate_home = spec.isolate_home == true })

  local clean = env_mod.sanitize(spec.parent_env or vim.fn.environ(), { allow = spec.env_allow })
  local env = clean.env
  if spec.deterministic ~= false then
    env_mod.apply_determinism(env)
  end
  -- `isolate_home`: the parts of the real home that would name it again are removed (any spelling)
  for _, key in ipairs(drop) do
    for existing in pairs(env) do
      if existing:upper() == key then
        env[existing] = nil
      end
    end
  end
  -- the sandbox variables replace whatever case the parent spelled them in (`Temp` vs `TEMP`)
  for key, value in pairs(sandbox_vars) do
    for existing in pairs(env) do
      if existing:upper() == key then
        env[existing] = nil
      end
    end
    env[key] = native(value)
  end

  for key, value in pairs(spec.extra_env or {}) do
    env[key] = native(value)
  end
  return { env = env, dropped_env = clean.dropped, sandbox = sandbox, dirs = dirs }
end

---The job of a file: what the child's runner reads (`testing.child.boot`, `testing.child.pool_boot`).
---Pure: nothing is written.
---@param spec Testing.Child.Spec
---@param fragment string Where the result records go.
---@param minit? string
---@return table job
function M.job(spec, fragment, minit)
  return {
    version = 1,
    kind = spec.kind or "cases",
    entry = spec.entry,
    root = spec.root,
    rtp_prepend = spec.rtp_prepend or {},
    rtp = spec.rtp or {},
    filetype = spec.filetype ~= false,
    minit = minit,
    disable_first_run = spec.disable_first_run ~= false,
    assertions = spec.assertions,
    fragment = fragment,
    selector = spec.selector or {},
    lf_ids = spec.lf_ids,
    timeouts = spec.timeouts or {},
    seed = spec.seed,
    script_args = spec.script_args,
    -- the guard layer's configuration (`testing.run.options.guard_config`): `testing.child.runner` installs it
    guard = spec.guard,
    trace = spec.trace ~= false,
  }
end

---Build the plan of a child. Pure apart from reading the environment and a counter: nothing is
---created and nothing is started, so a spec can inspect the argv, the environment and the job.
---@param spec Testing.Child.Spec
---@return Testing.Child.Plan
function M.build(spec)
  local host = spec.host or "c"
  assert(host == "c" or host == "l", "testing.child: host must be 'c' or 'l'")
  local e = M.environment(spec)
  local env, sandbox, dirs = e.env, e.sandbox, e.dirs
  local clean = { dropped = e.dropped_env }

  local job_file = sandbox .. "/job.json"
  local fragment = sandbox .. "/result.ndjson"
  local boot = M.boot_path()
  env.TESTING_CHILD_JOB = native(job_file)
  local argv = { spec.nvim or vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NORC" }
  if host == "c" then
    env.TESTING_CHILD_BOOT = native(boot)
    vim.list_extend(argv, { "-c", M.HOST_C_COMMAND })
  else
    vim.list_extend(argv, { "-l", native(boot) })
  end

  local job = M.job(spec, fragment, spec.minit)
  return {
    argv = argv,
    cwd = native(spec.root),
    env = env,
    dropped_env = clean.dropped,
    sandbox = sandbox,
    dirs = dirs,
    job_file = job_file,
    fragment = fragment,
    job = job,
    host = host,
    detached = not is_windows,
  }
end

---Create the sandbox directories and write the job file.
---@param plan Testing.Child.Plan
---@return boolean ok
---@return string|nil err
function M.prepare(plan)
  local mkdirp = require("lib.nvim.fs.mkdirp")
  for _, dir in pairs(plan.dirs) do
    local ok, err = mkdirp(dir)
    if not ok then
      return false, ("cannot create %s: %s"):format(dir, tostring(err))
    end
  end
  local text, err = require("lib.nvim.json").encode(plan.job)
  if not text then
    return false, "cannot encode the job: " .. tostring(err)
  end
  local f, oerr = io.open(plan.job_file, "wb")
  if not f then
    return false, ("cannot write %s: %s"):format(plan.job_file, tostring(oerr))
  end
  f:write(text)
  f:close()
  return true, nil
end

---Remove the sandbox of a child. Refuses anything that is not a `testing-child-*` directory
---directly below the parent's temp dir or the `base` it was built with.
---@param plan Testing.Child.Plan
---@return boolean removed
function M.cleanup(plan)
  local name = plan.sandbox:match("([^/]+)$") or ""
  if not name:match("^testing%-child%-") then
    return false
  end
  if vim.fn.isdirectory(plan.sandbox) ~= 1 then
    return true
  end
  return vim.fn.delete(plan.sandbox, "rf") == 0
end

---@class Testing.Child.Buffer
---@field chunks (string|false)[] The live chunks are `chunks[first .. #chunks]`; a slot before `first` is `false` (dropped).
---@field first integer Index of the oldest live chunk (the read cursor: dropping from the front must not shift the array).
---@field bytes integer
---@field truncated boolean Older output was dropped (the cap).

---@class Testing.Child.Handle
---@field plan Testing.Child.Plan
---@field uv_handle? uv.uv_process_t The process handle (nil once closed).
---@field pid integer
---@field started_ms number Monotonic clock at the start.
---@field exited boolean The child is finished (process ended and drained, or abandoned).
---@field ended? boolean The process itself ended (the pipes may still be drained).
---@field abandoned? boolean The process did not end after the kill; the pool stopped waiting.
---@field finish? fun() Internal: completes the handle once.
---@field exit? { code?: integer, signal?: integer } Set when the process ended (`{}` when abandoned).
---@field kill_requested_ms? number
---@field kill_pending? boolean `kill_tree_async` booked the kill and has not carried it out yet (a waiting kill then still takes the whole tree).
---@field first_kill_ms? number Monotonic ms of the FIRST kill request (the pool's upper bound counts from it).
---@field reason? "file"|"stall"|"cancel" Why the pool killed it (set by the supervisor).
---@field deadline? number Monotonic ms of the hard file deadline.
---@field stall_limit? number ms without a new record that count as a stuck case (busted).
---@field progress_ms? number Monotonic ms of the last new record.
---@field frag_size? integer Size of the fragment at `progress_ms`.
---@field frag_scanned? integer Bytes of the fragment the supervisor already scanned for the end of the file.
---@field out Testing.Child.Buffer Everything the child printed (stdout and stderr, arrival order).
---@field stdout Testing.Child.Buffer What it wrote to stdout.
---@field err Testing.Child.Buffer What it wrote to stderr.
---@field stdin? uv.uv_pipe_t RPC mode only: the write end of the child's stdin (closed when the handle is finished).

---Cap of the captured output per stream and child (bytes); the newest output is kept.
M.OUTPUT_CAP = 256 * 1024

---Dead slots at the front of `chunks` before they are compacted away (a smaller buffer is not worth the move).
local COMPACT_MIN = 64

---An empty capture buffer.
---@return Testing.Child.Buffer
function M.new_buffer()
  return { chunks = {}, first = 1, bytes = 0, truncated = false }
end

---Append a chunk the child wrote and drop the OLDEST chunks until the buffer is within `OUTPUT_CAP`
---(a single chunk is never dropped). A pipe read can hand over a few bytes at a time, so the number of
---chunks is not bounded by the cap: dropping from the front must not shift the array (`table.remove(chunks, 1)` moved
---every live chunk for every dropped one, 349 s for 1.5 MB written one byte at a time). The read cursor `first`
---moves instead, and the array is compacted once the dead front is at least as long as the live part (amortized O(1)).
---@param buf Testing.Child.Buffer
---@param chunk string
function M.keep(buf, chunk)
  local chunks = buf.chunks
  local last = #chunks + 1
  chunks[last] = chunk
  buf.bytes = buf.bytes + #chunk
  local first = buf.first
  local cap = M.OUTPUT_CAP
  while buf.bytes > cap and first < last do
    buf.bytes = buf.bytes - #(chunks[first] or "")
    chunks[first] = false -- not nil: `#chunks` must keep counting the dead slots
    first = first + 1
    buf.truncated = true
  end
  if first > COMPACT_MIN and first * 2 > last then
    local live = last - first + 1
    for i = 1, live do
      chunks[i] = chunks[first + i - 1]
    end
    for i = live + 1, last do
      chunks[i] = nil
    end
    first = 1
  end
  buf.first = first
end

---The captured text of a buffer (CRLF folded to LF).
---@param buf Testing.Child.Buffer
---@return string
function M.text(buf)
  return (
    table.concat(buf.chunks --[[@as string[] ]], "", buf.first or 1, #buf.chunks):gsub("\r\n", "\n")
  )
end

---Children that are running, by pid; the editor quitting kills what is left (`VimLeavePre`).
---@type table<integer, Testing.Child.Handle>
local live = {}
local leave_hooked = false

---Kill the process trees of all children that are still running.
function M.kill_all()
  local all = {}
  for _, h in pairs(live) do
    all[#all + 1] = h
  end
  M.kill_trees(all)
end

local function hook_leave()
  if leave_hooked then
    return
  end
  leave_hooked = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("TestingChildReaper", { clear = true }),
    callback = function()
      M.kill_all()
    end,
  })
end

---Remove the `VimLeavePre` reaper when no child is left to reap: a spec that runs real children
---in-process must not leave an autocmd behind (the state guard names it), and an idle editor needs
---none. The next `spawn` hooks it again.
local function unhook_leave()
  if leave_hooked and next(live) == nil then
    leave_hooked = false
    pcall(vim.api.nvim_del_augroup_by_name, "TestingChildReaper")
  end
end

---How long after the PROCESS ended the pipes are still read (ms). A spec that left a grandchild
---behind (a language server, a `start /b` helper) leaves it holding the inherited ends of the pipes:
---waiting for end-of-file would wait for that orphan, not for the child.
M.DRAIN_MS = 200

---@class Testing.Child.SpawnOpts
---@field on_stdout? fun(data: string) RPC mode: stdout is a binary stream handed to this function (called in a libuv callback, fast context: no `vim.api`), stdin is a pipe (`h.stdin`) instead of the null device, and stdout is not buffered.

---Start a prepared child. The child is finished when its PROCESS has exited (plus a short drain of
---what is still in the pipes), never when the pipes reach end-of-file (`vim.system` waits for that,
---which an orphan can delay for ever).
---@param plan Testing.Child.Plan
---@param on_exit fun(h: Testing.Child.Handle) Called ON THE MAIN LOOP (scheduled) when the process ended.
---@param popts? Testing.Child.SpawnOpts
---@return Testing.Child.Handle|nil handle
---@return string|nil err
function M.spawn(plan, on_exit, popts)
  popts = popts or {}
  local uv = vim.uv
  ---@diagnostic disable-next-line: missing-fields
  local h = {
    plan = plan,
    pid = 0,
    started_ms = uv.hrtime() / 1e6,
    exited = false,
    out = M.new_buffer(),
    stdout = M.new_buffer(),
    err = M.new_buffer(),
  } --[[@as Testing.Child.Handle]]

  local out_pipe, err_pipe = uv.new_pipe(false), uv.new_pipe(false)
  local in_pipe = popts.on_stdout and uv.new_pipe(false) or nil
  h.stdin = in_pipe
  if not out_pipe or not err_pipe or (popts.on_stdout and not in_pipe) then
    if in_pipe then
      in_pipe:close()
    end
    if out_pipe then
      out_pipe:close()
    end
    if err_pipe then
      err_pipe:close()
    end
    return nil, "cannot create the pipes of the child"
  end
  local env = {}
  for name, value in pairs(plan.env) do
    env[#env + 1] = name .. "=" .. value
  end
  table.sort(env)
  local args = vim.list_slice(plan.argv, 2)

  local finished = false
  local timer
  local eof = 0
  local function close(handle)
    if handle and not handle:is_closing() then
      handle:close()
    end
  end
  ---Runs once: the pipes are closed (the orphan's writes now fail, they do not block it), the handle
  ---is `exited` and the owner is told on the main loop.
  local function finish()
    if finished then
      return
    end
    finished = true
    close(timer)
    close(out_pipe)
    close(err_pipe)
    close(in_pipe)
    h.exited = true
    if h.ended then
      live[h.pid] = nil
    end
    vim.schedule(function()
      on_exit(h)
      unhook_leave()
    end)
  end
  h.finish = finish

  ---@diagnostic disable-next-line: missing-fields -- uid/gid/verbatim are optional in libuv; the type stub lists them as required
  local handle, pid = uv.spawn(plan.argv[1], {
    args = args,
    cwd = plan.cwd,
    env = env,
    stdio = { in_pipe, out_pipe, err_pipe },
    detached = plan.detached,
    hide = true,
  }, function(code, signal)
    h.ended = true
    h.exit = { code = code, signal = signal }
    live[h.pid] = nil
    close(h.uv_handle)
    if not is_windows then
      -- what the child left in its process group (the group outlives its leader)
      pcall(uv.kill, -h.pid, "sigkill")
    end
    if eof >= 2 then
      finish()
      return
    end
    timer = uv.new_timer()
    if timer then
      timer:start(M.DRAIN_MS, 0, finish)
    else
      finish()
    end
  end)
  if not handle then
    close(out_pipe)
    close(err_pipe)
    close(in_pipe)
    return nil, ("cannot start %s: %s"):format(tostring(plan.argv[1]), tostring(pid))
  end
  h.uv_handle = handle
  h.pid = pid
  live[h.pid] = h
  hook_leave()

  ---@param pipe uv.uv_pipe_t
  ---@param sinks Testing.Child.Buffer[]
  ---@param stream? fun(data: string)
  local function read(pipe, sinks, stream)
    pipe:read_start(function(_, data)
      if data then
        if stream then
          stream(data)
        end
        for _, sink in ipairs(sinks) do
          M.keep(sink, data)
        end
      else
        eof = eof + 1
        if not pipe:is_closing() then
          pipe:read_stop()
        end
        if h.ended and eof >= 2 then
          finish() -- everything the child wrote has arrived: no need to wait out the drain
        end
      end
    end)
  end
  if popts.on_stdout then
    read(out_pipe, {}, popts.on_stdout)
  else
    read(out_pipe, { h.out, h.stdout })
  end
  read(err_pipe, { h.err, h.out })
  return h, nil
end

---Give up on a child whose process did not end after the kill: it is reported as ended (its exit
---is unknown) so that one stubborn process can never keep a run waiting.
---@param h Testing.Child.Handle
function M.abandon(h)
  if h.exited then
    return
  end
  h.abandoned = true
  h.exit = h.exit or {}
  if h.finish then
    h.finish()
  else
    h.exited = true
  end
end

---The command that prints one `<pid> <ppid> <created>` line for every process (`created`: milliseconds since the epoch,
---Windows only). Constant argv, no shell, no user text. Windows has no `ps`: one PowerShell call (about a second,
---`wmic` is gone from current Windows), used on the timeout path only.
---@return string[]
local function process_table_argv()
  if M.platform.windows then
    return {
      "powershell.exe",
      "-NoProfile",
      "-NonInteractive",
      "-NoLogo",
      "-Command",
      "Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,CreationDate"
        .. " | ForEach-Object { '{0} {1} {2}' -f $_.ProcessId,$_.ParentProcessId,"
        .. "$(if ($_.CreationDate) { ([DateTimeOffset]$_.CreationDate).ToUnixTimeMilliseconds() } else { 0 }) }",
    }
  end
  return { "ps", "-A", "-o", "pid=", "-o", "ppid=" }
end

---@class Testing.Child.Proc
---@field ppid integer
---@field created integer Creation time (milliseconds since the epoch); 0 when the table does not say (POSIX).

---@alias Testing.Child.Exec fun(argv: string[], ms: integer, cb: fun(res: table|nil))

---Run `fn` outside a guard that is installed (the processes started here are the driver's, not the spec's).
---@param fn fun(): any
---@return any
local function unguarded(fn)
  local guard = package.loaded["testing.guard"]
  if type(guard) == "table" and guard.suspended then
    return guard.suspended(fn)
  end
  return fn()
end

---Synchronous execution: waits for the answer (`nil` when the command could not run or did not answer in time).
---@type Testing.Child.Exec
local function exec_sync(argv, ms, cb)
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait(ms)
  end)
  cb(ok and type(res) == "table" and res or nil)
end

---Asynchronous execution: returns at once, `cb` runs on the main loop (scheduled) with the answer.
---@type Testing.Child.Exec
local function exec_async(argv, ms, cb)
  local started = pcall(unguarded, function()
    return vim.system(argv, { text = true, timeout = ms }, function(res)
      vim.schedule(function()
        cb(res)
      end)
    end)
  end)
  if not started then
    vim.schedule(function()
      cb(nil)
    end)
  end
end

---The process table: pid -> parent and creation time, through `exec`. `cb(nil)` when it cannot be read.
---@param exec Testing.Child.Exec
---@param cb fun(procs: table<integer, Testing.Child.Proc>|nil)
local function read_table(exec, cb)
  exec(process_table_argv(), M.platform.windows and 8000 or 3000, function(res)
    if type(res) ~= "table" or res.code ~= 0 or type(res.stdout) ~= "string" then
      return cb(nil)
    end
    local procs = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
      local p, pp, created = line:match("^%s*(%d+)%s+(%d+)%s*(%d*)%s*$")
      if p and pp then
        procs[tonumber(p)] = { ppid = tonumber(pp) or 0, created = tonumber(created) or 0 }
      end
    end
    cb(procs)
  end)
end

---Everything below `pid` in a process table (children, grandchildren, ...) whatever the process group.
---The parent id of a process can name a process that has ended and whose number went to a new one, so an edge counts
---only when the child is not older than its parent (where both creation times are known).
---@param procs table<integer, Testing.Child.Proc>
---@param pid integer
---@return { pid: integer, created: integer }[]
local function below_of(procs, pid)
  local kids = {}
  for p, e in pairs(procs) do
    local list = kids[e.ppid] or {}
    kids[e.ppid] = list
    list[#list + 1] = p
  end
  for _, list in pairs(kids) do
    table.sort(list)
  end
  local out, queue, seen = {}, { pid }, { [pid] = true }
  while #queue > 0 do
    local cur = table.remove(queue)
    local born = procs[cur] and procs[cur].created or 0
    for _, k in ipairs(kids[cur] or {}) do
      local created = procs[k].created
      if not seen[k] and (born == 0 or created == 0 or created >= born) then
        seen[k] = true
        out[#out + 1] = { pid = k, created = created }
        queue[#queue + 1] = k
      end
    end
  end
  return out
end

---@param h Testing.Child.Handle
local function root_kill(h)
  if h.uv_handle and not h.uv_handle:is_closing() then
    pcall(vim.uv.process_kill, h.uv_handle, 9)
  end
end

---The kill of the trees of `hs` (handles whose tree is to be taken now), ONE process table for all of them.
---`exec` and `pause` decide whether it waits (the sync path: the editor is quitting, or the caller needs the result)
---or goes on in callbacks (the supervisor of a run must not stand still for the seconds a Windows snapshot takes).
---  POSIX: every root is frozen (SIGSTOP) so it cannot start anything while the table is read, then each tree gets
---  SIGKILL (the group, and every descendant that is in a group of its own).
---  Windows: the table is read first (a descendant whose parent dies with the root would be invisible to `/T`), ONE
---  `taskkill /T` takes the trees. What `/T` could not reach is still there: a process that has ended is not looked
---  at again, a number is handed out again soon after its process ended, so a survivor is ended only when a fresh
---  table names the same process (same creation time), and all of them in ONE call.
---@param hs Testing.Child.Handle[]
---@param exec Testing.Child.Exec
---@param pause fun(ms: integer, cb: fun())
---@param done fun()
local function kill_trees(hs, exec, pause, done)
  if M.platform.windows then
    read_table(exec, function(procs)
      local below = {}
      for _, h in ipairs(hs) do
        below[h] = procs and below_of(procs, h.pid) or {}
      end
      local argv = { "taskkill" }
      for _, h in ipairs(hs) do
        argv[#argv + 1] = "/PID"
        argv[#argv + 1] = tostring(h.pid)
      end
      argv[#argv + 1] = "/T"
      argv[#argv + 1] = "/F"
      exec(argv, 5000, function(res)
        if type(res) ~= "table" or res.code ~= 0 then
          -- access denied, no such process, a timeout: do not wait for a later call
          for _, h in ipairs(hs) do
            root_kill(h)
          end
        end
        local left = {}
        for _, h in ipairs(hs) do
          for _, d in ipairs(below[h]) do
            if M.alive(d.pid) then
              left[#left + 1] = d
            end
          end
        end
        if #left == 0 then
          return done()
        end
        -- (a process that /T ended can read as alive for a few milliseconds more)
        pause(50, function()
          left = vim.tbl_filter(function(d)
            return M.alive(d.pid)
          end, left)
          if #left == 0 then
            return done()
          end
          read_table(exec, function(now)
            local kill_argv = { "taskkill", "/F" }
            for _, d in ipairs(left) do
              local cur = now and now[d.pid]
              if cur and cur.created == d.created then
                kill_argv[#kill_argv + 1] = "/PID"
                kill_argv[#kill_argv + 1] = tostring(d.pid)
              end
            end
            if #kill_argv > 2 then
              return exec(kill_argv, 5000, function()
                done()
              end)
            end
            done()
          end)
        end)
      end)
    end)
    return
  end
  for _, h in ipairs(hs) do
    pcall(vim.uv.kill, h.pid, "sigstop")
  end
  read_table(exec, function(procs)
    for _, h in ipairs(hs) do
      local below = procs and below_of(procs, h.pid) or {}
      if not pcall(vim.uv.kill, -h.pid, "sigkill") then
        root_kill(h)
      end
      for _, d in ipairs(below) do
        pcall(vim.uv.kill, d.pid, "sigkill")
      end
      root_kill(h)
    end
    done()
  end)
end

---Book the kill request of a handle. Returns whether the tree has to be taken now: false when the handle has ended
---(an abandoned one is not: it can still be killed when the editor quits) or, on Windows, when this is not the first
---request (the tree is gone; only the root is killed again).
---@param h Testing.Child.Handle
---@return boolean full
local function book(h)
  if h.ended then
    return false
  end
  -- a request that `kill_tree_async` booked but has not carried out yet (`kill_pending`) is still the first one: if the
  -- editor quits now, its callbacks never run, and the waiting kill has to take the tree
  local first = h.kill_requested_ms == nil or h.kill_pending == true
  h.kill_requested_ms = h.kill_requested_ms or (vim.uv.hrtime() / 1e6)
  if M.platform.windows and not first then
    root_kill(h)
    return false
  end
  return true
end

---Kill the process trees of `hs` and wait: ONE process table for all of them. For the paths that cannot go on
---without the result (the editor quitting, a pool shut down). Idempotent; never raises. The processes this starts
---(`powershell` for the process table, `taskkill`) are the driver's, not the spec's: when a guard is installed (a
---spec that drives an RPC child inside a guarded case) they run outside it.
---@param hs Testing.Child.Handle[]
function M.kill_trees(hs)
  unguarded(function()
    local full = {}
    for _, h in ipairs(hs) do
      if book(h) then
        full[#full + 1] = h
      end
    end
    if #full == 0 then
      return
    end
    kill_trees(full, exec_sync, function(ms, cb)
      vim.wait(ms)
      cb()
    end, function() end)
  end)
end

---Kill the process tree of a child and wait (see the module header). Idempotent; never raises.
---@param h Testing.Child.Handle
function M.kill_tree(h)
  M.kill_trees({ h })
end

---@type Testing.Child.Handle[]
local queued = {}
local flushing = false

local function flush()
  local batch = queued
  queued = {}
  local finished = false
  local function finish()
    if finished then
      return
    end
    finished = true
    for _, h in ipairs(batch) do
      h.kill_pending = nil
    end
    if #queued > 0 then
      return flush()
    end
    flushing = false
  end
  -- an error in any step must neither leave the queue stuck (no later kill would ever run) nor leave a frozen root
  -- (POSIX: SIGSTOP was sent): the roots are killed directly and the queue goes on
  local function fail()
    for _, h in ipairs(batch) do
      root_kill(h)
    end
    finish()
  end
  ---@param cb function
  ---@return function
  local function guarded(cb)
    return function(...)
      local ok = pcall(cb, ...)
      if not ok then
        fail()
      end
    end
  end
  local ok = pcall(kill_trees, batch, function(argv, ms, cb)
    exec_async(argv, ms, guarded(cb))
  end, function(ms, cb)
    vim.defer_fn(guarded(cb), ms)
  end, finish)
  if not ok then
    fail()
  end
end

---Kill the process tree of a child WITHOUT waiting: the request is booked at once (`kill_requested_ms`), the table
---and the kills go on in callbacks, and every request of the same tick (or made while a kill is going on) shares ONE
---process table. For the supervisor of a run, which must keep watching the other children meanwhile. Idempotent;
---never raises. The editor quitting needs `kill_tree` / `kill_trees`: callbacks do not run then.
---@param h Testing.Child.Handle
function M.kill_tree_async(h)
  if h.kill_pending then
    -- the tree is being taken: the root once more is all a repeated request adds
    if not h.ended then
      root_kill(h)
    end
    return
  end
  if not book(h) then
    return
  end
  h.kill_pending = true
  for _, q in ipairs(queued) do
    if q == h then
      return
    end
  end
  queued[#queued + 1] = h
  if not flushing then
    flushing = true
    vim.schedule(flush)
  end
end

---Does a process exist? (`kill(pid, 0)`: no signal is sent.)
---@param pid integer
---@return boolean
function M.alive(pid)
  local r, _, name = vim.uv.kill(pid, 0)
  return r == 0 or name == "EPERM"
end

---Names of signals worth naming in a crash message.
local SIGNALS = {
  [1] = "SIGHUP",
  [2] = "SIGINT",
  [3] = "SIGQUIT",
  [4] = "SIGILL",
  [6] = "SIGABRT",
  [7] = "SIGBUS",
  [8] = "SIGFPE",
  [9] = "SIGKILL",
  [11] = "SIGSEGV",
  [13] = "SIGPIPE",
  [15] = "SIGTERM",
}

---Describe how a process ended, for a crash message.
---@param exit { code?: integer, signal?: integer }
---@return string
function M.describe_exit(exit)
  local parts = { ("exit code %d"):format(exit.code or -1) }
  if exit.signal and exit.signal ~= 0 then
    parts[#parts + 1] = ("signal %d (%s)"):format(exit.signal, SIGNALS[exit.signal] or "?")
  elseif exit.code and exit.code >= 128 and exit.code < 160 and not is_windows then
    parts[#parts + 1] = ("= 128 + signal %d (%s)"):format(
      exit.code - 128,
      SIGNALS[exit.code - 128] or "?"
    )
  elseif exit.code and exit.code >= 0xC0000000 then
    parts[#parts + 1] = ("= NTSTATUS 0x%08X"):format(exit.code)
  end
  return table.concat(parts, ", ")
end

return M
