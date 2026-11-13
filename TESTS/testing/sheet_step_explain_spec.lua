-- TESTS/testing/sheet_step_explain_spec.lua -- `explain <n> <kind>` in a stepped run: the request an AI would get about
-- a step comes back as an `explain` event, built as the panel builds it (`testing.sheet.explain`), for a client that is
-- not the editor. Nothing is sent, the run stays where it is, and the request is no part of the recording.
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
      msg .. " (got " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end
  local step_cli = require("testing.sheet.step")
  local explain = require("testing.sheet.explain")
  local schema = require("testing.export.schema")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")
  local session_schema =
    schema.load(repo .. "/schemas/testing-sheet-session/1/testing-sheet-session.schema.json")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-step-explain"
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
    "TESTS/sheets/red.sheet.lua",
    [[return {
  id = "explain.red",
  title = "Red in the middle",
  steps = {
    { lua = "vim.g.a = 1", note = "one" },
    { expect = "false", note = "never" },
    { lua = "vim.g.c = 1", note = "three" },
  },
}
]]
  )

  ---@return integer code, table[] events
  local function step_run(commands)
    local events = {}
    local queue = vim.deepcopy(commands)
    local code = step_cli.main({ "explain.red", "--root", root }, {
      out = function() end,
      err = function() end,
    }, {
      emit = function(line)
        local doc = vim.json.decode(line)
        local valid, problems = schema.validate(session_schema, doc)
        eq(problems, {}, "an event fits the schema: " .. line:sub(1, 200))
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
    })
    return code, events
  end
  local function of(events, name)
    return vim.tbl_filter(function(e)
      return e.event == name
    end, events)
  end

  -- 1. the command line ------------------------------------------------------------------------------------------------
  eq(step_cli.explain_args("explain 2 result"), { n = 2, kind = "result" }, "explain_args")
  eq(step_cli.explain_args("explain   12   what"), { n = 12, kind = "what" }, "... blanks")
  eq(step_cli.explain_args("explain"), false, "... a bare word is the command, malformed")
  eq(step_cli.explain_args("explain x what"), false, "... a step that is no number")
  eq(step_cli.explain_args("explain 2"), false, "... no question")
  eq(step_cli.explain_args("explain 2 what now"), false, "... a word too many")
  eq(step_cli.explain_args("explained 2 what"), nil, "... another word is another command")
  eq(step_cli.explain_args("next"), nil, "... as is next")

  -- 2. in a run ----------------------------------------------------------------------------------------------------------
  do
    local code, events = step_run({
      "explain 1 what", -- before step 1 ran
      "explain 1 result", -- refused: it has not run
      "explain 9 what", -- refused: no such step
      "explain 1 why", -- refused: no such question
      "explain", -- refused: malformed
      "note looks odd",
      "next", -- step 1 runs, paused before 2
      "explain 1 result",
      "next", -- step 2 fails, paused on the failure
      "explain 2 result",
      "abort",
    })
    eq(code, 3, "the run was aborted in the end")
    local asked = of(events, "explain")
    eq(#asked, 3, "three requests came back")
    local errors = vim.tbl_map(function(e)
      return e.message
    end, of(events, "error"))
    eq(#errors, 4, "four were refused")
    has(errors[1], "step 1 has not run yet", "... the result of a step that did not run")
    has(errors[2], "the sheet has no step 9", "... a step the sheet does not have")
    has(errors[3], "unknown question: why", "... a question that is none")
    has(errors[4], "explain <n> what|watch|result", "... a malformed line names the form")

    local first = asked[1]
    eq({ first.n, first.kind }, { 1, "what" }, "the step and the question come back")
    ok(first.size:match("^%d+x%d+$") ~= nil, "... with the size the run stands in")
    eq(first.system, explain.SYSTEM, "the system text is the panel's")
    has(first.prompt, "Sheet explain.red: Red in the middle (engine rpc)", "the sheet")
    has(first.prompt, "> 1. lua vim.g.a = 1  -- one", "the step in question is marked")
    has(first.prompt, "It has not run yet.", "... and has not run")
    has(first.prompt, "Question: What does this step do?", "the question")

    local ran = asked[2]
    eq({ ran.n, ran.kind }, { 1, "result" }, "the result, once it ran")
    has(ran.prompt, "It ran: pass in ", "... what it did")
    has(ran.prompt, "Note of the person: looks odd", "... and the note taken on it")
    has(ran.prompt, "Question: What does the result of this step mean?", "... the question")

    local red = asked[3]
    has(red.prompt, "It ran: fail in ", "a failed step")
    has(red.prompt, "Failure: ", "... with its failure line")
    ok(red.prompt:find("looks odd", 1, true) == nil, "... and not the note of another step")

    -- the same request the panel would build from the events a client saw
    local start = of(events, "start")[1]
    local mark
    for _, e in ipairs(of(events, "step-after")) do
      if e.n == 2 then
        mark = e
      end
    end
    local want = assert(
      explain.request({ doc = start, size = red.size, n = 2, mark = mark, notes = {} }, "result")
    )
    eq(red.prompt, want.prompt, "the request is the one the panel builds from the events")

    -- the run stayed where it was: each step ran once, in order
    eq(
      vim.tbl_map(function(e)
        return e.n
      end, of(events, "step-after")),
      { 1, 2 },
      "the steps ran once each, an explain moves nothing"
    )

    -- the recording has every event but the requests
    local recorded = {}
    for _, line in
      ipairs(vim.fn.readfile(step_cli.evidence_dir("explain.red") .. "/" .. step_cli.EVENTS_FILE))
    do
      recorded[#recorded + 1] = vim.json.decode(line).event
    end
    ok(not vim.tbl_contains(recorded, "explain"), "a request is no part of the recording")
    eq(#recorded, #events - #asked, "... every other event is")
  end

  vim.fn.delete(root, "rf")
  vim.fn.delete(step_cli.evidence_dir("explain.red"), "rf")
end
