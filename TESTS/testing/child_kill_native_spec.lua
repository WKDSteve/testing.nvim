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
  ---@param procs table<integer, { created: integer, parent: integer, open?: boolean }>
  ---@param opts? { table_fails?: boolean }
  local function fake(procs, opts)
    opts = opts or {}
    local log, handles = {}, {}
    local w = {}
    function w.children(pid)
      log[#log + 1] = "children " .. pid
      if opts.table_fails then
        return nil
      end
      local out = {}
      for p, e in pairs(procs) do
        if e.parent == pid then
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
      handles[pid] = (handles[pid] or 0) + 1
      return { pid = pid, created = e.created, handle = pid }
    end
    function w.terminate(p)
      log[#log + 1] = "terminate " .. p.pid
      return true
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

  do
    local w, log, handles = fake(TREE)
    local root_kills = 0
    local complete = winproc.kill_trees(w, {
      {
        pid = 100,
        kill = function()
          root_kills = root_kills + 1
          log[#log + 1] = "root kill 100"
          return true
        end,
      },
    })
    eq(complete, true, "every table was read")
    eq(root_kills, 1, "the root is ended by its own (libuv) handle, once")
    eq(log, {
      "open 100",
      "root kill 100",
      "children 100",
      "open 200",
      "open 500",
      "terminate 200",
      "children 200",
      "open 300",
      "open 600",
      "terminate 300",
      "children 300",
    }, "each process is opened, ended, and only then asked for its children")
    for _, line in ipairs(log) do
      ok(line ~= "terminate 500", "500 is older than its parent: not a child of 100, not ended")
      ok(
        line ~= "terminate 600" and line ~= "open 700",
        "600 cannot be opened: left alone with what is below it"
      )
    end
    eq(open_handles(handles), 0, "every handle is closed again")
  end

  -- the libuv kill of the root fails: the root is ended through the handle that was opened
  do
    local w, log = fake({ [100] = { created = 5000, parent = 1 } })
    winproc.kill_trees(w, {
      {
        pid = 100,
        kill = function()
          return false
        end,
      },
    })
    eq(
      log,
      { "open 100", "terminate 100", "children 100" },
      "a failed root kill: TerminateProcess on the handle"
    )
  end

  -- the root has ended already (it cannot be opened): its libuv kill is all, nothing is looked up by its number
  do
    local w, log = fake({})
    local killed = false
    winproc.kill_trees(w, {
      {
        pid = 100,
        kill = function()
          killed = true
          return true
        end,
      },
    })
    eq(killed, true, "the root's own kill still runs")
    eq(log, { "open 100" }, "no children of a number that may belong to somebody else by now")
  end

  -- through testing.child.kill_tree: native functions answer, no process is started; a table that cannot be read
  -- sends it the slow way (the PowerShell table first)
  do
    local function drive(w)
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
            return false
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
    ok(vim.tbl_contains(log, "terminate 300"), "and takes the tree")
    local blind = fake(TREE, { table_fails = true })
    eq(
      drive(blind)[1],
      "powershell.exe",
      "a table that cannot be read natively: the PowerShell table after all"
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
