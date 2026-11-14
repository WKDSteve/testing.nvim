-- TESTS/testing/tree_tests_source_spec.lua -- testing.integrations.tree: the view `tests` at lib.nvim's registry.
-- What is registered (the source next to the decorator, its severity, aggregate, preview and actions), that nothing
-- is read before a tree asks, the root it answers (the last result plus the spec files that never ran), a changed
-- result told with `reset`, the runs its actions start, the keys from the options, and `setup({ tree = ... })`.
-- The registry is lib.nvim's own, emptied before and after; the run is a stand-in that records its flags.

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
  local nodes = require("testing.explorer.nodes")
  local registry = require("lib.nvim.tree.registry")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  local sopts = { state_dir = sdir }
  local function write(rel, lines)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
  end
  local red, green, fresh = "TESTS/red_spec.lua", "TESTS/green_spec.lua", "TESTS/fresh_spec.lua"
  write(red, { "return function() end" })
  write(green, { "return function() end" })
  write(fresh, {
    'describe("fresh", function()',
    '  it("one", function() end)',
    '  it("two", function() end)',
    "end)",
  })

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
  local st = state.new(root)
  state.apply(
    st,
    ir({ { red, "one", "pass" }, { red, "two", "fail" }, { green, "one", "pass" } }),
    { ran_files = { [red] = true, [green] = true } }
  )

  registry.reset()
  local loads = 0
  local real_load = state.load
  local current = st
  state.load = function()
    loads = loads + 1
    return current
  end
  local runs = {}
  local function opts(extra)
    return vim.tbl_extend("force", {
      root = function()
        return root
      end,
      state_opts = sopts,
      run = function(run)
        runs[#runs + 1] = run
      end,
    }, extra or {})
  end
  local config = require("testing.config")
  local finish = function()
    state.load = real_load
    tree.unregister()
    registry.reset()
    config.reset()
  end

  ---The node with this id, searched below `node` (lists only).
  local function find(node, id)
    if node.id == id then
      return node
    end
    if type(node.children) == "table" then
      for _, child in ipairs(node.children) do
        local hit = find(child, id)
        if hit then
          return hit
        end
      end
    end
    return nil
  end

  local worked, err = pcall(function()
    eq(tree.status(), "not registered", "before register: not registered")
    eq(tree.register(opts()), true, "register answers true")
    eq(tree.status(), "registered", "... and status says so")
    local entry = registry.get("source", "tests")
    ok(entry ~= nil, "the source is at lib.nvim's registry")
    ok(registry.get("decorator", "tests") ~= nil, "... next to the decorator")
    eq(
      { entry.title, entry.mutable, entry.severity, entry.aggregate },
      { "Tests", false, nodes.SEVERITY, nodes.aggregate },
      "a view that changes no file, with the severity order and the aggregate of the nodes"
    )
    eq(loads, 0, "registering reads no result")

    -- the root ------------------------------------------------------------------------
    local top = entry.root({})
    eq(loads, 1, "showing the view reads the result")
    local red_node = find(top, "tests:file:" .. red)
    eq(
      { red_node.path, red_node.icon, red_node.columns[1] },
      { nodes.norm(root .. "/" .. red), "✗", "1/2" },
      "a spec file of the result: its path, red, one of two"
    )
    local fresh_node = find(top, "tests:file:" .. fresh)
    eq(fresh_node.status, "never", "a spec file below TESTS that never ran is listed as such")
    local got
    fresh_node.children(fresh_node, function(list)
      got = list
    end)
    eq(
      { got[1].label, #got[1].children, got[1].children[2].data.lnum },
      { "fresh", 2, 3 },
      "... and opening it reads its describe and its cases from the file"
    )
    entry.root({})
    eq(
      loads,
      2,
      "without a subscriber every showing reads the result again: nobody follows the file"
    )

    -- told when the result changes ------------------------------------------------------
    local resets = 0
    local stop = entry.subscribe({}, {
      reset = function()
        resets = resets + 1
      end,
      push = function() end,
      invalidate = function() end,
    })
    eq(resets, 0, "subscribing tells nothing: the view was just built")
    local before = loads
    vim.fn.mkdir(state.dir(root, sopts), "p")
    vim.fn.writefile({ "{}" }, state.dir(root, sopts) .. "/touched")
    vim.wait(4000, function()
      return resets > 0
    end, 20)
    ok(loads > before, "a change of the result directory makes it read the result")
    ok(resets > 0, "... and the view is told to ask for the root again")
    before = loads
    entry.root({})
    eq(loads, before, "the root after that is made from what was just read")

    current = state.new(root)
    tree.reload()
    eq(
      find(entry.root({}), "tests:file:" .. red).status,
      "never",
      "a reload replaces what the view shows"
    )
    current = st

    stop()
    local at_stop = resets
    tree.reload()
    eq(resets, at_stop, "after unsubscribe nobody is told")
    local loads_at_stop = loads
    vim.fn.writefile({ "{}" }, state.dir(root, sopts) .. "/touched-again")
    vim.wait(600, function()
      return false
    end)
    eq(loads, loads_at_stop, "... and nothing is watched")

    -- the decorator steps back on the nodes of the view -----------------------------------
    local decorator = registry.get("decorator", "tests")
    local stop_badges = decorator.subscribe(function() end)
    local key = nodes.norm(root .. "/" .. red)
    ok(decorator.get(key) ~= nil, "the badge of a spec file in a file view")
    eq(
      decorator.get(key, find(entry.root({}), "tests:file:" .. red)),
      nil,
      "... is not drawn on the node of the view, which says the same itself"
    )
    ok(
      decorator.get(key, { id = key, label = "red_spec.lua", path = key }) ~= nil,
      "... but on any other node"
    )
    stop_badges()

    -- the actions -------------------------------------------------------------------------------
    top = entry.root({})
    local by_name = {}
    for _, action in ipairs(entry.actions) do
      by_name[action.name] = action
    end
    local run, failed = by_name["tests.run"], by_name["tests.run_failed"]
    eq({ run.key, failed.key }, { "r", "R" }, "the keys of the view")
    eq(run.when({ id = "x", label = "x", kind = "note" }, {}), false, "run: not on a line of text")
    eq(run.when(find(top, "tests:file:" .. red), {}), true, "run: on a spec file")

    run.run({ find(top, "tests:file:" .. red) }, {})
    eq(runs[#runs], {
      root = root,
      flags = { file = { red } },
    }, "run on a file: that file, and no filter (a filtered file counts as run in part)")
    local case_id = red .. "::two"
    local case_node = find(top, "tests:case:" .. case_id)
    ok(case_node ~= nil, "the red case is a node")
    run.run({ case_node, find(top, "tests:file:" .. green) }, {})
    eq(runs[#runs].flags, {
      file = { red, green },
      filter = { case_id, green },
    }, "run on a case and a file: the case of the one, all of the other")
    run.run({ top }, {})
    eq(runs[#runs].flags, {}, "run on the root: everything")
    local count = #runs
    run.run({ { id = "x", label = "x" } }, {})
    eq(#runs, count, "run on a node of somebody else starts nothing")
    failed.run({}, {})
    eq(runs[#runs].flags, { raw = { "--lf" } }, "run failed: what failed last time")

    -- the preview -------------------------------------------------------------------------------
    case_node.data.testing.message = "expected 1, got 2"
    H.has(
      table.concat(entry.preview(case_node, {}).lines, "\n"),
      "expected 1, got 2",
      "the preview of a red case is what it said"
    )
    eq(
      entry.preview(find(top, "tests:file:" .. green), {}),
      nil,
      "no preview of its own for a green file"
    )

    -- the keys ------------------------------------------------------------------------------------
    tree.register(opts({ keys = { run = "gr", failed = false } }))
    eq(#registry.list("source"), 1, "registering again replaces the entry")
    by_name = {}
    for _, action in ipairs(registry.get("source", "tests").actions) do
      by_name[action.name] = action
    end
    eq(
      { by_name["tests.run"].key, by_name["tests.run_failed"].key },
      { "gr", nil },
      "keys from the options; false keeps an action without a key"
    )
    tree.unregister()
    eq(
      { registry.get("source", "tests"), registry.get("decorator", "tests"), tree.status() },
      { nil, nil, "not registered" },
      "unregister takes both out"
    )

    -- setup({ tree = ... }) -------------------------------------------------------------------------
    local _, problems =
      config.validate({ tree = { keys = { run = "gr", failed = { "R", "gR" } } } })
    eq(problems, {}, "tree: keys as an lhs or a list of them")
    _, problems = config.validate({ tree = false })
    eq(problems, {}, "tree: false")
    for name, bad in pairs({
      ["a number"] = 1,
      ["an unknown key"] = { colour = true },
      ["an unknown action"] = { keys = { walk = "w" } },
      ["an empty lhs"] = { keys = { run = "" } },
      ["an empty list"] = { keys = { run = {} } },
    }) do
      _, problems = config.validate({ tree = bad })
      eq(#problems, 1, "tree: " .. name .. " is refused")
    end
    eq(config.get().tree, true, "tree is on by default")
    config.setup({ tree = { keys = { run = "gr" } } })
    eq(config.get().tree, { keys = { run = "gr" } }, "tree: a table of keys is kept as given")
    config.setup({ tree = false })
    eq(config.get().tree, false, "tree: false is kept")
  end)
  finish()
  if not worked then
    error(err, 0)
  end
end
