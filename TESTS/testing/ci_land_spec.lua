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
    w.push_env = {}
    land.deps.git = function(_, args, env)
      local cmd = args[1]
      if cmd == "push" then
        w.push_env[#w.push_env + 1] = env and env.TESTING_LAND_PUSH or "-"
      end
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
      elseif cmd == "diff" then
        return 0, table.concat(o.changed or { "lua/x.lua" }, "\0"), ""
      elseif cmd == "show" then
        return 0, o.workflow or 'on:\n  push:\n    branches: [main, "ci/**"]\n', ""
      elseif cmd == "push" then
        w.pushes[#w.pushes + 1] = table.concat(args, " ")
        return 0, "", ""
      end
      return 1, "", "unexpected git " .. table.concat(args, " ")
    end
    -- `o.also` the workflows of ci.workflow.land.also (or `o.also_err`), `o.also_states[name]` their answers
    w.wf_looks, w.asked_wf = {}, {}
    land.deps.also = function()
      if o.also_err then
        return nil, o.also_err
      end
      return o.also or {}
    end
    -- `o.before` (`o.before_also[name]`): the answer before the check branch is pushed, default no run
    w.before_looks = 0
    land.deps.remote = function(_, sha, _, wf)
      if #w.pushes == 0 then
        w.before_looks = w.before_looks + 1
        if wf then
          return o.before_also and o.before_also[wf] or { overall = "no_run" }
        end
        return o.before or { overall = "no_run" }
      end
      if wf then
        w.asked_wf[#w.asked_wf + 1] = wf
        w.wf_looks[wf] = (w.wf_looks[wf] or 0) + 1
        local list = assert(o.also_states and o.also_states[wf], "no states for " .. wf)
        return list[math.min(w.wf_looks[wf], #list)]
      end
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
  eq(
    w.push_env,
    { "-", "1", "-" },
    "green: only the push of main says it comes from land (the pre-push guard lets it through)"
  )
  has(w.text, "landed on main", "green: says so")
  has(w.text, "https://x/run/1", "green: ... with the run")
  has(w.text, ": running", "green: the states on the way")
  has(w.text, "CI-10:", "green: while the hosted CI runs, the line of rule CI-10")

  -- a run GitHub skipped by the marker in the commit text (no run, `skipped`): only documentation may land that way
  do
    local skipped = { overall = "skipped", note = "head commit has the skip marker" }
    local code_change = scenario({ states = { skipped }, changed = { "lua/x.lua", "README.md" } })
    eq(code_change.code, 1, "skipped + code: land stops")
    has(
      code_change.text,
      "skipped by marker in the commit text, but code changed",
      "skipped + code: says why"
    )
    has(code_change.text, "main stays", "skipped + code: ... and that main stays")
    eq(code_change.text:find("landed on", 1, true), nil, "skipped + code: never says landed")
    for _, p in ipairs(code_change.pushes) do
      eq(p:find(":refs/heads/main", 1, true), nil, "skipped + code: main is not pushed")
    end
    local docs = scenario({ states = { skipped }, changed = { "README.md", "docs/CI.md" } })
    eq(docs.code, 0, "skipped + docs only: lands")
    has(
      docs.text,
      "landed on main WITHOUT a hosted run (docs only, skipped by marker)",
      "skipped + docs: says it honestly"
    )
    eq(
      docs.text:find("green on the hosted CI", 1, true),
      nil,
      "skipped + docs: never claims a hosted run"
    )
    -- a real run whose jobs were all skipped is a run: lands as green
    local real = scenario({
      states = { { overall = "skipped", run = { url = "https://x/run/2" } } },
      changed = { "lua/x.lua" },
    })
    eq(real.code, 0, "skipped jobs of a real run: lands")
    has(real.text, "green on the hosted CI", "skipped jobs of a real run: as green")
  end

  -- the line of CI-10 can be turned off: in the environment and with vim.g
  do
    local saved_env, saved_g = vim.env.TESTING_CI_HINT, vim.g.testing_ci_hint
    vim.env.TESTING_CI_HINT = "0"
    local quiet = scenario({ states = { { overall = "success" } } })
    vim.env.TESTING_CI_HINT = saved_env
    vim.g.testing_ci_hint = false
    local quiet_g = scenario({ states = { { overall = "success" } } })
    vim.g.testing_ci_hint = saved_g
    eq(quiet.text:find("CI-10:", 1, true), nil, "TESTING_CI_HINT=0: no line of CI-10")
    eq(quiet_g.text:find("CI-10:", 1, true), nil, "vim.g.testing_ci_hint = false: no line of CI-10")
  end

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

  -- red while another system still runs: the wait ends at the first red system, and the last line says so (the tail
  -- `windows running` / `run: ...` read like land giving up, m1-review 2026-11-13)
  w = scenario({
    states = {
      {
        overall = "failure",
        os = {
          ubuntu = { state = "failure", url = "https://x/job/1" },
          windows = { state = "running", url = "https://x/job/2" },
        },
        run = { url = "https://x/run/4" },
      },
    },
  })
  eq(w.code, 1, "red, one still running: exit 1")
  eq(
    w.said[#w.said],
    "land: red (ubuntu failure); origin/main does not move, nothing landed",
    "red, one still running: the last line is the verdict with the red system"
  )

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
  local old_red = {
    overall = "failure",
    run = {
      id = 1,
      status = "completed",
      conclusion = "failure",
      url = "https://x/run/old",
      created_at = "1970-01-01T00:00:00Z",
    },
  }
  w = scenario({
    before = old_red,
    states = {
      old_red,
      { overall = "running", run = { id = 2, created_at = "1970-01-01T00:20:00Z" } },
      { overall = "success", run = { id = 2, created_at = "1970-01-01T00:20:00Z" } },
    },
  })
  eq(w.code, 0, "again: the old red run of the commit does not count")
  has(w.text, "only an older run of this commit so far", "again: says why it waits")

  -- no new run for the check branch, only the old red one: give up after NO_RUN_S, saying which run to rerun
  w = scenario({ before = old_red, states = { old_red } })
  eq(w.code, 3, "old red only: exit 3")
  has(w.text, "the only run of the commit is an older one", "old red only: says so")
  has(w.text, "gh run rerun 1", "old red only: ... and how to rerun it")

  -- the commit is green and completed already (an earlier land gave up, or its push of main failed): main moves at
  -- once, no check branch, no second hosted run (found 2026-11-26: only a second `ci land` landed)
  do
    local green = {
      overall = "success",
      run = {
        id = 3,
        status = "completed",
        conclusion = "success",
        branch = "ci/x-aaaa",
        url = "https://x/run/3",
      },
    }
    w = scenario({ before = green, states = { { overall = "no_run" } } })
    eq(w.code, 0, "green before: landed")
    eq(
      w.pushes,
      { "push --quiet origin " .. SHA .. ":refs/heads/main" },
      "green before: only main is pushed, no check branch"
    )
    has(w.text, "green already on the hosted CI on ci/x-aaaa", "green before: says so")
    has(w.text, "https://x/run/3", "green before: names the run")
    -- an also-workflow that is not green yet: the check branch goes up as before
    w = scenario({
      before = green,
      before_also = { native = { overall = "no_run" } },
      also = { "native" },
      states = { green },
      also_states = { native = { { overall = "success" } } },
    })
    eq(w.code, 0, "green before, native not: landed after the wait")
    eq(#w.pushes, 3, "green before, native not: check branch, main, deletion")
  end

  -- GitHub's clock and the machine's differ by minutes: the new run looks older than the push by created_at, but it is
  -- not the run from before (another id), so it is this push's run, not `no_run` until NO_RUN_S
  w = scenario({
    before = old_red,
    states = {
      {
        overall = "running",
        run = { id = 9, status = "in_progress", created_at = "1970-01-01T00:00:00Z" },
      },
      {
        overall = "success",
        run = { id = 9, status = "completed", created_at = "1970-01-01T00:00:00Z" },
      },
    },
  })
  eq(w.code, 0, "clock skew: the new run is told apart by its id")
  eq(w.text:find("only an older run", 1, true), nil, "clock skew: never called an older run")

  -- an earlier run of the commit still runs (pushed elsewhere a moment before): no `no_run` after NO_RUN_S, it is
  -- waited for, and its green completion is the verdict
  do
    local states = {}
    local going = {
      overall = "running",
      run = { id = 5, status = "in_progress", created_at = "1970-01-01T00:00:00Z" },
    }
    for _ = 1, 15 do -- 15 looks of 31 s each: past NO_RUN_S
      states[#states + 1] = going
    end
    states[#states + 1] = {
      overall = "success",
      run = { id = 5, status = "completed", created_at = "1970-01-01T00:00:00Z", branch = "ci/y" },
    }
    w = scenario({ before = going, states = states })
    eq(w.code, 0, "earlier run going: waited for past NO_RUN_S, then landed")
    has(w.text, "an earlier run of this commit still runs", "earlier run going: says so")
    has(
      w.text,
      "an earlier run of this commit on ci/y is green",
      "earlier run going: its green is the verdict"
    )
  end

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

  -- ci.workflow.land.also: main moves only when the other workflows of the commit are green too (mdview.nvim's
  -- native.yml beside the generated ci.yml: a red native run did not hold main)
  w = scenario({
    also = { "native" },
    states = { { overall = "success", run = { url = "https://x/run/ci" } } },
    also_states = {
      native = { { overall = "running" }, { overall = "success" } },
    },
  })
  eq(w.code, 0, "also green: landed")
  eq(w.wf_looks.native, 2, "also green: it waited for the other workflow")
  has(w.text, "on " .. CHECK .. " (native): running", "also: the other workflow's state, named")
  has(w.text, "https://x/run/ci", "also green: the run of CI is named")
  eq(
    w.pushes[2],
    "push --quiet origin " .. SHA .. ":refs/heads/main",
    "also green: main moves (the guard push)"
  )
  eq(w.push_env, { "-", "1", "-" }, "also green: only the push of main says it comes from land")

  w = scenario({
    also = { "native" },
    states = { { overall = "success" } },
    also_states = {
      native = {
        { overall = "running" },
        {
          overall = "failure",
          os = { macos = { state = "failure", url = "https://x/job/7" } },
          run = { url = "https://x/run/n" },
        },
      },
    },
  })
  eq(w.code, 1, "also red: exit 1 although CI is green")
  ok(not (w.pushes[2] or ""):find(":refs/heads/main", 1, true), "also red: main does not move")
  has(w.text, "is red in the workflow native", "also red: names the workflow")
  has(w.text, "macos    failure  https://x/job/7", "also red: names the red system")
  eq(
    w.said[#w.said],
    "land: red (native: macos failure); origin/main does not move, nothing landed",
    "also red: the last line names the workflow"
  )

  -- --also adds one; a workflow named twice is waited for once
  w = scenario({
    also = { "native" },
    states = { { overall = "success" } },
    also_states = { native = { { overall = "success" } }, release = { { overall = "success" } } },
  }, { "--also=Native,release" })
  eq(w.code, 0, "--also: landed")
  eq(w.asked_wf, { "native", "release" }, "--also: each workflow once, names without case")

  -- the other workflow never runs on ci/**: give up, naming it
  w = scenario({
    also = { "native" },
    states = { { overall = "success" } },
    also_states = { native = { { overall = "no_run" } } },
  })
  eq(w.code, 3, "also no run: exit 3")
  has(w.text, "no run of the workflow native", "also no run: names it")

  -- an unreadable .testing.lua: nothing is pushed (it must not land without the workflows it names)
  w = scenario({ also_err = "not trusted", states = { { overall = "success" } } })
  eq({ w.code, #w.pushes }, { 2, 0 }, "also unreadable: refused before any push")
  has(w.text, "not trusted", "also unreadable: says why")

  -- the real reader: ci.workflow.land.also of the checkout
  do
    local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-land-also"
    vim.fn.mkdir(tmp, "p")
    local f = assert(io.open(tmp .. "/.testing.lua", "wb"))
    f:write("return { ci = { workflow = { name = 'x.nvim', land = { also = { 'native' } } } } }\n")
    f:close()
    eq({ saved.also(tmp) }, { { "native" } }, "also: read from ci.workflow.land.also")
    f = assert(io.open(tmp .. "/.testing.lua", "wb"))
    f:write("return { ci = { workflow = { name = 'x.nvim', land = true } } }\n")
    f:close()
    eq({ saved.also(tmp) }, { {} }, "also: none with land = true")
    vim.fn.delete(tmp, "rf")
  end
  do
    local no_args, problem = land.parse({ "--also=a;b" })
    eq(no_args, nil, "args: --also takes workflow names only")
    has(problem, "--also", "args: ... names the option")
  end

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

  -- scripts/test.sh puts its --state-dir in front of the subcommand: land, remote and overview are still found, and
  -- the state directory goes with them (found 2026-11-16: `scripts/test.sh ci land` printed the usage of `testing ci`)
  for _, sub in ipairs({ "land", "remote", "overview" }) do
    local mod = require("testing.ci." .. sub)
    local real = mod.main
    local seen
    mod.main = function(argv)
      seen = argv
      return 0
    end
    local code1 = require("testing.ci").main({ "--state-dir", "/st", sub, "--keep" }, { env = {} })
    local got1 = seen
    seen = nil
    local code2 = require("testing.ci").main({ "--state-dir=/st", sub }, { env = {} })
    local got2 = seen
    mod.main = real
    eq(code1, 0, sub .. ": --state-dir <dir> in front: dispatched")
    eq(
      got1,
      { "--state-dir=/st", "--keep" },
      sub .. ": ... with the state directory and its own arguments"
    )
    eq(code2, 0, sub .. ": --state-dir=<dir> in front: dispatched")
    eq(got2, { "--state-dir=/st" }, sub .. ": ... with the state directory")
  end
end
