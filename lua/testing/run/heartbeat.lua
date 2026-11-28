---@module 'testing.run.heartbeat'
---@brief A run that says nothing for a while says what it waits for.
---@description
--- Under full load a run with `--file` stayed silent for over 110 s (markdown.nvim, 2026-11-22), and nobody could tell
--- whether it waited in the queue, for a child that would not start, or for something else. A heartbeat watches the
--- events of the run (a file started, a case done, a file done) and, after `after_s` without one, writes one line on
--- stderr naming the phase and the files that are still running and for how long; then again every `every_s` while it
--- stays quiet.
---
--- It runs on a libuv timer, so it speaks while the run waits in the event loop (`vim.wait` for the children of an
--- isolated run, the queue). A spec that runs in this process and keeps Lua busy holds the timer back as well: that
--- run is not silent by waiting, it is busy.

local M = {}

---Seconds without an event before the first line, and between two lines.
M.AFTER_S = 30
M.EVERY_S = 30
---How often the timer looks (ms).
M.TICK_MS = 1000

---@class Testing.Heartbeat
---@field after_s number
---@field every_s number
---@field now fun(): number seconds
---@field write fun(s: string)
---@field started number
---@field last number the last event
---@field said? number the last line written
---@field what string the phase
---@field files table<string, number> running file -> when it started
---@field timer? table the libuv timer
local H = {}
H.__index = H

---@param opts? table `after_s`, `every_s`, `now` (seconds), `write` (one line)
---@return Testing.Heartbeat
function M.new(opts)
  opts = opts or {}
  local now = opts.now or function()
    return vim.uv.hrtime() / 1e9
  end
  local t = now()
  return setmetatable({
    after_s = opts.after_s or M.AFTER_S,
    every_s = opts.every_s or M.EVERY_S,
    now = now,
    write = opts.write or function(s)
      io.stderr:write(s .. "\n")
    end,
    started = t,
    last = t,
    what = "starting",
    files = {},
  }, H)
end

---Something happened: the quiet starts again.
function H:beat()
  self.last = self.now()
end

---The phase of the run (`discovering spec files`, `running specs`, ...); also an event.
---@param what string
function H:phase(what)
  self.what = what
  self:beat()
end

---@param rel string
function H:file_start(rel)
  self.files[rel] = self.now()
  self:beat()
end

---@param rel string
function H:file_done(rel)
  self.files[rel] = nil
  self:beat()
end

---The line for a quiet run, or nil while it is not quiet long enough.
---@return string|nil
function H:check()
  local t = self.now()
  if t - self.last < self.after_s then
    return nil
  end
  if self.said and t - self.said < self.every_s then
    return nil
  end
  self.said = t
  local running = {}
  for rel, since in pairs(self.files) do
    running[#running + 1] = ("%s (%d s)"):format(rel, math.floor(t - since))
  end
  table.sort(running)
  local files = #running > 0
      and ("; still running: " .. table.concat(vim.list_slice(running, 1, 5), ", ") .. (#running > 5 and (", +" .. (#running - 5)) or ""))
    or ""
  return ("testing: still working after %d s, nothing new for %d s: %s%s"):format(
    math.floor(t - self.started),
    math.floor(t - self.last),
    self.what,
    files
  )
end

---Start the timer (idempotent).
function H:start()
  if self.timer then
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  self.timer = timer
  timer:start(M.TICK_MS, M.TICK_MS, function()
    local line = self:check()
    if line then
      pcall(self.write, line)
    end
  end)
end

---Stop the timer (idempotent).
function H:stop()
  if self.timer then
    pcall(self.timer.stop, self.timer)
    pcall(self.timer.close, self.timer)
    self.timer = nil
  end
end

return M
