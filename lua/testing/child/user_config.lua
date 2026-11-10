---@module 'testing.child.user_config'
-- @cache-env CI TESTING_USER_CONFIG TESTING_USER_DATA HOME USERPROFILE LOCALAPPDATA XDG_CONFIG_HOME XDG_DATA_HOME
---@brief A child editor on the user's installed config, read only (`config = "user"` of a test sheet).
---@description
--- The child keeps its sandbox (state, cache, the rest of data and config, temp) and gets the real config on top:
---
--- * `stdpath('config')` is a link in the sandbox config folder to the user's config (`NVIM_APPNAME` of the child is
---   its folder name): on the runtimepath with its `after/`, its `init.lua` (or `init.vim`) is the init of the child.
---   `XDG_CONFIG_HOME` stays the sandbox's, so what other tools write there (lazygit, gh) stays in it.
--- * The plugins are the installed ones: `lazy`, `lazy-rocks`, `site/pack`, the parsers and queries of `site/` and
---   the installed tools of mason (`packages`, `bin`, `share`, `opt`) in the sandbox data folder are links to the
---   user's (a junction on Windows); mason's `registries` is a copy (mason refreshes it on a start whose cache does
---   not know the last refresh, and the cache is the sandbox's).
--- * The environment is the caller's (the variables a config reads: `REPOS_DIR`, `NVIM_MACHINE_ROLE`, ...), not the
---   allow-list of a spec's child; only what points at the calling editor stays out (`NVIM`, `NVIM_LISTEN_ADDRESS`),
---   and the harness sets `NVIM_APPNAME` and `NVIM_LOG_FILE`. The determinism of every child holds (`TZ=UTC`, a C
---   locale).
--- * Read only for lazy.nvim's start: `require("lazy")` gets lazy.nvim with a `setup` that turns off installing missing
---   plugins, the checker and the change detection, and writes its lock file to a copy in the sandbox. The runtimepath
---   keeps testing.nvim and lib.nvim, also when lazy.nvim resets it (behind the plugins: a config that loads its own
---   lib.nvim sees that one).
--- * Where it is: `$TESTING_USER_CONFIG` / `$TESTING_USER_DATA`, else the default places of the platform. On CI
---   (`CI` set, not `0` or `false`) and without an `init.lua`/`init.vim` the sheet is a skip with the reason.
---
--- The links point into the user's folders. What fetches something MISSING by itself (a tree-sitter parser of
--- `ensure_installed`, a tool of mason) writes there, as the user's own editor would; so does a step that runs
--- `:Lazy sync`, `update`, `clean` or `build`, and a config that installs another way (a plugin manager of its own,
--- a `git pull` in its init).

local M = {}

M.CONFIG_ENV = "TESTING_USER_CONFIG"
M.DATA_ENV = "TESTING_USER_DATA"
---The folders of the user's data folder the child sees through links (relative to it).
M.LINKS = {
  "lazy",
  "lazy-rocks",
  "site/pack",
  "site/parser",
  "site/parser-info",
  "site/queries",
  "mason/packages",
  "mason/bin",
  "mason/share",
  "mason/opt",
}
---The folders of the user's data folder the child gets a copy of: they are written on a plain start.
M.COPIES = { "mason/registries" }

---@class Testing.UserConfig
---@field config string The user's config folder.
---@field data string The user's data folder (where the plugins are).
---@field init string Its `init.lua` or `init.vim`.

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(p), ":p")):gsub("/+$", ""))
end

---@param p string
---@return boolean
local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

