-- TESTS/testing/ci_commit_ops_spec.lua -- the operation around `testing ci commit`: a kept result comes back without a
-- run until --force, a dirty working tree does not change the result (and is not touched), `scripts/test.sh` hands its
-- --state-dir in front of the subcommand, no snapshot is left behind (--keep names one), a red root commit is
-- unclassified, and an unknown revision or a non-repository is exit 2. The verdicts are in ci_commit_run_spec.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok = H.ok
  local S = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
      .. "/ci_commit_support.lua"
  ).new(H, "ci-commit-ops")
  local eq, has, call = S.eq, S.has, S.call
  local cli, tmp, state_dir, write, git_out = S.cli, S.tmp, S.state_dir, S.write, S.git_out
  local worktrees = S.worktrees

  local root, c1 = S.project("proj", { ["gate.txt"] = "green\n", ["README.md"] = "# proj\n" })
  local c2 = S.commit(root, { ["gate.txt"] = "red\n" }, "turn the gate red")

  do
    -- a kept result comes back without a run; --force runs again
    local r = call(root, c2, "--agent")
    ok(not r.out:find("kept result", 1, true), "first call: from a run")
    r = call(root, c2, "--agent")
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
    local r = call(root, c1, "--agent", "--force")
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
    -- scripts/test.sh puts --state-dir in front of the subcommand
    local code = cli.main(
      { "ci", "--state-dir", state_dir, "commit", "--root=" .. root, c1, "--agent" },
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
    local red_root = S.project("rootred", { ["gate.txt"] = "red\n" })
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

  do
    -- a root trusted through the store is trusted for the .testing.lua it was trusted with: a commit that carries
    -- another one is refused, although the working tree still has the trusted file
    local trust = require("testing.trust")
    local tctx = { env = {}, store = tmp .. "/trust.json" }
    local troot, t1 = S.project("trusted", { ["gate.txt"] = "green\n" })
    ok(trust.add(troot, tctx), "trust: the root is stored")
    local prev = trust.arm(tctx)
    local r = call(troot, t1, "--agent")
    eq(r.code, 0, "trust: a commit with the trusted .testing.lua runs: " .. r.err)
    local t2 =
      S.commit(troot, { [".testing.lua"] = S.CFG .. "-- changed\n" }, "another .testing.lua")
    git_out(troot, "checkout", "-q", t1, "--", ".testing.lua")
    git_out(troot, "reset", "-q")
    r = call(troot, t2, "--agent")
    eq(r.code, 2, "trust: a commit with another .testing.lua is refused")
    has(r.err, "is not trusted", "trust: ... said")
    has(r.err, t2:sub(1, 12), "trust: ... naming the commit")
    -- the root trust of the environment does not look at the file
    trust.arm({ env = { TESTING_TRUST_ROOTS = tmp }, store = tctx.store })
    r = call(troot, t2, "--agent")
    ok(r.code ~= 2, "trust: a root below TESTING_TRUST_ROOTS runs the commit: " .. r.err)
    trust.arm(prev)
  end

  S.cleanup()
end
