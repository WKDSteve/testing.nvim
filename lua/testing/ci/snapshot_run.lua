---@module 'testing.ci.snapshot_run'
---@brief `testing ci --snapshot`: the pipeline on the snapshot of HEAD, the proof in the state of the real repository.
---@description
--- ```
--- testing ci --snapshot [--rev=<rev>] [--profile=<name>] [--keep-going] [--json=<file>] [--state-dir=<dir>] [--root=<dir>] [-- <suite options>]
--- ```
---
--- The pipeline runs on a detached worktree of HEAD (`testing.ci.snapshot`), not on the working tree: another session's
--- uncommitted edits cannot make the run red or green, and the checkout is not touched. The run's own state is thrown
--- away with the snapshot; what stays is the document `testing-ci/1` of the run, written into the state of the REAL
--- repository (`ci.json`, and `ci-<profile>.json` when the run was complete) with `snapshot = true`.
---
--- That is what `testing ci verify` and the pre-push hook read. The keys of the suite's stamp name the root they were
--- made in, so the stamp of a snapshot cannot be checked from the real root; `verify` therefore takes a snapshot
--- document as the proof of its tree (`HEAD^{tree}`) and skips the stamp, while the tree, the tools, the pipeline, the
--- age and a clean working tree are checked as for any proof (`testing.ci.verify`).
---
--- `--rev` takes another commit than HEAD (the pre-push hook: what is pushed need not be HEAD). A run that is not green
--- prints what the child printed: the verdict line alone does not say what to fix, and the run's state is gone by then.
---
--- Whole profiles only: `--step` and `--reuse` are refused (a partial run proves nothing; a reused suite would say
--- nothing about the snapshot). The trust gate applies to the repository and to the `.testing.lua` HEAD carries
--- (`testing.trust.check_commit_file`). Refused on the workstation like every run.

local M = {}

M.EXIT_OK, M.EXIT_FAILED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

---Lines of the child's output a run that is not green prints, from the end.
M.MAX_OUTPUT_LINES = 200

---The end of what the child printed.
---@param text string
---@return string|nil
local function output_tail(text)
  local lines = vim.split(vim.trim(text), "\r?\n", { trimempty = true })
  if #lines == 0 then
    return nil
  end
  local first = math.max(1, #lines - M.MAX_OUTPUT_LINES + 1)
  local tail = table.concat(vim.list_slice(lines, first), "\n")
  return first > 1 and ("... %d lines above\n%s"):format(first - 1, tail) or tail
end

---Run it.
---@param args Testing.Ci.Args
---@param root string The repository (absolute, normalized).
---@param sv table `out`, `err`, `state_dir`.
---@return integer exit_code
function M.main(args, root, sv)
  local out, err = sv.out, sv.err
  local snapshot = require("testing.ci.snapshot")
  local commit = require("testing.ci.commit")
  if args.steps then
    err("testing ci --snapshot: --step is a partial run; a snapshot proof covers a whole profile")
    return M.EXIT_USAGE
  end
  if args.reuse then
    err("testing ci --snapshot: --reuse is for the working tree; a snapshot always runs the suite")
    return M.EXIT_USAGE
  end
  local state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p") or sv.state_dir
  local refused = require("testing.trust").check(root)
  if refused then
    err("testing ci --snapshot: " .. refused)
    return M.EXIT_USAGE
  end
  local sha, problem = snapshot.resolve(root, args.rev or "HEAD")
  if not sha then
    err("testing ci --snapshot: " .. tostring(problem))
    return M.EXIT_USAGE
  end
  refused = require("testing.trust").check_commit_file(root, commit.testing_lua_at(root, sha))
  if refused then
    err(("testing ci --snapshot: %s: %s"):format(sha:sub(1, 12), refused))
    return M.EXIT_USAGE
  end

  pcall(snapshot.sweep, root, { state_dir = state_dir })
  local snap, why = snapshot.create(root, sha, { state_dir = state_dir })
  if not snap then
    err(("testing ci --snapshot: cannot check %s out: %s"):format(sha:sub(1, 12), tostring(why)))
    return M.EXIT_INFRA
  end
  local extra = {}
  if args.profile then
    extra[#extra + 1] = "--profile=" .. args.profile
  end
  local ok, code, doc, tail, output = pcall(commit.run_ci, snap, root, extra, args.suite_args)
  pcall(snapshot.remove, snap)
  if not ok then
    err("testing ci --snapshot: " .. tostring(code))
    return M.EXIT_INFRA
  end
  if not doc then
    err("testing ci --snapshot: the run on " .. sha:sub(1, 12) .. " ended without a document")
    if tail ~= "" then
      err(tail)
    end
    return M.EXIT_INFRA
  end

  doc.snapshot = true
  local notes = require("testing.ci").write_proof(doc, root, args.json, state_dir)
  for _, n in ipairs(notes) do
    err("testing ci --snapshot: " .. n)
  end
  local shown = code ~= M.EXIT_OK and output_tail(output or "") or nil
  if shown then
    out(shown)
  end
  local verdict = type(doc.verdict) == "string" and doc.verdict or "?"
  out(
    ("ci --snapshot %s %s exit %d%s"):format(
      sha:sub(1, 7),
      verdict,
      code,
      type(doc.profile) == "string" and (" (profile " .. doc.profile .. ")") or ""
    )
  )
  if #notes > 0 then
    return M.EXIT_INFRA
  end
  if code == M.EXIT_OK and not doc.partial then
    out(require("testing.ci").SENTINEL)
  end
  return code
end

return M
