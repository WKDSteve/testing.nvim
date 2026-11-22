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
  eq(
    from,
    { path = "/x.lock", token = "tok", off = true, slots = queue.DEFAULT_SLOTS },
    "from_env: the variables"
  )
  for value, want in pairs({ ["3"] = 3, ["0"] = queue.DEFAULT_SLOTS, ["x"] = queue.DEFAULT_SLOTS }) do
    eq(
      queue.from_env(function(name)
        return name == "TESTING_QUEUE_SLOTS" and value or nil
      end).slots,
      want,
      "from_env: TESTING_QUEUE_SLOTS=" .. value
    )
  end
  eq(queue.slot_path("/t/q.lock", 1), "/t/q.lock", "slot 1 is the file itself")
  eq(queue.slot_path("/t/q.lock", 2), "/t/q-2.lock", "slot 2 beside it")
  has(
    queue.from_env(function() end).path,
    "/testing/heavy-run-",
    "from_env: the default file in temp"
  )

  -- a CI job (`CI=true`) queues in a lane of its own, never behind a local run; an explicit file stays as it is
  local ci_env = function(extra)
    return function(name)
      return extra[name] or (name == "CI" and "true" or nil)
    end
  end
  local local_path = queue.from_env(function() end).path
  eq(
    queue.from_env(ci_env({})).path,
    (local_path:gsub("%.lock$", "")) .. "-ci.lock",
    "from_env: CI=true has a lane of its own"
  )
  eq(
    queue.from_env(ci_env({ TESTING_QUEUE_FILE = "/x.lock" })).path,
    "/x.lock",
    "from_env: an explicit file wins"
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

  -- fair: a free slot goes to the oldest live waiter, not to whoever looks first (terminal.nvim waited an hour on
  -- 2026-11-14 while later runs went through)
  do
    local dir = queue.waiting_dir(lock)
    local function tickets()
      local out = {}
      for name in vim.fs.dir(dir) do
        out[#out + 1] = name
      end
      table.sort(out)
      return out
    end
    local function ticket(name, doc)
      vim.fn.mkdir(dir, "p")
      local f = assert(io.open(dir .. "/" .. name, "wb"))
      f:write(vim.json.encode(doc))
      f:close()
    end
    local saved_clock = queue.clock_ms
    queue.clock_ms = function()
      return 2000
    end
    said = {}
    write_lock({ pid = parent, token = "holder", started = os.time(), what = "the holder" })
    -- an earlier waiter (alive), and one whose process is gone
    ticket("000000000001000-earlier.json", { pid = parent, token = "earlier", what = "earlier" })
    ticket("000000000000500-dead.json", { pid = 2147480000, token = "dead", what = "dead" })
    local looks = 0
    h = queue.acquire(q(), "suite F", say, {
      poll_ms = 1,
      sleep = function()
        looks = looks + 1
        if looks == 1 then
          eq(
            #tickets(),
            2,
            "fair: the dead ticket is gone, this run's is there beside the earlier one"
          )
        elseif looks == 2 then
          os.remove(lock) -- the holder ends; the earlier waiter has not looked yet
        elseif looks == 3 then
          -- the earlier waiter takes its turn and leaves the line
          write_lock({ pid = parent, token = "earlier", started = os.time(), what = "earlier" })
          os.remove(dir .. "/000000000001000-earlier.json")
        elseif looks == 5 then
          os.remove(lock)
        end
      end,
    })
    ok(h and h.held, "fair: taken in the end")
    eq(looks, 5, "fair: a free slot with an earlier live waiter is left to it")
    eq(read().what, "suite F", "fair: ... then the lock is this run's")
    has(said[1], "1 run(s) waiting before this one", "fair: says how many wait before it")
    eq(tickets(), {}, "fair: the ticket is gone once the run has its turn")
    queue.release(h)

    -- a newcomer finds the slot free but a live waiter in the line: it waits too (and gives up here), without a
    -- ticket left behind
    ticket("000000000001000-earlier.json", { pid = parent, token = "earlier", what = "earlier" })
    local clk = 0
    local late, late_why = queue.acquire(q(), "suite G", say, {
      max_wait_ms = 100,
      poll_ms = 50,
      now = function()
        return clk
      end,
      sleep = function(ms)
        clk = clk + ms
      end,
    })
    eq(late, nil, "fair: a newcomer does not overtake a waiting run")
    has(late_why, "given up", "fair: ... and gives up at its deadline")
    eq(tickets(), { "000000000001000-earlier.json" }, "fair: the newcomer's ticket goes with it")

    -- a ticket older than any wait can be is a crashed run's whose pid another process has now: it holds nobody
    os.remove(dir .. "/000000000001000-earlier.json")
    ticket("000000000000900-reused.json", {
      pid = parent,
      token = "reused",
      what = "crashed long ago",
      since = os.time() - math.floor(queue.MAX_WAIT_MS / 1000) - 7200,
    })
    local fresh_h = queue.acquire(q(), "suite H", say, { max_wait_ms = 100, poll_ms = 50 })
    ok(fresh_h and fresh_h.held, "fair: an expired ticket of a live pid does not hold the line")
    eq(tickets(), {}, "fair: ... and is removed")
    queue.release(fresh_h)
    vim.fn.delete(dir, "rf")
    queue.clock_ms = saved_clock
  end

  -- two slots: a second run goes at once while the first one runs; a third waits for either
  said = {}
  write_lock({ pid = parent, token = "other", started = os.time(), what = "first" })
  local two = queue.acquire(q({ slots = 2 }), "second", say, { max_wait_ms = 200, poll_ms = 20 })
  ok(two and two.held, "two slots: the second run goes at once")
  eq(two and two.held.path, queue.slot_path(lock, 2), "two slots: ... in slot 2")
  eq(#said, 0, "two slots: without a wait")
  queue.release(two)
  eq(io.open(queue.slot_path(lock, 2)) == nil, true, "two slots: the release removes slot 2")
  local f2 = assert(io.open(queue.slot_path(lock, 2), "wb"))
  f2:write(vim.json.encode({ pid = parent, token = "o2", started = os.time(), what = "second" }))
  f2:close()
  local clk = 0
  local third, third_why = queue.acquire(q({ slots = 2 }), "third", say, {
    max_wait_ms = 100,
    poll_ms = 50,
    now = function()
      return clk
    end,
    sleep = function(ms)
      clk = clk + ms
    end,
  })
  eq(third, nil, "two slots full: the third waits (and gives up here)")
  has(third_why, "first", "two slots full: ... names a holder")
  has(said[1] or "", "and 1 more", "two slots full: ... and that there is one more")
  os.remove(queue.slot_path(lock, 2))
  os.remove(lock)

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
