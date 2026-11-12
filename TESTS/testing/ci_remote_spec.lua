-- TESTS/testing/ci_remote_spec.lua -- `testing ci remote`: the latest GitHub Actions run of the CI workflow per
-- repository and system, through a fake git and a fake GitHub (the transport of lib.nvim.net.github): the workflow
-- filter, a run with zero jobs, a self-hosted job without a runner, cancelled, skipped, no run, a host that is not
-- GitHub, the ETag cache, no token, and that the token never reaches an output or a file. No real network call.

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local remote = require("testing.ci.remote")
  local cli = require("testing.cli")
  local project = require("testing.config.project")

  -- ------------------------------------------------------------------ pure parts

  do
    local function origin(url)
      return { remote.parse_origin(url) }
    end
    eq(
      origin("https://github.com/WKDSteve/testing.nvim.git"),
      { "WKDSteve", "testing.nvim" },
      "origin: https"
    )
    eq(
      origin("https://github.com/WKDSteve/lib.nvim"),
      { "WKDSteve", "lib.nvim" },
      "origin: https without .git"
    )
    eq(
      origin("https://user@github.com/a-b/c_d/\n"),
      { "a-b", "c_d" },
      "origin: user, trailing slash and newline"
    )
    eq(origin("git@github.com:WKDSteve/beta.git"), { "WKDSteve", "beta" }, "origin: scp-like ssh")
    eq(
      origin("ssh://git@github.com:22/WKDSteve/gamma.nvim.git"),
      { "WKDSteve", "gamma.nvim" },
      "origin: ssh://"
    )
    eq(origin("https://gitlab.com/WKDSteve/x.git"), {}, "origin: another host is not GitHub")
    eq(origin("E:/repos/bare.git"), {}, "origin: a local path is not GitHub")
    eq(origin("https://github.com/a/b/c"), {}, "origin: a path that is not owner/repo")
    eq(origin(""), {}, "origin: empty")

    eq(remote.epoch("1970-01-02T00:00:00Z"), 86400, "epoch: one day")
    eq(remote.epoch("2000-03-01T00:00:00Z"), 951868800, "epoch: after a leap day")
    eq(remote.epoch("not a time"), nil, "epoch: garbage")

    local now = remote.epoch("2026-10-31T12:00:00Z")
    local function job(t)
      t.id = t.id or 1
      t.name = t.name or "j"
      t.labels = t.labels or {}
      return t
    end
    eq(
      remote.job_state(job({ status = "completed", conclusion = "timed_out" }), now),
      "failure",
      "job: timed out"
    )
    eq(
      remote.job_state(job({ status = "completed", conclusion = "neutral" }), now),
      "skipped",
      "job: neutral"
    )
    eq(remote.job_state(job({ status = "in_progress" }), now), "running", "job: in progress")
    eq(
      remote.job_state(
        job({ status = "queued", labels = { "ubuntu-latest" }, created_at = "2026-10-31T11:00:00Z" }),
        now
      ),
      "queued",
      "job: a hosted queued job is queued however long it waits"
    )
    eq(
      remote.job_state(job({ status = "weird" }), now),
      "unknown",
      "job: an unknown status is never green"
    )
    eq(remote.job_os(job({ name = "test (windows-latest)" })), "windows", "os: by name")
    eq(
      remote.job_os(job({ name = "build", labels = { "self-hosted", "Linux" } })),
      "ubuntu",
      "os: by label"
    )
    eq(remote.job_os(job({ name = "luacheck" })), "other", "os: none is other")
    eq(
      remote.job_os(job({ name = "stylua", labels = { "ubuntu-latest" } })),
      "other",
      "os: a hosted gate job is other, whatever image it runs on"
    )
    eq(
      remote.pick_run(
        { { id = 1, name = "ci", event = "push", created_at = "2026-10-31T11:00:00Z" } },
        "CI"
      ).id,
      1,
      "pick: the workflow name is compared without case"
    )
    local push = { id = 1, name = "CI", event = "push", created_at = "2026-10-31T11:00:00Z" }
    local pr = { id = 2, name = "CI", event = "pull_request", created_at = "2026-10-31T12:00:00Z" }
    eq(
      remote.pick_run({ push, pr }, "CI").id,
      1,
      "pick: the push run wins over a newer pull_request run"
    )
    eq(remote.pick_run({ pr }, "CI"), nil, "pick: a pull_request run alone is no run")

    -- testing ci land: the legs ran on ci/**, the later run of main skipped them; the check run stands for the commit
    local function run(id, branch, at, conclusion)
      return {
        id = id,
        name = "CI",
        event = "push",
        head_branch = branch,
        created_at = at,
        conclusion = conclusion,
        status = conclusion and "completed" or "in_progress",
      }
    end
    local check = run(10, "ci/x.nvim-abc", "2026-11-10T01:00:00Z", "success")
    eq(
      remote.pick_run({ run(11, "main", "2026-11-10T01:05:00Z", "success"), check }, "CI").id,
      10,
      "pick, land: the green check run, not main's run without legs"
    )
    eq(
      remote.pick_run({ run(11, "main", "2026-11-10T01:05:00Z", nil), check }, "CI").id,
      10,
      "pick, land: also while main's run (publish) is still going"
    )
    eq(
      remote.pick_run({ run(11, "main", "2026-11-10T01:05:00Z", "failure"), check }, "CI").id,
      11,
      "pick, land: a red run of main stays visible (a failed publish)"
    )
    eq(
      remote.pick_run({
        run(11, "main", "2026-11-10T01:05:00Z", "success"),
        run(10, "ci/x.nvim-abc", "2026-11-10T01:00:00Z", "failure"),
      }, "CI").id,
      11,
      "pick, land: a red check run never hides a later run of main"
    )
    eq(
      remote.pick_run({ run(11, "main", "2026-11-10T01:05:00Z", "success") }, "CI").id,
      11,
      "pick: without a check run, main's run as before"
    )
  end

  do
    local cfg, problems = project.validate({ ci_remote = { workflow = "Build", branch = "trunk" } })
    eq(problems, {}, "config: ci_remote is a known key")
    eq(
      cfg.ci_remote,
      { workflow = "Build", branch = "trunk", non_gating = { "nightly" } },
      "config: merged"
    )
    local _, bad = project.validate({ ci_remote = { workflow = "", branch = "-x", nope = 1 } })
    eq(
      #bad,
      3,
      "config: an empty workflow, a branch like an option and an unknown key: " .. vim.inspect(bad)
    )
  end

  -- ------------------------------------------------------------------ a fake fleet

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-remote"
  local state = tmp .. "/state"
  local NOW = remote.epoch("2026-10-31T12:00:00Z")
  local TOKEN = "ghp_SECRET_test_token_0123456789"

  local function sha(c)
    return c:rep(40)
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---dir -> { url, sha, msg }
  local GIT = {}
  local function repo(name, url, head, msg, opts)
    local dir = tmp .. "/repos/" .. name
    vim.fn.mkdir(dir, "p")
    if opts and opts.workflows then
      vim.fn.mkdir(dir .. "/.github/workflows", "p")
    end
    GIT[dir] = { url = url, sha = head, msg = msg or "a commit" }
    return dir
  end

  local function run_(id, name, status, conclusion, created, extra)
    local r = {
      id = id,
      name = name,
      status = status,
      conclusion = conclusion == nil and vim.NIL or conclusion,
      created_at = created,
      updated_at = created,
      html_url = "https://github.com/x/runs/" .. id,
      event = "push",
    }
    return vim.tbl_extend("force", r, extra or {})
  end
  local function job_(id, name, status, conclusion, extra)
    local j = {
      id = id,
      name = name,
      status = status,
      conclusion = conclusion == nil and vim.NIL or conclusion,
      html_url = "https://github.com/x/jobs/" .. id,
      labels = {},
      created_at = "2026-10-31T11:00:00Z",
    }
    return vim.tbl_extend("force", j, extra or {})
  end

  local dirs = {
    alpha = repo("alpha", "https://github.com/WKDSteve/alpha.nvim.git", sha("a")),
    beta = repo("beta", "git@github.com:WKDSteve/beta.git", sha("b")),
    gamma = repo("gamma", "ssh://git@github.com/WKDSteve/gamma.nvim", sha("c")),
    delta = repo("delta", "https://github.com/WKDSteve/delta", sha("d")),
    eps = repo("eps", "https://github.com/WKDSteve/eps", sha("e")),
    skipci = repo(
      "skipci",
      "https://github.com/WKDSteve/skipci",
      sha("f"),
      "docs: map\n\n[skip ci]\n"
    ),
    allskip = repo("allskip", "https://github.com/WKDSteve/allskip", sha("1")),
    norun = repo("norun", "https://github.com/WKDSteve/norun", sha("3")),
    norun2 = repo("norun2", "https://github.com/WKDSteve/norun2", sha("4")),
    zeta = repo("zeta", "https://gitlab.com/WKDSteve/zeta.git", sha("2")),
  }

  local R = "/repos/WKDSteve/"
  ---path -> { etag, body } (body: a table to encode or a JSON text)
  local API = {
    [R .. "alpha.nvim/actions/runs"] = {
      etag = '"runs-alpha"',
      body = {
        workflow_runs = {
          run_(10, "CI", "completed", "success", "2026-10-31T11:00:00Z"),
          -- a path-filtered sibling workflow, created later for the same push: must not be the verdict
          run_(11, "pages", "completed", "failure", "2026-10-31T11:30:00Z"),
          run_(9, "CI", "completed", "failure", "2026-10-31T10:00:00Z"),
        },
      },
    },
    [R .. "alpha.nvim/actions/runs/10/jobs"] = {
      etag = '"jobs-alpha"',
      body = {
        jobs = {
          job_(101, "test (ubuntu-latest)", "completed", "success"),
          job_(102, "test (windows-latest)", "completed", "success"),
          job_(103, "test (macos-latest)", "completed", "success"),
          job_(104, "luacheck", "completed", "success", { labels = { "ubuntu-latest" } }),
          job_(105, "nightly (ubuntu-latest)", "completed", "failure"),
        },
      },
    },
    [R .. "beta/actions/runs"] = {
      etag = '"runs-beta"',
      body = { workflow_runs = { run_(20, "CI", "completed", "failure", "2026-10-31T11:00:00Z") } },
    },
    [R .. "beta/actions/runs/20/jobs"] = {
      etag = '"jobs-beta"',
      body = '{"total_count":0,"jobs":[]}',
    },
    [R .. "gamma.nvim/actions/runs"] = {
      etag = '"runs-gamma"',
      body = { workflow_runs = { run_(30, "CI", "queued", nil, "2026-10-31T11:50:00Z") } },
    },
    [R .. "gamma.nvim/actions/runs/30/jobs"] = {
      etag = '"jobs-gamma"',
      body = {
        jobs = {
          -- ten minutes in the queue of a self-hosted runner: the runner is off
          job_(
            301,
            "build",
            "queued",
            nil,
            { labels = { "self-hosted", "Windows" }, created_at = "2026-10-31T11:50:00Z" }
          ),
          -- thirty seconds: still just queued
          job_(
            302,
            "build-linux",
            "queued",
            nil,
            { labels = { "self-hosted", "Linux" }, created_at = "2026-10-31T11:59:30Z" }
          ),
        },
      },
    },
    [R .. "delta/actions/runs"] = {
      etag = '"runs-delta"',
      body = {
        workflow_runs = { run_(40, "CI", "completed", "cancelled", "2026-10-31T11:00:00Z") },
      },
    },
    [R .. "delta/actions/runs/40/jobs"] = {
      etag = '"jobs-delta"',
      body = {
        jobs = {
          job_(401, "test (ubuntu-latest)", "completed", "cancelled"),
          job_(402, "test (windows-latest)", "completed", "success"),
        },
      },
    },
    [R .. "eps/actions/runs"] = {
      etag = '"runs-eps"',
      body = '{"total_count":0,"workflow_runs":[]}',
    },
    [R .. "skipci/actions/runs"] = {
      etag = '"runs-skipci"',
      body = {
        workflow_runs = { run_(60, "pages", "completed", "success", "2026-10-31T11:00:00Z") },
      },
    },
    [R .. "allskip/actions/runs"] = {
      etag = '"runs-allskip"',
      body = { workflow_runs = { run_(70, "CI", "completed", "skipped", "2026-10-31T11:00:00Z") } },
    },
    [R .. "allskip/actions/runs/70/jobs"] = {
      etag = '"jobs-allskip"',
      body = { jobs = { job_(701, "test (ubuntu-latest)", "completed", "skipped") } },
    },
    [R .. "norun/actions/runs"] = {
      etag = '"runs-norun"',
      body = { workflow_runs = { run_(80, "CI", "completed", "failure", "2026-10-31T11:00:00Z") } },
    },
    [R .. "norun/actions/runs/80/jobs"] = {
      etag = '"jobs-norun"',
      body = {
        jobs = {
          job_(801, "test (ubuntu-latest)", "completed", "success", {
            runner_name = "GitHub Actions 1",
            steps = { { name = "Run" } },
          }),
          job_(802, "test (macos-latest)", "completed", "cancelled", {
            runner_name = vim.NIL,
            steps = {},
          }),
        },
      },
    },
    [R .. "norun2/actions/runs"] = {
      etag = '"runs-norun2"',
      body = {
        workflow_runs = { run_(90, "CI", "completed", "cancelled", "2026-10-31T11:00:00Z") },
      },
    },
    [R .. "norun2/actions/runs/90/jobs"] = {
      etag = '"jobs-norun2"',
      body = {
        jobs = {
          -- cancelled while it ran: someone or a limit stopped real work, that is no missing runner
          job_(901, "test (macos-latest)", "completed", "cancelled", {
            runner_name = "GitHub Actions 2",
            steps = { { name = "Run" } },
          }),
          -- a runner was assigned, the steps list is still empty
          job_(902, "test (ubuntu-latest)", "completed", "cancelled", {
            runner_name = "GitHub Actions 3",
            steps = {},
          }),
          -- an empty runner name counts as none, but only together with no step
          job_(903, "test (windows-latest)", "completed", "cancelled", {
            runner_name = "",
            steps = { { name = "Run" } },
          }),
        },
      },
    },
  }

  local requests = {}
  local transport_fail = nil
  local function transport(url, copts, done)
    local path = url:gsub("^https://api%.github%.com", "")
    requests[#requests + 1] = {
      path = path,
      url = url,
      query = copts.query,
      etag = copts.headers and copts.headers["If-None-Match"],
      token = copts.bearer_token,
    }
    if transport_fail then
      return done(false, transport_fail)
    end
    local entry = API[path]
    if not entry then
      return done(
        true,
        { status = 404, status_text = "Not Found", headers = {}, body = '{"message":"Not Found"}' }
      )
    end
    local headers = { etag = entry.etag, ["x-ratelimit-remaining"] = "4999" }
    if copts.headers and copts.headers["If-None-Match"] == entry.etag then
      return done(
        true,
        { status = 304, status_text = "Not Modified", headers = headers, body = "" }
      )
    end
    local body = type(entry.body) == "string" and entry.body or vim.json.encode(entry.body)
    done(true, { status = 200, status_text = "OK", headers = headers, body = body })
  end

  local function git(dir, args)
    local g = GIT[dir]
    local res
    if not g then
      res = { code = 128, stdout = "", stderr = "not a git repository" }
    elseif args[1] == "remote" and g.fail then
      res = g.fail
    elseif args[1] == "remote" then
      res = g.url and { code = 0, stdout = g.url .. "\n" }
        or { code = 2, stdout = "", stderr = "no such remote" }
    elseif args[1] == "log" then
      eq(
        args[#args - 1],
        "origin/" .. (g.branch or "main"),
        "git: the head of origin/<branch> is asked for"
      )
      res = { code = 0, stdout = g.sha .. "\n" .. g.msg }
      if vim.tbl_contains(args, "--format=%ct") then
        res = { code = 0, stdout = tostring(g.ts or 0) .. "\n" }
      end
      -- `log.showSignature=true` in the user's config: gpg's lines come first unless switched off
      if g.signed and not vim.tbl_contains(args, "--no-show-signature") then
        res.stdout = "gpg: Signature made Sat Oct 31 2026\ngpg: Good signature\n" .. res.stdout
      end
    end
    return {
      wait = function()
        return res
      end,
    }
  end

  local function run(args, opts)
    opts = opts or {}
    local out, err = {}, {}
    local real = remote.deps
    remote.deps = {
      git = git,
      transport = opts.transport or transport,
      now = opts.now or function()
        return NOW
      end,
      sleep = opts.sleep or function()
        error("a sleep without --wait")
      end,
      token = opts.token or function()
        return TOKEN, "env:" .. remote.TOKEN_ENV
      end,
    }
    requests = {}
    local pass, code = pcall(cli.main, vim.list_extend({ "ci", "remote" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
    })
    remote.deps = real
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n"), lines = out }
  end

  local function by_repo(doc)
    local t = {}
    for _, r in ipairs(doc.repos) do
      t[r.repo] = r
    end
    return t
  end

  local all = {}
  for _, name in ipairs({ "zeta", "alpha", "beta", "gamma", "delta", "eps", "skipci", "allskip" }) do
    all[#all + 1] = dirs[name]
  end

  -- ------------------------------------------------------------------ the first fetch

  local first = run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
  eq(
    first.code,
    remote.EXIT_RED,
    "exit: a rejected and a cancelled repository are red (" .. first.err .. ")"
  )
  local doc = vim.json.decode(first.out)
  eq(doc.schema, "testing-ci-remote/1", "doc: schema")
  eq(doc.generated_at, "2026-10-31T12:00:00Z", "doc: generated_at")
  eq(
    doc.token_source,
    "env:TESTING_GITHUB_TOKEN",
    "doc: where the token came from (never the token)"
  )
  local names = vim.tbl_map(function(r)
    return r.repo
  end, doc.repos)
  eq(
    names,
    { "allskip", "alpha.nvim", "beta", "delta", "eps", "gamma.nvim", "skipci", "zeta" },
    "doc: sorted by name"
  )
  local rec = by_repo(doc)

  local a = rec["alpha.nvim"]
  eq(
    { a.owner, a.sha, a.branch, a.workflow },
    { "WKDSteve", sha("a"), "main", "CI" },
    "alpha: owner, sha, branch, workflow"
  )
  eq(a.run.id, 10, "alpha: the newest CI run, not the later pages run nor the older CI run")
  eq(a.overall, "success", "alpha: green")
  eq(
    a.os.ubuntu,
    { state = "success", url = "https://github.com/x/jobs/101", job = "test (ubuntu-latest)" },
    "alpha: ubuntu cell"
  )
  eq(
    { a.os.windows.state, a.os.macos.state, a.os.other.state },
    { "success", "success", "success" },
    "alpha: cells"
  )
  eq(a.non_gating, {
    { name = "nightly (ubuntu-latest)", state = "failure", url = "https://github.com/x/jobs/105" },
  }, "alpha: nightly listed apart")
  has(a.note, "non-gating red: nightly", "alpha: ... and noted, without turning the repository red")

  eq(
    rec.beta.overall,
    "rejected",
    "beta: a completed run with zero jobs is a rejected workflow, not a pass"
  )
  has(rec.beta.note, "0 jobs", "beta: ... said so")
  eq(rec["gamma.nvim"].overall, "waiting_runner", "gamma: a self-hosted job queued for ten minutes")
  eq(rec["gamma.nvim"].os.windows.state, "waiting_runner", "gamma: ... in the windows cell")
  eq(
    rec["gamma.nvim"].os.ubuntu.state,
    "queued",
    "gamma: thirty seconds in the queue is just queued"
  )
  eq(rec.delta.overall, "cancelled", "delta: cancelled")
  eq(rec.eps.overall, "no_run", "eps: no run for the commit")
  has(rec.eps.note, "eeeeeee", "eps: ... names the commit")
  eq(
    rec.skipci.overall,
    "skipped",
    "skipci: a [skip ci] head without a CI run (the pages run does not count)"
  )
  eq(rec.allskip.overall, "skipped", "allskip: every job skipped")
  eq(rec.zeta.overall, "no_github", "zeta: a GitLab origin")
  eq(rec.zeta.owner, nil, "zeta: no owner")
  for _, r in ipairs(requests) do
    eq(r.token, TOKEN, "request: the token goes to curl's options")
    lacks(r.url, TOKEN, "request: never into the URL")
    ok(
      not r.path:find("zeta", 1, true),
      "request: nothing is asked about a repository that is not on GitHub"
    )
  end
  local runs_q = vim.tbl_filter(function(r)
    return r.path == R .. "alpha.nvim/actions/runs"
  end, requests)
  eq(
    runs_q[1].query,
    { head_sha = sha("a"), per_page = "20" },
    "request: the runs of the head commit, not of the branch"
  )
  eq(runs_q[1].etag, nil, "request: nothing stored yet, no If-None-Match")
  lacks(first.out, TOKEN, "the token is not in the output")
  lacks(first.err, TOKEN, "the token is not in the errors")

  -- ------------------------------------------------------------------ the cache: 304 and unchanged jobs

  local second = run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
  eq(
    second.out,
    first.out,
    "deterministic: the same answers give the same bytes (the second from the cache)"
  )
  local asked = {}
  for _, r in ipairs(requests) do
    asked[r.path] = r.etag or "none"
  end
  eq(
    asked[R .. "alpha.nvim/actions/runs"],
    '"runs-alpha"',
    "cache: the runs are asked with If-None-Match"
  )
  eq(
    asked[R .. "alpha.nvim/actions/runs/10/jobs"],
    nil,
    "cache: the jobs of an unchanged completed run are not asked"
  )
  eq(
    asked[R .. "gamma.nvim/actions/runs/30/jobs"],
    '"jobs-gamma"',
    "cache: the jobs of an open run are asked again, conditionally"
  )
  for _, f in ipairs(vim.fn.glob(state .. "/testing/ci-remote/*.json", true, true)) do
    local fh = assert(io.open(f, "rb"))
    local text = fh:read("*a")
    fh:close()
    lacks(text, TOKEN, "cache: the token is in no cache file (" .. f .. ")")
  end
  eq(
    #vim.fn.glob(state .. "/testing/ci-remote/*.json", true, true),
    7,
    "cache: one file per GitHub repository"
  )
  -- a runs list stored before runs carried their branch (no version) is asked anew once, then cached again
  do
    for _, f in ipairs(vim.fn.glob(state .. "/testing/ci-remote/*.json", true, true)) do
      local fh = assert(io.open(f, "rb"))
      local stored = vim.json.decode(fh:read("*a"))
      fh:close()
      if type(stored.runs) == "table" then
        stored.runs.v = nil
      end
      fh = assert(io.open(f, "wb"))
      fh:write(vim.json.encode(stored))
      fh:close()
    end
    run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
    local unversioned = {}
    for _, r in ipairs(requests) do
      if r.path == R .. "alpha.nvim/actions/runs" then
        unversioned[#unversioned + 1] = r.etag or "none"
      end
    end
    eq(unversioned, { "none" }, "cache: an unversioned runs list is asked without If-None-Match")
    run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
    local again
    for _, r in ipairs(requests) do
      if r.path == R .. "alpha.nvim/actions/runs" then
        again = r.etag
      end
    end
    eq(
      again,
      '"runs-alpha"',
      "cache: ... and the list stored then is versioned (conditional again)"
    )
  end

  -- a new run (a re-run: updated_at moved) fetches the jobs again
  API[R .. "alpha.nvim/actions/runs"].etag = '"runs-alpha-2"'
  API[R .. "alpha.nvim/actions/runs"].body.workflow_runs[1].updated_at = "2026-10-31T11:45:00Z"
  API[R .. "alpha.nvim/actions/runs/10/jobs"].body.jobs[2].conclusion = "failure"
  API[R .. "alpha.nvim/actions/runs/10/jobs"].etag = '"jobs-alpha-2"'
  local third = run({ "--json", dirs.alpha })
  asked = {}
  for _, r in ipairs(requests) do
    asked[r.path] = r.etag or "none"
  end
  eq(
    asked[R .. "alpha.nvim/actions/runs/10/jobs"],
    '"jobs-alpha"',
    "cache: a changed run asks for its jobs again"
  )
  eq(third.code, remote.EXIT_RED, "a red windows leg is exit 1")
  eq(vim.json.decode(third.out).repos[1].os.windows.state, "failure", "... in the windows cell")

  -- ------------------------------------------------------------------ a job that never got a runner

  local norun = run({ "--json", dirs.norun })
  eq(norun.code, remote.EXIT_RED, "no_runner: red, the run on GitHub is too")
  local nr = vim.json.decode(norun.out).repos[1]
  eq(nr.overall, "no_runner", "no_runner: the repository says so, not `cancelled`")
  eq(
    { nr.os.macos.state, nr.os.ubuntu.state },
    { "no_runner", "success" },
    "no_runner: only the job without a runner"
  )
  has(nr.note, "not started, no test ran (macos)", "no_runner: the note says what it means")
  -- the owner is redacted where the user of the machine has its name, so only around it
  has(nr.note, "gh run rerun 80 -R ", "no_runner: ... and what to try")
  has(nr.note, "/norun --failed", "no_runner: ... from anywhere")
  has(
    run({ dirs.norun }).out,
    "not-started",
    "no_runner: in the table, not the word of waiting_runner"
  )
  do
    local rec_ = { owner = "o", repo = "r" }
    local jobs_ = {}
    for i, name in ipairs({ "test (macos-latest)", "lint", "publish" }) do
      jobs_[i] = {
        id = i,
        name = name,
        status = "completed",
        conclusion = "cancelled",
        no_runner = true,
        labels = {},
      }
    end
    remote.classify(rec_, { id = 7, status = "completed", conclusion = "cancelled" }, jobs_, {}, 0)
    eq(
      select(2, rec_.note:gsub("gh run rerun", "")),
      1,
      "no_runner: one hint for a run, however many jobs: " .. rec_.note
    )
    has(rec_.note, "(other, macos)", "no_runner: ... naming each system once")
  end

  local nr2 = vim.json.decode(run({ "--json", dirs.norun2 }).out).repos[1]
  eq(
    { nr2.overall, nr2.os.macos.state, nr2.os.ubuntu.state, nr2.os.windows.state },
    { "cancelled", "cancelled", "cancelled", "cancelled" },
    "no_runner: a runner or a step means it was cancelled, not left without one"
  )
  eq((nr2.note or ""):find("rerun", 1, true), nil, "no_runner: and no such hint")
  eq(
    remote.job_state({ status = "completed", conclusion = "cancelled", labels = {} }, 0),
    "cancelled",
    "no_runner: a job from an old cache, without the fields, stays what it was"
  )

  -- ------------------------------------------------------------------ a repository without a macOS job

  do
    local now = 1800000000
    local run_rec = run_(77, "CI", "completed", "success", "2026-10-31T11:00:00Z")
    local nomac = { dir = "/x/nomac", repo = "nomac", owner = "o" }
    remote.classify(nomac, run_rec, {
      job_(771, "testing ci (windows)", "completed", "success", {
        labels = { "self-hosted", "windows" },
      }),
    }, {}, now)
    eq(nomac.overall, "success", "no macOS job: the jobs that exist decide")
    eq(nomac.os.macos, nil, "no macOS job: no cell in the document, so no state at all")
    local shown = remote.render({ nomac })
    ok(
      shown[2]:match("^nomac%s+%-%s+ok%s+%-") ~= nil,
      "no macOS job: the cell is `-`, never `ok`: " .. shown[2]
    )
    eq(
      shown[#shown],
      "fully green: 1 / 1 (no macos job: 1)",
      "no macOS job: the summary says so, it counts the jobs that exist"
    )

    -- the two-runner workflow: the hosted macOS leg gets its own cell, and red there is red
    local two = { dir = "/x/two", repo = "two", owner = "o" }
    remote.classify(two, run_rec, {
      job_(781, "testing ci (windows)", "completed", "success", {
        labels = { "self-hosted", "windows" },
      }),
      job_(782, "testing ci (macos)", "completed", "failure", { labels = { "macos-latest" } }),
    }, {}, now)
    eq(two.os.macos.state, "failure", "two runners: the hosted leg is the macOS cell")
    eq(two.os.windows.state, "success", "two runners: the local leg is the windows cell")
    eq(two.overall, "failure", "two runners: red only on macOS is red")
    local two_shown = remote.render({ two })
    eq(two_shown[#two_shown], "fully green: 0 / 1", "two runners: no addition with a macOS job")
    local no_run = { dir = "/x/none", repo = "none", owner = "o", overall = "no_run" }
    local none_shown = remote.render({ no_run })
    eq(none_shown[#none_shown], "fully green: 0 / 1", "no run at all says nothing about macOS")

    -- queued on a hosted runner is not "the local runner is off"
    local q = { dir = "/x/q", repo = "q", owner = "o" }
    remote.classify(q, run_(79, "CI", "queued", nil, "2026-10-31T11:00:00Z"), {
      job_(791, "testing ci (macos)", "queued", nil, {
        labels = { "macos-latest" },
        created_at = "2020-01-01T00:00:00Z",
      }),
    }, {}, now)
    eq(q.os.macos.state, "queued", "two runners: a hosted leg never waits for the local runner")

    -- a macOS run by hand on a private repository is no verdict about the commit: it cannot hide a red push
    local dispatched = remote.pick_run({
      run_(90, "CI", "completed", "failure", "2026-10-31T10:00:00Z"),
      vim.tbl_extend("force", run_(91, "CI", "completed", "success", "2026-10-31T12:00:00Z"), {
        event = "workflow_dispatch",
      }),
    }, "CI")
    eq(dispatched.id, 90, "workflow_dispatch: the newer run by hand does not replace the push run")
  end

  -- ------------------------------------------------------------------ the human table

  local tbl = run({ dirs.eps, dirs.zeta, dirs.allskip })
  eq(tbl.code, remote.EXIT_OK, "exit: no run, not GitHub and skipped are not red")
  has(tbl.lines[1], "REPO", "table: header")
  has(tbl.lines[1], "UBUNTU", "table: header names the systems")
  local row
  for _, l in ipairs(tbl.lines) do
    if l:match("^eps ") then
      row = l
    end
  end
  has(row, "no_run", "table: the eps row says no_run")
  has(tbl.out, "fully green: 0 / 3", "table: the summary line")
  local renamed = run({ dirs.alpha })
  ok(
    renamed.lines[2]:match("^alpha %(alpha%.nvim%) ") ~= nil,
    "table: a checkout named otherwise shows both names"
  )

  -- ------------------------------------------------------------------ no token, no network

  local none = run({ "--json", dirs.alpha, dirs.zeta }, {
    token = function()
      return nil, "$TESTING_GITHUB_TOKEN is not set; `gh auth token` failed (exit 1)"
    end,
  })
  eq(none.code, remote.EXIT_INFRA, "no token: exit 3")
  eq(#requests, 0, "no token: nothing is asked")
  local nd = by_repo(vim.json.decode(none.out))
  eq(nd["alpha.nvim"].overall, "unknown", "no token: unknown, never green")
  has(nd["alpha.nvim"].error, "no GitHub token", "no token: ... said so")
  eq(nd.zeta.overall, "no_github", "no token: a repository that needs none is still reported")
  has(none.err, "TESTING_GITHUB_TOKEN", "no token: the error names the variable to set")

  transport_fail = "curl: (6) Could not resolve host: api.github.com"
  local offline = run({ "--json", dirs.delta })
  transport_fail = nil
  eq(offline.code, remote.EXIT_INFRA, "offline: exit 3")
  local od = vim.json.decode(offline.out).repos[1]
  eq(od.overall, "unknown", "offline: unknown, never the cached state")
  has(od.error, "Could not resolve host", "offline: the error is kept")

  -- an API error (a 404 for a repository the token cannot see)
  local hidden = repo("hidden", "https://github.com/WKDSteve/hidden", sha("3"))
  local h = run({ "--json", hidden })
  eq(h.code, remote.EXIT_INFRA, "404: exit 3")
  has(vim.json.decode(h.out).repos[1].error, "404", "404: the status is in the error")

  -- an error text that quotes the token (a proxy echoing the request): cut out all the same
  transport_fail = "proxy said: Authorization: Bearer " .. TOKEN .. " refused"
  local echo = run({ "--json", dirs.delta })
  transport_fail = nil
  lacks(echo.out, TOKEN, "redaction: the token is not in the document")
  has(vim.json.decode(echo.out).repos[1].error, "Bearer ***", "redaction: ... it reads ***")

  -- free texts of the GitHub answer (a job name, a non-gating job, a note) are redacted in the document
  do
    local recs = {
      {
        dir = "/work/repo",
        repo = "x/y",
        overall = "success",
        note = "see " .. TOKEN,
        os = { ubuntu = { state = "success", job = "test " .. TOKEN .. " (ubuntu)" } },
        non_gating = { { name = "lint " .. TOKEN, state = "success" } },
      },
    }
    local d = remote.document(recs, { token = TOKEN }, {})
    local text = vim.json.encode(d)
    lacks(text, TOKEN, "document: the token is in no free text")
    has(d.repos[1].os.ubuntu.job, "<TOKEN>", "document: a job name reads <TOKEN>")
    has(d.repos[1].non_gating[1].name, "<TOKEN>", "document: a non-gating job name reads <TOKEN>")
    has(d.repos[1].note, "<TOKEN>", "document: a note reads <TOKEN>")
    has(recs[1].os.ubuntu.job, TOKEN, "document: the records themselves are not changed")
  end

  -- lib.nvim.net.github throwing (an older one, curl missing): unknown and exit 3, no crash
  do
    local github = require("lib.nvim.net.github")
    local real_request = github.request
    github.request = function()
      error("ENOENT: no such file or directory (cmd): 'curl'", 0)
    end
    local pass, thrown = pcall(run, { "--json", dirs.delta, dirs.eps })
    github.request = real_request
    ok(pass, "throwing request: the command does not crash: " .. tostring(thrown))
    eq(thrown.code, remote.EXIT_INFRA, "throwing request: exit 3")
    for _, r in ipairs(vim.json.decode(thrown.out).repos) do
      eq(r.overall, "unknown", "throwing request: unknown (" .. r.repo .. ")")
      has(r.error, "ENOENT", "throwing request: ... with the error (" .. r.repo .. ")")
    end
  end

  -- git failing (dubious ownership, not a repository: exit 128) is no "no origin": unknown, exit 3
  local dubious = repo("dubious", "https://github.com/WKDSteve/dubious", sha("5"))
  GIT[dubious].fail = {
    code = 128,
    stdout = "",
    stderr = "fatal: detected dubious ownership in repository\n",
  }
  local dub = run({ "--json", dubious })
  eq(dub.code, remote.EXIT_INFRA, "git failed: exit 3, not 0")
  local dr = vim.json.decode(dub.out).repos[1]
  eq(dr.overall, "unknown", "git failed: unknown, not no_github")
  has(dr.error, "dubious ownership", "git failed: git's message is kept")
  has(dr.error, "exit 128", "git failed: ... with its exit code")
  local noorigin = repo("noorigin", nil, sha("6"))
  eq(
    vim.json.decode(run({ "--json", noorigin }).out).repos[1].overall,
    "no_github",
    "git: no origin remote (exit 2) is still no_github"
  )

  -- log.showSignature in the user's config: the hash is still found
  local signed = repo("signed", "https://github.com/WKDSteve/eps", sha("e"))
  GIT[signed].signed = true
  local sg = vim.json.decode(run({ "--json", signed }).out).repos[1]
  eq({ sg.sha, sg.overall }, { sha("e"), "no_run" }, "signed: the commit is read past gpg's lines")

  -- a run with zero jobs: rejected only when it failed; cancelled in the queue is cancelled
  do
    local function zero(conclusion)
      local r = {}
      remote.classify(r, {
        id = 1,
        status = "completed",
        conclusion = conclusion,
      }, {}, {}, NOW)
      return r
    end
    eq(zero("failure").overall, "rejected", "0 jobs: failure is a rejected workflow")
    eq(zero("startup_failure").overall, "rejected", "0 jobs: startup_failure too")
    eq(zero(nil).overall, "rejected", "0 jobs: no conclusion too")
    local cq = zero("cancelled")
    eq(cq.overall, "cancelled", "0 jobs: cancelled while queued is cancelled, not rejected")
    lacks(cq.note, "REJECTED", "0 jobs: ... and not called rejected")
    local ar = zero("action_required")
    eq(ar.overall, "unknown", "0 jobs: action_required is no verdict")
    has(ar.note, "action_required", "0 jobs: ... said so")
    eq(zero("skipped").overall, "skipped", "0 jobs: skipped stays skipped")

    -- only non-gating jobs: no verdict, and a note that says why
    local ng = {}
    remote.classify(ng, { id = 2, status = "completed", conclusion = "success" }, {
      { id = 1, name = "nightly (ubuntu-latest)", status = "completed", conclusion = "success" },
    }, { "nightly" }, NOW)
    eq(ng.overall, "unknown", "non-gating only: unknown")
    has(ng.note, "only non-gating jobs", "non-gating only: ... with the reason")
  end

  -- jobs answered 200 without an ETag: the stored ETag of the old list is not kept with the new one
  do
    local theta = repo("theta", "https://github.com/WKDSteve/theta", sha("7"))
    API[R .. "theta/actions/runs"] = {
      etag = '"runs-theta"',
      body = { workflow_runs = { run_(90, "CI", "in_progress", nil, "2026-10-31T11:55:00Z") } },
    }
    local jobs_theta = {
      etag = '"jobs-theta-1"',
      body = { jobs = { job_(901, "test (ubuntu-latest)", "in_progress", nil) } },
    }
    API[R .. "theta/actions/runs/90/jobs"] = jobs_theta
    run({ "--json", theta })
    jobs_theta.etag = nil
    jobs_theta.body.jobs[1].status = "completed"
    jobs_theta.body.jobs[1].conclusion = "failure"
    run({ "--json", theta })
    local again = run({ "--json", theta })
    local jobs_q = vim.tbl_filter(function(r)
      return r.path == R .. "theta/actions/runs/90/jobs"
    end, requests)
    eq(jobs_q[1].etag, nil, "jobs etag: no If-None-Match with the old ETag for the new list")
    eq(vim.json.decode(again.out).repos[1].overall, "failure", "jobs etag: ... the new list counts")
  end

  -- two checkouts of one GitHub repository are one row: the CI is asked once, for the checkout whose origin commit
  -- is newer; the other is named in the note (a stale second clone must not show an old state)
  do
    local one = repo("twin-one", "https://github.com/WKDSteve/twin", sha("8"))
    local two = repo("twin-two", "https://github.com/WKDSteve/twin", sha("9"))
    GIT[one].ts, GIT[two].ts = 100, 200
    API[R .. "twin/actions/runs"] = { etag = '"runs-twin"', body = '{"workflow_runs":[]}' }
    local rows = vim.json.decode(run({ "--json", one, two }).out).repos
    eq(#rows, 1, "twins: one row for one repository")
    eq(rows[1].sha, sha("9"), "twins: the checkout with the newer origin commit wins")
    has(rows[1].note, "further clone: twin-one", "twins: the other checkout is named")
    local twin_asked = 0
    for i = 1, #requests do
      if requests[i].path == R .. "twin/actions/runs" then
        twin_asked = twin_asked + 1
      end
    end
    eq(twin_asked, 1, "twins: the CI is asked once")
    -- the order on the command line does not decide
    GIT[one].ts, GIT[two].ts = 300, 200
    local flipped = vim.json.decode(run({ "--json", two, one }).out).repos
    eq(flipped[1].sha, sha("8"), "twins: the newer commit wins whatever the order")
  end

  -- past the deadline: a late answer changes nothing, starts nothing, writes nothing
  do
    local late_a = repo("late-a", "https://github.com/WKDSteve/late-a", sha("a"))
    local late_b = repo("late-b", "https://github.com/WKDSteve/late-b", sha("b"))
    API[R .. "late-a/actions/runs"] = { etag = '"runs-late"', body = '{"workflow_runs":[]}' }
    API[R .. "late-b/actions/runs"] = { etag = '"runs-late"', body = '{"workflow_runs":[]}' }
    local real_deadline, real_parallel = remote.DEADLINE_MS, remote.PARALLEL
    remote.DEADLINE_MS, remote.PARALLEL = 50, 1
    local slow_state = tmp .. "/slow-state"
    -- the answers are held until the command has returned, then given: late by construction, not by timing
    local held, seen_paths = {}, {}
    local function slow(url, copts, done)
      seen_paths[#seen_paths + 1] = url
      held[#held + 1] = function()
        transport(url, copts, done)
      end
    end
    local pass, late = pcall(run, { "--json", "--state-dir", slow_state, late_a, late_b }, {
      transport = slow,
    })
    remote.DEADLINE_MS, remote.PARALLEL = real_deadline, real_parallel
    ok(pass, "deadline: runs: " .. tostring(late))
    eq(late.code, remote.EXIT_INFRA, "deadline: exit 3")
    -- the fake stays in place while the late answers arrive: a request they start must not reach the network
    local real_deps = remote.deps
    remote.deps = vim.tbl_extend("force", real_deps, { transport = slow })
    for _, give in ipairs(held) do
      give()
    end
    vim.wait(100)
    remote.deps = real_deps
    eq(#seen_paths, 1, "deadline: no request is started after it: " .. vim.inspect(seen_paths))
    eq(
      #vim.fn.glob(slow_state .. "/testing/ci-remote/*.json", true, true),
      0,
      "deadline: a late answer writes no cache"
    )
  end

  -- ------------------------------------------------------------------ configuration and --workflow

  local cfgd = repo("cfgd", "https://github.com/WKDSteve/cfgd", sha("4"))
  write(
    cfgd .. "/.testing.lua",
    'return { ci_remote = { workflow = "Build", non_gating = { "Lib Suite" } } }\n'
  )
  API[R .. "cfgd/actions/runs"] = {
    etag = '"runs-cfgd"',
    body = {
      workflow_runs = {
        run_(80, "CI", "completed", "failure", "2026-10-31T11:00:00Z"),
        run_(81, "Build", "completed", "success", "2026-10-31T10:00:00Z"),
      },
    },
  }
  API[R .. "cfgd/actions/runs/81/jobs"] = {
    etag = '"jobs-cfgd"',
    body = {
      jobs = {
        job_(811, "test (ubuntu-latest)", "completed", "success"),
        job_(812, "lib suite via testing.nvim (ubuntu-latest)", "completed", "failure"),
      },
    },
  }
  API[R .. "cfgd/actions/runs/80/jobs"] = {
    etag = '"jobs-cfgd-80"',
    body = { jobs = { job_(801, "test (ubuntu-latest)", "completed", "failure") } },
  }
  local c = run({ "--json", cfgd })
  local cr = vim.json.decode(c.out).repos[1]
  eq(
    { cr.workflow, cr.run.id, cr.overall },
    { "Build", 81, "success" },
    "config: the workflow of .testing.lua"
  )
  eq(cr.os.ubuntu.job, "test (ubuntu-latest)", "config: a non-gating job is not in the OS cell")
  eq(c.code, remote.EXIT_OK, "config: exit 0")
  local w = run({ "--json", "--workflow", "CI", cfgd })
  eq(vim.json.decode(w.out).repos[1].run.id, 80, "--workflow wins over the configuration")
  eq(w.code, remote.EXIT_RED, "--workflow: ... and that run is red")

  -- ------------------------------------------------------------------ --repos-root

  local root = tmp .. "/fleet"
  local function fleet(name, url, workflows)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    if workflows then
      vim.fn.mkdir(dir .. "/.github/workflows", "p")
    end
    GIT[dir] = { url = url, sha = sha("e"), msg = "x" }
  end
  fleet("eps", "https://github.com/WKDSteve/eps", true)
  fleet("tasks-vault", "https://github.com/WKDSteve/tasks-vault", true)
  fleet("noflows", "https://github.com/WKDSteve/noflows", false)
  fleet("elsewhere", "https://gitlab.com/WKDSteve/elsewhere", true)
  local f = run({ "--json", "--repos-root", root })
  local fr = vim.json.decode(f.out).repos
  eq(
    vim.tbl_map(function(r)
      return r.repo
    end, fr),
    { "eps" },
    "--repos-root: GitHub repositories with workflows, no vault, no other host (and not `testing ci --repos-root`)"
  )
  -- one git cannot read stays in the table as unknown, never silently out of "fully green: n / n"
  fleet("broken", "https://github.com/WKDSteve/broken", true)
  GIT[root .. "/broken"].fail = { code = 128, stdout = "", stderr = "fatal: not a git repository" }
  local fb = run({ "--repos-root", root })
  eq(fb.code, remote.EXIT_INFRA, "--repos-root: a repository git cannot read is exit 3")
  has(fb.out, "broken", "--repos-root: ... and has its row")
  has(fb.out, "fully green: 0 / 2", "--repos-root: ... and counts")

  -- ------------------------------------------------------------------ --wait

  do
    local waity = repo("waity", "https://github.com/WKDSteve/waity", sha("7"))
    local runs_path, jobs_path = R .. "waity/actions/runs", R .. "waity/actions/runs/77/jobs"
    -- the run of the head commit, round by round: queued without jobs, running, running (unchanged: a 304), done
    local phases = {
      { status = "queued", jobs = {} },
      { status = "in_progress", jobs = { job_(771, "test (ubuntu-latest)", "in_progress", nil) } },
      { status = "in_progress", jobs = { job_(771, "test (ubuntu-latest)", "in_progress", nil) } },
      {
        status = "completed",
        conclusion = "success",
        jobs = { job_(771, "test (ubuntu-latest)", "completed", "success") },
      },
    }
    local function show(i)
      local ph = phases[i]
      -- an unchanged answer keeps its ETag: the fake GitHub then says 304
      local tag = (i == 3) and 2 or i
      API[runs_path] = {
        etag = '"runs-waity-' .. tag .. '"',
        body = {
          workflow_runs = {
            run_(77, "CI", ph.status, ph.conclusion, "2026-10-31T11:59:00Z", {
              updated_at = "2026-10-31T12:0" .. tag .. ":00Z",
            }),
          },
        },
      }
      API[jobs_path] = { etag = '"jobs-waity-' .. tag .. '"', body = { jobs = ph.jobs } }
    end
    local clock, phase, sleeps = NOW, 1, {}
    show(1)
    local res = run({ "--wait", "--state-dir", tmp .. "/wait-state", waity }, {
      now = function()
        return clock
      end,
      sleep = function(s)
        sleeps[#sleeps + 1] = s
        clock = clock + s
        phase = phase + 1
        show(phase)
      end,
    })
    eq(res.code, remote.EXIT_OK, "--wait: exit 0 once the run is green: " .. res.err)
    eq(sleeps, { 30, 30, 30 }, "--wait: three pauses of WAIT_POLL_S, then done")
    has(res.out, "fully green: 1 / 1", "--wait: the table of the finished run")
    has(res.err, "waity (queued)", "--wait: says what it waits for")
    has(res.err, "waity (running)", "--wait: ... and when that changes")
    local _, n_running = res.err:gsub("waity %(running%)", "")
    eq(n_running, 1, "--wait: an unchanged state is said once")
    local conditional, not_modified = 0, 0
    for _, r in ipairs(requests) do
      if r.path == runs_path and r.etag then
        conditional = conditional + 1
        if r.etag == '"runs-waity-2"' then
          not_modified = not_modified + 1
        end
      end
    end
    eq(conditional, 3, "--wait: every later round asks with the stored ETag")
    ok(not_modified >= 1, "--wait: ... and an unchanged run is a 304")

    -- past the limit: the table, `not finished`, exit 1
    clock, phase, sleeps = NOW, 1, {}
    show(1)
    local stuck = run({ "--wait=75s", "--state-dir", tmp .. "/wait-state2", waity }, {
      now = function()
        return clock
      end,
      sleep = function(s)
        sleeps[#sleeps + 1] = s
        clock = clock + s
      end,
    })
    eq(stuck.code, remote.EXIT_RED, "--wait=75s: still queued past the limit is exit 1")
    eq(sleeps, { 30, 30, 15 }, "--wait=75s: the last pause ends at the limit")
    has(stuck.err, "not finished after 1m15s: waity (queued)", "--wait: names what is not finished")
    has(stuck.out, "REPO", "--wait: ... after the table")

    -- a commit without a run: a fresh push's run may not be there yet, so it is waited for WAIT_NO_RUN_S, not longer
    clock, sleeps = NOW, {}
    local no_run_wait = run({ "--wait=1h", "--state-dir", tmp .. "/wait-state3", dirs.eps }, {
      now = function()
        return clock
      end,
      sleep = function(s)
        sleeps[#sleeps + 1] = s
        clock = clock + s
      end,
    })
    eq(
      #sleeps,
      remote.WAIT_NO_RUN_S / remote.WAIT_POLL_S,
      "--wait: no run is waited for WAIT_NO_RUN_S"
    )
    eq(no_run_wait.code, run({ dirs.eps }).code, "--wait: ... then the exit code of no_run")

    -- nothing going: no pause at all
    local fin = repo("fin", "https://github.com/WKDSteve/fin", sha("8"))
    API[R .. "fin/actions/runs"] = {
      etag = '"runs-fin"',
      body = { workflow_runs = { run_(88, "CI", "completed", "success", "2026-10-31T11:00:00Z") } },
    }
    API[R .. "fin/actions/runs/88/jobs"] = {
      etag = '"jobs-fin"',
      body = { jobs = { job_(881, "test (ubuntu-latest)", "completed", "success") } },
    }
    local done_now = run({ "--wait", "--state-dir", tmp .. "/wait-state4", fin })
    eq(done_now.code, remote.EXIT_OK, "--wait: a finished run needs no wait (and no sleep)")

    eq(run({ "--wait=soon" }).code, remote.EXIT_USAGE, "--wait=soon: not a duration, exit 2")
    eq(run({ "--wait", "--history" }).code, remote.EXIT_USAGE, "--wait with --history: exit 2")
    eq(remote.human(4500), "1h15m", "human: hours and minutes")
  end

  -- ------------------------------------------------------------------ usage

  local u = run({ "--frobnicate" })
  eq(u.code, remote.EXIT_USAGE, "usage: an unknown flag is exit 2")
  has(u.err, "--frobnicate", "usage: ... named")
  eq(run({ "--help" }).code, 0, "usage: --help")
  eq(run({ tmp .. "/absent" }).code, remote.EXIT_USAGE, "usage: a root that is not a directory")

  -- `sha`: one named commit instead of the head of origin/<branch> (testing ci land asks about its check branch)
  do
    local saved_git, saved_token = remote.deps.git, remote.deps.token
    local git_calls = {}
    remote.deps.git = function(_, args)
      git_calls[#git_calls + 1] = table.concat(args, " ")
      local out = args[1] == "remote" and "https://github.com/WKDSteve/alpha.nvim.git\n"
        or (("f"):rep(40) .. "\nmessage\n")
      return {
        wait = function()
          return { code = 0, stdout = out, stderr = "" }
        end,
      }
    end
    remote.deps.token = function()
      return nil, "no token here"
    end
    local recs = remote.collect(
      { { dir = tmp, from_root = false } },
      { state_dir = tmp .. "/sha-state", sha = ("f"):rep(40) }
    )
    remote.deps.git, remote.deps.token = saved_git, saved_token
    has(
      table.concat(git_calls, "\n"),
      "--format=%H%n%B " .. ("f"):rep(40) .. " --",
      "sha: git log names the commit"
    )
    ok(
      not table.concat(git_calls, "\n"):find("origin/", 1, true),
      "sha: not the head of origin/<branch>"
    )
    eq(recs[1].sha, ("f"):rep(40), "sha: the record is about that commit")
  end

  vim.fn.delete(tmp, "rf")
end
