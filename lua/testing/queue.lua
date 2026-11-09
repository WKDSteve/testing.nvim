---@module 'testing.queue'
-- @cache-allow env
-- (`from_env` takes the environment as an argument and is tested with a fake one; the token in `$TESTING_HEAVY_RUN` is
-- the runner's own state and changes nothing a spec sees)
---@brief One heavy run at a time per machine and user: a full suite, `testing ci` with its suite step, `ci commit`.
---@description
--- Two heavy runs at once (two sessions, a review and a fleet roll) make load-sensitive specs time out and cost reruns.
--- The queue is a lock file in the user's temp directory (`<tmp>/testing/heavy-run-<user>.lock`; not
--- `stdpath('state')`, which `scripts/test.sh` points at a throwaway directory), made exclusively
--- (`lib.nvim.fs.create_exclusive`), holding the pid of its holder, a token, the start time and what runs. A second
--- heavy run waits and says once what it waits for; a lock whose pid is gone is taken over.
---
--- Re-entrant: the holder puts its token into `$TESTING_HEAVY_RUN`, so its children (`ci commit` starts `testing ci` on
--- the commit and on the base) are part of its run and never wait for it; inside one process a counter does the same.
---
--- Only the command-line entry (`scripts/testing.lua`) arms the queue (`services.queue`, from `M.from_env`): a spec or an
--- editor that calls `cli.main` as a library never waits for another session's run. A suite run sets
--- `$TESTING_QUEUE=off` for the processes it starts, so a spec that starts `scripts/testing.lua` itself does not queue
--- either. `TESTING_QUEUE=off` turns it off by hand, `TESTING_QUEUE_FILE` names another lock file (specs).
---
--- Light runs never queue: a selected suite (`--file`, `--affected`, ...), a profile without a suite step (the `fast`
--- run of the pre-push hook), `--watch`.

local create_exclusive = require("lib.nvim.fs.create_exclusive")

local uv = vim.uv or vim.loop

local M = {}

---The variable that carries the holder's token to its children.
M.TOKEN_ENV = "TESTING_HEAVY_RUN"
---`off` turns the queue off.
M.OFF_ENV = "TESTING_QUEUE"
---Another lock file (specs).
M.FILE_ENV = "TESTING_QUEUE_FILE"
---How many heavy runs may go at the same time (`1` to `16`).
M.SLOTS_ENV = "TESTING_QUEUE_SLOTS"
---The slots without `$TESTING_QUEUE_SLOTS`.
M.DEFAULT_SLOTS = 1
---How often a waiting run looks again.
M.POLL_MS = 2000
---How long a run waits at most (then it gives up, exit 3).
M.MAX_WAIT_MS = 4 * 60 * 60 * 1000
---Seconds since the epoch, for `started` in the lock (replaced by specs).
M.time = os.time

---@class Testing.Queue
---@field path string The lock file of the first slot (slot n: `<name>-<n>.lock` beside it).
---@field token? string `$TESTING_HEAVY_RUN`: this process is a child of the holder.
---@field off boolean
---@field slots? integer How many heavy runs at the same time (default `M.DEFAULT_SLOTS`).

---@class Testing.Queue.Handle
---@field noop? boolean Nothing was taken (off, a child of the holder, no lock file possible).
---@field held? { token: string, path: string, depth: integer, env_before?: string }

---@class Testing.Queue.AcquireOpts
---@field max_wait_ms? integer
---@field poll_ms? integer
---@field now? fun(): integer The clock in milliseconds; replaced by specs.
---@field sleep? fun(ms: integer) How a waiting run sleeps; replaced by specs.

---@type { token: string, path: string, depth: integer, env_before?: string }|nil
local held = nil

---The default lock file.
---@return string
function M.default_path()
  local ok, pw = pcall(uv.os_get_passwd)
  local user = ok and type(pw) == "table" and pw.username
    or os.getenv("USERNAME")
    or os.getenv("USER")
    or "user"
  user = tostring(user):gsub("[^%w_.%-]", "_")
  return vim.fs.normalize(uv.os_tmpdir()) .. "/testing/heavy-run-" .. user .. ".lock"
end

---The queue of the command-line entry.
---@param getenv? fun(name: string): string|nil
---@return Testing.Queue
function M.from_env(getenv)
  getenv = getenv or os.getenv
  local file = getenv(M.FILE_ENV)
  local token = getenv(M.TOKEN_ENV)
  local slots = tonumber(getenv(M.SLOTS_ENV) or "")
  if not slots or slots ~= math.floor(slots) or slots < 1 or slots > 16 then
    slots = M.DEFAULT_SLOTS
  end
  return {
    path = (file and file ~= "") and file or M.default_path(),
    token = (token and token ~= "") and token or nil,
    off = getenv(M.OFF_ENV) == "off",
    slots = slots,
  }
end

---The lock file of slot `n` (slot 1 is `path` itself).
---@param path string
---@param n integer
---@return string
function M.slot_path(path, n)
  if n == 1 then
    return path
  end
  return (path:gsub("%.lock$", "")) .. "-" .. n .. ".lock"
end

---Is the process alive? (A process of another user answers EPERM: alive.)
---@param pid integer
---@return boolean
function M.alive(pid)
  local ok, err = uv.kill(pid, 0)
  if ok == 0 then
    return true
  end
  return type(err) == "string" and err:find("EPERM", 1, true) ~= nil
