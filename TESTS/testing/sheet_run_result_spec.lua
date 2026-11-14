-- TESTS/testing/sheet_run_result_spec.lua -- `testing sheets run --result`: the last line of stdout is a document
-- of `testing-sheet-run/1`. The command ends with exit 1 for a red sheet and for a task it could not write alike; a
-- program that started the run (the hub of testing-desktop) tells the two apart by `red` and `written`, not by the
-- wording of the lines for a person.

return function(H)
  local eq, ok = H.eq, H.ok
  local run = require("testing.sheet.run")
  local schema = require("testing.export.schema")
  local base = vim.fs.normalize(vim.fn.tempname())
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local schema_file = vim.fs.normalize(
    vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
      .. "/../../schemas/testing-sheet-run/1/testing-sheet-run.schema.json"
  )
  local sf = assert(io.open(schema_file, "rb"))
  local sdoc = vim.json.decode(sf:read("*a"))
  sf:close()

  local repo = base .. "/x"
  write(
    repo .. "/TESTS/sheets/a.sheet.lua",
    'return { id = "a", title = "A", task = "x/live", steps = { { keys = "x" } } }\n'
  )
  write(
    repo .. "/TESTS/sheets/b.sheet.lua",
    'return { id = "b", title = "B", task = "x/live", steps = { { keys = "x" } } }\n'
  )
  write(
    repo .. "/TESTS/sheets/c.sheet.lua",
    'return {\n  id = "c",\n  task = "x/broken",\n  steps = {{\n'
  )

  local pass = { ok = true, status = "pass", failures = {}, snapshots = {} }
  local fail =
    { ok = false, status = "fail", failures = { "80x24 step 1: not truthy" }, snapshots = {} }
  local skip = {
    ok = true,
    status = "skip",
    skipped = "chromium is not installed",
    failures = {},
    snapshots = {},
  }

  ---A stand-in for the engine of tasks.nvim: every body is read, and the write answers `answer`.
  local function engine(answer)
    return function(method, params)
      if method == "bodies" then
        return {
          kind = "tasks.bodies",
          items = vim.tbl_map(function(id)
            return { id = id, etag = "sha256:1", body = "Summary.\n" }
          end, params.ids),
        }
      end
      return answer
    end
  end
  local changed = { kind = "tasks.result", results = { { n = 1, ok = true, outcome = "changed" } } }
  local conflict = {
    kind = "tasks.result",
    results = {
      { n = 1, ok = false, error = { code = "conflict", message = "stale\n\27[31mred" } },
    },
  }

  ---Run `argv` with the sheets answering by id; the exit code, the lines of stdout and the decoded last one.
  local function go(argv, by_id, call)
    local out = {}
    local code = run.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function() end,
    }, {
      call = call,
      getenv = function()
        return nil
      end,
      trust_check = function()
        return nil
      end,
      run = function(s)
        return by_id[s.id] or pass
      end,
    })
    local decoded, doc = pcall(vim.json.decode, out[#out] or "")
    return code, out, decoded and type(doc) == "table" and doc or nil
  end
  ---The document of a run, valid against the schema and agreeing with the exit code.
  local function result(argv, by_id, call, what)
    local code, out, doc = go(argv, by_id, call)
    ok(doc ~= nil, what .. ": the last line is a document: " .. tostring(out[#out]))
    doc = doc or {}
    local valid, problems = schema.validate(sdoc, doc)
    eq(problems, {}, what .. ": valid")
    ok(valid, what .. ": valid")
    eq(doc.exit, code, what .. ": the document names the exit code")
    ok(not (out[#out] or ""):find("[%c]"), what .. ": one line without control characters")
    return code, doc, out
  end
  local task = { "--task", "x/live", "--root", repo, "--tasks", base, "--result" }

  -- green sheets, the task written
  local code, doc, out = result(task, {}, engine(changed), "green and written")
  eq({ code, doc.red, doc.written, doc.task }, { 0, false, true, "x/live" }, "green and written")
  eq(
    doc.sheets,
    { { id = "a", status = "pass" }, { id = "b", status = "pass" } },
    "... both sheets, in order"
  )
  eq(doc.tasks, { { id = "x/live", outcome = "changed" } }, "... and what became of the task")
  ok(
    vim.list_contains(out, "testing sheets: task x/live changed"),
    "the lines for a person are still there, the document comes after them"
  )

  -- a red sheet, the task written: exit 1, and it is the sheet
  code, doc = result(task, { b = fail }, engine(changed), "red and written")
  eq({ code, doc.red, doc.written }, { 1, true, true }, "a red sheet with a written task")
  eq(doc.sheets[2], { id = "b", status = "fail" }, "... names the red sheet")

  -- green sheets, the task not written: the same exit 1, and it is not a sheet
  code, doc = result(task, {}, engine(conflict), "green and not written")
  eq(
    { code, doc.red, doc.written },
    { 1, false, false },
    "green sheets with a task that was not written"
  )
  eq(doc.tasks[1].outcome, "failed", "... a conflict is a failure")
  ok(
    doc.tasks[1].message:find("conflict", 1, true) ~= nil,
    "... with its reason: " .. doc.tasks[1].message
  )

  -- a skipped sheet is not red, and is said
  code, doc = result(task, { a = skip }, engine(changed), "a skip")
  eq({ code, doc.red, doc.sheets[1].status }, { 0, false, "skip" }, "a skipped sheet is no red run")

  -- a dry run writes nothing and the block would stand
  local dry = vim.list_extend({ "--dry-run" }, task)
  code, doc = result(dry, {}, engine(changed), "a dry run")
  eq(
    { code, doc.written, doc.tasks[1].outcome },
    { 0, true, "would_change" },
    "a dry run says what would change"
  )

  -- tasks.nvim does not answer after the sheets ran: exit 3, nothing written, and why
  code, doc = result(task, {}, function(method)
    if method == "bodies" then
      return nil, "tasks.nvim call bodies failed"
    end
  end, "the engine is gone")
  eq({ code, doc.written, doc.tasks }, { 3, false, {} }, "no engine: not written")
  ok(type(doc.problem) == "string" and doc.problem ~= "", "... with the problem")

  -- without --tasks nothing was to be written
  code, doc = result(
    { "--task", "x/live", "--root", repo, "--result" },
    { a = fail },
    nil,
    "no vault"
  )
  eq(
    { code, doc.red, doc.written, doc.tasks },
    { 1, true, vim.NIL, {} },
    "without --tasks: written is null"
  )

  -- a sheet that does not load is red, named by its file
  code, doc = result(
    { "--task", "x/broken", "--root", repo, "--result" },
    {},
    nil,
    "a sheet that does not load"
  )
  eq({ code, doc.red }, { 1, true }, "a sheet that does not load is red")
  eq(doc.sheets, { { id = "TESTS/sheets/c.sheet.lua", status = "fail" } }, "... named by its file")

  -- every sheet of a root: no task
  code, doc = result({ "--sheet", "a", "--root", repo, "--result" }, {}, nil, "--sheet")
  eq({ code, doc.task, #doc.sheets }, { 0, vim.NIL, 1 }, "--sheet: no task, one sheet")
  -- --strict: a skip is red there, and the document says so
  code, doc = result(
    { "--sheet", "a", "--root", repo, "--strict", "--result" },
    { a = skip },
    nil,
    "--strict"
  )
  eq(
    { code, doc.red, doc.sheets[1].status },
    { 1, true, "skip" },
    "--strict: a skip makes the run red"
  )

  -- without --result nothing changes: no document
  local _, plain_out, plain_doc = go(
    { "--task", "x/live", "--root", repo, "--tasks", base },
    {},
    engine(changed)
  )
  eq(plain_doc, nil, "without --result the last line is for a person")
  eq(plain_out[#plain_out], "testing sheets: task x/live changed", "... as before")

  -- a run that is refused prints no document: there is nothing to say of sheets
  local refused, refused_out = go({ "--task", "x/none", "--root", repo, "--result" }, {}, nil)
  eq({ refused, #refused_out }, { 2, 0 }, "no sheet names the task: exit 2, nothing on stdout")

  vim.fn.delete(base, "rf")
end
