-- TESTS/testing/ci_commit_spec.lua -- `testing ci commit`, the pure parts: the arguments, what counts as
-- documentation, the dependency names a commit declares, the report lines, and `testing.ci.baseline` (new, known
-- and fixed as a multiset, a red step without findings as a whole, a cut list is inexact). The runs on fixture
-- repositories are in ci_commit_run_spec.lua.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local commit = require("testing.ci.commit")
  local baseline = require("testing.ci.baseline")
  local snapshot = require("testing.ci.snapshot")

  -- the arguments
  do
    local a =
      commit.parse({ "HEAD", "abc123", "--base=main", "--keep", "--force", "--", "--jobs", "2" })
    eq(a.revs, { "HEAD", "abc123" }, "args: revisions")
    eq({ a.base, a.keep, a.force, a.include_docs }, { "main", true, true, false }, "args: options")
    eq(a.suite_args, { "--jobs", "2" }, "args: suite options after --")
    a = commit.parse({ "--range", "main~3..main", "--profile=fast", "--include-docs", "--agent" })
    eq(
      { a.range, a.profile, a.include_docs, a.agent },
      { "main~3..main", "fast", true, true },
      "args: range"
    )
    local none, why = commit.parse({})
    eq(none, nil, "args: nothing named")
    has(why, "name a commit", "args: ... says what is missing")
    none, why = commit.parse({ "HEAD", "--range=a..b" })
    eq(none, nil, "args: commits and a range")
    has(why, "not both", "args: ... is refused")
    none, why = commit.parse({ "HEAD", "--frobnicate" })
    eq(none, nil, "args: an unknown option")
    has(why, "--frobnicate", "args: ... is named")
    none, why = commit.parse({ "HEAD", "--base", "--keep" })
    eq(none, nil, "args: a valued option without its value")
    has(why, "--base needs a value", "args: ... is named")
    eq(commit.parse({ "--help" }).help, true, "args: --help needs no commit")
  end

  -- revisions the command line may name
  do
    eq(snapshot.valid_rev("HEAD~2"), true, "rev: HEAD~2")
    eq(snapshot.valid_rev("v1.0^{commit}"), true, "rev: a peeled tag")
    eq(snapshot.valid_rev("--output=x"), false, "rev: an option is no revision")
    eq(snapshot.valid_rev("a b"), false, "rev: a blank")
    eq(snapshot.valid_rev("a;rm"), false, "rev: a shell character")
    eq(snapshot.valid_rev(""), false, "rev: empty")
  end

  -- documentation
  do
    for _, f in ipairs({
      "README.md",
      "docs/CI.md",
      "doc/testing.txt",
      "LICENSE",
      "sub/CHANGELOG.md",
    }) do
      eq(commit.is_doc(f), true, "docs: " .. f)
    end
    for _, f in ipairs({
      "lua/x.lua",
      ".testing.lua",
      "scripts/test.sh",
      "TESTS/a_spec.lua",
      "md.lua",
    }) do
      eq(commit.is_doc(f), false, "not docs: " .. f)
    end
  end

  -- the dependency names of a commit: its .testing.lua and TESTS/minimal_init.lua, read as text
  do
    local tree = vim.fs.normalize(vim.fn.tempname()) .. "-ci-commit-deps"
    vim.fn.mkdir(tree .. "/TESTS", "p")
    local function write(rel, text)
      local f = assert(io.open(tree .. "/" .. rel, "wb"))
      f:write(text)
      f:close()
    end
    write(".testing.lua", "return { plugin = 'x', deps = { 'lib.nvim', \"plenary.nvim\" } }\n")
    write("TESTS/minimal_init.lua", "local DEPS = { 'testing.nvim', 'ui.nvim', '../evil' }\n")
    eq(
      commit.dep_names(tree),
      { "testing.nvim", "lib.nvim", "plenary.nvim", "ui.nvim" },
      "deps: runner, lib, .testing.lua, minimal_init (an invalid name is dropped)"
    )
    vim.fn.delete(tree, "rf")
  end

  -- the comparison
  local function step(name, state, findings, total)
    return {
      name = name,
      state = state,
      findings = findings or {},
      findings_total = total or #(findings or {}),
    }
  end
  local function f(file, line, text)
    return { file = file, line = line, col = 1, text = text }
  end

  do
    local head = {
      steps = {
        step("lint", "red", {
          f("lua/a.lua", 10, "unused variable x"),
          f("lua/a.lua", 20, "unused variable x"),
          f("lua/b.lua", 3, "line is too long"),
        }),
        step("suite", "red", { f("TESTS/a_spec.lua", 7, "a_spec.lua:7: boom") }),
        step("fmt", "green"),
      },
    }
    local base = {
      steps = {
        -- moved lines are the same finding; the second unused x is new (a multiset)
        step("lint", "red", { f("lua/a.lua", 12, "unused variable x"), f("lua/c.lua", 1, "gone") }),
        step("suite", "red", { f("TESTS/a_spec.lua", 9, "a_spec.lua:9: boom") }),
      },
    }
    local r = baseline.classify(head, base)
    eq(r.red_steps, { "lint", "suite" }, "classify: the red steps, in order")
    eq(#r.new, 2, "classify: two new")
    eq({ r.new[1].file, r.new[2].file }, { "lua/a.lua", "lua/b.lua" }, "classify: ... which")
    eq(#r.known, 2, "classify: two known (a moved line, a position in the text)")
    eq(#r.fixed, 1, "classify: one fixed")
    eq(r.fixed[1].file, "lua/c.lua", "classify: ... which")
    eq(r.exact, true, "classify: exact")
    eq(baseline.by_step(r.new), { { step = "lint", n = 2 } }, "by_step: counted per step")
  end

  do
    -- a red step without findings is compared as a whole
    local head = { steps = { step("gate", "red"), step("other", "red") } }
    local base = { steps = { step("gate", "red") } }
    local r = baseline.classify(head, base)
    eq(#r.known, 1, "whole: known when red at the base too")
    eq(r.known[1].whole, true, "whole: ... marked")
    eq(#r.new, 1, "whole: new when the base has no such red step")
    eq(r.new[1].step, "other", "whole: ... which")
    r = baseline.classify(head, nil)
    eq(#r.new, 2, "no base: everything red is new")
  end

  do
    -- a cut list: what is left over is new, and the comparison says it is not exact
    local head = { steps = { step("lint", "red", { f("a", 1, "x"), f("b", 1, "y") }, 500) } }
    local base = { steps = { step("lint", "red", { f("a", 1, "x") }, 400) } }
    local r = baseline.classify(head, base)
    eq(r.exact, false, "cut: inexact")
    eq({ #r.new, #r.known, #r.fixed }, { 1, 1, 0 }, "cut: the rest is new, nothing is called fixed")
  end

  -- the report
  do
    local r = {
      sha = "abcdef1234567890",
      verdict = "regression",
      exit = 1,
      exact = true,
      new = { { step = "lint", file = "lua/a.lua", line = 3, col = 5, text = "unused x" } },
      known = { { step = "suite", text = "red", whole = true } },
      fixed = {},
      problems = {},
      rerun = "testing ci commit abcdef123456 --force --keep",
    }
    local lines = commit.lines(r, true)
    eq(
      lines[1],
      "ci commit abcdef1 REGRESSION 1 new, 1 known, 0 fixed (lint 1) exit 1",
      "report: the verdict line"
    )
    eq(lines[2], "  new   lint lua/a.lua:3:5 unused x", "report: the new finding")
    eq(lines[3], "  known suite: 1 (red at the base too)", "report: known as a count (agent)")
    eq(lines[4], "  rerun " .. r.rerun, "report: how to reproduce")
    local term = commit.lines(r, false)
    eq(term[3], "  known suite: red", "report: known in full (terminal)")
    eq(
      commit.headline({
        sha = "abcdef1234",
        verdict = "docs-only",
        exit = 0,
        changed_files = { "README.md" },
      }),
      "ci commit abcdef1 DOCS-ONLY 1 files, not run exit 0",
      "report: docs-only"
    )
  end

  -- a base that did not run: unclassified, and not kept (the next call asks again)
  do
    local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-commit-keep"
    vim.fn.mkdir(tmp, "p")
    local saved = { create = snapshot.create, remove = snapshot.remove, run_ci = commit.run_ci }
    local saved_parent, saved_changed = snapshot.parent, snapshot.changed_files
    snapshot.parent = function()
      return ("b"):rep(40)
    end
    snapshot.changed_files = function()
      return { "lua/x.lua" }
    end
    snapshot.create = function(_, sha)
      return { root = tmp, sha = sha, dir = tmp, tree = tmp .. "/" .. sha:sub(1, 1), state = tmp }
    end
    snapshot.remove = function()
      return true
    end
    local runs = 0
    commit.run_ci = function(snap)
      runs = runs + 1
      if snap.sha:sub(1, 1) == "a" then
        return 1,
          { profile = "full", steps = { { name = "gate", state = "red", findings = {} } } },
          ""
      end
      return 3, nil, "the base hung"
    end
    local args = commit.parse({ ("a"):rep(40), "--state-dir=" .. tmp })
    args.state_dir = tmp
    local r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq(r.verdict, "unclassified", "base did not run: unclassified")
    has(r.problems[1] or "", "the base did not run (exit 3)", "base did not run: ... and why")
    r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq({ r.reused, runs }, { false, 4 }, "base did not run: not kept, asked again")
    local removed = 0
    snapshot.remove = function()
      removed = removed + 1
      return true
    end
    commit.run_ci = function()
      error("boom in the child")
    end
    local okc, why = pcall(
      commit.check,
      tmp,
      ("a"):rep(40),
      vim.tbl_extend("force", args, { force = true }),
      function() end
    )
    eq(okc, false, "an internal failure: raised")
    has(tostring(why), "boom in the child", "an internal failure: ... the message")
    eq(removed, 1, "an internal failure: the snapshot is removed")
    snapshot.create, snapshot.remove, commit.run_ci = saved.create, saved.remove, saved.run_ci
    snapshot.parent, snapshot.changed_files = saved_parent, saved_changed
    vim.fn.delete(tmp, "rf")
  end

  -- a new suite finding is run once more at the commit: green again is flaky, red again a regression;
  -- a kept result belongs to one runner
  do
    local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-commit-flaky"
    vim.fn.mkdir(tmp, "p")
    local saved = {
      create = snapshot.create,
      remove = snapshot.remove,
      parent = snapshot.parent,
      changed = snapshot.changed_files,
      run_ci = commit.run_ci,
      runner_key = commit.runner_key,
    }
    snapshot.parent = function()
      return ("b"):rep(40)
    end
    snapshot.changed_files = function()
      return { "lua/x.lua" }
    end
    snapshot.create = function(_, sha)
      return { root = tmp, sha = sha, dir = tmp, tree = tmp .. "/" .. sha:sub(1, 1), state = tmp }
    end
    snapshot.remove = function()
      return true
    end
    local red_again = false
    local confirm_args
    local function suite(state, findings)
      return { profile = "full", steps = { { name = "suite", state = state, findings = findings } } }
    end
    local BOOM = { { file = "TESTS/x_spec.lua", line = 3, text = "x_spec.lua:3: slow" } }
    commit.run_ci = function(snap, _, extra, suite_args)
      if snap.sha:sub(1, 1) == "b" then
        return 0, suite("green", {}), ""
      end
      if vim.tbl_contains(suite_args, "--file") then
        confirm_args = { extra = extra, suite = suite_args }
        if red_again == "measured" then
          -- the same spec red again, its message with another measured number
          return 1,
            suite("red", { { file = "TESTS/x_spec.lua", line = 3, text = "took 312 ms" } }),
            ""
        elseif red_again == "whole" then
          return 1, suite("red", {}), ""
        elseif red_again then
          return 1, suite("red", BOOM), ""
        end
        return 0, suite("green", {}), ""
      end
      return 1, suite("red", BOOM), ""
    end
    commit.runner_key = function()
      return "runner-1"
    end
    local args = commit.parse({ ("a"):rep(40), "--force" })
    args.state_dir = tmp
    local r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq({ r.verdict, #r.new, #r.flaky }, { "flaky", 0, 1 }, "flaky: green when run again")
    eq(confirm_args.extra, { "--profile=full", "--step=suite" }, "flaky: only the step ...")
    eq(confirm_args.suite, { "--file", "TESTS/x_spec.lua" }, "flaky: ... and the spec file")
    r.exit = 0
    has(commit.headline(r), "FLAKY 0 new, 0 known, 0 fixed, 1 flaky", "flaky: the verdict line")
    has(
      table.concat(commit.lines(r, true), "\n"),
      "  flaky suite TESTS/x_spec.lua:3",
      "flaky: listed"
    )
    red_again = true
    r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq({ r.verdict, #r.new, #r.flaky }, { "regression", 1, 0 }, "red again: a regression")
    red_again = "measured"
    r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq(r.verdict, "regression", "red again with another text: still a regression (by file)")
    red_again = "whole"
    r = commit.check(tmp, ("a"):rep(40), args, function() end)
    eq(r.verdict, "regression", "the step red again without findings: still a regression")

    local mem = commit.internal.memory_path
    local p1 = mem(tmp, ("a"):rep(40), args, ("b"):rep(40))
    commit.runner_key = function()
      return "runner-2"
    end
    ok(mem(tmp, ("a"):rep(40), args, ("b"):rep(40)) ~= p1, "kept: another runner, another key")
    eq(type(saved.runner_key()), "string", "runner_key: a string for this checkout")

    snapshot.create, snapshot.remove = saved.create, saved.remove
    snapshot.parent, snapshot.changed_files = saved.parent, saved.changed
    commit.run_ci, commit.runner_key = saved.run_ci, saved.runner_key
    vim.fn.delete(tmp, "rf")
  end
end
