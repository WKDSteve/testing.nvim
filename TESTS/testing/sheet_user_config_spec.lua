-- TESTS/testing/sheet_user_config_spec.lua -- `config = "user"`: a sheet on the user's installed config, read only.
-- A config and a data folder made here stand in for the user's; a fake lazy.nvim does what the real one would do
-- with the switches it is given (install into the plugin folder, write the lock file, reset the runtimepath), so
-- the proof that both folders are unchanged after a run means something.
-- @cache-allow processes

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
      msg .. " (got " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local uc = require("testing.child.user_config")

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-uc"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    return path
  end
  local root, config, data = base .. "/project", base .. "/user/nvim", base .. "/user/nvim-data"
  write(root .. "/TESTS/minimal_init.lua", "vim.o.swapfile = false\n")

  -- the user's config: lazy.nvim bootstrapped as people do, a module of its own, a plugin/ file
  write(
    config .. "/init.lua",
    [[
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  error("would clone lazy.nvim into " .. lazypath)
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({ { "x/y" } }, {
  install = { missing = true },
  checker = { enabled = true },
  change_detection = { enabled = true },
  performance = { rtp = { reset = true } },
})
vim.g.user_config_mod = require("myconf").value
-- as mason does on a start whose cache does not know the last refresh: the registry is written again
local mason = vim.fn.stdpath("data") .. "/mason"
vim.g.mason_tool = vim.uv.fs_stat(mason .. "/packages/tool/tool.txt") ~= nil
vim.fn.writefile({ "refreshed" }, mason .. "/registries/r/registry.json")
]]
  )
  write(config .. "/lua/myconf.lua", "return { value = 42 }\n")
  write(config .. "/plugin/mine.lua", "vim.g.user_plugin_dir_ran = true\n")
  write(config .. "/lazy-lock.json", "{}\n")
  write(
    data .. "/lazy/lazy.nvim/lua/lazy/init.lua",
    [[
local M = {}
function M.setup(spec, opts)
  -- lazy.nvim's rule: a first table with `spec` is the options, the second argument is not read
  if type(spec) == "table" and spec.spec then
    opts = spec
  end
  vim.g.fake_lazy = {
    missing = opts.install.missing,
    checker = opts.checker.enabled,
    change = opts.change_detection.enabled,
    lockfile = opts.lockfile,
  }
  -- what lazy.nvim does with these switches
  if opts.install.missing ~= false then
    vim.fn.mkdir(vim.fn.stdpath("data") .. "/lazy/y", "p")
  end
  vim.fn.writefile({ '{ "y": "abc" }' }, opts.lockfile or (vim.fn.stdpath("config") .. "/lazy-lock.json"))
  if opts.performance.rtp.reset then
    local rtp = { vim.fn.stdpath("config"), vim.env.VIMRUNTIME }
    vim.list_extend(rtp, opts.performance.rtp.paths or {})
    vim.o.rtp = table.concat(rtp, ",")
  end
end
return M
]]
  )
  write(data .. "/site/pack/p/start/px/plugin/px.lua", "vim.g.pack_px = true\n")
  write(data .. "/other/keep.txt", "not linked\n")
  write(data .. "/mason/packages/tool/tool.txt", "an installed tool\n")
  write(data .. "/mason/registries/r/registry.json", "the registry\n")

  -- a second config: a bootstrap that asks for lazy.nvim before it is on the runtimepath, and setup({ spec = ... }, {})
  local config2 = base .. "/user2/nvim"
  write(
    config2 .. "/init.lua",
    [[
vim.g.early_lazy = pcall(require, "lazy")
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({
  spec = { { "x/y" } },
  install = { missing = true },
  checker = { enabled = true },
  change_detection = { enabled = true },
  performance = { rtp = { reset = false } },
}, {})
]]
  )

  ---Every file below a folder with its size and time: what a run must not change.
  local function tree(dir)
    local out = {}
    for name, kind in vim.fs.dir(dir, { depth = 20 }) do
      local st = vim.uv.fs_stat(dir .. "/" .. name)
      out[name] = kind
        .. ":"
        .. (st and (st.size .. ":" .. st.mtime.sec .. "." .. st.mtime.nsec) or "?")
    end
    return out
  end

  local env = { TESTING_USER_CONFIG = config, TESTING_USER_DATA = data }
  local function getenv(name)
    return env[name]
  end

  -- 1. where it is ---------------------------------------------------------------------------------------------------
  do
    local found = uc.locate(getenv)
    eq(
      found and { found.config, found.data, found.init },
      { config, data, config .. "/init.lua" },
      "named"
    )
    local win = uc.locate(function(n)
      return ({ LOCALAPPDATA = base .. "/user" })[n]
    end, true)
    eq(win and win.config, config, "Windows: LOCALAPPDATA/nvim")
    eq(win and win.data, data, "... and nvim-data")
    local _, why = uc.locate(function(n)
      return ({ XDG_CONFIG_HOME = base .. "/nowhere", XDG_DATA_HOME = base })[n]
    end, false)
    has(why, "no user config at " .. base .. "/nowhere/nvim", "no init there: why")
    local _, ci = uc.locate(function(n)
      return ({ CI = "true", TESTING_USER_CONFIG = config, TESTING_USER_DATA = data })[n]
    end)
    has(ci, "on CI a sheet never reads a user's config", "never on CI")
    eq(uc.child_data("/s/data", "nvim", true), "/s/data/nvim-data", "the data folder of the child")
    local cwd = vim.fn.getcwd()
    vim.fn.chdir(base)
    local rel = uc.locate(function(n)
      return ({ TESTING_USER_CONFIG = "user/nvim", TESTING_USER_DATA = "user/nvim-data" })[n]
    end)
    vim.fn.chdir(cwd)
    -- compared as real paths: on macOS the temp folder `/var/...` is `/private/var/...` from inside it
    local function real(p)
      return p and vim.fs.normalize(vim.uv.fs_realpath(p) or p)
    end
    eq(
      rel and { real(rel.config), real(rel.data) },
      { real(config), real(data) },
      "a relative path is made absolute"
    )
    ok(rel and rel.config:match("^%a:/") or rel.config:sub(1, 1) == "/", "... absolute")
  end

  -- 2. the shape --------------------------------------------------------------------------------------------------------
  do
    local function v(t)
      return sheet.validate(
        vim.tbl_extend("force", { id = "a", title = "T", steps = { { keys = "x" } } }, t)
      )
    end
    ok(v({ config = "user" }), "config = user")
    local _, e1 = v({ config = "mine" })
    has(e1, 'config: "user"', "only user")
    local _, e2 = v({ config = "user", minit = "x.lua" })
    has(e2, "no minit", "not with a minit")
    local _, e3 = v({ config = "user", engine = "browser", steps = { { open = "x" } } })
    has(e3, "config belongs to an rpc sheet", "rpc only")
  end

  -- 3. a run on it, read only ---------------------------------------------------------------------------------------
  do
    local before_config, before_data = tree(config), tree(data)
    local s = assert(sheet.validate({
      id = "uc.real",
      title = "On the user's config",
      config = "user",
      sizes = { { rows = 10, cols = 60 } },
      steps = {
        { expect = "vim.g.user_config_mod == 42", note = "its init ran, its lua/ is found" },
        {
          expect = "vim.env.TESTING_UC_PROBE == 'from the caller'",
          note = "the caller's environment, not the allow-list",
        },
        {
          expect = ("vim.fs.normalize(vim.uv.fs_realpath(vim.fn.stdpath('config'))) == vim.fs.normalize(vim.uv.fs_realpath(%q))"):format(
            config
          ),
          note = "stdpath('config') is the user's config",
        },
        {
          expect = ("not vim.fs.normalize(vim.env.XDG_CONFIG_HOME):find(%q, 1, true)"):format(
            base .. "/user"
          ),
          note = "what other tools write to XDG_CONFIG_HOME stays in the sandbox",
        },
        {
          expect = "vim.env.NVIM_UC_PROBE == 'role' and vim.env.NVIM_LISTEN_ADDRESS == nil",
          note = "the user's NVIM_* variables, not what points at the caller",
        },
        { expect = "vim.g.mason_tool == true", note = "the installed tools of mason" },
        { expect = "vim.g.user_plugin_dir_ran == true", note = "its plugin/ files" },
        { expect = "vim.g.pack_px == true", note = "the packages of its data folder" },
        {
          expect = "vim.g.fake_lazy.missing == false and vim.g.fake_lazy.checker == false and vim.g.fake_lazy.change == false",
          note = "lazy.nvim installs, checks and watches nothing",
        },
        { expect = ("not vim.g.fake_lazy.lockfile:find(%q, 1, true)"):format(config) },
        {
          expect = ("not vim.fs.normalize(vim.fn.stdpath('state')):find(%q, 1, true)"):format(
            base .. "/user"
          ),
        },
        { lua = "vim.fn.writefile({ 'x' }, vim.fn.stdpath('data') .. '/written.txt')" },
        {
          expect = "pcall(require, 'testing.screen')",
          note = "testing.nvim stays after lazy's reset",
        },
        { screen = "after", note = "the screen still works" },
      },
    }))
    s.path = root .. "/TESTS/sheets/uc.sheet.lua"
    vim.env.TESTING_UC_PROBE = "from the caller"
    vim.env.NVIM_UC_PROBE = "role"
    vim.env.NVIM_LISTEN_ADDRESS = "\\\\.\\pipe\\the-caller"
    local res = sheet.run(s, { root = root, getenv = getenv, ci = false })
    vim.env.TESTING_UC_PROBE, vim.env.NVIM_UC_PROBE, vim.env.NVIM_LISTEN_ADDRESS = nil, nil, nil
    eq({ res.status, res.failures }, { "pass", {} }, "a sheet on the user's config runs")
    eq(tree(config), before_config, "the user's config is unchanged (lock file, folders)")
    eq(
      tree(data),
      before_data,
      "the user's data is unchanged (no plugin installed, nothing written)"
    )

    -- the second config: lazy's own rule for `setup({ spec = ... }, {})`, and an early require is "not found"
    local before2 = tree(config2)
    local s2 = assert(sheet.validate({
      id = "uc.second",
      title = "setup with spec",
      config = "user",
      sizes = { { rows = 10, cols = 60 } },
      steps = {
        { expect = "vim.g.early_lazy == false", note = "require before the bootstrap: not found" },
        {
          expect = "vim.g.fake_lazy.missing == false and vim.g.fake_lazy.checker == false and vim.g.fake_lazy.change == false",
          note = "setup({ spec = ... }, {}): the switches reach lazy.nvim",
        },
      },
    }))
    local res2 = sheet.run(s2, {
      root = root,
      ci = false,
      getenv = function(n)
        return ({ TESTING_USER_CONFIG = config2, TESTING_USER_DATA = data })[n]
      end,
    })
    eq({ res2.status, res2.failures }, { "pass", {} }, "the second config runs")
    eq(tree(config2), before2, "its config is unchanged")
    eq(tree(data), before_data, "and the data still")

    -- 4. no config: a skip with the reason, never green
    local skipped = sheet.run(s, {
      root = root,
      getenv = function(n)
        return ({ CI = "1", TESTING_USER_CONFIG = config, TESTING_USER_DATA = data })[n]
      end,
    })
    eq(skipped.status, "skip", "on CI: a skip")
    has(skipped.skipped, "on CI", "... with the reason")
  end

  vim.fn.delete(base, "rf")
end
