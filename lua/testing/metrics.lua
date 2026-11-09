---@module 'testing.metrics'
-- @cache-allow env
-- (`from_env` takes the environment as an argument and is tested with a fake one; nothing a spec sees depends on it)
---@brief One line per heavy run: what ran, how long, how much came from the cache, how long it waited (`testing stats`).
---@description
--- The numbers behind the CI cadence (docs/CI.md, "Metrics"): does a cheaper cadence really mean fewer and shorter runs?
--- Every heavy run of the command line appends one JSON line to `metrics.jsonl`:
---
---   { v = 1, ts, kind, repo, sha?, host, os, duration_s, wait_s?, verdict, profile?, files? = { selected, cached, ran },
---     quick?, steps? = { [name] = seconds }, note? }
---
--- `kind`: `suite` (a whole suite), `suite-partial` (a selection), `ci` (`testing ci`), `ci-commit` / `ci-commit-quick`
--- (one commit of `testing ci commit`), `land`. Never a secret, an environment value or a path below the repository.
---
--- Where: `$TESTING_METRICS_FILE`, else the user's data folder read from the environment, not from `stdpath()`
--- (`scripts/test.sh` points `stdpath('state')` at a throwaway folder and sets its own `NVIM_APPNAME`):
--- `%LOCALAPPDATA%\testing\metrics.jsonl` on Windows, `$XDG_DATA_HOME/testing/metrics.jsonl` or
--- `~/.local/share/testing/metrics.jsonl` elsewhere. Only the command-line entry arms it (`services.metrics`), so a spec
--- or an editor calling `cli.main` writes nothing; `TESTING_METRICS=off` turns it off, and a CI service (`CI` set) does
--- not record (its machine is gone after the job). The file is cut at `MAX_BYTES`: the older half moves to
--- `metrics.1.jsonl` (replacing an older one).

local M = {}

M.SCHEMA_V = 1
M.OFF_ENV = "TESTING_METRICS"
M.FILE_ENV = "TESTING_METRICS_FILE"
---When the file is moved aside.
M.MAX_BYTES = 8 * 1024 * 1024

---@class Testing.Metrics
---@field path string
---@field host string

---@param getenv fun(name: string): string|nil
---@return string|nil
local function data_dir(getenv)
  local local_app = getenv("LOCALAPPDATA")
  if local_app and local_app ~= "" then
    return local_app
  end
  local xdg = getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then
    return xdg
  end
  local home = getenv("HOME") or getenv("USERPROFILE")
  if home and home ~= "" then
    return home .. "/.local/share"
  end
  return nil
end

---The metrics of the command-line entry; nil when off (by hand, in CI, or no place to write).
---@param getenv? fun(name: string): string|nil
---@return Testing.Metrics|nil
function M.from_env(getenv)
  getenv = getenv or os.getenv
  if getenv(M.OFF_ENV) == "off" then
    return nil
  end
  -- a child of a heavy run (`testing ci commit` starts `testing ci` at the commit and the base) is part of that run's
  -- line, not a line of its own
  local token = getenv(require("testing.queue").TOKEN_ENV)
  if token and token ~= "" then
    return nil
  end
  local file = getenv(M.FILE_ENV)
  if not (file and file ~= "") then
    local ci = getenv("CI")
    if ci and ci ~= "" and ci ~= "0" and ci ~= "false" then
      return nil
    end
    local dir = data_dir(getenv)
    if not dir then
      return nil
    end
    file = dir .. "/testing/metrics.jsonl"
  end
  local ok, host = pcall(vim.uv.os_gethostname)
  return {
    path = vim.fs.normalize(file),
    host = ok and type(host) == "string" and host or "?",
  }
end

---@return string
local function this_os()
  local sys = vim.uv.os_uname().sysname:lower()
  if sys:find("windows", 1, true) then
    return "windows"
  elseif sys == "darwin" then
    return "macos"
  end
  return "linux"
end

---Seconds with one decimal.
---@param s number|nil
---@return number|nil
function M.seconds(s)
  if type(s) ~= "number" then
    return nil
  end
  return math.floor(s * 10 + 0.5) / 10
end

---Append one run. Never raises and never fails the run: a line that cannot be written is lost.
---@param m Testing.Metrics|nil nil: not armed (a library call), nothing happens.
---@param entry table `kind`, `repo`, `duration_s`, `verdict` and what else there is (see the module's description).
---@return boolean written
function M.record(m, entry)
  if not m or type(entry) ~= "table" or type(entry.kind) ~= "string" then
    return false
  end
  local ok = pcall(function()
    local line = vim.tbl_extend("keep", {
      v = M.SCHEMA_V,
      ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      host = m.host,
      os = this_os(),
    }, entry)
    line.duration_s = M.seconds(line.duration_s)
    line.wait_s = M.seconds(line.wait_s)
    local st = vim.uv.fs_stat(m.path)
    if st and st.size > M.MAX_BYTES then
      os.remove(m.path:gsub("%.jsonl$", "") .. ".1.jsonl")
      os.rename(m.path, m.path:gsub("%.jsonl$", "") .. ".1.jsonl")
    end
    local wrote, err = require("lib.nvim.fs.write.append")(m.path, vim.json.encode(line) .. "\n")
    if not wrote then
      error(err)
    end
  end)
  return ok
end

---The lines of a metrics file (and its moved-aside part), oldest first; broken lines are skipped and counted.
---@param path string
---@return table[] entries
---@return integer broken
function M.read(path)
  local out, broken = {}, 0
  for _, p in ipairs({ (path:gsub("%.jsonl$", "")) .. ".1.jsonl", path }) do
    local f = io.open(p, "rb")
    if f then
      for line in f:lines() do
        if line ~= "" then
          local ok, doc = pcall(vim.json.decode, line)
          if ok and type(doc) == "table" and doc.v == M.SCHEMA_V and type(doc.kind) == "string" then
            out[#out + 1] = doc
          else
            broken = broken + 1
          end
        end
      end
      f:close()
    end
  end
  return out, broken
end

return M