---Where the user's config and data are, or why a sheet on it does not run here.
---@param getenv? fun(name: string): string|nil
---@param is_windows? boolean
---@return Testing.UserConfig|nil, string|nil why
function M.locate(getenv, is_windows)
  getenv = getenv or os.getenv
  if is_windows == nil then
    is_windows = require("testing.platform").is_windows()
  end
  local function env(name)
    local v = getenv(name)
    return (v ~= nil and v ~= "") and v or nil
  end
  if require("testing.run.fast").in_ci(env("CI") or "") then
    return nil, 'on CI a sheet never reads a user\'s config (config = "user")'
  end
  local config, data = env(M.CONFIG_ENV), env(M.DATA_ENV)
  local home = env("HOME") or env("USERPROFILE")
  if is_windows then
    local local_app = env("LOCALAPPDATA") or (home and (home .. "/AppData/Local"))
    config = config or (local_app and (local_app .. "/nvim"))
    data = data or (local_app and (local_app .. "/nvim-data"))
  else
    local xdg_config = env("XDG_CONFIG_HOME") or (home and (home .. "/.config"))
    local xdg_data = env("XDG_DATA_HOME") or (home and (home .. "/.local/share"))
    config = config or (xdg_config and (xdg_config .. "/nvim"))
    data = data or (xdg_data and (xdg_data .. "/nvim"))
  end
  if not config or not data then
    return nil, ("no user config: set %s and %s"):format(M.CONFIG_ENV, M.DATA_ENV)
  end
  -- absolute: a junction needs an absolute target, and the child runs in the project root
  config, data = norm(config), norm(data)
  for _, name in ipairs({ "init.lua", "init.vim" }) do
    if is_file(config .. "/" .. name) then
      return { config = config, data = data, init = config .. "/" .. name }
    end
  end
  return nil,
    ("no user config at %s (no init.lua or init.vim; %s names another)"):format(
      config,
      M.CONFIG_ENV
    )
end

---The data folder the child's `stdpath('data')` is in its sandbox: `NVIM_APPNAME` below `XDG_DATA_HOME`, with
---`-data` on Windows.
---@param sandbox_data string The sandbox's `XDG_DATA_HOME`.
---@param appname string
---@param is_windows boolean
---@return string
function M.child_data(sandbox_data, appname, is_windows)
  return (vim.fs.normalize(sandbox_data):gsub("/+$", ""))
    .. "/"
    .. appname
    .. (is_windows and "-data" or "")
end

-- The init of the child: the runtimepath of the config, the read-only lazy.nvim, then the user's init.
local WRAPPER = [=[
-- written by testing.child.user_config: the user's config, read only
local cfg = vim.json.decode(%q)
vim.opt.rtp:prepend(cfg.site)
vim.opt.packpath:prepend(cfg.site)
vim.opt.rtp:prepend(cfg.config)
vim.opt.rtp:append(cfg.config .. "/after")
-- lazy.nvim's switches, set on whatever form `setup` is called with (lazy's own rule: a first table with `spec` IS the
-- options, the second argument is not read)
local function read_only(mod)
  if type(mod) ~= "table" or type(mod.setup) ~= "function" or mod.__testing_read_only then
    return mod
  end
  local setup = mod.setup
  mod.setup = function(spec, opts)
    local as_opts = type(spec) == "table" and spec.spec ~= nil
    local o = as_opts and spec or (opts or {})
    o.install = vim.tbl_extend("force", o.install or {}, { missing = false })
    o.checker = vim.tbl_extend("force", o.checker or {}, { enabled = false })
    o.change_detection = vim.tbl_extend("force", o.change_detection or {}, { enabled = false })
    o.lockfile = cfg.lockfile
    o.performance = o.performance or {}
    o.performance.rtp = o.performance.rtp or {}
    local paths = vim.list_extend({}, o.performance.rtp.paths or {})
    o.performance.rtp.paths = vim.list_extend(paths, cfg.keep)
    if as_opts then
      return setup(o)
    end
    return setup(spec, o)
  end
  mod.__testing_read_only = true
  return mod
end
-- A searcher in front of the others, not a preload: a preload that cannot find lazy.nvim yet (a bootstrap's
-- `pcall(require, "lazy")` before it is on the runtimepath) would have to raise, and a raising loader leaves require's
-- mark behind ("loop or previous error"). This one says nothing then, and require says "not found" as always.
local function searcher(name)
  if name ~= "lazy" then
    return nil
  end
  for _, other in ipairs(package.loaders) do
    if other ~= searcher then
      local loader = other(name)
      if type(loader) == "function" then
        return function(...)
          return read_only(loader(...))
        end
      end
    end
  end
  return nil
end
table.insert(package.loaders, 1, searcher)
if cfg.init:match("%%.vim$") then
  vim.cmd.source(vim.fn.fnameescape(cfg.init))
else
  dofile(cfg.init)
end
]=]

