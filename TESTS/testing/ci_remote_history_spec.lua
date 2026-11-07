-- TESTS/testing/ci_remote_history_spec.lua -- `testing ci remote --history[=N]`: the last N push runs per repository and
-- system, a red macOS job compared with the same job on the other systems of its run (only / also / no peer), the
-- stored jobs of completed runs (asked for once), and the arguments. Fake git, fake GitHub, no network.

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local remote = require("testing.ci.remote")
  local history = require("testing.ci.remote_history")
  local cli = require("testing.cli")

  -- ------------------------------------------------------------------ pure parts

  eq(history.job_key("suite (macos-latest)"), "suite", "key: the system and `latest` are dropped")
  eq(
    history.job_key("suite (ubuntu-latest)"),
    history.job_key("Suite (Windows-2022)"),
    "key: one job on every system, case and image version aside"
  )
  eq(history.job_key("test (lua 5.1, macos-14)"), "test lua 5.1", "key: a matrix value stays")
  ok(history.job_key("lint") ~= history.job_key("suite"), "key: different jobs differ")
  eq(
    history.job_key("suite windows test"),
    history.job_key("suite ubuntu test"),
    "key: the word after the system stays (only an image version goes with it)"
  )
  eq(history.job_key("suite (macos 14)"), "suite", "key: a version after a blank goes too")

  local a = remote.parse({ "--history" })
  eq(a and a.history, history.DEFAULT, "parse: --history alone is the default")
  a = remote.parse({ "--history=5", "." })
  eq(a and a.history, 5, "parse: --history=N")
  for _, bad in ipairs({ "--history=0", "--history=101", "--history=x", "--history=2.5" }) do
    local e
    a, e = remote.parse({ bad })
    ok(
      a == nil and e:find("--history", 1, true),
      "parse: " .. bad .. " is refused (" .. tostring(e) .. ")"
    )
  end

  local function run_of(id, name, event, status, created)
    return {
      id = id,
      name = name,
      event = event,
      status = status,
      created_at = created,
      updated_at = created,
    }
  end
  local done, pending = history.select({
    run_of(1, "CI", "push", "completed", "2026-10-01T00:00:00Z"),
    run_of(2, "ci", "push", "completed", "2026-10-02T00:00:00Z"),
    run_of(3, "CI", "pull_request", "completed", "2026-10-03T00:00:00Z"),
    run_of(4, "pages", "push", "completed", "2026-10-04T00:00:00Z"),
    run_of(5, "CI", "push", "in_progress", "2026-10-05T00:00:00Z"),
    run_of(6, "CI", "push", "completed", "2026-10-06T00:00:00Z"),
  }, "CI", 3)
  eq(
    vim.tbl_map(function(r)
      return r.id
    end, done),
    { 6, 2 },
    "select: the newest push runs of the workflow only, newest first"
  )
  eq(pending, 1, "select: a run not completed is counted apart")

  local function job(id, name, conclusion)
    return { id = id, name = name, status = "completed", conclusion = conclusion, labels = {} }
  end
  local NOW = remote.epoch("2026-10-31T12:00:00Z")
  local result = history.analyze({
    {
      id = 1,
      jobs = {
        job(1, "suite (ubuntu-latest)", "success"),
        job(2, "suite (windows-latest)", "success"),
        job(3, "suite (macos-latest)", "failure"),
      },
    },
    {
      id = 2,
      jobs = {
        job(4, "suite (ubuntu-latest)", "failure"),
        job(5, "suite (windows-latest)", "success"),
        job(6, "suite (macos-latest)", "failure"),
        -- no counterpart elsewhere
        job(7, "bundle (macos-latest)", "failure"),
        -- a gate and a non-gating job decide nothing here
        job(8, "luacheck", "failure"),
        job(9, "nightly (macos-latest)", "failure"),
      },
    },
    {
      id = 3,
      jobs = {
        job(10, "suite (ubuntu-latest)", "cancelled"),
        job(11, "suite (macos-latest)", "failure"),
        job(12, "suite (windows-latest)", "skipped"),
      },
    },
  }, { "nightly" }, NOW)
  eq(
    result.systems.macos,
    { success = 0, failure = 4, cancelled = 0, skipped = 0, other = 0 },
    "analyze: counts per system (the gate and the non-gating job are not counted)"
  )
  eq(result.systems.ubuntu.cancelled, 1, "analyze: ubuntu cancelled once")
  eq(result.systems.windows.skipped, 1, "analyze: windows skipped once")
  local m = result.red.macos
  eq(m.total, 4, "red: four red macOS jobs")
  eq(m.only, 2, "red: run 1 and run 3 (a cancelled peer is not red): macOS alone")
  eq(m.also, 1, "red: run 2: ubuntu was red too")
  eq(m.no_peer, 1, "red: bundle has no job elsewhere")
  eq(m.only_runs, { 1, 3 }, "red: the runs where macOS was alone")
  eq(result.red.ubuntu.also, 1, "red: ubuntu's red in run 2 had macOS red beside it")

  -- ------------------------------------------------------------------ a fake GitHub

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-history"
  local state = tmp .. "/state"
  local dir = tmp .. "/repos/alpha"
  vim.fn.mkdir(dir .. "/.github/workflows", "p")
  local TOKEN = "ghp_SECRET_history_0123456789"
  local R = "/repos/WKDSteve/alpha"

  local function run_json(id, name, event, status, conclusion, created)
    return {
      id = id,
      name = name,
      event = event,
      status = status,
      conclusion = conclusion or vim.NIL,
      created_at = created,
      updated_at = created,
    }
  end
  local function jobs_of(list)
    local out = {}
    for i, j in ipairs(list) do
      out[i] = { id = j[3] or i, name = j[1], status = "completed", conclusion = j[2], labels = {} }
    end
    return { jobs = out }
  end
  local API = {
    [R .. "/actions/runs"] = {
      etag = '"runs"',
      body = {
        workflow_runs = {
          run_json(10, "CI", "push", "completed", "failure", "2026-10-31T10:00:00Z"),
          run_json(11, "CI", "push", "completed", "failure", "2026-10-31T11:00:00Z"),
          run_json(12, "CI", "push", "in_progress", nil, "2026-10-31T11:30:00Z"),
          run_json(13, "pages", "push", "completed", "success", "2026-10-31T11:40:00Z"),
        },
      },
    },
    [R .. "/actions/runs/10/jobs"] = {
      etag = '"j10"',
      body = jobs_of({
        { "suite (ubuntu-latest)", "success" },
        { "suite (windows-latest)", "success" },
        { "suite (macos-latest)", "failure" },
      }),
    },
    [R .. "/actions/runs/11/jobs"] = {
      etag = '"j11"',
      body = jobs_of({
        { "suite (ubuntu-latest)", "failure" },
        { "suite (windows-latest)", "success" },
        { "suite (macos-latest)", "failure" },
      }),
    },
  }
  local requests = {}
  local function transport(url, copts, done_cb)
    local path = url:gsub("^https://api%.github%.com", "")
    requests[#requests + 1] = path
    local entry = API[path]
    if not entry then
      return done_cb(true, { status = 404, status_text = "Not Found", headers = {}, body = "{}" })
    end
    local headers = { etag = entry.etag, ["x-ratelimit-remaining"] = "4999" }
    if copts.headers and copts.headers["If-None-Match"] == entry.etag then
      return done_cb(
        true,
        { status = 304, status_text = "Not Modified", headers = headers, body = "" }
      )
    end
    done_cb(
      true,
      { status = 200, status_text = "OK", headers = headers, body = vim.json.encode(entry.body) }
    )
  end
  local function git(d, args)
    local res = { code = 128, stdout = "", stderr = "no repository" }
    if d == dir and args[1] == "remote" then
      res = { code = 0, stdout = "https://github.com/WKDSteve/alpha.git\n" }
    elseif d:match("/gitlab$") and args[1] == "remote" then
      res = { code = 0, stdout = "https://gitlab.com/WKDSteve/gitlab.git\n" }
    end
    return {
      wait = function()
        return res
      end,
    }
  end
  local function run(args)
    local out, err = {}, {}
    local real = remote.deps
    remote.deps = {
      git = git,
      transport = transport,
      now = function()
        return NOW
      end,
      token = function()
        return TOKEN, "env:" .. remote.TOKEN_ENV
      end,
    }
    requests = {}
    local pass, code =
      pcall(cli.main, vim.list_extend({ "ci", "remote", "--state-dir=" .. state }, args), {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
      })
    remote.deps = real
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local first = run({ "--history=10", "--json", dir })
  eq(first.code, 0, "history: exit 0 (" .. first.err .. ")")
  local doc = vim.json.decode(first.out)
  eq(doc.schema, "testing-ci-remote-history/1", "doc: schema")
  eq(doc.n, 10, "doc: the number asked for")
  eq(doc.token_source, "env:TESTING_GITHUB_TOKEN", "doc: the source of the token")
  eq(#doc.repos, 1, "doc: one repository")
  local rec = doc.repos[1]
  eq(
    rec.runs,
    { considered = 3, completed = 2, pending = 1 },
    "rec: two completed runs and one under way"
  )
  eq(rec.systems.macos.failure, 2, "rec: macOS failed twice")
  eq(rec.red.macos.only, 1, "rec: once alone (run 10)")
  eq(rec.red.macos.also, 1, "rec: once with ubuntu (run 11)")
  eq(rec.red.macos.only_runs, { 10 }, "rec: the run where macOS was alone")
  ok(
    rec.note and rec.note:find("only 3 run(s)", 1, true),
    "rec: fewer runs than asked for is said (" .. tostring(rec.note) .. ")"
  )
  ok(not first.out:find(TOKEN, 1, true), "doc: the token is nowhere")
  eq(#requests, 3, "requests: the run list and the jobs of the two completed runs")

  local second = run({ "--history=10", "--json", dir })
  eq(second.code, 0, "again: exit 0")
  eq(#requests, 1, "again: the run list only (304), the jobs of completed runs come from the store")
  eq(vim.json.decode(second.out).repos[1].red, rec.red, "again: the same answer")

  local table_out = run({ "--history", dir })
  eq(table_out.code, 0, "table: exit 0")
  ok(table_out.out:find("MACOS RED", 1, true), "table: the header")
  ok(table_out.out:find("1 / 1 / 0", 1, true), "table: only / also / no peer of macOS")

  local bad = run({ "--history=0", dir })
  eq(bad.code, 2, "usage: a wrong number is exit 2")

  -- as `testing ci remote`: an origin that is not GitHub is a note (exit 0), git failing is an error (exit 3)
  local gitlab = tmp .. "/repos/gitlab"
  local broken = tmp .. "/repos/broken"
  vim.fn.mkdir(gitlab .. "/.github/workflows", "p")
  vim.fn.mkdir(broken .. "/.github/workflows", "p")
  local other = run({ "--history=10", "--json", gitlab })
  eq(other.code, 0, "not github: exit 0 (" .. other.err .. ")")
  local orec = vim.json.decode(other.out).repos[1]
  eq({ orec.note, orec.error }, { "origin is not on GitHub", nil }, "not github: a note, no error")
  local failed = run({ "--history=10", "--json", broken })
  eq(failed.code, 3, "git failed: exit 3")
  ok(
    tostring(vim.json.decode(failed.out).repos[1].error):find("exit 128", 1, true),
    "git failed: the error names git's exit code"
  )

  vim.fn.delete(tmp, "rf")
end
