-- TESTS/testing/ci_commit_run_spec.lua -- `testing ci commit` on fixture repositories: a green commit is clean, a
-- commit that turns a step red is a regression, one that leaves it red is known-red, a docs-only commit is not run, a
-- red root commit is unclassified, a dirty working tree does not change the result (and is not touched), a kept result
-- comes back without a run until --force, a range reports every commit, `scripts/test.sh` hands its --state-dir in
-- front of the subcommand, and no snapshot is left behind.

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 2500) .. ")"
    )
  end

  local cli = require("testing.cli")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-commit"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"
  local nvim = vim.v.progpath

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function git_out(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end
  local function commit(root, files, message)
    for rel, text in pairs(files) do
      write(root .. "/" .. rel, text)
    end
    git_out(root, "add", "-A")
    git_out(root, "commit", "-q", "-m", message)
    return git_out(root, "rev-parse", "HEAD")
  end

  -- a step that is red while gate.txt says so (no findings: compared as a whole), and the suite (findings from the IR)
  local GATE = "local f = assert(io.open(_G.arg[1] .. '/gate.txt', 'rb'))\n"
    .. "local t = f:read('*a')\nf:close()\n"
    .. "if t:find('red') then io.stderr:write('gate is red\\n') os.exit(1) end\n"
  local CFG = ("return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = { profiles = { full = { 'suite', 'gate' } }, steps = { gate = { run = { %q, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', 'gate.lua', '${root}' } } } } }\n"):format(
    nvim
  )
  local PASS = "return function(H)\n  H.ok(true, 'fine')\nend\n"
  local BOOM = "return function(H)\n  H.ok(false, 'boom')\nend\n"

  local function project(name, files)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root, "p")
    git_out(root, "init", "-q")
    git_out(root, "symbolic-ref", "HEAD", "refs/heads/main")
    local all = { [".testing.lua"] = CFG, ["gate.lua"] = GATE, ["TESTS/a_spec.lua"] = PASS }
    for k, v in pairs(files) do
      all[k] = v
    end
    return root, commit(root, all, "init")
  end

  local function call(root, ...)
    local out, err = {}, {}
    local code = cli.main(
      vim.list_extend({ "ci", "commit", "--root=" .. root, "--state-dir=" .. state_dir }, { ... }),
      {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = state_dir,
        color = false,
      }
    )
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      first = out[1] or "",
    }
  end

  local root, c1 = project("proj", { ["gate.txt"] = "green\n", ["README.md"] = "# proj\n" })
  local c2 = commit(root, { ["gate.txt"] = "red\n" }, "turn the gate red")
  local c3 = commit(root, { ["lua/proj/x.lua"] = "return 1\n" }, "a change, the gate stays red")
  local c4 = commit(root, { ["README.md"] = "# proj\n\nmore\n" }, "docs only")
  local c5 = commit(
    root,
    { ["gate.txt"] = "green\n", ["TESTS/a_spec.lua"] = BOOM },
    "gate fixed, suite broken"
  )
  local c6 = commit(root, { ["TESTS/a_spec.lua"] = PASS }, "suite fixed")

  local function worktrees(dir)
    local n = 0
    for line in git_out(dir, "worktree", "list", "--porcelain"):gmatch("[^\n]+") do
      n = n + (line:match("^worktree ") and 1 or 0)
    end
    return n
  end

  do
    local r = call(root, c1, "--agent")
    eq(r.code, 0, "a green root commit: exit 0")
    has(r.first, "ci commit " .. c1:sub(1, 7) .. " CLEAN full 2 steps exit 0", "... clean")
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
    -- a kept result comes back without a run; --force runs again
    local r = call(root, c2, "--agent")
    eq(r.code, 1, "kept: the same exit code")
    has(r.out, "(kept result; --force runs it again)", "kept: ... said")
    r = call(root, c2, "--agent", "--force")
    eq(r.code, 1, "--force: the same verdict")
    ok(not r.out:find("kept result", 1, true), "--force: ... from a run")
  end

  do
    -- another session's uncommitted work does not change the result and is not touched
    write(root .. "/gate.txt", "red\n")
    write(root .. "/untracked.txt", "mine\n")
    local before = git_out(root, "status", "--porcelain")
    local r = call(root, c6, "--agent", "--force")
    eq(r.code, 0, "dirty tree: the commit is still clean")
    eq(git_out(root, "status", "--porcelain"), before, "dirty tree: git status unchanged")
    eq(require("lib.nvim.fs.read")(root .. "/gate.txt"), "red\n", "dirty tree: the edit is kept")
    -- the counter-check: the same pipeline on the working tree is red
    local out = {}
    local code = cli.main({ "ci", "--root=" .. root, "--no-agent", "--state-dir=" .. state_dir }, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function() end,
      state_dir = state_dir,
      color = false,
    })
    eq(code, 1, "dirty tree: testing ci in the working tree is red")
    git_out(root, "checkout", "--", "gate.txt")
    os.remove(root .. "/untracked.txt")
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

  do
    -- scripts/test.sh puts --state-dir in front of the subcommand
    local code = cli.main(
      { "ci", "--state-dir", state_dir, "commit", "--root=" .. root, c6, "--agent" },
      { out = function() end, err = function() end, state_dir = state_dir, color = false }
    )
    eq(code, 0, "test.sh form: --state-dir before commit")
  end

  do
    eq(worktrees(root), 1, "no snapshot is left registered")
    local left = 0
    for _ in vim.fs.dir(state_dir .. "/testing/snap") do
      left = left + 1
    end
    eq(left, 0, "no snapshot directory is left")
    local r = call(root, c1, "--agent", "--force", "--keep")
    local kept = r.out:match("  kept  (%S+)")
    ok(kept and vim.fn.isdirectory(kept) == 1, "--keep: the snapshot is named and still there")
    eq(worktrees(root), 2, "--keep: ... and registered")
    git_out(root, "worktree", "remove", "--force", kept)
  end

  do
    local red_root = project("rootred", { ["gate.txt"] = "red\n" })
    local r = call(red_root, "HEAD", "--agent")
    eq(r.code, 1, "a red root commit: exit 1")
    has(r.first, "UNCLASSIFIED 1 new", "... unclassified")
    has(r.out, "no base to compare with", "... and why")
  end

  do
    local r = call(root, "no-such-rev", "--agent")
    eq(r.code, 2, "an unknown revision: exit 2")
    has(r.err, "unknown revision no-such-rev", "... named")
    r = call(tmp, "HEAD", "--agent")
    eq(r.code, 2, "not a repository: exit 2")
  end

  vim.fn.delete(tmp, "rf")
end
