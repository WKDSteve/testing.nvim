---@module 'testing.ci.commit'
---@brief `testing ci commit`: the pipeline on the snapshot of a commit, red sorted into new, known and fixed.
---@description
--- ```
--- testing ci commit <rev>... | --range=<a>..<b> | --since=<time>  [--base=<rev>] [--profile=<name>] [--force] [--keep]
---                            [--include-docs] [--json=<file>] [--agent|--no-agent] [--root=<dir>] [-- <suite options>]
--- testing ci commit --repos-root=<dir> --since=<time> [--repos-include=<a,b>] [--repos-exclude=<a,b>]
--- ```
---
--- `--since` takes the non-merge commits of HEAD newer than a time; with `--repos-root` that is done for every repository
--- below the directory that has a `ci` section (a repository that cannot be checked is reported, the others go on).
---
--- Each commit is checked out into a detached `git worktree` of its own (`testing.ci.snapshot`) and its pipeline runs
--- there in a child process (`testing ci --keep-going`, a throwaway state directory): what another session does in the
--- working tree meanwhile does not change the result. A red run is compared with the base (`--base`, default the first
--- parent): only the red steps run on the base's snapshot, and `testing.ci.baseline` sorts every finding into new,
--- known or fixed. A commit that changes only documentation is not run (`docs-only`, `--include-docs` runs it).
---
--- Verdicts and exit codes (several commits: the worst code): `clean` 0 (green at the commit), `known-red` 0 (red, and
--- all of it red at the base too), `flaky` 0 (what was new is green on one of up to `CONFIRM_ATTEMPTS` reruns of its
--- spec files at the commit), `regression` 1 (something new is red on every one of those reruns too),
--- `unclassified` 1 (red, and there is no base
--- or the base did not run), `docs-only` / `empty` 0 (not run), `error` 2 (usage, pipeline), `infra` 3 (git, the
--- snapshot, a tool). A result is kept per commit, profile, base, suite options and runner (the trees of testing.nvim
--- and lib.nvim) in the project's state directory (`ci-commit/`) and returned again without a run (`reused`) until
--- `--force`.
---
--- The report: the agent report's first line is the verdict (`ci commit abc1234 REGRESSION 2 new, 1 known (luacheck 2)
--- exit 1`), then only the new findings, then one line per known group; the terminal report lists all three groups.
--- `--json=<file>` writes the document `testing-ci-commit/1` (`schemas/testing-ci-commit/1/`).
---
--- Limits: the dependencies are not frozen (both sides see the same ones, from `$<NAME>_DIR`, the repository's `.deps/`
--- or its siblings, handed to the child as `$<NAME>_DIR`); a load-sensitive spec may be red on one side only (new or
--- fixed); submodules are not checked out. The snapshot of a trusted repository is trusted (`TESTING_TRUST=1` for the
--- child, after `testing.trust.check` passed for the repository itself).

local baseline = require("testing.ci.baseline")
local snapshot = require("testing.ci.snapshot")

local M = {}

M.EXIT_OK, M.EXIT_FAILED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci-commit/1"

---Most commits of one call (a range beyond it is a usage error: name a shorter one).
M.MAX_COMMITS = 50

---The deadline of one child run (the pipeline of a whole repository).
M.TIMEOUT_MS = 60 * 60 * 1000

M.USAGE = table.concat({
  "usage: testing ci commit <rev>... | --range=<a>..<b> | --since=<time> [options] [-- <suite options>]",
  "       testing ci commit --repos-root=<dir> --since=<time> [options] [-- <suite options>]",
  "  <rev>...          the commits to check (a SHA, a branch, HEAD~2, ...)",
  "  --range=<a>..<b>  every commit of a..b, oldest first (at most 50)",
  "  --since=<time>    every non-merge commit of HEAD newer than this (git's date: 2.days.ago, 2026-11-01)",
  "  --repos-root=<d>  with --since: every repository below d with a ci section (repeatable); 50 commits in all",
  "  --repos-include=<a,b>, --repos-exclude=<a,b>  narrow those repositories by directory name",
  "  --base=<rev>      compare with this commit instead of the first parent",
  "  --profile=<name>  the profile to run (default: ci.default of the commit)",
  "  --force           run again even when a result for the commit is kept",
  "  --keep            leave the snapshots (git worktrees) in place and name them",
  "  --include-docs    run a commit that changes only documentation too",
  "  --quick           only the spec files the diff to the base reaches (--affected); never a proof of the tree",
  "  --agent           the agent report (default in an agent environment); --no-agent: the terminal report",
  "  --json=<file>     also write the testing-ci-commit/1 document there",
  "  --state-dir=<dir> where kept results and snapshots go (default: stdpath('state'); snapshots: temp on Windows)",
  "  --root=<dir>      the repository (default: the current directory)",
  "  -- <options>      passed on to the suite step of both runs",
  "verdicts: clean 0, known-red 0, flaky 0, docs-only 0, empty 0, regression 1, unclassified 1, error 2, infra 3",
}, "\n")

---@class Testing.Ci.Commit.Args
---@field revs string[]
---@field range? string
---@field since? string
---@field repos_roots string[]
---@field repos_include string[]
---@field repos_exclude string[]
---@field base? string
---@field profile? string
---@field force boolean
---@field keep boolean
---@field include_docs boolean
---@field quick boolean `--quick`: the suite runs what the diff to the base reaches (`--affected=<base>`).
---@field json? string
---@field state_dir? string
---@field agent? boolean
---@field root string
---@field suite_args string[]
---@field help boolean

local VALUED = {
  range = true,
  since = true,
  base = true,
  profile = true,
  json = true,
  ["state-dir"] = true,
  root = true,
  ["repos-root"] = true,
  ["repos-include"] = true,
  ["repos-exclude"] = true,
}

---@param argv string[] The arguments after `ci commit`.
---@return Testing.Ci.Commit.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Commit.Args
  local args = {
    revs = {},
    repos_roots = {},
    repos_include = {},
    repos_exclude = {},
    force = false,
    keep = false,
    include_docs = false,
    quick = false,
    root = ".",
    suite_args = {},
    help = false,
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      args.suite_args = vim.list_slice(argv, i + 1)
      break
    end
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "force" and value == nil then
      args.force = true
    elseif key == "keep" and value == nil then
      args.keep = true
    elseif key == "include-docs" and value == nil then
      args.include_docs = true
    elseif key == "quick" and value == nil then
      args.quick = true
    elseif (key == "agent" or key == "no-agent") and value == nil then
      args.agent = key == "agent"
    elseif key and VALUED[key] then
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "repos-include" or key == "repos-exclude" then
        vim.list_extend(
          args[key == "repos-include" and "repos_include" or "repos_exclude"],
          vim.split(value, ",", { plain = true, trimempty = true })
        )
      else
        args[key == "state-dir" and "state_dir" or key] = value
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.revs[#args.revs + 1] = a
    end
    i = i + 1
  end
  if not args.help then
    local named = (#args.revs > 0 and 1 or 0) + (args.range and 1 or 0) + (args.since and 1 or 0)
    if #args.repos_roots > 0 then
      if not args.since or named > 1 then
        return nil, "--repos-root takes --since=<time> and no commits or --range"
      end
      if args.base then
        return nil, "--base names one commit: it does not go with --repos-root"
      end
    elseif #args.repos_include > 0 or #args.repos_exclude > 0 then
      return nil, "--repos-include and --repos-exclude narrow --repos-root"
    elseif #args.revs > 0 and args.range then
      return nil, "name commits or a --range, not both"
    elseif named > 1 then
      return nil, "name commits, a --range or --since, only one of them"
    elseif named == 0 then
      return nil, "name a commit (testing ci commit HEAD), a --range or --since"
    end
    if args.since and (args.since:sub(1, 1) == "-" or args.since:find("%c")) then
      return nil, "--since: expected a date git understands (2.days.ago, 2026-11-01)"
    end
    if args.quick and M.selects(args.suite_args) then
      return nil,
        "--quick selects by the diff itself: no --affected, --changed, --since, --file or --only after --"
    end
  end
  return args
end

---The `.testing.lua` of a commit, byte for byte; nil when the commit has none.
---@param root string
---@param sha string
---@return string|nil
function M.testing_lua_at(root, sha)
  local ok, res = pcall(function()
    return snapshot
      .system({ "git", "cat-file", "blob", sha .. ":.testing.lua" }, { cwd = root, text = false })
      :wait(120000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return res.stdout
end

---@param argv string[]
---@param cwd string
---@return integer code
---@return string stdout
---@return string stderr
local function git(argv, cwd)
  local ok, res = pcall(function()
    return snapshot
      .system(vim.list_extend({ "git" }, argv), { cwd = cwd, text = true })
      :wait(120000)
  end)
  if not ok or not res then
    return 127, "", tostring(res)
  end
  return res.code or 1, res.stdout or "", res.stderr or ""
end

---Is a changed file documentation (a commit of nothing else is not run)?
---@param file string
---@return boolean
function M.is_doc(file)
  local f = file:gsub("\\", "/")
  local name = f:match("[^/]+$") or f
  return f:match("%.md$") ~= nil
    or f:match("^docs?/") ~= nil
    or name:match("^LICENSE") ~= nil
    or name:match("^CHANGELOG") ~= nil
end

---The dependency names the commit declares: `deps` of its `.testing.lua`, `DEPS` of its `TESTS/minimal_init.lua`
---(read as text: the commit's own files are not executed here), the runner and lib.nvim.
---@param tree string
---@return string[]
function M.dep_names(tree)
  local names, seen = {}, {}
  local function add(n)
    if not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  add("testing.nvim")
  add("lib.nvim")
  for _, name in ipairs(require("testing.deps").declared(tree)) do
    add(name)
  end
  return names
end

---The environment of a child: trusted (the repository itself passed the gate) and every dependency the commit
---declares as `$<NAME>_DIR`, resolved from the real repository (its `.deps/`, its siblings; one already set stays).
---@param root string
---@param tree string
---@return table<string, string>
function M.child_env(root, tree)
  local deps = require("testing.deps")
  local env = { TESTING_TRUST = "1" }
  local own = vim.fs.basename(root)
  for _, name in ipairs(M.dep_names(tree)) do
    local var = deps.env_name(name)
    -- `resolve` asks `$<NAME>_DIR` first: one that is set comes back unchanged
    if name ~= own then
      local found = deps.resolve(name, root)
      if found and found.dir then
        env[var] = found.dir
      end
    end
  end
  return env
end

---The driver of a child: the snapshot's own when it is testing.nvim, else this checkout's.
---@param tree string
---@return string
function M.driver(tree)
  if
    vim.fn.filereadable(tree .. "/scripts/testing.lua") == 1
    and vim.fn.filereadable(tree .. "/lua/testing/cli.lua") == 1
  then
    return tree .. "/scripts/testing.lua"
  end
  return require("testing.bindings.child").driver()
end

---Replaced by a spec: run `testing ci` on a snapshot and return its exit code and `testing-ci/1` document.
---@param snap Testing.Ci.Snapshot
---@param root string The real repository.
---@param extra string[] More arguments of `testing ci` (`--profile=`, `--step=`).
---@param suite_args string[]
---@return integer code
---@return table|nil doc
---@return string tail The last lines of stderr (for a run that did not end in a document).
function M.run_ci(snap, root, extra, suite_args)
  local json = snap.state .. "/ci-run.json"
  os.remove(json)
  local argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    M.driver(snap.tree),
    "ci",
    "--root=" .. snap.tree,
    "--keep-going",
    "--no-agent",
    "--json=" .. json,
    "--state-dir=" .. snap.state,
  }
  vim.list_extend(argv, extra)
  if #suite_args > 0 then
    argv[#argv + 1] = "--"
    vim.list_extend(argv, suite_args)
  end
  local ok, res = pcall(function()
    return snapshot
      .system(argv, {
        cwd = snap.tree,
        text = true,
        env = M.child_env(root, snap.tree),
        timeout = M.TIMEOUT_MS,
      })
      :wait()
  end)
  if not ok or not res then
    return M.EXIT_INFRA, nil, tostring(res)
  end
  local text = require("lib.nvim.fs.read")(json)
  local okd, doc = pcall(vim.json.decode, text or "", { luanil = { object = true, array = true } })
  local lines = vim.split(vim.trim(res.stderr or ""), "\n", { trimempty = true })
  local tail = table.concat(vim.list_slice(lines, math.max(1, #lines - 9)), "\n")
  local code = (res.signal or 0) ~= 0 and M.EXIT_INFRA or res.code or M.EXIT_INFRA
  return code, okd and type(doc) == "table" and doc or nil, tail, res.stdout or ""
end

---Where kept results go.
---@param root string
---@param state_dir? string
---@return string
local function memory_dir(root, state_dir)
  return require("testing.state").dir(root, { state_dir = state_dir }) .. "/ci-commit"
end

local runner_key_cache

---The state of the runner itself: the tree of testing.nvim and of lib.nvim, with a hash of their uncommitted changes.
---A kept result is about the checks of one runner; another runner checks again. Replaced by a spec.
---@return string
function M.runner_key()
  if runner_key_cache then
    return runner_key_cache
  end
  local deps = require("testing.deps")
  local dirs = { deps.self_dir() }
  local lib = deps.resolve("lib.nvim", dirs[1])
  if lib and lib.dir then
    dirs[2] = lib.dir
  end
  local parts = {}
  for _, d in ipairs(dirs) do
    local code, tree = git({ "rev-parse", "HEAD^{tree}" }, d)
    local dcode, diff = git({ "diff", "HEAD" }, d)
    parts[#parts + 1] = (code == 0 and vim.trim(tree) or "nogit")
      .. (
        (dcode == 0 and diff ~= "")
          and ("~" .. require("testing.cache.hash").sha256(diff):sub(1, 12))
        or ""
      )
  end
  runner_key_cache = table.concat(parts, "+")
  return runner_key_cache
end

---The file of a kept result: per commit, profile, base, suite options and runner (`M.runner_key`).
---@param root string
---@param sha string
---@param args Testing.Ci.Commit.Args
---@param base string|nil
---@return string
local function memory_path(root, sha, args, base)
  local key = require("testing.cache.hash").sha256(table.concat({
    base or "-",
    args.profile or "-",
    args.include_docs and "docs" or "-",
    table.concat(args.suite_args, "\0"),
    args.quick and "quick" or "-",
    M.runner_key(),
  }, "\n"))
  return ("%s/%s-%s.json"):format(memory_dir(root, args.state_dir), sha, key:sub(1, 12))
end

---Verdicts that are kept (an error or an infrastructure failure is asked again next time).
local KEPT = {
  clean = true,
  flaky = true,
  ["known-red"] = true,
  regression = true,
  unclassified = true,
  ["docs-only"] = true,
  empty = true,
}

---@param verdict string
---@return integer
local function exit_of(verdict)
  if verdict == "regression" or verdict == "unclassified" then
    return M.EXIT_FAILED
  elseif verdict == "error" then
    return M.EXIT_USAGE
  elseif verdict == "infra" then
    return M.EXIT_INFRA
  end
  return M.EXIT_OK
end

---@param it Testing.Ci.Baseline.Item
---@return table
local function item_doc(it)
  return {
    step = it.step,
    file = it.file or vim.NIL,
    line = it.line or vim.NIL,
    col = it.col or vim.NIL,
    text = it.text,
    whole = it.whole or false,
  }
end

---@param list Testing.Ci.Baseline.Item[]
---@return table[]
local function items_doc(list)
  local out = {}
  for _, it in ipairs(list) do
    out[#out + 1] = item_doc(it)
  end
  return out
end

---The steps of a run as `{ name = state }` pairs, in run order.
---@param doc table|nil
---@return table[]
local function step_states(doc)
  local out = {}
  for _, s in ipairs(doc and doc.steps or {}) do
    out[#out + 1] = { name = s.name, state = s.state }
  end
  return out
end

---How many times a step's spec files are run again before a finding that stays red counts as a regression.
---
---A single rerun (the previous behaviour) catches a spec that happened to be red once under load and green
---right after; a machine busy for longer than that (several self-hosted runners, several Claude sessions)
---can keep a load-sensitive spec red across one rerun too, which is exactly how a sheet test (`gitsuite.nvim`
---`TESTS/sheets_spec.lua`, a whole test sheet as one busted case, no budget smaller than `timeouts.case_ms`)
---turned load into a false `regression`. More attempts cost time only on the rare path a commit actually has
---a new finding, and a spec that is genuinely broken stays red on every one of them regardless.
---
---A module field so a spec can read it (as this file's own `ci_commit_spec.lua` does, to assert on the exact
---rerun count rather than a magic number), not so one can be assigned at runtime: nothing in this file does,
---and a test that did would change `M.confirm`'s behaviour for every other spec sharing this process.
---@type integer
M.CONFIRM_ATTEMPTS = 3

---Run the spec files of new findings again at the commit, up to `M.CONFIRM_ATTEMPTS` times: a finding whose
---spec file is not red on any of those reruns is flaky (red under load, green once load eases), not a
---regression. A file that is red on every rerun keeps all its new findings, and so does a step that is red
---again without findings or takes no file selection (not the suite).
---@param snap Testing.Ci.Snapshot The commit's snapshot.
---@param root string
---@param profile any The profile the commit ran.
---@param new_items Testing.Ci.Baseline.Item[]
---@param suite_args string[]
---@return Testing.Ci.Baseline.Item[] still_new
---@return Testing.Ci.Baseline.Item[] flaky
function M.confirm(snap, root, profile, new_items, suite_args)
  local by_step, order = {}, {}
  for _, it in ipairs(new_items) do
    if it.file and not it.whole then
      if not by_step[it.step] then
        by_step[it.step], order[#order + 1] = {}, it.step
      end
      table.insert(by_step[it.step], it)
    end
  end
  local flaky_set = {}
  for _, step in ipairs(order) do
    local extra = type(profile) == "string" and { "--profile=" .. profile } or {}
    extra[#extra + 1] = "--step=" .. step
    -- Still-red items only: an item already proven flaky by an earlier attempt needs no further run (its
    -- file is dropped from the `--file` selection of the next attempt too, not just from `pending`), and a
    -- step whose run reports a usage problem (code outside OK/FAILED, or no doc) stops retrying altogether --
    -- that is not "red", it is the rerun itself not having worked.
    local pending = {}
    for _, it in ipairs(by_step[step]) do
      pending[it] = true
    end
    for _ = 1, M.CONFIRM_ATTEMPTS do
      if not next(pending) then
        break
      end
      local sel, seen = vim.deepcopy(suite_args), {}
      for it in pairs(pending) do
        local spec = it.spec or it.file
        if not seen[spec] then
          seen[spec] = true
          vim.list_extend(sel, { "--file", spec })
        end
      end
      local code, doc = M.run_ci(snap, root, extra, sel)
      -- 2: the step takes no file selection (not the suite) or another usage problem: nothing is confirmed
      if (code ~= M.EXIT_OK and code ~= M.EXIT_FAILED) or not doc then
        break
      end
      -- by file, not by text: a message with a measured number differs between two runs of the same red spec
      local red_files, red_whole = {}, false
      for _, s in ipairs(doc.steps or {}) do
        if s.name == step and baseline.is_red(s) then
          red_whole = red_whole or #(s.findings or {}) == 0
          for _, f in ipairs(s.findings or {}) do
            red_files[tostring(f.spec or f.file or ""):gsub("\\", "/")] = true
          end
        end
      end
      for it in pairs(pending) do
        if not red_whole and not red_files[(it.spec or it.file):gsub("\\", "/")] then
          flaky_set[it] = true
          pending[it] = nil
        end
      end
    end
  end
  local still, flaky = {}, {}
  for _, it in ipairs(new_items) do
    if flaky_set[it] then
      flaky[#flaky + 1] = it
    else
      still[#still + 1] = it
    end
  end
  return still, flaky
end

---Do the suite options select spec files already (`--affected`, `--changed`, `--since`, `--file`, `--only`)?
---@param suite_args string[]
---@return boolean
function M.selects(suite_args)
  for _, a in ipairs(suite_args) do
    local name = a:match("^%-%-([%w%-]+)")
    if
      name == "affected"
      or name == "changed"
      or name == "since"
      or name == "file"
      or name == "only"
    then
      return true
    end
  end
  return false
end

---The suite options without the `--affected` of `--quick`: at the base the diff to itself is empty, so the base takes
---the red files of the commit (`base_suite_args`), or the whole suite when those cannot be named.
---@param suite_args string[]
---@return string[]
function M.without_affected(suite_args)
  return vim.tbl_filter(function(a)
    return a ~= "--affected" and not a:match("^%-%-affected=")
  end, suite_args)
end

---The suite options of the run at the base: those of the commit's run plus a `--file` for every spec file that is red
---at the commit, so the base runs those files and not the whole suite (a finding of the commit is in one of them, and
---the base is asked about exactly the findings of the commit). The whole suite runs when that cannot be said for sure:
---the options already select (`--file`, `--changed`, `--only`), a red suite step has no finding with a file (the step
---itself is red), a red file does not exist at the base (a renamed spec file: its old name is the base's), or no
---suite finding is red at all.
---@param items Testing.Ci.Baseline.Item[] The findings of the red steps at the commit (`baseline.classify(doc).new`).
---@param suite_args string[]
---@param base_tree string The base's snapshot.
---@return string[] suite_args
---@return boolean narrowed
function M.base_suite_args(items, suite_args, base_tree)
  for _, a in ipairs(suite_args) do
    if
      a == "--file"
      or a:match("^%-%-file=")
      or a == "--changed"
      or a == "--only"
      or a:match("^%-%-only=")
    then
      return suite_args, false
    end
  end
  local files, seen = {}, {}
  for _, it in ipairs(items) do
    if it.step == "suite" then
      if it.whole or not it.file or it.file == "" then
        return suite_args, false
      end
      local rel = (it.spec or it.file):gsub("\\", "/")
      if not seen[rel] then
        seen[rel] = true
        if not vim.uv.fs_stat(base_tree .. "/" .. rel) then
          return suite_args, false
        end
        files[#files + 1] = rel
      end
    end
  end
  if #files == 0 then
    return suite_args, false
  end
  table.sort(files)
  local out = vim.deepcopy(suite_args)
  for _, f in ipairs(files) do
    vim.list_extend(out, { "--file", f })
  end
  return out, true
end

---The `unknown step <name>` problems of a run (a step the base does not have yet).
---@param doc table|nil
---@return string[]
local function unknown_steps(doc)
  local out = {}
  for _, p in ipairs(doc and doc.problems or {}) do
    local name = type(p) == "string" and p:match("^unknown step (%S+)")
    if name then
      out[#out + 1] = name
    end
  end
  return out
end

---Check one commit (the body of `M.check`).
---@param root string
---@param sha string
---@param args Testing.Ci.Commit.Args
---@param say fun(s: string)
---@param snaps Testing.Ci.Snapshot[] Filled with the snapshots made, so a failure can still remove them.
---@return table result
local function check(root, sha, args, say, snaps)
  local base, problem
  if args.base then
    base, problem = snapshot.resolve(root, args.base)
    if not base then
      return { sha = sha, verdict = "error", problems = { problem } }
    end
  else
    base = snapshot.parent(root, sha)
  end
  local r = {
    sha = sha,
    base = base or vim.NIL,
    profile = args.profile or vim.NIL,
    suite_args = args.suite_args,
    reused = false,
    exact = true,
    problems = {},
    new = {},
    known = {},
    fixed = {},
    snapshots = {},
    rerun = ("testing ci commit %s --force --keep%s"):format(
      sha:sub(1, 12),
      args.base and (" --base=" .. args.base) or ""
    ),
  }
  local changed
  changed, problem = snapshot.changed_files(root, sha, base)
  if not changed then
    r.verdict, r.problems = "infra", { problem }
    return r
  end
  r.changed_files = changed
  local docs_only = #changed > 0
  for _, f in ipairs(changed) do
    docs_only = docs_only and M.is_doc(f)
  end
  r.docs_only = docs_only
  if not args.include_docs and (#changed == 0 or docs_only) then
    r.verdict = #changed == 0 and "empty" or "docs-only"
    return r
  end

  local mem = memory_path(root, sha, args, base)
  if not args.force then
    local text = require("lib.nvim.fs.read")(mem)
    local okd, kept = pcall(vim.json.decode, text or "", { luanil = { object = true } })
    if okd and type(kept) == "table" and kept.sha == sha and KEPT[kept.verdict] then
      kept.reused = true
      kept.snapshots = {}
      return kept
    end
  end

  local function cleanup()
    for _, s in ipairs(snaps) do
      if args.keep then
        r.snapshots[#r.snapshots + 1] = s.tree
      else
        local okr, why = snapshot.remove(s)
        if not okr then
          r.problems[#r.problems + 1] = why
        end
      end
    end
  end

  say(("ci commit %s: snapshot"):format(sha:sub(1, 7)))
  local head_snap
  head_snap, problem = snapshot.create(root, sha, { state_dir = args.state_dir })
  if not head_snap then
    r.verdict, r.problems = "infra", { problem }
    return r
  end
  snaps[#snaps + 1] = head_snap
  local extra = args.profile and { "--profile=" .. args.profile } or {}
  say(("ci commit %s: testing ci at the commit"):format(sha:sub(1, 7)))
  -- `--cached` needs no folder of its own: a snapshot is a worktree of this repository, and the cache folder is that
  -- of the main checkout (`testing.cache.store.repo_key`), shared with the base and with runs in the working tree
  local suite_args = args.suite_args
  if args.quick and base then
    -- what the diff to the base reaches; a root commit has no base and runs everything
    suite_args = vim.list_extend(vim.deepcopy(suite_args), { "--affected=" .. base })
    r.quick = true
  end
  local code, head_doc, tail = M.run_ci(head_snap, root, extra, suite_args)
  r.head = head_doc or vim.NIL
  r.steps_head = step_states(head_doc)
  if head_doc and head_doc.profile and head_doc.profile ~= vim.NIL then
    r.profile = head_doc.profile
  end
  if code == M.EXIT_OK then
    r.verdict = "clean"
    -- the run at the commit is a snapshot run: a green, complete one is the proof of the commit's tree, so the
    -- pre-push hook (`--snapshot`) and `testing ci --snapshot` do not run the same tree again. A quick run selected:
    -- it proves nothing about the tree
    if head_doc and not r.quick then
      require("testing.ci.snapshot_run").keep(root, args.state_dir, head_doc)
    end
  elseif code ~= M.EXIT_FAILED or not head_doc then
    r.verdict = code == M.EXIT_USAGE and "error" or "infra"
    for _, p in ipairs(head_doc and head_doc.problems or {}) do
      r.problems[#r.problems + 1] = p
    end
    if tail ~= "" and #r.problems == 0 then
      r.problems[#r.problems + 1] = tail
    end
  elseif not base then
    r.verdict = "unclassified"
    r.problems[#r.problems + 1] = "a root commit: there is no base to compare with"
    local cls = baseline.classify(head_doc, nil)
    r.new, r.exact = items_doc(cls.new), cls.exact
  else
    local cls0 = baseline.classify(head_doc, nil)
    say(
      ("ci commit %s: red (%s), the same steps at the base %s"):format(
        sha:sub(1, 7),
        table.concat(cls0.red_steps, ", "),
        base:sub(1, 7)
      )
    )
    local base_snap
    base_snap, problem = snapshot.create(root, base, { state_dir = args.state_dir })
    local base_doc
    if not base_snap then
      r.problems[#r.problems + 1] = problem
    else
      snaps[#snaps + 1] = base_snap
      local steps = vim.deepcopy(cls0.red_steps)
      -- the base runs the profile the commit ran (its default may differ)
      local profile = type(r.profile) == "string" and { "--profile=" .. r.profile } or {}
      local base_code
      -- only the spec files that are red at the commit run at the base (a run of the whole suite takes minutes)
      local base_suite_args, narrowed =
        M.base_suite_args(cls0.new, M.without_affected(suite_args), base_snap.tree)
      if narrowed then
        say(
          ("ci commit %s: the suite at the base runs only the red spec files"):format(sha:sub(1, 7))
        )
      end
      for _ = 1, 2 do
        base_code, base_doc, tail = M.run_ci(
          base_snap,
          root,
          vim.list_extend(vim.deepcopy(profile), { "--step=" .. table.concat(steps, ",") }),
          base_suite_args
        )
        -- a step the base does not have yet is new as a whole: run the others
        local missing = base_code == M.EXIT_USAGE and unknown_steps(base_doc) or {}
        if #missing == 0 then
          break
        end
        steps = vim.tbl_filter(function(s)
          return not vim.tbl_contains(missing, s)
        end, steps)
        r.problems[#r.problems + 1] = ("not at the base: %s"):format(table.concat(missing, ", "))
        base_doc = { steps = {} }
        if #steps == 0 then
          base_code = M.EXIT_OK
          break
        end
      end
      if base_code ~= M.EXIT_OK and base_code ~= M.EXIT_FAILED then
        r.problems[#r.problems + 1] = ("the base did not run (exit %d)%s"):format(
          base_code,
          tail ~= "" and (": " .. tail) or ""
        )
        base_doc = nil
      end
    end
    r.base_run = base_doc or vim.NIL
    r.steps_base = step_states(base_doc)
    local cls = baseline.classify(head_doc, base_doc)
    local still, flaky = cls.new, {}
    if base_doc and #cls.new > 0 then
      say(("ci commit %s: the new findings once more at the commit"):format(sha:sub(1, 7)))
      still, flaky = M.confirm(head_snap, root, r.profile, cls.new, suite_args)
    end
    r.new, r.known, r.fixed, r.flaky, r.exact =
      items_doc(still), items_doc(cls.known), items_doc(cls.fixed), items_doc(flaky), cls.exact
    if not base_doc then
      r.verdict = "unclassified"
    else
      r.verdict = #still > 0 and "regression" or #flaky > 0 and "flaky" or "known-red"
    end
  end
  cleanup()
  r.exit = exit_of(r.verdict)
  -- unclassified is kept only for a root commit: a base that did not run is asked again next time
  if KEPT[r.verdict] and not (r.verdict == "unclassified" and base) then
    local canonical = require("lib.nvim.json.canonical")
    local kept = vim.deepcopy(r)
    kept.snapshots = {}
    pcall(
      require("lib.nvim.fs.write.atomic"),
      mem,
      canonical.encode(kept) .. "\n",
      { mkdirp = true }
    )
  end
  return r
end

---Check one commit.
---@param root string
---@param sha string
---@param args Testing.Ci.Commit.Args
---@param say fun(s: string) Progress (quiet in the agent report).
---@return table result One entry of `commits` in `testing-ci-commit/1`.
function M.check(root, sha, args, say)
  local snaps = {}
  local ok, r = pcall(check, root, sha, args, say, snaps)
  if not ok then
    -- an internal failure must not leave a worktree registered until the sweep
    if not args.keep then
      for _, s in ipairs(snaps) do
        pcall(snapshot.remove, s)
      end
    end
    error(r, 0)
  end
  return r
end

---The commits of `--range=a..b`, oldest first.
---@param root string
---@param range string
---@return string[]|nil shas
---@return string|nil problem
local function range_shas(root, range)
  local a, b = range:match("^(.-)%.%.(.+)$")
  if
    not a
    or a == ""
    or not snapshot.valid_rev(a)
    or not snapshot.valid_rev(b)
    or b:find("%.%.")
  then
    return nil, ("--range=%s: expected <from>..<to>"):format(range)
  end
  local code, out, err = git({ "rev-list", "--reverse", range, "--" }, root)
  if code ~= 0 then
    return nil, ("--range=%s: %s"):format(range, vim.trim(err))
  end
  return vim.split(out, "\n", { trimempty = true })
end

---@param it table An item of the document.
---@return string
local function where(it)
  if it.whole then
    return it.step .. ": " .. it.text
  end
  local function field(v)
    return v ~= vim.NIL and v or nil
  end
  local file, line, col = field(it.file), field(it.line), field(it.col)
  local pos = file and (file .. (line and (":" .. line) or "") .. (col and (":" .. col) or ""))
  return ("%s %s%s"):format(it.step, pos and (pos .. " ") or "", it.text)
end

---The first line of one commit's report.
---@param r table
---@return string
function M.headline(r)
  local short = r.sha:sub(1, 7)
  -- `CLEAN quick`: what the diff reaches was green, not the whole suite
  local v = r.verdict:upper() .. (r.quick and " quick" or "")
  local tail = ("exit %d"):format(r.exit)
  if
    r.verdict == "regression"
    or r.verdict == "known-red"
    or r.verdict == "unclassified"
    or r.verdict == "flaky"
  then
    local by = {}
    for _, g in ipairs(baseline.by_step(r.new)) do
      by[#by + 1] = ("%s %d"):format(g.step, g.n)
    end
    local flaky = #(r.flaky or {}) > 0 and (", %d flaky"):format(#r.flaky) or ""
    return ("ci commit %s %s %d new, %d known, %d fixed%s%s%s %s"):format(
      short,
      v,
      #r.new,
      #r.known,
      #r.fixed,
      flaky,
      #by > 0 and (" (" .. table.concat(by, ", ") .. ")") or "",
      r.exact and "" or " (inexact: a list was cut)",
      tail
    )
  elseif r.verdict == "docs-only" or r.verdict == "empty" then
    return ("ci commit %s %s %d files, not run %s"):format(short, v, #(r.changed_files or {}), tail)
  elseif r.verdict == "clean" then
    local n = #(r.steps_head or {})
    return ("ci commit %s %s %s %d steps%s %s"):format(
      short,
      v,
      tostring(r.profile ~= vim.NIL and r.profile or "?"),
      n,
      r.reused and " (kept result)" or "",
      tail
    )
  end
  return ("ci commit %s %s %s %s"):format(
    short,
    v,
    tostring(r.problems[1] or ""):gsub("\n", " "),
    tail
  )
end

---The report of one commit.
---@param r table
---@param agent boolean
---@return string[]
function M.lines(r, agent)
  local out = { M.headline(r) }
  if r.reused and r.verdict ~= "clean" then
    out[#out + 1] = "  (kept result; --force runs it again)"
  end
  for _, it in ipairs(r.new or {}) do
    out[#out + 1] = "  new   " .. where(it)
  end
  for _, it in ipairs(r.flaky or {}) do
    out[#out + 1] = "  flaky " .. where(it) .. " (green when run again)"
  end
  if agent then
    for _, g in ipairs(baseline.by_step(r.known or {})) do
      out[#out + 1] = ("  known %s: %d (red at the base too)"):format(g.step, g.n)
    end
    for _, g in ipairs(baseline.by_step(r.fixed or {})) do
      out[#out + 1] = ("  fixed %s: %d"):format(g.step, g.n)
    end
  else
    for _, it in ipairs(r.known or {}) do
      out[#out + 1] = "  known " .. where(it)
    end
    for _, it in ipairs(r.fixed or {}) do
      out[#out + 1] = "  fixed " .. where(it)
    end
  end
  for i, p in ipairs(r.problems or {}) do
    if not (i == 1 and (r.verdict == "error" or r.verdict == "infra")) then
      out[#out + 1] = "  note  " .. tostring(p):gsub("\n", " | ")
    end
  end
  for _, s in ipairs(r.snapshots or {}) do
    out[#out + 1] = "  kept  " .. s
  end
  if #(r.new or {}) > 0 or r.verdict == "unclassified" then
    out[#out + 1] = "  rerun " .. r.rerun
  end
  return out
end

---The system this process runs on, the only one its verdicts speak for.
---@return "windows"|"macos"|"linux"
function M.system()
  local platform = require("testing.platform")
  return platform.is_windows() and "windows" or platform.is_macos() and "macos" or "linux"
end

---Verdicts that come from a run, so a green one could be read as more than it is.
local RAN = {
  clean = true,
  ["known-red"] = true,
  flaky = true,
  regression = true,
  unclassified = true,
}

---The line that says what the verdicts above it do not cover: a commit can be clean here and red in the CI of
---another system. Nil when nothing ran.
---@param results table[]
---@return string|nil
function M.system_note(results)
  for _, r in ipairs(results) do
    if RAN[r.verdict] then
      return ("checked on %s only; the other systems: `testing ci remote` after the push"):format(
        M.system()
      )
    end
  end
  return nil
end

---Helpers a spec reaches (not an API).
M.internal = { range_shas = range_shas, memory_path = memory_path }

---The non-merge commits of HEAD newer than `since`, oldest first.
---@param root string
---@param since string
---@return string[]|nil shas
---@return string|nil problem
local function since_shas(root, since)
  local code, out, err =
    git({ "log", "--no-merges", "--reverse", "--format=%H", "--since=" .. since }, root)
  if code ~= 0 then
    return nil, ("--since=%s: %s"):format(since, vim.trim(err))
  end
  return vim.split(out, "\n", { trimempty = true })
end

---What one repository of a call is checked for: its top level, the trust, the commits and the trust of the
---`.testing.lua` each commit carries. A repository that cannot be checked gets a `problem`; the others go on.
---@param dir string A directory of the repository.
---@param args Testing.Ci.Commit.Args
---@return { dir: string, root?: string, shas: string[], problem?: string }
local function plan_repo(dir, args)
  local entry = { dir = dir, shas = {} }
  local code, top = git({ "rev-parse", "--show-toplevel" }, dir)
  if vim.fn.isdirectory(dir) ~= 1 or code ~= 0 then
    entry.problem = ("%s is not a git repository"):format(dir)
    return entry
  end
  local root = vim.fs.normalize(vim.trim(top))
  entry.root = root
  local refused = require("testing.trust").check(root)
  if refused then
    entry.problem = refused
    return entry
  end
  local shas, problem
  if args.range then
    shas, problem = range_shas(root, args.range)
  elseif args.since then
    shas, problem = since_shas(root, args.since)
  else
    shas = {}
    for _, rev in ipairs(args.revs) do
      local sha
      sha, problem = snapshot.resolve(root, rev)
      if not sha then
        shas = nil
        break
      end
      shas[#shas + 1] = sha
    end
  end
  if not shas then
    entry.problem = problem
    return entry
  end
  if #shas == 0 and not args.since then
    entry.problem = "the range names no commit"
    return entry
  end
  if #shas > M.MAX_COMMITS then
    -- the call is refused for the count; no need to ask git for the `.testing.lua` of every one of them first
    entry.shas = shas
    return entry
  end
  -- trusted through the store, the root is trusted for one `.testing.lua`: the one a commit carries is what runs
  for _, sha in ipairs(shas) do
    local refusal = require("testing.trust").check_commit_file(root, M.testing_lua_at(root, sha))
    if refusal then
      entry.problem = ("%s: %s"):format(sha:sub(1, 12), refusal)
      return entry
    end
  end
  entry.shas = shas
  return entry
end

---Check the commits of one repository.
---@param root string
---@param shas string[]
---@param args Testing.Ci.Commit.Args
---@param say fun(line: string)
---@return table[] results
local function check_shas(root, shas, args, say)
  pcall(snapshot.sweep, root, { state_dir = args.state_dir })
  local results = {}
  for _, sha in ipairs(shas) do
    local ok_c, r = pcall(M.check, root, sha, args, say)
    if not ok_c then
      r = { sha = sha, verdict = "infra", problems = { "internal error: " .. tostring(r) } }
    end
    r.exit = exit_of(r.verdict)
    r.new, r.known, r.fixed, r.flaky = r.new or {}, r.known or {}, r.fixed or {}, r.flaky or {}
    r.problems = r.problems or {}
    r.rerun = r.rerun or ("testing ci commit %s --force --keep"):format(sha:sub(1, 12))
    if r.exact == nil then
      r.exact = true
    end
    results[#results + 1] = r
  end
  return results
end

local VERDICT_ORDER = {
  "regression",
  "unclassified",
  "error",
  "infra",
  "flaky",
  "known-red",
  "clean",
  "docs-only",
  "empty",
}

---The summary line of several commits: how many per verdict, the worst exit.
---@param tally table<string, integer>
---@param n integer
---@param worst integer
---@param repos? integer
---@return string
function M.summary(tally, n, worst, repos)
  local parts = {}
  for _, v in ipairs(VERDICT_ORDER) do
    if tally[v] then
      parts[#parts + 1] = ("%d %s"):format(tally[v], v)
    end
  end
  return ("ci commits %d%s: %s exit %d"):format(
    n,
    repos and (" in %d repositories"):format(repos) or "",
    #parts > 0 and table.concat(parts, ", ") or "none",
    worst
  )
end

---A name per repository that is unique within one call: the directory name, `<parent>/<name>` when two share one,
---the whole path when even that is shared (the name keys the document's `repo` of a commit and its `repos` list).
---@param plans { root?: string, dir: string }[]
---@return string[]
function M.repo_names(plans)
  local paths, names = {}, {}
  for i, plan in ipairs(plans) do
    paths[i] = plan.root or plan.dir
    names[i] = vim.fs.basename(paths[i])
  end
  for _, deeper in ipairs({
    function(path, name)
      return vim.fs.basename(vim.fs.dirname(path)) .. "/" .. name
    end,
    function(path)
      return path
    end,
  }) do
    local count = {}
    for _, name in ipairs(names) do
      count[name] = (count[name] or 0) + 1
    end
    for i, name in ipairs(names) do
      if count[name] > 1 then
        names[i] = deeper(paths[i], vim.fs.basename(paths[i]))
      end
    end
  end
  return names
end

---`testing ci commit ...`.
---@param argv string[] The arguments after `ci commit`.
---@param sv table `out`, `err`, `env`, `state_dir`.
---@return integer exit_code
function M.main(argv, sv)
  local out, err = sv.out, sv.err
  local args, problem = M.parse(argv)
  if not args then
    err("testing ci commit: " .. tostring(problem))
    err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    out(M.USAGE)
    return M.EXIT_OK
  end
  args.state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p") or sv.state_dir
  local agent = args.agent
  if agent == nil then
    agent = require("testing.report.agent").choose(nil, sv.env) == "agent"
  end
  local function fail(code, msg)
    err("testing ci commit: " .. msg)
    if agent then
      out(
        ("ci commit %s %s exit %d"):format(code == M.EXIT_USAGE and "ERROR" or "INFRA", msg, code)
      )
    end
    return code
  end

  -- the repositories: the one of --root, or those below the roots of --repos-root
  local multi = #args.repos_roots > 0
  local dirs = {}
  if multi then
    local repos, why = require("testing.ci.repos").resolve({
      repos = {},
      roots = args.repos_roots,
      include = args.repos_include,
      exclude = args.repos_exclude,
      refresh = false,
      force = false,
      jobs = 1,
      keep_going = false,
      reuse = false,
      help = false,
    }, (args.state_dir or vim.fn.stdpath("state")) .. "/testing-ci-repos.json")
    if not repos then
      return fail(M.EXIT_USAGE, tostring(why))
    end
    dirs = repos
  else
    dirs[1] = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  end

  local plans, total = {}, 0
  for _, dir in ipairs(dirs) do
    local plan = plan_repo(dir, args)
    if plan.problem and not multi then
      return fail(M.EXIT_USAGE, plan.problem)
    end
    total = total + #plan.shas
    plans[#plans + 1] = plan
    if total > M.MAX_COMMITS then
      break
    end
  end
  if total > M.MAX_COMMITS then
    return fail(M.EXIT_USAGE, ("%d commits, at most %d per call"):format(total, M.MAX_COMMITS))
  end
  if total == 0 and not multi then
    return fail(M.EXIT_USAGE, "the range names no commit")
  end

  ---@param _ string
  local function quiet(_) end
  local say = agent and quiet or out
  local results, worst, tally = {}, M.EXIT_OK, {}
  local repo_docs = {}
  local names = M.repo_names(plans)
  for i, plan in ipairs(plans) do
    local name = names[i]
    local rs = {}
    if plan.problem then
      worst = math.max(worst, M.EXIT_USAGE)
    elseif #plan.shas > 0 then
      if multi then
        say(("== %s: %d commit(s)"):format(name, #plan.shas))
      end
      rs = check_shas(plan.root, plan.shas, args, say)
    end
    local repo_worst = plan.problem and M.EXIT_USAGE or M.EXIT_OK
    for _, r in ipairs(rs) do
      r.repo = name
      repo_worst = math.max(repo_worst, r.exit)
      worst = math.max(worst, r.exit)
      tally[r.verdict] = (tally[r.verdict] or 0) + 1
      results[#results + 1] = r
    end
    repo_docs[#repo_docs + 1] = {
      name = name,
      root = plan.root or plan.dir,
      commits = #rs,
      exit = repo_worst,
      problem = plan.problem or vim.NIL,
    }
  end

  if #results > 1 or multi then
    out(M.summary(tally, #results, worst, multi and #plans or nil))
  end
  for _, rd in ipairs(repo_docs) do
    if rd.problem ~= vim.NIL then
      out(("ci commit repository %s ERROR %s"):format(rd.name, rd.problem))
    elseif multi and rd.commits == 0 then
      out(("ci commit repository %s: no commits since %s"):format(rd.name, args.since))
    end
  end
  local last_repo
  for _, r in ipairs(results) do
    if multi and r.repo ~= last_repo then
      out(("== %s"):format(r.repo))
      last_repo = r.repo
    end
    for _, line in ipairs(M.lines(r, agent)) do
      out(line)
    end
  end
  local note = M.system_note(results)
  if note then
    out(note)
  end

  if args.json then
    local doc = {
      schema = M.SCHEMA,
      repo = multi and ("%d repositories"):format(#plans) or vim.fs.basename(plans[1].root),
      exit = worst,
      tally = tally,
      time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      system = M.system(),
      commits = results,
    }
    if multi then
      doc.repos = repo_docs
    end
    local ok_w, werr = require("lib.nvim.fs.write.atomic")(
      vim.fn.fnamemodify(args.json, ":p"),
      require("lib.nvim.json.canonical").encode(doc) .. "\n",
      { mkdirp = true }
    )
    if not ok_w then
      err(("testing ci commit: cannot write %s: %s"):format(args.json, tostring(werr)))
      worst = M.EXIT_INFRA
    end
  end
  return worst
end

return M
