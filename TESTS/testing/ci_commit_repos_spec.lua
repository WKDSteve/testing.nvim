-- TESTS/testing/ci_commit_repos_spec.lua -- `testing ci commit --since=<time>` (one repository) and `--repos-root=<dir>
-- --since=<time>` (every repository below a root): the commits since a time, the section per repository, the summary
-- line, the document with `repo` per commit and `repos`, the usage errors, and a repository that cannot be checked.
-- The verdicts themselves are in ci_commit_run_spec.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields, duplicate-set-field

return function(H)
  local ok = H.ok
  local S = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
      .. "/ci_commit_support.lua"
  ).new(H, "ci-commit-repos")
  local eq, has, cli, tmp, state_dir = S.eq, S.has, S.cli, S.tmp, S.state_dir

  ---`testing ci commit <args...>` (no --root: the arguments say which repositories).
  local function run(...)
    local out, err = {}, {}
    local code = cli.main(
      vim.list_extend({ "ci", "commit", "--state-dir=" .. state_dir, "--agent" }, { ... }),
      {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = state_dir,
        color = false,
      }
    )
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n"), lines = out }
  end

  -- two repositories below one root: `a` has a clean commit and then one that turns the gate red, `b` one clean commit
  local a, a1 = S.project("fleet/a", { ["gate.txt"] = "green\n" })
  local a2 = S.commit(a, { ["gate.txt"] = "red\n" }, "turn the gate red")
  local _, b1 = S.project("fleet/b", { ["gate.txt"] = "green\n" })
  local fleet = tmp .. "/fleet"
  -- a directory without a ci section and one that is no repository are not part of the fleet
  S.write(fleet .. "/notes/README.md", "# notes\n")

  do
    -- one repository, the commits since a time
    local r = run("--root=" .. a, "--since=1.day.ago")
    eq(r.code, 1, "since: the regression of the second commit is exit 1")
    has(r.out, "ci commits 2: 1 regression, 1 clean exit 1", "since: the summary of both commits")
    has(r.out, "ci commit " .. a2:sub(1, 7) .. " REGRESSION", "since: the red commit")
    has(r.out, "ci commit " .. a1:sub(1, 7) .. " CLEAN", "since: the first commit too")
    r = run("--root=" .. a, "--since=2099-01-01")
    eq(r.code, 2, "since: no commit since then is a usage error for one repository")
    has(r.err, "names no commit", "since: ... said")
  end

  do
    -- every repository below the root, as a document
    local json = tmp .. "/fleet.json"
    local r = run("--repos-root=" .. fleet, "--since=1.day.ago", "--json=" .. json)
    eq(r.code, 1, "repos: the worst exit of all repositories")
    has(
      r.out,
      "ci commits 3 in 2 repositories: 1 regression, 2 clean exit 1",
      "repos: the summary line"
    )
    has(r.out, "== a", "repos: a section for a")
    has(r.out, "== b", "repos: a section for b")
    has(r.out, "ci commit " .. b1:sub(1, 7) .. " CLEAN", "repos: the commit of b")
    ok(
      r.out:find("== a", 1, true) < r.out:find("== b", 1, true),
      "repos: in the order of the repositories"
    )
    ok(vim.uv.fs_stat(json) ~= nil, "repos: the document is written: " .. r.err .. r.out)
    local doc = vim.json.decode((require("lib.nvim.fs.read")(json)))
    eq(doc.schema, "testing-ci-commit/1", "repos: the same schema")
    eq(doc.exit, 1, "repos: the document's exit")
    eq(doc.repo, "2 repositories", "repos: the repo field names the count")
    eq(#doc.commits, 3, "repos: every commit")
    local per = {}
    for _, c in ipairs(doc.commits) do
      per[c.repo] = (per[c.repo] or 0) + 1
    end
    eq(per, { a = 2, b = 1 }, "repos: each commit names its repository")
    eq(#doc.repos, 2, "repos: a summary per repository")
    eq(doc.repos[1].name, "a", "repos: ... the first")
    eq(doc.repos[1].exit, 1, "repos: ... its exit")
    eq(doc.repos[2].commits, 1, "repos: ... the commits of the second")
  end

  do
    -- narrowed by name, and nothing to check since a later time
    local r = run("--repos-root=" .. fleet, "--since=1.day.ago", "--repos-include=b")
    eq(r.code, 0, "include: b alone is clean")
    has(r.out, "ci commits 1 in 1 repositories", "include: one repository")
    ok(not r.out:find("== a", 1, true), "include: a is left out")
    r = run("--repos-root=" .. fleet, "--since=2099-01-01")
    eq(r.code, 0, "later: nothing to check is not an error with several repositories")
    has(r.out, "repository a: no commits since 2099-01-01", "later: ... said per repository")
  end

  do
    -- a repository that cannot be checked is reported and does not stop the others
    local broken = tmp .. "/fleet2/broken"
    S.write(broken .. "/.testing.lua", S.CFG)
    local good = S.project("fleet2/good", { ["gate.txt"] = "green\n" })
    ok(good ~= nil, "broken: the second repository is there")
    local r = run("--repos-root=" .. tmp .. "/fleet2", "--since=1.day.ago")
    eq(r.code, 2, "broken: a repository that is no git repository is exit 2")
    has(r.out, "repository broken ERROR", "broken: ... named")
    has(r.out, "ci commit", "broken: the other one is checked")
    has(r.out, "CLEAN", "broken: ... and clean")
  end

  do
    -- the usage
    local r = run("--repos-root=" .. fleet)
    eq(r.code, 2, "usage: --repos-root without --since")
    has(r.err, "--repos-root takes --since", "usage: ... said")
    r = run("--repos-root=" .. fleet, "--since=1.day.ago", "HEAD")
    eq(r.code, 2, "usage: --repos-root with a commit")
    r = run("--repos-root=" .. fleet, "--since=1.day.ago", "--base=main")
    eq(r.code, 2, "usage: --repos-root with --base")
    r = run("--root=" .. a, "--since=1.day.ago", "HEAD")
    eq(r.code, 2, "usage: --since with a commit")
    r = run("--root=" .. a, "--since=--all")
    eq(r.code, 2, "usage: --since is not an option of git")
    r = run("--root=" .. a, "--repos-include=a", "HEAD")
    eq(r.code, 2, "usage: --repos-include without --repos-root")
  end

  do
    -- two repositories of one name below different roots keep apart: the name keys `repo` and `repos`
    local dup_a = S.project("dups/x/same", { ["gate.txt"] = "green\n" })
    local dup_b = S.project("dups/y/same", { ["gate.txt"] = "green\n" })
    ok(dup_a ~= nil and dup_b ~= nil, "dups: both repositories are there")
    local json = tmp .. "/dups.json"
    local r = run(
      "--repos-root=" .. tmp .. "/dups/x",
      "--repos-root=" .. tmp .. "/dups/y",
      "--since=1.day.ago",
      "--json=" .. json
    )
    eq(r.code, 0, "dups: both clean: " .. r.err .. r.out)
    local doc = vim.json.decode((require("lib.nvim.fs.read")(json)))
    eq(#doc.repos, 2, "dups: a summary per repository")
    ok(doc.repos[1].name ~= doc.repos[2].name, "dups: ... under names of their own")
    eq(doc.commits[1].repo ~= doc.commits[2].repo, true, "dups: ... and the commits name theirs")

    local commit = require("testing.ci.commit")
    eq(
      commit.repo_names({ { dir = "/r/x/same" }, { dir = "/r/y/same" }, { dir = "/r/solo" } }),
      { "x/same", "y/same", "solo" },
      "names: the parent tells equal names apart"
    )
    eq(
      commit.repo_names({ { dir = "/r/x/same" }, { dir = "/q/x/same" } }),
      { "/r/x/same", "/q/x/same" },
      "names: the whole path when the parent is equal too"
    )
  end

  do
    -- too many commits are refused before git is asked for the `.testing.lua` of each of them
    local commit = require("testing.ci.commit")
    local max, at, asked = commit.MAX_COMMITS, commit.testing_lua_at, 0
    commit.MAX_COMMITS = 1
    commit.testing_lua_at = function(...)
      asked = asked + 1
      return at(...)
    end
    local ok_run, r = pcall(run, "--root=" .. a, "--since=1.day.ago")
    commit.MAX_COMMITS, commit.testing_lua_at = max, at
    ok(ok_run, "limit: the run did not raise")
    eq(r.code, 2, "limit: more commits than the limit is a usage error")
    has(r.err, "2 commits, at most 1 per call", "limit: ... said")
    eq(asked, 0, "limit: no `.testing.lua` was asked for")
  end

  S.cleanup()
end
