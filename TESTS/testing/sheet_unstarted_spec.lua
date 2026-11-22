-- TESTS/testing/sheet_unstarted_spec.lua -- an rpc sheet whose child does not start in time (the boot call or the first
-- `nvim_ui_attach` runs out of its limit, as on a machine at 100 % CPU with this run at a low priority) is red, but
-- marked: `unstarted`, a line that names the load and `TESTING_PRIORITY=normal`, and the field in `--result`. A step
-- that fails in a child that did start stays an ordinary failure. The limits are lowered to 1 ms to stand for the load.
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
  local function has(text, part, msg)
    return ok(
      tostring(text):find(part, 1, true) ~= nil,
      ("%s: %q not in %q"):format(msg, part, tostring(text))
    )
  end
  local sheet = require("testing.sheet")
  local drv = require("testing.sheet.driver_rpc")

  -- ---- what counts as a start that ran out of time, and what the line says ------------------------------------
  ok(
    drv.start_timeout("RPC call nvim_exec_lua timed out after 60000 ms (child pid 4 was killed)"),
    "a timed-out boot call is a start timeout"
  )
  ok(
    drv.start_timeout("no answer within 20000 ms"),
    "the asynchronous boot limit is a start timeout"
  )
  ok(not drv.start_timeout("child exited with code 1"), "a child that died is not a start timeout")
  has(
    drv.load_note({ priority = 10 }),
    "TESTING_PRIORITY=normal",
    "a run with a low priority names the way out"
  )
  has(
    drv.load_note({ load = 23.04, cpus = 16, priority = 0 }),
    "load 23.0 on 16 CPUs",
    "the load is named where there is one"
  )
  local u = drv.unstarted_failure("120x30", "RPC call x timed out after 1 ms", { priority = 10 })
  ok(u.unstarted == true, "the failure is marked unstarted")
  has(u.failure, "120x30: the child did not start in time", "the line says what happened")

  -- ---- real children: the boot call, and the first ui_attach, run out of time ---------------------------------
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-unstarted"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()
  local function run(steps, spawn)
    local s = assert(sheet.validate({
      id = "t.unstarted",
      title = "U",
      sizes = { { rows = 12, cols = 50 } },
      steps = steps,
    }))
    return sheet.run(s, { root = root, ci = true, spawn = spawn })
  end

  local boot = run({ { expect = "true" } }, { boot_timeout_ms = 1 })
  eq(boot.status, "fail", "a child that did not start in time leaves the sheet red")
  ok(boot.unstarted == true, "and marks it unstarted: " .. vim.inspect(boot.failures))
  has(boot.failures[1], "did not start in time", "the failure says it did not start in time")

  local attach = run({ { expect = "true" } }, { call_timeout_ms = 1 })
  eq(attach.status, "fail", "a first draw that ran out of time leaves the sheet red")
  ok(attach.unstarted == true, "and is a start too: " .. vim.inspect(attach.failures))

  local real = run({ { expect = "false" } })
  eq(real.status, "fail", "a step that fails in a started child is red")
  ok(real.unstarted == nil, "and is an ordinary failure: " .. vim.inspect(real.failures))

  -- ---- `--result` carries the mark --------------------------------------------------------------------------
  local doc = require("testing.sheet.run").result_doc({}, {
    { sheet = { id = "a" }, case = { status = "fail", unstarted = true } },
    { sheet = { id = "b" }, case = { status = "fail" } },
  }, true, nil, 1)
  eq(doc.sheets[1], { id = "a", status = "fail", unstarted = true }, "the document marks the sheet")
  eq(doc.sheets[2], { id = "b", status = "fail" }, "and not an ordinary red one")
  vim.fn.delete(root, "rf")
end
