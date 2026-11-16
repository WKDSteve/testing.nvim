-- TESTS/testing/sheet_steady_spec.lua -- the step `steady = ms` of an rpc sheet: it waits until the screen the attached
-- UI was told has not changed for `ms` (no cell, no cursor), what a snapshot needs when parts of the UI draw debounced
-- after the lines. A picture that never holds still fails it in time, with how long ago it last changed.
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
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-steady"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()

  ---A timer in the child that writes the buffer's line `n` times, every `every` ms (n = 0: for ever).
  local function ticker(n, every)
    return ([[
      vim.g.ticks = 0
      local t = vim.uv.new_timer()
      t:start(%d, %d, vim.schedule_wrap(function()
        vim.g.ticks = vim.g.ticks + 1
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "tick " .. vim.g.ticks })
        if %d > 0 and vim.g.ticks >= %d then
          t:stop()
        end
      end))
    ]]):format(every, every, n, n)
  end
  local function run(steps)
    local s = assert(sheet.validate({
      id = "t.steady",
      title = "T",
      sizes = { { rows = 8, cols = 30 } },
      steps = steps,
    }))
    return sheet.run(s, { root = root, ci = true })
  end

  -- 1. it waits for the last change: ten ticks of 80 ms, then 400 ms without one --------------------------------------
  local started = vim.uv.hrtime()
  local res = run({
    { lua = ticker(10, 80) },
    { steady = 400, timeout = 5000 },
    { expect = "vim.g.ticks == 10", note = "every tick was drawn before the step ended" },
  })
  eq(res.status, "pass", "steady waits until the ticks stop: " .. vim.inspect(res.failures))
  ok((vim.uv.hrtime() - started) / 1e6 >= 1200, "it took the ticks and the quiet time")

  -- 2. a picture that never holds still fails in time --------------------------------------------------------------------
  res = run({ { lua = ticker(0, 50) }, { steady = 300, timeout = 1500 } })
  eq(res.status, "fail", "a screen that keeps changing is not steady")
  ok(
    tostring(res.failures[1]):find("the screen changed", 1, true) ~= nil,
    "it says the screen still changed: " .. vim.inspect(res.failures)
  )

  -- 3. the value is checked ---------------------------------------------------------------------------------------------
  local _, err = sheet.validate({ id = "a", title = "T", steps = { { steady = 0 } } })
  ok(
    tostring(err):find("milliseconds must be a whole number", 1, true) ~= nil,
    "steady 0: " .. tostring(err)
  )
  ok(
    sheet.validate({ id = "a", title = "T", steps = { { steady = 500, timeout = 3000 } } }) ~= nil,
    "steady takes a timeout"
  )

  vim.fn.delete(root, "rf")
end
