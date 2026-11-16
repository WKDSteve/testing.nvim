---@module 'testing.sheet.native_host'
---@brief A native messaging host for one browser sheet run: registered before Chromium starts, gone after the run.
---@description
--- A browser sheet with an unpacked `extension` can name a program of the project as the extension's native messaging
--- host (`native_host = { name, path }`), so the extension talks to a host from this build without an installed app.
--- The runner (`browser_runner.mjs`) writes the host's manifest (the extension's id from the `key` of its manifest) and
--- registers it: on Windows under `HKCU\Software\Chromium\NativeMessagingHosts\<name>`, which Playwright's Chromium reads
--- before `Software\Google\Chrome` (measured 2026-11-16, Chromium 156), so an installed app's host under Chrome's key is
--- neither touched nor used; on Linux and macOS in `<profile>/NativeMessagingHosts`, no registry at all.
---
--- Here: before the run, a key of that name under Chromium's key that is not of an earlier run of this engine refuses
--- the run (red, the key is left alone); one an earlier run left behind (it crashed) is removed. After the run, however
--- it ended, the key is removed when it still points into this run's folder.

local M = {}

---Where Chromium looks for hosts of the user on Windows.
M.KEY = [[HKCU\Software\Chromium\NativeMessagingHosts]]
---A part of the folder of each run: a registered manifest below such a folder is one this engine wrote.
M.MARK = "testing-native-host"

---The rule of Chromium for a host's name: dot-separated parts of lower-case letters, digits and `_`.
---@param name any
---@return boolean
function M.valid_name(name)
  if type(name) ~= "string" or name == "" or #name > 200 then
    return false
  end
  for part in (name .. "."):gmatch("([^.]*)%.") do
    if not part:match("^[a-z0-9_]+$") then
      return false
    end
  end
  return true
end

---@param v any The `native_host` of a sheet.
---@return string|nil err
function M.check(v)
  if type(v) ~= "table" then
    return "native_host must be a table { name = ..., path = ... }"
  end
  for k in pairs(v) do
    if k ~= "name" and k ~= "path" and k ~= "env" then
      return ("native_host: unknown field %s (name, path and env)"):format(tostring(k))
    end
  end
  if v.env ~= nil then
    if type(v.env) ~= "table" then
      return "native_host.env must be a table { NAME = value }"
    end
    for k, val in pairs(v.env) do
      if type(k) ~= "string" or not k:match("^[%a_][%w_]*$") or k:upper():match("^NVIM") then
        return ("native_host.env: %s is no variable name (letters, digits, _; not NVIM*)"):format(
          tostring(k)
        )
      end
      if type(val) ~= "string" or val:find("%c") then
        return ("native_host.env.%s must be text without control characters"):format(k)
      end
    end
  end
  if not M.valid_name(v.name) then
    return "native_host.name: dot-separated parts of a-z, 0-9 and _ (Chromium's rule for a host)"
  end
  local p = v.path
  if
    type(p) ~= "string"
    or p == ""
    or p:match("^[/\\]")
    or p:match("^%a:")
    or p:find("%c")
    -- a part that is two dots; a pattern, not the literal, which the cache key would read as a path outside
    or ("/" .. p:gsub("\\", "/") .. "/"):find("/%.%./")
  then
    return "native_host.path: the host program, relative to the project root (no '..', not absolute)"
  end
  return nil
end

---@alias Testing.Sheet.RegRun fun(args: string[]): { code: integer, stdout: string }

---@type Testing.Sheet.RegRun
local function reg_exe(args)
  local ok, done = pcall(function()
    return vim.system(vim.list_extend({ "reg" }, args), { text = true }):wait(10000)
  end)
  if not ok then
    return { code = -1, stdout = "" }
  end
  return { code = done.code or -1, stdout = done.stdout or "" }
end

