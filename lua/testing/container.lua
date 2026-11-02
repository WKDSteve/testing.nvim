-- @cache-env TESTING_CONTAINER_ENGINE TESTING_CONTAINER_IMAGE
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
---@field timeout_ms? integer Per call (default 120000).
---@field mounts? table<string, string> Host path -> container path, mounted read-only.
---@field env? table<string, string> Environment of the command.

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

---@param opts Testing.Container.Opts
---@return fun(argv: string[]): Testing.Container.Result
local function runner(opts)
  if opts.run then
    return opts.run
  end
  return function(argv)
    local ok, proc = pcall(vim.system, argv, { text = true })
    if not ok then
      return { code = 127, stdout = "", stderr = tostring(proc) }
    end
    local done = proc:wait(opts.timeout_ms or 120000)
    return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end
end

---Is the engine up and the image built?
---@param opts? Testing.Container.Opts
---@return boolean ok, string reason
function M.available(opts)
  opts = opts or {}
  local res = runner(opts)({ engine(opts), "image", "exists", image(opts) })
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
  return false, engine(opts) .. " is not usable (is its machine running?)"
end

---The argument vector of a one-shot run.
---@param command string[]
---@param opts? Testing.Container.Opts
---@return string[]
function M.argv(command, opts)
  opts = opts or {}
  local argv = { engine(opts), "run", "--rm", "--network", "none" }
  local hosts = vim.tbl_keys(opts.mounts or {})
  table.sort(hosts)
  for _, host in ipairs(hosts) do
    vim.list_extend(argv, { "-v", ("%s:%s:ro"):format(host, opts.mounts[host]) })
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

---Run `command` in a fresh container (no network, mounts read-only).
---@param command string[]
---@param opts? Testing.Container.Opts
---@return Testing.Container.Result
function M.run(command, opts)
  opts = opts or {}
  return runner(opts)(M.argv(command, opts))
end

return M
