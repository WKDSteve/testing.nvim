-- TESTS/testing/ci_on_copy_spec.lua -- the copy a container of `testing ci --on` makes before the run
-- (testing.ci.on.COPY_SCRIPT), run with the local `sh` against temp folders: from a git checkout the tracked files,
-- the untracked ones that are not ignored and `.git`, not what is ignored; from a plain folder everything; a copy that
-- fails is exit 3. The command after `--` runs in the copy of the first pair.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local sh = vim.fn.exepath("sh")
  if sh == "" or vim.fn.executable("git") ~= 1 or vim.fn.executable("tar") ~= 1 then
    -- the script is POSIX sh with git and tar; a machine without them has nothing to say about it
    ok(true, "no sh, git or tar here: the copy is not run")
    return
  end
  local on = require("testing.ci.on")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-on-copy"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function git(dir, ...)
    local res = vim
      .system(
        vim.list_extend({ "git", "-C", dir, "-c", "commit.gpgsign=false" }, { ... }),
        { text = true }
      )
      :wait(30000)
    assert(res.code == 0, (res.stderr or "") .. table.concat({ ... }, " "))
  end
  local function exists(path)
    return vim.uv.fs_stat(path) ~= nil
  end

  -- a checkout: tracked, untracked, ignored (a build folder of a pin), and git's own folder
  local src = tmp .. "/src"
  write(src .. "/lua/a.lua", "return 1\n")
  write(src .. "/.gitignore", "build/\n")
  git(src, "init", "-q")
  git(src, "add", ".")
  git(src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x")
  write(src .. "/new_spec.lua", "return 2\n")
  write(src .. "/build/huge.bin", "x")
  -- a plain folder
  local plain = tmp .. "/plain"
  write(plain .. "/build/kept.txt", "y")

  local dst, dst2 = tmp .. "/work/repo", tmp .. "/work/plain"
  local res = vim
    .system({ sh, "-c", on.COPY_SCRIPT, "sh", dst, src, dst, plain, dst2, "--", "sh", "-c", "pwd" }, {
      text = true,
    })
    :wait(60000)
  eq(res.code, 0, "copy: exit 0: " .. (res.stderr or ""))
  ok(exists(dst .. "/lua/a.lua"), "copy: a tracked file")
  ok(
    exists(dst .. "/new_spec.lua"),
    "copy: an untracked file that is not ignored (the working tree)"
  )
  ok(exists(dst .. "/.git/HEAD"), "copy: git's folder")
  ok(not exists(dst .. "/build/huge.bin"), "copy: not what is ignored")
  ok(exists(dst2 .. "/build/kept.txt"), "copy: a plain folder is copied whole")
  ok(
    vim.trim(res.stdout or ""):find("work/repo$") ~= nil,
    "copy: the command runs in the first copy"
  )

  res = vim
    .system({ sh, "-c", on.COPY_SCRIPT, "sh", dst, tmp .. "/missing", dst, "--", "true" }, { text = true })
    :wait(60000)
  eq(res.code, 3, "copy: a folder that cannot be copied is exit 3")
  ok((res.stderr or ""):find("cannot copy", 1, true) ~= nil, "copy: ... and says so")
  vim.fn.delete(tmp, "rf")
end
