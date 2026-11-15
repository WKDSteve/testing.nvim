-- TESTS/testing/explorer_nodes_spec.lua -- testing.explorer.nodes: the last result as tree nodes. The shape (folder,
-- file, describe, case), what a case and a branch show, stale, the spec files that never ran, the severity order and
-- the aggregate a tree adds up with, the flags of the run a node stands for, and the preview of a red case. Pure:
-- nothing is read, the one tree used is lib.nvim's.

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
  local nodes = require("testing.explorer.nodes")

  local ROOT = "C:/proj"
  ---@return Testing.State.Case
  local function case(file, describe, name, status, extra)
    local id = table.concat(vim.list_extend(vim.list_extend({ file }, describe), { name }), "::")
    return vim.tbl_extend("force", {
      id = id,
      file = file,
      describe = #describe > 0 and describe or nil,
      name = name,
      status = status,
      duration_ms = 10,
    }, extra or {})
  end
  ---The child of `node` with this label.
  local function child(node, label)
    for _, c in ipairs(node.children or {}) do
      if c.label == label then
        return c
      end
    end
    return nil
  end
  local function labels(node)
    return vim.tbl_map(function(c)
      return c.label
    end, node.children)
  end

  local cases = {
    case("TESTS/parser_spec.lua", { "parser", "lists" }, "reads a list", "pass", { line = 12 }),
    case("TESTS/parser_spec.lua", { "parser", "lists" }, "rejects junk", "fail", {
      line = 20,
      message = "expected 1, got 2",
      expected = "1",
      actual = "2",
      fails = { { line = 22, msg = "expected 1, got 2" } },
    }),
    case("TESTS/parser_spec.lua", { "parser" }, "is skipped", "skip", { line = 30 }),
    case("TESTS/parser_spec.lua", {}, "top level", "pass", { line = 40 }),
    case("TESTS/unit/green_spec.lua", { "green" }, "one", "pass", { line = 3 }),
    case("TESTS/unit/green_spec.lua", { "green" }, "two", "xfail", { line = 5 }),
    case("TESTS/unit/idle_spec.lua", { "idle" }, "one", "pass", { line = 3 }),
    case("TESTS/unit/idle_spec.lua", { "idle" }, "two", "skip", { line = 5 }),
    case("TESTS/unit/old_spec.lua", { "old" }, "green then", "pass", { line = 3 }),
    case("TESTS/unit/old_spec.lua", { "old" }, "red then", "error", { line = 5 }),
    {
      id = "TESTS/whole_spec.lua::whole_spec.lua",
      file = "TESTS/whole_spec.lua",
      name = "whole_spec.lua",
      status = "fail",
      duration_ms = 1500,
      message = "boom",
      fails = { { line = 7, msg = "boom" }, { line = 9, msg = "bang" } },
      fails_total = 5,
    },
  }
  local asked = {}
  local root = nodes.build({
    root = "c:\\proj",
    cases = cases,
    stale = { ["TESTS/unit/old_spec.lua"] = true },
    files = { "TESTS/parser_spec.lua", "TESTS/never_spec.lua" },
    positions = function(file)
      asked[#asked + 1] = file
      return {
        { kind = "describe", name = "never", line = 1, path = {}, dynamic = false },
        { kind = "it", name = "a", line = 2, path = { "never" }, dynamic = false },
        { kind = "it", name = "a", line = 3, path = { "never" }, dynamic = false },
        { kind = "pending", line = 4, path = { "never" }, dynamic = true },
      }
    end,
  })

  -- the shape ---------------------------------------------------------------------
  eq({ root.id, root.kind, root.label }, { "tests:root", "root", "Tests" }, "the root")
  eq(labels(root), { "TESTS" }, "one spec folder below the root")
  local tests = child(root, "TESTS")
  eq(
    { tests.id, tests.kind, tests.path },
    { "tests:dir:TESTS", "dir", ROOT .. "/TESTS" },
    "a folder: its path, the drive letter upper case"
  )
  eq(
    labels(tests),
    { "unit", "never_spec.lua", "parser_spec.lua", "whole_spec.lua" },
    "folders first, then the files by name"
  )
  local parser = child(tests, "parser_spec.lua")
  eq(
    { parser.id, parser.kind, parser.path },
    { "tests:file:TESTS/parser_spec.lua", "file", ROOT .. "/TESTS/parser_spec.lua" },
    "a spec file carries its path"
  )
  eq(labels(parser), { "parser", "top level" }, "describes and cases of a file, in source order")
  local describe = child(parser, "parser")
  eq(
    { describe.id, describe.kind, describe.path },
    { "tests:describe:TESTS/parser_spec.lua::parser", "describe", nil },
    "a describe is a group, not a place in a file: no path"
  )
  eq(labels(describe), { "lists", "is skipped" }, "a describe in a describe")
  local red = child(child(describe, "lists"), "rejects junk")
  eq({ red.id, red.kind, red.status, red.path, red.data.lnum }, {
    "tests:case:TESTS/parser_spec.lua::parser::lists::rejects junk",
    "case",
    "fail",
    ROOT .. "/TESTS/parser_spec.lua",
    20,
  }, "a case: a stable id, its status, where it is")
  eq(red.children, nil, "a case in a describe is a leaf")
  eq(parser.status, nil, "a branch carries no status of its own: the tree adds up")

  -- what is drawn -------------------------------------------------------------------
  eq({ red.icon, red.hl, red.columns }, { "✗", "DiagnosticError", { "10ms" } }, "a red case")
  eq(
    { parser.icon, parser.hl, parser.columns },
    { "✗", "DiagnosticError", { "1/4", "40ms" } },
    "a file: the worst below it, red over all, the time"
  )
  local green = child(child(tests, "unit"), "green_spec.lua")
  eq(
    { green.icon, green.hl, green.columns },
    { "✓", "DiagnosticOk", { "2", "20ms" } },
    "green: pass and xfail, the count alone"
  )
  eq(child(child(tests, "unit"), "idle_spec.lua").icon, "○", "a skipped case below: not green")
  eq(
    { parser.open, describe.open, green.open },
    { true, true, nil },
    "what is red is open, the rest is not"
  )
  eq(tests.open, true, "the one spec folder is open")
  -- nothing red below it: the folder is open because it is the only one, and stays so when the tree is indexed
  -- (the index writes on every node again what it shows)
  local calm = nodes.build({
    root = ROOT,
    cases = { case("TESTS/unit/green_spec.lua", { "g" }, "one", "pass", { line = 1 }) },
  })
  local calm_dir = calm.children[#calm.children]
  eq(calm_dir.open, true, "the one spec folder is open when nothing below it is red")
  nodes.index(calm)
  eq(calm_dir.open, true, "... and still after the tree was indexed")
  eq(
    child(calm_dir, "unit").open,
    nil,
    "... a folder below it that is not the only one of the project stays closed"
  )
  eq({ nodes.duration(7.4), nodes.duration(1400), nodes.duration(125000) }, {
    "7ms",
    "1.4s",
    "2m05s",
  }, "a duration")
  eq(nodes.look("brand_new").icon, "?", "a status nobody knows is not drawn as green")

  -- stale -----------------------------------------------------------------------------
  local old = child(child(child(tests, "unit"), "old_spec.lua"), "old")
  eq(
    { child(old, "green then").status, child(old, "green then").data.testing.recorded },
    { "stale", "pass" },
    "an old green is stale, and what the run said is kept"
  )
  eq(child(old, "red then").status, "error", "an old red stays red")

  -- a file that is one case ---------------------------------------------------------------
  local whole = child(tests, "whole_spec.lua")
  eq(
    { whole.kind, whole.status, whole.data.testing.case, whole.columns },
    { "file", "fail", "TESTS/whole_spec.lua::whole_spec.lua", { "1.5s" } },
    "a file that is one case is that case"
  )
  eq(
    labels(whole),
    { "boom", "bang", "... and 3 more" },
    "... with its failing assertions below it, and how many more there were"
  )
  eq(
    { whole.children[1].data.lnum, whole.children[1].status, whole.children[1].path },
    { 7, nil, ROOT .. "/TESTS/whole_spec.lua" },
    "an assertion goes to its line and is no case"
  )

  -- never ran ---------------------------------------------------------------------------
  local never = child(tests, "never_spec.lua")
  eq(
    { never.status, never.icon, never.columns, type(never.children) },
    { "never", "·", {}, "function" },
    "a spec file that never ran: said so, its cases are read when it is opened"
  )
  eq(asked, {}, "... and not before")
  local got
  never.children(never, function(list)
    got = list
  end)
  eq(asked, { "TESTS/never_spec.lua" }, "opening it asks for the calls of the file")
  eq(#got, 1, "the describe")
  eq(
    vim.tbl_map(function(c)
      return { c.id, c.status, c.data.lnum }
    end, got[1].children),
    {
      { "tests:case:TESTS/never_spec.lua::never::a", "never", 2 },
      { "tests:case:TESTS/never_spec.lua::never::a#2", "never", 3 },
      { "tests:case:TESTS/never_spec.lua::never::<dynamic>", "never", 4 },
    },
    "its cases with the ids a run will give them"
  )
  eq(
    nodes.build({
      root = ROOT,
      cases = {},
      files = { "TESTS/x_spec.lua" },
    }).children[1].children[1].children,
    nil,
    "without a reader of positions a file that never ran is a leaf"
  )
  eq(
    labels(nodes.build({ root = ROOT, cases = {} })),
    { "no spec files and no result yet" },
    "nothing at all: a line that says so"
  )

  -- adding up -----------------------------------------------------------------------------
  eq(nodes.SEVERITY[1], "crash", "the worst status first")
  eq(nodes.SEVERITY[#nodes.SEVERITY], "pass", "green last")
  local rank = {}
  for i, status in ipairs(nodes.SEVERITY) do
    rank[status] = i
  end
  ok(
    rank.fail < rank.running and rank.running < rank.stale and rank.stale < rank.never,
    "red before running before stale before never"
  )
  ok(rank.skip < rank.xfail and rank.skip < rank.pass, "skip is never green")
  eq(nodes.worse("pass", "skip"), "skip", "worse: skip over pass")
  eq(nodes.worse("brand_new", "pass"), "brand_new", "worse: an unknown status over a green one")
  eq(nodes.worse(nil, "pass"), "pass", "worse: anything over nothing")

  local tree = require("lib.nvim.tree").new({
    root = root,
    severity = nodes.SEVERITY,
    aggregate = nodes.aggregate,
  })
  local function agg(id)
    return tree:agg(id)
  end
  eq(
    { agg(parser.id).status, agg(parser.id).counts, agg(parser.id).total },
    { "fail", { fail = 1 }, 4 },
    "the tree: a file is as bad as its worst case, and counts the red ones only"
  )
  eq(
    { agg(green.id).status, agg(green.id).counts },
    { "xfail", {} },
    "the tree: nothing red, nothing counted"
  )
  eq(
    agg("tests:file:TESTS/unit/idle_spec.lua").status,
    "skip",
    "the tree: a skipped case keeps a file from being green"
  )
  eq(
    { agg(whole.id).status, agg(whole.id).counts, agg(whole.id).total },
    { "fail", { fail = 1 }, 1 },
    "the tree: a case counts once, whatever stands below it"
  )
  eq(
    { agg(root.id).status, agg(root.id).counts },
    { "error", { fail = 2, error = 1 } },
    "the tree: the root counts every red case"
  )
  eq(
    nodes.aggregate({ id = "x", label = "x" }, {
      { status = "pass", counts = {}, total = 1 },
      { status = "brand_new", counts = {}, total = 1 },
    }, { status = "pass", counts = {}, total = 2 }).status,
    "brand_new",
    "aggregate: a status nobody knows is not rolled up to green"
  )

  -- a changed case ---------------------------------------------------------------------------
  local green_case = child(child(green, "green"), "one")
  green_case.status = "fail"
  nodes.restyle(green)
  eq(
    { green.icon, green.columns, green.open, green_case.icon },
    { "✗", { "1/2", "20ms" }, true, "✗" },
    "restyle writes what a branch shows again after a case changed"
  )

  -- the run of a node ----------------------------------------------------------------------------
  eq(nodes.run_flags(root), {}, "the root: everything")
  eq(nodes.run_flags(tests), { file = { "TESTS/" } }, "a folder: the files below it")
  eq(nodes.run_flags(parser), { file = { "TESTS/parser_spec.lua" } }, "a file")
  eq(nodes.run_flags(describe), {
    file = { "TESTS/parser_spec.lua" },
    filter = { "TESTS/parser_spec.lua::parser::" },
  }, "a describe: the prefix of the ids below it")
  eq(nodes.run_flags(red), {
    file = { "TESTS/parser_spec.lua" },
    filter = { "TESTS/parser_spec.lua::parser::lists::rejects junk" },
  }, "a case: its id")
  eq(nodes.run_flags(whole), { file = { "TESTS/whole_spec.lua" } }, "a file that is one case")
  eq(nodes.run_flags(whole.children[1]), {
    file = { "TESTS/whole_spec.lua" },
    filter = { "TESTS/whole_spec.lua::whole_spec.lua" },
  }, "an assertion: its case")
  eq(nodes.run_flags({ id = "x", label = "x" }), nil, "a node of somebody else: no run")
  eq(nodes.run_flags(whole.children[3]), nil, "a note: no run")

  -- the preview -----------------------------------------------------------------------------------
  local preview = nodes.preview(red)
  eq(
    { preview.title, preview.filetype },
    { "TESTS/parser_spec.lua::parser::lists::rejects junk", "markdown" },
    "the preview of a red case is named after it"
  )
  local text = table.concat(preview.lines, "\n")
  for _, needle in ipairs({
    "status: fail",
    "time: 10ms",
    "expected 1, got 2",
    "## expected\n\n1",
    "## actual\n\n2",
    "- line 22: expected 1, got 2",
  }) do
    H.has(text, needle, "the preview says " .. needle)
  end
  H.has(
    table.concat(nodes.preview(whole).lines, "\n"),
    "- ... and 3 more",
    "the preview says how many assertions it does not list"
  )
  eq(nodes.preview(green_case), nil, "a case with nothing to say has no preview: its file is shown")
  eq(nodes.preview(parser), nil, "nor has a branch")
  local old_red = child(old, "red then")
  old_red.status, old_red.data.testing.message = "stale", "was red"
  H.has(
    table.concat(nodes.preview(old_red).lines, "\n"),
    "status: error (stale: the file changed since)",
    "the preview of an old result says that it is old"
  )
end
