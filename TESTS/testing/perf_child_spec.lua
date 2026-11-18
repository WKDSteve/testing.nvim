-- TESTS/testing/perf_child_spec.lua -- `testing perf` with REAL child editors: `preload` installs the spawn trace
-- before the minit (a start of the minit is seen, a start of an RPC chunk is the sheet's own), a preload that fails
-- ends the start with its reason, and `testing.perf.run.run_root` over a fixture project with one sheet: the step of
-- each start, the sheet's preparation apart from the plugin's start, the coverage of the plugin's site.
-- The only programs it starts are editors (the one running it, `--version`).
-- @cache-allow spawn

---@diagnostic disable: missing-fields, need-check-nil

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
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 800))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local trace = require("testing.perf.trace")
  local exe = vim.fs.normalize(vim.v.progpath)

  S.run(function()
    -- 1. preload: the trace is in place before the minit runs
    do
      local project = S.new_dir()
      local out = project .. "/trace.jsonl"
      vim.fn.writefile({
        ("vim.fn.system({ %q, '--version' })"):format(exe),
      }, project .. "/minit.lua")
      local child = S.spawn({
        root = project,
        minit = project .. "/minit.lua",
        preload = { { module = "testing.perf.trace", opts = { out = out } } },
      })
      child.lua(("vim.fn.system({ %q, '--version' })"):format(exe))
      child.kill()
      local spawns = trace.fold(trace.read(out))
      eq(#spawns, 2, "the minit's start and the chunk's start")
      has(spawns[1].site or "", "minit.lua", "the minit's start has its file")
      eq(spawns[2].plugin, "sheet", "a start of an RPC chunk is the sheet's own")
      ok(spawns[2].sync and spawns[2].blocked_ms, "vim.fn.system: synchronous, with its time")
    end

    -- 2. a preload that fails ends the start with its reason
    do
      local child, err = require("testing.rpc").spawn({
        root = S.new_dir(),
        guard = false,
        preload = { { module = "testing.perf.trace", opts = {} } },
      })
      ok(child == nil, "no child")
      has(tostring(err), "preload 1 (testing.perf.trace) failed", "the reason names the preload")
    end

    -- 3. run_root over a project with one sheet
    do
      local root = S.new_dir() .. "/proj.nvim"
      vim.fn.mkdir(root .. "/lua/proj", "p")
      vim.fn.mkdir(root .. "/TESTS/sheets", "p")
      vim.fn.writefile({ "return {}" }, root .. "/.testing.lua")
      vim.fn.writefile({
        "local M = {}",
        "function M.go()",
        ("  return vim.system({ %q, '--version' }):wait()"):format(exe),
        "end",
        "function M.never()",
        "  return vim.fn.system({ 'never' })",
        "end",
        "return M",
      }, root .. "/lua/proj/init.lua")
      vim.fn.writefile({
        ("vim.opt.rtp:prepend(%q)"):format(root),
      }, root .. "/TESTS/minimal_init.lua")
      vim.fn.writefile({
        "return {",
        '  id = "proj.go",',
        '  title = "go starts the editor",',
        '  feature = "proj.go",',
        "  steps = {",
        ("    { lua = \"vim.fn.system({ '%s', '--version' })\", note = \"prepare\" },"):format(exe),
        "    { lua = \"require('proj').go()\" },",
        "  },",
        "}",
      }, root .. "/TESTS/sheets/go.sheet.lua")
      vim.fn.writefile({
        "return {",
        '  { id = "proj.go", title = "go" },',
        '  { id = "proj.gui", title = "a window", perf = "manual:opens a window" },',
        "}",
      }, root .. "/TESTS/sheets/features.lua")
      local fake_tree = {
        count = function()
          return 0
        end,
        between = function()
          return {}
        end,
        error = "no tree in this spec",
      }
      local rr = require("testing.perf.run").run_root(root, {
        dir = S.new_dir(),
        tree = fake_tree,
        lib_root = S.new_dir(), -- no library: only primitives are sites
      })
      eq(#rr.sheets, 1, "one sheet ran")
      local sh = rr.sheets[1]
      eq(sh.status, "pass", "it passed: " .. table.concat(sh.failures or {}, "; "))
      eq(#sh.steps, 2, "its two steps, with their bounds")
      eq(#sh.spawns, 2, "two starts")
      eq({ sh.spawns[1].step, sh.spawns[1].plugin }, { 1, "sheet" }, "the preparation, in step 1")
      eq(
        { sh.spawns[2].step, sh.spawns[2].plugin },
        { 2, "proj.nvim" },
        "the plugin's start, in step 2"
      )
      ok(sh.spawns[2].sync and sh.spawns[2].blocked_ms, "its wait() blocked the editor")
      eq(#rr.sites, 2, "two sites in the plugin")
      eq(#rr.coverage.covered, 1, "the one the sheet reached")
      eq(rr.coverage.missing[1].line, 6, "M.never is not reached")
      local report = require("testing.perf.report")
      local doc = report.document({
        started = "x",
        machine = { host = "h", os = "o" },
        interval_ms = 500,
        roots = { rr },
      })
      eq(doc.repos[1].summary.preparation, 1, "the preparation counted apart")
      eq(doc.repos[1].catalog.marked[1].id, "proj.gui", "the marked functionality")
    end
  end)
end
