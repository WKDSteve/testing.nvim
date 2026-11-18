---@module 'testing.perf.tree'
---@brief Snapshots of a process tree while `testing perf` runs a sheet: working set, peak, CPU seconds, command line.
---@description
--- `start({ root = pid })` samples every descendant of `root` (default: this editor, so the sheet's child editor and
--- everything it starts) every `interval_ms`:
---
--- * Windows: one long-lived PowerShell (`tree.ps1`, a CIM query per interval), so the sampling costs one process, not
---   one per sample; it leaves itself out and ends when `root` is gone or `stop()` kills it.
--- * Linux: `/proc/<pid>/stat` and `status` read from a timer of this editor.
---
--- A sample is `{ us, procs = { { pid, ppid, name, ws, peak, cpu, cmd } } }`; `us` is when it arrived here (monotonic
--- clock, microseconds), `ws`/`peak` bytes, `cpu` seconds. A process shorter than the interval may be missed: the
--- spawn trace has it with its duration, the tree only adds memory and CPU to the longer ones. Command lines are
--- redacted (`testing.core.ledger.redact_secrets`).

local M = {}

M.DEFAULT_INTERVAL_MS = 500
---Samples kept at most (a sheet that runs for hours must not grow without bound).
M.MAX_SAMPLES = 20000

local uv = vim.uv or vim.loop

local function now_us()
  return math.floor(uv.hrtime() / 1000)
end

local function redact(s)
  local ok, out = pcall(require("testing.core.ledger").redact_secrets, s or "")
  return ok and out or ""
end

---@param T table
---@param procs table[]
local function add(T, procs)
  if #T.list >= M.MAX_SAMPLES then
    return
  end
  for _, p in ipairs(procs) do
    p.cmd = redact(p.cmd)
  end
  T.list[#T.list + 1] = { us = now_us(), procs = procs }
end

---Parse one line of `tree.ps1`. Nil for a line that is no sample.
---@param line string
---@return table[]|nil
function M.parse_line(line)
  local ok, doc = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(doc) ~= "table" then
    return nil
  end
  local procs = doc.procs
  if type(procs) ~= "table" then
    return nil
  end
  -- a single process may come as an object instead of a list of one (ConvertTo-Json)
  if procs.pid then
    procs = { procs }
  end
  local out = {}
  for _, p in ipairs(procs) do
    if type(p) == "table" and tonumber(p.pid) then
      out[#out + 1] = {
        pid = tonumber(p.pid),
        ppid = tonumber(p.ppid),
        name = tostring(p.name or "?"),
        ws = tonumber(p.ws) or 0,
        peak = tonumber(p.peak) or 0,
        cpu = tonumber(p.cpu) or 0,
        cmd = tostring(p.cmd or ""),
      }
    end
  end
  return out
end

local function start_windows(T, root, interval)
  local here = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local script = (here:gsub("tree%.lua$", "tree.ps1"))
  local stdout = uv.new_pipe(false)
  local buf = ""
  local handle, pid = uv.spawn("powershell", {
    args = {
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (script:gsub("/", "\\")),
      "-Root",
      tostring(root),
      "-IntervalMs",
      tostring(interval),
    },
    stdio = { nil, stdout, nil },
    hide = true,
  }, function()
    T.done = true
  end)
  if not handle then
    pcall(stdout.close, stdout)
    return false, "cannot start powershell: " .. tostring(pid)
  end
  T.handle, T.pid, T.pipe = handle, pid, stdout
  stdout:read_start(function(_, data)
    if not data then
      return
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1):gsub("\r$", "")
      buf = buf:sub(nl + 1)
      local procs = M.parse_line(line)
      if procs then
        add(T, procs)
      end
    end
  end)
  return true
end

