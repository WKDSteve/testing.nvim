---@module 'testing.ci.land'
---@brief `testing ci land`: the hosted CI checks a commit on a branch of its own; main moves to it only when it is green.
---@description
--- ```
--- testing ci land [<rev>] [--root=<dir>] [--branch=main] [--remote=origin] [--timeout=<minutes>] [--keep]
--- ```
---
--- For a public repository whose generated workflow has `ci.workflow.land = true` (docs/WORKFLOW-CI.md). The machine
--- does not run the long suite: the commit goes to a check branch `ci/<repo>-<sha>`, the hosted runners check it on
--- every system (`testing ci remote` for exactly that commit), and only a green run moves `<branch>` to it, as a plain
--- fast-forward push. `<branch>` is therefore never red. On main the workflow's `already-verified` job sees the green run
--- and skips the legs: `publish-ci-verified` runs alone.
---
--- 1. `<remote>/<branch>` (fetched) must be an ancestor of the commit: one that moved meanwhile (another session landed)
---    is not merged here, the commit is rebased and landed again (a new run: the rebased state is unchecked).
--- 1a. The local `ci commit` verdicts of `<remote>/<branch>..<sha>` (the newest of each commit, kept below every project
---    of the state directory, WSL2 checks included) must not leave the tip red (`M.still_red`: oldest first, a
---    `regression` or `unclassified` commit makes it red, a later `clean` one green again): the quick run of each commit
---    (`CI-01`) holds the land even when a pipe hid its exit code. `--ignore-local` lands anyway; a commit that was never
---    checked locally does not hold it (the hosted CI still checks it).
--- 2. The workflow file of the commit must run on `ci/**` (else: set `land = true`, regenerate).
--- 3. A commit whose push runs are green and completed already (every awaited workflow) lands at once, no check branch.
---    Else push to `refs/heads/ci/<repo>-<sha12>`, then wait for the run of the CI workflow for that commit (and of every
---    workflow of `ci.workflow.land.also` / `--also`: a red one holds `<branch>` as well). Every system green:
---    fetch again, push `<sha>:<branch>` (no force: a branch that moved meanwhile refuses it). Red: `<branch>` stays, the
---    report names the systems. The check branch is deleted either way (`--keep` leaves it).
---
--- It waits (default up to 90 minutes, a look every 30 s) and is meant to run in the background: the machine stays free.
--- Exit codes: 0 landed (or already there), 1 red or `<branch>` moved, 2 usage (no land in the workflow), 3 git, GitHub
--- or the wait failed (no run appeared, the deadline passed).

local M = {}

M.EXIT_OK, M.EXIT_RED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

---Seconds between two looks at the run.
M.POLL_S = 30
---Default minutes to wait for the run.
M.TIMEOUT_MIN = 90
---A pushed check branch without any run of the commit (or only an older red one) after this many seconds: the pushed
---workflow does not run on `ci/**`, or GitHub started no new run. A queued or running run is waited for.
M.NO_RUN_S = 300

M.USAGE = table.concat({
  "usage: testing ci land [<rev>] [--root=<dir>] [--branch=main] [--remote=origin] [--timeout=<minutes>] [--keep] [--also=<name>] [--ignore-local]",
  "  <rev>             the commit to land (default HEAD); <remote>/<branch> must be its ancestor",
  "  --branch=<name>   the branch that moves to it when the hosted CI is green (default main)",
  "  --remote=<name>   default origin",
  "  --timeout=<min>   how long to wait for the run (default 90)",
  "  --keep            leave the check branch ci/<repo>-<sha> on the remote",
  "  --also=<name>     wait for this workflow too (its name; repeatable, comma-separated), besides",
  "                    ci.workflow.land = { also = { ... } } of .testing.lua",
  "  --ignore-local    land although the newest local `ci commit` verdict of a commit is regression",
  "                    or unclassified (by default that holds the land before anything is pushed)",
  "needs ci.workflow.land = true in .testing.lua and the regenerated workflow (docs/WORKFLOW-CI.md)",
  "exit: 0 landed, 1 red or the branch moved, 2 usage, 3 git/GitHub/timeout",
}, "\n")

---What the hosted run's overall state means here.
local GREEN = { success = true, skipped = true }
local RED = { failure = true, rejected = true, cancelled = true, no_runner = true }

