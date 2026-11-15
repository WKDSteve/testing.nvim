-- TESTS/testing/tree_ci_spec.lua -- the last pipeline run in the view `tests`: `testing.explorer.ci` reads `ci.json`
-- as untrusted input and makes the pipeline node with its steps and their findings; `testing.explorer.nodes` draws
-- and adds them up (a step counts once, its findings nothing); the view puts the pipeline first, and `r` on it runs
-- the profile, on a step only that step. The pipeline run is a stand-in that records what it was asked.

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil, duplicate-set-field

return function(H)
  local ok = H.ok
  local W = dofile(
    vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
      .. "/watch_support.lua"
  )
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local ci = require("testing.explorer.ci")
  local nodes = require("testing.explorer.nodes")
  local state = require("testing.state")
  local tree = require("testing.integrations.tree")
  local registry = require("lib.nvim.tree.registry")
  local json = require("lib.nvim.json")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  local sopts = { state_dir = sdir }
  vim.fn.mkdir(root .. "/lua", "p")
  vim.fn.writefile({ "local x = 1" }, root .. "/lua/x.lua")
  local function write_doc(doc)
    vim.fn.mkdir(vim.fs.dirname(ci.path(root, sopts)), "p")
    local f = assert(io.open(ci.path(root, sopts), "wb"))
    f:write(type(doc) == "string" and doc or assert(json.encode(doc)))
    f:close()
  end
  local function child(node, label)
    for _, c in ipairs(node.children or {}) do
      if c.label == label then
        return c
      end
    end
    return nil
  end

  local DOC = {
    schema = "testing-ci/1",
    profile = "fast",
    verdict = "red",
    time = "2026-11-14T10:00:00Z",
    steps = {
      { name = "stylua", state = "green", ms = 700, findings = {}, findings_total = 0 },
      {
        name = "luacheck",
        state = "red",
        ms = 1500,
        findings = {
          { file = "lua/x.lua", line = 3, col = 7, text = "unused variable 'x'" },
          { file = "lua\\x.lua", line = 9, text = "line is too long" },
        },
        findings_total = 5,
      },
      {
        name = "suite",
        state = "skipped",
        ms = 0,
        reason = "an earlier step is red",
        findings = {},
      },
      {
        name = "tools",
        state = "infra",
        ms = 3,
        reason = "stylua is not installed",
        findings = {},
      },
    },
  }

  -- reading the document ---------------------------------------------------------------
  eq(ci.read(root, sopts), nil, "no document: nothing")
  write_doc(DOC)
  local doc = ci.read(root, sopts)
  eq(
    { doc.profile, doc.verdict, #doc.steps, doc.steps[2].findings_total },
    { "fast", "red", 4, 5 },
    "the document of the last run"
  )
  eq(
    doc.steps[2].findings[2].file,
    "lua/x.lua",
    "a file of a finding is spelled with forward slashes"
  )

  for name, bad in pairs({
    ["not JSON"] = "{ nope",
    ["another schema"] = { schema = "testing-ci/2", profile = "fast", steps = {} },
    ["no steps"] = { schema = "testing-ci/1", profile = "fast" },
    ["a profile that is no name"] = { schema = "testing-ci/1", profile = "fast --all", steps = {} },
    ["an array"] = { 1, 2, 3 },
  }) do
    write_doc(bad)
    eq(ci.read(root, sopts), nil, "refused: " .. name)
  end
  local real_max = ci.MAX_BYTES
  write_doc(DOC)
  ci.MAX_BYTES = 10
  eq(ci.read(root, sopts), nil, "refused: a file over the size cap, before it is decoded")
  ci.MAX_BYTES = real_max

  local hostile = ci.validate({
    schema = "testing-ci/1",
    profile = "fast",
    verdict = "red\27[31m",
    steps = {
      { name = "ok", state = "red", ms = -5, findings_total = 1e12 },
      { name = "--force", state = "red" },
      { name = "two words", state = "red" },
      { name = "ok", state = "green" },
      "junk",
      {
        name = "paths",
        state = "red",
        reason = "bell\7 and a line\nbreak",
        findings = {
          { file = "../../etc/passwd", line = 1, text = "outside" },
          { file = "C:/Windows/x", line = 1, text = "a drive" },
          { file = "lua/x.lua", line = -3, col = 0.5, text = "esc\27[2J" },
          { file = "lua/x.lua", line = 2 },
          "junk",
        },
      },
    },
  })
  eq(
    vim.tbl_map(function(s)
      return s.name
    end, hostile.steps),
    { "ok", "paths" },
    "a step whose name could not go on a command line is dropped, and a name counts once"
  )
  eq(hostile.verdict, "unknown", "a verdict that is no plain word is not shown")
  eq(
    { hostile.steps[1].ms, hostile.steps[1].findings_total },
    { 0, 0 },
    "numbers out of range are not taken"
  )
  local found = hostile.steps[2].findings
  eq(
    { #found, found[1].file, found[2].file, found[3].file },
    { 3, nil, nil, "lua/x.lua" },
    "a finding outside the project keeps its text and loses its place; one without a text is dropped"
  )
  eq(
    { found[3].line, found[3].col, found[3].text:find("\27", 1, true) },
    { nil, nil, nil },
    "a line or column that is none is dropped, a control character does not reach a window"
  )
  ok(not hostile.steps[2].reason:find("[%c]"), "the reason of a step is one clean line")
  local many = { schema = "testing-ci/1", profile = "p", steps = {} }
  for i = 1, ci.MAX_STEPS + 20 do
    many.steps[i] = { name = "s" .. i, state = "green" }
  end
  eq(#ci.validate(many).steps, ci.MAX_STEPS, "the steps are bounded")

  -- the nodes -----------------------------------------------------------------------------
  local R = nodes.norm(root)
  local node = ci.node(R, doc)
  eq({ node.id, node.kind, node.label }, { "tests:ci", "ci", "Pipeline fast" }, "the pipeline node")
  local lint = child(node, "luacheck")
  eq(
    { lint.id, lint.kind, lint.status, lint.data.testing.step },
    { "tests:ci:step:luacheck", "ci_step", "fail", "luacheck" },
    "a red step: a unit with the status fail"
  )
  eq(
    vim.tbl_map(function(s)
      return s.status
    end, node.children),
    { "pass", "fail", "skip", "error" },
    "green, red, skipped and infra as the statuses a tree adds up with"
  )
  eq(
    ci.node(
      R,
      ci.validate({
        schema = "testing-ci/1",
        profile = "p",
        steps = { { name = "s", state = "dancing" } },
      })
    ).children[1].status,
    "never",
    "a state nobody knows is not green"
  )
  local finding = lint.children[1]
  eq(
    { finding.kind, finding.path, finding.data.lnum, finding.data.col, finding.columns },
    { "ci_finding", R .. "/lua/x.lua", 3, 6, { "lua/x.lua:3" } },
    "a finding goes to its file, line and column (0-based for the jump)"
  )
  eq(lint.children[3].label, "... and 3 more", "how many findings the document does not list")
  eq(
    { child(node, "tools").children[1].label, child(node, "tools").children[1].kind },
    { "stylua is not installed", "note" },
    "a step without findings says why below it"
  )
  eq(child(node, "stylua").children, nil, "a green step has nothing below it")

  -- drawn and added up by the nodes of the view ----------------------------------------------
  local top = nodes.build({ root = root, cases = {}, first = { node } })
  eq(top.children[1].id, "tests:ci", "the pipeline stands first in the view")
  eq(
    { node.icon, node.hl, node.columns, node.open },
    { "✗", "DiagnosticError", { "2/4", "2.2s" }, true },
    "the pipeline: the worst of its steps, red over all, the time; open while something is red"
  )
  eq(
    { lint.icon, lint.columns, lint.open },
    { "✗", { "1.5s" }, true },
    "a red step: its sign and its time"
  )
  eq(
    { finding.icon, finding.columns },
    { nil, { "lua/x.lua:3" } },
    "a finding carries no sign of its own"
  )
  local lib_tree = require("lib.nvim.tree").new({
    root = top,
    severity = nodes.SEVERITY,
    aggregate = nodes.aggregate,
  })
  eq({
    lib_tree:agg("tests:ci").status,
    lib_tree:agg("tests:ci").counts,
    lib_tree:agg("tests:ci").total,
  }, { "error", { fail = 1, error = 1 }, 4 }, "the tree: a step counts once, its findings nothing")
  eq(nodes.run_flags(lint), nil, "a step is no test run")
  eq(nodes.preview(lint), nil, "... and has no preview of a case")

  -- which run a node stands for ----------------------------------------------------------------
  eq(ci.run_of({ node }), { profile = "fast" }, "the pipeline node: the whole profile")
  eq(ci.run_of({ lint }), { profile = "fast", steps = { "luacheck" } }, "a step: that step")
  eq(ci.run_of({ finding }), { profile = "fast", steps = { "luacheck" } }, "a finding: its step")
  eq(
    ci.run_of({ lint, child(node, "stylua"), finding }),
    { profile = "fast", steps = { "luacheck", "stylua" } },
    "several steps, each once"
  )
  eq(ci.run_of({ lint, node }), { profile = "fast" }, "the pipeline among them: the whole profile")
  eq(ci.run_of({ { id = "x", label = "x" } }), nil, "a node of somebody else: no run")

  -- the view ---------------------------------------------------------------------------------------
  registry.reset()
  local runs, tests = {}, {}
  local finish = function()
    tree.unregister()
    registry.reset()
  end
  local worked, err = pcall(function()
    tree.register({
      root = function()
        return root
      end,
      state_opts = sopts,
      files = function()
        return {}
      end,
      ci_run = function(run)
        runs[#runs + 1] = run
      end,
      run = function(run)
        tests[#tests + 1] = run
      end,
    })
    local source = registry.get("source", "tests")
    local shown = source.root({})
    eq(shown.children[1].id, "tests:ci", "the view shows the last pipeline run first")
    local by_name = {}
    for _, action in ipairs(source.actions) do
      by_name[action.name] = action
    end
    local run_ci, run_tests = by_name["tests.ci"], by_name["tests.run"]
    eq(run_ci.key, run_tests.key, "the run key is one key: which run it starts depends on the node")
    local step = child(shown.children[1], "luacheck")
    eq(
      { run_ci.when(step, {}), run_tests.when(step, {}) },
      { true, false },
      "on a step the pipeline action applies and the test run steps back"
    )
    eq(run_ci.when({ id = "x", label = "x" }, {}), false, "... and not on a node of somebody else")
    run_ci.run({ step }, {})
    eq(
      runs[#runs],
      { root = root, profile = "fast", steps = { "luacheck" } },
      "r on a step runs that step again"
    )
    run_ci.run({ shown.children[1] }, {})
    eq(runs[#runs], { root = root, profile = "fast" }, "r on the pipeline runs the profile")
    eq(#tests, 0, "... and no test run was started for it")

    -- a new run of the pipeline shows like a new result: the state folder is followed
    local resets = 0
    local stop = source.subscribe({}, {
      reset = function()
        resets = resets + 1
      end,
      push = function() end,
      invalidate = function() end,
    })
    local green = vim.deepcopy(DOC)
    green.verdict = "green"
    for _, s in ipairs(green.steps) do
      s.state, s.findings, s.findings_total, s.reason = "green", {}, 0, nil
    end
    -- written again while not seen: the watch may not be armed yet right after subscribe (FSEvents on macOS)
    W.until_seen(function()
      write_doc(green)
    end, function()
      return resets > 0
    end)
    ok(resets > 0, "a pipeline run that ended tells the view")
    shown = source.root({})
    eq(
      { shown.children[1].icon, shown.children[1].columns[1], shown.children[1].open },
      { "✓", "4", nil },
      "... which shows the new run: green, four steps, closed"
    )
    stop()

    -- a pipeline that is going -------------------------------------------------------------------
    -- The stream is what `testing ci --events` wrote for a run of three steps with --keep-going (recorded; the
    -- `suite_progress` lines are the editor's, from the suite's own stream). The view is told as a tree would
    -- be: `reset` makes it ask for the root again, `push` changes one node.
    local RECORDED = {
      '{"event":"run_start","profile":"fast","root":"proj","steps":["stylua","luacheck","suite"],"ts":1,"v":1}',
      '{"event":"step_start","index":1,"step":"stylua","total":3,"ts":1,"v":1}',
      '{"event":"step_end","exit":0,"findings_total":0,"index":1,"ms":700,"state":"green","step":"stylua","total":3,"ts":2,"v":1}',
      '{"event":"step_start","index":2,"step":"luacheck","total":3,"ts":2,"v":1}',
      '{"event":"step_end","exit":1,"findings_total":2,"index":2,"ms":1500,"state":"red","step":"luacheck","total":3,"ts":3,"v":1}',
      '{"event":"step_start","index":3,"step":"suite","suite_events":"e.suite.ndjson","total":3,"ts":3,"v":1}',
      '{"event":"suite_progress","step":"suite","done":0,"total":2}',
      '{"event":"suite_progress","step":"suite","done":1,"total":2}',
      '{"event":"step_end","exit":0,"findings_total":0,"index":3,"ms":4000,"state":"green","step":"suite","total":3,"ts":9,"v":1}',
      '{"event":"run_done","exit":1,"first_red":"luacheck","ts":9,"verdict":"red","v":1}',
    }
    local editor = require("testing.ci.editor")
    local real_listen = editor.listen
    local heard, unheard = nil, 0
    editor.listen = function(fn)
      heard = fn
      return function()
        unheard = unheard + 1
      end
    end
    local live_resets, pushes = 0, {}
    local stop_live = source.subscribe({}, {
      reset = function()
        live_resets = live_resets + 1
        shown = source.root({})
      end,
      push = function(update)
        pushes[update.id] = update
      end,
      invalidate = function() end,
    })
    editor.listen = real_listen
    ok(type(heard) == "function", "a view on screen listens to the pipeline runs of the editor")
    shown = source.root({})
    ---Feed line `i` of the recording; answers how many resets and which pushes it caused.
    local function feed(i, other_root)
      local before = live_resets
      pushes = {}
      heard(other_root or root, vim.json.decode(RECORDED[i]))
      return live_resets - before
    end
    local function steps_of()
      return vim.tbl_map(function(s)
        return { s.label, s.status, s.icon, s.columns }
      end, shown.children[1].children)
    end

    eq(feed(1, root .. "-other"), 0, "a run of another project changes nothing here")
    eq(#shown.children[1].children, 4, "... the last document is still shown")
    eq(feed(1), 1, "run_start: the view asks for the root again")
    eq(steps_of(), {
      { "stylua", "queued", "◌", {} },
      { "luacheck", "queued", "◌", {} },
      { "suite", "queued", "◌", {} },
    }, "... and shows the planned steps as queued, in place of the last run")
    eq(
      { shown.children[1].label, shown.children[1].icon, shown.children[1].open },
      { "Pipeline fast", "◌", true },
      "... the pipeline is open while its run goes: the steps are in sight"
    )

    eq(feed(2), 0, "step_start: no new root")
    eq(
      { pushes["tests:ci:step:stylua"].icon, pushes["tests:ci:step:stylua"].status },
      { "●", "running" },
      "... the step is pushed as running"
    )
    eq(pushes["tests:ci"].icon, "●", "... and the pipeline above it")
    eq(feed(3), 0, "step_end of a green step: a push")
    eq(
      { pushes["tests:ci:step:stylua"].icon, pushes["tests:ci:step:stylua"].columns },
      { "✓", { "700ms" } },
      "... with its state and its time"
    )
    eq(
      pushes["tests:ci"].icon,
      "◌",
      "... the pipeline shows the worst of its steps: two are queued"
    )
    feed(4)
    eq(
      feed(5),
      1,
      "step_end of a step with findings: they are lines below it, the root is asked for again"
    )
    local red_step = child(shown.children[1], "luacheck")
    eq(
      { red_step.icon, red_step.columns, red_step.open, red_step.children[1].label },
      { "✗", { "1.5s" }, true, "2 finding(s), listed when the run has ended" },
      "... the step is red and open, and says how many findings wait for the end of the run"
    )
    eq(
      shown.children[1].columns,
      { "1/3", "2.2s" },
      "... the pipeline counts it: one red of three, and the time so far"
    )
    feed(6)
    eq(pushes["tests:ci:step:suite"].icon, "●", "the suite step runs")
    feed(7)
    eq(pushes["tests:ci:step:suite"].columns, { "0/2" }, "... and shows how far it is")
    feed(8)
    eq(pushes["tests:ci:step:suite"].columns, { "1/2" }, "... file by file")
    eq(pushes["tests:ci"].icon, "✗", "... the pipeline stays red meanwhile")
    eq(feed(8), 0, "the same progress again is nothing new")
    eq(pushes, {}, "... no push")
    feed(9)
    eq(
      pushes["tests:ci:step:suite"].columns,
      { "4.0s" },
      "step_end: the progress gives way to the time"
    )
    -- the run writes its document, then says it is done
    write_doc(DOC)
    eq(feed(10), 1, "run_done: the root is asked for again")
    eq(
      { #shown.children[1].children, child(shown.children[1], "luacheck").children[1].label },
      { 4, "unused variable 'x'" },
      "... and is the document the run wrote, with the findings"
    )
    eq(nodes.data(shown.children[1]).unfold, nil, "... a run that has ended is no longer held open")
    eq(feed(2), 0, "an event after the end of the run changes nothing")
    eq(pushes, {}, "... no push")

    -- a killed run: the planned steps show, then the end the editor made up brings the last document back
    feed(1)
    feed(2)
    eq(#shown.children[1].children, 3, "a second run: its steps again")
    local before_kill = live_resets
    heard(root, { event = "run_done", synthetic = true })
    eq(
      { live_resets - before_kill, #shown.children[1].children },
      { 1, 4 },
      "a killed run leaves the last document: nothing stays queued or running"
    )

    -- the events are the words of a child: what could not be shown or run is not taken
    for name, bad in pairs({
      ["a profile that is no name"] = {
        event = "run_start",
        profile = "fast --all",
        steps = { "a" },
      },
      ["no steps"] = { event = "run_start", profile = "fast" },
      ["only steps that are no names"] = {
        event = "run_start",
        profile = "fast",
        steps = { "--force", 7, "two words" },
      },
    }) do
      heard(root, bad)
      eq(#shown.children[1].children, 4, "refused: " .. name .. " (the last document stays)")
    end
    heard(
      root,
      { event = "run_start", profile = "fast", steps = { "ok", "--force", "ok", "also" } }
    )
    eq(
      vim.tbl_map(function(s)
        return s.label
      end, shown.children[1].children),
      { "ok", "also" },
      "a step whose name could not go on a command line is dropped, and a name counts once"
    )
    pushes = {}
    heard(root, { event = "step_start", step = "nobody" })
    heard(root, { event = "suite_progress", step = "also", done = 1, total = 2 })
    heard(root, "junk")
    eq(
      pushes,
      {},
      "a step the run did not plan, progress of a step that is not running, junk: nothing"
    )
    heard(root, { event = "step_start", step = "ok" })
    heard(root, { event = "suite_progress", step = "ok", done = -4, total = "many" })
    eq(pushes["tests:ci:step:ok"].columns, {}, "progress that is no number is not drawn")
    heard(
      root,
      { event = "step_end", step = "ok", state = "red\27[31m", ms = -1, reason = "bell\7" }
    )
    local odd = child(shown.children[1], "ok")
    eq(
      { odd.status, odd.children[1].label:find("[%c]") },
      { "never", nil },
      "a state that is no plain word is not green, a reason is one clean line"
    )

    stop_live()
    eq(unheard, 1, "a view that is gone stops listening")
    local after_stop = live_resets
    tree.on_ci_event(root, vim.json.decode(RECORDED[1]))
    eq(live_resets, after_stop, "... and is told nothing more")
    eq(#source.root({}).children[1].children, 4, "... the run it followed is forgotten with it")

    -- a run that goes on while the view is off screen: the tree shows the files (the badges keep this module
    -- awake), the run goes on and ends, and the view comes back to what is true by then
    editor.listen = function(fn)
      heard = fn
      return function() end
    end
    local stop_badges = registry.get("decorator", "tests").subscribe(function() end)
    editor.listen = real_listen
    local function show()
      return source.subscribe({}, {
        reset = function()
          shown = source.root({})
        end,
        push = function() end,
        invalidate = function() end,
      })
    end
    local hide = show()
    feed(1)
    eq(#shown.children[1].children, 3, "off screen: the run starts while the view is shown")
    hide()
    feed(2)
    feed(3)
    hide = show()
    shown = source.root({})
    eq(
      { steps_of()[1][2], steps_of()[2][2] },
      { "pass", "queued" },
      "off screen: a step that ended meanwhile has its state when the view is back"
    )
    hide()
    feed(10)
    hide = show()
    shown = source.root({})
    eq(
      #shown.children[1].children,
      4,
      "off screen: a run that ended meanwhile leaves no step queued or running: the document shows"
    )
    hide()
    stop_badges()

    os.remove(ci.path(root, sopts))
    eq(
      source.root({}).children[1].kind,
      "note",
      "no pipeline run: the view is as it was without one"
    )
    eq(state.load(root, sopts).cases, {}, "nothing of this touched the result of the specs")
  end)
  finish()
  vim.fn.delete(sdir, "rf")
  vim.fn.delete(root, "rf")
  if not worked then
    error(err, 0)
  end
end
