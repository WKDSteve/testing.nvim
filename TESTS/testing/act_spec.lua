-- TESTS/testing/act_spec.lua -- `testing act`: a finding becomes an intent `wkd-intent/1` (fixed action, a mode the
-- target takes, the finding as it is, no target), `--list` shows the tasks that name a finding (`tasks call find` with
-- `testing-finding:<fp>`), `--do=task|rule` is a dry run without `--yes` and a duplicate says "already there", `--do=ai`
-- writes the hand-over only into testing's own state folder and starts nothing, a repository the data classes do not
-- release gives exit 2, and the only process testing starts for a task is the CLI of the tasks engine.

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local act = require("testing.act")
  local cli = require("testing.cli")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local base = fixture.base("act")
  local fx = fixture.build(base)
  local restore = fixture.install()
  local real_dc = package.loaded["lib.nvim.data_classes"]
  local dc = require("lib.nvim.data_classes")
  local real_load = dc.load
  dc.load = function(o)
    return real_load(vim.tbl_extend("force", { path = fx.areas }, o or {}))
  end

  ---@param args string[]
  ---@param engines? table
  ---@param env? table<string, string>
  local function run(args, engines, env)
    local out, errs = {}, {}
    local code =
      cli.main(vim.list_extend({ "act", "--root=" .. fx.beta, "--state-dir=" .. fx.state }, args), {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          errs[#errs + 1] = s
        end,
        act = engines,
        getenv = function(name)
          return (env or {})[name]
        end,
      })
    return code, out, errs
  end

  local docs = assert(act.findings(fx.beta, { state_dir = fx.state }))
  ok(#docs >= 2, "the fixture repository has findings")
  local first = docs[1]

  -- ── the intent ──
  local intent = assert(act.intent(first, "task"))
  eq(intent.schema, "wkd-intent/1", "schema")
  eq(intent.action, "tasks.new", "--do=task is tasks.new")
  eq(intent.mode, "form", "the default mode of a task")
  eq(intent.source, { app = "testing", finding = first.fp }, "source names the finding")
  eq(intent.finding, first, "the finding goes as it is")
  eq(intent.target, vim.NIL, "no target for a new task")
  eq(assert(act.intent(first, "rule")).action, "rules.new", "--do=rule")
  eq(assert(act.intent(first, "ai")).action, "ai.handoff", "--do=ai")
  eq(assert(act.intent(first, "ai")).mode, "agent", "the AI goes to an agent by default")
  local none, why = act.intent(first, "task", "agent")
  ok(none == nil and why:find("form", 1, true) ~= nil, "a mode the target does not take: refused")
  ok(act.intent(first, "wipe") == nil, "an action that is not fixed: refused")
  local private = vim.tbl_extend("force", first, { class = "private" })
  ok(act.intent(private, "task") == nil, "a private finding never leaves: the second lock")

  -- ── pick ──
  eq(act.pick(docs, first.fp), first, "the whole fp")
  eq(act.pick(docs, first.fp:upper()), first, "upper case hex")
  local short = first.fp:sub(1, 8)
  eq(act.pick(docs, short), first, "a unique prefix")
  ok(act.pick(docs, "abc") == nil, "less than 4 hex: refused")
  ok(act.pick(docs, "zzzz") == nil, "no hex: refused")
  ok(act.pick(docs, "0000000000000000") == nil, "an unknown fp")

  -- ── --list: the way back through tasks call find ──
  local asked = {}
  local fake_tasks = function(method, params)
    asked[#asked + 1] = { method = method, params = params }
    if method == "find" then
      return {
        kind = "tasks.find",
        matches = {
          {
            ref = act.REF_PREFIX .. first.fp,
            id = "beta.nvim/fix-it",
            status = "open",
            location = "open",
          },
        },
      }
    end
    if method == "intent" then
      if params.intent.finding.fp == first.fp then
        return {
          kind = "tasks.intent",
          outcome = "exists",
          id = "beta.nvim/fix-it",
          status = "open",
        }
      end
      if params.yes then
        return { kind = "tasks.intent", outcome = "created", id = "beta.nvim/new-one" }
      end
      return {
        kind = "tasks.intent",
        outcome = "would_create",
        area = "beta.nvim",
        title = params.intent.finding.title,
      }
    end
    return nil, "unexpected method " .. method
  end
  local code, out = run({ "--list" }, { tasks = fake_tasks })
  eq(code, 0, "--list: exit 0")
  eq(#out, #docs, "one line per finding")
  eq(asked[1].method, "find", "the way back is a lookup")
  eq(#asked[1].params.refs, #docs, "one ref per finding")
  ok(vim.startswith(asked[1].params.refs[1], "testing-finding:"), "the namespace of D5")
  local line
  for _, l in ipairs(out) do
    if vim.startswith(l, first.fp) then
      line = l
    end
  end
  has(line, "task beta.nvim/fix-it (open)", "the linked task is on the finding's line")

  local _, jout = run({ "--list", "--json" }, { tasks = fake_tasks })
  local j = vim.json.decode(jout[1])
  ok(j.fp ~= nil and j.kind ~= nil and type(j.tasks) == "table", "--json: one object per finding")

  -- without an engine the list still comes, with a note
  local codel, outl, errl = run({ "--list" }, nil, {})
  eq(codel, 0, "--list without a vault: exit 0")
  eq(#outl, #docs, "the findings still come")
  has(table.concat(errl, "\n"), "TASKS_VAULT", "the note names the missing vault")

  -- ── --do=task ──
  asked = {}
  local codee, oute = run({ first.fp, "--do=task" }, { tasks = fake_tasks })
  eq(codee, 0, "a duplicate: exit 0")
  has(table.concat(oute, "\n"), "already there: beta.nvim/fix-it", "a duplicate is named")
  eq(asked[1].method, "intent", "the engine takes the intent")
  eq(asked[1].params.yes, false, "without --yes a dry run")

  local other = docs[2]
  asked = {}
  local coded, outd = run({ other.fp, "--do=task" }, { tasks = fake_tasks })
  eq(coded, 0, "dry run: exit 0")
  has(
    table.concat(outd, "\n"),
    "would create a task in beta.nvim",
    "the dry run says what would happen"
  )
  local codey, outy = run({ other.fp, "--do=task", "--yes" }, { tasks = fake_tasks })
  eq(codey, 0, "--yes: exit 0")
  has(
    table.concat(outy, "\n"),
    "created task beta.nvim/new-one",
    "--yes creates through the engine"
  )
  eq(asked[#asked].params.yes, true, "--yes goes to the engine")

  local coden, _, errn = run({ other.fp, "--do=task" }, nil, {})
  eq(coden, 3, "no task vault: exit 3")
  has(table.concat(errn, "\n"), "TASKS_VAULT", "the message names what is missing")

  local codeu = run({ "0000000000000000", "--do=task" }, { tasks = fake_tasks })
  eq(codeu, 2, "an unknown fp: exit 2")
  eq(run({ first.fp }, { tasks = fake_tasks }), 2, "no --do: exit 2")
  eq(
    run({ first.fp, "--do=task", "--bogus" }, { tasks = fake_tasks }),
    2,
    "an unknown option: exit 2"
  )

  -- ── --do=rule ──
  local rule_calls = {}
  local fake_rules = function(i, o)
    rule_calls[#rule_calls + 1] = { intent = i, opts = o }
    if o.yes then
      return {
        action = "rules.new",
        dry_run = false,
        document = { results = { { id = "LUA-99" } } },
      }
    end
    return { action = "rules.new", dry_run = true, document = { results = { {} } } }
  end
  local coder, outr = run({ first.fp, "--do=rule", "--family=LUA" }, { rules = fake_rules })
  eq(coder, 0, "rule dry run: exit 0")
  has(table.concat(outr, "\n"), "would create rule LUA", "the dry run names the family")
  eq(rule_calls[1].opts, { yes = false, family = "LUA" }, "the family goes to the engine")
  eq(rule_calls[1].intent.action, "rules.new", "the action of a rule")
  local _, outry = run({ first.fp, "--do=rule", "--family=LUA", "--yes" }, { rules = fake_rules })
  has(table.concat(outry, "\n"), "created rule LUA-99", "--yes: the id the engine gave")
  local failing = function()
    return nil, "no_family: no family given"
  end
  local codef, _, errf = run({ first.fp, "--do=rule" }, { rules = failing })
  eq(codef, 1, "the engine refuses: exit 1")
  has(table.concat(errf, "\n"), "no_family", "the engine's reason is shown")

  -- ── --do=ai: the own state folder, nothing started ──
  local file = act.handoff_file(fx.beta, first.fp, fx.state)
  ok(vim.startswith(file, fx.state), "the hand-over lives in testing's state folder")
  local codea, outa = run({ first.fp, "--do=ai" })
  eq(codea, 0, "ai dry run: exit 0")
  has(table.concat(outa, "\n"), "would write the hand-over", "without --yes it only says where")
  eq(vim.uv.fs_stat(file), nil, "nothing written without --yes")
  local codeay, outay = run({ first.fp, "--do=ai", "--yes" })
  eq(codeay, 0, "ai --yes: exit 0")
  local written = vim.json.decode(fixture.read(file))
  eq(written.action, "ai.handoff", "the hand-over is the intent")
  eq(written.finding.fp, first.fp, "of this finding")
  has(table.concat(outay, "\n"), 'claude "Read ', "the command for Claude Code is printed")
  -- a second write replaces the first (Windows does not rename over a file)
  eq(run({ first.fp, "--do=ai", "--yes" }), 0, "written again")
  eq(vim.uv.fs_stat(file .. ".tmp"), nil, "no temporary file left")

  -- ── data classes: a private repository gives nothing ──
  local areas = base .. "/private-areas.json"
  fixture.write(areas, fixture.areas({ ["beta.nvim"] = "private" }))
  local codep, _, errp = run({ "--list", "--areas=" .. areas }, { tasks = fake_tasks })
  eq(codep, 2, "a private repository: exit 2")
  has(table.concat(errp, "\n"), "private", "the reason names the class")

  -- ── the process: only the CLI of the tasks engine ──
  local fake_cli = base .. "/fake-tasks/scripts/tasks.lua"
  local log = base .. "/fake-tasks.log"
  fixture.write(
    fake_cli,
    table.concat({
      "local argv = {}",
      "for i = 1, #arg do argv[#argv + 1] = arg[i] end",
      "local stdin = io.stdin:read('*a')",
      ("local f = assert(io.open(%q, 'ab'))"):format(log),
      "f:write(vim.json.encode({ argv = argv, stdin = vim.json.decode(stdin) }), '\\n')",
      "f:close()",
      "io.stdout:write(vim.json.encode({ kind = 'tasks.intent', outcome = 'would_create', area = 'beta.nvim', title = 'x' }), '\\n')",
    }, "\n")
  )
  local vault = base .. "/vault"
  vim.fn.mkdir(vault, "p")
  local codec, outc = run(
    { other.fp, "--do=task", "--vault=" .. vault, "--tasks-cli=" .. fake_cli },
    nil,
    {}
  )
  eq(codec, 0, "through a real process: exit 0")
  has(table.concat(outc, "\n"), "would create a task in beta.nvim", "the engine's answer")
  local entry = vim.json.decode(vim.split(fixture.read(log), "\n")[1])
  eq(
    { entry.argv[1], entry.argv[2], entry.argv[3] },
    { "call", "intent", "--params=-" },
    "the engine's door"
  )
  eq(entry.argv[4], "--vault=" .. vault, "the vault goes to the engine, testing does not open it")
  eq(entry.stdin.intent.finding.fp, other.fp, "the intent on stdin")
  eq(entry.stdin.yes, false, "a dry run")
  eq(vim.fn.readdir(vault), {}, "testing wrote nothing into the vault")

  -- ── :Testing act: the target, the two steps, nothing written before yes ──
  local ui = require("testing.bindings.act")
  local seams = { engines = ui.engines, ask = ui.ask, select = ui.select, input = ui.input }
  local with_where
  for _, d in ipairs(docs) do
    if type(d.where) == "table" and type(d.where.line) == "number" then
      with_where = with_where or d
    end
  end
  ok(with_where ~= nil, "a finding with a place")
  local here = { file = fx.beta .. "/" .. with_where.where.file, line = with_where.where.line }
  eq(ui.target(docs, fx.beta, here), with_where, "the cursor on the finding's line")
  eq(ui.target(docs, fx.beta, { qf = here, file = "", line = 1 }), with_where, "the quickfix entry")
  eq(
    ui.target(docs, fx.beta, { file = base .. "/elsewhere.lua", line = 1 }),
    nil,
    "a file outside the repository: no target"
  )

  local prompts, asked_q = {}, {}
  ui.engines = { tasks = fake_tasks }
  ui.select = function(items, o, cb)
    prompts[#prompts + 1] = o.prompt
    cb(items[1], 1) -- the first: Task, then (one mode) no second step
  end
  local answer = 1
  ui.ask = function(q, _, cb)
    asked_q[#asked_q + 1] = q
    cb(answer, false)
  end
  asked = {}
  ui.choose(fx.beta, other)
  has(prompts[1], other.title, "the heading names the target")
  eq(#prompts, 1, "a target with one mode skips the second step")
  eq(#asked_q, 1, "a question before anything is written")
  eq(#asked, 1, "Cancel: only the dry run reached the engine")
  eq(asked[1].params.yes, false, "the dry run")
  answer = 2
  asked = {}
  ui.choose(fx.beta, other)
  eq(#asked, 2, "Create: the dry run, then the engine with yes")
  eq(asked[2].params.yes, true, "yes after the answer")
  asked, asked_q = {}, {}
  ui.choose(fx.beta, first)
  eq(#asked_q, 0, "a duplicate asks nothing")
  eq(#asked, 1, "and writes nothing")

  -- the AI: two steps, a hand-over file, the command in register +
  local ai_file = act.handoff_file(fx.beta, other.fp, fx.state)
  os.remove(ai_file)
  prompts = {}
  ui.select = function(items, o, cb)
    prompts[#prompts + 1] = o.prompt
    if #prompts == 1 then
      return cb(items[3], 3) -- AI
    end
    cb(items[1], 1) -- agent
  end
  local real_handoff = act.handoff_file
  act.handoff_file = function(d, fp)
    return real_handoff(d, fp, fx.state)
  end
  answer = 1
  ui.choose(fx.beta, other)
  eq(#prompts, 2, "the AI has a second step: how")
  eq(vim.uv.fs_stat(ai_file), nil, "Cancel: no hand-over")
  answer = 2
  prompts = {}
  local reg = {}
  local real_setreg = vim.fn.setreg
  vim.fn.setreg = function(name, value)
    reg[name] = value
  end
  ui.choose(fx.beta, other)
  vim.fn.setreg = real_setreg
  act.handoff_file = real_handoff
  ok(vim.uv.fs_stat(ai_file) ~= nil, "Write: the hand-over is there")
  has(reg["+"] or "", 'claude "Read ', "the command is in register +")

  ui.engines, ui.ask, ui.select, ui.input = seams.engines, seams.ask, seams.select, seams.input

  dc.load = real_load
  package.loaded["lib.nvim.data_classes"] = real_dc
  restore()
  vim.fn.delete(base, "rf")
end
