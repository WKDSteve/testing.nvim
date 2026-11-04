-- TESTS/testing/cache_spawn_spec.lua -- a spec that starts processes can be cached when it vouches for them
-- (`-- @cache-allow spawn`) and the key holds what the processes start from: the dependency checkouts and the tools
-- (`testing.cache.tools`). Any other program in the ledger, a blocked one or a dropped entry still refuses the file.

-- @cache-allow env
-- @cache-env TN_CI_PROBE
-- (hands the real environment to the key code, as cache_key_spec does)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local tools = require("testing.cache.tools")
  local hash = require("testing.cache.hash")

  -- ---------------------------------------------------------------- which program a ledger entry names
  eq(tools.program_of("git -C <TMP>/x status (x3)"), "git", "program_of: the first word")
  eq(
    tools.program_of('"C:/Program Files/Git/bin/git.exe" status'),
    "git",
    "program_of: a quoted path, without directory and .exe"
  )
  eq(tools.program_of("NVIM --embed"), "nvim", "program_of: lower case")
  eq(tools.program_of(""), nil, "program_of: nothing")
  eq(tools.program_of(42), nil, "program_of: not text")

  eq(tools.covered({}), true, "covered: no process")
  eq(
    tools.covered({ "git status", "bash <TMP>/hook (x3)", "nvim --embed --headless" }),
    true,
    "covered: git, bash and the editor"
  )
  eq(tools.covered({ "git status", "stylua --check ." }), false, "covered: another program")
  eq(tools.covered({ "git status [blocked]" }), false, "covered: a blocked one")
  eq(
    tools.covered({ "git status", "... 4 more not recorded (ledger bound)" }),
    false,
    "covered: entries the ledger dropped"
  )
  eq(tools.covered({ ["git status"] = 1 }), false, "covered: not a list")

  -- ---------------------------------------------------------------- the key lines
  local spawn_spec = "-- @cache-allow spawn\nreturn function(H)\n  H.ok(true, 'x')\nend\n"
  local A = "TESTS/proj/spawn_spec.lua"
  local B = "TESTS/proj/a_spec.lua"
  local root = S.project({ [A] = spawn_spec })
  local dep = vim.fs.normalize(vim.fn.tempname()) .. "/dep.nvim"
  S.write(dep .. "/lua/dep/init.lua", "return 1\n")
  S.write(dep .. "/lua/lib/nvim/init.lua", "return 1\n")
  S.write(dep .. "/plugin/dep.lua", "vim.g.dep = 1\n")
  local cdir = vim.fs.normalize(vim.fn.tempname())

  local function ctx(over)
    return vim.tbl_extend("force", {
      root = root,
      cache_dir = cdir,
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
      -- the dependencies of the project, found through an override of the environment
      deps_declared = { "dep.nvim" },
      deps_opts = {
        getenv = function(name)
          if name == "DEP_NVIM_DIR" then
            return dep
          elseif name == "LIB_NVIM_DIR" then
            return dep
          end
        end,
        fallback = false,
      },
      tools = { git = "git 2.0|config a", bash = "bash 5", nvim = "NVIM 0.12" },
    }, over or {})
  end
  local function key_of(file, over)
    return cache.key({ file = file }, ctx(over))
  end

  local key, why, parts, detail = key_of(A)
  ok(key ~= nil, "a vouching spec has a key: " .. tostring(why))
  local joined = table.concat(parts or {}, "\n")
  ok(
    joined:find("spawn tool git=git 2.0|config a", 1, true) ~= nil,
    "the key holds the git version"
  )
  ok(joined:find("spawn tool bash=bash 5", 1, true) ~= nil, "... the bash version")
  ok(joined:find("spawn dep dep.nvim lua/=", 1, true) ~= nil, "... the dependency checkout")
  ok(
    joined:find("spawn dep lib.nvim lua/=", 1, true) ~= nil,
    "... and lib.nvim, which every child loads"
  )
  ok(
    joined:find("spawn dep dep.nvim runtime plugin/=", 1, true) ~= nil,
    "... with its runtime directories"
  )
  eq(detail and detail.spawn_ok, true, "the detail says the processes are covered")

  local plain_key, _, plain_parts, plain_detail = key_of(B)
  ok(plain_key ~= nil, "a spec without the vouching has a key")
  ok(
    not table.concat(plain_parts or {}, "\n"):find("spawn ", 1, true),
    "... without any line about processes"
  )
  eq(plain_detail and plain_detail.spawn_ok, nil, "... and no spawn_ok")

  ok(
    key_of(A, { tools = { git = "git 2.1|config a", bash = "bash 5", nvim = "NVIM 0.12" } }) ~= key,
    "another git version is another key"
  )
  ok(
    key_of(A, { tools = { git = "git 2.0|config b", bash = "bash 5", nvim = "NVIM 0.12" } }) ~= key,
    "another git configuration is another key"
  )
  ok(
    key_of(A, { tools = { git = "git 2.0|config a", bash = "bash 4", nvim = "NVIM 0.12" } }) ~= key,
    "another bash is another key"
  )
  eq(key_of(A), key, "the same inputs give the same key")
  S.edit(dep, "lua/dep/init.lua", "return 2\n")
  ok(key_of(A) ~= key, "an edit in a dependency is another key")
  S.edit(dep, "lua/dep/init.lua", "return 1\n")
  ok(
    key_of(A) ~= nil and key_of(B) == plain_key,
    "an edit in a dependency leaves the key of a spec that starts nothing alone"
  )

  -- a dependency that cannot be found is no key
  local none, none_why = key_of(A, {
    deps_declared = { "ghost.nvim" },
    deps_opts = {
      getenv = function(name)
        if name == "LIB_NVIM_DIR" then
          return dep
        end
      end,
      fallback = false,
    },
  })
  eq(none, nil, "a dependency that is not found: no key")
  ok(
    type(none_why) == "string" and none_why:find("dependency", 1, true) ~= nil,
    "... and the reason says so: " .. tostring(none_why)
  )

  -- ---------------------------------------------------------------- what is stored
  local function fragment(spawned)
    local c = S.case(A, "case")
    c.effects.spawned = spawned
    return { c }
  end
  local meta = { file = A, spawn_ok = true }
  local opts = { root = root, cache_dir = cdir }
  local stored =
    cache.put(key, fragment({ "git -C <TMP>/r status (x3)", "nvim --embed" }), meta, opts)
  eq(stored, true, "put: git and the editor are stored")
  local back = cache.get(key, vim.tbl_extend("force", opts, { file = A }))
  ok(back ~= nil and #back == 1, "get: the case comes back")
  eq(back and back[1].cached, true, "get: ... marked as cached")

  local k2 = key_of(A, { tools = { git = "git 3|config a", bash = "bash 5", nvim = "NVIM 0.12" } })
  local refused, refused_why = cache.put(k2, fragment({ "stylua --check ." }), meta, opts)
  eq(refused, false, "put: another program is not stored")
  ok(
    type(refused_why) == "string" and refused_why:find("spawned", 1, true) ~= nil,
    "... and says why: " .. tostring(refused_why)
  )
  eq(
    (cache.put(k2, fragment({ "git status [blocked]" }), meta, opts)),
    false,
    "put: a blocked process is not stored"
  )
  eq(
    (cache.put(k2, fragment({ "git status" }), { file = A }, opts)),
    false,
    "put: without the key's word the process still refuses the file"
  )
  eq(
    (cache.put(k2, fragment({}), { file = A }, opts)),
    true,
    "put: a file without a process is stored as before"
  )

  S.remove(root)
  S.remove(vim.fs.dirname(dep))
end
