-- TESTS/testing/sheet_session_worktree_spec.lua -- a sheet session in a linked git worktree (`.claude/worktrees/<name>`)
-- hands the child the dependencies the main checkout resolves (`$<NAME>_DIR`), as `testing perf` does: a worktree has
-- no sibling checkouts, and the child of `testing sheets run` died without lib.nvim (docmap.nvim, 2026-11-19).
-- What is set already stays; closing the session takes back what it set.

-- @cache-allow outside
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function git(dir, ...)
    local r = vim
      .system({ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", ... }, { text = true })
      :wait()
    assert(r.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr))
    return r.stdout
  end

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-sesswt"
  local main, dep = base .. "/repos/plug.nvim", base .. "/repos/dep.nvim"
  write(dep .. "/lua/dep/init.lua", "return {}\n")
  write(main .. "/.testing.lua", 'return { deps = { "dep.nvim" } }\n')
  write(main .. "/lua/plug/init.lua", "return {}\n")
  git(main, "init", "-q")
  git(main, "add", "-A")
  git(main, "commit", "-q", "-m", "one")
  local wt = base .. "/elsewhere/wt"
  git(main, "worktree", "add", "-q", "--detach", wt)

  local VAR = "DEP_NVIM_DIR"
  local saved = vim.env[VAR]
  vim.env[VAR] = nil
  local s = assert(require("testing.sheet").validate({
    id = "wt.deps",
    title = "deps in a worktree",
    sizes = { { rows = 10, cols = 40 } },
    steps = { { keys = "x" } },
  }))
  local session = require("testing.sheet.session")
  local sess = session.open(s, { root = wt, ci = false })
  local during = vim.env[VAR]
  sess:close()
  local after = vim.env[VAR]
  ok(
    during ~= nil and vim.fs.normalize(during):lower() == vim.fs.normalize(dep):lower(),
    "open: the sibling of the main checkout as " .. VAR .. " (" .. tostring(during) .. ")"
  )
  eq(after, nil, "close: taken back")

  -- a value set already wins and stays
  vim.env[VAR] = "E:/set/before"
  local sess2 = session.open(s, { root = wt, ci = false })
  local during2 = vim.env[VAR]
  sess2:close()
  eq(during2, "E:/set/before", "a value set already wins")
  eq(vim.env[VAR], "E:/set/before", "... and stays after close")

  -- the main checkout itself: nothing set (it has its siblings)
  vim.env[VAR] = nil
  local sess3 = session.open(s, { root = main, ci = false })
  local during3 = vim.env[VAR]
  sess3:close()
  eq(during3, nil, "the main checkout: nothing set")

  vim.env[VAR] = saved
  pcall(git, main, "worktree", "remove", "--force", wt)
  vim.fn.delete(base, "rf")
end
