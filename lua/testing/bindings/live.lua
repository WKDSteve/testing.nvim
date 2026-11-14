---@module 'testing.bindings.live'
---@brief A run started from the editor, followed while it goes: its event file read as it grows.
---@description
--- `testing.bindings.child` asks `begin(root)` before it starts a run. While somebody listens (`listen`, a tree
--- that shows results), the answer is a file in the state folder of the project; the child gets it as
--- `--events=<file>` and writes one line per case (`testing.run.events`). A timer reads what was added since the
--- last look, `testing.run.events_reader` turns the bytes into validated events, and every listener gets them in
--- batches: `fn(root, events)`.
---
--- Nobody listening: `begin` answers nil, the run gets no `--events`, there is no file, no reader and no timer.
--- The run over (`finish`): the rest of the file is read, a stream without an end gets one from the reader
--- (`run_done`, `aborted`), the timer is closed and the file removed.
---
--- The file is untrusted like every result file: bounded lines, validated fields, never used as a path
--- (`events_reader`). It is a convenience: a file that cannot be opened or read means no live view, and the
--- result of the run shows when it has ended, as without this module.

local M = {}

---How often the event file of a run is read (ms).
M.POLL_MS = 100
---Most bytes read from the event file in one look.
M.CHUNK = 256 * 1024
---Event files older than this are leftovers of an editor that died during a run (seconds).
M.LEFTOVER_S = 24 * 60 * 60

local uv = vim.uv or vim.loop

---@type (fun(root: string, events: table[]))[]
local listeners = {}
---@type table<table, true>  the runs that are followed right now
local runs = {}
local serial = 0

---Get the events of every run started from this editor: `fn(root, events)`, a batch per look at the file.
---@param fn fun(root: string, events: table[])
---@return fun() unlisten
function M.listen(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do
      if f == fn then
        table.remove(listeners, i)
        return
      end
    end
  end
end

---Whether anybody listens.
---@return boolean
function M.wanted()
  return #listeners > 0
end

---How many runs are followed right now (their timers are the handles this module holds).
---@return integer
function M.active()
  return vim.tbl_count(runs)
end

---@param root string
---@param events table[]
local function deliver(root, events)
  if #events == 0 then
    return
  end
  for _, fn in ipairs(vim.list_slice(listeners)) do
    pcall(fn, root, events)
  end
end

---The folder the event files of a project are written to: a folder of its own below the state folder, so a
---watch on the state folder (the result file) is not woken by every case.
---@param root string
---@param opts? Testing.State.Opts
---@return string
function M.dir(root, opts)
  return require("testing.state").dir(root, opts) .. "/live"
end

---Remove what an editor left that died during a run.
---@param dir string
local function sweep(dir)
  local now = os.time()
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("^events%-%d+%-%d+%.ndjson$") then
      local stat = uv.fs_stat(dir .. "/" .. name)
      if stat and now - stat.mtime.sec > M.LEFTOVER_S then
        pcall(os.remove, dir .. "/" .. name)
      end
    end
  end
end

---@class Testing.Live.Run
---@field path string  The event file: what the child gets as `--events`.
---@field root string
---@field finish fun(exit_code?: integer)  The process has ended: read the rest, end the stream, release everything.

---Follow the run that is about to start. nil when nobody listens or the file cannot be made.
---@param root string
---@param opts? { state_opts?: Testing.State.Opts, poll_ms?: integer }
---@return Testing.Live.Run|nil
function M.begin(root, opts)
  if not M.wanted() then
    return nil
  end
  opts = opts or {}
  local dir = M.dir(root, opts.state_opts)
  if vim.fn.mkdir(dir, "p") == 0 and not uv.fs_stat(dir) then
    return nil
  end
  pcall(sweep, dir)
  serial = serial + 1
  local path = ("%s/events-%d-%d.ndjson"):format(dir, uv.os_getpid(), serial)
  -- the file exists before the child opens it: a look before its first line finds an empty file, not none
  local made = io.open(path, "wb")
  if not made then
    return nil
  end
  made:close()

  local batch = {}
  local reader = require("testing.run.events_reader").new({
    on_event = function(ev)
      batch[#batch + 1] = ev
    end,
  })
  local offset = 0
  ---Read what the file gained since the last look.
  local function look()
    local fd = uv.fs_open(path, "r", 438)
    if not fd then
      return
    end
    while true do
      local chunk = uv.fs_read(fd, M.CHUNK, offset)
      if not chunk or chunk == "" then
        break
      end
      offset = offset + #chunk
      reader:feed(chunk)
      if #chunk < M.CHUNK then
        break
      end
    end
    uv.fs_close(fd)
  end
  local function flush()
    local events = batch
    batch = {}
    deliver(root, events)
  end

  local run = { path = path, root = root }
  local timer = uv.new_timer()
  local over = false
  runs[run] = true
  if timer then
    timer:start(
      opts.poll_ms or M.POLL_MS,
      opts.poll_ms or M.POLL_MS,
      vim.schedule_wrap(function()
        if over then
          return
        end
        pcall(look)
        flush()
      end)
    )
  end
  function run.finish(exit_code)
    if over then
      return
    end
    over = true
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
    runs[run] = nil
    pcall(look)
    reader:finish(exit_code)
    flush()
    pcall(os.remove, path)
  end
  return run
end

return M