---@param path string
---@return string|nil
local function slurp(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---Every process of /proc with its parent, name, rss, peak and CPU seconds.
---@param proc_dir? string
---@return table<integer, table>
function M.read_proc(proc_dir)
  proc_dir = proc_dir or "/proc"
  local ticks = 100
  local page = 4096
  local out = {}
  local dir = uv.fs_scandir(proc_dir)
  if not dir then
    return out
  end
  while true do
    local name = uv.fs_scandir_next(dir)
    if not name then
      break
    end
    local pid = tonumber(name)
    if pid then
      local stat = slurp(("%s/%d/stat"):format(proc_dir, pid))
      if stat then
        -- the name is in parentheses and may contain spaces and parentheses: the rest starts after the last ")"
        local comm, rest = stat:match("^%d+ %((.*)%) (.*)$")
        if rest then
          local f = vim.split(rest, " ", { plain = true })
          -- rest[1] is field 3 (state): ppid 4, utime 14, stime 15, rss 24
          local status = slurp(("%s/%d/status"):format(proc_dir, pid)) or ""
          local hwm = tonumber(status:match("VmHWM:%s*(%d+)")) or 0
          local cmd = (slurp(("%s/%d/cmdline"):format(proc_dir, pid)) or ""):gsub("%z", " ")
          out[pid] = {
            pid = pid,
            ppid = tonumber(f[2]) or 0,
            name = comm,
            ws = (tonumber(f[22]) or 0) * page,
            peak = hwm * 1024,
            cpu = ((tonumber(f[12]) or 0) + (tonumber(f[13]) or 0)) / ticks,
            cmd = vim.trim(cmd):sub(1, 300),
          }
        end
      end
    end
  end
  return out
end

---The descendants of `root` in a process table.
---@param all table<integer, table>
---@param root integer
---@return table[]
function M.descendants(all, root)
  local kids = {}
  for pid, p in pairs(all) do
    if pid ~= p.ppid then
      kids[p.ppid] = kids[p.ppid] or {}
      table.insert(kids[p.ppid], p)
    end
  end
  local out, queue, seen = {}, { root }, { [root] = true }
  while #queue > 0 do
    local parent = table.remove(queue, 1)
    for _, c in ipairs(kids[parent] or {}) do
      if not seen[c.pid] then
        seen[c.pid] = true
        out[#out + 1] = c
        queue[#queue + 1] = c.pid
      end
    end
  end
  table.sort(out, function(a, b)
    return a.pid < b.pid
  end)
  return out
end

local function start_proc(T, root, interval)
  local timer = uv.new_timer()
  if not timer then
    return false, "cannot create a timer"
  end
  T.timer = timer
  local function tick()
    add(T, M.descendants(M.read_proc(), root))
  end
  tick()
  timer:start(interval, interval, vim.schedule_wrap(tick))
  return true
end

---@class Testing.Perf.Tree
---@field list { us: integer, procs: table[] }[]
---@field done? boolean
---@field error? string why there are no samples
local Tree = {}
Tree.__index = Tree

---@param opts? { root?: integer, interval_ms?: integer, platform?: "windows"|"proc" }
---@return Testing.Perf.Tree
function M.start(opts)
  opts = opts or {}
  local T = setmetatable({ list = {} }, Tree)
  local root = opts.root or uv.os_getpid()
  local interval = opts.interval_ms or M.DEFAULT_INTERVAL_MS
  local platform = opts.platform
    or (require("testing.platform").is_windows() and "windows" or "proc")
  local ok, err
  if platform == "windows" then
    ok, err = start_windows(T, root, interval)
  elseif uv.fs_stat("/proc/self/stat") then
    ok, err = start_proc(T, root, interval)
  else
    ok, err = false, "no /proc on this system"
  end
  if not ok then
    T.error = err
  end
  return T
end

---How many samples there are now (a mark for `between`).
function Tree:count()
  return #self.list
end

---Samples from mark `a` (exclusive) to mark `b` (inclusive).
function Tree:between(a, b)
  return vim.list_slice(self.list, a + 1, b)
end

---Stop sampling. Safe to call twice.
function Tree:stop()
  if self.timer then
    pcall(self.timer.stop, self.timer)
    pcall(self.timer.close, self.timer)
    self.timer = nil
  end
  if self.handle then
    pcall(self.handle.kill, self.handle, "sigterm")
    pcall(self.handle.close, self.handle)
    self.handle = nil
  end
  if self.pipe then
    pcall(self.pipe.read_stop, self.pipe)
    pcall(self.pipe.close, self.pipe)
    self.pipe = nil
  end
end

---@class Testing.Perf.Proc
---@field pid integer
---@field name string
---@field cmd string
---@field first_us integer
---@field last_us integer
---@field ws integer bytes, the largest working set seen
---@field peak integer bytes
---@field cpu number seconds
---@field alive_at_end? boolean

---Per process of a list of samples: first and last seen, the largest working set and peak, the last CPU seconds.
---@param samples { us: integer, procs: table[] }[]
---@return table<integer, Testing.Perf.Proc>
function M.per_process(samples)
  local out = {}
  for _, s in ipairs(samples) do
    for _, p in ipairs(s.procs) do
      local e = out[p.pid]
      if not e then
        e = { pid = p.pid, name = p.name, cmd = p.cmd, first_us = s.us, ws = 0, peak = 0, cpu = 0 }
        out[p.pid] = e
      end
      e.last_us = s.us
      e.ws = math.max(e.ws, p.ws or 0)
      e.peak = math.max(e.peak, p.peak or 0, p.ws or 0)
      e.cpu = math.max(e.cpu, p.cpu or 0)
    end
  end
  return out
end

return M
