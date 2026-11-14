-- TESTS/testing/tree_ci_spec.lua -- the last pipeline run in the view `tests`: `testing.explorer.ci` reads `ci.json`
-- as untrusted input and makes the pipeline node with its steps and their findings; `testing.explorer.nodes` draws
-- and adds them up (a step counts once, its findings nothing); the view puts the pipeline first, and `r` on it runs
-- the profile, on a step only that step. The pipeline run is a stand-in that records what it was asked.

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
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
    write_doc(green)
    vim.wait(4000, function()
      return resets > 0
    end, 20)
    ok(resets > 0, "a pipeline run that ended tells the view")
    shown = source.root({})
    eq(
      { shown.children[1].icon, shown.children[1].columns[1], shown.children[1].open },
      { "✓", "4", nil },
      "... which shows the new run: green, four steps, closed"
    )
    stop()

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
