---@module 'testing.ci.release'
---@brief `testing ci release`: release a commit for the self-hosted runner and re-run its refused jobs, in one word.
---@description
--- ```
--- testing ci release [<owner/repo>] [<sha>] [--yes] [--note=<text>] [--count=<n>] [--runners=<dir>]
--- testing ci release [--repos | <repo> --commits | <repo> <sha> --show] [--json]
--- testing ci release <repo> <sha> --yes --json
--- ```
---
--- The whole way after a refused job (docs/RUNNER-GUARD.md), as a small wizard in a terminal:
---
---   1. the repository: given, else chosen from the one of the current folder and those on the list of reviewed
---      commits (Enter takes the first);
---   2. the commit: given, else chosen from the last `--count` (10) commits of the default branch, each with its
---      title, author and date, the ones already released marked (Enter takes the newest);
---   3. what changed since the last reviewed commit (`testing ci trust --show`);
---   4. one question, `release ...? [y/N]` (`--yes` skips it);
---   5. the release (`testing ci trust <repo> <sha>`) and `gh run rerun <id> --failed` for every failed or
---      cancelled run of that commit.
---
--- Without a terminal nothing is asked: the repository, the commit and `--yes` must all be given, so a script never
--- releases a commit it did not name. A bare `testing ci trust` stays refused; this is the short way.
---
--- The steps one by one, for the editor and testing-desktop (`--json` prints one `testing-ci-release/1` document and
--- never asks): `--repos` (step 1), `<repo> --commits` (step 2), `<repo> <sha> --show` (step 3) and
--- `<repo> <sha> --yes` (step 5). Free text from GitHub reaches the document without control characters.

local M = {}

M.COUNT = 10
M.MAX_COUNT = 50
M.SCHEMA = "testing-ci-release/1"

M.USAGE = table.concat({
  "usage: testing ci release [<owner/repo>] [<sha>] [--yes] [--note=<text>] [--count=<n>] [--runners=<dir>]",
  "       testing ci release [--repos | <repo> --commits | <repo> <sha> --show] [--json]",
  "  In a terminal it asks for what is missing: the repository, the commit (from the last --count, default 10),",
  "  then shows what changed since the last reviewed commit and asks before it releases the commit and re-runs",
  "  its failed runs. Without a terminal: the repository, the commit and --yes must be given.",
  "  --repos, --commits, --show: only that step; --json: one testing-ci-release/1 document, never a question.",
}, "\n")

local RERUN = { failure = true, cancelled = true, startup_failure = true, timed_out = true }
local STEPS = { ["--repos"] = "repos", ["--commits"] = "commits", ["--show"] = "show" }

---@class Testing.Release.Ctx: Testing.RunnerGuard.Ctx
---@field ask? fun(prompt: string): string|nil A seam for specs: the answer to one question (nil: no terminal).

---@param argv string[]
---@return table|nil args
---@return string|nil problem
function M.parse(argv)
  local rg = require("testing.ci.runner_guard")
  local a = { positional = {}, count = M.COUNT }
  for _, x in ipairs(argv) do
    if x == "--yes" or x == "-y" then
      a.yes = true
    elseif x == "--json" then
      a.json = true
    elseif STEPS[x] then
      if a.step and a.step ~= STEPS[x] then
        return nil, "one step at a time: --repos, --commits or --show"
      end
      a.step = STEPS[x]
    elseif x:match("^%-%-note=") then
      a.note = x:sub(8):gsub("%c", " "):sub(1, 200)
    elseif x:match("^%-%-runners=") then
      a.runners = x:sub(11)
    elseif x:match("^%-%-count=") then
      local n = tonumber(x:sub(9))
      if not n or n ~= math.floor(n) or n < 1 or n > M.MAX_COUNT then
        return nil, ("--count takes a whole number from 1 to %d"):format(M.MAX_COUNT)
      end
      a.count = n
    elseif x == "-h" or x == "--help" then
      a.help = true
    elseif x:sub(1, 1) == "-" then
      return nil, "unknown option " .. x:sub(1, 40):gsub("%c", "?")
    elseif rg.repo_key(x) then
      if a.repo then
        return nil, "two repositories"
      end
      a.repo = x
    elseif x:match("^%x+$") and #x >= 7 and #x <= 40 then
      if a.sha then
        return nil, "two commit ids"
      end
      a.sha = x:lower()
    else
      return nil, "not a repository (owner/name) or a commit id: " .. x:sub(1, 40):gsub("%c", "?")
    end
  end
  if a.step and a.yes then
    return nil, "--yes releases: it does not go with --repos, --commits or --show"
  end
  if a.step == "commits" and not a.repo then
    return nil, "--commits needs the repository"
  end
  if a.step == "show" and not (a.repo and a.sha) then
    return nil, "--show needs the repository and the commit"
  end
  if a.json and not a.step and not (a.repo and a.sha and a.yes) then
    return nil,
      "--json needs a step (--repos, --commits, --show) or the repository, the commit and --yes"
  end
  return a
