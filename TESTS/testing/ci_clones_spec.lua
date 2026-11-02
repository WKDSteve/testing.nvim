-- TESTS/testing/ci_clones_spec.lua -- two checkouts of one GitHub repository are one repository also without the
-- question to GitHub: `testing ci overview --no-remote` (one row) and the repository list of the export
-- (`testing.export.resolve`, so `call fleet` and `testing export`). Real git in temp directories, no network.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq = H.ok, H.eq
  local overview = require("testing.ci.overview")
  local export = require("testing.export")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-clones"
  local function git(dir, args)
    local argv = vim.list_extend({ "git", "-C", dir }, args)
    local r = vim.system(argv, { text = true }):wait()
    assert(r.code == 0, table.concat(argv, " ") .. ": " .. tostring(r.stderr))
  end
  local function repo(name, url, when)
    local dir = tmp .. "/" .. name
    vim.fn.mkdir(dir, "p")
    git(dir, { "init", "-q", "-b", "main" })
    git(dir, { "config", "user.email", "t@example.org" })
    git(dir, { "config", "user.name", "t" })
    git(dir, { "remote", "add", "origin", url })
    local f = assert(io.open(dir .. "/a.txt", "wb"))
    f:write(name)
    f:close()
    git(dir, { "add", "a.txt" })
    local r = vim
      .system(
        { "git", "-C", dir, "commit", "-q", "-m", "init" },
        { env = { GIT_AUTHOR_DATE = when, GIT_COMMITTER_DATE = when }, text = true }
      )
      :wait()
    assert(r.code == 0, r.stderr)
    -- origin/main: the branch the merge compares
    git(dir, { "update-ref", "refs/remotes/origin/main", "HEAD" })
    return dir
  end

  local old = repo("alpha-old", "https://github.com/acme/alpha.git", "2026-01-01T00:00:00Z")
  local new = repo("alpha-new", "git@github.com:acme/alpha.git", "2026-06-01T00:00:00Z")
  local other = repo("beta", "https://github.com/acme/beta.git", "2026-03-01T00:00:00Z")

  local rows = overview.collect({ old, new, other }, { no_remote = true, now = os.time() }, {})
  local names = vim.tbl_map(function(r)
    return r.repo
  end, rows)
  table.sort(names)
  eq(
    names,
    { "alpha-new", "beta" },
    "--no-remote: the two checkouts of acme/alpha are one row (the newer one)"
  )

  local dirs, info = export.resolve({ roots = { old, new, other } })
  ok(dirs ~= nil, "the export list resolves: " .. tostring(info))
  local base = vim.tbl_map(vim.fs.basename, dirs)
  table.sort(base)
  eq(base, { "alpha-new", "beta" }, "the export list holds the repository once")
  eq(info.merged, { "alpha-old" }, "and names the checkout that was merged")

  -- an origin that cannot be read is never merged
  local lone = tmp .. "/lone"
  vim.fn.mkdir(lone, "p")
  git(lone, { "init", "-q", "-b", "main" })
  local dirs2 = export.resolve({ roots = { lone, other } })
  eq(#dirs2, 2, "a checkout without origin is kept")

  vim.fn.delete(tmp, "rf")
end
