-- TESTS/testing/child_kill_frozen_spec.lua -- a POSIX tree kill freezes the root (SIGSTOP) and kills it only after the
-- process table was read. A killer that ends in between must not leave the root stopped for good (it is detached, an
-- orphaned stopped process is never continued, and it once held the WSL mirror lock of every session): the frozen roots
-- are remembered, `kill_all` (the `VimLeavePre` reaper) takes them, and `os.exit` kills them first while one is frozen.
-- Driven with stubs on every platform; on POSIX also with a real killer process that calls `os.exit` in that window.

---@diagnostic disable: duplicate-set-field

-- @cache-allow spawn
-- (the stub part starts nothing; the POSIX part starts a killer editor, which starts `sleep`)
return function(H)
  local ok = H.ok
  local child = require("testing.child")

  ---Stubs for the POSIX way: the process table answers after `delay_ms`, every signal is logged.
  ---@param delay_ms integer
  local function stub(delay_ms)
    local signals = {}
    local real_system, real_process_kill, real_kill = vim.system, vim.uv.process_kill, vim.uv.kill
    vim.system = function(_, _, on_exit)
      if on_exit then
        vim.defer_fn(function()
          on_exit({ code = 0, stdout = "", stderr = "" })
        end, delay_ms)
        return {}
      end
      return {
        wait = function()
          return { code = 0, stdout = "", stderr = "" }
        end,
      }
    end
    vim.uv.process_kill = function(_, sig)
      signals[#signals + 1] = "handle " .. tostring(sig)
      return 0
    end
    vim.uv.kill = function(pid, sig)
      signals[#signals + 1] = ("%d %s"):format(pid, tostring(sig))
      return 0
    end
    local was_windows = child.platform.windows
    child.platform.windows = false
    return signals,
      function()
        child.platform.windows = was_windows
        vim.system, vim.uv.process_kill, vim.uv.kill = real_system, real_process_kill, real_kill
      end
  end

  local function has_signal(signals, want)
    for _, s in ipairs(signals) do
      if s == want then
        return true
      end
    end
    return false
  end

  local function wait_for(signals, want)
    return vim.wait(2000, function()
      return has_signal(signals, want)
    end, 5)
  end

  -- ---- the editor quits (VimLeavePre) while a root that is not a child of ours is frozen ------------------------
  do
    local signals, restore = stub(300)
    -- a process that is not our child (the app of a sheet): no libuv handle, not among the running children
    local h = { pid = 4242, ended = false }
    child.kill_tree_async(h)
    ok(wait_for(signals, "4242 sigstop"), "the asynchronous kill froze the root")
    local before = #signals
    child.kill_all() -- what the `VimLeavePre` reaper does
    local after = {}
    for n = before + 1, #signals do
      after[#after + 1] = signals[n]
    end
    ok(
      has_signal(after, "4242 sigkill"),
      "kill_all kills a frozen root that is not a running child: " .. vim.inspect(after)
    )
    vim.wait(500) -- the asynchronous chain ends into the stubs
    restore()
  end

  -- ---- os.exit while a root is frozen kills it first, and the wrapper goes away with the last frozen root --------
  do
    local signals, restore = stub(300)
    local exited = {}
    local function fake_exit(code)
      exited[#exited + 1] = code
    end
    local real_exit = os.exit
    rawset(os, "exit", fake_exit)
    local h = { pid = 4343, ended = false }
    child.kill_tree_async(h)
    ok(wait_for(signals, "4343 sigstop"), "the asynchronous kill froze the root")
    ok(os.exit ~= fake_exit, "while a root is frozen, os.exit is wrapped")
    local before = #signals
    os.exit(7)
    local at_exit = {}
    for n = before + 1, #signals do
      at_exit[#at_exit + 1] = signals[n]
    end
    ok(
      has_signal(at_exit, "4343 sigkill"),
      "os.exit kills the frozen root before the editor ends: " .. vim.inspect(at_exit)
    )
    ok(exited[1] == 7, "and then calls the os.exit that was in place, with the code")
    -- the chain finishes after the table answered: the wrapper is taken out again
    local back = vim.wait(2000, function()
      return os.exit == fake_exit
    end, 10)
    ok(back, "the os.exit wrapper is taken out once no root is frozen")
    rawset(os, "exit", real_exit)
    restore()
  end

  -- ---- a finished kill leaves nothing behind -------------------------------------------------------------------
  do
    local signals, restore = stub(0)
    local h = { pid = 4444, ended = false }
    local real_exit = os.exit
    child.kill_trees({ h })
    restore()
    ok(has_signal(signals, "4444 sigkill"), "a root without a libuv handle is killed by its number")
    ok(os.exit == real_exit, "a finished kill leaves os.exit as it was")
  end

  -- ---- a real killer ends between SIGSTOP and the table (POSIX) ------------------------------------------------
  if vim.fn.has("win32") == 1 then
    print("n/a  the SIGSTOP window exists on POSIX only")
    return
  end
  local here = debug.getinfo(1, "S").source:sub(2)
  local repo =
    vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p")))))
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/killer.lua"
  local f = assert(io.open(script, "wb"))
  f:write(([[
vim.opt.rtp:prepend(%q)
local child = require("testing.child")
local handle, pid = vim.uv.spawn("sleep", { args = { "60" }, detached = true }, function() end)
io.stdout:write(tostring(pid), "\n")
io.stdout:flush()
child.kill_tree_async({ pid = pid, uv_handle = handle, ended = false })
-- the flush (SIGSTOP, the table started) runs first; the editor ends before the table answers
vim.schedule(function()
  os.exit(0)
end)
]]):format(repo))
  f:close()
  local res = vim
    .system(
      { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script },
      { text = true }
    )
    :wait(30000)
  local pid = tonumber((res.stdout or ""):match("(%d+)"))
  ok(pid ~= nil, "the killer named its root: " .. vim.inspect(res))
  if pid then
    local gone = vim.wait(3000, function()
      return not child.alive(pid)
    end, 20)
    local stat = vim.trim(
      vim.system({ "ps", "-o", "stat=", "-p", tostring(pid) }, { text = true }):wait(5000).stdout
        or ""
    )
    ok(gone, ("the root of a killer that ended in the window is gone (ps stat: %q)"):format(stat))
    if not gone then
      vim.uv.kill(pid, "sigkill") -- our own leftover
    end
  end
  vim.fn.delete(dir, "rf")
end
