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

---The identity of each program asked in this process; `false`: the program is there but did not answer.
---@type table<string, string|false>
local memo = {}

---How long one question to a program may take, in milliseconds. A program that does not answer is asked once more:
---Git Bash on a loaded Windows machine once hung for the whole ten seconds of the old single question.
M.ASK_MS = 5000

---Output of a command; nil and `"silent"` when it did not answer in time (or could not be started although it is
---there), nil, `"failed"` and the exit code when it answered with an exit code other than 0.
---@param argv string[]
---@return string|nil text
---@return "silent"|"failed"|nil why
---@return integer|nil code
local function output(argv)
  -- not from the project: on Windows a program is looked for in the working directory first, and a `git.exe` in the
  -- root of the project under test must not be what the key asks for its version
  local cwd = vim.fn.stdpath("data")
  local ok, res = pcall(function()
    return vim
      .system(argv, { text = true, timeout = M.ASK_MS, cwd = vim.fn.isdirectory(cwd) == 1 and cwd or nil })
      :wait(M.ASK_MS + 1000)
  end)
  -- `vim.system` ends a process that runs past `timeout` with SIGTERM and reports code 124
  if not ok or type(res) ~= "table" or res.code == 124 or res.signal == 15 then
    return nil, "silent"
  end
  if res.code ~= 0 then
    return nil, "failed", res.code
  end
  local text = (res.stdout or ""):gsub("\r", "")
  return text
end

---`output`, and once more when the program did not answer.
---@param argv string[]
---@return string|nil text
---@return "silent"|"failed"|nil why
---@return integer|nil code
local function ask(argv)
  local text, why, code = output(argv)
  if why == "silent" then
    text, why, code = output(argv)
  end
  return text, why, code
end

---The program a spec of this name really starts: bash is the one `lib.nvim.cross.bash` finds (Git Bash on Windows,
---never the WSL launcher that comes first on the PATH there), the others the name on the PATH. Nil when there is none.
---@param name string
---@return string|nil
local function program_path(name)
  if name == "bash" then
    local ok, cross = pcall(require, "lib.nvim.cross.bash")
    if ok and type(cross) == "table" and type(cross.find) == "function" then
      local found_ok, path = pcall(cross.find)
      return found_ok and path or nil
    end
  end
  return nil
end

---Is the program on the PATH? (`<absent>` is a statement about this, never a guess from a missing answer.)
---@param name string
---@return boolean
local function present(name)
  local ok, executable = pcall(require, "lib.nvim.cross.executable")
  if ok and type(executable) == "table" and type(executable.clear) == "function" then
    -- the PATH of a run can change between two questions (a spec that puts stand-ins first): asked fresh
    executable.clear(name)
    return executable.exists(name)
  end
  return vim.fn.executable(name) == 1
end

---@param text string
---@return string
local function first_line(text)
  return vim.trim(text:match("^[^\n]*"))
end

---@param name string
---@param lookup fun(name: string): string|nil
---@return string|nil  nil when git did not answer
local function git_identity(name, lookup)
  local out = ask({ name, "--version" })
  if not out then
    return nil
  end
  local version = first_line(out)
  -- the system and the global configuration (a `core.hookspath` there changed what a fixture repository does), with
  -- where each line comes from; the configuration of the repository the runner happens to sit in is not asked.
  -- A scope without a file is `<none>` (git exits 1); another exit code (a configuration git cannot read, exit 128) is a
  -- line of its own, never `<none>`; a scope that did not answer leaves git without an identity.
  local config = {}
  for _, scope in ipairs({ "--system", "--global" }) do
    local listed, why, code = ask({ name, "config", scope, "--list", "--show-origin" })
    if why == "silent" then
      return nil
    end
    if listed then
      config[#config + 1] = listed
    elseif code == 1 then
      config[#config + 1] = "<none>"
    else
      config[#config + 1] = ("<failed: exit %s>"):format(tostring(code))
    end
  end
  local env = {}
  for _, var in ipairs(M.GIT_ENV) do
    env[#env + 1] = var .. "=" .. tostring(lookup(var))
  end
  return version
    .. "|config "
    .. require("testing.cache.hash").sha256(table.concat(config, "\0")):sub(1, 16)
    .. "|env "
    .. require("testing.cache.hash").sha256(table.concat(env, "\0")):sub(1, 16)
end

---What a program is, as a line of the key: its version, and for git also its configuration; `<absent>` when it is not
---there; `<failed: exit N>` when it answered `--version` with an error (a stable answer is a line). Nil when it is there
---but did not answer (twice): then nothing is known about it, and a key that would name it cannot be made (it would
---store a result under a line that the next run, with an answer, never finds again). bash is the one
---`lib.nvim.cross.bash` finds, the one the specs start. Made once per process; `over` (a table from tool name to text,
---for specs; `false` = did not answer) replaces it.
---@param name string `git`, `bash` or `nvim`.
---@param over? table<string, string|false>
---@param lookup? fun(name: string): string|nil  Environment lookup (default `vim.uv.os_getenv`).
---@return string|nil
function M.identity(name, over, lookup)
  if over and over[name] ~= nil then
    return over[name] or nil
  end
  local hit = memo[name]
  if hit ~= nil then
    return hit or nil
  end
  local text
  local exe = program_path(name)
  if not exe and not present(name) then
    text = "<absent>"
  elseif name == "git" then
    text = git_identity(name, lookup or vim.uv.os_getenv)
  else
    local out, why, code = ask({ exe or name, "--version" })
    if out then
      text = first_line(out)
    elseif why == "failed" then
      text = ("<failed: exit %s>"):format(tostring(code))
    end
  end
  memo[name] = text or false
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
