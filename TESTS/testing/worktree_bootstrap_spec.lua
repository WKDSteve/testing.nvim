-- TESTS/testing/worktree_bootstrap_spec.lua -- the generated scripts/test.sh in a git worktree: a worktree under
-- `<repo>/.claude/worktrees/<name>` has no sibling checkouts, so the dependencies are also looked up under
-- $REPOS_DIR and beside the main checkout the worktree was made from (git's common dir). Without them the message
-- names those places too.
---@diagnostic disable: param-type-mismatch, need-check-nil

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end

  local scaffold = require("testing.scaffold")
  local is_windows = vim.fn.has("win32") == 1

  local bash
  if is_windows then
    -- PATH's bash may be WSL's, which cannot run this; the one that ships with git is the one CI uses.
    local git = vim.fn.exepath("git")
    local candidate = git ~= ""
        and vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(git))) .. "/bin/bash.exe"
      or ""
    bash = vim.uv.fs_stat(candidate) and candidate or vim.fn.exepath("bash")
  else
    bash = vim.fn.exepath("bash")
  end
  ok(bash ~= "", "bash is available")
  ok(vim.fn.executable("git") == 1, "git is available")

  local path_sep = is_windows and ";" or ":"
  local base_env = {
    NVIM_APPNAME = "testing-worktree-spec", -- its stdpath('data') holds no checkout
    TESTING_AGENT = "0",
    PATH = vim.fs.dirname(vim.v.progpath) .. path_sep .. (vim.env.PATH or ""),
    LIB_NVIM_DIR = "",
    TESTING_NVIM_DIR = "",
    REPOS_DIR = "",
  }

  ---@param argv string[]
  ---@param cwd string
  ---@param env? table
  local function run(argv, cwd, env)
    local full = vim.tbl_extend("force", base_env, env or {})
    return vim.system(argv, { cwd = cwd, env = full, text = true, timeout = 60000 }):wait()
  end
  local function git(cwd, ...)
    local res = run({ "git", ... }, cwd)
    eq(res.code, 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end

  local tmp = vim.fs.normalize(vim.fn.tempname())

  --- A stand-in for the two dependencies below `dir`: the marker directories the resolver wants, and a runner entry
  --- that only says it ran (the real runner is not the subject here).
  ---@param dir string
  local function stub_deps(dir)
    vim.fn.mkdir(dir .. "/testing.nvim/lua/testing", "p")
    vim.fn.mkdir(dir .. "/testing.nvim/scripts", "p")
    vim.fn.writefile(
      { 'io.stdout:write("stub-runner ran\\n")', "os.exit(0)" },
      dir .. "/testing.nvim/scripts/testing.lua"
    )
    vim.fn.mkdir(dir .. "/lib.nvim/lua/lib/nvim", "p")
  end

  --- A generated project (`<root>/proj.nvim`) that is a git checkout with one worktree under `.claude/worktrees`.
  ---@param root string
  ---@return string main, string worktree
  local function project_with_worktree(root)
    local main = root .. "/proj.nvim"
    vim.fn.mkdir(main .. "/lua/proj", "p")
    vim.fn.writefile({ "return {}" }, main .. "/lua/proj/init.lua")
    eq(scaffold.init(main).errors, {}, "init for the worktree project")
    git(main, "init", "-q")
    git(main, "add", ".")
    -- a throwaway repository of this spec: nothing of the user's is signed or configured here
    git(
      main,
      "-c",
      "user.name=spec",
      "-c",
      "user.email=spec@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "-m",
      "init"
    )
    local worktree = main .. "/.claude/worktrees/w1"
    git(main, "worktree", "add", "-q", worktree)
    return main, worktree
  end

  -- 1. the siblings of the main checkout are found from the worktree, with REPOS_DIR unset
  local root1 = tmp .. "-beside"
  vim.fn.mkdir(root1, "p")
  stub_deps(root1)
  local _, wt1 = project_with_worktree(root1)
  local res1 = run({ bash, "scripts/test.sh" }, wt1)
  eq(res1.code, 0, "a worktree finds the siblings of its main checkout: " .. tostring(res1.stderr))
  has(res1.stdout, "stub-runner ran", "and runs the runner it found")

  -- 2. $REPOS_DIR is searched too
  local root2 = tmp .. "-reposdir"
  vim.fn.mkdir(root2, "p")
  local repos2 = tmp .. "-reposdir-all"
  vim.fn.mkdir(repos2, "p")
  stub_deps(repos2)
  local _, wt2 = project_with_worktree(root2)
  local res2 = run({ bash, "scripts/test.sh" }, wt2, { REPOS_DIR = repos2 })
  eq(res2.code, 0, "the dependencies are found under $REPOS_DIR: " .. tostring(res2.stderr))
  has(res2.stdout, "stub-runner ran", "and the runner under $REPOS_DIR runs")

  -- 3. nothing anywhere: exit 1, and the message names the two new places and what each held
  local root3 = tmp .. "-none"
  vim.fn.mkdir(root3, "p")
  local _, wt3 = project_with_worktree(root3)
  local res3 = run({ bash, "scripts/test.sh" }, wt3, { REPOS_DIR = root3 .. "/nowhere" })
  eq(res3.code, 1, "no dependency anywhere is exit 1")
  has(
    res3.stderr,
    "$REPOS_DIR/testing.nvim (" .. root3 .. "/nowhere/testing.nvim)",
    "names the $REPOS_DIR place"
  )
  has(
    res3.stderr,
    "beside the main checkout of this worktree (",
    "names the main checkout place with a path"
  )
  ok(
    not res3.stderr:find("(not a worktree)", 1, true),
    "and a worktree is known as one: " .. tostring(res3.stderr)
  )

  -- 4. an override that is set still decides alone, also in a worktree
  local res4 = run({ bash, "scripts/test.sh" }, wt1, { TESTING_NVIM_DIR = root3 .. "/nope" })
  eq(res4.code, 1, "a wrong override is never skipped for the main checkout's sibling")

  -- 5. a plain checkout (no worktree) says so in the message instead of a path
  local plain = tmp .. "-plain/proj.nvim"
  vim.fn.mkdir(plain .. "/lua/proj", "p")
  vim.fn.writefile({ "return {}" }, plain .. "/lua/proj/init.lua")
  eq(scaffold.init(plain).errors, {}, "init for the plain project")
  local res5 = run({ bash, "scripts/test.sh" }, plain)
  eq(res5.code, 1, "a plain checkout without dependencies is exit 1")
  has(res5.stderr, "(not a worktree)", "and says it is not a worktree")

  for _, d in ipairs({ root1, root2, repos2, root3, tmp .. "-plain" }) do
    vim.fn.delete(d, "rf")
  end
end
