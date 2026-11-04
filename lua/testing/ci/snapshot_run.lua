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
--- A green, complete run is kept per git TREE (`<state>/ci-proofs/<tree>-<profile>.json`, the last 24): a commit whose
--- tree has such a proof is not run again (the pre-push hook of a push that was refused for another reason, a second
--- push of the same commit, a commit made again with another message), whatever the working tree looks like. The proof
--- must come from this system and this Neovim and be younger than `testing.ci.verify.DEFAULT_MAX_AGE`; `--force` runs
--- anyway. The tree holds `.testing.lua` too, so the pipeline is the same; the versions of the tools are not asked again
--- (the CI of the host is the gate that runs everything).
---
--- `--with=<a,b>` lays the named paths of the working tree over the snapshot (`testing.ci.overlay`): the commit plus YOUR
--- changes, without what other sessions have lying uncommitted. Such a run is never a proof: nothing is kept, the document
--- is partial, the sentinel is not printed, and the summary line says how many files came from the working tree.
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

M.PROOFS_KEEP = 24

---The tree of a commit.
---@param root string
---@param sha string
---@return string|nil
local function tree_of(root, sha)
  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", root, "rev-parse", sha .. "^{tree}" }, { text = true })
      :wait(30000)
  end)
  local tree = ok and res.code == 0 and vim.trim(res.stdout or "") or nil
  return tree and tree:match("^%x+$") and tree or nil
end

---Where the kept run of a tree and a profile lives.
---@param root string
---@param state_dir string|nil
---@param tree string
---@param profile string
---@return string dir
---@return string path
local function proof_path(root, state_dir, tree, profile)
  local dir = require("testing.state").dir(root, { state_dir = state_dir }) .. "/ci-proofs"
  return dir, ("%s/%s-%s.json"):format(dir, tree:sub(1, 20), (profile:gsub("[^%w_%-]", "_")))
end

---Is there a green, complete run of this tree that is still good?
---@param path string
---@param tree string
---@return table|nil doc
local function kept_proof(path, tree)
  local text = require("lib.nvim.fs.read")(path)
  local okd, doc = pcall(vim.json.decode, text or "")
  if not okd or type(doc) ~= "table" then
    return nil
  end
  local ci = require("testing.ci")
  local verify = require("testing.ci.verify")
  local max_age = require("testing.stamp").parse_age(verify.DEFAULT_MAX_AGE) --[[@as integer]]
  local age = verify._age_of(doc.time)
  if
    doc.schema ~= ci.SCHEMA
    or doc.verdict ~= "green"
    or doc.partial == true
    or doc.snapshot ~= true
    or doc.tree ~= tree
    or doc.os ~= ci.internal.this_os()
    or doc.nvim ~= tostring(vim.version())
    or age == nil
    or age < -300
    or age > max_age
  then
    return nil
  end
  return doc
end

---Keep the run of a tree; the oldest records beyond `PROOFS_KEEP` go.
---@param dir string
---@param path string
---@param doc table
local function keep_proof(dir, path, doc)
  local wrote = require("lib.nvim.fs.write.atomic")(
    path,
    require("lib.nvim.json.canonical").encode(doc) .. "\n",
    { mkdirp = true }
  )
  if not wrote then
    return
  end
  local files = {}
  for name, kind in vim.fs.dir(dir) do
    local st = kind == "file" and vim.uv.fs_stat(dir .. "/" .. name) or nil
    if st and name:match("%.json$") then
      files[#files + 1] = { path = dir .. "/" .. name, time = st.mtime.sec }
    end
  end
  table.sort(files, function(a, b)
    return a.time > b.time
  end)
  for i = M.PROOFS_KEEP + 1, #files do
    pcall(os.remove, files[i].path)
  end
end

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

  -- a green run of this very tree is kept: nothing to run again
  local tree = tree_of(root, sha)
  local profile = args.profile
  if not profile then
    local pipeline = require("testing.ci.schema").load(root)
    profile = pipeline and pipeline.default or nil
  end
  local proofs, proof
  if tree and profile then
    proofs, proof = proof_path(root, state_dir, tree, profile)
    if not args.force and not args.with and kept_proof(proof, tree) then
      out(
        ("ci --snapshot %s green exit 0 (profile %s, kept: tree %s was green)"):format(
          sha:sub(1, 7),
          profile,
          tree:sub(1, 8)
        )
      )
      out(require("testing.ci").SENTINEL)
      return M.EXIT_OK
    end
  end

  pcall(snapshot.sweep, root, { state_dir = state_dir })
  local snap, why = snapshot.create(root, sha, { state_dir = state_dir })
  if not snap then
    err(("testing ci --snapshot: cannot check %s out: %s"):format(sha:sub(1, 12), tostring(why)))
    return M.EXIT_INFRA
  end
  local laid
  if args.with then
    local why_with
    laid, why_with = require("testing.ci.overlay").apply(root, snap.tree, args.with)
    if not laid then
      pcall(snapshot.remove, snap)
      err("testing ci --snapshot: --with: " .. tostring(why_with))
      return M.EXIT_USAGE
    end
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
  if laid then
    -- not the commit alone: no proof of the commit, nothing in the state
    doc.partial = true
    if args.json then
      pcall(
        require("lib.nvim.fs.write.atomic"),
        vim.fn.fnamemodify(args.json, ":p"),
        require("lib.nvim.json.canonical").encode(doc) .. "\n",
        { mkdirp = true }
      )
    end
  end
  local notes = laid and {} or require("testing.ci").write_proof(doc, root, args.json, state_dir)
  for _, n in ipairs(notes) do
    err("testing ci --snapshot: " .. n)
  end
  if code ~= M.EXIT_OK then
    -- both streams: a step prints to stdout, a problem of the run itself (a missing dependency) only to stderr
    local shown = output_tail(output or "")
    if shown then
      out(shown)
    end
    if tail ~= nil and tail ~= "" then
      err(tail)
    end
  end
  local verdict = type(doc.verdict) == "string" and doc.verdict or "?"
  out(
    ("ci --snapshot %s%s %s exit %d%s%s"):format(
      sha:sub(1, 7),
      laid and (" + %d file(s) of the working tree"):format(laid) or "",
      verdict,
      code,
      type(doc.profile) == "string" and (" (profile " .. doc.profile .. ")") or "",
      laid and ", no proof" or ""
    )
  )
  if #notes > 0 then
    return M.EXIT_INFRA
  end
  if code == M.EXIT_OK and not doc.partial then
    if proofs and proof and doc.verdict == "green" then
      keep_proof(proofs, proof, doc)
    end
    out(require("testing.ci").SENTINEL)
  end
  return code
end

return M
