---@module 'testing.ci.commit'
---@brief `testing ci commit`: the pipeline on the snapshot of a commit, red sorted into new, known and fixed.
---@description
--- ```
--- testing ci commit <rev>... | --range=<a>..<b>  [--base=<rev>] [--profile=<name>] [--force] [--keep]
---                            [--include-docs] [--json=<file>] [--agent|--no-agent] [--root=<dir>] [-- <suite options>]
--- ```
---
--- Each commit is checked out into a detached `git worktree` of its own (`testing.ci.snapshot`) and its pipeline runs
--- there in a child process (`testing ci --keep-going`, a throwaway state directory): what another session does in the
--- working tree meanwhile does not change the result. A red run is compared with the base (`--base`, default the first
--- parent): only the red steps run on the base's snapshot, and `testing.ci.baseline` sorts every finding into new,
--- known or fixed. A commit that changes only documentation is not run (`docs-only`, `--include-docs` runs it).
---
--- Verdicts and exit codes (several commits: the worst code): `clean` 0 (green at the commit), `known-red` 0 (red, and
--- all of it red at the base too), `regression` 1 (something new is red), `unclassified` 1 (red, and there is no base
--- or the base did not run), `docs-only` / `empty` 0 (not run), `error` 2 (usage, pipeline), `infra` 3 (git, the
--- snapshot, a tool). A result is kept per commit, profile, base and suite options in the project's state directory
--- (`ci-commit/`) and returned again without a run (`reused`) until `--force`.
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
  "usage: testing ci commit <rev>... | --range=<a>..<b> [options] [-- <suite options>]",
  "  <rev>...          the commits to check (a SHA, a branch, HEAD~2, ...)",
  "  --range=<a>..<b>  every commit of a..b, oldest first (at most 50)",
  "  --base=<rev>      compare with this commit instead of the first parent",
  "  --profile=<name>  the profile to run (default: ci.default of the commit)",
  "  --force           run again even when a result for the commit is kept",
  "  --keep            leave the snapshots (git worktrees) in place and name them",
  "  --include-docs    run a commit that changes only documentation too",
  "  --agent           the agent report (default in an agent environment); --no-agent: the terminal report",
  "  --json=<file>     also write the testing-ci-commit/1 document there",
  "  --state-dir=<dir> where kept results and snapshots go (default: stdpath('state'))",
  "  --root=<dir>      the repository (default: the current directory)",
  "  -- <options>      passed on to the suite step of both runs",
  "verdicts: clean 0, known-red 0, docs-only 0, empty 0, regression 1, unclassified 1, error 2, infra 3",
}, "\n")

---@class Testing.Ci.Commit.Args
---@field revs string[]
---@field range? string
---@field base? string
---@field profile? string
---@field force boolean
---@field keep boolean
---@field include_docs boolean
---@field json? string
---@field state_dir? string
---@field agent? boolean
---@field root string
---@field suite_args string[]
---@field help boolean

local VALUED =
  { range = true, base = true, profile = true, json = true, ["state-dir"] = true, root = true }

