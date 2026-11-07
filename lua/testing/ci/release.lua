---@module 'testing.ci.release'
---@brief `testing ci release`: release a commit for the self-hosted runner and re-run its refused jobs, in one word.
---@description
--- ```
--- testing ci release [<owner/repo>] [<sha>] [--yes] [--note=<text>] [--count=<n>] [--runners=<dir>]
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

local M = {}

M.COUNT = 10
M.MAX_COUNT = 50

M.USAGE = table.concat({
  "usage: testing ci release [<owner/repo>] [<sha>] [--yes] [--note=<text>] [--count=<n>] [--runners=<dir>]",
  "  In a terminal it asks for what is missing: the repository, the commit (from the last --count, default 10),",
  "  then shows what changed since the last reviewed commit and asks before it releases the commit and re-runs",
  "  its failed runs. Without a terminal: the repository, the commit and --yes must be given.",
}, "\n")

local RERUN = { failure = true, cancelled = true, startup_failure = true, timed_out = true }

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

---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), cwd?: string }
---@param ctx? Testing.Release.Ctx
---@return integer
function M.main(argv, sv, ctx)
  local rg = require("testing.ci.runner_guard")
  local a, problem = M.parse(argv)
  if not a then
    sv.err("testing ci release: " .. problem)
    sv.err(M.USAGE)
    return 2
  end
  if a.help then
    sv.out(M.USAGE)
    return 0
  end
  -- a spec passes its answers (`ask`), or `false` for "no terminal"
  local ask
  if ctx and ctx.ask ~= nil then
    ask = ctx.ask or nil
  else
    ask = terminal_ask()
  end
  if not ask and not (a.repo and a.sha and a.yes) then
    sv.err(
      "testing ci release: no terminal to ask in: name the repository and the commit, and add --yes"
    )
    return 2
  end
  local store = rg.read(rg.store_path(rg.root(ctx, a.runners)))

  -- 1. the repository
  local repo = a.repo
  if not repo then
    local here = rg.repo_of_cwd(ctx, sv.cwd)
    local list, seen = {}, {}
    if here then
      list[1], seen[here:lower()] = here, true
    end
    local keys = vim.tbl_keys(store)
    table.sort(keys)
    for _, k in ipairs(keys) do
      if not seen[k:lower()] then
        list[#list + 1], seen[k:lower()] = k, true
      end
    end
    local labels = {}
    for i, r in ipairs(list) do
      labels[i] = (i == 1 and here) and (r .. "   (this folder)") or r
    end
    ---@cast ask fun(prompt: string): string|nil
    local i, typed = choose(ask, sv, "Repository:", labels, rg.repo_key)
    repo = typed and tostring(typed) or (i and list[i])
    if not repo then
      sv.err("testing ci release: no repository chosen")
      return 2
    end
  end
  local key = rg.repo_key(repo) or repo:lower()

  -- 2. the commit
  local ref = a.sha
  if not ref then
    local raw, err =
      rg.call_gh(ctx, { "api", ("repos/%s/commits?per_page=%d"):format(repo, a.count) })
    local commits = decode(raw)
    if not commits then
      sv.err(("testing ci release: cannot list the commits of %s: %s"):format(repo, tostring(err)))
      return 3
    end
    local released = {}
    for _, s in ipairs(store[key] and store[key].shas or {}) do
      released[s.sha] = true
    end
    local labels, shas = {}, {}
    for _, c in ipairs(commits) do
      if type(c) == "table" and rg.is_sha(c.sha) then
        local info = type(c.commit) == "table" and c.commit or {}
        local author = type(info.author) == "table" and info.author or {}
        local title = tostring(info.message or ""):match("^[^\n]*"):gsub("%c", " "):sub(1, 60)
        shas[#shas + 1] = c.sha
        labels[#labels + 1] = ("%s  %-60s  %-16s %s%s"):format(
          c.sha:sub(1, 10),
          title,
          tostring(author.name or "?"):gsub("%c", " "):sub(1, 16),
          tostring(author.date or ""):sub(1, 10),
          released[c.sha] and "  (released)" or ""
        )
      end
    end
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
    ref = typed or (i and shas[i])
    if not ref then
      sv.err("testing ci release: no commit chosen")
      return 2
    end
  end
  local full, ferr =
    rg.call_gh(ctx, { "api", ("repos/%s/commits/%s"):format(repo, ref), "--jq", ".sha" })
  full = full and full:gsub("%s+", "")
  if not rg.is_sha(full) then
    sv.err(("testing ci release: %s has no commit %s: %s"):format(repo, ref, tostring(ferr)))
    return 3
  end
  ---@cast full string

  -- 3. what changed, 4. the question
  local runners = a.runners and { "--runners=" .. a.runners } or {}
  local shown = rg.trust_main(vim.list_extend({ repo, full, "--show" }, runners), sv, ctx)
  if shown ~= 0 then
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
  local raw, rerr =
    rg.call_gh(ctx, { "api", ("repos/%s/actions/runs?head_sha=%s&per_page=50"):format(repo, full) })
  local doc = decode(raw)
  if not doc or type(doc.workflow_runs) ~= "table" then
    sv.err(("testing ci release: released, but the runs cannot be read: %s"):format(tostring(rerr)))
    return 3
  end
  local rerun, failed = 0, false
  for _, run in ipairs(doc.workflow_runs) do
    if
      type(run) == "table"
      and type(run.id) == "number"
      and run.status == "completed"
      and RERUN[run.conclusion]
    then
      local _, err = rg.call_gh(ctx, { "run", "rerun", tostring(run.id), "-R", repo, "--failed" })
      if err then
        failed = true
        sv.err(("  re-run %d (%s) failed: %s"):format(run.id, tostring(run.name), err))
      else
        rerun = rerun + 1
        sv.out(("  re-run %d (%s, was %s)"):format(run.id, tostring(run.name), run.conclusion))
      end
    end
  end
  if rerun == 0 and not failed then
    sv.out("no failed run of this commit: nothing to re-run")
  end
  return failed and 3 or 0
end

return M