end

---The default question: a line from the terminal, nil without one.
---@return (fun(prompt: string): string|nil)|nil
local function terminal_ask()
  local uv = vim.uv or vim.loop
  if uv.guess_handle(0) ~= "tty" then
    return nil
  end
  return function(prompt)
    io.stdout:write(prompt)
    io.stdout:flush()
    return io.stdin:read("l")
  end
end

---@param s string|nil
---@return boolean
local function yes(s)
  s = vim.trim(s or ""):lower()
  return s == "y" or s == "yes" or s == "j" or s == "ja"
end

---Choose from `items` (labels); Enter takes the first, a number its item, anything else goes to `other`.
---@param ask fun(prompt: string): string|nil
---@param sv table
---@param title string
---@param labels string[]
---@param other fun(text: string): any|nil Turns a typed value into a choice (nil: not one).
---@return integer|nil index
---@return any|nil typed
local function choose(ask, sv, title, labels, other)
  sv.out(title)
  for i, l in ipairs(labels) do
    sv.out(("  %2d  %s"):format(i, l))
  end
  for _ = 1, 3 do
    local answer = ask(("%s [1]: "):format(#labels > 0 and "number or value" or "value"))
    if answer == nil then
      return nil
    end
    answer = vim.trim(answer)
    if answer == "" and #labels > 0 then
      return 1
    end
    local n = tonumber(answer)
    if n and labels[n] then
      return n
    end
    local typed = other(answer)
    if typed then
      return nil, typed
    end
    sv.err("  not a choice: " .. answer:sub(1, 60):gsub("%c", "?"))
  end
  return nil
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
  local ok, doc = pcall(vim.json.decode, raw or "")
  return ok and type(doc) == "table" and doc or nil
end

-- ---------------------------------------------------------------------------------------------- the steps as data

---@class Testing.Release.Repo
---@field name string owner/name
---@field here boolean The repository of the current folder.
---@field mode string|nil The guard mode on the list (nil: not on it).
---@field reviewed integer Commits on the list.

---Step 1: the repository of the current folder first, then those on the list of reviewed commits.
---@param store table The list of reviewed commits (`runner_guard.read`).
---@param here string|nil
---@return Testing.Release.Repo[]
function M.repos(store, here)
  local rg = require("testing.ci.runner_guard")
  local list, seen = {}, {}
  local function add(name, is_here)
    local key = rg.repo_key(name) or name:lower()
    if seen[key] then
      return
    end
    seen[key] = true
    local e = store[key]
    list[#list + 1] = {
      name = rg.clean(name, 200),
      here = is_here,
      mode = e and e.mode or nil,
      reviewed = e and #e.shas or 0,
    }
  end
  if here then
    add(here, true)
  end
  local keys = vim.tbl_keys(store)
  table.sort(keys)
  for _, k in ipairs(keys) do
    add(k, false)
  end
  return list
end

---@class Testing.Release.Commit
---@field sha string
---@field title string
---@field author string
---@field date string
---@field released boolean

---Step 2: the last `count` commits of the default branch, newest first.
---@param ctx? Testing.Release.Ctx
---@param store table
---@param repo string
---@param count integer
---@return Testing.Release.Commit[]|nil
---@return string|nil problem
function M.commits(ctx, store, repo, count)
  local rg = require("testing.ci.runner_guard")
  local raw, err = rg.call_gh(ctx, { "api", ("repos/%s/commits?per_page=%d"):format(repo, count) })
  local list = decode(raw)
  if not list then
    return nil, ("cannot list the commits of %s: %s"):format(repo, rg.clean(err or "not JSON", 300))
  end
  local key = rg.repo_key(repo) or repo:lower()
  local released = {}
  for _, s in ipairs(store[key] and store[key].shas or {}) do
    released[s.sha] = true
  end
  local out = {}
  for _, c in ipairs(list) do
    if type(c) == "table" and rg.is_sha(c.sha) then
      local info = type(c.commit) == "table" and c.commit or {}
      local author = type(info.author) == "table" and info.author or {}
      out[#out + 1] = {
        sha = c.sha,
        title = rg.clean(tostring(info.message or ""):match("^[^\n]*"), 200),
        author = rg.clean(author.name or "?", 100),
        date = rg.clean(author.date, 40),
        released = released[c.sha] == true,
      }
    end
  end
  return out
end

---The full id of `ref` in `repo` at GitHub (this also checks that the commit is in THIS repository).
---@param ctx? Testing.Release.Ctx
---@param repo string
---@param ref string
---@return string|nil full
---@return string|nil problem
local function resolve(ctx, repo, ref)
  local rg = require("testing.ci.runner_guard")
  local full, err =
    rg.call_gh(ctx, { "api", ("repos/%s/commits/%s"):format(repo, ref), "--jq", ".sha" })
  full = full and full:gsub("%s+", "")
  if not rg.is_sha(full) then
    return nil, ("%s has no commit %s: %s"):format(repo, ref, rg.clean(err or "?", 300))
  end
  return full
end

---Step 3: what changed since the last reviewed commit (the data of `testing ci trust --show`).
---@param ctx? Testing.Release.Ctx
---@param store table
---@param repo string
---@param full string
---@return table
function M.show(ctx, store, repo, full)
  local rg = require("testing.ci.runner_guard")
  local e = store[rg.repo_key(repo) or repo:lower()]
  local already = false
  for _, s in ipairs(e and e.shas or {}) do
    already = already or s.sha == full
  end
  local prev = e and e.shas[#e.shas] and e.shas[#e.shas].sha or nil
  local r = already
      and {
        prev = prev,
        compared = false,
        commits = {},
        files = {},
        files_total = 0,
        truncated = false,
      }
    or rg.compare(repo, prev, full, ctx)
  return {
    sha = full,
    already = already,
    prev = r.prev,
    compared = r.compared,
    problem = r.problem,
    status = r.status,
    total_commits = r.total_commits,
    commits = r.commits,
    files = r.files,
    files_total = r.files_total,
    truncated = r.truncated,
  }
end

---Step 5b: re-run every failed or cancelled run of `full`.
---@param ctx? Testing.Release.Ctx
---@param repo string
---@param full string
---@return { id: integer, name: string, was: string, ok: boolean, problem: string|nil }[]|nil
---@return string|nil problem
function M.rerun(ctx, repo, full)
  local rg = require("testing.ci.runner_guard")
  local raw, err =
    rg.call_gh(ctx, { "api", ("repos/%s/actions/runs?head_sha=%s&per_page=50"):format(repo, full) })
  local doc = decode(raw)
  if not doc or type(doc.workflow_runs) ~= "table" then
    return nil, "released, but the runs cannot be read: " .. rg.clean(err or "not JSON", 300)
  end
  local out = {}
  for _, run in ipairs(doc.workflow_runs) do
    if
      type(run) == "table"
      and type(run.id) == "number"
      and run.status == "completed"
      and RERUN[run.conclusion]
    then
      local _, rerr = rg.call_gh(ctx, { "run", "rerun", tostring(run.id), "-R", repo, "--failed" })
      out[#out + 1] = {
        id = run.id,
        name = rg.clean(run.name or "?", 200),
        was = run.conclusion,
        ok = rerr == nil,
        problem = rerr and rg.clean(rerr, 300) or nil,
      }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------------------------- --json

---@param a table
---@param sv table
---@param ctx? Testing.Release.Ctx
---@return integer
local function json_main(a, sv, ctx)
  local rg = require("testing.ci.runner_guard")
  local doc = { schema = M.SCHEMA, step = a.step or "release", repo = a.repo, exit = 0 }
  local function done(code, problem)
    doc.exit = code
    doc.problem = problem
    sv.out(vim.json.encode(doc))
    return code
  end
  local store = rg.read(rg.store_path(rg.root(ctx, a.runners)))
  if doc.step == "repos" then
    doc.repos = M.repos(store, rg.repo_of_cwd(ctx, sv.cwd))
    return done(0)
  elseif doc.step == "commits" then
    local list, problem = M.commits(ctx, store, a.repo, a.count)
    if not list then
      return done(3, problem)
    end
    doc.commits = list
    return done(0)
  end
  local full, problem = resolve(ctx, a.repo, a.sha)
  if not full then
    return done(3, problem)
  end
  doc.sha = full
  if doc.step == "show" then
    doc.show = M.show(ctx, store, a.repo, full)
    return done(0)
  end
  -- release: the guard's own words go to a sink, the document says what happened
  local said = {}
  local quiet = {
    out = function(s)
      said[#said + 1] = s
    end,
    err = function(s)
      said[#said + 1] = s
    end,
    cwd = sv.cwd,
  }
  local e = store[rg.repo_key(a.repo) or a.repo:lower()]
  local already = false
  for _, s in ipairs(e and e.shas or {}) do
    already = already or s.sha == full
  end
  local args = { a.repo, full }
  if a.note then
    args[#args + 1] = "--note=" .. a.note
  end
  if a.runners then
    args[#args + 1] = "--runners=" .. a.runners
  end
  local code = rg.trust_main(args, quiet, ctx)
  doc.release = { already = already, recorded = code == 0, reruns = {} }
  if code ~= 0 then
    return done(code, rg.clean(said[#said] or "the release failed", 300))
  end
  local reruns, rproblem = M.rerun(ctx, a.repo, full)
  if not reruns then
    return done(3, rproblem)
  end
  doc.release.reruns = reruns
  for _, r in ipairs(reruns) do
    if not r.ok then
      return done(3, ("re-run %d failed: %s"):format(r.id, r.problem))
    end
  end
  return done(0)
end

-- ---------------------------------------------------------------------------------------------- text

---@param c Testing.Release.Commit
---@return string
local function commit_label(c)
  return ("%s  %-60s  %-16s %s%s"):format(
    c.sha:sub(1, 10),
    c.title:sub(1, 60),
    c.author:sub(1, 16),
    c.date:sub(1, 10),
    c.released and "  (released)" or ""
  )
end

---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), cwd?: string }
---@param ctx? Testing.Release.Ctx
---@return integer
function M.main(argv, sv, ctx)
  local rg = require("testing.ci.runner_guard")
  local a, problem = M.parse(argv)
  if not a then
    if vim.tbl_contains(argv, "--json") then
      sv.out(vim.json.encode({ schema = M.SCHEMA, step = "usage", exit = 2, problem = problem }))
    else
      sv.err("testing ci release: " .. problem)
      sv.err(M.USAGE)
    end
    return 2
  end
  if a.help then
    sv.out(M.USAGE)
    return 0
  end
  if a.json then
    return json_main(a, sv, ctx)
  end
  local store = rg.read(rg.store_path(rg.root(ctx, a.runners)))
  if a.step == "repos" then
    for _, r in ipairs(M.repos(store, rg.repo_of_cwd(ctx, sv.cwd))) do
      sv.out(
        ("%-40s %s%s"):format(
          r.name,
          r.mode and ("mode=%s, %d reviewed"):format(r.mode, r.reviewed) or "not on the list",
          r.here and "   (this folder)" or ""
        )
      )
    end
    return 0
  elseif a.step == "commits" then
    local list, cproblem = M.commits(ctx, store, a.repo, a.count)
    if not list then
      sv.err("testing ci release: " .. cproblem)
      return 3
    end
    for _, c in ipairs(list) do
      sv.out(commit_label(c))
    end
    return 0
  end
  -- a spec passes its answers (`ask`), or `false` for "no terminal"
  local ask
  if ctx and ctx.ask ~= nil then
    ask = ctx.ask or nil
  else
    ask = terminal_ask()
  end
  if a.step ~= "show" and not ask and not (a.repo and a.sha and a.yes) then
    sv.err(
      "testing ci release: no terminal to ask in: name the repository and the commit, and add --yes"
    )
    return 2
  end

  -- 1. the repository
  local repo = a.repo
  if not repo then
    local list = M.repos(store, rg.repo_of_cwd(ctx, sv.cwd))
    local labels = {}
    for i, r in ipairs(list) do
      labels[i] = r.here and (r.name .. "   (this folder)") or r.name
    end
    ---@cast ask fun(prompt: string): string|nil
    local i, typed = choose(ask, sv, "Repository:", labels, rg.repo_key)
    repo = typed and tostring(typed) or (i and list[i].name)
    if not repo then
      sv.err("testing ci release: no repository chosen")
      return 2
    end
  end

  -- 2. the commit
  local ref = a.sha
  if not ref then
    local list, cproblem = M.commits(ctx, store, repo, a.count)
    if not list then
      sv.err("testing ci release: " .. cproblem)
      return 3
    end
    local labels = vim.tbl_map(commit_label, list)
    ---@cast ask fun(prompt: string): string|nil
    local i, typed = choose(
      ask,
      sv,
      ("Commit of %s (newest first):"):format(repo),
      labels,
      function(s)
        return s:match("^%x+$") and #s >= 7 and #s <= 40 and s:lower() or nil
      end
    )
    ref = typed or (i and list[i].sha)
    if not ref then
      sv.err("testing ci release: no commit chosen")
      return 2
    end
  end
  local full, rproblem = resolve(ctx, repo, ref)
  if not full then
    sv.err("testing ci release: " .. rproblem)
    return 3
  end

  -- 3. what changed, 4. the question
  local runners = a.runners and { "--runners=" .. a.runners } or {}
  local shown = rg.trust_main(vim.list_extend({ repo, full, "--show" }, runners), sv, ctx)
  if shown ~= 0 or a.step == "show" then
    return shown
  end
  if not a.yes then
    ---@cast ask fun(prompt: string): string|nil
    local prompt = ("release %s %s and re-run its failed runs? [y/N]: "):format(
      repo,
      full:sub(1, 12)
    )
    if not yes(ask(prompt)) then
      sv.out("nothing released")
      return 1
    end
  end

  -- 5. release, re-run
  local args = { repo, full }
  if a.note then
    args[#args + 1] = "--note=" .. a.note
  end
  local code = rg.trust_main(vim.list_extend(args, runners), sv, ctx)
  if code ~= 0 then
    return code
  end
  local reruns, perr = M.rerun(ctx, repo, full)
  if not reruns then
    sv.err("testing ci release: " .. perr)
    return 3
  end
  local failed = false
  for _, r in ipairs(reruns) do
    if r.ok then
      sv.out(("  re-run %d (%s, was %s)"):format(r.id, r.name, r.was))
    else
      failed = true
      sv.err(("  re-run %d (%s) failed: %s"):format(r.id, r.name, r.problem))
    end
  end
  if #reruns == 0 then
    sv.out("no failed run of this commit: nothing to re-run")
  end
  return failed and 3 or 0
end

return M
