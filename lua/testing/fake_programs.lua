---@module 'testing.fake_programs'
---@brief Stand-ins for platform programs (`open`, `osascript`, `trash`, `xdg-open`) that record how they were called.
---
--- A spec that wants to know WHICH command a feature would run on macOS or Linux (`open -R <file>`, `trash <paths>`)
--- puts a folder of stand-ins first on the `PATH`, runs the feature, and reads the recorded calls. It proves what
--- would be called, not what the system does with it; it never replaces a real run on that system.
---
---   local fake = require("testing.fake_programs").new({ "open", "osascript" })
---   fake:as("macos", function()          -- `testing.platform` answers "macOS" inside
---     fake:with_path(function()          -- `PATH` of this process starts with the stand-ins
---       feature.reveal("/tmp/a.txt")     -- runs `open -R /tmp/a.txt`
---     end)
---   end)
---   eq(fake:calls()[1].argv, { "-R", "/tmp/a.txt" })
---   fake:close()
---
--- A child editor gets the folder through `fake:path()` (the value for its `PATH`). Stand-ins are `.cmd` files on
--- Windows and `sh` scripts elsewhere. Known limit on Windows: an empty argument ends the argument list.

local uv = vim.uv or vim.loop

---@class Testing.FakeProgram
---@field exit_code? integer Exit code of the stand-in (default 0).
---@field stdout? string Text the stand-in prints (default none).
---@field stderr? string Text the stand-in prints on stderr (default none).
---@field stdin? boolean Record standard input too (POSIX only; off by default, because reading an inherited terminal blocks).

---@class Testing.FakePrograms.Call
---@field program string Name the stand-in was called by.
---@field argv string[] Arguments, without the program.
---@field cwd string Working directory of the call.
---@field stdin? string Recorded standard input (only with `stdin = true`).

---@class Testing.FakePrograms
---@field dir string Folder that holds the stand-ins and the log.
---@field names string[] Programs that were stood in for.
local Fake = {}
Fake.__index = Fake

local M = {}

---The system the stand-ins run on, fixed when this module loads: `Fake:as()` changes what `testing.platform` answers
---for the feature under test, and the stand-ins (`.cmd` or `sh`, `;` or `:` in the PATH) must not follow it. An
---`as()` needs an instance, so the module is always loaded before one is active.
local HOST_WINDOWS = require("testing.platform").is_windows()

---@return boolean
local function windows()
  return HOST_WINDOWS
end

local function sep()
  return windows() and ";" or ":"
end

---@param path string
---@param text string
local function write(path, text)
  local fd = assert(io.open(path, "wb"))
  fd:write(text)
  fd:close()
end

