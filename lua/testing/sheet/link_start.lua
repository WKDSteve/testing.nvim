---@module 'testing.sheet.link_start'
---@brief Starts the program of a sheet's app the way a link or a double click does (`start = "link"`).
---@description
--- Not a module: `nvim --clean -l link_start.lua <program> <arg>...`, started by `testing.sheet.app` as a detached
--- process (no console of its own). A program started from a link gets no standard handles and its parent has no
--- console; a window program of appkit then has nobody to write to and shows its errors in a message box. libuv cannot
--- start a process like that (it gives NUL to a stream it is told to ignore), so this script does it with
--- `CreateProcessW`: `STARTF_USESTDHANDLES` with three null handles, nothing inherited, and `CREATE_NO_WINDOW` (a console
--- program gets a console without a window; a window program does not look at the flag). It writes `pid <n>` on its
--- stdout, waits for the program and ends with its exit code, so whoever started it ends the program with its tree.
--- Windows only; elsewhere `testing.sheet.app` starts the program itself.

-- Only as the script of `nvim -l`: loaded by `require` (inside a run whose own script is another one) it does nothing.
if not (_G.arg and type(_G.arg[0]) == "string" and _G.arg[0]:find("link_start%.lua$")) then
  return {}
end

local ffi = require("ffi")

ffi.cdef([[
typedef struct {
  uint32_t cb; void *lpReserved; void *lpDesktop; void *lpTitle;
  uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  uint16_t wShowWindow, cbReserved2; void *lpReserved2;
  void *hStdInput, *hStdOutput, *hStdError;
} testing_link_si;
typedef struct { void *hProcess, *hThread; uint32_t dwProcessId, dwThreadId; } testing_link_pi;
int CreateProcessW(const uint16_t *app, uint16_t *cmdline, void *pa, void *ta, int inherit, uint32_t flags,
  void *env, const uint16_t *cwd, testing_link_si *si, testing_link_pi *pi);
uint32_t WaitForSingleObject(void *h, uint32_t ms);
int GetExitCodeProcess(void *h, uint32_t *code);
int CloseHandle(void *h);
int MultiByteToWideChar(uint32_t cp, uint32_t flags, const char *s, int n, uint16_t *out, int size);
uint32_t GetLastError(void);
]])

local STARTF_USESTDHANDLES = 0x100
local CREATE_NO_WINDOW = 0x08000000
local INFINITE = 0xFFFFFFFF

---UTF-8 to a NUL-terminated UTF-16 buffer.
---@param s string
local function wide(s)
  local n = ffi.C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
  local buf = ffi.new("uint16_t[?]", n + 1)
  ffi.C.MultiByteToWideChar(65001, 0, s, #s, buf, n)
  buf[n] = 0
  return buf
end

---One argument as the C runtime reads it back (CommandLineToArgvW rules): quotes around it when it needs them,
---backslashes doubled only in front of a quote.
---@param a string
---@return string
local function quote(a)
  if a ~= "" and not a:find('[ \t\n\v"]') then
    return a
  end
  local out, slashes = { '"' }, 0
  for c in a:gmatch(".") do
    if c == "\\" then
      slashes = slashes + 1
    elseif c == '"' then
      out[#out + 1] = ("\\"):rep(slashes * 2 + 1) .. '"'
      slashes = 0
    else
      out[#out + 1] = ("\\"):rep(slashes) .. c
      slashes = 0
    end
  end
  out[#out + 1] = ("\\"):rep(slashes * 2) .. '"'
  return table.concat(out)
end

local argv = {}
for i = 1, #_G.arg do
  argv[i] = _G.arg[i]
end
if #argv == 0 then
  io.stderr:write("link_start: no program\n")
  os.exit(2)
end
local parts = {}
for i, a in ipairs(argv) do
  parts[i] = quote(a)
end

local si = ffi.new("testing_link_si")
si.cb = ffi.sizeof(si)
si.dwFlags = STARTF_USESTDHANDLES -- and the three handles stay null
local pi = ffi.new("testing_link_pi")
local cmdline = wide(table.concat(parts, " "))
local program = wide((argv[1]:gsub("/", "\\")))
if ffi.C.CreateProcessW(program, cmdline, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi) == 0 then
  io.stderr:write(
    ("link_start: %s did not start (error %d)\n"):format(argv[1], ffi.C.GetLastError())
  )
  os.exit(2)
end
ffi.C.CloseHandle(pi.hThread)
io.stdout:write(("pid %d\n"):format(pi.dwProcessId))
io.stdout:flush()
ffi.C.WaitForSingleObject(pi.hProcess, INFINITE)
local code = ffi.new("uint32_t[1]")
ffi.C.GetExitCodeProcess(pi.hProcess, code)
ffi.C.CloseHandle(pi.hProcess)
os.exit(tonumber(code[0]))
