-- TESTS/testing/ci_git_slow_spec.lua -- a git that does not answer in time (a machine at 100 % CPU) is no finding:
-- after a `testing ci` run, a `git rev-parse HEAD` that runs out of its wait is asked once more, longer, and if it
-- still says nothing HEAD is unknown (partial), never "moved"; the runner guard's release of a pushed range says the
-- range could not be read instead of "the range holds a merge commit" when `git rev-list --merges` fails. Driven with a
-- stubbed `vim.system`: the waits it is asked for and the answers are the stub's.

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
  local ci = require("testing.ci")
  local guard = require("testing.ci.runner_guard")
  local SHA = string.rep("a", 40)

  ---Replace `vim.system`: `answer(argv, n)` gives the result of the n-th start of that command (nil: it ran out of
  ---its wait, as `SystemObj:wait` reports a timeout).
  ---@param answer fun(argv: string[], n: integer): table|nil
  local function stub(answer)
    local real = vim.system
    local count, waits = {}, {}
    vim.system = function(argv)
      local key = table.concat(argv, " ")
      count[key] = (count[key] or 0) + 1
      local n = count[key]
      return {
        wait = function(_, ms)
          waits[#waits + 1] = ms
          return answer(argv, n) or { code = 124, signal = 15, stdout = "", stderr = "" }
        end,
      }
    end
    return waits, function()
      vim.system = real
    end
  end

  local function is_rev_parse(argv)
    return argv[2] == "rev-parse"
  end

  -- ---- HEAD read after the run: a slow first answer, then the right one ---------------------------------------
  do
    local waits, restore = stub(function(argv, n)
      if is_rev_parse(argv) and n >= 2 then
        return { code = 0, stdout = SHA .. "\n" }
      end
      return nil
    end)
    local moved, _, unknown = ci._after_facts("/root", { commit = SHA })
    restore()
    ok(moved == false, "a git that answered only on the second, longer wait: HEAD did not move")
    ok(unknown == false, "and HEAD is known")
    ok((waits[2] or 0) > (waits[1] or 0), "the second wait is longer: " .. vim.inspect(waits))
  end

  -- ---- no answer at all: unknown, not moved -----------------------------------------------------------------
  do
    local _, restore = stub(function()
      return nil
    end)
    local moved, _, unknown = ci._after_facts("/root", { commit = SHA })
    restore()
    ok(moved == false, "a git that never answers is not a HEAD that moved")
    ok(unknown == true, "HEAD is unknown")
  end

  -- ---- a HEAD that did move is still found -----------------------------------------------------------------
  do
    local _, restore = stub(function(argv)
      if is_rev_parse(argv) then
        return { code = 0, stdout = string.rep("b", 40) .. "\n" }
      end
      return nil
    end)
    local moved, _, unknown = ci._after_facts("/root", { commit = SHA })
    restore()
    ok(moved == true, "a HEAD that moved is reported")
    ok(unknown == false, "and is known")
  end

  -- ---- the runner guard: a failing `rev-list --merges` is not a merge -------------------------------------------
  do
    local _, restore = stub(function(argv)
      local merges = vim.tbl_contains(argv, "--merges")
      if merges then
        return nil -- ran out of its wait
      end
      return { code = 0, stdout = SHA .. "\n" }
    end)
    local good, why = guard._made_here("/root", SHA, string.rep("c", 40))
    restore()
    eq(good, false, "an unreadable range is not released")
    ok(
      not tostring(why):find("merge", 1, true),
      "and is not called a merge commit: " .. tostring(why)
    )
    ok(
      tostring(why):find("could not be read", 1, true) ~= nil,
      "it says the range could not be read"
    )
  end

  -- ---- the runner guard: a first `rev-list` that runs out of time is not a range missing here ----------------------
  do
    local _, restore = stub(function()
      return nil -- every git call runs out of its wait
    end)
    local good, why = guard._made_here("/root", SHA, string.rep("c", 40))
    restore()
    eq(good, false, "a range git could not read is not released")
    ok(
      not tostring(why):find("fetch first", 1, true),
      "and is not called missing here: " .. tostring(why)
    )
  end
end
