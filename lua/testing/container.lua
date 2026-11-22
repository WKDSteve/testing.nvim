-- @cache-env TESTING_CONTAINER_ENGINE TESTING_CONTAINER_IMAGE TESTING_OUTER_*
---@module 'testing.container'
---@brief Linux checks in a container: a one-shot `podman run` of a command, the repositories mounted read-only.
---@description
--- `run()` starts `<engine> run --rm <image> <command...>` and returns the exit code and both output streams. The
--- image is `containers/linux/Containerfile` of this repository (`build()`; Neovim, `gio`, `trash-cli`, `xdg-utils`,
--- pinned fonts). A spec that needs it asks `available()` first and prints `n/a  <reason>` when the engine, its
--- machine or the image is missing (a reported skip). Every call is an argument vector, never a shell string; the
--- engine is `$TESTING_CONTAINER_ENGINE` (default `podman`), the image tag `$TESTING_CONTAINER_IMAGE`.

local M = {}

---@class Testing.Container.Result
---@field code integer
---@field stdout string
---@field stderr string

---@class Testing.Container.Opts
---@field engine? string `podman` (default) or `docker`.
---@field image? string Image tag (default `localhost/testing-linux:1`).
---@field run? fun(argv: string[]): Testing.Container.Result Injectable runner for specs.
---@field run_async? fun(argv: string[], cb: fun(res: Testing.Container.Result)) Injectable async runner for `probe_async`.
---@field timeout_ms? integer Per call (default 120000).
---@field mounts? table<string, string> Host path -> container path, mounted read-only.
---@field writable? table<string, string> Host path -> container path, mounted read-write (an output folder).
---@field env? table<string, string> Environment of the command.
---@field network? boolean true: the container has the network (default: `--network none`).
---@field name? string `--name` of the container (it is removed when it ends: `--rm`).
---@field user? string `--user` (default: the image's).
---@field userns? string Podman's `--userns` (`keep-id`: the user of this machine is the user in the container, not root;
---an output folder of this machine stays writable). Ignored for docker, which has no such mode.
---@field passwd_entry? string Podman's `--passwd-entry`: the line of /etc/passwd for that user (its name and HOME;
---`$UID` and `$GID` are filled in by Podman). Ignored for docker.
---@field init? boolean `--init`: a small init is PID 1 and reaps the orphans, as launchd or systemd do on a host (a
---suite that kills a process tree and checks that nothing is left needs it).
---@field workdir? string `--workdir` (default: the image's).
---@field stop_after_s? integer Podman's `--timeout`: the engine ends the container after this long, also when the client
---that started it is gone.

M.default_image = "localhost/testing-linux:1"

---@param opts Testing.Container.Opts
---@return string
local function engine(opts)
  return opts.engine or vim.uv.os_getenv("TESTING_CONTAINER_ENGINE") or "podman"
end

---@param opts Testing.Container.Opts
---@return string
local function image(opts)
  return opts.image or vim.uv.os_getenv("TESTING_CONTAINER_IMAGE") or M.default_image
end

---The environment the engine runs with: inside a child of the runner the sandbox variables (`XDG_DATA_HOME`,
---`XDG_RUNTIME_DIR`, `TMPDIR`, ...) get the values they had outside back (`TESTING_OUTER_*`, testing.child.env); an
---empty one stays empty, which the engine reads as unset. Rootless podman keeps its images below `XDG_DATA_HOME` and its
---runtime below `XDG_RUNTIME_DIR`: with the sandbox's, the image built before the suite is not there and the engine has
---no runtime. nil outside a child (nothing to give back): the engine inherits the environment as it is. Every name is
---read literally (the cache key sees each one; a read of the whole environment would leave this module without a key).
---@param getenv? fun(name: string): string? Default `os.getenv`.
---@return table<string, string>? env Merged into the engine's environment.
function M.engine_env(getenv)
  getenv = getenv or os.getenv
  local outer = {
    XDG_CONFIG_HOME = getenv("TESTING_OUTER_XDG_CONFIG_HOME"),
    XDG_DATA_HOME = getenv("TESTING_OUTER_XDG_DATA_HOME"),
    XDG_STATE_HOME = getenv("TESTING_OUTER_XDG_STATE_HOME"),
    XDG_CACHE_HOME = getenv("TESTING_OUTER_XDG_CACHE_HOME"),
    XDG_RUNTIME_DIR = getenv("TESTING_OUTER_XDG_RUNTIME_DIR"),
    TEMP = getenv("TESTING_OUTER_TEMP"),
    TMP = getenv("TESTING_OUTER_TMP"),
    TMPDIR = getenv("TESTING_OUTER_TMPDIR"),
  }
  if next(outer) == nil then
    return nil
  end
  return outer
end

---@param opts Testing.Container.Opts
---@return fun(argv: string[]): Testing.Container.Result
local function runner(opts)
  if opts.run then
    return opts.run
  end
  return function(argv)
    local env = M.engine_env()
    local ok, proc = pcall(vim.system, argv, { text = true, env = env })
    if not ok then
      return { code = 127, stdout = "", stderr = tostring(proc) }
    end
    ---@cast proc vim.SystemObj
    local done = proc:wait(opts.timeout_ms or 120000)
    return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end
end

---The argument vector of the question "is the image there?" (`image exists` is podman's; docker answers the same
---question with `image inspect`).
---@param opts Testing.Container.Opts
---@return string[]
local function probe_argv(opts)
  local probe = engine(opts):match("docker[^/]*$") and { "image", "inspect" }
    or { "image", "exists" }
  return { engine(opts), probe[1], probe[2], image(opts) }
end

---The answer of the engine to the probe, as `available` reports it.
---@param res Testing.Container.Result
---@param opts Testing.Container.Opts
---@return boolean ok, string reason
local function classify(res, opts)
  if res.code == 0 then
    return true, image(opts)
  end
  if res.code == 127 then
    return false, engine(opts) .. " is not installed"
  end
  if res.code == 1 and res.stderr == "" then
    return false,
      ("image %s is not built (`testing container build`, or `podman build` in containers/linux)"):format(
        image(opts)
      )
  end
  -- the engine's own words: "is its machine running?" alone hid a Linux engine that ran with the wrong environment
  local said = vim.trim(res.stderr or ""):match("^[^\n]*") or ""
  return false,
    ("%s is not usable (is its machine running?): exit %d%s"):format(
      engine(opts),
      res.code,
      said ~= "" and (", " .. said:sub(1, 200)) or ""
    )
end

---Is the engine up and the image built? Blocks until the engine answers (a CI run, a spec); an editor command must
---use `probe_async` / `cached` instead.
---@param opts? Testing.Container.Opts
---@return boolean ok, string reason
function M.available(opts)
  opts = opts or {}
  return classify(runner(opts)(probe_argv(opts)), opts)
end

---@type table<string, {ok: boolean, reason: string}>
local answers = {}
---@type table<string, boolean>
local asking = {}

---@param opts Testing.Container.Opts
---@return string
local function answer_key(opts)
  return engine(opts) .. " " .. image(opts)
end

---The answer of this session for this engine and image, nil when none was asked yet. Never starts a process.
---@param opts? Testing.Container.Opts
---@return boolean|nil ok, string|nil reason
function M.cached(opts)
  local got = answers[answer_key(opts or {})]
  if got then
    return got.ok, got.reason
  end
end

---Forget the answers of this session (the image was built since, or a spec).
---@return nil
function M.forget()
  answers = {}
end

---Ask the engine without blocking the editor: the probe runs through `vim.system` with a callback; the answer is kept
---for the session (`cached`) and handed to `done` on the main loop. A probe already under way is not started twice
---(its asker gets the answer through `cached` later). `opts.run_async(argv, cb)` stands in for the process in specs.
---@param opts? Testing.Container.Opts
---@param done? fun(ok: boolean, reason: string)
---@return nil
function M.probe_async(opts, done)
  opts = opts or {}
  local key = answer_key(opts)
  if answers[key] then
    if done then
      done(answers[key].ok, answers[key].reason)
    end
    return
  end
  if asking[key] then
    return
  end
  asking[key] = true
  local function finish(res)
    asking[key] = nil
    local ok, reason = classify(res, opts)
    answers[key] = { ok = ok, reason = reason }
    if done then
      done(ok, reason)
    end
  end
  if opts.run_async then
    opts.run_async(probe_argv(opts), finish)
    return
  end
  local started, err = pcall(
    vim.system,
    probe_argv(opts),
    {
      text = true,
      env = M.engine_env(),
      timeout = opts.timeout_ms or 120000,
    },
    vim.schedule_wrap(function(done_res)
      finish({
        code = done_res.code,
        stdout = done_res.stdout or "",
        stderr = done_res.stderr or "",
      })
    end)
  )
  if not started then
    finish({ code = 127, stdout = "", stderr = tostring(err) })
  end
end

---The argument vector of a one-shot run.
---@param command string[]
---@param opts? Testing.Container.Opts
---@return string[]
function M.argv(command, opts)
  opts = opts or {}
  local argv = { engine(opts), "run", "--rm" }
  if opts.network ~= true then
    vim.list_extend(argv, { "--network", "none" })
  end
  if opts.name then
    vim.list_extend(argv, { "--name", opts.name })
  end
  if opts.user then
    vim.list_extend(argv, { "--user", opts.user })
  end
  if opts.userns and not engine(opts):match("docker[^/]*$") then
    vim.list_extend(argv, { "--userns", opts.userns })
  end
  if opts.passwd_entry and not engine(opts):match("docker[^/]*$") then
    vim.list_extend(argv, { "--passwd-entry", opts.passwd_entry })
  end
  if opts.init then
    argv[#argv + 1] = "--init"
  end
  if opts.workdir then
    vim.list_extend(argv, { "--workdir", opts.workdir })
  end
  -- docker has no such option: its containers end with the client only through `--rm` and the kill of the client
  if opts.stop_after_s and not engine(opts):match("docker[^/]*$") then
    vim.list_extend(argv, { "--timeout", tostring(opts.stop_after_s) })
  end
  for _, kind in ipairs({ { opts.mounts, "ro" }, { opts.writable, "rw" } }) do
    local map = kind[1] or {}
    local hosts = vim.tbl_keys(map)
    table.sort(hosts)
    for _, host in ipairs(hosts) do
      vim.list_extend(argv, { "-v", ("%s:%s:%s"):format(host, map[host], kind[2]) })
    end
  end
  local names = vim.tbl_keys(opts.env or {})
  table.sort(names)
  for _, name in ipairs(names) do
    vim.list_extend(argv, { "-e", ("%s=%s"):format(name, opts.env[name]) })
  end
  argv[#argv + 1] = image(opts)
  vim.list_extend(argv, command)
  return argv
end

---The id (digest) of the image: what a proof of a run in it names. Nil and why when it cannot be asked.
---@param opts? Testing.Container.Opts
---@return string|nil id, string|nil why
function M.digest(opts)
  opts = opts or {}
  local res = runner(opts)({ engine(opts), "image", "inspect", "--format", "{{.Id}}", image(opts) })
  local id = res.code == 0 and vim.trim(res.stdout or ""):match("^[%w:]+$") or nil
  if not id or id == "" then
    return nil, ("%s image inspect %s: exit %d"):format(engine(opts), image(opts), res.code)
  end
  return id
end

---Build an image from a Dockerfile (`<engine> build --tag <tag> --file <file> <context>`; a build may use the
---network). Exit code and output as `run`.
---@param tag string
---@param file string
---@param context string
---@param opts? Testing.Container.Opts
---@return Testing.Container.Result
function M.build(tag, file, context, opts)
  opts = vim.tbl_extend("force", { timeout_ms = 30 * 60 * 1000 }, opts or {})
  return runner(opts)({ engine(opts), "build", "--tag", tag, "--file", file, context })
end

---Remove a container of this name that an earlier run left when it ended (a crash between `run` and `--rm`). Only a
---name the caller made itself (`testing-ci-<repo>-<target>`); a container that is not there is no error, and a running
---one stays (another run of the same repository) unless `force`: the caller's own container, whose client gave up.
---@param name string
---@param opts? Testing.Container.Opts
---@param force? boolean
function M.remove(name, opts, force)
  opts = opts or {}
  local argv = { engine(opts), "rm", "--ignore", name }
  if force then
    table.insert(argv, 3, "--force")
  end
  runner(opts)(argv)
end

---Run `command` in a fresh container (no network, mounts read-only).
---@param command string[]
---@param opts? Testing.Container.Opts
---@return Testing.Container.Result
function M.run(command, opts)
  opts = opts or {}
  return runner(opts)(M.argv(command, opts))
end

return M
