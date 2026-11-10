-- TESTS/testing/suite_gitconfig_spec.lua -- the git configuration of this suite (TESTS/minimal_init.lua): a spec's child
-- editor gives its fixture repositories a configuration of its own (no global hooks, no signing, fixed line endings and
-- identity), outside the checkout (no key names the place of a checkout), and without the system configuration; the
-- runner's own process, which runs the same minit for the keys, keeps the machine's configuration (its git works on
-- the real checkout: `safe.directory`, credentials).
-- It starts git (questions about its configuration) and an editor that runs the minit as the runner does, and nothing
-- else: the key holds git, nvim (`testing.cache.tools`) and the minit (reviewed 2026-11-10).
-- @cache-allow spawn
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local root = vim.fs.dirname(
    vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
      )
    )
  )
  local minit = root .. "/TESTS/minimal_init.lua"

  -- this spec runs in a child editor: the minit gave it the suite's configuration
  local global = vim.env.GIT_CONFIG_GLOBAL
  ok(
    type(global) == "string" and vim.uv.fs_stat(global) ~= nil,
    "the child has a git configuration file of its own"
  )
  eq(vim.env.GIT_CONFIG_NOSYSTEM, "1", "and git does not read the system configuration")
  local norm = vim.fs.normalize(tostring(global))
  ok(
    norm:sub(1, #root + 1) ~= root .. "/",
    "the file is not in the checkout (a key must not name its place)"
  )
  local function git_global(key)
    local res = vim
      .system({ "git", "config", "--global", "--get", key }, { text = true })
      :wait(30000)
    return res.code, vim.trim(res.stdout or "")
  end
  eq(
    { git_global("core.hooksPath") },
    { 1, "" },
    "no hooks path: a fixture commit starts no hook of the machine"
  )
  eq(
    { git_global("user.name") },
    { 0, "testing.nvim spec" },
    "a fixed identity for fixture commits"
  )
  eq({ git_global("commit.gpgsign") }, { 0, "false" }, "and no signing")

  -- the runner's process (testing.run.project is loaded when it runs the minit): nothing changes there
  local probe = vim.fn.tempname() .. "-probe.lua"
  local fh = assert(io.open(probe, "wb"))
  fh:write(table.concat({
    "vim.env.GIT_CONFIG_GLOBAL = nil",
    "vim.env.GIT_CONFIG_NOSYSTEM = nil",
    "local as_runner = _G.arg[1]",
    "if as_runner == 'runner' then package.loaded['testing.run.project'] = {} end",
    "dofile(" .. string.format("%q", minit) .. ")",
    "io.stdout:write(tostring(vim.env.GIT_CONFIG_GLOBAL), ' ', tostring(vim.env.GIT_CONFIG_NOSYSTEM))",
  }, "\n"))
  fh:close()
  local function run_minit(as)
    local res = vim
      .system(
        { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", probe, as },
        { text = true }
      )
      :wait(60000)
    return res.code, res.stdout or ""
  end
  local code_r, out_r = run_minit("runner")
  eq(
    { code_r, out_r },
    { 0, "nil nil" },
    "the runner's process keeps the machine's git configuration"
  )
  local code_c, out_c = run_minit("child")
  eq(code_c, 0, "the minit runs in a child: " .. out_c)
  ok(
    out_c:find("testing-spec.gitconfig 1", 1, true) ~= nil,
    "and a child gets the suite's configuration: " .. out_c
  )
  os.remove(probe)
end
