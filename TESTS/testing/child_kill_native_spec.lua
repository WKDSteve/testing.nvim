-- TESTS/testing/child_kill_native_spec.lua -- the Windows tree kill without a process start (`testing.child.winproc`):
-- every process is opened before it is judged (its number stays its own), terminated, and only then asked for its
-- children; a child older than its parent is somebody else's (the parent id names a process whose number was handed
-- out again); a process that cannot be opened is left with everything below it; a process table that cannot be read
-- sends `kill_tree` the slow way (PowerShell and taskkill). Driven with stand-ins on every platform; on Windows also on
-- a real tree (`cmd` and the `ping` it started), which must end without one `powershell` or `taskkill` start.

-- @cache-allow spawn
-- (the stand-in part starts nothing; the Windows part starts cmd, which starts ping)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local winproc = require("testing.child.winproc")
  local child = require("testing.child")

  ---Stand-ins for a process tree: `procs[pid] = { created, parent, open = false (access denied) }`. Every call is logged.
  ---`opts.table_fails`: no table can be read; `opts.table_fails_after = n`: the n-th and later reads fail;
  ---`opts.gone_after_open = pid`: once `pid` was opened, the table no longer names it as anybody's child (it ended
  ---between the first look and the open, and its number went to another process).
  ---@param procs table<integer, { created: integer, parent: integer, open?: boolean }>
  ---@param opts? { table_fails?: boolean, table_fails_after?: integer, gone_after_open?: integer }
  local function fake(procs, opts)
    opts = opts or {}
    local log, handles, reads, opened = {}, {}, 0, {}
    local w = {}
    function w.children(pid)
      log[#log + 1] = "children " .. pid
      reads = reads + 1
      if opts.table_fails or (opts.table_fails_after and reads >= opts.table_fails_after) then
        return nil
      end
      local out = {}
      for p, e in pairs(procs) do
        if e.parent == pid and not (p == opts.gone_after_open and opened[p]) then
          out[#out + 1] = p
        end
      end
      table.sort(out)
      return out
    end
    function w.open(pid)
      log[#log + 1] = "open " .. pid
      local e = procs[pid]
      if not e or e.open == false then
        return nil
      end
      opened[pid] = true
      handles[pid] = (handles[pid] or 0) + 1
      return { pid = pid, created = e.created, handle = pid }
    end
    function w.terminate(p)
      log[#log + 1] = "terminate " .. p.pid
      return true
    end
    function w.wait(p)
      log[#log + 1] = "wait " .. p.pid
    end
    function w.close(p)
      handles[p.pid] = handles[p.pid] - 1
    end
    return w, log, handles
  end

  local function open_handles(handles)
    local n = 0
    for _, c in pairs(handles) do
      n = n + c
    end
    return n
  end

  ---@param log string[]
  ---@param line string
  ---@return boolean
  local function logged(log, line)
    return vim.tbl_contains(log, line)
  end

  -- 100 is the child; 200 and 300 hang below it; 500 names 100 as its parent but is OLDER (its parent ended, the
  -- number went to the child); 600 is a child of 200 that cannot be opened, 700 hangs below 600
  local TREE = {
    [100] = { created = 5000, parent = 1 },
    [200] = { created = 5100, parent = 100 },
    [300] = { created = 5200, parent = 200 },
    [500] = { created = 1000, parent = 100 },
    [600] = { created = 5300, parent = 200, open = false },
    [700] = { created = 5400, parent = 600 },
  }
  local function root(log, result)
    return {
      pid = 100,
      kill = function()
        log[#log + 1] = "root kill 100"
        return result
      end,
    }
  end

  do
    local w, log, handles = fake(TREE)
    local done = winproc.kill_trees(w, { root(log, true) })
    eq(done, true, "the tree was taken natively")
    eq(
      log,
      {
        "children 100",
        "open 100",
        "root kill 100",
        "wait 100",
        "children 100",
        "open 200",
        "children 100",
        "open 500",
        "terminate 200",
        "wait 200",
        "children 200",
        "open 300",
        "children 200",
        "open 600",
        "terminate 300",
        "wait 300",
        "children 300",
      },
      "the table is read first, then each process is opened, ended, waited for and only then asked for its children"
    )
    ok(
      not logged(log, "terminate 500"),
      "500 is older than its parent: not a child of 100, not ended"
    )
    ok(
      not logged(log, "terminate 600") and not logged(log, "open 700"),
      "600 cannot be opened: left alone with what is below it"
    )
    eq(open_handles(handles), 0, "every handle is closed again")
  end

  -- the libuv kill of the root fails: the root is ended through the handle that was opened
  do
    local w, log = fake({ [100] = { created = 5000, parent = 1 } })
    local only = {}
    winproc.kill_trees(w, { root(only, false) })
    eq(
      log,
      { "children 100", "open 100", "terminate 100", "wait 100", "children 100" },
      "a failed root kill: TerminateProcess on the handle"
    )
  end

  -- the root has ended already (it cannot be opened): its libuv kill is all, nothing below it is looked up
  do
    local w, log = fake({})
    local killed = {}
    winproc.kill_trees(w, { root(killed, true) })
    eq(killed, { "root kill 100" }, "the root's own kill still runs")
    eq(
      log,
      { "children 100", "open 100" },
      "no children of a number that may belong to somebody else by now"
    )
  end

  -- a child ended between the first look and the open, and its number went to a stranger: the table no longer names it
  -- as a child of the parent, so it is not ended (its creation time alone would let it through: younger than the parent)
  do
    local w, log, handles = fake(TREE, { gone_after_open = 200 })
    winproc.kill_trees(w, { root(log, true) })
    ok(logged(log, "open 200"), "the number was opened (it is pinned now)")
    ok(not logged(log, "terminate 200"), "but the stranger behind it is not ended")
    ok(not logged(log, "terminate 300"), "nor anything below it")
    eq(open_handles(handles), 0, "and its handle is closed again")
  end

  -- no table at the start: nothing is touched (the caller takes the slow way while the roots still live)
  do
    local w, log = fake(TREE, { table_fails = true })
    local done = winproc.kill_trees(w, { root(log, true) })
    eq(done, false, "no table: not done")
    eq(log, { "children 100" }, "and nothing was opened or killed")
  end

  -- a table that fails later: what is below stays (never a kill of what cannot be identified), and it is still done
  do
    local w, log = fake(TREE, { table_fails_after = 2 })
    local done = winproc.kill_trees(w, { root(log, true) })
    eq(done, true, "the walk began: done, no second way")
    ok(
      logged(log, "root kill 100") and not logged(log, "terminate 200"),
      "the root ended, nothing below it guessed"
    )
  end

  -- through testing.child.kill_tree: native functions answer, no process is started; a table that cannot be read at the
  -- start sends it the slow way (the PowerShell table first); a root whose libuv handle is closing is not looked up
  do
    local function drive(w, closing)
      local started = {}
      local real_system, real_process_kill = vim.system, vim.uv.process_kill
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(argv)
        started[#started + 1] = argv[1]
        return {
          wait = function()
            return { code = 0, stdout = "", stderr = "" }
          end,
        }
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.uv.process_kill = function()
        return 0
      end
      local was_windows, was_winproc = child.platform.windows, child.winproc
      child.platform.windows, child.winproc = true, w
      local handle = {
        pid = 100,
        ended = false,
        uv_handle = {
          is_closing = function()
            return closing == true
          end,
        },
      }
      local pok, err = pcall(child.kill_tree, handle)
      child.platform.windows, child.winproc = was_windows, was_winproc
      vim.system, vim.uv.process_kill = real_system, real_process_kill
      ok(pok, "kill_tree does not raise: " .. tostring(err))
      return started
    end
    local w, log = fake(TREE)
    eq(drive(w), {}, "kill_tree with the native functions starts no process")
    ok(logged(log, "terminate 300"), "and takes the tree")
    local blind = fake(TREE, { table_fails = true })
    eq(
      drive(blind)[1],
      "powershell.exe",
      "a table that cannot be read natively: the PowerShell table after all"
    )
    local wc, logc = fake(TREE)
    eq(drive(wc, true), {}, "a root whose handle is closing: no process started")
    eq(
      logc,
      {},
      "and its number is neither opened nor asked for children (it may be somebody else's by now)"
    )
  end

  -- the real thing (Windows): cmd with ping below it; both end, without a PowerShell or taskkill start
  if require("testing.platform").is_windows() then
    local w = winproc.load()
    ok(w ~= nil, "the native functions load on Windows")
    if w then
      -- `cmd` is no libuv process: what it starts is not in a job object of its own (an editor's children end with
      -- the editor through libuv's job object, so a tree of editors would prove nothing about the walk)
      local outer = vim.system({ "cmd.exe", "/d", "/c", "ping -n 30 127.0.0.1 >NUL" })
      local inner
      vim.wait(15000, function()
        local kids = w.children(outer.pid) or {}
        inner = kids[1]
        return inner ~= nil
      end, 20)
      ok(inner ~= nil, "cmd started ping, and the native table names it as its child")
      local me = w.open(outer.pid)
      ok(me ~= nil and me.created > 0, "a process is opened with its creation time")
      if me then
        w.close(me)
      end
      local started = {}
      local real_system = vim.system
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(argv, ...)
        started[#started + 1] = argv[1]
        return real_system(argv, ...)
      end
      local complete = winproc.kill_trees(w, {
        {
          pid = outer.pid,
          kill = function()
            return false
          end,
        },
      })
      vim.system = real_system
      eq(complete, true, "the tables were read")
      eq(started, {}, "no process was started for the kill")
      local gone = vim.wait(10000, function()
        return not child.alive(outer.pid) and (inner == nil or not child.alive(inner))
      end, 50)
      ok(gone, "cmd and ping have ended")
      outer:wait(5000)
    end
  end
end
