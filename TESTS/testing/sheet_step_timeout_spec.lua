-- TESTS/testing/sheet_step_timeout_spec.lua -- the RPC limit of an rpc sheet's steps. A `lua` step whose code computes
-- before it returns (`:checkhealth` in testing.commands: 7 s alone) gets `timeout` as the limit of that one call, and
-- a poll of a `wait` may take as long as the wait itself: a child still busy with the step before answers it only
-- then. The spec lowers the RPC limit to 500 ms, so a call of 1.5 s stands for the busy child under load.
-- @cache-allow spawn
-- (it starts child editors)
---@diagnostic disable: missing-fields
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local sheet = require("testing.sheet")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-step-timeout"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()

  -- a loop, not `vim.wait`: an editor in `vim.wait` still answers RPC calls, a computing one does not
  local BUSY = "local t0 = vim.uv.hrtime(); while vim.uv.hrtime() - t0 < 1.5e9 do end"
  local function run(steps)
    local s = assert(sheet.validate({
      id = "t.timeout",
      title = "T",
      sizes = { { rows = 12, cols = 50 } },
      steps = steps,
    }))
    return sheet.run(s, { root = root, ci = true, spawn = { call_timeout_ms = 500 } })
  end

  -- 1. the RPC limit holds without `timeout` (else the cases below prove nothing) --------------------------------------
  eq(run({ { lua = BUSY } }).status, "fail", "a lua step past the RPC limit fails")

  -- 2. a lua step with its own timeout waits for the call ---------------------------------------------------------------
  local res =
    run({ { lua = BUSY .. "; vim.g.done = 1", timeout = 5000 }, { expect = "vim.g.done == 1" } })
  eq(
    res.status,
    "pass",
    "a lua step with timeout = 5000 outlives the RPC limit: " .. vim.inspect(res.failures)
  )

  -- 3. a poll of a wait may take as long as the wait ------------------------------------------------------------------
  res = run({
    { lua = "function _G.busy() " .. BUSY .. "; vim.g.done = 1 end" },
    { input = ":lua _G.busy()<CR>", note = "the child is busy for 1.5 s" },
    { wait = "vim.g.done == 1", timeout = 5000 },
  })
  eq(res.status, "pass", "a wait of 5 s on a busy child is green: " .. vim.inspect(res.failures))

  -- 4. timeout is accepted on a lua step, still refused on keys ----------------------------------------------------------
  ok(
    sheet.validate({ id = "a", title = "T", steps = { { lua = "x()", timeout = 100 } } }) ~= nil,
    "lua takes a timeout"
  )
  local _, err =
    sheet.validate({ id = "a", title = "T", steps = { { keys = "x", timeout = 100 } } })
  ok(
    tostring(err):find("timeout belongs to a wait, prompt, close, lua or steady step", 1, true)
      ~= nil,
    "keys: " .. tostring(err)
  )

  vim.fn.delete(root, "rf")
end
