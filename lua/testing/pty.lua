-- @cache-env TESTING_WSL_DISTRO
---@module 'testing.pty'
---@brief Tier 2.5: a command in a real terminal (tmux in WSL, or tmux on Linux), its screen and its raw byte stream.
---@description
--- `open()` starts a detached tmux session of a fixed size running a command. `send()` types keys into it,
--- `screen()` is `tmux capture-pane -p -e` (the grid with its escape sequences) and `raw()` is everything the
--- program wrote to the terminal, recorded with `pipe-pane` (the OSC-1337 images of images.nvim, kitty graphics,
--- title sequences). Nothing is compared to a pixel image: what is checked is the byte stream.
---
--- Every call is an argument vector, never a shell string. On Windows tmux runs in WSL (`wsl [-d <distro>] --exec
--- tmux ...`, the distro from `$TESTING_WSL_DISTRO` or `opts.distro`); on Linux it runs directly. The process
--- runner is injectable (`opts.run(argv, stdin) -> { code, stdout, stderr }`) for specs.

local M = {}

---@class Testing.Pty.Result
---@field code integer
---@field stdout string
---@field stderr string

---@class Testing.Pty.Opts
---@field distro? string WSL distribution (default: `$TESTING_WSL_DISTRO`, else the default one).
---@field run? fun(argv: string[], stdin: string|nil, binary: boolean|nil): Testing.Pty.Result
---@field cols? integer Default 100.
---@field rows? integer Default 30.
---@field timeout_ms? integer Per tmux call (default 15000).

---The words that run a program on the host of tmux: `wsl [-d <distro>] --exec` on Windows (no shell: the words stay as they are), nothing on Linux.
---@param opts Testing.Pty.Opts
---@return string[]
local function host(opts)
  if not require("testing.platform").is_windows() then
    return {}
  end
  local distro = opts.distro or vim.uv.os_getenv("TESTING_WSL_DISTRO")
  local argv = { "wsl" }
  if distro and distro ~= "" then
    vim.list_extend(argv, { "-d", distro })
  end
  argv[#argv + 1] = "--exec"
  return argv
end

---@param opts Testing.Pty.Opts
---@return string[] prefix
local function prefix(opts)
  local argv = host(opts)
  argv[#argv + 1] = "tmux"
  return argv
end

---@param opts Testing.Pty.Opts
---@return fun(argv: string[], stdin: string|nil, binary: boolean|nil): Testing.Pty.Result
local function runner(opts)
  if opts.run then
    return opts.run
  end
  return function(argv, stdin, binary)
    -- `text` turns CRLF into LF (on Windows); the raw stream of a terminal is full of CRLF and must stay as it is
    local done =
      vim.system(argv, { text = not binary, stdin = stdin }):wait(opts.timeout_ms or 15000)
    return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end
end

---A tmux session.
---@class Testing.Pty.Session
---@field name string
---@field raw_path string File of the recording, on the host of tmux.
---@field _opts Testing.Pty.Opts
local Session = {}
Session.__index = Session

---@param self Testing.Pty.Session
---@param args string[]
---@param stdin? string
---@return Testing.Pty.Result
local function tmux(self, args, stdin)
  local argv = prefix(self._opts)
  vim.list_extend(argv, args)
  return runner(self._opts)(argv, stdin)
end

---Is tmux usable here (WSL with tmux on Windows)? Starts one short process.
---@param opts? Testing.Pty.Opts
---@return boolean ok, string reason
function M.available(opts)
  opts = opts or {}
  local argv = prefix(opts)
  argv[#argv + 1] = "-V"
  local ok, res = pcall(runner(opts), argv)
  if not ok or res.code ~= 0 then
    return false, "tmux is not available (WSL with tmux, or tmux on Linux)"
  end
  return true, (select(1, (res.stdout or ""):gsub("%s+$", "")))
end

local counter = 0

---Start `argv` in a new detached session. The raw stream is recorded from the first byte.
---@param command string[] The program and its arguments (run by tmux through `sh -c` with each word quoted).
---@param opts? Testing.Pty.Opts
---@return Testing.Pty.Session|nil session, string|nil err
function M.open(command, opts)
  opts = opts or {}
  counter = counter + 1
  local self = setmetatable({
    name = ("testing-pty-%d-%d"):format(vim.uv.os_getpid(), counter),
    _opts = opts,
  }, Session)
  -- on this machine the recording lives in this editor's temp folder (a spec may write there, its guard allows it);
  -- through WSL in the distribution's /tmp
  self.raw_path = #host(opts) == 0 and (vim.fn.tempname() .. "-" .. self.name .. ".raw")
    or ("/tmp/%s.raw"):format(self.name)
  local quoted = {}
  for _, word in ipairs(command) do
    quoted[#quoted + 1] = "'" .. word:gsub("'", "'" .. string.char(92) .. "''") .. "'"
  end
  -- Hold the program until the recorder is attached: `read` waits for the line `go` sent after pipe-pane.
  local script = ("read _; exec %s"):format(table.concat(quoted, " "))
  local res = tmux(self, {
    "new-session",
    "-d",
    "-s",
    self.name,
    "-x",
    tostring(opts.cols or 100),
    "-y",
    tostring(opts.rows or 30),
    "sh",
    "-c",
    script,
  })
  if res.code ~= 0 then
    return nil, "tmux new-session failed: " .. res.stderr
  end
  res = tmux(self, { "pipe-pane", "-t", self.name, "-o", "cat >> '" .. self.raw_path .. "'" })
  if res.code ~= 0 then
    self:close()
    return nil, "tmux pipe-pane failed: " .. res.stderr
  end
  tmux(self, { "send-keys", "-t", self.name, "Enter" })
  return self
end

---Type keys (tmux key names: `Enter`, `M-n`, `C-c`; a literal text with `opts.literal`).
---@param keys string[]
---@param literal? boolean
---@return boolean ok, string|nil err
function Session:send(keys, literal)
  local args = { "send-keys", "-t", self.name }
  if literal then
    args[#args + 1] = "-l"
  end
  vim.list_extend(args, keys)
  local res = tmux(self, args)
  return res.code == 0, res.code ~= 0 and res.stderr or nil
end

---The screen grid with its escape sequences (`capture-pane -p -e`).
---@return string
function Session:screen()
  return tmux(self, { "capture-pane", "-p", "-e", "-t", self.name }).stdout
end

---Everything the program wrote to the terminal so far.
---@return string
function Session:raw()
  local argv = host(self._opts)
  vim.list_extend(argv, { "cat", self.raw_path })
  return runner(self._opts)(argv, nil, true).stdout
end

---Wait until the screen or the raw stream holds `needle` (plain text).
---@param needle string
---@param timeout_ms? integer
---@param what? "screen"|"raw"
---@return boolean found
function Session:wait_for(needle, timeout_ms, what)
  local deadline = vim.uv.hrtime() + (timeout_ms or 5000) * 1e6
  repeat
    local text = what == "raw" and self:raw() or self:screen()
    if text:find(needle, 1, true) then
      return true
    end
    vim.wait(100)
  until vim.uv.hrtime() > deadline
  return false
end

---End the session and remove the recording.
function Session:close()
  tmux(self, { "kill-session", "-t", self.name })
  local argv = host(self._opts)
  if #argv == 0 then
    -- the recording is a file of this machine, in this editor's temp folder: removed without a process (a spec's
    -- process guard blocks an `rm` it was not told about, images.nvim's pty_osc1337_spec on Linux)
    os.remove(self.raw_path)
    return
  end
  vim.list_extend(argv, { "rm", "-f", self.raw_path })
  runner(self._opts)(argv)
end

return M
