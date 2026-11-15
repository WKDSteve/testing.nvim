-- TESTS/testing/watch_support_spec.lua -- the helper of the specs that wait for a file watch (watch_support.lua): a
-- watch that misses the first change (not armed yet, as FSEvents on macOS right after subscribe) still sees the
-- change made again, and a watch that sees nothing ends at the deadline. The watch and the clock are stand-ins.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local W = dofile(
    vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
      .. "/watch_support.lua"
  )

  ---A watch armed only from `armed_at` (ms) on: a change made before that is lost.
  local function scenario(armed_at)
    local clock, events, changes = 0, 0, {}
    local function now()
      return clock
    end
    local function wait(ms, cond)
      if cond() then
        return true
      end
      clock = clock + ms
      return cond()
    end
    local seen, rounds = W.until_seen(function(n)
      changes[#changes + 1] = n
      if armed_at and clock >= armed_at then
        events = events + 1
      end
    end, function()
      return events > 0
    end, { total_ms = 5000, again_ms = 1000, wait = wait, now = now })
    return seen, rounds, changes
  end

  local seen, rounds, changes = scenario(0)
  ok(seen, "an armed watch sees the first change")
  eq({ rounds, changes }, { 1, { 1 } }, "... made once")

  seen, rounds, changes = scenario(1500)
  ok(seen, "a watch that missed the first change sees one made again")
  eq({ rounds, changes }, { 3, { 1, 2, 3 } }, "... each round makes it once more, numbered")

  seen, rounds = scenario(nil)
  ok(not seen, "a watch that sees nothing: not seen")
  eq(rounds, 5, "... after the deadline, one change per round")
end