---@param argv string[] The arguments after `ci commit`.
---@return Testing.Ci.Commit.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Commit.Args
  local args = {
    revs = {},
    force = false,
    keep = false,
    include_docs = false,
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
      args[key == "state-dir" and "state_dir" or key] = value
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.revs[#args.revs + 1] = a
    end
    i = i + 1
  end
  if not args.help then
    if args.range and #args.revs > 0 then
      return nil, "name commits or a --range, not both"
    end
    if not args.range and #args.revs == 0 then
      return nil, "name a commit (testing ci commit HEAD) or a --range"
    end
  end
  return args
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
  local deps = require("testing.deps")
  local names, seen = {}, {}
  local function add(n)
    if not seen[n] and deps.is_valid_name(n) then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  add("testing.nvim")
  add("lib.nvim")
  for _, spec in ipairs({
    { ".testing.lua", "deps%s*=%s*(%b{})" },
    { "TESTS/minimal_init.lua", "DEPS%s*=%s*(%b{})" },
  }) do
    local text = require("lib.nvim.fs.read")(tree .. "/" .. spec[1])
    local list = text and text:match(spec[2])
    for q in (list or ""):gmatch("[\"']([^\"']+)[\"']") do
      add(q)
    end
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
  return code, okd and type(doc) == "table" and doc or nil, tail
end

---Where kept results go.
---@param root string
---@param state_dir? string
---@return string
local function memory_dir(root, state_dir)
  return require("testing.state").dir(root, { state_dir = state_dir }) .. "/ci-commit"
end

---The file of a kept result: per commit, profile, base and suite options.
---@param root string
---@param sha string
---@param args Testing.Ci.Commit.Args
---@param base string|nil
---@return string
local function memory_path(root, sha, args, base)
  local key = vim.fn.sha256(table.concat({
    base or "-",
    args.profile or "-",
    args.include_docs and "docs" or "-",
    table.concat(args.suite_args, "\0"),
  }, "\n"))
  return ("%s/%s-%s.json"):format(memory_dir(root, args.state_dir), sha, key:sub(1, 12))
end

---Verdicts that are kept (an error or an infrastructure failure is asked again next time).
local KEPT = {
  clean = true,
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

---Check one commit.
---@param root string
---@param sha string
---@param args Testing.Ci.Commit.Args
---@param say fun(s: string) Progress (quiet in the agent report).
---@return table result One entry of `commits` in `testing-ci-commit/1`.
function M.check(root, sha, args, say)
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

  local snaps = {}
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
  local code, head_doc, tail = M.run_ci(head_snap, root, extra, args.suite_args)
  r.head = head_doc or vim.NIL
  r.steps_head = step_states(head_doc)
  if head_doc and head_doc.profile and head_doc.profile ~= vim.NIL then
    r.profile = head_doc.profile
  end
  if code == M.EXIT_OK then
    r.verdict = "clean"
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
      for _ = 1, 2 do
        base_code, base_doc, tail = M.run_ci(
          base_snap,
          root,
          vim.list_extend(vim.deepcopy(profile), { "--step=" .. table.concat(steps, ",") }),
          args.suite_args
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
    r.new, r.known, r.fixed, r.exact =
      items_doc(cls.new), items_doc(cls.known), items_doc(cls.fixed), cls.exact
    if not base_doc then
      r.verdict = "unclassified"
    else
      r.verdict = #cls.new > 0 and "regression" or "known-red"
    end
  end
  cleanup()
  r.exit = exit_of(r.verdict)
  if KEPT[r.verdict] then
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
  local v = r.verdict:upper()
  local tail = ("exit %d"):format(r.exit)
  if r.verdict == "regression" or r.verdict == "known-red" or r.verdict == "unclassified" then
    local by = {}
    for _, g in ipairs(baseline.by_step(r.new)) do
      by[#by + 1] = ("%s %d"):format(g.step, g.n)
    end
    return ("ci commit %s %s %d new, %d known, %d fixed%s%s %s"):format(
      short,
      v,
      #r.new,
      #r.known,
      #r.fixed,
      #by > 0 and (" (" .. table.concat(by, ", ") .. ")") or "",
      r.exact and "" or " (inexact: a list was cut)",
      tail
    )
  elseif r.verdict == "docs-only" or r.verdict == "empty" then
    return ("ci commit %s %s %d files, not run %s"):format(short, v, #(r.changed_files or {}), tail)
  elseif r.verdict == "clean" then
    local n = #(r.steps_head or {})
    return ("ci commit %s CLEAN %s %d steps%s %s"):format(
      short,
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

---Helpers a spec reaches (not an API).
M.internal = { range_shas = range_shas, memory_path = memory_path }

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

  local dir = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local code, top = git({ "rev-parse", "--show-toplevel" }, dir)
  if vim.fn.isdirectory(dir) ~= 1 or code ~= 0 then
    return fail(M.EXIT_USAGE, ("%s is not a git repository"):format(args.root))
  end
  local root = vim.fs.normalize(vim.trim(top))
  local refused = require("testing.trust").check(root)
  if refused then
    return fail(M.EXIT_USAGE, refused)
  end

  local shas = {}
  if args.range then
    local list
    list, problem = range_shas(root, args.range)
    if not list then
      return fail(M.EXIT_USAGE, problem)
    end
    shas = list
  else
    for _, rev in ipairs(args.revs) do
      local sha
      sha, problem = snapshot.resolve(root, rev)
      if not sha then
        return fail(M.EXIT_USAGE, problem)
      end
      shas[#shas + 1] = sha
    end
  end
  if #shas == 0 then
    return fail(M.EXIT_USAGE, "the range names no commit")
  end
  if #shas > M.MAX_COMMITS then
    return fail(M.EXIT_USAGE, ("%d commits, at most %d per call"):format(#shas, M.MAX_COMMITS))
  end

  pcall(snapshot.sweep, root, { state_dir = args.state_dir })
  ---@param _ string
  local function quiet(_) end
  local say = agent and quiet or out
  local results, worst = {}, M.EXIT_OK
  for _, sha in ipairs(shas) do
    local ok_c, r = pcall(M.check, root, sha, args, say)
    if not ok_c then
      r = { sha = sha, verdict = "infra", problems = { "internal error: " .. tostring(r) } }
    end
    r.exit = exit_of(r.verdict)
    r.new, r.known, r.fixed = r.new or {}, r.known or {}, r.fixed or {}
    r.problems = r.problems or {}
    r.rerun = r.rerun or ("testing ci commit %s --force --keep"):format(sha:sub(1, 12))
    if r.exact == nil then
      r.exact = true
    end
    results[#results + 1] = r
    worst = math.max(worst, r.exit)
  end

  local tally = {}
  for _, r in ipairs(results) do
    tally[r.verdict] = (tally[r.verdict] or 0) + 1
  end
  if #results > 1 then
    local parts = {}
    for _, v in ipairs({
      "regression",
      "unclassified",
      "error",
      "infra",
      "known-red",
      "clean",
      "docs-only",
      "empty",
    }) do
      if tally[v] then
        parts[#parts + 1] = ("%d %s"):format(tally[v], v)
      end
    end
    out(("ci commits %d: %s exit %d"):format(#results, table.concat(parts, ", "), worst))
  end
  for _, r in ipairs(results) do
    for _, line in ipairs(M.lines(r, agent)) do
      out(line)
    end
  end

  if args.json then
    local doc = {
      schema = M.SCHEMA,
      repo = vim.fs.basename(root),
      exit = worst,
      tally = tally,
      time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      commits = results,
    }
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
