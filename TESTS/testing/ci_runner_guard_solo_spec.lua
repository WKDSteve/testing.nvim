-- TESTS/testing/ci_runner_guard_solo_spec.lua -- `solo` mode of the runner guard: the owner works alone, so the
-- guard lets the owner's pushes through without a release, and turns itself on (for good) as soon as another
-- account shows up. Pull requests and foreign actors stay refused in every mode. No network: a fake `gh`.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local guard = require("testing.ci.runner_guard")
  local SHA = ("a"):rep(40)
  local REPO = "WKDSteve/tasks.nvim"
  local NOW = 1800000000

  local function sink()
    local o = { out = {}, err = {} }
    o.sv = {
      out = function(s)
        o.out[#o.out + 1] = s
      end,
      err = function(s)
        o.err[#o.err + 1] = s
      end,
    }
    return o
  end
  local function joined(o)
    return table.concat(o.out, "\n") .. "\n" .. table.concat(o.err, "\n")
  end
  local function tmp()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (vim.fs.normalize(d))
  end

  local function env(over)
    return vim.tbl_extend("force", {
      GITHUB_EVENT_NAME = "push",
      GITHUB_ACTOR = "WKDSteve",
      GITHUB_TRIGGERING_ACTOR = "WKDSteve",
      GITHUB_REPOSITORY = REPO,
      GITHUB_REPOSITORY_OWNER = "WKDSteve",
      GITHUB_SHA = SHA,
    }, over or {})
  end

  ---A fake GitHub: who collaborates, contributes and opened pull requests. `fail` names an endpoint that errors.
  local function fake(state)
    state.calls = state.calls or {}
    return function(args)
      local endpoint = args[2] or ""
      state.calls[#state.calls + 1] = endpoint
      local function lines(list)
        return table.concat(list or {}, "\n") .. "\n"
      end
      if endpoint == "repos/" .. REPO and args[4] == ".private" then
        return "false\n"
      end
      for name, list in pairs({
        collaborators = "collab",
        contributors = "contrib",
        pulls = "pulls",
      }) do
        if endpoint:find("/" .. name .. "?", 1, true) then
          if state.fail == name then
            return nil, "HTTP 500: boom"
          end
          return lines(state[list])
        end
      end
      return nil, "unexpected " .. endpoint
    end
  end

  local function setup(mode)
    local root = tmp()
    local o = sink()
    guard.trust_main({ "--mode=" .. mode, REPO, "--runners=" .. root }, o.sv, { root = root })
    return root
  end
  local function entry(root)
    return guard.read(guard.store_path(root))[REPO:lower()]
  end
  local function run_check(root, state, over, now)
    local o = sink()
    local code = guard.main({ "check" }, o.sv, {
      env = env(over),
      root = root,
      gh = fake(state),
      now = now or NOW,
      nvim = "/x/nvim",
      script = "/x/scripts/testing.lua",
    })
    return code, joined(o)
  end

  -- ------------------------------------------------------------------ the decision

  local function facts(over)
    return vim.tbl_extend("force", {
      event = "push",
      actor = "WKDSteve",
      triggering_actor = "WKDSteve",
      repo = REPO,
      owner = "WKDSteve",
      sha = SHA,
      is_private = false,
      entry = { mode = "solo", shas = {} },
    }, over or {})
  end
  do
    ok(guard.MODES.solo == true, "solo is a mode")

    local run, why = guard.decide(facts({
      solo = function()
        return true, "no other account"
      end,
    }))
    eq(run, true, "decide: alone, an unreviewed commit of the owner runs")
    has(why, "solo", "decide: ... and says why")

    local f = facts({
      solo = function()
        return false, "collaborator mallory"
      end,
    })
    run, why = guard.decide(f)
    eq(run, false, "decide: with another account the commit is refused as in auto")
    has(why, "collaborator mallory", "decide: ... and names who")
    has(why, "not reviewed", "decide: ... and the usual reason follows")
    eq(f.solo_found, "collaborator mallory", "decide: the finding is handed to the writer")

    f = facts({
      solo = function()
        return nil, "HTTP 500"
      end,
    })
    run = guard.decide(f)
    eq(run, false, "decide: no answer from GitHub refuses (fail closed)")
    eq(
      f.solo_found,
      nil,
      "decide: ... but records nothing (a rate limit says nothing about the repository)"
    )

    run = guard.decide(facts())
    eq(run, false, "decide: solo without a way to ask refuses")

    local asked = false
    local function ask()
      asked = true
      return true, "alone"
    end
    run = guard.decide(facts({ event = "pull_request", solo = ask }))
    eq(run, false, "decide: a pull request is refused in solo mode")
    eq(asked, false, "decide: ... without asking GitHub")
    run = guard.decide(facts({ actor = "mallory", solo = ask }))
    eq(run, false, "decide: a foreign actor is refused in solo mode")
    run = guard.decide(facts({ event = "pull_request_review", solo = ask }))
    eq(run, false, "decide: an event outside the allowlist is refused in solo mode")

    run = guard.decide(facts({
      entry = { mode = "solo", shas = { { sha = SHA, at = 1 } } },
      solo = function()
        error("a reviewed commit needs no question")
      end,
    }))
    eq(run, true, "decide: a reviewed commit runs without asking GitHub")
  end

  -- ------------------------------------------------------------------ the hook

  do
    local root = setup("solo")
    eq(entry(root).mode, "solo", "setup: the mode is stored")

    local state = {}
    local run = { GITHUB_RUN_ID = "4711", GITHUB_RUN_ATTEMPT = "1" }
    local code, text = run_check(root, state, run)
    eq(code, 0, "check: the owner alone, an unreviewed commit runs")
    has(text, "solo", "check: ... says so")
    eq(entry(root).mode, "solo", "check: ... and the mode stays")
    local n = #state.calls

    code = run_check(root, state, run, NOW + 30)
    eq(code, 0, "check: a second job of the run runs too")
    eq(
      #state.calls,
      n + 1,
      "check: ... and asked GitHub only for the repository's privacy (the run's answer is shared)"
    )

    code = run_check(root, state, run, NOW + guard.SOLO_TTL_S + 1)
    eq(code, 0, "check: a job long after the others asks again")
    ok(#state.calls > n + 2, "check: ... asking GitHub again")

    n = #state.calls
    code = run_check(root, state, { GITHUB_RUN_ID = "4712" }, NOW + 40)
    eq(code, 0, "check: the next run runs")
    ok(#state.calls > n + 1, "check: ... and asks for itself (another run never reads this answer)")
    n = #state.calls
    code = run_check(root, state, { GITHUB_RUN_ID = "4712", GITHUB_RUN_ATTEMPT = "2" }, NOW + 41)
    eq(code, 0, "check: a re-run of it runs")
    ok(#state.calls > n + 1, "check: ... and asks again too")
    n = #state.calls
    run_check(root, state, nil, NOW + 42)
    run_check(root, state, nil, NOW + 43)
    ok(#state.calls >= n + 8, "check: without a run id every job asks for itself")

    -- the window that must stay shut: somebody opens a pull request after the answer and the owner merges it
    -- within minutes; the push run of the merge is a new run and sees the account
    code = run_check(root, { pulls = { "WKDSteve", "eve" } }, { GITHUB_RUN_ID = "4713" }, NOW + 60)
    eq(code, 1, "check: a newer run sees the pull request of a foreign account at once")
    root = setup("solo")
    run_check(root, {}, run, NOW)
    code = run_check(root, { pulls = { "eve" } }, { GITHUB_RUN_ID = "4714" }, NOW + 60)
    eq(code, 1, "check: ... also when an earlier run had just found the owner alone")
    root = setup("solo")

    code = run_check(root, state, { GITHUB_EVENT_NAME = "pull_request" })
    eq(code, 1, "check: a pull request is refused in solo mode")
    code = run_check(root, state, { GITHUB_ACTOR = "mallory" })
    eq(code, 1, "check: a foreign actor is refused in solo mode")
    eq(entry(root).mode, "solo", "check: ... and neither ends solo mode")
  end

  for name, spec in pairs({
    collaborator = {
      state = { collab = { "WKDSteve", "mallory" } },
      mention = "collaborator mallory",
    },
    contributor = {
      state = { contrib = { "WKDSteve", "dependabot[bot]" } },
      mention = "contributor dependabot[bot]",
    },
    ["pull request"] = {
      state = { pulls = { "WKDSteve", "Eve" } },
      mention = "pull request by eve",
    },
  }) do
    local root = setup("solo")
    local code, text = run_check(root, spec.state)
    eq(code, 1, "check: a " .. name .. " of somebody else ends the free pass")
    has(text, spec.mention, "check: ... names the signal (" .. name .. ")")
    local e = entry(root)
    eq(e.mode, "auto", "check: ... and the guard is on for good (" .. name .. ")")
    has(e.flipped or "", spec.mention, "check: ... with the reason stored (" .. name .. ")")
    has(e.flipped or "", "2027-01-15", "check: ... and the day")

    -- the other account is gone again: the guard stays on until a person says otherwise
    code = run_check(root, {})
    eq(code, 1, "check: sticky, the guard stays on when the signal is gone (" .. name .. ")")

    local o = sink()
    guard.trust_main({ "--mode=solo", REPO, "--runners=" .. root }, o.sv, { root = root })
    eq(entry(root).mode, "solo", "trust: a person turns solo mode on again (" .. name .. ")")
    eq(entry(root).flipped, nil, "trust: ... and the old reason is gone (" .. name .. ")")
    code = run_check(root, {})
    eq(code, 0, "check: alone again, it runs (" .. name .. ")")
  end

  do
    -- an agent's commit authored by an address GitHub cannot link to an account is not a foreign party: it lists no
    -- account at all
    local root = setup("solo")
    eq(
      run_check(root, { contrib = { "WKDSteve" } }),
      0,
      "check: only the owner's account contributes: solo"
    )
  end

  for _, endpoint in ipairs({ "collaborators", "contributors", "pulls" }) do
    local root = setup("solo")
    local state = { fail = endpoint }
    local code, text = run_check(root, state)
    eq(code, 1, "check: no answer about " .. endpoint .. " refuses (fail closed)")
    has(text, "JOB REFUSED", "check: ... loudly")
    eq(
      entry(root).mode,
      "solo",
      "check: ... and does not end solo mode for good (" .. endpoint .. ")"
    )
    state.fail = nil
    eq(
      run_check(root, state),
      0,
      "check: the next job with an answer runs again (" .. endpoint .. ")"
    )
  end

  do
    -- a full page is not the whole list: a stranger beyond the first `SOLO_PAGE` entries must be seen (paged), and a
    -- list longer than the cap is unknown, never "alone"
    local function paged(pages)
      local calls = {}
      return calls,
        function(args)
          local endpoint = args[2] or ""
          calls[#calls + 1] = endpoint
          if not endpoint:find("/contributors?", 1, true) then
            return "WKDSteve\n"
          end
          local page = tonumber(endpoint:match("[?&]page=(%d+)") or "1")
          local list = pages[page] or {}
          return table.concat(list, "\n") .. (#list > 0 and "\n" or "")
        end
    end
    local function contributor_calls(calls)
      return #vim.tbl_filter(function(c)
        return c:find("/contributors?", 1, true) ~= nil
      end, calls)
    end
    local owners = {}
    for i = 1, guard.SOLO_PAGE do
      owners[i] = "WKDSteve"
    end
    local calls, gh = paged({ owners, { "stranger" } })
    local alone, detail =
      guard.solo_clear(REPO, "WKDSteve", { gh = gh, now = NOW, env = {} }, tmp())
    eq(alone, false, "paging: a stranger on page 2 is somebody else")
    has(detail, "contributor stranger", "paging: ... and is named")
    eq(contributor_calls(calls), 2, "paging: a short page ends the paging")

    local short = vim.list_slice(owners, 1, guard.SOLO_PAGE - 1)
    gh = select(2, paged({ short, { "stranger" } }))
    alone = guard.solo_clear(REPO, "WKDSteve", { gh = gh, now = NOW, env = {} }, tmp())
    eq(alone, true, "paging: a list one short of a page is complete (page 2 is not asked)")

    local endless = {}
    for i = 1, guard.SOLO_PAGES + 1 do
      endless[i] = owners
    end
    calls, gh = paged(endless)
    alone, detail = guard.solo_clear(REPO, "WKDSteve", { gh = gh, now = NOW, env = {} }, tmp())
    eq(alone, nil, "paging: a list beyond the cap is unknown (fail closed)")
    has(detail, "more than", "paging: ... and says so")
    eq(contributor_calls(calls), guard.SOLO_PAGES, "paging: ... after asking at most the cap")
  end

  do
    -- a repository that was never released has no entry: it is `solo` by default (decision 2026-11-24)
    eq(guard.DEFAULT_MODE, "solo", "default: a repository without an entry is solo")
    local root = tmp()
    local code, text = run_check(root, {})
    eq(code, 0, "default: no entry, the owner alone: the job runs")
    has(text, "solo", "default: ... as solo")
    eq(entry(root), nil, "default: ... and nothing is written for it")

    -- somebody else: an entry is made, as `auto`, with the reason, and it stays
    root = tmp()
    code, text = run_check(root, { pulls = { "eve" } })
    eq(code, 1, "default: no entry, another account: refused")
    has(text, "solo mode ended", "default: ... says that solo ended")
    eq(entry(root).mode, "auto", "default: ... and the repository is guarded from now on")
    has(entry(root).flipped or "", "pull request by eve", "default: ... with the reason")
    eq(run_check(root, {}), 1, "default: ... also when the account is gone")

    -- no answer from GitHub: strict for the job, no entry made (a rate limit says nothing)
    root = tmp()
    code = run_check(root, { fail = "pulls" })
    eq(code, 1, "default: no entry, no answer: refused")
    eq(entry(root), nil, "default: ... and no entry is made")

    -- releasing a commit of a repository without an entry must not turn it strict
    root = tmp()
    local o = sink()
    guard.trust_main({ "--runners=" .. root, REPO, ("c"):rep(40) }, o.sv, {
      root = root,
      gh = function()
        return ("c"):rep(40) .. "\n"
      end,
    })
    eq(entry(root).mode, "solo", "default: a release creates the entry as solo, not auto")
  end

  -- ------------------------------------------------------------------ setting and showing the mode

  do
    local root = tmp()
    local function trust(args)
      local o = sink()
      table.insert(args, "--runners=" .. root)
      local code = guard.trust_main(args, o.sv, { root = root })
      return code, joined(o)
    end
    trust({ "--mode=auto", "WKDSteve/a.nvim" })
    trust({ "--mode=always", "WKDSteve/b.nvim" })
    trust({ "--mode=off", "WKDSteve/c.nvim" })

    local code, text = trust({ "--mode=solo", "--all" })
    eq(code, 0, "trust: --mode=solo --all")
    has(text, "3 repositories", "trust: ... counts them")
    for _, r in ipairs({ "a.nvim", "b.nvim", "c.nvim" }) do
      eq(
        guard.read(guard.store_path(root))["wkdsteve/" .. r].mode,
        "solo",
        "trust: " .. r .. " is solo now"
      )
    end

    code = trust({ "--all" })
    eq(code, 2, "trust: --all without a mode is refused")
    code = trust({ "--mode=solo", "--all", "WKDSteve/a.nvim" })
    eq(code, 2, "trust: --all with a repository is refused")
    code = trust({ "--mode=sole", "WKDSteve/a.nvim" })
    eq(code, 2, "trust: an unknown mode is refused")

    -- the status lists who is alone and who lost it
    vim.fn.mkdir(root .. "/runner1", "p")
    local f = assert(io.open(root .. "/runner1/run.cmd", "wb"))
    f:write("@echo off\n")
    f:close()
    local o = sink()
    guard.main(
      { "status", "--runners=" .. root },
      o.sv,
      { root = root, nvim = "/x/nvim", script = "/x/t.lua" }
    )
    has(joined(o), "wkdsteve/a.nvim: solo", "status: a repository in solo mode is listed")

    run_check(root, { collab = { "mallory" } }, { GITHUB_REPOSITORY = "WKDSteve/a.nvim" })
    o = sink()
    guard.main(
      { "status", "--runners=" .. root },
      o.sv,
      { root = root, nvim = "/x/nvim", script = "/x/t.lua" }
    )
    has(joined(o), "solo ended", "status: ... and one that lost it, with the reason")
    local _, listing = trust({ "--list" })
    has(
      listing,
      "wkdsteve/a.nvim  mode=auto",
      "trust --list: the repository that lost it is guarded"
    )
    has(listing, "(solo ended: collaborator mallory", "trust --list: ... with the reason")
  end

  -- ------------------------------------------------------------------ accounts the owner does not count

  do
    local function ignore(root, args)
      local o = sink()
      local code = guard.main(vim.list_extend({ "solo-ignore" }, args), o.sv, { root = root })
      return code, joined(o)
    end
    local agent = { contrib = { "WKDSteve", "claude" } }

    local root = setup("solo")
    eq(run_check(root, agent), 1, "ignore: the account Claude's commits link to counts by default")
    eq(entry(root).mode, "auto", "ignore: ... and ends solo mode")

    root = setup("solo")
    local code, text = ignore(root, { "list" })
    eq(code, 0, "ignore: list on an empty list")
    has(text, "no account is ignored", "ignore: ... says so")
    code, text = ignore(root, { "add", "Claude" })
    eq(code, 0, "ignore: add")
    has(text, "claude", "ignore: ... the login is lower case")
    eq(select(2, guard.solo_ignore(root)), { "claude" }, "ignore: the list holds it")
    ignore(root, { "add", "claude" })
    eq(select(2, guard.solo_ignore(root)), { "claude" }, "ignore: adding twice keeps one line")

    eq(run_check(root, agent), 0, "ignore: with the account on the list the owner is alone")
    eq(entry(root).mode, "solo", "ignore: ... and the mode stays")

    -- a bot is not ignored by the account that is
    code, text = run_check(root, { contrib = { "WKDSteve", "claude", "dependabot[bot]" } })
    eq(code, 1, "ignore: another account still counts")
    has(text, "contributor dependabot[bot]", "ignore: ... and is named")
    lacks(text, "contributor claude", "ignore: ... without the ignored one")

    -- the ignored account is ignored in every list GitHub gives
    root = setup("solo")
    ignore(root, { "add", "claude" })
    eq(
      run_check(root, { collab = { "claude" }, pulls = { "claude" } }),
      0,
      "ignore: as collaborator and as author of a pull request too"
    )

    -- it stops counting when taken off
    code = ignore(root, { "remove", "claude" })
    eq(code, 0, "ignore: remove")
    eq(select(2, guard.solo_ignore(root)), {}, "ignore: ... the list is empty again")
    eq(run_check(root, agent), 1, "ignore: removed, the account counts again")

    -- the file is read as untrusted data
    local f = assert(io.open(root .. "/solo_ignore", "wb"))
    f:write(
      "# a comment\nclaude   # trailing\n../../x\n  Eve  \nbad name\n\n" .. ("x"):rep(300) .. "\n"
    )
    f:close()
    eq(
      select(2, guard.solo_ignore(root)),
      { "claude", "eve" },
      "ignore: comments and non-logins are skipped"
    )

    for _, bad in ipairs({
      { "add", "bad name" },
      { "add", "a/b" },
      { "add", ("x"):rep(101) },
      { "add" },
      { "list", "claude" },
      { "frobnicate", "claude" },
      {},
    }) do
      eq(select(1, ignore(root, bad)), 2, "ignore: refused " .. vim.inspect(bad))
    end
    eq(select(2, guard.solo_ignore(root)), { "claude", "eve" }, "ignore: a refusal writes nothing")

    local o = sink()
    local runner = root .. "/runner1"
    vim.fn.mkdir(runner, "p")
    local rc = assert(io.open(runner .. "/run.cmd", "wb"))
    rc:write("@echo off\n")
    rc:close()
    guard.main(
      { "status", "--runners=" .. root },
      o.sv,
      { root = root, nvim = "/x/nvim", script = "/x/t.lua" }
    )
    has(joined(o), "solo mode ignores: claude, eve", "ignore: status shows the list")
  end
end
