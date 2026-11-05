-- TESTS/testing/sheet_ask_spec.lua -- a question of a sheet (`ask`): a judge criterion when nobody can answer, a stop in a
-- stepped run, a no is red, a yes ticks its box in the task, and only a run that counts writes.
-- @cache-allow time processes
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch, undefined-field

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
  local step_cli = require("testing.sheet.step")
  local schema = require("testing.export.schema")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")
  local session_schema =
    schema.load(repo .. "/schemas/testing-sheet-session/1/testing-sheet-session.schema.json")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-ask"
  local function write(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end
  write("TESTS/minimal_init.lua", "vim.o.swapfile = false\n")
  write(
    "TESTS/sheets/walk.sheet.lua",
    [[return {
  id = "ask.walk",
  title = "A walk",
  task = "x/walk",
  steps = {
    { lua = "vim.g.a = 1", note = "before" },
    { ask = "Do you hear music?" },
    { lua = "vim.g.b = 1", note = "after" },
  },
  judge = { "It reads well" },
}
]]
  )
  write(
    "TESTS/sheets/hand.sheet.lua",
    [[return {
  id = "ask.hand",
  title = "By hand",
  task = "x/hand",
  engine = "manual",
  steps = { { ask = "Is the tray icon there?" }, { ask = "Does it start with Windows?" } },
}
]]
  )

  -- 1. the shape, and nobody to answer ---------------------------------------------------------------------------------
  do
    local s = assert(sheet.load(root .. "/TESTS/sheets/walk.sheet.lua"))
    eq(s.judge, { "It reads well", "Do you hear music?" }, "a question is a judge criterion too")
    local twice = assert(sheet.validate({
      id = "a",
      title = "T",
      judge = { "Q?" },
      steps = { { ask = "Q?" } },
    }))
    eq(twice.judge, { "Q?" }, "... once")
    ok(
      sheet.validate({ id = "a", title = "T", steps = { { ask = "" } } }) == nil,
      "an empty question"
    )
    local browser = assert(sheet.validate({
      id = "a",
      title = "T",
      engine = "browser",
      steps = { { ask = "Q?" } },
    }))
    eq(browser.judge, { "Q?" }, "a question in every engine")
    ok(assert(sheet.validate({
      id = "a",
      title = "T",
      engine = "desktop",
      app = "x",
      steps = { { ask = "Q?" } },
    })) ~= nil, "... desktop too")
    local _, mixed = sheet.validate({
      id = "a",
      title = "T",
      engine = "manual",
      steps = { { ask = "Q?" }, { keys = "x" } },
    })
    has(mixed, "no steps but questions", "a manual sheet asks and does nothing else")
    local plain = assert(sheet.validate({
      id = "a",
      title = "T",
      engine = "manual",
      steps = { { ask = "Q?" } },
    }))
    eq(plain.manual, {}, "a manual sheet with questions needs no manual list")

    local res = sheet.run(s, { root = root, ci = true })
    eq({ res.ok, res.status }, { true, "pass" }, "in a suite the question passes over")
    local hand =
      sheet.run(assert(sheet.load(root .. "/TESTS/sheets/hand.sheet.lua")), { root = root })
    eq({ hand.ok, hand.status }, { true, "manual" }, "a manual sheet stays manual")
    local report = require("testing.sheet.report")
    local entries = report.collect({ root }, {
      cases = {
        ["sheet:ask.walk"] = {
          id = "1",
          file = "TESTS/sheets_spec.lua",
          name = "sheet:ask.walk",
          status = "pass",
          duration_ms = 1,
        },
      },
    })
    local bucket
    for _, e in ipairs(entries) do
      if e.sheet.id == "ask.walk" then
        bucket = report.bucket(e)
      end
    end
    eq(bucket, "inbox", "it waits for a person, like any other criterion")
  end

  -- 2. the command -------------------------------------------------------------------------------------------------------
  local function step_run(argv, commands, deps)
    local events, errs = {}, {}
    local queue = vim.deepcopy(commands)
    local code = step_cli.main(
      argv,
      {
        out = function() end,
        err = function(s)
          errs[#errs + 1] = s
        end,
      },
      vim.tbl_extend("force", {
        emit = function(line)
          local doc = vim.json.decode(line)
          local valid, problems = schema.validate(session_schema, doc)
          eq(problems, {}, "an event fits the schema: " .. line)
          ok(valid, "... valid")
          events[#events + 1] = doc
          return true
        end,
        reader = {
          start = function() end,
          next = function()
            return table.remove(queue, 1)
          end,
          stop = function() end,
        },
        trust_check = function()
          return nil
        end,
        getenv = function()
          return nil
        end,
      }, deps or {})
    )
    return code, events, table.concat(errs, "\n")
  end
  local function of(events, name)
    return vim.tbl_filter(function(e)
      return e.event == name
    end, events)
  end

  -- a task in memory
  local bodies = {}
  local function memory_call(method, params)
    if method == "bodies" then
      local items = {}
      for _, id in ipairs(params.ids) do
        if bodies[id] then
          items[#items + 1] = { id = id, body = bodies[id], etag = "e" }
        end
      end
      return { items = items }
    end
    local results = {}
    for _, op in ipairs(params.ops or {}) do
      bodies[op.id] = op.body
      results[#results + 1] = { n = #results + 1, ok = true }
    end
    return { results = results }
  end

  do
    -- continue does not run past a question
    local code, events = step_run(
      { "ask.walk", "--root", root },
      { "continue", "answer yes it plays", "continue" }
    )
    eq(code, 0, "yes: green")
    local asks = of(events, "ask")
    eq(#asks, 1, "the question stops the run under continue")
    eq(asks[1].text, "Do you hear music?", "... with its text")
    eq(asks[1].n, 2, "... and its step")
    local last = events[#events]
    eq(last.status, "pass", "the end")
    eq(last.verdict, true, "an answered run counts")
    eq(last.answers[1].answer, "yes", "the answer is in the end event")
    eq(last.answers[1].note, "it plays", "... with its note")

    -- a command that is no answer leaves the question open
    local _, wrong = step_run(
      { "ask.walk", "--root", root },
      { "continue", "next", "answer maybe", "answer yes", "continue" }
    )
    eq(#of(wrong, "error"), 2, "next and maybe are no answers")
    eq(wrong[#wrong].status, "pass", "... and the run goes on after one")

    -- no is red, with the note, and stops like any failure
    local c2, no = step_run(
      { "ask.walk", "--root", root },
      { "continue", "answer no it crackles", "continue" }
    )
    eq(c2, 1, "no: exit 1")
    local failed = of(no, "step-after")[2]
    eq(failed.status, "fail", "the step fails")
    has(failed.reason, "answered no: it crackles", "... with the note")
    ok(vim.tbl_filter(function(e)
      return e.event == "paused" and e.reason == "failed"
    end, no)[1] ~= nil, "... and it pauses like any failure")
    ok(#of(no, "step-before") == 2, "the step after it does not run")

    -- closed stdin at a question is an abort
    local c3, eof = step_run({ "ask.walk", "--root", root }, { "continue" })
    eq(c3, 3, "the end of stdin at a question: an abort")
    eq(eof[#eof].verdict, false, "... no verdict")

    -- --run: nobody can answer
    local c4, ran = step_run({ "ask.walk", "--root", root, "--run" }, {}, {
      reader = {
        start = function()
          error("--run must not read stdin")
        end,
      },
    })
    eq(c4, 0, "--run passes over a question")
    eq(of(ran, "ask"), {}, "... and asks nothing")

    -- a guided walk: only questions
    local c5, guided = step_run({ "ask.hand", "--root", root }, { "answer yes", "answer yes" })
    eq(c5, 0, "a manual sheet with questions")
    eq(guided[#guided].status, "manual", "... stays manual")
    eq(guided[#guided].verdict, true, "... and counts")
    eq(#guided[#guided].answers, 2, "... with both answers")
    local c6, red_hand = step_run({ "ask.hand", "--root", root }, { "answer no", "continue" })
    eq(c6, 1, "a no in a walk is red")
    eq(red_hand[#red_hand].status, "fail", "... also for a manual sheet")
  end

  -- 3. the task ----------------------------------------------------------------------------------------------------------
  do
    local deps = { call = memory_call }
    bodies["x/walk"] = "The task.\n"
    local code, events = step_run(
      { "ask.walk", "--root", root, "--tasks", "vault" },
      { "next", "answer yes", "next" },
      deps
    )
    eq(code, 0, "a green run with --tasks")
    eq(of(events, "task")[1].outcome, "changed", "says what became of the block")
    has(bodies["x/walk"], "- [x] Do you hear music?", "a yes ticks its box")
    has(bodies["x/walk"], "- [ ] It reads well", "another criterion stays open")
    has(bodies["x/walk"], "ask.walk=inbox", "the state goes into the block")

    -- a later run keeps the box, as for one ticked by hand
    step_run(
      { "ask.walk", "--root", root, "--tasks", "vault" },
      { "next", "answer no nope", "continue" },
      deps
    )
    has(bodies["x/walk"], "ask.walk=red", "a no makes it red")
    has(bodies["x/walk"], "answered no: nope", "... with the reason")

    -- an abort writes nothing
    bodies["x/walk"] = "The task.\n"
    local c2, aborted = step_run(
      { "ask.walk", "--root", root, "--tasks", "vault" },
      { "next", "abort" },
      deps
    )
    eq(c2, 3, "an abort")
    eq(of(aborted, "task"), {}, "... writes nothing")
    eq(bodies["x/walk"], "The task.\n", "... into the task")

    -- nothing to write into
    local c3, _, err3 = step_run({ "ask.walk", "--root", root, "--tasks-cli", "x" }, {}, deps)
    eq(c3, 2, "--tasks-cli alone")
    has(err3, "belongs to --tasks", "... says so")
    write(
      "TESTS/sheets/none.sheet.lua",
      'return { id = "ask.none", title = "N", steps = { { ask = "Q" } } }\n'
    )
    local c4, ev4, err4 = step_run({ "ask.none", "--root", root, "--tasks", "vault" }, {}, deps)
    eq(c4, 2, "a sheet without a task")
    eq(ev4, {}, "... before anything runs")
    has(err4, "names no task", "... says so")
    -- another sheet of the task would lose its state
    write(
      "TESTS/sheets/other.sheet.lua",
      'return { id = "ask.other", title = "O", task = "x/walk", steps = { { lua = "vim.g.o = 1" } } }\n'
    )
    local c5, ev5, err5 = step_run({ "ask.walk", "--root", root, "--tasks", "vault" }, {}, deps)
    eq(c5, 2, "a task with another sheet is refused")
    eq(ev5, {}, "... before anything runs")
    has(err5, "ask.other", "... and it names it")
  end

  -- 4. the panel ---------------------------------------------------------------------------------------------------------
  do
    local panel = require("testing.sheet.panel")
    local sent
    local p = {
      target = "x",
      marks = {},
      breaks = {},
      stderr = {},
      running = false,
      buf = -1,
      proc = {
        write = function(_, text)
          sent = text
        end,
      },
    }
    panel.on_event(
      p,
      { schema = panel.SCHEMA, event = "ask", size = "80x24", n = 2, text = "Do you hear music?" }
    )
    local lines = panel.render(p)
    has(lines[2], "asks: Do you hear music?", "the panel shows the question")
    ok(panel.yes(p), "y")
    eq(sent, "answer yes\n", "... sends yes")
    p.paused, p.question = "ask", "Again?"
    ok(panel.next(p), "n")
    eq(sent, "answer no\n", "... sends no at a question")
    p.question = nil
    ok(not panel.yes(p), "y without a question does nothing")
  end

  vim.fn.delete(root, "rf")
end