---The manifest a host of this name is registered with under Chromium's key, nil without one.
---@param name string
---@param run? Testing.Sheet.RegRun
---@return string|nil
function M.registered(name, run)
  local res = (run or reg_exe)({ "query", M.KEY .. "\\" .. name, "/ve" })
  if res.code ~= 0 then
    return nil
  end
  -- "    (Default)    REG_SZ    C:\...\x.json": the name of the default value is localized, the type is not
  return res.stdout:match("REG_SZ%s+([^\r\n]+)") or ""
end

---@param a string
---@param b string
---@return boolean
local function under(a, b)
  local function norm(p)
    -- a registry value has backslashes; normalize keeps them off Windows
    return (vim.fs.normalize((p:gsub("\\", "/"))):gsub("/+$", ""):lower())
  end
  local na, nb = norm(a), norm(b)
  return na == nb or na:sub(1, #nb + 1) == nb .. "/"
end

---@class Testing.Sheet.NativeHost
---@field name string
---@field path string The host program, absolute.
---@field dir string This run's folder for the manifest.
---@field env? table<string, string> Variables Chromium starts with, and so the host it starts (`${...}` filled in).

---The host with its `env` filled in from the sheet's app (`${temp}`, ...), as a step is.
---@param host Testing.Sheet.NativeHost
---@param spec { env?: table<string, string> }
---@param vars? table<string, string> The app's (`testing.sheet.app`), nil without an app.
---@return Testing.Sheet.NativeHost|nil host, string|nil err
function M.with_env(host, spec, vars)
  if not spec.env then
    return host, nil
  end
  local env = {}
  for k, v in pairs(spec.env) do
    if vars then
      local filled, err = require("testing.sheet.app").expand(v, vars)
      if not filled then
        return nil, ("native_host.env.%s: %s"):format(k, tostring(err))
      end
      env[k] = filled
    elseif v:find("${", 1, true) then
      return nil, ("native_host.env.%s: ${...} needs the sheet's app"):format(k)
    else
      env[k] = v
    end
  end
  return vim.tbl_extend("force", host, { env = env }), nil
end

---Before the run: the host of the sheet, ready for the runner. Nil and the reason of a failure.
---@param root string
---@param spec { name: string, path: string }
---@param opts? { run?: Testing.Sheet.RegRun, windows?: boolean }
---@return Testing.Sheet.NativeHost|nil host, string|nil err
function M.prepare(root, spec, opts)
  opts = opts or {}
  local windows = opts.windows
  if windows == nil then
    windows = require("testing.platform").is_windows()
  end
  -- `${exe}` is the suffix of a program on this system: one sheet names a host built for Windows and for Linux
  local rel = spec.path:gsub("%${exe}", windows and ".exe" or "")
  local path = vim.fs.normalize(root .. "/" .. rel)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, ("native_host.path %s is no file (build the host first)"):format(rel)
  end
  if windows then
    local key = M.KEY .. "\\" .. spec.name
    local value = M.registered(spec.name, opts.run)
    if value and value:find(M.MARK, 1, true) then
      -- an earlier run of this engine ended without its cleanup: its key goes, nobody else wrote it
      (opts.run or reg_exe)({ "delete", key, "/f" })
    elseif value then
      return nil,
        ("a native messaging host %s is registered for Chromium already (%s -> %s): the sheet leaves it alone"):format(
          spec.name,
          key,
          value
        )
    end
    path = path:gsub("/", "\\")
  end
  local dir = vim.fn.tempname() .. "-" .. M.MARK
  vim.fn.mkdir(dir, "p")
  return { name = spec.name, path = path, dir = dir }, nil
end

---After the run, however it ended: the key goes when it still points into this run's folder, and the folder goes.
---@param host Testing.Sheet.NativeHost
---@param opts? { run?: Testing.Sheet.RegRun, windows?: boolean }
function M.cleanup(host, opts)
  opts = opts or {}
  local windows = opts.windows
  if windows == nil then
    windows = require("testing.platform").is_windows()
  end
  if windows then
    local value = M.registered(host.name, opts.run)
    if value and value ~= "" and under(value, host.dir) then
      (opts.run or reg_exe)({ "delete", M.KEY .. "\\" .. host.name, "/f" })
    end
  end
  vim.fn.delete(host.dir, "rf")
end

return M
