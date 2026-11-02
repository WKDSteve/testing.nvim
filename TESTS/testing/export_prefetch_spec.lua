-- TESTS/testing/export_prefetch_spec.lua -- the export asks git for all repositories together (prefetch); the document
-- is byte-for-byte the one the one-by-one questions give: commit, branch (also none when detached), dirty, key.
-- Real git in temp directories.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq = H.ok, H.eq
  local export = require("testing.export")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-export-prefetch"
  local function git(dir, args)
    local argv = vim.list_extend({ "git", "-C", dir }, args)
    local r = vim.system(argv, { text = true }):wait()
    assert(r.code == 0, table.concat(argv, " ") .. ": " .. tostring(r.stderr))
  end
  local function repo(name)
    local dir = tmp .. "/" .. name
    vim.fn.mkdir(dir, "p")
    git(dir, { "init", "-q", "-b", "main" })
    git(dir, { "config", "user.email", "t@example.org" })
    git(dir, { "config", "user.name", "t" })
    local f = assert(io.open(dir .. "/a.txt", "wb"))
    f:write(name)
    f:close()
    git(dir, { "add", "a.txt" })
    git(dir, { "commit", "-q", "-m", "init" })
    return dir
  end
  local clean = repo("clean")
  local dirty = repo("dirty")
  local f = assert(io.open(dirty .. "/b.txt", "wb"))
  f:write("x")
  f:close()
  local detached = repo("detached")
  git(detached, { "checkout", "-q", "--detach" })
  local fresh = tmp .. "/fresh"
  vim.fn.mkdir(fresh, "p")
  git(fresh, { "init", "-q", "-b", "main" })
  local dirs = { clean, dirty, detached, fresh }

  local real_clock = export.clock
  export.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  local function heads()
    local doc, err = export.fleet({ roots = dirs, form = "local", state_dir = tmp .. "/state" })
    ok(doc ~= nil, "fleet: " .. tostring(err))
    local out = {}
    for _, r in ipairs(doc.repos) do
      out[r.name] = { head = r.head, key = r.key }
    end
    return out
  end

  -- with the real seams: prefetch
  local fast = heads()
  -- with wrappers around them (not the real functions: no prefetch), one question after the other
  local real = export.deps
  export.deps = vim.tbl_extend("force", {}, real, {
    identity = function(d)
      return real.identity(d)
    end,
    shallow = function(d)
      return real.shallow(d)
    end,
    head = function(d)
      return real.head(d)
    end,
  })
  local slow = heads()
  export.deps = real
  export.clock = real_clock

  eq(fast, slow, "the prefetch gives the same heads and keys as the questions one by one")
  eq(fast.clean.head.dirty, false, "clean tree")
  eq(fast.dirty.head.dirty, true, "dirty tree (an untracked file)")
  eq(fast.clean.head.branch, "main", "branch")
  eq(fast.detached.head.branch, vim.NIL, "detached: no branch")
  eq(fast.fresh.head, vim.NIL, "no commit: no head")

  vim.fn.delete(tmp, "rf")
end
