---@module 'testing.fake_redirect'
---@brief Sends the starts of stood-in programs straight to their stand-in, past cmd.exe and the `.exe` search.
---@description
--- A sheet's `fakes` (`testing.fake_programs`) put a folder of stand-ins first on the child's `PATH`. On Windows that
--- is not enough: a stand-in is a `.cmd` file, cmd.exe parses its command line before the script runs (an argument
--- `x&cursor=1` started the real `cursor`), and a call of `explorer.exe` or a bare `uv.spawn("curl")` does not look
--- for `.cmd` at all and starts the real program. Installed in the child before the minimal init (`job.preload`, so
--- an outer spawn trace still sees the call as the plugin made it), this module rewrites every start whose program
--- is a stand-in (by its bare name, by `<name>.exe`, or by its path in the folder):
---
--- * Windows: to `nvim -l <recorder> <dir> <name> <args...>`. nvim is a real program, so the arguments arrive as
---   given and the recorder (`scripts/fake_record.lua`) writes them to the log one by one.
--- * elsewhere: to the stand-in's absolute path (WSL calls Windows programs as `explorer.exe`).
---
--- Covered: `vim.system`, `vim.uv.spawn`, `vim.fn.system`/`systemlist`/`jobstart`/`termopen` called from Lua, and
--- the first word of a command string (`io.popen`, `os.execute`, a string to `vim.fn.system`). Not covered: a start
--- from Vimscript (`system()`, `:!`), and one a program makes itself; those still find the `.cmd` on the `PATH`.

local uv = vim.uv or vim.loop

local M = {}

-- the fields of the standard libraries are replaced on purpose, through a setter (luacheck reads `io.x =` as a mistake)
local function set(t, k, v)
  t[k] = v
end

local WINDOWS = require("testing.platform").is_windows()

---@type table?
local O = nil
---@type { dir: string, names: table<string, string>, recorder: string, nvim: string }?
local state = nil

---@param s string
---@return string
local function key(s)
  return WINDOWS and s:lower() or s
end

---@param p string
---@return string
local function norm(p)
  return key(vim.fs.normalize(p))
end

---The stand-in a program name or path means, nil when it is none.
---@param prog any
---@return string?
function M.match(prog)
  if not state or type(prog) ~= "string" or prog == "" then
    return nil
  end
  local p = prog:gsub("\\", "/")
  local base = p:match("([^/]+)$") or p
  if base ~= p then
    -- a path: only one into the folder of the stand-ins (`exepath()` of a stand-in), never a real program's
    if norm(vim.fs.dirname(p)) ~= norm(state.dir) then
      return nil
    end
    base = base:gsub("%.[Cc][Mm][Dd]$", "")
  end
  local k = key(base)
  return state.names[k] or state.names[(k:gsub("%.exe$", ""))]
end

---The program and the arguments to run instead of `name args...`.
---@param name string
---@return string program
---@return string[] prefix
local function target(name)
  assert(state)
  if WINDOWS then
    return state.nvim,
      { "--clean", "-n", "-i", "NONE", "--headless", "-l", state.recorder, state.dir, name }
  end
  return state.dir .. "/" .. name, {}
end

