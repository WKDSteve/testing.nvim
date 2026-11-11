-- TESTS/testing/ci_land_spec.lua -- `testing ci land`: the commit goes to a check branch ci/<repo>-<sha>, the hosted CI
-- checks it, and main moves to it (a plain fast-forward push) only when the run is green; red leaves main alone, a
-- main that moved is never merged, a workflow without land is refused, a run that never appears or never ends gives up.
-- git, GitHub and the clock are fakes.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end

  local land = require("testing.ci.land")
  local SHA, BASE, OTHER = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40)
  local saved = vim.deepcopy(land.deps)

  ---One scenario: `o.states` are the answers of the remote, one per look; `o.base` main before, `o.moved_after` the
  ---main after a green run; `o.workflow` the text of the commit's workflow file.
  local function scenario(o, argv)
    local w = { pushes = {}, fetches = 0, base = o.base or BASE, looks = 0, said = {} }
    local clock = 1000
    land.deps.git = function(_, args)
      local cmd = args[1]
      if cmd == "rev-parse" then
        local rev = args[#args]:gsub("%^{commit}$", "")
        if rev == "origin/main" then
          return 0, w.base .. "\n", ""
        end
        return 0, SHA .. "\n", ""
      elseif cmd == "fetch" then
        w.fetches = w.fetches + 1
        if o.moved_after and w.fetches >= 2 then
          w.base = o.moved_after
        end
        return 0, "", ""
      elseif cmd == "merge-base" then
        return args[3] == BASE and 0 or 1, "", ""
      elseif cmd == "show" then
        return 0, o.workflow or 'on:\n  push:\n    branches: [main, "ci/**"]\n', ""
      elseif cmd == "push" then
        w.pushes[#w.pushes + 1] = table.concat(args, " ")
        return 0, "", ""
      end
      return 1, "", "unexpected git " .. table.concat(args, " ")
    end
    land.deps.remote = function(_, sha)
      w.looks = w.looks + 1
      w.asked = sha
      return o.states[math.min(w.looks, #o.states)]
    end
    land.deps.sleep = function() end
    land.deps.now = function()
      clock = clock + 31
      return clock
    end
    local args = assert(land.parse(argv or {}))
    w.code = land.run(args, function(s)
      w.said[#w.said + 1] = s
    end, "/state")
    w.text = table.concat(w.said, "\n")
    return w
  end
  local CHECK = "ci/"
    .. require("testing.metrics").repo_name(vim.fn.getcwd())
    .. "-"
    .. SHA:sub(1, 12)

  -- green: the check branch, the run, main moves, the check branch goes
  local w = scenario({
    states = {
      { overall = "no_run" },
      { overall = "running" },
      { overall = "success", run = { url = "https://x/run/1" } },
    },
  })
  eq(w.code, 0, "green: landed")
  eq(w.asked, SHA, "green: the remote is asked about exactly that commit")
  eq(w.pushes, {
    "push --quiet origin " .. SHA .. ":refs/heads/" .. CHECK,
    "push --quiet origin " .. SHA .. ":refs/heads/main",
    "push --quiet origin --delete refs/heads/" .. CHECK,
  }, "green: check branch, then main (no force), then the check branch is deleted")
  has(w.text, "landed on main", "green: says so")
  has(w.text, "https://x/run/1", "green: ... with the run")
  has(w.text, ": running", "green: the states on the way")

  -- from a linked worktree the check branch carries the repository's name, not the folder's
  do
    local tmp = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(tmp .. "/myrepo/.git/worktrees/myrepo-topic", "p")
    vim.fn.mkdir(tmp .. "/myrepo-topic", "p")
    local f = assert(io.open(tmp .. "/myrepo-topic/.git", "wb"))
    f:write("gitdir: " .. tmp .. "/myrepo/.git/worktrees/myrepo-topic\n")
    f:close()
    local wt = scenario(
      { states = { { overall = "success", run = { url = "https://x/run/2" } } } },
      { "--root=" .. tmp .. "/myrepo-topic" }
    )
    eq(wt.code, 0, "worktree: landed")
    eq(
      wt.pushes[1],
      "push --quiet origin " .. SHA .. ":refs/heads/ci/myrepo-" .. SHA:sub(1, 12),
      "worktree: the check branch is named after the repository"
    )
    vim.fn.delete(tmp, "rf")
  end

  -- red: main stays, the systems are named
  w = scenario({
    states = {
      { overall = "running" },
      {
        overall = "failure",
        os = {
          ubuntu = { state = "success" },
          macos = { state = "failure", url = "https://x/job/9" },
        },
        run = { url = "https://x/run/2" },
      },
    },
  })
  eq(w.code, 1, "red: exit 1")
  eq(#w.pushes, 2, "red: the check branch and its deletion, no push to main")
  ok(not w.pushes[2]:find(":refs/heads/main", 1, true), "red: main does not move")
  has(w.text, "is red on the hosted CI", "red: says so")
  has(w.text, "macos    failure  https://x/job/9", "red: names the red system")

  -- all jobs green while the run is still in progress is no verdict: a later job or the conclusion can still be red
  w = scenario({
    states = {
      { overall = "success", run = { status = "in_progress" } },
      { overall = "failure", run = { status = "completed", url = "https://x/run/3" } },
    },
  })
  eq(w.code, 1, "in progress: green jobs of an unfinished run do not land")
  ok(not (w.pushes[2] or ""):find(":refs/heads/main", 1, true), "in progress: main does not move")
  has(w.text, "the run is not completed yet", "in progress: says why it waits")
  w = scenario({
    states = {
      { overall = "success", run = { status = "in_progress" } },
      { overall = "success", run = { status = "completed" } },
    },
  })
  eq(w.code, 0, "in progress: lands once the run is completed")

  -- landing the same commit again (an earlier land was red): its old run is no answer until the new one exists
  w = scenario({
    states = {
      { overall = "failure", run = { created_at = "1970-01-01T00:00:00Z" } },
      { overall = "running", run = { created_at = "1970-01-01T00:20:00Z" } },
      { overall = "success", run = { created_at = "1970-01-01T00:20:00Z" } },
    },
  })
  eq(w.code, 0, "again: the old red run of the commit does not count")
  has(w.text, "only an older run of this commit so far", "again: says why it waits")

  -- main moved before: nothing is pushed
  w = scenario({ base = OTHER, states = { { overall = "success" } } })
  eq(w.code, 1, "moved before: exit 1")
  eq(w.pushes, {}, "moved before: nothing pushed")
  has(w.text, "Rebase onto origin/main", "moved before: says what to do")

  -- main moved while the run went: green, but no push to main
  w = scenario({ moved_after = OTHER, states = { { overall = "success" } } })
  eq(w.code, 1, "moved after: exit 1")
  eq(#w.pushes, 2, "moved after: no push to main")
  has(w.text, "moved meanwhile", "moved after: says so")

  -- already there
  w = scenario({ base = SHA, states = { { overall = "success" } } })
  eq({ w.code, #w.pushes }, { 0, 0 }, "already on main: nothing to do")

  -- a workflow without land
  w = scenario({
    workflow = "on:\n  push:\n    branches: [main]\n",
    states = { { overall = "success" } },
  })
  eq({ w.code, #w.pushes }, { 2, 0 }, "no land in the workflow: refused before any push")
  has(w.text, "ci.workflow.land = true", "no land: says how to switch it on")

  -- no run appears: give up after NO_RUN_S, the check branch goes
  w = scenario({ states = { { overall = "no_run" } } })
  eq(w.code, 3, "no run: exit 3")
  has(w.text, "does the pushed workflow run on ci/**", "no run: says why")
  has(w.pushes[#w.pushes], "--delete", "no run: the check branch goes")

  -- a run that does not end: the deadline
  w = scenario({ states = { { overall = "running" } } }, { "--timeout=1" })
  eq(w.code, 3, "deadline: exit 3")
  has(w.text, "no verdict within 1 min", "deadline: says so")

  -- --keep leaves the check branch
  w = scenario({ states = { { overall = "success" } } }, { "--keep" })
  eq(#w.pushes, 2, "keep: no deletion")
  has(w.text, "stays (--keep)", "keep: says so")

  -- the arguments
  eq(land.parse({}).rev, "HEAD", "args: HEAD by default")
  eq(land.parse({ "abc", "--branch=dev" }).branch, "dev", "args: another branch")
  local none, why = land.parse({ "a", "b" })
  eq(none, nil, "args: two commits")
  has(why, "one commit at a time", "args: ... refused")
  none, why = land.parse({ "--timeout=0" })
  eq(none, nil, "args: a timeout below one minute")
  has(why, "--timeout", "args: ... names the option")
  none, why = land.parse({ "--branch=--x" })
  eq(none, nil, "args: an option is no branch")
  ok(why ~= nil, "args: ... and says why")

  land.deps = saved
end
