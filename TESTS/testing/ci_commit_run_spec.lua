-- TESTS/testing/ci_commit_run_spec.lua -- `testing ci commit` verdicts on a fixture repository: a green commit is
-- clean, a commit that turns a step red is a regression, one that leaves it red is known-red, a docs-only commit is not
-- run, a broken suite is a new finding of the suite, and a range reports every commit. The operation around them (kept
-- results, a dirty tree, snapshots, errors) is in ci_commit_ops_spec.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local S = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
      .. "/ci_commit_support.lua"
  ).new(H, "ci-commit")
  local eq, has, call, tmp = S.eq, S.has, S.call, S.tmp

  local root, c1 = S.project("proj", { ["gate.txt"] = "green\n", ["README.md"] = "# proj\n" })
  local c2 = S.commit(root, { ["gate.txt"] = "red\n" }, "turn the gate red")
  local c3 = S.commit(root, { ["lua/proj/x.lua"] = "return 1\n" }, "a change, the gate stays red")
  local c4 = S.commit(root, { ["README.md"] = "# proj\n\nmore\n" }, "docs only")
  local c5 = S.commit(
    root,
    { ["gate.txt"] = "green\n", ["TESTS/a_spec.lua"] = S.BOOM },
    "gate fixed, suite broken"
  )
  local c6 = S.commit(root, { ["TESTS/a_spec.lua"] = S.PASS }, "suite fixed")

  do
    local r = call(root, c1, "--agent")
    eq(r.code, 0, "a green root commit: exit 0")
    has(r.first, "ci commit " .. c1:sub(1, 7) .. " CLEAN full 2 steps exit 0", "... clean")
    local system = require("testing.ci.commit").system()
    has(r.out, "checked on " .. system .. " only", "... and says which system that speaks for")
    has(r.out, "`testing ci remote`", "... and where the others are")
  end

  do
    local r = call(root, c2, "--agent")
    eq(r.code, 1, "the gate turns red: exit 1")
    has(r.first, "REGRESSION 1 new, 0 known, 0 fixed (gate 1) exit 1", "... a regression")
    has(r.out, "  new   gate: red", "... the new red step")
    has(r.out, "  rerun testing ci commit " .. c2:sub(1, 12), "... how to reproduce it")
  end

  do
    local json = tmp .. "/c3.json"
    local r = call(root, c3, "--agent", "--json=" .. json)
    eq(r.code, 0, "the gate stays red: exit 0")
    has(r.first, "KNOWN-RED 0 new, 1 known, 0 fixed exit 0", "... known-red")
    has(r.out, "  known gate: 1 (red at the base too)", "... known as a count")
    local doc = vim.json.decode((require("lib.nvim.fs.read")(json)))
    eq(doc.schema, "testing-ci-commit/1", "json: the schema")
    eq(doc.exit, 0, "json: the exit code")
    eq(doc.system, require("testing.ci.commit").system(), "json: the system")
    local c = doc.commits[1]
    eq({ c.sha, c.base, c.verdict, c.exit }, { c3, c2, "known-red", 0 }, "json: the commit")
    eq(c.changed_files, { "lua/proj/x.lua" }, "json: the changed files")
    eq({ c.known[1].step, c.known[1].whole }, { "gate", true }, "json: the known step")
    eq(c.head.schema, "testing-ci/1", "json: the run at the commit")
    eq(c.base_run.steps[1].name, "gate", "json: only the red steps ran at the base")
  end

  do
    local r = call(root, c4, "--agent")
    eq(r.code, 0, "docs only: exit 0")
    has(r.first, "DOCS-ONLY 1 files, not run exit 0", "... not run")
    r = call(root, c4, "--agent", "--include-docs")
    has(r.first, "KNOWN-RED", "--include-docs: it runs")
  end

  do
    local r = call(root, c5, "--agent")
    eq(r.code, 1, "the gate fixed, the suite broken: exit 1")
    has(r.first, "REGRESSION 1 new, 0 known, 0 fixed (suite 1)", "... the suite's finding is new")
    has(r.out, "TESTS/a_spec.lua", "... it names the spec file")
    r = call(root, c6, "--agent")
    eq(r.code, 0, "everything green again: exit 0")
    has(r.first, "CLEAN", "... clean")
  end

  do
    local r = call(root, "--range=" .. c1 .. ".." .. c6, "--agent")
    eq(r.code, 1, "range: the worst exit code")
    has(
      r.first,
      "ci commits 5: 2 regression, 1 known-red, 1 clean, 1 docs-only exit 1",
      "range: the tally"
    )
  end

  S.cleanup()
end
