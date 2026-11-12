-- @cache-env TESTING_* PLAYWRIGHT_BROWSERS_PATH LOCALAPPDATA HOME
---@module 'testing.tier3'
---@brief The tools of tier 2.5 and tier 3 (PTY capture, browser, WebDriver) and where they are found.
---@description
--- Pure lookup, no process is started: a tool is found through an environment override (an absolute
--- path), then `PATH`. The Playwright browsers are found in `PLAYWRIGHT_BROWSERS_PATH` or the default
--- cache of the system. A tool that is missing is not a defect of the machine: the cases that need it
--- are reported skips, and `:checkhealth testing` says which tool is missing on purpose.
---
--- The environment, the executable lookup and the directory listing can be injected for specs.

local M = {}

---@class Testing.Tier3.Row
---@field name string
---@field tier string
---@field env string Name of the override variable.
---@field purpose string
---@field path? string Where it was found.
---@field via? string Label of the place that matched.

---@type { name: string, tier: string, env: string, purpose: string, exe: string }[]
local TOOLS = {
  {
    name = "node",
    tier = "3",
    env = "TESTING_NODE",
    purpose = "runs the Playwright specs",
    exe = "node",
  },
  {
    name = "tauri-driver",
    tier = "3",
    env = "TESTING_TAURI_DRIVER",
    purpose = "WebDriver for the Tauri windows (tasks-desktop, docmap-desktop)",
    exe = "tauri-driver",
  },
  {
    name = "msedgedriver",
    tier = "3",
    env = "TESTING_MSEDGEDRIVER",
    purpose = "WebDriver of WebView2 (its version must match the installed WebView2)",
    exe = "msedgedriver",
  },
  {
    name = "wsl",
    tier = "2.5",
    env = "TESTING_WSL",
    purpose = "tmux and PTY capture of the raw terminal byte stream",
    exe = "wsl",
  },
}

---@class Testing.Tier3.Opts
---@field getenv? fun(name: string): string|nil
---@field which? fun(exe: string): string|nil
---@field is_file? fun(path: string): boolean
---@field list_dir? fun(path: string): string[]
---@field home? string

---@param opts Testing.Tier3.Opts|nil
---@return Testing.Tier3.Opts
local function defaults(opts)
  opts = opts or {}
  local uv = vim.uv or vim.loop
  return {
    getenv = opts.getenv or function(name)
      local value = uv.os_getenv(name)
      return value ~= "" and value or nil
    end,
    which = opts.which or function(exe)
      local path = vim.fn.exepath(exe)
      return path ~= "" and path or nil
    end,
    is_file = opts.is_file or function(path)
      local stat = uv.fs_stat(path)
      return stat ~= nil and stat.type == "file"
    end,
    list_dir = opts.list_dir or function(path)
      local names = {}
      local handle = uv.fs_scandir(path)
      while handle do
        local name = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        names[#names + 1] = name
      end
      return names
    end,
    home = opts.home,
  }
end

---The tools of tier 2.5 and 3, found or not.
---@param opts Testing.Tier3.Opts|nil
---@return Testing.Tier3.Row[]
function M.tools(opts)
  local o = defaults(opts)
  local rows = {}
  for _, tool in ipairs(TOOLS) do
    local row = { name = tool.name, tier = tool.tier, env = tool.env, purpose = tool.purpose }
    local override = o.getenv(tool.env)
    if override and o.is_file(override) then
      row.path, row.via = override, "$" .. tool.env
    else
      local found = o.which(tool.exe)
      if found then
        row.path, row.via = found, "PATH"
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

---The folder that holds the Playwright browsers: `PLAYWRIGHT_BROWSERS_PATH`, else the cache of the system.
---@param opts Testing.Tier3.Opts|nil
---@return string|nil
function M.browsers_dir(opts)
  local o = defaults(opts)
  local set = o.getenv("PLAYWRIGHT_BROWSERS_PATH")
  if set and set ~= "0" then
    return set
  end
  local localapp = o.getenv("LOCALAPPDATA")
  if localapp then
    return localapp .. "/ms-playwright"
  end
  local home = o.home or o.getenv("HOME")
  if home then
    return home .. "/.cache/ms-playwright"
  end
  return nil
end

---The installed Playwright browsers by engine (`chromium`, `firefox`, `webkit`), each with its revisions.
---@param opts Testing.Tier3.Opts|nil
---@return table<string, string[]>
function M.browsers(opts)
  local o = defaults(opts)
  local dir = M.browsers_dir(opts)
  local found = {}
  if not dir then
    return found
  end
  for _, name in ipairs(o.list_dir(dir)) do
    local engine, rev = name:match("^([%a_]+)%-(%d+)$")
    if engine == "chromium_headless_shell" then
      engine = "chromium"
    end
    if engine == "chromium" or engine == "firefox" or engine == "webkit" then
      found[engine] = found[engine] or {}
      table.insert(found[engine], rev)
    end
  end
  for _, revs in pairs(found) do
    table.sort(revs)
  end
  return found
end

---@class Testing.Tier3.ContainerOpts
---@field run? fun(argv: string[]): Testing.Container.Result The engine call (specs inject it).
---@field timeout_ms? integer Deadline of the engine call (default 5000).

---tmux for the PTY capture (`testing.pty`) where it runs directly (Linux, macOS). On Windows it is looked up
---inside WSL when a case starts, which needs a process: nil there.
---@param opts Testing.Tier3.Opts|nil
---@param is_windows? boolean Default: this system.
---@return string|nil path, boolean applies
function M.tmux(opts, is_windows)
  if is_windows == nil then
    is_windows = vim.fn.has("win32") == 1
  end
  if is_windows then
    return nil, false
  end
  return defaults(opts).which("tmux"), true
end

---The container engine and the image of the container cases (`testing.container`): is it usable? Unlike the
---lookups above this asks the engine (`podman image exists`), with a short deadline: a stopped Podman machine must
---not hold up `:checkhealth`.
---@param opts? Testing.Tier3.ContainerOpts
---@return boolean ok
---@return string reason The image when ok, else what is missing.
function M.container(opts)
  opts = opts or {}
  return require("testing.container").available({
    run = opts.run,
    timeout_ms = opts.timeout_ms or 5000,
  })
end

return M
