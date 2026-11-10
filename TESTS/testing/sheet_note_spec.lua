-- TESTS/testing/sheet_note_spec.lua -- notes in a stepped run (`note <text>`): they belong to the step the run stands
-- before (else the one that ran last), come back in `end`, stay beside the pictures of the run for the report, and a run
-- that counts adds them to the task as a paragraph that later reports keep.
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
  local tasks = require("testing.sheet.tasks")
  local schema = require("testing.export.schema")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")
  local session_schema =
    schema.load(repo .. "/schemas/testing-sheet-session/1/testing-sheet-session.schema.json")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-note"
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
  id = "note.walk",
  title = "A walk with notes",
  task = "x/notes",
  steps = {
    { lua = "vim.g.a = 1", note = "one" },
    { lua = "vim.g.b = 1", note = "two" },
    { lua = "vim.g.c = 1", note = "three" },
  },
}
]]
  )

  ---Run the command in this process. `hooks.start(on_note)` runs when the reader starts (a live stdin hands the
  ---run its notes at once), `hooks.event(ev, on_note)` after each event.
  ---@return integer code, table[] events, string errs
  local function step_run(argv, commands, deps, hooks)
    hooks = hooks or {}
    local events, errs = {}, {}
    local queue = vim.deepcopy(commands)
    local live
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
          if hooks.event and live then
            hooks.event(doc, live)
          end
          return true
        end,
        reader = {
          start = function(_, on_note)
            live = hooks.start and on_note or nil
            if hooks.start then
              hooks.start(on_note)
            end
          end,
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

  -- 1. the command -------------------------------------------------------------------------------------------------------
  local size
  do
    eq(step_cli.note_text("note  a  b "), "a  b", "note_text: the text, trimmed")
    eq(step_cli.note_text("note"), "", "... a bare note")
    eq(step_cli.note_text("note\ta\1b"), "a b", "... control characters become blanks")
    eq(step_cli.note_text("notes"), nil, "... another word is no note")
    eq(step_cli.note_text("next"), nil, "... nor another command")

    local code, events = step_run({ "note.walk", "--root", root }, {
      "note the first looks fine",
      "next",
      "note",
      "note " .. ("x"):rep(step_cli.MAX_NOTE + 1),
      "note second\tone",
      "continue",
    })
    eq(code, 0, "a green run with notes")
    local notes = of(events, "note")
    eq(#notes, 2, "two notes taken")
    size = notes[1].size
    eq(
      { notes[1].n, notes[1].text },
      { 1, "the first looks fine" },
      "the step the run stands before"
    )
    eq({ notes[2].n, notes[2].text }, { 2, "second one" }, "... after next, the next step")
    ok(notes[1].time:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, "a UTC time")
    local errors = of(events, "error")
    eq(#errors, 2, "an empty and a too long note are refused")
    has(errors[1].message, "needs a text", "... the empty one")
    has(errors[2].message, "at most", "... the long one")
    ok(
      vim.tbl_contains(
        vim.tbl_map(function(e)
          return e.event == "paused" and e.n
        end, events),
        2
      ),
      "a note leaves the run paused"
    )
    local last = events[#events]
    eq(last.status, "pass", "the run goes on")
    eq(#last.notes, 2, "end carries the notes")
    eq(last.notes[2].text, "second one", "... in order")

    -- a live stdin: a note comes at once, also between two steps, where it belongs to the one that ran
    local _, live_events = step_run({ "note.walk", "--root", root }, { "continue" }, nil, {
      start = function(on_note)
        on_note("too early")
      end,
      event = function(ev, on_note)
        if ev.event == "step-after" and ev.n == 1 then
          on_note("between")
        end
      end,
    })
    has(of(live_events, "error")[1].message, "no step yet", "a note before any step is refused")
    local between = of(live_events, "note")
    eq(#between, 1, "the note between the steps")
    eq(between[1].n, 1, "... belongs to the step that ran last")
    eq(live_events[#live_events].status, "pass", "... and the run goes on under continue")

    -- a run without notes has no notes field
    local _, plain = step_run({ "note.walk", "--root", root }, { "continue" })
    eq(plain[#plain].notes, nil, "no notes, no field")
  end

  -- 1b. every engine: the note is the run's, not the engine's ------------------------------------------------------------
  do
    local nvim = vim.v.progpath:gsub("\\", "/")
    local driver = write(
      "note_driver.lua",
      [[
while true do
  local line = io.stdin:read("*l")
  if not line then break end
  local cmd = vim.json.decode(line)
  io.stdout:write(vim.json.encode({ schema = "testing-sheet-driver/1", ok = true }), "\n")
  io.stdout:flush()
  if cmd.cmd == "close" then break end
end
]]
    )
    write("note_app.lua", "vim.wait(120000)\n")
    write(".testing.lua", "return { sheets = { apps = " .. vim.inspect({
      window = {
        run = { nvim, "--headless", "-u", "NONE", "-l", "note_app.lua" },
        window = "demo",
      },
    }) .. " } }\n")
    write(
      "TESTS/sheets/browser.sheet.lua",
      [[return {
  id = "note.browser",
  title = "Browser",
  engine = "browser",
  sizes = { { rows = 7, cols = 9 } },
  steps = { { press = "a" }, { press = "b" } },
}
]]
    )
    write(
      "TESTS/sheets/desk.sheet.lua",
      [[return {
  id = "note.desk",
  title = "Desktop",
  engine = "desktop",
  app = "window",
  steps = { { wait = "a" }, { click = "b" } },
}
]]
    )
    write(
      "TESTS/sheets/hand.sheet.lua",
      [[return {
  id = "note.hand",
  title = "By hand",
  engine = "manual",
  steps = { { ask = "Is the icon there?" }, { ask = "Does it start?" } },
}
]]
    )
    local driven = {
      session_opts = {
        driver_argv = { nvim, "--headless", "-u", "NONE", "-l", driver },
        driver_margin_ms = 60000,
        driver_stop_ms = 2000,
      },
    }
    for _, c in ipairs({
      { id = "note.browser", deps = driven, commands = { "next", "note in the page", "continue" } },
      { id = "note.desk", deps = driven, commands = { "next", "note in the window", "continue" } },
      {
        id = "note.hand",
        commands = { "answer yes", "note at the question", "answer yes" },
      },
    }) do
      local code, events, errs = step_run({ c.id, "--root", root }, c.commands, c.deps)
      local last = events[#events] or {}
      eq({ code, last.event }, { 0, "end" }, c.id .. ": the run ends green (" .. errs .. ")")
      local notes = of(events, "note")
      eq(#notes, 1, c.id .. ": the note is taken")
      eq(notes[1] and notes[1].n, 2, c.id .. ": ... on the step the run stands before")
      eq(#(last.notes or {}), 1, c.id .. ": ... and end has it")
    end
  end

  -- 2. kept for the report -----------------------------------------------------------------------------------------------
  do
    eq(step_cli.last_notes(root, "note.walk"), nil, "the last run had no notes: nothing kept")
    step_run({ "note.walk", "--root", root }, { "note look at the prompt", "continue" })
    local kept = step_cli.last_notes(root, "note.walk")
    ok(kept ~= nil, "the notes of the last run are kept")
    eq(
      { kept.status, #kept.notes, kept.notes[1].text, kept.notes[1].n },
      { "pass", 1, "look at the prompt", 1 },
      "... with the run's end"
    )
    ok(kept.date:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil, "... and its date")
    eq(step_cli.last_notes(root .. "-other", "note.walk"), nil, "a sheet of the same id elsewhere")

    local report = require("testing.sheet.report")
    local text = report.render(report.collect({ root }, { cases = {} }))
    has(text, "notes of the stepped run on " .. kept.date .. " (pass):", "the report shows them")
    has(text, ("    - step 1 (%s): look at the prompt"):format(size), "... each under the sheet")
    local stood_in = report.collect({ root }, {
      cases = {},
      notes_of = function()
        return nil
      end,
    })
    eq(stood_in[1].last_notes, nil, "notes_of stands in")

    -- an aborted run keeps its notes too, and says so
    local c, ab = step_run({ "note.walk", "--root", root }, { "note half way", "abort" })
    eq(c, 3, "an abort")
    eq(ab[#ab].notes[1].text, "half way", "... end has the note")
    eq(step_cli.last_notes(root, "note.walk").status, "aborted", "... kept as an aborted run")
  end

  -- 3. the task ----------------------------------------------------------------------------------------------------------
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
    local deps = { call = memory_call }
    local date = os.date("%Y-%m-%d")
    bodies["x/notes"] = "The task.\n\n## Notizen\n\nMine.\n"
    local code = step_run(
      { "note.walk", "--root", root, "--tasks", "vault" },
      { "note first run <!-- testing:sheets:end -->", "continue" },
      deps
    )
    eq(code, 0, "a green run with --tasks")
    local body = bodies["x/notes"]
    has(
      body,
      ("### Notizen aus dem Durchgang %s (`note.walk`)\n\n- Schritt 1 (%s): first run"):format(
        date,
        size
      ),
      "the notes become a paragraph of the block"
    )
    local block, _, _, st = tasks.extract(body)
    eq(st, "ok", "a note cannot end the block")
    has(block, "<!- testing:sheets:end -->", "... its comment is defused")
    has(
      block,
      "\n\n<!-- testing:sheets:states note.walk=",
      "the states line stays a line of its own"
    )
    has(body, "## Notizen\n\nMine.", "the task's own notes are untouched")
    eq(
      tasks.kept_notes(block)[1],
      ("### Notizen aus dem Durchgang %s (`note.walk`)"):format(date),
      "kept_notes finds the paragraph"
    )

    -- a second run adds its paragraph after the first; a run without notes keeps both as they are
    step_run(
      { "note.walk", "--root", root, "--tasks", "vault" },
      { "next", "note second run", "continue" },
      deps
    )
    local two = bodies["x/notes"]
    local first_at = two:find("first run", 1, true)
    local second_at = two:find(("- Schritt 2 (%s): second run"):format(size), 1, true)
    ok(first_at and second_at and first_at < second_at, "the second paragraph follows the first")
    step_run({ "note.walk", "--root", root, "--tasks", "vault" }, { "continue" }, deps)
    eq(bodies["x/notes"], two, "a run without notes leaves them as they are")

    -- what a person added to a paragraph stays (only new lines and line ends are added by hand)
    bodies["x/notes"] = two:gsub("(first run[^\n]*)", "%1 (seen again)")
    step_run({ "note.walk", "--root", root, "--tasks", "vault" }, { "continue" }, deps)
    has(bodies["x/notes"], "(seen again)", "a hand edit inside the paragraph is kept")

    -- an abort writes nothing, notes or not
    local before = bodies["x/notes"]
    step_run(
      { "note.walk", "--root", root, "--tasks", "vault" },
      { "note never written", "abort" },
      deps
    )
    eq(bodies["x/notes"], before, "an aborted run does not write its notes into the task")
  end

  -- 4. kept_notes and the block without notes -------------------------------------------------------------------------
  do
    local fenced = table.concat({
      tasks.BEGIN,
      "```",
      "### Notizen aus dem Durchgang quoted",
      "```",
      tasks.STATES .. " a=green -->",
      tasks.END,
    }, "\n")
    eq(tasks.kept_notes(fenced), {}, "a heading in a fence is text")
    eq(tasks.kept_notes(nil), {}, "no block")
    local plain = tasks.render_block({
      {
        root = "/x/proj",
        rel = "TESTS/sheets/a.sheet.lua",
        sheet = { id = "a", title = "A", judge = {}, manual = {}, engine = "rpc" },
        snapshots = {},
      },
    })
    ok(not plain:find("Notizen", 1, true), "a block without notes has no notes paragraph")
    ok(not plain:find("\n\n" .. tasks.STATES, 1, true), "... and no blank line before the states")
  end

  -- 5. the panel ---------------------------------------------------------------------------------------------------------
  do
    local panel = require("testing.sheet.panel")
    local sent
    local p = {
      target = "x",
      marks = {},
      notes = {},
      breaks = {},
      stderr = {},
      running = true,
      buf = -1,
      size = "80x24",
      at = 2,
      doc = {
        title = "T",
        engine = "rpc",
        steps = {
          { n = 1, action = "lua", value = "a" },
          { n = 2, action = "lua", value = "b" },
        },
      },
      proc = {
        write = function(_, text)
          sent = text
        end,
      },
    }
    ok(panel.note(p, " looks\tright "), "N while a step runs")
    eq(sent, "note looks right\n", "... sends the note, one line")
    ok(not panel.note(p, "   "), "an empty note is not sent")
    panel.on_event(p, {
      schema = panel.SCHEMA,
      event = "note",
      size = "80x24",
      n = 2,
      text = "looks right",
      time = "2026-11-10T10:00:00Z",
    })
    local lines = panel.render(p)
    local text = table.concat(lines, "\n")
    has(text, " 2 lua b  [1 note]", "the step line counts its notes")
    has(text, "--- step 2, lua: b\nnote: looks right", "the tile shows the note under the step")
    has(lines[3], "N note", "the key is in the help line")
    sent = nil
    ok(not panel.note(p, ("x"):rep(step_cli.MAX_NOTE + 1)), "a note that is too long is not sent")
    eq(sent, nil, "... nothing reaches the run")

    -- an error of a note while the run goes on leaves it running; only a refused command restores the pause
    p.paused, p.running, p.pending_pause = "start", false, nil
    ok(panel.continue(p), "c")
    panel.on_event(p, { schema = panel.SCHEMA, event = "step-before", size = "80x24", n = 2 })
    panel.on_event(
      p,
      { schema = panel.SCHEMA, event = "error", message = "a note is at most 1000 bytes" }
    )
    eq({ p.paused, p.running }, { nil, true }, "a refused note does not bring back the old pause")
    p.paused, p.running = "step", false
    ok(panel.until_step(p, 2) == false, "(until to an earlier step is refused before sending)")
    ok(panel.next(p), "n")
    panel.on_event(p, { schema = panel.SCHEMA, event = "error", message = "unknown command" })
    eq(p.paused, "step", "a refused command leaves the run paused")

    p.finished = { status = "pass", ms = 1, failures = {} }
    ok(not panel.note(p, "late"), "no note after the end")
  end

  -- 6. limits, the comment, the case of a root -------------------------------------------------------------------------
  do
    local max = step_cli.MAX_NOTES
    step_cli.MAX_NOTES = 2
    local _, capped = step_run(
      { "note.walk", "--root", root },
      { "note a", "note b", "note c", "continue" }
    )
    step_cli.MAX_NOTES = max
    eq(#of(capped, "note"), 2, "at most MAX_NOTES notes in a run")
    has((of(capped, "error")[1] or {}).message, "at most 2 notes", "... the next one is refused")

    bodies["x/notes"] = "The task.\n"
    step_run(
      { "note.walk", "--root", root, "--tasks", "vault" },
      { "note <!--- hidden --> and <!---- more", "continue" },
      { call = memory_call }
    )
    local block = tasks.extract(bodies["x/notes"])
    for line in block:gmatch("[^\n]+") do
      if line:find("<!--", 1, true) then
        ok(line:match("^<!%-%- testing:sheets:") ~= nil, "no comment opens in a note: " .. line)
      end
    end

    if vim.fn.has("win32") == 1 then
      step_run({ "note.walk", "--root", root }, { "note case", "continue" })
      ok(
        step_cli.last_notes(root:upper(), "note.walk") ~= nil,
        "Windows: the case of a root does not matter"
      )
    end
  end

  -- 7. the real stdin: a note comes at once, also while a step runs -------------------------------------------------
  do
    write(
      "TESTS/sheets/slow.sheet.lua",
      [[return {
  id = "note.slow",
  title = "Slow",
  steps = { { lua = "vim.g.a = 1" }, { lua = "vim.uv.sleep(1500)" }, { lua = "vim.g.b = 1" } },
}
]]
    )
    local events, partial, proc = {}, "", nil
    local sent_during = false
    proc = vim.system({
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      repo .. "/scripts/testing.lua",
      "sheets",
      "step",
      "note.slow",
      "--root",
      root,
    }, {
      stdin = true,
      text = true,
      env = { TESTING_TRUST_ROOTS = root, NVIM_MACHINE_ROLE = "" },
      stdout = function(_, data)
        partial = partial .. (data or "")
        for line in partial:gmatch("([^\n]*)\n") do
          local okj, ev = pcall(vim.json.decode, line)
          if okj and type(ev) == "table" then
            events[#events + 1] = ev
            if ev.event == "paused" and ev.reason == "start" then
              proc:write("continue\n")
            elseif ev.event == "step-before" and ev.n == 2 and not sent_during then
              sent_during = true
              proc:write("note while it settles\n")
            end
          end
        end
        partial = partial:match("([^\n]*)$") or ""
      end,
    })
    local done = proc:wait(120000)
    eq(done.code, 0, "the real run ends green (" .. tostring(done.stderr) .. ")")
    local names, note_n = {}, nil
    for _, ev in ipairs(events) do
      names[#names + 1] = ev.event .. (ev.n and (":" .. ev.n) or "")
      if ev.event == "note" then
        note_n = ev.n
      end
    end
    eq(note_n, 2, "the note is taken during step 2, not at a later stop (there is none)")
    local at_note = vim.fn.index(names, "note:2")
    local after_two = vim.fn.index(names, "step-after:2")
    ok(
      at_note >= 0 and at_note < after_two,
      "... before the step ends: " .. table.concat(names, " ")
    )
  end

  vim.fn.delete(root, "rf")
end
