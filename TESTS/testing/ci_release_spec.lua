-- TESTS/testing/ci_release_spec.lua -- `testing ci release`: the wizard after a refused job (repository and commit to
-- choose, what changed, one question), the release and the re-run of the failed runs of that commit; without a
-- terminal only with everything named and --yes. Fake gh, fake answers, no network.

---@diagnostic disable: missing-fields, need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok
  local guard = require("testing.ci.runner_guard")
  local release = require("testing.ci.release")

  local function has(text, needle, msg)
    ok(text:find(needle, 1, true) ~= nil, msg .. " (missing " .. vim.inspect(needle) .. ")")
  end
  local function lacks(text, needle, msg)
    ok(text:find(needle, 1, true) == nil, msg .. " (found " .. vim.inspect(needle) .. ")")
  end
  local function sink()
    local o = { out = {}, err = {} }
    o.sv = {
      out = function(s)
        o.out[#o.out + 1] = s
      end,
      err = function(s)
        o.err[#o.err + 1] = s
      end,
      cwd = vim.fn.tempname(), -- not a git checkout: no repository of "this folder"
    }
    return o
  end
  local function joined(o)
    return table.concat(o.out, "\n") .. "\n" .. table.concat(o.err, "\n")
  end

  -- ------------------------------------------------------------------ arguments

  local a = release.parse({ "o/r", "ABCDEF1", "--yes", "--count=5", "--note=x" })
  eq({ a.repo, a.sha, a.yes, a.count, a.note }, { "o/r", "abcdef1", true, 5, "x" }, "parse")
  for _, bad in ipairs({
    { "--count=0" },
    { "--count=51" },
    { "--nope" },
    { "o/r", "p/q" },
    { "zz" },
  }) do
    ok(release.parse(bad) == nil, "parse refuses " .. table.concat(bad, " "))
  end

  -- ------------------------------------------------------------------ a fake GitHub

  local S1, S2, S3 = ("1"):rep(40), ("2"):rep(40), ("3"):rep(40)
  local calls = {}
  local function commit(sha, title, who)
    return {
      sha = sha,
      commit = {
        message = title .. "\n\nbody",
        author = { name = who, date = "2026-11-07T10:00:00Z" },
      },
    }
  end
  local function gh(args)
    local line = table.concat(args, " ")
    calls[#calls + 1] = line
    local route = args[2]
    if args[1] == "run" and args[2] == "rerun" then
      return ""
    elseif route == "repos/o/r/commits?per_page=10" then
      return vim.json.encode({
        commit(S3, "newest", "Al\27[31mice"), -- free text from GitHub: a control character
        commit(S2, "middle", "Bob"),
        commit(S1, "oldest", "Me"),
      })
    elseif route and route:match("^repos/o/r/commits/") then
      local ref = route:match("commits/(%x+)$")
      for _, s in ipairs({ S1, S2, S3 }) do
        if ref and s:sub(1, #ref) == ref then
          return s .. "\n"
        end
      end
      return nil, "no commit"
    elseif route and route:match("^repos/o/r/compare/") then
      return vim.json.encode({
        status = "ahead",
        total_commits = 1,
        commits = { commit(S2, "middle", "Bob") },
        files = {
          { filename = "lua/x.lua", status = "modified" },
          { filename = ".github/workflows/ci\n.yml", status = "added" },
        },
      })
    elseif route and route:match("^repos/o/r/actions/runs%?head_sha=") then
      return vim.json.encode({
        workflow_runs = {
          { id = 71, name = "CI", status = "completed", conclusion = "failure" },
          { id = 72, name = "Bench", status = "completed", conclusion = "success" },
          { id = 73, name = "Docs", status = "in_progress", conclusion = vim.NIL },
          { id = 74, name = "Pages", status = "completed", conclusion = "cancelled" },
        },
      })
    end
    return nil, "unexpected " .. line
  end
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local function ctx(answers)
    local i = 0
    local c = { root = root, gh = gh, now = 1, ask = false }
    if answers then
      c.ask = function()
        i = i + 1
        return answers[i]
      end
    end
    return c
  end
  local function shas()
    local e = guard.read(guard.store_path(root))["o/r"]
    return vim.tbl_map(function(s)
      return s.sha
    end, e and e.shas or {})
  end

  -- the first commit is on the list already
  eq(
    guard.trust_main({ "o/r", S1 }, sink().sv, { root = root, gh = gh, now = 1 }),
    0,
    "setup: S1 released"
  )

  -- ------------------------------------------------------------------ no terminal

  local o = sink()
  eq(release.main({ "o/r", S2 }, o.sv, ctx(false)), 2, "no terminal, no --yes: refused")
  has(joined(o), "add --yes", "no terminal: says what is missing")
  o = sink()
  eq(
    release.main({ "--yes" }, o.sv, ctx(false)),
    2,
    "no terminal, no repository and commit: refused"
  )
  eq(shas(), { S1 }, "no terminal: nothing recorded")

  -- ------------------------------------------------------------------ the steps one by one, as text

  o = sink()
  eq(release.main({ "--repos" }, o.sv, ctx(false)), 0, "--repos: no terminal needed")
  has(joined(o), "o/r", "--repos: the repository of the list")
  has(joined(o), "mode=auto, 1 reviewed", "--repos: with its mode and count")
  o = sink()
  eq(release.main({ "o/r", "--commits" }, o.sv, ctx(false)), 0, "--commits")
  has(joined(o), S1:sub(1, 10) .. "  oldest", "--commits: the commits with their titles")
  lacks(joined(o), "\27", "--commits: no control character from GitHub reaches the terminal")
  o = sink()
  eq(release.main({ "o/r", S2, "--show" }, o.sv, ctx(false)), 0, "--show: no terminal needed")
  has(joined(o), "look closely [.github]", "--show: the workflow file is flagged")
  eq(shas(), { S1 }, "--show records nothing")
  for _, bad in ipairs({
    { "--commits" },
    { "o/r", "--show" },
    { "o/r", S2, "--show", "--yes" },
    { "--repos", "--commits" },
    { "--json" },
    { "o/r", S2, "--json" },
  }) do
    ok(release.parse(bad) == nil, "parse refuses " .. table.concat(bad, " "))
  end

  -- ------------------------------------------------------------------ --json: testing-ci-release/1

  local schema = require("testing.export.schema")
  local schema_file = vim.fs.normalize(
    vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
      .. "/../../schemas/testing-ci-release/1/testing-ci-release.schema.json"
  )
  local sf = assert(io.open(schema_file, "rb"))
  local sdoc = vim.json.decode(sf:read("*a"))
  sf:close()
  ---One document on stdout, valid against the schema.
  local function json(argv, want_exit, what)
    local jo = sink()
    eq(release.main(argv, jo.sv, ctx(false)), want_exit, what .. ": exit")
    eq(#jo.out, 1, what .. ": one line on stdout (" .. joined(jo) .. ")")
    eq(jo.err, {}, what .. ": nothing on stderr")
    local doc = vim.json.decode(jo.out[1] or "{}")
    local valid, problems = schema.validate(sdoc, doc)
    eq(problems, {}, what .. ": valid")
    ok(valid, what .. ": valid")
    return doc
  end

  local d = json({ "--repos", "--json" }, 0, "json repos")
  eq(d.step, "repos", "json repos: step")
  eq(
    { d.repos[1].name, d.repos[1].mode, d.repos[1].reviewed, d.repos[1].here },
    { "o/r", "auto", 1, false },
    "json repos: the repository with its mode and count"
  )

  d = json({ "o/r", "--commits", "--json" }, 0, "json commits")
  eq(
    vim.tbl_map(function(c)
      return { c.sha, c.title, c.released }
    end, d.commits),
    { { S3, "newest", false }, { S2, "middle", false }, { S1, "oldest", true } },
    "json commits: full ids, titles, released, newest first"
  )
  eq(d.commits[1].author, "Al [31mice", "json commits: the control character is gone")

  d = json({ "o/r", S2:sub(1, 8), "--show", "--json" }, 0, "json show")
  eq(d.sha, S2, "json show: the full id")
  eq(
    { d.show.already, d.show.prev, d.show.compared, d.show.status },
    { false, S1, true, "ahead" },
    "json show: compared with the last reviewed"
  )
  eq(d.show.files_total, 2, "json show: both files")
  eq(
    { d.show.files[2].path, d.show.files[2].flag },
    { ".github/workflows/ci .yml", ".github" },
    "json show: the workflow file, flagged, without its newline"
  )
  eq(shas(), { S1 }, "json show records nothing")

  d = json({ "o/r", S1, "--show", "--json" }, 0, "json show of a released commit")
  eq(
    { d.show.already, d.show.compared },
    { true, false },
    "json show: already released, nothing compared"
  )

  d = json({ "--json" }, 2, "json usage")
  eq(d.step, "usage", "json usage: step")
  ok(type(d.problem) == "string", "json usage: says why")

  d = json({ "o/r", "abcdef1", "--show", "--json" }, 3, "json show of an unknown commit")
  has(d.problem, "no commit abcdef1", "json show: an unknown commit says so")

  -- ------------------------------------------------------------------ the wizard, answered no

  o = sink()
  calls = {}
  eq(release.main({}, o.sv, ctx({ "", "2", "n" })), 1, "wizard: no is exit 1")
  local text = joined(o)
  has(text, "o/r", "wizard: the repository of the list is offered")
  has(text, S3:sub(1, 10) .. "  newest", "wizard: the commits with their titles, newest first")
  has(text, "(released)", "wizard: a released commit is marked")
  has(text, "since " .. S1:sub(1, 12), "wizard: what changed since the last reviewed commit")
  has(text, "nothing released", "wizard: no says so")
  eq(shas(), { S1 }, "wizard: no records nothing")
  for _, c in ipairs(calls) do
    lacks(c, "rerun", "wizard: no re-runs nothing")
  end

  -- ------------------------------------------------------------------ the wizard, answered yes

  o = sink()
  calls = {}
  eq(
    release.main({}, o.sv, ctx({ "", "2", "y" })),
    0,
    "wizard: yes is exit 0 (" .. joined(o) .. ")"
  )
  eq(shas(), { S1, S2 }, "wizard: the chosen commit (number 2) is released")
  local reruns = vim.tbl_filter(function(c)
    return c:find("^run rerun") ~= nil
  end, calls)
  eq(
    reruns,
    { "run rerun 71 -R o/r --failed", "run rerun 74 -R o/r --failed" },
    "wizard: the failed and the cancelled run are re-run, not the green or the running one"
  )

  -- a typed commit id and an unknown choice
  o = sink()
  eq(release.main({ "o/r" }, o.sv, ctx({ "9", S3:sub(1, 8), "yes" })), 0, "wizard: a typed id")
  has(joined(o), "not a choice: 9", "wizard: a wrong number is said and asked again")
  eq(shas()[#shas()], S3, "wizard: the typed commit is released")

  -- ------------------------------------------------------------------ everything named, --yes

  o = sink()
  eq(release.main({ "o/r", S1:sub(1, 7), "--yes" }, o.sv, ctx(false)), 0, "--yes: no question")
  has(joined(o), "already on the list", "--yes: an already released commit says so")

  -- the release as a document: the guard's words stay out of stdout, the re-runs are listed
  calls = {}
  d = json({ "o/r", S3, "--yes", "--json", "--note=from json" }, 0, "json release")
  eq(d.step, "release", "json release: step")
  eq(
    { d.release.already, d.release.recorded },
    { true, true },
    "json release: recorded (already on the list)"
  )
  eq(
    vim.tbl_map(function(r)
      return { r.id, r.was, r.ok }
    end, d.release.reruns),
    { { 71, "failure", true }, { 74, "cancelled", true } },
    "json release: the failed and the cancelled run are re-run"
  )

  -- ------------------------------------------------------------------ through `testing ci`

  -- `testing ci release --repos` is the first step of the wizard, not the multi-repository run `testing ci --repos=`:
  -- the command line hands every form of `release` to this module (an app asks the steps one by one)
  o = sink()
  eq(
    require("testing.ci").main({ "release", "--repos", "--json", "--runners=" .. root }, o.sv),
    0,
    "testing ci release --repos --json: exit 0"
  )
  eq(#o.out, 1, "... one document on stdout")
  eq(o.err, {}, "... and nothing on stderr (not the usage of the multi-repository run)")
  local cli = vim.json.decode(o.out[1] or "{}")
  eq({ cli.schema, cli.step, cli.exit }, { release.SCHEMA, "repos", 0 }, "... the step repos")
  eq(
    { cli.repos and cli.repos[1].name, cli.repos and cli.repos[1].mode },
    { "o/r", "auto" },
    "... with the repository of the list"
  )
  o = sink()
  eq(
    require("testing.ci").main({ "release", "--repos", "--runners=" .. root }, o.sv),
    0,
    "testing ci release --repos: the text form too"
  )
  has(joined(o), "o/r", "... names the repository of the list")
end
