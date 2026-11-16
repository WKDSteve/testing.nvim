-- TESTS/testing/priority_spec.lua -- a heavy run of the command line lowers its CPU priority (testing.priority):
-- `run`, `ci` and `sheets run` do, the light commands do not, `CI` and `TESTING_PRIORITY=normal` keep it, and a
-- process that already runs lower is never raised.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end

  local priority = require("testing.priority")
  local function env(t)
    return function(name)
      return t[name]
    end
  end

  -- what is heavy
  for _, args in ipairs({
    {},
    { "." },
    { "E:/repos/x", "--file", "a" },
    { "--profile=fast" },
    { "run", "." },
    { "ci", "commit", "HEAD", "--quick" },
    { "ci", "--snapshot" },
    { "sheets", "run", "--all" },
  }) do
    eq(priority.heavy(args), true, "heavy: " .. table.concat(args, " "))
  end
  for _, args in ipairs({
    { "--help" },
    { ".", "--list" },
    { "list", "." },
    { "doctor" },
    { "stats" },
    { "trust", "add", "." },
    { "sheets", "step", "a.sheet.lua" },
    { "sheets", "report" },
    { "call", "status" },
  }) do
    eq(priority.heavy(args), false, "light: " .. table.concat(args, " "))
  end
  eq(
    { priority.command({ "sheets", "--root", "x", "run" }) },
    { "sheets" },
    "an option is no sub-command"
  )

  -- the decision
  eq(
    { priority.decide({ "ci" }, env({})) },
    { priority.BELOW_NORMAL },
    "heavy and no switch: lowered"
  )
  eq({ priority.decide({ "ci" }, env({ CI = "true" })) }, { nil, "CI" }, "never under CI")
  eq(
    { priority.decide({ "ci" }, env({ CI = "false" })) },
    { priority.BELOW_NORMAL },
    "CI=false is no CI"
  )
  eq(
    { priority.decide({ "ci" }, env({ TESTING_PRIORITY = "Normal" })) },
    { nil, "TESTING_PRIORITY" },
    "TESTING_PRIORITY=normal keeps it"
  )
  eq({ priority.decide({ "stats" }, env({})) }, { nil, "light" }, "a light command keeps it")

  -- applying it, with a fake libuv
  local function fake(current, set_result)
    local calls = {}
    return {
      os_getpriority = function(pid)
        calls[#calls + 1] = { "get", pid }
        return current
      end,
      os_setpriority = function(pid, prio)
        calls[#calls + 1] = { "set", pid, prio }
        if set_result == "raise" then
          error("EACCES")
        end
        return set_result
      end,
    },
      calls
  end
  local uv, calls = fake(0, true)
  eq(priority.apply({ "ci" }, env({}), uv), true, "a normal process is lowered")
  eq(calls[2], { "set", 0, priority.BELOW_NORMAL }, "this process, below normal")
  uv, calls = fake(19, true)
  eq(priority.apply({ "ci" }, env({}), uv), false, "an idle process is not raised")
  eq(#calls, 1, "no set call for a process that already runs lower")
  uv = fake(0, "raise")
  eq(priority.apply({ "ci" }, env({}), uv), false, "a refused set is no error")
  uv, calls = fake(0, true)
  eq(priority.apply({ "ci" }, env({ CI = "1" }), uv), false, "under CI nothing is touched")
  eq(#calls, 0, "under CI libuv is not even asked")

  -- the real libuv has both calls, and reads a number for this process
  eq(type(vim.uv.os_getpriority(0)), "number", "vim.uv.os_getpriority answers")
  eq(type(vim.uv.os_setpriority), "function", "vim.uv.os_setpriority exists")
end
