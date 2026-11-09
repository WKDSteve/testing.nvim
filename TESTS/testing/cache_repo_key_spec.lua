-- TESTS/testing/cache_repo_key_spec.lua -- the cache folder of a linked worktree is that of its main checkout:
-- `testing ci commit` checks every commit out into a worktree of its own, and the runs there, the base and the runs in
-- the working tree share one cache (keys describe content, never the place). A bare repository, a broken link and a
-- plain folder keep a folder of their own.

---@diagnostic disable: need-check-nil, missing-fields, param-type-mismatch

-- The real `git worktree add` case starts git.
-- @cache off
return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(a == b, ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a)))
  end
  local store = require("testing.cache.store")
  local base = vim.fs.normalize(vim.fn.tempname())

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local saved = store.project_key
  store.project_key = nil
  local tmp = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname(), ":p"))
  local main = tmp .. "/main"
  vim.fn.mkdir(main .. "/.git/worktrees/wt", "p")
  write(main .. "/.git/HEAD", "ref: refs/heads/main\n")
  local main_dir = store.dir(main, { cache_dir = base })

  -- absolute gitdir, relative commondir (what git writes)
  local wt = tmp .. "/elsewhere/wt"
  write(wt .. "/.git", "gitdir: " .. main .. "/.git/worktrees/wt\n")
  write(main .. "/.git/worktrees/wt/commondir", "../..\n")
  eq(store.repo_key(wt), store.repo_key(main), "a worktree has the key of its main checkout")
  eq(store.dir(wt, { cache_dir = base }), main_dir, "and the same cache folder")

  -- relative gitdir (`worktree.useRelativePaths`), CRLF in the files
  local wt2 = main .. "-wt2"
  vim.fn.mkdir(main .. "/.git/worktrees/wt2", "p")
  write(wt2 .. "/.git", "gitdir: ../main/.git/worktrees/wt2\r\n")
  write(main .. "/.git/worktrees/wt2/commondir", "../..\r\n")
  eq(store.dir(wt2, { cache_dir = base }), main_dir, "a relative gitdir is followed too")

  -- a broken link and a bare repository: a folder of their own
  local broken = tmp .. "/broken"
  write(broken .. "/.git", "gitdir: " .. tmp .. "/nowhere\n")
  ok(store.dir(broken, { cache_dir = base }) ~= main_dir, "a broken link keeps its own folder")
  local bare_wt = tmp .. "/bare-wt"
  vim.fn.mkdir(tmp .. "/repo.git/worktrees/x", "p")
  write(bare_wt .. "/.git", "gitdir: " .. tmp .. "/repo.git/worktrees/x\n")
  write(tmp .. "/repo.git/worktrees/x/commondir", "../..\n")
  eq(
    store.repo_key(bare_wt),
    require("lib.nvim.fs.project_key")(bare_wt),
    "a bare repository: no main checkout"
  )

  -- another repository is another folder; cache.project_key still wins
  local other = tmp .. "/other"
  vim.fn.mkdir(other .. "/.git", "p")
  ok(store.dir(other, { cache_dir = base }) ~= main_dir, "another repository has another folder")
  ok(
    store.dir(wt, { cache_dir = base, project_key = "named" }) ~= main_dir,
    "cache.project_key names the folder"
  )

  -- the real thing
  local function git(cwd, ...)
    return vim
      .system(
        { "git", "-c", "user.name=t", "-c", "user.email=t@example.com", ... },
        { cwd = cwd, text = true }
      )
      :wait()
  end
  local real = tmp .. "/real"
  vim.fn.mkdir(real, "p")
  if git(real, "init", "-q").code == 0 then
    write(real .. "/a.txt", "a\n")
    git(real, "add", "a.txt")
    eq(git(real, "commit", "-q", "--no-gpg-sign", "-m", "a").code, 0, "real: a commit")
    local rwt = tmp .. "/real-wt"
    eq(git(real, "worktree", "add", "-q", "--detach", rwt).code, 0, "real: git worktree add")
    eq(
      store.dir(rwt, { cache_dir = base }),
      store.dir(real, { cache_dir = base }),
      "real: the worktree shares the cache folder of the checkout"
    )
    git(real, "worktree", "remove", "--force", rwt)
  end

  store.project_key = saved
  vim.fn.delete(tmp, "rf")
end
