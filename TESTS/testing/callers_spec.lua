-- TESTS/testing/callers_spec.lua -- `testing callers`: what went away between two states of a project (a removed
-- export, a deleted or renamed module) and who still calls it, in the project, in the checkouts below $REPOS_DIR and in
-- $NVIM_CONFIG_DIR (the nvim config, which lives outside $REPOS_DIR). gopath renamed `resolve_and_open`, searched
-- for callers below $REPOS_DIR only, and the config broke.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local callers = require("testing.callers")

  -- ── the pieces ──
  eq(callers.module_of("lua/plug/a.lua"), "plug.a")
  eq(callers.module_of("lua/plug/init.lua"), "plug")
  eq(callers.module_of("lua/plug/sub/init.lua"), "plug.sub")
  eq(callers.module_of("plugin/plug.lua"), nil, "outside lua/ is no module")

  eq(
    callers.exports(
      "local M = {}\nfunction M.open(x) end\nM.close = function() end\nM.LIMIT = 3\nlocal function hidden() end\nreturn M\n"
    ),
    { open = true, close = true, LIMIT = true },
    "the fields of the returned table, at the start of a line"
  )
  eq(
    callers.exports("local P = {}\nfunction P:go() end\nreturn setmetatable(P, {})\n"),
    { go = true },
    "a table returned through setmetatable, a method"
  )
  eq(callers.exports("return { a = 1 }\n"), nil, "a table literal: nothing to compare")

  local removed = {
    { module = "plug.a", name = "old", path = "lua/plug/a.lua" },
    { module = "plug.gone", path = "lua/plug/gone.lua" },
  }
  local function lines(text)
    local out = {}
    for _, h in ipairs(callers.scan(text, removed)) do
      out[#out + 1] = ("%d %s.%s"):format(h.line, h.module, h.name or "*")
    end
    return out
  end
  eq(lines('require("plug.a").old()\n'), { "1 plug.a.old" }, "a field read off the require")
  eq(
    lines('local a = require("plug.a")\na.keep()\na.old(1)\nlocal t = { a.old }\n'),
    { "3 plug.a.old", "4 plug.a.old" },
    "through an alias"
  )
  eq(
    lines("local ok, a = pcall(require, 'plug.a')\nif ok then a:old() end\n"),
    { "2 plug.a.old" },
    "an alias of pcall(require, ...), a method call"
  )
  eq(lines('local g = require("plug.gone")\n'), { "1 plug.gone.*" }, "a module that went away")
  eq(lines('-- require("plug.a").old()\nlocal b = x.a.old\n'), {}, "a comment, a longer name")
  eq(lines('local a = require("plug.ab")\na.old()\n'), {}, "another module with the same head")
  eq(
    lines("vim.cmd(\"lua require('plug.a').old()\")\n"),
    { "1 plug.a.old" },
    "inside a string, too"
  )

  -- a submodule reached through the facade (gopath: `gopath.commands.resolve_and_open`)
  local facade = {
    { module = "gopath.commands", name = "resolve_and_open", path = "lua/gopath/commands.lua" },
    { module = "gopath.old", path = "lua/gopath/old.lua" },
  }
  local function facade_lines(text)
    local out = {}
    for _, h in ipairs(callers.scan(text, facade)) do
      out[#out + 1] = ("%d %s.%s"):format(h.line, h.module, h.name or "*")
    end
    return out
  end
  eq(
    facade_lines(
      'local gopath = require("gopath")\nreturn function() gopath.commands.resolve_and_open("edit") end\n'
    ),
    { "2 gopath.commands.resolve_and_open" },
    "a field chain through the facade"
  )
  eq(
    facade_lines('require("gopath").commands.resolve_and_open()\n'),
    { "1 gopath.commands.resolve_and_open" },
    "a chain read off the require"
  )
  eq(
    facade_lines('local c = require("gopath").commands\nc.resolve_and_open()\nc.goto_at_cursor()\n'),
    { "2 gopath.commands.resolve_and_open" },
    "an alias of a field of the require"
  )
  eq(
    facade_lines('local g = require("gopath")\ng.old.x()\ng.setup()\n'),
    { "2 gopath.old.*" },
    "a submodule that went away, reached through the facade"
  )
  eq(facade_lines('local g = require("gopath")\ng.setup()\n'), {}, "the facade alone is no call")

  -- ── a real repository and a fleet ──
  local function run(cwd, ...)
    local r = vim
      .system(
        { "git", "-c", "user.name=t", "-c", "user.email=t@example.com", ... },
        { cwd = cwd, text = true }
      )
      :wait()
    ok(r.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr))
    return r.stdout
  end
  local fleet = S.project()
  local plug = fleet .. "/plug.nvim"
  S.write(
    plug .. "/lua/plug/a.lua",
    "local M = {}\nfunction M.old() end\nfunction M.keep() end\nreturn M\n"
  )
  S.write(plug .. "/lua/plug/gone.lua", "return {}\n")
  S.write(plug .. "/lua/plug/moved.lua", "local M = {}\nfunction M.x() end\nreturn M\n")
  S.write(
    plug .. "/lua/plug/user.lua",
    'local a = require("plug.a")\nreturn function() a.old() end\n'
  )
  run(plug, "init", "-q")
  run(plug, "add", "-A")
  run(plug, "commit", "-q", "-m", "one")

  -- the change: old renamed, gone deleted, moved renamed to another module
  S.write(
    plug .. "/lua/plug/a.lua",
    "local M = {}\nfunction M.renamed() end\nfunction M.keep() end\nreturn M\n"
  )
  os.remove(plug .. "/lua/plug/gone.lua")
  run(plug, "mv", "lua/plug/moved.lua", "lua/plug/other.lua")

  local got = callers.removed(plug, "HEAD")
  local names = {}
  for _, r in ipairs(got) do
    names[#names + 1] = r.module .. "." .. (r.name or "*")
  end
  eq(names, { "plug.a.old", "plug.gone.*", "plug.moved.*" }, "what went away against HEAD")
  local _, err = callers.removed(plug, "no-such-rev")
  ok(err, "an unknown revision is an error")

  -- the fleet: another checkout, a linked worktree (a copy), the config outside the repos folder
  S.write(
    fleet .. "/other.nvim/lua/other/init.lua",
    'return { go = function() require("plug.a").old() end }\n'
  )
  vim.fn.mkdir(fleet .. "/other.nvim/.git", "p")
  S.write(fleet .. "/copy.nvim/.git", "gitdir: elsewhere\n")
  S.write(fleet .. "/copy.nvim/lua/c.lua", 'require("plug.gone")\n')
  local config = S.project()
  S.write(config .. "/lua/keys.lua", 'local p = require("plug.moved")\nreturn p.x\n')
  S.write(config .. "/init.vim", "lua require('plug.a').keep()\n")

  local function main(argv, env)
    local out = {}
    local code = callers.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        out[#out + 1] = "ERR " .. s
      end,
      cwd = plug,
      getenv = function(name)
        return env[name]
      end,
    })
    return code, table.concat(out, "\n")
  end

  local code, text = main({ "--base=HEAD" }, { REPOS_DIR = fleet, NVIM_CONFIG_DIR = config })
  eq(code, callers.EXIT_FOUND, text)
  has(text, "CALLERS | 3 calls")
  has(text, "plug.a.old (removed)  " .. vim.fs.normalize(plug) .. "/lua/plug/user.lua:2")
  has(
    text,
    "plug.a.old (removed)  " .. vim.fs.normalize(fleet) .. "/other.nvim/lua/other/init.lua:1"
  )
  has(text, "plug.moved (module removed)  " .. vim.fs.normalize(config) .. "/lua/keys.lua:1")
  ok(not text:find("copy.nvim", 1, true), "a linked worktree is a copy: not looked at")
  ok(not text:find("init.vim", 1, true), "an export that stays is no finding")

  -- the repos folder named through a link (macOS: /var is /private/var to git): the project is looked at once
  local link = vim.fs.normalize(vim.fn.tempname())
  local linked = vim.uv.fs_symlink(fleet, link, { junction = true, dir = true })
  if linked then
    code, text = main({ "--base=HEAD" }, { REPOS_DIR = link, NVIM_CONFIG_DIR = config })
    eq(code, callers.EXIT_FOUND)
    has(text, "CALLERS | 3 calls", "the same checkout through a link is one root")
    os.remove(link)
    vim.uv.fs_rmdir(link)
  end

  code, text = main({ "--base=HEAD" }, { REPOS_DIR = fleet })
  eq(code, callers.EXIT_FOUND)
  has(text, "note: NVIM_CONFIG_DIR is not set")
  ok(
    not text:find("keys.lua", 1, true),
    "without the variable the config is not looked at, and it says so"
  )

  code, text = main({ "--base=HEAD", "--roots=" .. config }, {})
  eq(code, callers.EXIT_FOUND)
  has(text, "CALLERS | 2 calls", "--roots: the project and the named folder")

  code, text = main(
    { "--base=HEAD", "--no-fleet" },
    { REPOS_DIR = fleet, NVIM_CONFIG_DIR = config }
  )
  eq(code, callers.EXIT_FOUND)
  has(text, "CALLERS | 1 calls", "--no-fleet: the project only")

  -- nothing that went away is called: clean
  S.write(
    plug .. "/lua/plug/user.lua",
    'local a = require("plug.a")\nreturn function() a.renamed() end\n'
  )
  code, text = main({ "--base=HEAD", "--no-fleet" }, {})
  eq(code, callers.EXIT_OK, text)
  has(text, "CLEAN | 3 removed since HEAD")

  -- usage and git failures
  eq(main({ "--bogus" }, {}), callers.EXIT_USAGE)
  eq(main({ "--roots=x", "--no-fleet" }, {}), callers.EXIT_USAGE)
  eq(main({ "--base=no-such-rev" }, {}), callers.EXIT_FAILED)

  -- the command line hands it over
  local cli_out = {}
  local cli_code = require("testing.cli").main({ "callers", "--help" }, {
    out = function(s)
      cli_out[#cli_out + 1] = s
    end,
    err = function(s)
      cli_out[#cli_out + 1] = s
    end,
  })
  eq(cli_code, 0)
  has(table.concat(cli_out, "\n"), "usage: testing callers")

  S.remove(fleet)
  S.remove(config)
end