---A record whose run is completed and green: a verdict (not a run whose jobs are green so far, not a skip by marker).
---@param rec table
---@return boolean
local function done_green(rec)
  return type(rec) == "table"
    and rec.overall == "success"
    and type(rec.run) == "table"
    and rec.run.status == "completed"
end

---` on <branch>` of a run record, or nothing.
---@param run? table
---@return string
local function on_branch(run)
  return type(run) == "table" and type(run.branch) == "string" and (" on " .. run.branch) or ""
end

---How long a git call of land may take: a push runs the pre-push hook (the fast pipeline of the commit), which may
---wait in the queue of testing.nvim behind heavy runs. A push that takes longer is not taken as failed blindly: land
---asks the remote where the ref is (`arrived`).
M.GIT_TIMEOUT_MS = 600000

---Replaced by a spec: processes, GitHub and the clock.
M.deps = {
  ---@param dir string
  ---@param args string[]
  ---@param env? table<string, string> Added to the environment (the push of main after green).
  ---@return integer code
  ---@return string stdout
  ---@return string stderr
  git = function(dir, args, env)
    local ok, res = pcall(function()
      -- a push runs the pre-push hook (the fast pipeline of the commit): minutes, not seconds
      return vim
        .system(vim.list_extend({ "git", "-C", dir }, args), { text = true, env = env })
        :wait(M.GIT_TIMEOUT_MS)
    end)
    if not ok then
      return 127, "", tostring(res)
    end
    -- killed at the limit (124), or no result at all: a process of the hook kept the pipes open after the kill
    if not res or res.code == 124 then
      return 124,
        res and res.stdout or "",
        ("git %s did not finish within %d min"):format(
          tostring(args[1]),
          math.floor(M.GIT_TIMEOUT_MS / 60000)
        )
    end
    return res.code or 1, res.stdout or "", res.stderr or ""
  end,
  ---The record of `testing ci remote` for one commit of the repository.
  ---@param dir string
  ---@param sha string
  ---@param state_dir string
  ---@param workflow? string Another workflow's name (`ci.workflow.land.also`); nil: the CI workflow.
  ---@return table rec
  remote = function(dir, sha, state_dir, workflow)
    local recs = require("testing.ci.remote").collect(
      { { dir = dir, from_root = false } },
      { state_dir = state_dir, sha = sha, workflow = workflow }
    )
    return recs[1] or { overall = "unknown", note = "no record" }
  end,
  ---The other workflows a land waits for: `ci.workflow.land.also` of the checkout's `.testing.lua`.
  ---@param dir string
  ---@return string[]|nil names
  ---@return string|nil problem
  also = function(dir)
    local loaded = require("testing.config.project").load(dir)
    if loaded.error then
      return nil, loaded.error
    end
    local ci = loaded.config.ci
    local wf = type(ci) == "table" and ci.workflow or nil
    if wf == nil then
      return {}
    end
    local cfg, problems = require("testing.ci.workflow").validate(wf)
    if not cfg then
      return nil, table.concat(problems, "; ")
    end
    return cfg.land_also
  end,
  ---@param s integer
  sleep = function(s)
    vim.wait(s * 1000)
  end,
  ---@return integer
  now = function()
    return os.time()
  end,
  ---The latest local `ci commit` verdict of a commit: its kept results below every project of the state directory (a
  ---worktree is a project of its own, and a check in WSL2 is kept on this side too), the newest file wins.
  ---@param state_dir string
  ---@param sha string
  ---@return { verdict: string, quick: boolean, path: string }|nil
  local_verdict = function(state_dir, sha)
    local best, best_t
    -- by listing, not `glob`: a folder name with `[`, `{` or `,` is a pattern to `glob`
    local paths = {}
    local root = state_dir .. "/testing"
    local ok_root, projects = pcall(vim.fs.dir, root)
    for project, kind in ok_root and projects or function() end do
      if kind == "directory" then
        local dir = root .. "/" .. project .. "/ci-commit"
        local ok_dir, files = pcall(vim.fs.dir, dir)
        for name, fkind in ok_dir and files or function() end do
          if fkind == "file" and name:sub(1, #sha + 1) == sha .. "-" and name:match("%.json$") then
            paths[#paths + 1] = dir .. "/" .. name
          end
        end
      end
    end
    for _, path in ipairs(paths) do
      local st = vim.uv.fs_stat(path)
      local t = st and (st.mtime.sec * 1e9 + (st.mtime.nsec or 0)) or 0
      if not best_t or t > best_t then
        local okd, r = pcall(
          vim.json.decode,
          require("lib.nvim.fs.read")(path) or "",
          { luanil = { object = true } }
        )
        if okd and type(r) == "table" and r.sha == sha and type(r.verdict) == "string" then
          best, best_t = { verdict = r.verdict, quick = r.quick == true, path = path }, t
        end
      end
    end
    return best
  end,
}

---Local verdicts that make the state red: what `ci commit` found new or could not compare (exit 1 there).
M.HOLDING = { regression = true, unclassified = true }

---The commits whose red local verdict is still red at the tip. Read oldest first: a `regression` or `unclassified`
---commit makes the state red, a `clean` one makes it green again (the run at that commit was green), and any other
---verdict (`known-red`, `flaky`, `nothing-affected`, `docs-only`) or none leaves it as it was.
---@param verdicts { sha: string, kept: { verdict: string, quick?: boolean, path?: string }|nil }[] Oldest first.
---@return { sha: string, kept: table }[] red The red commits since the last clean one; empty: the tip is not red.
function M.still_red(verdicts)
  local red = {}
  for _, it in ipairs(verdicts) do
    local v = it.kept and it.kept.verdict
    if v and M.HOLDING[v] then
      red[#red + 1] = it
    elseif v == "clean" then
      red = {}
    end
  end
  return red
end

---@class Testing.Ci.Land.Args
---@field rev string
---@field root string
---@field branch string
---@field remote string
---@field timeout integer Minutes.
---@field keep boolean
---@field also string[] More workflows (`--also=<name>`) besides `ci.workflow.land.also`.
---@field ignore_local boolean Land although a local `ci commit` verdict of a commit is red (`--ignore-local`).
---@field state_dir? string
---@field help boolean

local VALUED =
  { root = true, branch = true, remote = true, timeout = true, also = true, ["state-dir"] = true }

---@param argv string[] The arguments after `land`.
---@return Testing.Ci.Land.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Land.Args
  local args = {
    rev = "HEAD",
    root = ".",
    branch = "main",
    remote = "origin",
    timeout = M.TIMEOUT_MIN,
    keep = false,
    also = {},
    ignore_local = false,
    help = false,
  }
  local revs = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "keep" and value == nil then
      args.keep = true
    elseif key == "ignore-local" and value == nil then
      args.ignore_local = true
    elseif key and VALUED[key] then
      if value == nil then
        i = i + 1
        value = argv[i]
      end
      if value == nil or value == "" or value:sub(1, 1) == "-" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "timeout" then
        local n = tonumber(value)
        if not n or n ~= math.floor(n) or n < 1 or n > 600 then
          return nil, "--timeout: minutes, a whole number from 1 to 600"
        end
        args.timeout = n
      elseif key == "state-dir" then
        args.state_dir = value
      elseif key == "also" then
        for name in value:gmatch("[^,]+") do
          if not require("testing.ci.workflow").is_workflow_name(name) then
            return nil, ("--also: %s is no workflow name"):format(name)
          end
          args.also[#args.also + 1] = name
        end
      else
        args[key] = value
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      revs[#revs + 1] = a
    end
    i = i + 1
  end
  if #revs > 1 then
    return nil, "land one commit at a time"
  end
  args.rev = revs[1] or args.rev
  local snapshot = require("testing.ci.snapshot")
  for _, name in ipairs({ args.rev, args.branch, args.remote }) do
    if not snapshot.valid_rev(name) then
      return nil, ("not a revision or a branch: %s"):format(name)
    end
  end
  return args
end

---The cells of a red record, one line each.
---@param rec table
---@return string[]
local function cells(rec)
  local out = {}
  local names = vim.tbl_keys(type(rec.os) == "table" and rec.os or {})
  table.sort(names)
  for _, sys in ipairs(names) do
    local c = rec.os[sys]
    out[#out + 1] = ("  %-8s %s%s"):format(sys, tostring(c.state), c.url and ("  " .. c.url) or "")
  end
  return out
end

---Land one commit.
---@param args Testing.Ci.Land.Args
---@param say fun(s: string)
---@param state_dir string
---@return integer code
function M.run(args, say, state_dir)
  local d = M.deps
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local function git(...)
    return d.git(root, { ... })
  end
  local code, out = git("rev-parse", "--verify", "--quiet", args.rev .. "^{commit}")
  local _, err
  local sha = code == 0 and vim.trim(out) or nil
  if not sha or not sha:match("^%x+$") then
    say(("land: %s is no commit of %s"):format(args.rev, root))
    return M.EXIT_USAGE
  end
  local short = sha:sub(1, 7)
  local upstream = args.remote .. "/" .. args.branch
  ---Did a push that failed or ran out of time arrive anyway? The ref on the remote names the commit.
  ---@param ref string A branch name.
  ---@return boolean
  local function arrived(ref)
    local c, o = git("ls-remote", args.remote, "refs/heads/" .. ref)
    return c == 0 and (o or ""):match("^(%x+)") == sha
  end

  ---Is `<remote>/<branch>` (fetched now) an ancestor of the commit? "same", "ancestor", "moved" or nil, problem.
  local function where()
    local c, _, e = git("fetch", "--quiet", args.remote, args.branch)
    if c ~= 0 then
      return nil, ("git fetch %s %s failed: %s"):format(args.remote, args.branch, vim.trim(e))
    end
    local c2, base = git("rev-parse", "--verify", "--quiet", upstream .. "^{commit}")
    base = vim.trim(base)
    if c2 ~= 0 or base == "" then
      return nil, ("%s does not exist"):format(upstream)
    end
    if base == sha then
      return "same"
    end
    return git("merge-base", "--is-ancestor", base, sha) == 0 and "ancestor" or "moved", base
  end

  local pos, base = where()
  if not pos then
    say("land: " .. tostring(base))
    return M.EXIT_INFRA
  elseif pos == "same" then
    say(("land: %s is %s already"):format(short, upstream))
    return M.EXIT_OK
  elseif pos == "moved" then
    say(
      ("land: %s (%s) is not an ancestor of %s: it moved meanwhile. Rebase onto %s and land again"):format(
        upstream,
        tostring(base):sub(1, 7),
        short,
        upstream
      )
    )
    return M.EXIT_RED
  end

  -- the local verdicts of what goes out: a `ci commit` that found something new (a quick run per commit, `CI-01`) holds
  -- the land, whatever the shell made of its exit code (a pipe such as `| tail` hides it: 2026-11-21, a red quick run
  -- went on to land). The commits are read oldest first (`M.still_red`): a later clean commit is the fix of an earlier
  -- red one, a later known-red one is not. Only the newest verdict of each commit counts.
  if not args.ignore_local then
    -- one format, not `base .. ".." .. sha`: the cache scanner reads a bare ".." as a path out of the project
    local rc, list = git("rev-list", "--reverse", ("%s..%s"):format(tostring(base), sha))
    local shas = rc == 0 and vim.split(vim.trim(list), "%s+", { trimempty = true }) or { sha }
    local verdicts = {}
    for i, c in ipairs(shas) do
      verdicts[i] = { sha = c, kept = d.local_verdict(state_dir, c) }
    end
    local held = {}
    for _, it in ipairs(M.still_red(verdicts)) do
      held[#held + 1] = ("  %s %s%s  %s"):format(
        it.sha:sub(1, 7),
        it.kept.verdict:upper(),
        it.kept.quick and " quick" or "",
        it.kept.path or ""
      )
    end
    if #held > 0 then
      say(
        ("land: %d commit(s) of %s..%s are red in their local ci commit verdict; %s does not move"):format(
          #held,
          tostring(base):sub(1, 7),
          short,
          upstream
        )
      )
      for _, line in ipairs(held) do
        say(line)
      end
      say(
        "land: fix them, or check again (testing ci commit <sha> --force); --ignore-local lands anyway"
      )
      return M.EXIT_RED
    end
  end

  local wc, wtext = git("show", sha .. ":.github/workflows/ci.yml")
  if wc ~= 0 or not wtext:find('"ci/**"', 1, true) then
    say(
      ("land: the workflow of %s does not run on ci/**: set ci.workflow.land = true in .testing.lua and regenerate it (testing init --workflow=public --force)"):format(
        short
      )
    )
    return M.EXIT_USAGE
  end

  -- the other workflows main waits for (ci.workflow.land.also, --also): read before anything is pushed, and an
  -- unreadable .testing.lua stops here, it must not land without the workflows it names
  local also, why_not = d.also(root)
  if not also then
    say(("land: cannot read ci.workflow.land of %s: %s"):format(root, tostring(why_not)))
    return M.EXIT_USAGE
  end
  ---@type (string|false)[] false: the CI workflow (the default of `testing ci remote`)
  local workflows = { false }
  local seen = {}
  for _, name in ipairs(vim.list_extend(vim.deepcopy(also), args.also)) do
    if not seen[name:lower()] then
      seen[name:lower()] = true
      workflows[#workflows + 1] = name
    end
  end

  -- the repository's name, also from a linked worktree of it (`testing.metrics.repo_name`), not the folder's
  local repo = require("testing.metrics").repo_name(root):gsub("[^%w._-]", "-")
  local check = ("ci/%s-%s"):format(repo, sha:sub(1, 12))

  -- the runs of the commit before its check branch is pushed: one that is green and completed already (an earlier land
  -- that gave up, or whose push of main failed) is the verdict, nothing is checked twice; any other is told apart from
  -- the run of this push by its id, not by the clocks of the machine and of GitHub
  ---@type table[]
  local before = {}
  local all_green_before = true
  for i, wf in ipairs(workflows) do
    before[i] = d.remote(root, sha, state_dir, wf or nil)
    if not done_green(before[i]) then
      all_green_before = false
    end
  end

  local pushed = false
  local function drop_check()
    if not pushed then
      return
    end
    if args.keep then
      say(("land: the check branch %s stays (--keep)"):format(check))
      return
    end
    local c, _, e = git("push", "--quiet", args.remote, "--delete", "refs/heads/" .. check)
    if c ~= 0 then
      say(("land: the check branch %s could not be deleted: %s"):format(check, vim.trim(e)))
    end
  end

  local recs = {}
  if all_green_before then
    recs = before
    local run = before[1].run
    say(
      ("land: %s is green already on the hosted CI%s: no new run, %s moves to it"):format(
        short,
        on_branch(run),
        upstream
      )
    )
  end
  local red_wf
  if not all_green_before then
    say(("land: %s -> %s, the hosted CI checks it"):format(short, check))
    code, _, err = git("push", "--quiet", args.remote, sha .. ":refs/heads/" .. check)
    if code ~= 0 and arrived(check) then
      say(
        ("land: the push of %s reported %s, but %s is there: the hosted CI checks it"):format(
          check,
          vim.trim(err),
          short
        )
      )
    elseif code ~= 0 then
      say(("land: the push of %s failed: %s"):format(check, vim.trim(err)))
      return M.EXIT_INFRA
    end
    pushed = true
    -- the hosted CI takes minutes: rule CI-10, the next small task meanwhile
    require("testing.ci.hint").say(say)

    local pushed_at = d.now()
    local deadline = pushed_at + args.timeout * 60
    ---Is `run` (the newest run of the commit now) one from before this push, not the run of the check branch?
    ---@param run table
    ---@param b table The record of the look before the push.
    ---@return boolean
    local function earlier(run, b)
      local brun = type(b) == "table" and type(b.run) == "table" and b.run or nil
      if brun and brun.id ~= nil and run.id ~= nil then
        return run.id == brun.id
      end
      if not brun and type(b) == "table" and b.overall ~= nil and b.overall ~= "unknown" then
        -- the commit had no run before the push: every run now is this push's
        return false
      end
      -- the look before told nothing (GitHub unreachable, a record without ids): the clocks, a minute of slack
      local created = require("testing.ci.remote").epoch(run.created_at)
      return created ~= nil and created < pushed_at - 60
    end
    ---One look at the run of `wf` (false: the CI workflow) for the commit: its state and record.
    ---@param wf string|false
    ---@param i integer
    ---@return string state
    ---@return table rec
    local function look(wf, i)
      local rec = d.remote(root, sha, state_dir, wf or nil)
      local state = rec.overall or "unknown"
      local run = type(rec.run) == "table" and rec.run or nil
      if run and earlier(run, before[i]) then
        -- a run of the same commit from before this push: green and completed it is the verdict (the same commit, the
        -- same workflow file); still going, it is waited for (no `no_run`: the commit is being checked); red, it is no
        -- answer for this push (an earlier land that was red) until the run of the check branch exists
        if done_green(rec) then
          return "success",
            vim.tbl_extend(
              "force",
              rec,
              { note = ("an earlier run of this commit%s is green"):format(on_branch(run)) }
            )
        end
        if run.status ~= "completed" and not RED[state] then
          return "running",
            vim.tbl_extend("force", rec, {
              overall = "running",
              note = ("an earlier run of this commit%s still runs"):format(on_branch(run)),
            })
        end
        return "no_run",
          {
            overall = "no_run",
            earlier = run,
            note = ("only an older run of this commit so far: %s%s"):format(state, on_branch(run)),
          }
      end
      -- every job created so far is green, but the run is not completed: a job that GitHub creates later (`needs:`)
      -- or the run's own conclusion could still be red, so this is no verdict yet
      if GREEN[state] and run and run.status and run.status ~= "completed" then
        return "running",
          vim.tbl_extend(
            "force",
            rec,
            { overall = "running", note = "jobs green, the run is not completed yet" }
          )
      end
      return state, rec
    end
    ---`ci/x` for the CI workflow (as before), `ci/x (native)` for another one.
    local function where_of(wf)
      return wf and ("%s (%s)"):format(check, wf) or check
    end
    local last = {}
    while true do
      local all_green = true
      for i, wf in ipairs(workflows) do
        local state, rec = look(wf, i)
        recs[i] = rec
        if state ~= last[i] then
          say(
            ("land: %s on %s: %s%s"):format(
              short,
              where_of(wf),
              state,
              rec.note and ("  (" .. rec.note .. ")") or ""
            )
          )
          last[i] = state
        end
        if RED[state] then
          red_wf = i
          break
        end
        if not GREEN[state] then
          all_green = false
        end
        -- `no_run` only while no run of this push exists: a queued or running one (also an earlier one of the same
        -- commit) is waited for until the deadline
        if state == "no_run" and d.now() - pushed_at >= M.NO_RUN_S then
          local old = rec.earlier
          if old then
            say(
              ("land: GitHub started no run of %s for %s on %s within %d s; the only run of the commit is an older one (%s%s): rerun it (gh run rerun %s) or land again"):format(
                wf and ("the workflow " .. wf) or "the CI workflow",
                short,
                check,
                M.NO_RUN_S,
                tostring(old.conclusion or old.status),
                old.url and (", " .. old.url) or "",
                tostring(old.id)
              )
            )
          else
            say(
              ("land: no run of %s for %s after %d s: does the pushed workflow run on ci/**?"):format(
                wf and ("the workflow " .. wf) or "the CI workflow",
                short,
                M.NO_RUN_S
              )
            )
          end
          drop_check()
          return M.EXIT_INFRA
        end
      end
      if red_wf or all_green then
        break
      end
      if d.now() >= deadline then
        local states = {}
        for i, wf in ipairs(workflows) do
          states[i] = wf and (wf .. " " .. tostring(last[i])) or tostring(last[i])
        end
        say(
          ("land: no verdict within %d min (last: %s); %s does not move"):format(
            args.timeout,
            table.concat(states, ", "),
            upstream
          )
        )
        drop_check()
        return M.EXIT_INFRA
      end
      d.sleep(M.POLL_S)
    end
  end

  local rec = recs[1]
  local url = type(rec.run) == "table" and rec.run.url or nil
  if red_wf then
    local wf = workflows[red_wf]
    rec = recs[red_wf]
    local red_url = type(rec.run) == "table" and rec.run.url or nil
    say(
      ("land: %s is red %s; %s does not move"):format(
        short,
        wf and ("in the workflow " .. wf) or "on the hosted CI",
        upstream
      )
    )
    for _, line in ipairs(cells(rec)) do
      say(line)
    end
    if red_url then
      say("  run: " .. red_url)
    end
    -- the verdict once more as the last line: a red system ends the wait while others still run, and a reader of
    -- the tail (`windows running`, `run: ...`) took that for land giving up (m1-review, 2026-11-13)
    local red = {}
    for _, sys in ipairs(vim.tbl_keys(type(rec.os) == "table" and rec.os or {})) do
      if RED[rec.os[sys].state] then
        red[#red + 1] = ("%s %s"):format(sys, rec.os[sys].state)
      end
    end
    table.sort(red)
    say(
      ("land: red (%s%s); %s does not move, nothing landed"):format(
        wf and (wf .. ": ") or "",
        #red > 0 and table.concat(red, ", ") or tostring(rec.overall),
        upstream
      )
    )
    drop_check()
    return M.EXIT_RED
  end

  local unchecked = false
  pos, base = where()
  if not pos then
    say("land: green, but " .. tostring(base))
    drop_check()
    return M.EXIT_INFRA
  elseif pos == "moved" then
    say(
      ("land: %s is green, but %s moved meanwhile (%s): rebase and land again"):format(
        short,
        upstream,
        tostring(base):sub(1, 7)
      )
    )
    drop_check()
    return M.EXIT_RED
  elseif pos == "ancestor" then
    -- a workflow without a run that is `skipped`: GitHub skipped the push by the marker in the commit text, so nothing
    -- was checked. That may land only when the commit changes documentation and nothing else (`commit.is_doc`, as
    -- `ci commit` reads DOCS-ONLY); a code change with the marker (often a quoted one) stops here
    for _, r in ipairs(recs) do
      if r.overall == "skipped" and type(r.run) ~= "table" then
        unchecked = true
      end
    end
    if unchecked then
      local dcode, dout, derr = git("diff", "--name-only", "--no-renames", "-z", base, sha)
      local only_docs = dcode == 0
      local is_doc = require("testing.ci.commit").is_doc
      local n = 0
      for _, f in ipairs(vim.split(dout or "", "\0", { trimempty = true })) do
        n = n + 1
        only_docs = only_docs and is_doc(f)
      end
      if dcode ~= 0 then
        say(
          ("land: %s was skipped by the CI and its files cannot be read: %s"):format(
            short,
            vim.trim(derr or "")
          )
        )
        drop_check()
        return M.EXIT_INFRA
      end
      if not only_docs or n == 0 then
        local what = n == 0 and "and the commit changes no file: nothing to land"
          or "but code changed"
        say(
          ("land: %s: skipped by marker in the commit text, %s: %s stays; reword the commit and land again"):format(
            short,
            what,
            upstream
          )
        )
        drop_check()
        return M.EXIT_RED
      end
    end
    -- no force: a branch that moved between the fetch and this push refuses it. The pre-push hook refuses a direct
    -- push of main in a land repository; this is the push after green, said so (`testing.ci.hook.guard`)
    local hook = require("testing.ci.hook")
    code, _, err = d.git(
      root,
      { "push", "--quiet", args.remote, sha .. ":refs/heads/" .. args.branch },
      { [hook.LAND_PUSH_ENV] = "1" }
    )
    if code ~= 0 and arrived(args.branch) then
      say(
        ("land: the push to %s reported %s, but %s is there"):format(
          args.branch,
          vim.trim(err),
          short
        )
      )
    elseif code ~= 0 then
      say(
        ("land: %s is green, but the push to %s failed: %s"):format(
          short,
          args.branch,
          vim.trim(err)
        )
      )
      drop_check()
      return M.EXIT_RED
    end
  end
  if unchecked then
    say(
      ("land: %s landed on %s WITHOUT a hosted run (docs only, skipped by marker)"):format(
        short,
        args.branch
      )
    )
  else
    say(
      ("land: %s landed on %s (green on the hosted CI%s)"):format(
        short,
        args.branch,
        url and (": " .. url) or ""
      )
    )
  end
  drop_check()
  return M.EXIT_OK
end

---`testing ci land ...`
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci land: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p")
    or sv.state_dir
    or vim.fn.stdpath("state")
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local c, out = M.deps.git(root, { "rev-parse", "--verify", "--quiet", args.rev .. "^{commit}" })
  local started = M.deps.now()
  local code = M.run(args, sv.out, state_dir --[[@as string]])
  -- one line of `testing stats`: how long until landed (only when the entry armed the metrics)
  require("testing.metrics").record((sv --[[@as table]]).metrics, {
    kind = "land",
    repo = require("testing.metrics").repo_name(root),
    sha = c == 0 and vim.trim(out) or nil,
    duration_s = M.deps.now() - started,
    verdict = code == M.EXIT_OK and "landed"
      or code == M.EXIT_RED and "red"
      or code == M.EXIT_USAGE and "error"
      or "infra",
  })
  return code
end

return M
