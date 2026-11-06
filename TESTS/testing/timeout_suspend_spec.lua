-- TESTS/testing/timeout_suspend_spec.lua -- `Guard:suspend`: the runner's own bookkeeping after a case (what the guard layer checks)
-- is not cut off by the deadline the spec has just exceeded; the deadline is still there afterwards.

return function(H)
  local ok, eq = H.ok, H.eq
  local timeout = require("testing.run.timeout")

  local function busy()
    local x = 0
    for i = 1, 20000 do
      x = x + i
    end
    return x
  end

  -- A clock of our own: the deadline passes when WE say so, not when a loaded machine stalls the spec for 30 ms.
  -- Time has passed only INSIDE a suspend or a pcall. Outside of them the count hook may fire at any instruction,
  -- and a deadline that has passed there kills the spec itself, with this guard still running ("a timeout guard
  -- outlived the run"). Where the hook falls depends on what ran before, so that was a failure of full runs only.
  local now = 0
  local g = timeout.start({
    label = "suspend",
    file_ms = 30,
    clock = function()
      return now
    end,
  })
  -- the hook on every instruction: any spot the deadline is passed unprotected fails every run, not one in a hundred
  local hook, mask, count = debug.gethook()
  debug.sethook(hook, mask, 1)

  local worked, a, b = pcall(g.suspend, g, function()
    now = 80 -- the deadline has passed
    local result = busy()
    now = 0
    return result, "second"
  end)

  local failed, err = pcall(g.suspend, g, function()
    now = 80
    now = 0
    error("boom", 0)
  end)

  -- the deadline is persistent: the spec is stopped again as soon as the bookkeeping is over
  local stopped_it, message = xpcall(function()
    now = 80
    busy()
  end, function(e)
    now = 0 -- back to before the deadline, in the handler: no hook can fire between the raise and here
    return e
  end)

  debug.sethook(hook, mask, count)

  ok(worked, "suspended work is not stopped by the passed deadline: " .. tostring(a))
  ok(type(a) == "number" and b == "second", "suspend returns the results of the function")
  ok(not failed and err == "boom", "an error of the function is raised again")
  ok(not stopped_it, "the deadline stops the spec again after suspend")
  ok(timeout.is_timeout(message), "...with the timeout error: " .. tostring(message))
  eq(g:stop(), true, "the file deadline is reported as fired")
  eq(g:stop(), true, "stop is idempotent")

  -- a guard that was stopped inside suspend does not get its deadlines back
  local g2 = timeout.start({ label = "stopped inside", file_ms = 100000 })
  g2:suspend(function()
    g2:stop()
  end)
  ok(g2.file_deadline == nil and g2.stopped, "a guard stopped inside suspend stays stopped")
end