---A command as a list, rewritten when its program is a stand-in.
---@param cmd any
---@return any
function M.argv(cmd)
  if type(cmd) ~= "table" then
    return cmd
  end
  local name = M.match(cmd[1])
  if not name then
    return cmd
  end
  local prog, prefix = target(name)
  local out = { prog }
  vim.list_extend(out, prefix)
  for i = 2, #cmd do
    out[#out + 1] = cmd[i]
  end
  return out
end

---The kind of shell a command string goes to: `cmd`, `pwsh` (PowerShell) or `sh` (anything else).
---@param shell? string a program name or path; nil: the shell of `io.popen`/`os.execute` (cmd.exe on Windows)
---@return "cmd"|"pwsh"|"sh"
function M.shell_kind(shell)
  if shell == nil then
    return WINDOWS and "cmd" or "sh"
  end
  -- the program's own name: the last part of its path, without arguments (`pwsh -NoLogo`) or `.exe`
  local tail = shell:lower():gsub("\\", "/"):match("([^/]*)$") or ""
  local base = (tail:match('^"?([^%s"]+)') or ""):gsub("%.exe$", "")
  if base == "cmd" then
    return "cmd"
  elseif base == "pwsh" or base == "powershell" then
    return "pwsh"
  end
  return "sh"
end

---@param s string
---@param kind "cmd"|"pwsh"|"sh"
---@return string
local function shell_quote(s, kind)
  if s:match("^[%w%._/:%-]+$") then
    return s -- nothing a shell would split or expand: bare, as a guard that reads the line expects it
  end
  if kind == "cmd" then
    return '"' .. s .. '"'
  end
  return "'" .. s:gsub("'", kind == "pwsh" and "''" or "'\\''") .. "'"
end

---A command string, its first word rewritten when it names a stand-in; the rest goes to the shell as before.
---@param cmd any
---@param shell? string the shell it goes to (`'shell'`); nil: the one of `io.popen`/`os.execute`
---@return any
function M.line(cmd, shell)
  if type(cmd) ~= "string" then
    return cmd
  end
  local lead, word, rest = cmd:match('^(%s*)"([^"]+)"(.*)$')
  if not word then
    lead, word, rest = cmd:match("^(%s*)([^%s]+)(.*)$")
  end
  local name = word and M.match(word)
  if not name then
    return cmd
  end
  local kind = M.shell_kind(shell)
  local prog, prefix = target(name)
  -- PowerShell runs a quoted path only through its call operator
  local parts = { (kind == "pwsh" and "& " or "") .. shell_quote(prog, kind) }
  for _, a in ipairs(prefix) do
    parts[#parts + 1] = shell_quote(a, kind)
  end
  local line = lead .. table.concat(parts, " ") .. rest
  if shell == nil and kind == "cmd" then
    -- `cmd /c` of io.popen/os.execute strips the first and the last quote of a line with more than two
    -- ('shellxquote' does the same for a string to vim.fn.system)
    return '"' .. line .. '"'
  end
  return line
end

---@param cmd any
---@return any
local function either(cmd)
  return type(cmd) == "table" and M.argv(cmd) or M.line(cmd, vim.o.shell)
end

---Install the rewrite for the stand-ins in `opts.dir` (a folder from `testing.fake_programs.new`).
---@param opts { dir: string }
---@return boolean ok
---@return string? why
function M.install(opts)
  local dir = opts and opts.dir
  if type(dir) ~= "string" or dir == "" then
    return false, "fake_redirect: no folder of stand-ins"
  end
  local fd = io.open(dir .. "/specs.json", "rb")
  if not fd then
    return false, "fake_redirect: " .. dir .. " has no specs.json"
  end
  local ok, specs = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  if not ok or type(specs) ~= "table" then
    return false, "fake_redirect: specs.json does not parse"
  end
  local names = {}
  for name in pairs(specs) do
    names[key(name)] = name
  end
  -- the recorder is a script of the repository, not a module: `<root>/scripts/fake_record.lua`
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local repo = vim.fs.dirname(vim.fs.dirname(here))
  M.uninstall()
  state = {
    dir = vim.fs.normalize(dir),
    names = names,
    recorder = repo .. "/scripts/fake_record.lua",
    nvim = vim.v.progpath,
  }
  O = {
    system = vim.system,
    spawn = uv.spawn,
    fn_system = vim.fn.system,
    fn_systemlist = vim.fn.systemlist,
    jobstart = vim.fn.jobstart,
    termopen = vim.fn.termopen,
    popen = io.popen,
    execute = os.execute,
  }
  local o = O
  vim.system = function(cmd, ...)
    return o.system(M.argv(cmd), ...)
  end
  uv.spawn = function(path, sopts, ...)
    local name = M.match(path)
    if name and type(sopts) == "table" then
      local prog, prefix = target(name)
      local args = vim.list_extend(vim.deepcopy(prefix), sopts.args or {})
      sopts = vim.tbl_extend("force", sopts, { args = args })
      path = prog
    end
    return o.spawn(path, sopts, ...)
  end
  vim.fn.system = function(cmd, ...)
    return o.fn_system(either(cmd), ...)
  end
  vim.fn.systemlist = function(cmd, ...)
    return o.fn_systemlist(either(cmd), ...)
  end
  vim.fn.jobstart = function(cmd, ...)
    return o.jobstart(either(cmd), ...)
  end
  vim.fn.termopen = function(cmd, ...)
    return o.termopen(either(cmd), ...)
  end
  set(io, "popen", function(cmd, ...)
    return o.popen(M.line(cmd), ...)
  end)
  set(os, "execute", function(cmd, ...)
    return o.execute(M.line(cmd), ...)
  end)
  return true
end

---Put the originals back.
function M.uninstall()
  if not O then
    return
  end
  vim.system = O.system
  uv.spawn = O.spawn
  vim.fn.system = O.fn_system
  vim.fn.systemlist = O.fn_systemlist
  vim.fn.jobstart = O.jobstart
  vim.fn.termopen = O.termopen
  set(io, "popen", O.popen)
  set(os, "execute", O.execute)
  O, state = nil, nil
end

return M
