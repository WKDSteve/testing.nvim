-- TESTS/testing/timeout_run_guarded_spec.lua -- `timeout.run_guarded(guard, fn)` is the one place both the run path
-- and the list path hand `fn` and `guard:stop()` to the same outer pcall (c919b32, and the matching fix for the list
-- path): the FILE deadline stays armed once it has passed, so the count hook can raise in the few instructions
-- between the end of `fn` and `stop`. Such a raise must come back as `ok = false` from `run_guarded` itself, never
-- escape it, and must never corrupt a result `fn` actually returned.

---@diagnostic disable: need-check-nil

return function(H)
  local ok_, eq = H.ok, H.eq

  local timeout = require("testing.run.timeout")

  -- Locate the window inside `run_guarded` by its own source: from the first line inside the closure that wraps
  -- `fn` through the `guard:stop()` call, both still protected by the outer pcall. Found dynamically, bounded to
  -- this one function's own line range, so a refactor moves the window with the code instead of silently losing it
  -- or picking up an unrelated `guard:stop()` elsewhere in the file.
  local info = debug.getinfo(timeout.run_guarded, "S")
  local mod_source = info.source:gsub("^@", "")
  local lines = {}
  for line in io.lines(mod_source) do
    lines[#lines + 1] = line
  end
  local pcall_line, lower, upper
  for i = info.linedefined, info.lastlinedefined do
    if lines[i]:find("pcall(function()", 1, true) then
      pcall_line = i
      break
    end
  end
  assert(pcall_line, "could not find the outer pcall(function() ... end) in run_guarded")
  lower = pcall_line + 1
  for i = pcall_line, info.lastlinedefined do
    if lines[i]:find("guard:stop()", 1, true) then
      upper = i
      break
    end
  end
  assert(upper and upper >= lower, "could not find guard:stop() after the outer pcall")

  local saved_hook, saved_mask, saved_count = debug.gethook()
  local escaped = {}
  local fired_at, runs = 0, 0
  local LIMIT = 100
  for nth = 1, LIMIT do
    runs = nth
    local seen, fired = 0, false
    debug.sethook(function()
      if fired then
        return
      end
      local hinfo = debug.getinfo(2, "Sl")
      if
        hinfo.source:sub(2) == mod_source
        and hinfo.currentline >= lower
        and hinfo.currentline <= upper
      then
        seen = seen + 1
        if seen == nth then
          fired = true
          error(timeout.MARKER .. " file exceeded 1 ms (from the spec's hook)", 0)
        end
      end
    end, "l")
    local guard = timeout.start({ label = "run_guarded_spec" })
    local fine, call_ok, a, b = pcall(timeout.run_guarded, guard, function()
      return 1, 2
    end)
    debug.sethook(saved_hook, saved_mask or "", saved_count or 0)
    pcall(guard.stop, guard)
    if not fine then
      escaped[#escaped + 1] = ("line %d: escaped run_guarded: %s"):format(nth, tostring(call_ok))
    elseif call_ok and (a ~= 1 or b ~= 2) then
      escaped[#escaped + 1] = ("line %d: fn's own result was lost: %s, %s"):format(
        nth,
        tostring(a),
        tostring(b)
      )
    end
    if not fired then
      break
    end
    fired_at = nth
  end

  eq(
    escaped,
    {},
    "a raise between fn and guard:stop() stays inside run_guarded, and fn's result survives"
  )
  ok_(fired_at >= 1, "the hook reached the window at least once: " .. fired_at)
  ok_(runs < LIMIT, "and the walk ended, every line in the window was tried")
end
