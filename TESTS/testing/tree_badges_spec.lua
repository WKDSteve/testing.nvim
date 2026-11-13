-- TESTS/testing/tree_badges_spec.lua -- testing.integrations.tree: the last result as a badge per spec file for a
-- tree view. What a summary becomes (red with its count, stale, skipped is not green), the map by absolute path,
-- and the decorator at lib.nvim's registry: nothing read before a tree subscribes, a change told, gone on
-- unsubscribe.

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local state = require("testing.state")
  local result = require("testing.core.result")
  local tree = require("testing.integrations.tree")
  local registry = require("lib.nvim.tree.registry")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  local opts = { state_dir = sdir }
  local function write(rel)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write("return function() end\n")
    f:close()
  end
  local red, green, idle, old =
    "TESTS/red_spec.lua", "TESTS/green_spec.lua", "TESTS/idle_spec.lua", "TESTS/old_spec.lua"
  for _, rel in ipairs({ red, green, idle, old }) do
    write(rel)
  end

  ---@param cases table[]  { file, name, status }
  local function ir(cases)
    local res = result.new({ root = root, id = "2026-01-01T00:00:00Z-0001" })
    for _, c in ipairs(cases) do
      local case = result.new_case({ file = c[1], name = c[2] })
      case.status = c[3]
      case.duration_ms = 1
      result.add_case(res, case)
    end
    return result.finalize(res)
  end
  local function files_of(...)
    local set = {}
    for _, f in ipairs({ ... }) do
      set[f] = true
    end
    return set
  end

  local st = state.new(root)
  state.apply(
    st,
    ir({
      { red, "one", "pass" },
      { red, "two", "fail" },
      { red, "three", "error" },
      { green, "one", "pass" },
      { green, "two", "xfail" },
      { idle, "one", "pass" },
      { idle, "two", "skip" },
      { old, "one", "pass" },
    }),
    { ran_files = files_of(red, green, idle, old) }
  )
  -- the spec file changed after its result was recorded
  local f = assert(io.open(root .. "/" .. old, "ab"))
  f:write("-- edited since\n")
  f:close()

  -- what a summary becomes ------------------------------------------------------
  local function badge(rel)
    return tree.badge(state.file_summary(st, rel))
  end
  eq(
    badge(red),
    { text = "✗ 2/3", hl = "DiagnosticError", status = "failed", count = 2 },
    "red: the count of red cases over all of the file"
  )
  eq(badge(green).status, "passed", "green: pass and xfail are green")
  eq(badge(idle).status, "skipped", "a file with a skipped case is not green")
  eq(badge(old).status, "stale", "a result older than its file is stale, whatever it said")
  eq(badge(old).text, "~", "stale: its own sign")
  eq(
    tree.badge({
      file = "x",
      total = 1,
      counts = { brand_new = 1 },
      failed = {},
      duration_ms = 0,
      stale = false,
    }).status,
    "skipped",
    "a status this module does not know is not called green"
  )
  eq(tree.SEVERITY[1], "failed", "a folder shows red before anything else")
  ok(
    vim.fn.index(tree.SEVERITY, "skipped") < vim.fn.index(tree.SEVERITY, "passed"),
    "... and skipped before green"
  )

  -- the map a tree asks with ----------------------------------------------------
  local map = tree.badges(st)
  local function key(rel)
    local path = (root .. "/" .. rel):gsub("^(%a):", function(drive)
      return drive:upper() .. ":"
    end)
    return path
  end
  eq(vim.tbl_count(map), 4, "one badge per spec file the store has cases of")
  eq(map[key(red)].status, "failed", "keyed by the absolute path, drive letter upper case")
  eq(tree.badges(state.new(root)), {}, "no result: no badge")

  -- the decorator ---------------------------------------------------------------
  registry.reset()
  local loads = 0
  local real_load = state.load
  local current = st
  state.load = function()
    loads = loads + 1
    return current
  end
  local finish = function()
    state.load = real_load
    tree.unregister()
    registry.reset()
  end
  local worked, err = pcall(function()
    eq(
      tree.register({
        root = function()
          return root
        end,
        state_opts = opts,
      }),
      true,
      "register answers true"
    )
    local entry = registry.get("decorator", "tests")
    ok(entry ~= nil, "the decorator is at lib.nvim's registry")
    eq(
      { entry.key, entry.roll_up, entry.severity },
      { "path", "worst", tree.SEVERITY },
      "by path, a folder shows the worst"
    )
    eq(loads, 0, "registering reads no result")
    eq(entry.get(key(red)), nil, "nothing is known before a tree subscribes")

    local told = 0
    local stop = entry.subscribe(function()
      told = told + 1
    end)
    eq(loads, 1, "the first subscriber makes it read the result")
    eq(told, 1, "... and is told")
    eq(entry.get(key(red)).text, "✗ 2/3", "get is a lookup by path")
    eq(vim.tbl_count(entry.all()), 4, "all() is every file with a badge")
    eq(entry.get(root .. "/TESTS/unknown_spec.lua"), nil, "a file without a result has no badge")

    current = state.new(root)
    tree.reload()
    eq({ told, entry.get(key(red)) }, { 2, nil }, "a reload replaces the badges and tells the tree")

    stop()
    eq(entry.all(), {}, "unsubscribe forgets the badges")
    tree.reload()
    eq(told, 2, "... and nobody is told after it")

    tree.register({
      root = function()
        return root
      end,
      state_opts = opts,
    })
    eq(#registry.list("decorator"), 1, "registering again replaces the entry")
    tree.unregister()
    eq(registry.get("decorator", "tests"), nil, "unregister takes it out")
  end)
  finish()
  if not worked then
    error(err, 0)
  end
end
