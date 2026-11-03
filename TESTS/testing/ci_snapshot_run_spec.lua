-- TESTS/testing/ci_snapshot_run_spec.lua -- `testing ci --snapshot`: the pipeline runs on the snapshot of HEAD, the proof
-- lands in the state of the real repository and `testing ci verify` takes it for its tree. Another session's uncommitted
-- work is not part of the run and is not touched; a dirty tree, a new commit and a red run are not proven; `--step` and
-- `--reuse` are refused; the pre-push hook can run the profile that way.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok = H.ok
  local S = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
      .. "/ci_commit_support.lua"
  ).new(H, "ci-snapshot")
  local eq, has = S.eq, S.has

  local function ci(...)
    local out, err = {}, {}
    local code = S.cli.main(vim.list_extend({ "ci" }, { ... }), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = S.state_dir,
      color = false,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local root = S.project("proj", { ["gate.txt"] = "green\n", ["README.md"] = "# proj\n" })
  local base = { "--root=" .. root, "--state-dir=" .. S.state_dir }
  local function with(...)
    return vim.list_extend(vim.list_slice(base), { ... })
  end

  local r = ci("verify", unpack(base))
  eq(r.code, 1, "before any run: not proven")

  -- another session's work in the tree: not part of the run, not touched
  S.write(root .. "/untracked.txt", "mine\n")
  r = ci(unpack(with("--snapshot", "--profile=full")))
  eq(r.code, 0, "snapshot run: green (" .. r.out .. r.err .. ")")
  has(r.out, "ci --snapshot", "snapshot run: the summary line")
  has(r.out, "TESTING_CI_OK", "snapshot run: the sentinel of a whole green profile")
  eq(S.worktrees(root), 1, "snapshot run: no snapshot is left registered")
  eq(
    S.git_out(root, "status", "--porcelain"),
    "?? untracked.txt",
    "snapshot run: the tree is as it was"
  )
  os.remove(root .. "/untracked.txt")

  local state = require("testing.state").dir(root, { state_dir = S.state_dir })
  local doc = vim.json.decode(require("lib.nvim.fs.read")(state .. "/ci-full.json") or "{}")
  eq(doc.snapshot, true, "the proof document says it comes from a snapshot")
  eq(doc.tree, S.git_out(root, "rev-parse", "HEAD^{tree}"), "... and names the tree of HEAD")
  ok(vim.uv.fs_stat(state .. "/ci.json") ~= nil, "ci.json is written too")

  r = ci("verify", unpack(with("--profile=full")))
  eq(r.code, 0, "verify takes the snapshot proof: " .. r.out .. r.err)
  has(r.out, "ci verify: verified", "verify: verified")
  has(r.out, "suite stamp snapshot", "verify: ... saying where the suite's answer comes from")

  -- the working tree is dirty: not proven (the snapshot is HEAD, the tree is something else)
  S.write(root .. "/README.md", "# proj\n\nedited\n")
  r = ci("verify", unpack(with("--profile=full")))
  eq(r.code, 1, "dirty tree: not proven")
  has(r.out, "dirty", "dirty tree: said so")
  S.git_out(root, "checkout", "--", "README.md")

  -- a new commit: another tree, the proof is for the old one
  S.commit(root, { ["lua/proj/x.lua"] = "return 1\n" }, "a change")
  r = ci("verify", unpack(with("--profile=full")))
  eq(r.code, 1, "a new commit: the old proof does not hold")

  -- a red run is not a proof
  S.commit(root, { ["gate.txt"] = "red\n" }, "turn the gate red")
  r = ci(unpack(with("--snapshot", "--profile=full")))
  eq(r.code, 1, "a red snapshot run: exit 1")
  has(r.out, "ci --snapshot", "a red snapshot run: the summary line")
  ok(not r.out:find("TESTING_CI_OK", 1, true), "a red snapshot run: no sentinel")
  r = ci("verify", unpack(with("--profile=full")))
  eq(r.code, 1, "a red snapshot run: not proven")

  -- refused forms
  r = ci(unpack(with("--snapshot", "--step=gate")))
  eq(r.code, 2, "--step with --snapshot: usage")
  has(r.err, "partial run", "--step with --snapshot: said why")
  r = ci(unpack(with("--snapshot", "--reuse")))
  eq(r.code, 2, "--reuse with --snapshot: usage")

  -- the pre-push hook runs the profile that way when asked
  local hook = require("testing.ci.hook")
  has(
    hook.text({ run = "fast", driver_dir = "/opt/testing.nvim", snapshot = true }),
    "--profile=fast --snapshot ||",
    "hook --snapshot: runs the snapshot"
  )
  has(
    hook.text({ run = "fast", driver_dir = "/opt/testing.nvim" }),
    "--profile=fast --reuse ||",
    "hook: the working tree by default"
  )
  eq(hook.parse({ "install", "--snapshot" }).snapshot, true, "hook --snapshot: parsed")
  eq(hook.parse({ "install" }).snapshot, false, "hook: off by default")

  S.cleanup()
end
