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
--- 2. The workflow file of the commit must run on `ci/**` (else: set `land = true`, regenerate).
--- 3. Push to `refs/heads/ci/<repo>-<sha12>`, then wait for the run of the CI workflow for that commit. Every system green:
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
---A pushed check branch without a run after this many seconds: the pushed workflow does not run on `ci/**`.
M.NO_RUN_S = 300

M.USAGE = table.concat({
  "usage: testing ci land [<rev>] [--root=<dir>] [--branch=main] [--remote=origin] [--timeout=<minutes>] [--keep]",
  "  <rev>             the commit to land (default HEAD); <remote>/<branch> must be its ancestor",
  "  --branch=<name>   the branch that moves to it when the hosted CI is green (default main)",
  "  --remote=<name>   default origin",
  "  --timeout=<min>   how long to wait for the run (default 90)",
  "  --keep            leave the check branch ci/<repo>-<sha> on the remote",
  "needs ci.workflow.land = true in .testing.lua and the regenerated workflow (docs/WORKFLOW-CI.md)",
  "exit: 0 landed, 1 red or the branch moved, 2 usage, 3 git/GitHub/timeout",
}, "\n")

---What the hosted run's overall state means here.
local GREEN = { success = true, skipped = true }
local RED = { failure = true, rejected = true, cancelled = true, no_runner = true }

---Replaced by a spec: processes, GitHub and the clock.
M.deps = {
  ---@param dir string
  ---@param args string[]
  ---@return integer code
  ---@return string stdout
  ---@return string stderr
  git = function(dir, args)
    local ok, res = pcall(function()
      -- a push runs the pre-push hook (the fast pipeline of the commit): minutes, not seconds
      return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait(600000)
    end)
    if not ok or not res then
      return 127, "", tostring(res)
    end
    return res.code or 1, res.stdout or "", res.stderr or ""
  end,
  ---The record of `testing ci remote` for one commit of the repository.
  ---@param dir string
  ---@param sha string
  ---@param state_dir string
  ---@return table rec
  remote = function(dir, sha, state_dir)
    local recs = require("testing.ci.remote").collect(
      { { dir = dir, from_root = false } },
      { state_dir = state_dir, sha = sha }
    )
    return recs[1] or { overall = "unknown", note = "no record" }
  end,
  ---@param s integer
  sleep = function(s)
    vim.wait(s * 1000)
  end,
  ---@return integer
  now = function()
    return os.time()
  end,
}

---@class Testing.Ci.Land.Args
---@field rev string
---@field root string
---@field branch string
---@field remote string
---@field timeout integer Minutes.
---@field keep boolean
---@field state_dir? string
---@field help boolean

local VALUED = { root = true, branch = true, remote = true, timeout = true, ["state-dir"] = true }

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

  local wc, wtext = git("show", sha .. ":.github/workflows/ci.yml")
  if wc ~= 0 or not wtext:find('"ci/**"', 1, true) then
    say(
      ("land: the workflow of %s does not run on ci/**: set ci.workflow.land = true in .testing.lua and regenerate it (testing init --workflow=public --force)"):format(
        short
      )
    )
    return M.EXIT_USAGE
  end

  local repo = vim.fs.basename(root):gsub("[^%w._-]", "-")
  local check = ("ci/%s-%s"):format(repo, sha:sub(1, 12))
  say(("land: %s -> %s, the hosted CI checks it"):format(short, check))
  code, _, err = git("push", "--quiet", args.remote, sha .. ":refs/heads/" .. check)
  if code ~= 0 then
    say(("land: the push of %s failed: %s"):format(check, vim.trim(err)))
    return M.EXIT_INFRA
  end
  local function drop_check()
    if args.keep then
      say(("land: the check branch %s stays (--keep)"):format(check))
      return
    end
    local c, _, e = git("push", "--quiet", args.remote, "--delete", "refs/heads/" .. check)
    if c ~= 0 then
      say(("land: the check branch %s could not be deleted: %s"):format(check, vim.trim(e)))
    end
  end

  local pushed_at = d.now()
  local deadline = pushed_at + args.timeout * 60
  local last
  local rec
  while true do
    rec = d.remote(root, sha, state_dir)
    local state = rec.overall or "unknown"
    if state ~= last then
      say(
        ("land: %s on %s: %s%s"):format(
          short,
          check,
          state,
          rec.note and ("  (" .. rec.note .. ")") or ""
        )
      )
      last = state
    end
    if GREEN[state] or RED[state] then
      break
    end
    if state == "no_run" and d.now() - pushed_at >= M.NO_RUN_S then
      say(
        ("land: no run of the CI workflow for %s after %d s: does the pushed workflow run on ci/**?"):format(
          short,
          M.NO_RUN_S
        )
      )
      drop_check()
      return M.EXIT_INFRA
    end
    if d.now() >= deadline then
      say(
        ("land: no verdict within %d min (last: %s); %s does not move"):format(
          args.timeout,
          state,
          upstream
        )
      )
      drop_check()
      return M.EXIT_INFRA
    end
    d.sleep(M.POLL_S)
  end

  local url = type(rec.run) == "table" and rec.run.url or nil
  if RED[rec.overall] then
    say(("land: %s is red on the hosted CI; %s does not move"):format(short, upstream))
    for _, line in ipairs(cells(rec)) do
      say(line)
    end
    if url then
      say("  run: " .. url)
    end
    drop_check()
    return M.EXIT_RED
  end

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
    -- no force: a branch that moved between the fetch and this push refuses it
    code, _, err = git("push", "--quiet", args.remote, sha .. ":refs/heads/" .. args.branch)
    if code ~= 0 then
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
  say(
    ("land: %s landed on %s (green on the hosted CI%s)"):format(
      short,
      args.branch,
      url and (": " .. url) or ""
    )
  )
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
  return M.run(args, sv.out, state_dir --[[@as string]])
end

return M