end

---@param path string
---@return table|nil doc
---@return string|nil text
local function read_lock(path)
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, nil
  end
  local ok, doc = pcall(vim.json.decode, text)
  return ok and type(doc) == "table" and doc or nil, text
end

---Take the queue for a heavy run, waiting while another one holds it.
---@param q Testing.Queue|nil nil: no queue (a library call).
---@param what string What runs (said to whoever waits).
---@param say fun(s: string)
---@param opts? Testing.Queue.AcquireOpts
---@return Testing.Queue.Handle|nil handle
---@return string|nil problem The wait was too long.
function M.acquire(q, what, say, opts)
  opts = opts or {}
  if not q or q.off then
    return { noop = true }
  end
  if held then
    held.depth = held.depth + 1
    return { held = held }
  end
  if q.token then
    -- a child of the holder (or of a run that ended: then nobody holds it and nothing is lost)
    return { noop = true }
  end
  local now = opts.now or function()
    return math.floor(uv.hrtime() / 1e6)
  end
  local sleep = opts.sleep or function(ms)
    vim.wait(ms)
  end
  local pid = uv.os_getpid()
  local token = ("%d-%d-%d"):format(pid, os.time(), math.floor(uv.hrtime() % 1e9))
  local deadline = now() + (opts.max_wait_ms or M.MAX_WAIT_MS)
  local slots = q.slots or M.DEFAULT_SLOTS
  local waited = false

  ---Try slot `n`: "taken", "busy" (with the holder's lock), or "broken" (no lock file can be made there).
  ---@return "taken"|"busy"|"broken" what
  ---@return table|string|nil detail
  local function try(n)
    local path = M.slot_path(q.path, n)
    for _ = 1, 2 do
      -- `started` is when the run gets the lock, not when it began to wait: a waiter reads it as "running for N s"
      local body = vim.json.encode({ pid = pid, token = token, started = M.time(), what = what })
        .. "\n"
      local ok, err = create_exclusive(path, body)
      if ok then
        held = { token = token, path = path, depth = 1, env_before = vim.env[M.TOKEN_ENV] }
        vim.env[M.TOKEN_ENV] = token
        return "taken"
      end
      if not create_exclusive.is_exists(err) then
        return "broken", tostring(err)
      end
      local cur, text = read_lock(path)
      local holder = cur and type(cur.pid) == "number" and math.floor(cur.pid) or nil
      if not (text and (not holder or holder == pid or not M.alive(holder))) then
        return "busy", cur or {}
      end
      -- a holder that is gone (or a file nobody can read as a lock): taken over, unless it changed meanwhile
      local again = select(2, read_lock(path))
      if again ~= text then
        return "busy", cur or {}
      end
      say(
        ("testing: queue: the lock of pid %s is left over (the process is gone): taken over"):format(
          tostring(cur and cur.pid or "?")
        )
      )
      os.remove(path)
    end
    return "busy", {}
  end

  while true do
    local busy = {}
    for n = 1, slots do
      local state, detail = try(n)
      if state == "taken" then
        if waited then
          say("testing: queue: your turn, " .. what .. " starts")
        end
        return { held = held }
      elseif state == "broken" then
        -- a temp directory that refuses the file: run, and say that nothing was queued
        say(("testing: queue: no lock file (%s): %s runs without waiting"):format(detail, what))
        return { noop = true }
      end
      busy[#busy + 1] = detail
    end
    local cur = busy[1] or {}
    if now() >= deadline then
      return nil,
        ("waited %d min for %s (pid %s): given up"):format(
          math.floor((opts.max_wait_ms or M.MAX_WAIT_MS) / 60000),
          tostring(cur.what or "another run"),
          tostring(cur.pid)
        )
    end
    if not waited then
      waited = true
      local since = tonumber(cur.started)
      say(
        ("testing: queue: waiting for %s (pid %s%s)%s: %d heavy run(s) at a time on this machine"):format(
          tostring(cur.what or "another heavy run"),
          tostring(cur.pid),
          since and (", for %d s"):format(math.max(0, os.time() - since)) or "",
          #busy > 1 and (" and %d more"):format(#busy - 1) or "",
          slots
        )
      )
    end
    sleep(opts.poll_ms or M.POLL_MS)
  end
end

---Give the queue back (the last release of this process removes the lock, when it is still ours).
---@param h Testing.Queue.Handle|nil
function M.release(h)
  local mine = held
  if not h or not h.held or not mine or mine ~= h.held then
    return
  end
  mine.depth = mine.depth - 1
  if mine.depth > 0 then
    return
  end
  local cur = read_lock(mine.path)
  if cur and cur.token == mine.token then
    os.remove(mine.path)
  end
  vim.env[M.TOKEN_ENV] = mine.env_before
  held = nil
end

---Run `fn` with `$TESTING_QUEUE=off` for the processes it starts (a suite: its specs never queue), restored after.
---@generic T
---@param fn fun(): T
---@return T
function M.quiet_children(fn)
  local before = vim.env[M.OFF_ENV]
  vim.env[M.OFF_ENV] = "off"
  local ok, res = pcall(fn)
  vim.env[M.OFF_ENV] = before
  if not ok then
    error(res, 0)
  end
  return res
end

return M
