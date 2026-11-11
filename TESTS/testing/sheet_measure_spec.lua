-- TESTS/testing/sheet_measure_spec.lua -- `measure = expr` in an rpc sheet: a number read in the child (`runs` times, the
-- median counts), held against `min` / `max`, kept in the result, the step's event, as a note of a stepped run and,
-- with `testing sheets run --tasks`, as the notes of the run in the task's block.
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
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local function sheet_of(steps)
    return { id = "m.sheet", title = "measure", sizes = { { rows = 10, cols = 40 } }, steps = steps }
  end

  -- 1. the form ---------------------------------------------------------------------------------------------------------
  do
    ok(sheet.validate(sheet_of({ { measure = "1", name = "one" } })) ~= nil, "a measure loads")
    local function refused(steps, needle, msg)
      local s, err = sheet.validate(sheet_of(steps))
      ok(s == nil, msg .. ": refused")
      has(err, needle, msg)
    end
    refused({ { measure = "1" } }, ".name", "no name")
    refused({ { measure = " ", name = "x" } }, "must not be empty", "an empty expression")
    refused(
      { { measure = "1", name = "x", min = 3, max = 2 } },
      "min is above max",
      "min above max"
    )
    refused({ { measure = "1", name = "x", runs = 0 } }, ".runs", "no run")
    refused({ { measure = "1", name = "x", runs = 2.5 } }, ".runs", "half a run")
    refused({ { measure = "1", name = "x", max = 0 / 0 } }, "finite", "NaN")
    refused({ { measure = "1", name = "x", unit = ("u"):rep(17) } }, ".unit", "a long unit")
    refused({ { expect = "true", max = 1 } }, "belong to a measure step", "max on another step")
  end

  -- 2. median and text --------------------------------------------------------------------------------------------------
  do
    eq(sheet.median({ 5, 100, 7 }), 7, "the median of three")
    eq(sheet.median({ 4, 1, 3, 2 }), 2.5, "of four: the mean of the middle two")
    eq(
      sheet.measure_text({
        name = "probe",
        value = 7,
        values = { 5, 100, 7 },
        unit = "ms",
        max = 10,
      }),
      "probe = 7 ms (median of 3: 5, 100, 7; max 10)",
      "the text of a measure"
    )
    eq(
      sheet.measure_text({ name = "n", value = 1 / 3, values = { 1 / 3 } }),
      "n = 0.3333",
      "one reading, no unit, four digits"
    )
  end

  -- 3. in a child --------------------------------------------------------------------------------------------------------
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-measure"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()
  local three = {
    { lua = "vim.g.k = 0" },
    {
      measure = "(function() vim.g.k = vim.g.k + 1; return ({ 5, 100, 7 })[vim.g.k] end)()",
      name = "probe",
      runs = 3,
      max = 10,
      unit = "ms",
      note = "three readings",
    },
  }
  do
    local res = sheet.run(assert(sheet.validate(sheet_of(three))), { root = root, ci = true })
    eq(
      res.status,
      "pass",
      "the median is within the max (one reading of 100 is not): " .. vim.inspect(res.failures)
    )
    local m = res.measures and res.measures[1] or {}
    eq(
      { m.name, m.value, m.values, m.unit, m.size, m.n },
      { "probe", 7, { 5, 100, 7 }, "ms", "40x10", 2 },
      "the result"
    )

    local over = sheet.run(
      assert(sheet.validate(sheet_of({ { measure = "42", name = "answer", max = 10 } }))),
      { root = root, ci = true }
    )
    eq(over.status, "fail", "above the max: red")
    has(over.failures[1], "answer = 42 (max 10): above the max", "... with the value")
    eq(over.measures and over.measures[1].value, 42, "... and the value is kept")
    local under = sheet.run(
      assert(sheet.validate(sheet_of({ { measure = "1", name = "low", min = 2 } }))),
      { root = root, ci = true }
    )
    has(under.failures[1], "low = 1 (min 2): below the min", "below the min: red")
    local nan = sheet.run(
      assert(sheet.validate(sheet_of({ { measure = "'x'", name = "text" } }))),
      { root = root, ci = true }
    )
    has(nan.failures[1], 'text: got "x", not a number', "not a number: red")
  end

  -- 4. a stepped run: the event, a note, the text line ------------------------------------------------------------------
  do
    local w = assert(io.open(root .. "/TESTS/sheets/m.sheet.lua", "wb"))
    w:write("return " .. vim.inspect(sheet_of(three)) .. "\n")
    w:close()
    local step_cli = require("testing.sheet.step")
    local events = {}
    local deps = {
      emit = function(line)
        events[#events + 1] = line
        return true
      end,
      trust_check = function()
        return nil
      end,
      getenv = function()
        return nil
      end,
    }
    eq(
      step_cli.main({ "m.sheet", "--root", root, "--run" }, { out = print, err = print }, deps),
      0,
      "green"
    )
    local after, note
    for _, line in ipairs(events) do
      local ev = vim.json.decode(line)
      if ev.event == "step-after" and ev.n == 2 then
        after = ev
      elseif ev.event == "note" then
        note = ev
      end
    end
    eq(after and after.measure and after.measure.value, 7, "step-after carries the measure")
    eq(
      note and note.text,
      "probe = 7 ms (median of 3: 5, 100, 7; max 10)",
      "the value is a note of the run"
    )
    eq(note and note.n, 2, "... on its step")
    events = {}
    step_cli.main(
      { "m.sheet", "--root", root, "--run", "--format=text" },
      { out = print, err = print },
      deps
    )
    has(table.concat(events, "\n"), "=> probe = 7 ms", "the text line shows the value")
  end

  -- 5. `sheets run --tasks`: the measures are the notes of the run in the block ------------------------------------------
  do
    local seen
    local run_cli = require("testing.sheet.run")
    local w = assert(io.open(root .. "/TESTS/sheets/m.sheet.lua", "wb"))
    local t = sheet_of(three)
    t.task = "x/y"
    w:write("return " .. vim.inspect(t) .. "\n")
    w:close()
    run_cli.main(
      { "--task", "x/y", "--root", root, "--tasks", root },
      { out = function() end, err = function() end },
      {
        getenv = function()
          return nil
        end,
        trust_check = function()
          return nil
        end,
        call = function()
          return { items = {} }
        end,
        no_write = true,
        on_ran = function(entries)
          seen = entries
        end,
      }
    )
    local e = seen and seen[1] or {}
    local notes = e.new_notes and e.new_notes.notes or {}
    eq(#notes, 1, "one note per measure")
    eq(notes[1] and notes[1].text, "probe = 7 ms (median of 3: 5, 100, 7; max 10)", "... its text")
    local block = require("testing.sheet.tasks").render_block(seen)
    has(
      block,
      "- Schritt 2 (40x10): probe = 7 ms",
      "... in the block, as the notes of a stepped run"
    )
  end

  vim.fn.delete(root, "rf")
end
