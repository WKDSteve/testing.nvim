-- TESTS/testing/queue_spec.lua -- one heavy run at a time per machine (testing.queue): a second one waits and says
-- for what, a lock whose process is gone is taken over, the holder's children and nested calls never wait for it, a
-- light run (a selected suite, a run without the suite step) never queues, and a library call without the entry's
-- queue never touches the lock.

---@diagnostic disable: need-check-nil, missing-fields

-- The lock files are in a temp folder of this spec; the holder that is alive is this process's parent.
return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end

  -- a fresh module: the run that hosts this spec may hold the real queue in this very process
  local saved_mod = package.loaded["testing.queue"]
  package.loaded["testing.queue"] = nil
  local queue = require("testing.queue")
  local saved_env = { token = vim.env[queue.TOKEN_ENV], off = vim.env[queue.OFF_ENV] }
  vim.env[queue.TOKEN_ENV] = nil

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-queue"
  vim.fn.mkdir(tmp, "p")
  local lock = tmp .. "/heavy.lock"
  local function q(extra)
    return vim.tbl_extend("force", { path = lock, off = false }, extra or {})
  end
  local function read()
    local f = io.open(lock, "rb")
    if not f then
      return nil
    end
    local doc = vim.json.decode(f:read("*a"))
    f:close()
    return doc
  end
  local function write_lock(doc)
    local f = assert(io.open(lock, "wb"))
    f:write(vim.json.encode(doc))
    f:close()
  end
  local said = {}
  local function say(s)
    said[#said + 1] = s
  end

  -- the entry's queue
  local from = queue.from_env(function(name)
    return ({ TESTING_QUEUE = "off", TESTING_HEAVY_RUN = "tok", TESTING_QUEUE_FILE = "/x.lock" })[name]
  end)
  eq(from, { path = "/x.lock", token = "tok", off = true }, "from_env: the three variables")
  has(
    queue.from_env(function() end).path,
    "/testing/heavy-run-",
    "from_env: the default file in temp"
  )

  -- take, nest, give back
  local h = queue.acquire(q(), "suite A", say)
  ok(h and h.held, "acquire: taken")
  eq(read().what, "suite A", "acquire: the lock names the run")
  eq(read().pid, vim.uv.os_getpid(), "acquire: ... and its pid")
  eq(vim.env[queue.TOKEN_ENV], read().token, "acquire: the token goes to the children")
  local nested = queue.acquire(q(), "ci in the same process", say)
  ok(nested and nested.held == h.held, "acquire: a nested call shares the hold")
  queue.release(nested)
  ok(read() ~= nil, "release: the nested release keeps the lock")
  queue.release(h)
  eq(read(), nil, "release: the last release removes it")
  eq(vim.env[queue.TOKEN_ENV], nil, "release: and the token")
  eq(#said, 0, "nothing to say without a wait")

  -- off, and a child of the holder
  eq(queue.acquire(q({ off = true }), "x", say), { noop = true }, "off: nothing taken")
  eq(
    queue.acquire(q({ token = "t" }), "x", say),
    { noop = true },
    "a child of the holder does not wait"
  )
  eq(queue.acquire(nil, "x", say), { noop = true }, "a library call (no queue) does not wait")
  eq(read(), nil, "... and none of them made a lock")

  -- a holder that is alive: wait, say so once, go when it is gone
  local parent = vim.uv.os_getppid()
  write_lock({
    pid = parent,
    token = "other",
    started = os.time() - 30,
    what = "ci commit of 3 commit(s) in x",
  })
  local slept = 0
  local saved_time, clock_s = queue.time, 7000
  queue.time = function()
    return clock_s
  end
  h = queue.acquire(q(), "suite B", say, {
    poll_ms = 1,
    sleep = function()
      slept = slept + 1
      clock_s = clock_s + 1
      if slept == 3 then
        os.remove(lock) -- the other run ends
      end
    end,
  })
  queue.time = saved_time
  ok(h and h.held, "wait: taken after the other run ended")
  eq(slept, 3, "wait: it waited until then")
  eq(read().started, 7003, "wait: started is when the lock was taken, not when the wait began")
  has(said[1], "waiting for ci commit of 3 commit(s) in x", "wait: says what it waits for")
  has(said[1], "pid " .. parent, "wait: ... and the holder")
  eq(#vim.tbl_filter(function(s)
    return s:find("waiting for", 1, true) ~= nil
  end, said), 1, "wait: once, not on every look")
  has(said[#said], "your turn", "wait: says when it starts")
  queue.release(h)

  -- a holder that is gone: taken over
  said = {}
  write_lock({ pid = 2147480000, token = "dead", started = os.time() - 3600, what = "old" })
  h = queue.acquire(q(), "suite C", say, { max_wait_ms = 200, poll_ms = 20 })
  ok(h and h.held, "stale: taken over")
  has(said[1], "left over", "stale: says so")
  eq(read().what, "suite C", "stale: the lock is now this run's")
  queue.release(h)
  write_lock({ garbage = true })
  h = queue.acquire(q(), "suite D", say, { max_wait_ms = 200, poll_ms = 20 })
  ok(h and h.held, "stale: a file that is no lock is taken over too")
  queue.release(h)

  -- waiting has an end
  write_lock({ pid = parent, token = "other", started = os.time(), what = "the long one" })
  local clock = 0
  local none, why = queue.acquire(q(), "suite E", say, {
    max_wait_ms = 100,
    poll_ms = 50,
    now = function()
      return clock
    end,
    sleep = function(ms)
      clock = clock + ms
    end,
  })
  eq(none, nil, "deadline: no handle")
  has(why, "given up", "deadline: says so")
  has(why, "the long one", "deadline: ... and for what")
  eq(read().token, "other", "deadline: the other run's lock stays")

  -- a release never removes the lock of a successor (one that took over meanwhile)
  os.remove(lock)
  h = queue.acquire(q(), "suite F", say)
  write_lock({ pid = parent, token = "successor", started = os.time(), what = "next" })
  queue.release(h)
  eq(read().token, "successor", "release: the successor's lock stays")
  os.remove(lock)

  -- the processes a suite starts never queue
  vim.env[queue.OFF_ENV] = nil
  local inside = queue.quiet_children(function()
    return vim.env[queue.OFF_ENV]
  end)
  eq(inside, "off", "quiet_children: off while the suite runs")
  eq(vim.env[queue.OFF_ENV], nil, "quiet_children: restored after")

  -- the wiring: a whole suite waits, a selected one does not; a `testing ci` with the suite waits, with a selected
  -- suite not. MAX_WAIT_MS = 0: a run that would wait ends at once with exit 3 and says why.
  local proj = tmp .. "/proj"
  local function put(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  put(proj .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  -- a Lua project: `testing ci` derives its pipeline (the suite step among it)
  put(proj .. "/lua/proj/init.lua", "return {}\n")
  put(
    proj .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  write_lock({
    pid = parent,
    token = "other",
    started = os.time(),
    what = "another session's suite",
  })
  local saved_max = queue.MAX_WAIT_MS
  queue.MAX_WAIT_MS = 0
  local cli = require("testing.cli")
  local function main(argv)
    local lines = {}
    local function sink(s)
      lines[#lines + 1] = tostring(s)
    end
    local code = cli.main(argv, {
      out = sink,
      err = sink,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      queue = q(),
      affected = { getenv = function() end, provider = false },
    })
    return code, table.concat(lines, "\n")
  end
  local code, text = main({ proj, "--no-cache" })
  eq(code, 3, "wiring: the whole suite waits (and gives up at once here)")
  has(text, "another session's suite", "wiring: ... and names what it waited for")
  code, text = main({ proj, "--no-cache", "--file", "TESTS/a_spec.lua" })
  eq(code, 0, "wiring: a selected suite does not wait (" .. text:sub(1, 300) .. ")")
  code, text = main({ "ci", "--root=" .. proj, "--step=suite", "--no-agent" })
  eq(code, 3, "wiring: testing ci with the whole suite waits")
  has(text, "queue:", "wiring: ... and says so")
  code, text = main({
    "ci",
    "--root=" .. proj,
    "--step=suite",
    "--no-agent",
    "--",
    "--file",
    "TESTS/a_spec.lua",
  })
  ok(
    code ~= 3,
    "wiring: testing ci with a selected suite does not wait (exit "
      .. code
      .. ": "
      .. text:sub(1, 300)
      .. ")"
  )
  eq(read().token, "other", "wiring: the other session's lock is untouched")
  queue.MAX_WAIT_MS = saved_max

  vim.env[queue.TOKEN_ENV], vim.env[queue.OFF_ENV] = saved_env.token, saved_env.off
  package.loaded["testing.queue"] = saved_mod
  vim.fn.delete(tmp, "rf")
end
