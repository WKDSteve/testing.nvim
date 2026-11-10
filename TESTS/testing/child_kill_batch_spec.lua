-- TESTS/testing/child_kill_batch_spec.lua -- `testing.child` kills the trees of several children from ONE process table
-- (`kill_trees`, also what `kill_all` and the pool use), and `kill_tree_async` does not block the main thread: the
-- request is booked at once, the table and `taskkill` go on in callbacks, and requests of the same tick share one
-- table. Driven on every platform through `child.platform` and a stubbed `vim.system`.

---@diagnostic disable: duplicate-set-field

-- @cache-allow spawn
-- (`vim.system` is replaced by a stub: no process starts)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local child = require("testing.child")

  -- pid, parent pid, creation time (ms): the children 100, 101 and 102 each have one helper below them
  local TABLE = table.concat({
    "100 1 5000",
    "101 1 5001",
    "102 1 5002",
    "200 100 5100",
    "201 101 5101",
    "202 102 5102",
    "",
  }, "\n")

  local function handle(pid)
    return {
      pid = pid,
      ended = false,
      uv_handle = {
        is_closing = function()
          return false
        end,
      },
    }
  end

  ---Replace `vim.system`, `vim.uv.process_kill` and `vim.uv.kill`; returns what was started and a restore function.
  ---@param delay_ms integer How long an asynchronous answer takes.
  local function stub(delay_ms)
    local calls = {}
    local real_system, real_process_kill, real_kill = vim.system, vim.uv.process_kill, vim.uv.kill
    local function answer(argv)
      if argv[1] == "taskkill" then
        return { code = 0, stdout = "", stderr = "" }
      end
      return { code = 0, stdout = TABLE, stderr = "" }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, on_exit)
      calls[#calls + 1] = { argv = argv, async = on_exit ~= nil, at = vim.uv.hrtime() }
      if on_exit then
        vim.defer_fn(function()
          on_exit(answer(argv))
        end, delay_ms)
        return {}
      end
      return {
        wait = function()
          return answer(argv)
        end,
      }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.process_kill = function()
      return 0
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.kill = function()
      return nil, "ESRCH: no such process", "ESRCH" -- every process is gone after `/T`
    end
    local was_windows, was_winproc = child.platform.windows, child.winproc
    -- the PowerShell table and taskkill (the way without the native functions of testing.child.winproc)
    child.platform.windows, child.winproc = true, false
    return calls,
      function()
        child.platform.windows, child.winproc = was_windows, was_winproc
        vim.system, vim.uv.process_kill, vim.uv.kill = real_system, real_process_kill, real_kill
      end
  end

  local function tables_and_kills(calls)
    local reads, kills = 0, {}
    for _, c in ipairs(calls) do
      if c.argv[1] == "taskkill" then
        kills[#kills + 1] = c.argv
      else
        reads = reads + 1
      end
    end
    return reads, kills
  end

  -- ---- several children, one table, one taskkill -------------------------------------------------------------
  do
    local calls, restore = stub(0)
    local hs = { handle(100), handle(101), handle(102) }
    local pok, err = pcall(child.kill_trees, hs)
    restore()
    ok(pok, "kill_trees does not raise: " .. tostring(err))
    local reads, kills = tables_and_kills(calls)
    eq(reads, 1, "three children: the process table is read once")
    eq(#kills, 1, "three children: one taskkill call")
    eq(
      kills[1],
      { "taskkill", "/PID", "100", "/PID", "101", "/PID", "102", "/T", "/F" },
      "all three roots go in that call"
    )
    for _, h in ipairs(hs) do
      ok(h.kill_requested_ms ~= nil, "the request of " .. h.pid .. " is booked")
    end
  end

  -- ---- an ended handle, and a second request on Windows ------------------------------------------------------
  do
    local calls, restore = stub(0)
    local gone, again = handle(100), handle(101)
    gone.ended = true
    again.kill_requested_ms = 1
    child.kill_trees({ gone, again })
    restore()
    eq(
      #calls,
      0,
      "an ended handle and a second request start nothing (only the root is killed again)"
    )
  end

  -- ---- asynchronous: booked at once, nothing waited for, one table for the requests of a tick ---------------
  do
    local calls, restore = stub(300)
    local first, second = handle(100), handle(101)
    local t0 = vim.uv.hrtime()
    child.kill_tree_async(first)
    child.kill_tree_async(second)
    child.kill_tree_async(first) -- the same handle twice is one request
    local spent_ms = (vim.uv.hrtime() - t0) / 1e6
    ok(
      spent_ms < 100,
      ("kill_tree_async returns at once (%.1f ms, the answers take 300 ms)"):format(spent_ms)
    )
    ok(
      first.kill_requested_ms ~= nil and second.kill_requested_ms ~= nil,
      "both requests are booked at once"
    )
    eq(#calls, 0, "nothing is started inside the call (the work is scheduled)")

    -- the main loop stays free while the table and the kill are going on
    local ticks = 0
    local timer = assert(vim.uv.new_timer())
    timer:start(10, 10, function()
      ticks = ticks + 1
    end)
    local done = vim.wait(3000, function()
      local _, kills = tables_and_kills(calls)
      return #kills >= 1
    end, 10)
    timer:stop()
    timer:close()
    restore()
    ok(done, "the table was read and taskkill was called")
    local reads, kills = tables_and_kills(calls)
    eq(reads, 1, "two requests of one tick share one process table")
    eq(kills[1], { "taskkill", "/PID", "100", "/PID", "101", "/T", "/F" }, "and one taskkill call")
    ok(ticks >= 3, ("the main loop kept running while the table was read (%d ticks)"):format(ticks))
    for _, c in ipairs(calls) do
      ok(c.async, "every command of the asynchronous kill is started without waiting")
    end
  end

  -- ---- the editor quits while an asynchronous kill is booked but not carried out -------------------------------
  do
    local calls, restore = stub(0)
    local h = handle(100)
    child.kill_tree_async(h) -- booked; its callbacks would never run if the editor left now
    local before = #calls
    child.kill_trees({ h }) -- what `VimLeavePre` does
    local sync_calls = {}
    for n = before + 1, #calls do
      sync_calls[#sync_calls + 1] = calls[n]
    end
    local _, kills = tables_and_kills(sync_calls)
    restore()
    eq(
      kills[1],
      { "taskkill", "/PID", "100", "/T", "/F" },
      "a waiting kill still takes the whole tree of a handle whose asynchronous kill has not run yet"
    )
    ok(not sync_calls[1].async, "and does it without callbacks")
    vim.wait(100) -- let the scheduled asynchronous chain run into the restored functions
  end

  -- ---- a repeated asynchronous request while the kill goes on adds nothing -----------------------------------
  do
    local calls, restore = stub(200)
    local h = handle(100)
    child.kill_tree_async(h)
    vim.wait(50, function()
      return #calls > 0
    end, 5) -- the process table is out, its answer takes 200 ms
    child.kill_tree_async(h)
    child.kill_tree_async(h)
    vim.wait(1000, function()
      local _, kills = tables_and_kills(calls)
      return #kills >= 1
    end, 10)
    vim.wait(100)
    restore()
    local reads, kills = tables_and_kills(calls)
    eq(reads, 1, "repeated requests while the kill is going on read no second process table")
    eq(#kills, 1, "and start no second taskkill")
  end

  -- ---- an error inside the asynchronous chain does not stop later kills --------------------------------------
  do
    local calls, restore = stub(0)
    local real_alive = child.alive
    child.alive = function()
      error("boom") -- the survivor check is the first thing the callback of `taskkill` does
    end
    local first = handle(100)
    child.kill_tree_async(first)
    vim.wait(3000, function()
      local _, kills = tables_and_kills(calls)
      return #kills >= 1
    end, 10)
    vim.wait(100) -- the failing callback has run
    child.alive = real_alive
    local before = #calls
    local second = handle(101)
    child.kill_tree_async(second)
    local again = vim.wait(3000, function()
      return #calls > before
    end, 10)
    restore()
    ok(again, "after an error in a callback the next asynchronous kill still runs")
  end
end