---Escape text for a single-quoted POSIX shell word.
---@param s string
---@return string
local function sq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@param name string
---@param spec Testing.FakeProgram
---@param log string
---@return string
local function posix_script(name, spec, log)
  local lines = {
    "#!/bin/sh",
    ("log=%s"):format(sq(log)),
    ('{ printf \'program=%%s\\n\' %s; printf \'cwd=%%s\\n\' "$(pwd)"; for a in "$@"; do printf \'arg=%%s\\n\' "$a"; done; } >> "$log"'):format(
      sq(name)
    ),
  }
  if spec.stdin then
    lines[#lines + 1] =
      'while IFS= read -r l || [ -n "$l" ]; do printf \'stdin=%s\\n\' "$l" >> "$log"; done'
  end
  lines[#lines + 1] = "printf 'end\\n' >> \"$log\""
  if spec.stdout and spec.stdout ~= "" then
    lines[#lines + 1] = ("printf '%%s' %s"):format(sq(spec.stdout))
  end
  if spec.stderr and spec.stderr ~= "" then
    lines[#lines + 1] = ("printf '%%s' %s >&2"):format(sq(spec.stderr))
  end
  lines[#lines + 1] = ("exit %d"):format(spec.exit_code or 0)
  return table.concat(lines, "\n") .. "\n"
end

---@param name string
---@param spec Testing.FakeProgram
---@param log string
---@return string
local function cmd_script(name, spec, log)
  local win_log = log:gsub("/", "\\")
  local function echo_lines(text, to_err)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
      -- `^` escapes the characters cmd treats as operators
      out[#out + 1] = ("echo %s%s"):format(
        line:gsub("([&|<>^%%])", "^%1"),
        to_err and " 1>&2" or ""
      )
    end
    return out
  end
  local lines = {
    "@echo off",
    "setlocal DisableDelayedExpansion",
    ('echo program=%s>> "%s"'):format(name, win_log),
    ('echo cwd=%%CD%%>> "%s"'):format(win_log),
    ":loop",
    'if "%~1"=="" goto done',
    ('echo arg=%%~1>> "%s"'):format(win_log),
    "shift",
    "goto loop",
    ":done",
    ('echo end>> "%s"'):format(win_log),
  }
  vim.list_extend(lines, echo_lines(spec.stdout))
  vim.list_extend(lines, echo_lines(spec.stderr, true))
  lines[#lines + 1] = ("exit /b %d"):format(spec.exit_code or 0)
  return table.concat(lines, "\r\n") .. "\r\n"
end

---Create stand-ins in a fresh temporary folder.
---@param programs (string|table<string, Testing.FakeProgram>)[]|table<string, Testing.FakeProgram> Names (default behaviour) or `name = spec`.
---@return Testing.FakePrograms
function M.new(programs)
  local specs = {}
  for k, v in pairs(programs) do
    if type(k) == "number" then
      specs[v] = {}
    else
      specs[k] = v
    end
  end
  local dir = vim.fs.normalize(vim.fn.tempname())
  assert(vim.fn.mkdir(dir, "p") == 1, "fake_programs: cannot create " .. dir)
  local log = dir .. "/calls.log"
  write(log, "")
  local names = vim.tbl_keys(specs)
  table.sort(names)
  for _, name in ipairs(names) do
    if windows() then
      write(dir .. "/" .. name .. ".cmd", cmd_script(name, specs[name], log))
    else
      local path = dir .. "/" .. name
      write(path, posix_script(name, specs[name], log))
      assert(uv.fs_chmod(path, 493)) -- 0755
    end
  end
  return setmetatable({ dir = dir, names = names, _log = log }, Fake)
end

---`PATH` with the stand-ins first: the value for a child editor's environment.
---@param base? string The `PATH` to put them in front of (default: this process's).
---@return string
function Fake:path(base)
  base = base or vim.env.PATH or ""
  local dir = windows() and self.dir:gsub("/", "\\") or self.dir
  return dir .. sep() .. base
end

---Run `fn` with the stand-ins first on this process's `PATH`; the old `PATH` comes back afterwards.
---@generic T
---@param fn fun(): T
---@return T
function Fake:with_path(fn)
  local saved = vim.env.PATH
  vim.env.PATH = self:path(saved)
  local ok, res = pcall(fn)
  vim.env.PATH = saved
  if not ok then
    error(res, 0)
  end
  return res
end

---Run `fn` while `testing.platform` (and so `lib.nvim.cross.platform`'s `is_*` answers) says `system`.
---@generic T
---@param system "windows"|"macos"|"linux"
---@param fn fun(): T
---@return T
function Fake:as(system, fn)
  assert(
    system == "windows" or system == "macos" or system == "linux",
    "fake_programs: system is windows, macos or linux"
  )
  local names = {
    is_windows = "lib.nvim.cross.platform.is_windows",
    is_macos = "lib.nvim.cross.platform.is_macos",
    is_linux = "lib.nvim.cross.platform.is_linux",
  }
  local saved = {}
  for key, module in pairs(names) do
    saved[module] = package.loaded[module]
    local answer = key == "is_" .. system
    package.loaded[module] = function()
      return answer
    end
  end
  local ok, res = pcall(fn)
  for module, value in pairs(saved) do
    package.loaded[module] = value
  end
  if not ok then
    error(res, 0)
  end
  return res
end

---The recorded calls, oldest first.
---@param program? string Only the calls of this stand-in.
---@return Testing.FakePrograms.Call[]
function Fake:calls(program)
  local out, cur = {}, nil
  local fd = io.open(self._log, "rb")
  if not fd then
    return out
  end
  for line in fd:lines() do
    line = line:gsub("\r$", "")
    local key, value = line:match("^(%w+)=(.*)$")
    if key == "program" then
      cur = { program = value, argv = {}, cwd = "" }
    elseif cur and key == "cwd" then
      cur.cwd = value
    elseif cur and key == "arg" then
      cur.argv[#cur.argv + 1] = value
    elseif cur and key == "stdin" then
      cur.stdin = (cur.stdin and cur.stdin .. "\n" or "") .. value
    elseif cur and line == "end" then
      if not program or cur.program == program then
        out[#out + 1] = cur
      end
      cur = nil
    end
  end
  fd:close()
  return out
end

---Forget the recorded calls.
function Fake:reset()
  write(self._log, "")
end

---Remove the folder.
function Fake:close()
  vim.fn.delete(self.dir, "rf")
end

return M
