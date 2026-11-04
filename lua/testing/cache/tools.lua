---@module 'testing.cache.tools'
-- @cache-env GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_EXEC_PATH GIT_TEMPLATE_DIR
-- @cache-env GIT_DIR GIT_WORK_TREE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME
-- @cache-env GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE HOME XDG_CONFIG_HOME
---@brief The tools a spec that vouches `-- @cache-allow spawn` may start and still be cached.
---@description
--- A spec that starts a process is cached only when the author vouches for it (`-- @cache-allow spawn`) AND everything
--- that process was started from is part of the key: the editor (its version is in every key), `git` and `bash`. For
--- those two the key holds the version and, for git, the system and global configuration and the `GIT_*` variables
--- that change what git does (`identity`). The effects ledger of the run says which programs were started; a program
--- that is not on this list (`SPAWN_TOOLS`) keeps the file out of the cache as before (`strip`).
local M = {}

---The programs a vouched spec may start. Anything else in the ledger refuses the file.
---@type table<string, true>
M.SPAWN_TOOLS = { nvim = true, git = true, bash = true }

---The `GIT_*` variables that decide what git does with a repository the spec makes (identity of a commit, configuration,
---where it looks for things).
M.GIT_ENV = {
  "GIT_CONFIG_GLOBAL",
  "GIT_CONFIG_SYSTEM",
  "GIT_CONFIG_NOSYSTEM",
  "GIT_CONFIG_COUNT",
  "GIT_EXEC_PATH",
  "GIT_TEMPLATE_DIR",
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_AUTHOR_NAME",
  "GIT_AUTHOR_EMAIL",
  "GIT_AUTHOR_DATE",
  "GIT_COMMITTER_NAME",
  "GIT_COMMITTER_EMAIL",
  "GIT_COMMITTER_DATE",
  "HOME",
  "XDG_CONFIG_HOME",
}

---@type table<string, string>
local memo = {}

---Output of a command, or nil when it cannot be run or fails.
---@param argv string[]
---@return string|nil
local function output(argv)
  -- not from the project: on Windows a program is looked for in the working directory first, and a `git.exe` in the
  -- root of the project under test must not be what the key asks for its version
  local cwd = vim.fn.stdpath("data")
  local ok, res = pcall(function()
    return vim
      .system(argv, { text = true, timeout = 10000, cwd = vim.fn.isdirectory(cwd) == 1 and cwd or nil })
      :wait(11000)
  end)
  if not ok or type(res) ~= "table" or res.code ~= 0 then
    return nil
  end
  local text = (res.stdout or ""):gsub("\r", "")
  return text
end

---@param text string|nil
---@return string
local function first_line(text)
  return text and vim.trim(text:match("^[^\n]*")) or "<absent>"
end

---@param name string
---@param lookup fun(name: string): string|nil
---@return string
local function git_identity(name, lookup)
  local version = first_line(output({ name, "--version" }))
  if version == "<absent>" then
    return version
  end
  -- the system and the global configuration (a `core.hookspath` there changed what a fixture repository does), with
  -- where each line comes from; the configuration of the repository the runner happens to sit in is not asked
  local config = {}
  for _, scope in ipairs({ "--system", "--global" }) do
    config[#config + 1] = output({ name, "config", scope, "--list", "--show-origin" }) or "<none>"
  end
  local env = {}
  for _, var in ipairs(M.GIT_ENV) do
    env[#env + 1] = var .. "=" .. tostring(lookup(var))
  end
  return version
    .. "|config "
    .. vim.fn.sha256(table.concat(config, "\0")):sub(1, 16)
    .. "|env "
    .. vim.fn.sha256(table.concat(env, "\0")):sub(1, 16)
end

---What a program is, as a line of the key: its version, and for git also its configuration. Made once per process; `over`
---(a table from tool name to text, for specs) replaces it.
---@param name string `git`, `bash` or `nvim`.
---@param over? table<string, string>
---@param lookup? fun(name: string): string|nil  Environment lookup (default `vim.uv.os_getenv`).
---@return string
function M.identity(name, over, lookup)
  if over and over[name] then
    return over[name]
  end
  if memo[name] then
    return memo[name]
  end
  local text
  if name == "git" then
    text = git_identity(name, lookup or vim.uv.os_getenv)
  else
    text = first_line(output({ name, "--version" }))
  end
  memo[name] = text
  return text
end

---The program of a ledger entry (`git -C <TMP>/x status (x3)`, `"C:/Program Files/Git/bin/git.exe" status`): the first
---word or quoted string, without its directory and its `.exe`.
---@param text any
---@return string|nil
function M.program_of(text)
  if type(text) ~= "string" then
    return nil
  end
  local first = text:match('^"([^"]*)"') or text:match("^(%S+)")
  if not first then
    return nil
  end
  local base = first:gsub("\\", "/"):match("([^/]+)$") or first
  return (base:lower():gsub("%.exe$", ""))
end

---Is every process of this ledger list one that the key covers? An entry that was blocked, or the note that the ledger
---dropped entries, is not.
---@param list any The `spawned` list of a case.
---@return boolean
function M.covered(list)
  if type(list) ~= "table" then
    return false
  end
  for _, entry in ipairs(list) do
    local text = type(entry) == "table" and entry.text or entry
    if type(text) ~= "string" or text:find("[blocked]", 1, true) then
      return false
    end
    local program = M.program_of(text)
    if not program or not M.SPAWN_TOOLS[program] then
      return false
    end
  end
  -- a list with a hole (a map, a ledger bound) is not a list of processes
  return next(list) == nil or #list > 0
end

---The cases of a vouched spec without the processes the key covers, to be stored (a cached case replays with empty
---effects, as it always did); nil and the reason when one case started something else.
---@param cases table[]
---@return table[]|nil cases
---@return string|nil why
function M.strip(cases)
  local out = {}
  for i, c in ipairs(cases) do
    local ef = type(c) == "table" and c.effects or nil
    if type(ef) ~= "table" or type(ef.spawned) ~= "table" then
      return nil, "effects were not recorded"
    end
    if not M.covered(ef.spawned) then
      return nil, "the file has effects (spawned)"
    end
    out[i] = vim.tbl_extend("force", c, { effects = vim.tbl_extend("force", ef, { spawned = {} }) })
  end
  return out, nil
end

---Forget what was looked up (specs).
function M.reset()
  memo = {}
end

return M