---A link to a folder (a junction on Windows), unless there is one already (a sandbox that is kept).
---@param real string
---@param link string
---@return boolean ok, string|nil err
local function link_dir(real, link)
  local ok, err = require("lib.nvim.fs.mkdirp")(vim.fs.dirname(link))
  if not ok then
    return false, ("cannot create %s: %s"):format(vim.fs.dirname(link), tostring(err))
  end
  if vim.uv.fs_lstat(link) then
    return true
  end
  local made, lerr = vim.uv.fs_symlink(real, link, { dir = true, junction = true })
  if not made then
    return false, ("cannot link %s to %s: %s"):format(link, real, tostring(lerr))
  end
  return true
end

---Copy a folder, unless the copy is there already.
---@param from string
---@param to string
---@return boolean ok, string|nil err
local function copy_dir(from, to)
  if vim.uv.fs_stat(to) then
    return true
  end
  local mkdirp = require("lib.nvim.fs.mkdirp")
  local ok, err = mkdirp(to)
  if not ok then
    return false, ("cannot create %s: %s"):format(to, tostring(err))
  end
  for name, kind in vim.fs.dir(from, { depth = 50 }) do
    local src, dst = from .. "/" .. name, to .. "/" .. name
    if kind == "directory" then
      ok, err = mkdirp(dst)
    elseif kind == "file" then
      ok, err = vim.uv.fs_copyfile(src, dst)
    end
    if not ok then
      return false, ("cannot copy %s: %s"):format(src, tostring(err))
    end
  end
  return true
end

---Make the sandbox of a child ready for the user's config: the links, the copies and the init.
---@param user Testing.UserConfig
---@param sandbox string The child's sandbox folder.
---@param dirs { config: string, data: string } Its `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.
---@param keep string[] Folders that stay on the runtimepath (testing.nvim, lib.nvim).
---@param is_windows boolean
---@return { init: string, env: table<string, string> }|nil, string|nil err
function M.prepare(user, sandbox, dirs, keep, is_windows)
  local appname = vim.fs.basename(user.config)
  -- stdpath('config') is `<sandbox config>/<appname>`: a link to the user's config
  local config = (vim.fs.normalize(dirs.config):gsub("/+$", "")) .. "/" .. appname
  local ok, err = link_dir(user.config, config)
  if not ok then
    return nil, err
  end
  local data = M.child_data(dirs.data, appname, is_windows)
  for _, rel in ipairs(M.LINKS) do
    local real = user.data .. "/" .. rel
    local st = vim.uv.fs_stat(real)
    if st and st.type == "directory" then
      ok, err = link_dir(real, data .. "/" .. rel)
      if not ok then
        return nil, err
      end
    end
  end
  for _, rel in ipairs(M.COPIES) do
    local real = user.data .. "/" .. rel
    local st = vim.uv.fs_stat(real)
    if st and st.type == "directory" then
      ok, err = copy_dir(real, data .. "/" .. rel)
      if not ok then
        return nil, err
      end
    end
  end
  local site = data .. "/site"
  ok, err = require("lib.nvim.fs.mkdirp")(site)
  if not ok then
    return nil, ("cannot create %s: %s"):format(site, tostring(err))
  end
  -- lazy.nvim writes its lock file to a copy: the user's stays as it is
  local lockfile = sandbox .. "/lazy-lock.json"
  local real_lock = user.config .. "/lazy-lock.json"
  if is_file(real_lock) and not is_file(lockfile) then
    local copied, cerr = vim.uv.fs_copyfile(real_lock, lockfile)
    if not copied then
      return nil, ("cannot copy %s: %s"):format(real_lock, tostring(cerr))
    end
  end
  local init = sandbox .. "/user_init.lua"
  local text = WRAPPER:format(vim.json.encode({
    config = config,
    init = config .. "/" .. vim.fs.basename(user.init),
    site = site,
    lockfile = lockfile,
    keep = keep,
  }))
  local f, oerr = io.open(init, "wb")
  if not f then
    return nil, ("cannot write %s: %s"):format(init, tostring(oerr))
  end
  f:write(text)
  f:close()
  return { init = init, env = { NVIM_APPNAME = appname } }
end

return M
