-- TESTS/testing/discover_case_spec.lua -- `TESTS/` and `tests/` on a case-insensitive file system are ONE
-- directory: discovery compares real paths case-folded there (WSL /mnt/e, where fs_realpath keeps the
-- spelling it was given, listed every spec twice), and never folds on a case-sensitive file system.
-- The file system is a seam (`opts.case_insensitive`, `opts.realpath`), so the cases do not depend on the
-- file system the spec runs on.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local discover = require("testing.discover")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-case"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/a_spec.lua", "wb"))
  f:write('return function(H)\n  H.ok(true, "a")\nend\n')
  f:close()
  -- a second spelling: on a case-insensitive file system this is the same file, on a case-sensitive one a copy
  vim.fn.mkdir(root .. "/tests", "p")
  f = assert(io.open(root .. "/tests/a_spec.lua", "wb"))
  f:write('return function(H)\n  H.ok(true, "a")\nend\n')
  f:close()

  ---@param files table[]
  ---@return string[]
  local function rels(files)
    local out = {}
    for _, e in ipairs(files) do
      out[#out + 1] = e.rel
    end
    return out
  end
  ---@param res table
  ---@return boolean
  local function has_legacy_finding(res)
    for _, fd in ipairs(res.findings) do
      if fd.kind == "legacy_location" then
        return true
      end
    end
    return false
  end

  -- a file system whose realpath keeps the spelling (what drvfs does): `tests` is found as a legacy root
  local function identity(p)
    return p
  end

  -- "tests/" below a root that names "TESTS" is a second spelling when the file system folds case
  local on = discover.discover(root, { case_insensitive = true, realpath = identity })
  eq(rels(on.files), { "TESTS/a_spec.lua" }, "case-insensitive: one spec, not one per spelling")
  eq(has_legacy_finding(on), false, "case-insensitive: `tests/` is not reported as a legacy place")

  -- the same inputs without folding (a case-sensitive file system): `tests` is another directory, it is
  -- walked as the legacy place it is, and nothing is merged by lowercasing
  local off = discover.discover(root, { case_insensitive = false, realpath = identity })
  eq(
    rels(off.files),
    { "TESTS/a_spec.lua", "tests/a_spec.lua" },
    "case-sensitive: two directories, two specs"
  )
  eq(has_legacy_finding(off), true, "case-sensitive: `tests/` is a legacy place")

  -- the probe never reports a case-sensitive file system as case-insensitive
  eq(
    discover.is_case_insensitive(root .. "/does-not-exist"),
    false,
    "probe: a missing directory is false"
  )
  vim.fn.mkdir(root .. "/Dup", "p")
  vim.fn.mkdir(root .. "/dup", "p")
  local distinct = 0
  for _, kind in vim.fs.dir(root) do
    distinct = distinct + (kind == "directory" and 1 or 0)
  end
  if distinct == 4 then
    -- TESTS, tests, Dup and dup are four directories: a case-sensitive file system
    eq(
      discover.is_case_insensitive(root .. "/Dup"),
      false,
      "probe: Dup and dup are two directories"
    )
    eq(
      discover.is_case_insensitive(root),
      false,
      "probe: a case-sensitive file system is never folded"
    )
  end

  -- a mount point: `/repo` of a container lies in the container's case-sensitive file system (`/REPO` is not there),
  -- what is mounted there is a Windows folder (`TESTS` and `tests` are the same directory): the entries tell
  do
    local function fs(tree)
      return {
        stat = function(p)
          return tree[p]
        end,
        names = function()
          return { "lua", "TESTS" }
        end,
      }
    end
    local same = { ino = 7, dev = 1 }
    eq(
      discover.is_case_insensitive(
        "/repo",
        fs({
          ["/repo"] = { ino = 1, dev = 0 },
          ["/repo/lua"] = { ino = 2, dev = 1 },
          ["/repo/LUA"] = { ino = 2, dev = 1 },
        })
      ),
      true,
      "probe: a case-insensitive folder mounted on a case-sensitive file system"
    )
    eq(
      discover.is_case_insensitive(
        "/repo",
        fs({ ["/repo"] = { ino = 1, dev = 0 }, ["/repo/lua"] = { ino = 2, dev = 1 } })
      ),
      false,
      "probe: a case-sensitive folder below it stays case-sensitive"
    )
    eq(
      discover.is_case_insensitive(
        "/repo",
        fs({
          ["/repo"] = { ino = 1, dev = 0 },
          ["/repo/lua"] = { ino = 2, dev = 1 },
          ["/repo/LUA"] = { ino = 3, dev = 1 },
          ["/repo/TESTS"] = same,
        })
      ),
      false,
      "probe: two directories that differ in case only are two"
    )
  end

  -- a link `tests -> TESTS` on a case-sensitive file system is one inode under two names: never case-insensitive
  do
    local function fs(tree, names)
      return {
        stat = function(p)
          return tree[p]
        end,
        names = function()
          return names
        end,
      }
    end
    local dir = { ino = 5, dev = 1, type = "directory" }
    eq(
      discover.is_case_insensitive(
        "/r",
        fs(
          { ["/r"] = { ino = 1, dev = 0 }, ["/r/TESTS"] = dir, ["/r/tests"] = dir },
          { "TESTS", "tests" }
        )
      ),
      false,
      "probe: a listing with both spellings is a case-sensitive file system"
    )
    eq(
      discover.is_case_insensitive(
        "/r",
        fs({
          ["/r"] = { ino = 1, dev = 0 },
          ["/r/tests"] = { ino = 5, dev = 1, type = "link" },
          ["/r/TESTS"] = dir,
        }, { "tests" })
      ),
      false,
      "probe: a link is no answer"
    )
  end

  -- without seams the probe of the real file system decides
  vim.fn.delete(root .. "/Dup", "rf")
  vim.fn.delete(root .. "/dup", "rf")
  local real = discover.discover(root, {})
  eq(
    #real.files,
    discover.is_case_insensitive(root) and 1 or 2,
    "real file system: the probe decides whether the two spellings are one directory"
  )

  vim.fn.delete(root, "rf")
end
