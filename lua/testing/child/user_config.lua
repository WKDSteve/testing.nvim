---@module 'testing.child.user_config'
-- @cache-env CI TESTING_USER_CONFIG TESTING_USER_DATA
---@brief A child editor on the user's installed config, read only (`config = "user"` of a test sheet).
---@description
--- The child keeps its sandbox (state, cache, the rest of data, temp) and gets the real config on top:
---
--- * `stdpath('config')` is the user's config (`XDG_CONFIG_HOME` + `NVIM_APPNAME` of the child), on the
---   runtimepath with its `after/`; its `init.lua` (or `init.vim`) is the init of the child.
--- * The plugins are the installed ones: `lazy`, `lazy-rocks`, `site/pack`, the parsers and queries of `site/` and
---   `mason` of the sandbox data folder are links to the user's (a junction on Windows), so the init finds lazy.nvim,
---   the tree-sitter parsers and the installed tools where it looks for them and downloads nothing.
--- * The environment is the caller's (the variables a config reads, `REPOS_DIR` and the like), not the allow-list of a
---   spec's child; `NVIM*` stays out, the sandbox variables win.
--- * Read only: `require("lazy")` gets lazy.nvim with a `setup` that turns off installing missing plugins, the
---   checker and the change detection, and writes its lock file to a copy in the sandbox. What a plugin writes below
---   `stdpath('data')`, `stdpath('state')` or `stdpath('cache')` stays in the sandbox. The runtimepath keeps
---   testing.nvim and lib.nvim, also when lazy.nvim resets it.
--- * Where it is: `$TESTING_USER_CONFIG` / `$TESTING_USER_DATA`, else the default places of the platform. On CI
---   (`CI` set) and without an `init.lua`/`init.vim` there the sheet is a skip with the reason, never green.
---
--- The links point into the user's folders: only lazy.nvim's switches keep them unchanged. A plugin that fetches what
--- is MISSING by itself (a tree-sitter parser of `ensure_installed`, a tool of mason) writes there through the link,
--- as the user's own editor would; a config that installs or updates another way (a plugin manager of its own, a
--- `git pull` in its init) is not stopped either.

local M = {}

M.CONFIG_ENV = "TESTING_USER_CONFIG"
M.DATA_ENV = "TESTING_USER_DATA"
---The folders of the user's data folder the child sees through links (relative to it).
M.LINKS =
  { "lazy", "lazy-rocks", "site/pack", "site/parser", "site/parser-info", "site/queries", "mason" }

---@class Testing.UserConfig
---@field config string The user's config folder (`stdpath('config')` of the child).
---@field data string The user's data folder (where the plugins are).
---@field init string Its `init.lua` or `init.vim`.

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(p):gsub("/+$", ""))
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
  local ci = env("CI")
  if ci and ci ~= "0" and ci:lower() ~= "false" then
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
  return norm(sandbox_data) .. "/" .. appname .. (is_windows and "-data" or "")
end

-- The init of the child: the runtimepath of the config, the read-only lazy.nvim, then the user's init.
local WRAPPER = [=[
-- written by testing.child.user_config: the user's config, read only
local cfg = vim.json.decode(%q)
vim.opt.rtp:prepend(cfg.site)
vim.opt.packpath:prepend(cfg.site)
vim.opt.rtp:prepend(cfg.config)
vim.opt.rtp:append(cfg.config .. "/after")
package.preload["lazy"] = function(name)
  package.preload[name] = nil
  local mod
  for i = 2, #package.loaders do
    local loader = package.loaders[i](name)
    if type(loader) == "function" then
      mod = loader(name)
      break
    end
  end
  if type(mod) ~= "table" or type(mod.setup) ~= "function" then
    return mod
  end
  local setup = mod.setup
  mod.setup = function(spec, opts)
    -- `setup(opts)` with `opts.spec` and `setup(spec, opts)`
    local as_opts = opts == nil and type(spec) == "table" and spec.spec ~= nil
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
  package.loaded[name] = mod
  return mod
end
if cfg.init:match("%%.vim$") then
  vim.cmd.source(vim.fn.fnameescape(cfg.init))
else
  dofile(cfg.init)
end
]=]

---Make the sandbox of a child ready for the user's config: the links, the copy of the lock file and the init.
---@param user Testing.UserConfig
---@param sandbox string The child's sandbox folder.
---@param sandbox_data string Its `XDG_DATA_HOME`.
---@param keep string[] Folders that stay on the runtimepath (testing.nvim, lib.nvim).
---@param is_windows boolean
---@return { init: string, env: table<string, string> }|nil, string|nil err
function M.prepare(user, sandbox, sandbox_data, keep, is_windows)
  local mkdirp = require("lib.nvim.fs.mkdirp")
  local appname = vim.fs.basename(user.config)
  local data = M.child_data(sandbox_data, appname, is_windows)
  for _, rel in ipairs(M.LINKS) do
    local real = user.data .. "/" .. rel
    local st = vim.uv.fs_stat(real)
    if st and st.type == "directory" then
      local link = data .. "/" .. rel
      local ok, err = mkdirp(vim.fs.dirname(link))
      if not ok then
        return nil, ("cannot create %s: %s"):format(vim.fs.dirname(link), tostring(err))
      end
      if not vim.uv.fs_lstat(link) then
        local made, lerr = vim.uv.fs_symlink(real, link, { dir = true, junction = true })
        if not made then
          return nil, ("cannot link %s to %s: %s"):format(link, real, tostring(lerr))
        end
      end
    end
  end
  local site = data .. "/site"
  local ok, err = mkdirp(site)
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
    config = user.config,
    init = user.init,
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
  return {
    init = init,
    env = {
      XDG_CONFIG_HOME = vim.fs.dirname(user.config),
      NVIM_APPNAME = appname,
    },
  }
end

return M
