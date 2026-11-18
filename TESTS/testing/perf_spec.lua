-- TESTS/testing/perf_spec.lua -- `testing perf` without a child editor: the spawn trace in this editor (install,
-- the folded records, uninstall), the line scan of spawn sites with lib.nvim's spawning modules and the coverage, the
-- findings and the report, the helpers of the run (fakes made real, the step of a moment), the `perf` field of the
-- feature catalog, the command line, the parser of the Windows sampler and the process tree, the priority.
-- The only program it starts is the editor running it (`--version`).
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
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-perf"
  vim.fn.mkdir(tmp, "p")
  local function write(rel, lines)
    local p = tmp .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    vim.fn.writefile(lines, p)
    return p
  end

  -- ── the trace, in this editor ─────────────────────────────────────────
  do
    local trace = require("testing.perf.trace")
    local out = tmp .. "/trace.jsonl"
    local before = { system = vim.system, spawn = vim.uv.spawn, fn_system = vim.fn.system }
    eq(
      { trace.install({}) },
      { false, "testing.perf.trace: opts.out is required" },
      "out is required"
    )
    assert(trace.install({ out = out, real = "xdg-open,network" }))
    ok(trace.installed(), "installed")
    ok(
      trace.real("network") and trace.real("XDG-OPEN") and not trace.real("browser"),
      "real() reads the list"
    )
    local exe = vim.v.progpath
    local obj = vim.system({ exe, "--version" }, { text = true })
    local done = obj:wait(20000)
    eq(done.code, 0, "vim.system still works")
    vim.fn.system({ exe, "--version" })
    local exited = false
    local job = vim.fn.jobstart({ exe, "--version" }, {
      on_exit = function()
        exited = true
      end,
    })
    ok(job > 0, "jobstart still works")
    vim.wait(20000, function()
      return exited
    end, 20)
    ok(exited, "the caller's on_exit still runs")
    trace.uninstall()
    trace.uninstall() -- twice is safe
    ok(not trace.installed(), "uninstalled")
    ok(vim.system == before.system and vim.uv.spawn == before.spawn, "the primitives are back")
    ok(vim.fn.system == before.fn_system, "vim.fn.system is back")

    local records = trace.read(out)
    eq(records[1].ev, "install", "the first line is the install")
    local spawns = trace.fold(records)
    eq(
      vim.tbl_map(function(s)
        return s.kind
      end, spawns),
      { "vim.system", "fn.system", "jobstart" },
      "one start each: vim.system and its uv.spawn are folded"
    )
    local sys, fsys, js = spawns[1], spawns[2], spawns[3]
    ok(sys.pid and sys.ms and sys.ms >= 0, "vim.system: pid and the end from the spawn's exit")
    ok(
      sys.sync == true and sys.blocked_ms ~= nil,
      "a wait() makes it synchronous with the blocked time"
    )
    ok(
      fsys.sync == true and fsys.blocked_ms and fsys.blocked_ms > 0,
      "vim.fn.system is synchronous"
    )
    ok(
      js.sync == false and js.ms ~= nil and js.pid ~= nil,
      "jobstart: asynchronous with its end and pid"
    )
    has(sys.argv, "--version", "the argv")
    has(sys.site or "", "perf_spec.lua", "the site is the line that asked")
    ok(
      type(sys.stack) == "table" and (sys.stack[1] or ""):find("perf_spec.lua", 1, true),
      "the stack of the start"
    )
    -- nothing after the uninstall
    vim.fn.system({ exe, "--version" })
    eq(#trace.fold(trace.read(out)), 3, "no start after the uninstall")
    -- io.popen ends when its handle closes, jobwait makes a job synchronous
    -- vim.lsp.start: an in-process client (cmd is a function) starts no process; its line is a reach
    local real_lsp_start = vim.lsp.start
    vim.lsp.start = function()
      return 1
    end
    local out2 = tmp .. "/trace2.jsonl"
    assert(trace.install({ out = out2 }))
    local fh = assert(io.popen(('"%s" --version'):format(exe)))
    has(fh:read("*a"), "NVIM", "the proxy reads like the file")
    fh:close()
    vim.lsp.start({ name = "inproc", cmd = function() end })
    local job2 = vim.fn.jobstart({ exe, "--version" })
    vim.fn.jobwait({ job2 }, 20000)
    vim.system({ exe, "--version" }, {}, function() end)
    trace.uninstall()
    ok(vim.lsp.start ~= real_lsp_start, "the stub is back, not the original")
    vim.lsp.start = real_lsp_start
    local s2 = trace.fold(trace.read(out2))
    local reach = trace.reaches(trace.read(out2))
    eq(reach[1] and reach[1].kind, "lsp.start(in-process)", "the in-process LSP client is a reach")
    ok((reach[1].stack[1] or ""):find("perf_spec.lua", 1, true), "with the line that asked")
    eq(s2[1].kind, "io.popen", "the popen")
    ok(
      s2[1].ms ~= nil and s2[1].blocked_ms ~= nil,
      "its close is its end, the editor waited until then"
    )
    ok(s2[2].sync == true and s2[2].blocked_ms ~= nil, "a jobwait makes the job synchronous")
    eq(s2[3].sync, false, "vim.system with a callback is asynchronous")
    ok(
      trace._is_runtime("@E:/repos/testing.nvim/lua/testing/guard/process_net.lua"),
      "the guard is no caller"
    )
    ok(not trace._is_runtime("@E:/repos/foo.nvim/lua/foo/init.lua"), "a plugin is")
    local refolded = trace.fold({
      { ev = "install" },
      { ev = "start", id = 1, us = 1, kind = "a", argv = "a" },
      { ev = "install" },
      { ev = "start", id = 1, us = 5, kind = "b", argv = "b" },
      { ev = "end", id = 1, us = 9, ms = 4 },
    })
    eq(
      { refolded[1].ms, refolded[2].ms },
      { nil, 4 },
      "a new child's ids start again: the end is the new one's"
    )
    eq(trace.repo_of("E:/repos/foo.nvim/lua/foo/init.lua"), "foo.nvim", "repo of a source")
    eq(
      trace.repo_of("C:/x/nvim-data/lazy/gitsigns.nvim/lua/gitsigns/a.lua"),
      "gitsigns.nvim",
      "lazy"
    )
  end

  -- ── the scan ───────────────────────────────────────────────────────────
  do
    local scan = require("testing.perf.scan")
    eq(scan.code_of("  -- vim.system({})"), nil, "a comment line")
    eq(
      scan.code_of('local a = "--x" -- vim.system()'),
      'local a = "--x" ',
      "text after -- outside a string"
    )
    eq(scan.match("vim.system({ 'git' }, {}, cb)"), "vim.system", "a primitive")
    eq(
      scan.match("local x = vim.fn.systemlist({ 'git' })"),
      "vim.fn.systemlist",
      "systemlist before system"
    )
    eq(scan.match("-- vim.fn.jobstart(cmd)"), nil, "not in a comment")
    eq(scan.match("function M.spawn(cmd, opts)"), nil, "a definition is no call")
    eq(scan.match("local function jobstart(cmd)"), nil, "a local definition neither")
    eq(
      scan.match("function M.go(a) return vim.system(a) end"),
      "vim.system",
      "the call inside it is"
    )
    -- the primitives in the forms the fleet writes them (terminal.nvim, 2026-11-18)
    eq(
      scan.match("local ok, res = pcall(fn.jobstart, cmd, job_opts)"),
      "pcall(jobstart)",
      "pcall(fn.jobstart"
    )
    eq(scan.match("local ok, p = pcall(vim.system, argv, {})"), "pcall(system)", "pcall(vim.system")
    eq(scan.match("local h = b.spawn(spec)"), nil, "a method named spawn is no uv.spawn")
    eq(scan.match("local h = uv.spawn(path, opts, cb)"), "uv.spawn", "uv.spawn is")
    eq(scan.match("local h = vim.uv.spawn(path, opts, cb)"), "uv.spawn", "vim.uv.spawn too")
    eq(
      scan.joined({ "  local ok, s = pcall(", "    vim.system,", "  )" }, 1),
      "  local ok, s = pcall(vim.system,",
      "a call wrapped after ( is joined"
    )
    eq(
      scan.joined({ "  return vim", "    .system(argv)" }, 1),
      "  return vim.system(argv)",
      "and after vim"
    )
    local lib = tmp .. "/lib.nvim"
    write("lib.nvim/lua/lib/nvim/run/init.lua", {
      "local M = {}",
      "function M.go(a) return vim.system(a) end",
      "local function helper(a)",
      "  return vim.fn.system(a)",
      "end",
      "function M.wrapped(a)",
      "  return helper(a)",
      "end",
      "function M.pure(a)",
      "  return a",
      "end",
      "return M",
    })
    write("lib.nvim/lua/lib/nvim/git/init.lua", {
      'local run = require("lib.nvim.run")',
      "local M = {}",
      "function M.status(dir)",
      "  return run.go({ 'git', '-C', dir, 'status' })",
      "end",
      "function M.root_of(path)",
      "  return run.pure(path)",
      "end",
      "return M",
    })
    write("lib.nvim/lua/lib/nvim/text/init.lua", {
      'local run = require("lib.nvim.run")',
      "return { upper = string.upper }",
    })
    local spawning = scan.spawning_modules(lib)
    ok(spawning["lib.nvim.run"].go, "a function with a primitive spawns (one line)")
    ok(spawning["lib.nvim.run"].wrapped, "one that calls a local function that does spawns too")
    ok(not spawning["lib.nvim.run"].pure, "one that does neither does not")
    ok(
      spawning["lib.nvim.git"].status,
      "one that calls a spawning function of a required module spawns"
    )
    ok(not spawning["lib.nvim.git"].root_of, "one that calls a pure function of it does not")
    eq(spawning["lib.nvim.text"], nil, "requiring a spawning module is not spawning")
    local root = tmp .. "/plug.nvim"
    write("plug.nvim/lua/plug/init.lua", {
      'local git = require("lib.nvim.git")',
      'local text = require("lib.nvim.text")',
      "local M = {}",
      "function M.a() return git.status({}) end",
      "function M.b() return text.upper('x') end",
      "function M.c() vim.fn.system({ 'ls' }) end",
      'function M.d() return require("lib.nvim.run").go({ "x" }) end',
      "-- git.status() in a comment",
      "function M.e() return git.root_of('x') end",
      'local resolve = require("lib.nvim.run").go',
      "function M.f()",
      "  local ok = pcall(",
      "    vim.system,",
      "    { 'x' }",
      "  )",
      "end",
      "return M",
    })
    local sites = scan.sites(root, spawning)
    eq(
      vim.tbl_map(function(s)
        return ("%s:%d %s %s %s"):format(
          s.file,
          s.line,
          s.what,
          tostring(s.tail_fn),
          tostring(s.span)
        )
      end, sites),
      {
        "lua/plug/init.lua:4 lib.nvim.git.status a nil",
        "lua/plug/init.lua:6 vim.fn.system nil nil",
        "lua/plug/init.lua:7 lib.nvim.run.go d nil",
        "lua/plug/init.lua:12 pcall(system) nil 2",
      },
      "primitives, spawning functions by alias and in place, a wrapped pcall; not a pure function, not a field read"
    )
    local cov = scan.coverage(sites, {
      -- the frames of a start: the alias call is three frames up (a wrapper of the plugin in between)
      {
        origin = root .. "/lua/plug/wrap.lua:2",
        site = lib .. "/lua/lib/nvim/run/init.lua:2",
        stack = {
          lib .. "/lua/lib/nvim/run/init.lua:2",
          root .. "/lua/plug/wrap.lua:2",
          (root .. "/lua/plug/init.lua:4"):upper(),
        },
      },
      { site = root .. "/lua/plug/init.lua:13" }, -- the wrapped pcall, reported on its next line
    }, root, true)
    eq(
      #cov.covered,
      2,
      "a frame up the stack counts, case-insensitive on Windows; a wrapped call on its next line"
    )
    eq(
      vim.tbl_map(function(s)
        return s.line
      end, cov.missing),
      { 6, 7 },
      "the ones not reached"
    )
    -- a tail call: its frame is gone, a caller of its function on a stack reaches it
    write(
      "plug.nvim/lua/plug/caller.lua",
      { "local M = {}", "function M.x() return require('plug').d() end", "return M" }
    )
    local tail = scan.coverage(sites, {
      {
        site = lib .. "/lua/lib/nvim/run/init.lua:2",
        stack = { root .. "/lua/plug/caller.lua:2" },
      },
    }, root, false)
    eq(
      vim.tbl_map(function(s)
        return s.line
      end, tail.covered),
      { 7 },
      "the tail call of M.d is reached through its caller"
    )
    local reached = scan.coverage(
      sites,
      {},
      root,
      false,
      { { stack = { root .. "/lua/plug/init.lua:6" } } }
    )
    eq(#reached.covered, 1, "a reach record (an in-process LSP client) counts too")
    eq(scan.relative("D:/other/x.lua:3", root), nil, "a place outside the root")
    -- a linked worktree: its main checkout from the .git file
    write("wt/.git", { "gitdir: E:/repos/plug.nvim/.git/worktrees/x1" })
    eq(
      require("testing.perf.run").main_checkout(tmp .. "/wt"),
      "E:/repos/plug.nvim",
      "the main checkout of a worktree"
    )
    eq(require("testing.perf.run").main_checkout(root), nil, "a plain folder is none")
  end

  -- ── the findings and the report ────────────────────────────────────────
  do
    local report = require("testing.perf.report")
    eq(
      report.program('"C:\\Program Files\\Git\\bin\\git.exe" status'),
      "git",
      "the program of a quoted path"
    )
    eq(report.program("/usr/bin/rg --files"), "rg", "of a POSIX path")
    ok(
      report.is_lsp("lua-language-server --stdio") and not report.is_lsp("git status"),
      "LSP names"
    )
    local steps = { { n = 1, action = "lua" }, { n = 2, action = "keys" } }
    ok(report.is_preparation({ plugin = "sheet", step = 2 }, steps), "the sheet's own start")
    ok(
      report.is_preparation({ plugin = "?", step = 1, argv = "git init" }, steps),
      "a lua step without a plugin"
    )
    ok(
      not report.is_preparation({ plugin = "?", step = 2, argv = "git init" }, steps),
      "a key step's is the plugin's"
    )
    local sh = {
      id = "p.view",
      feature = "p.view",
      steps = steps,
      spawns = {
        {
          plugin = "p",
          step = 2,
          argv = "git status",
          us = 1000,
          blocked_ms = 120,
          sync = true,
          origin = "a.lua:1",
        },
        {
          plugin = "p",
          step = 2,
          argv = "git status",
          us = 1500,
          sync = false,
          origin = "a.lua:1",
        },
        {
          plugin = "p",
          step = 2,
          argv = "git status",
          us = 900000000,
          sync = false,
          origin = "a.lua:1",
        },
        {
          plugin = "p",
          step = 2,
          argv = "rg x",
          us = 2000,
          peak = 400e6,
          cpu = 12,
          alive_at_end = true,
          origin = "b.lua:9",
        },
        { plugin = "p", step = 2, argv = "lua-language-server", us = 3000, alive_at_end = true },
        { plugin = "sheet", step = 1, argv = "git init", us = 10, blocked_ms = 999, sync = true },
      },
    }
    for i = 1, 4 do
      table.insert(
        sh.spawns,
        { plugin = "p", step = 2, argv = "fd " .. i, us = 5000 + i, origin = "c.lua:1" }
      )
    end
    local f = report.findings("p.nvim", sh)
    local by = {}
    for _, x in ipairs(f) do
      by[x.kind] = by[x.kind] or {}
      table.insert(by[x.kind], x)
    end
    eq(#by.freeze, 1, "one freeze (the sheet's own 999 ms is no finding)")
    eq(by.freeze[1].value, 120, "its value")
    eq(by.memory[1].value, 400, "memory in MB")
    eq(by.cpu[1].value, 12, "cpu")
    eq(#by.left, 1, "left running: not the language server")
    eq(by["repeat"][1].count, 1, "a repeat within 2 s, not the one 15 min later")
    eq(by.burst[1].value, 9, "nine starts of the plugin in one step")
    local sized = { id = "s", steps = { { n = 1, action = "keys" } }, spawns = {} }
    for _, size in ipairs({ "80x24", "120x40" }) do
      for i = 1, 3 do
        table.insert(
          sized.spawns,
          { plugin = "p", step = 1, size = size, argv = "x" .. size .. i, us = i }
        )
      end
    end
    eq(#report.findings("p", sized), 0, "three starts at each of two sizes are no burst")
    eq(f[1].kind, "freeze", "a freeze comes first")
    local rr = {
      repo = "p.nvim",
      root = "/x/p.nvim",
      sheets = { vim.tbl_extend("force", sh, { status = "pass", ms = 10 }) },
      unloadable = {},
      sites = {
        { file = "lua/a.lua", line = 1, what = "vim.system" },
        { file = "lua/z.lua", line = 3, what = "x" },
      },
      coverage = { covered = { {} }, missing = { { file = "lua/z.lua", line = 3, what = "x" } } },
      catalog = {
        { id = "p.view", title = "v" },
        { id = "p.copy", title = "c" },
        { id = "p.gui", title = "g", perf = "manual:opens a window" },
      },
    }
    local gaps = report.catalog_gaps(rr)
    eq(#gaps.without_sheet, 1, "one functionality without a sheet")
    eq(gaps.marked[1].perf, "manual:opens a window", "the marked one is listed, not a gap")
    local doc = report.document({
      started = "2026-11-18T00:00:00Z",
      machine = { host = "h", os = "o" },
      interval_ms = 500,
      roots = { rr },
    })
    eq(doc.schema, "testing-perf/1", "schema")
    eq(doc.repos[1].summary.preparation, 1, "the sheet's start counted apart")
    eq(doc.repos[1].summary.covered, 1, "covered sites")
    local md = report.markdown(doc)
    has(md, "| p.nvim | 1 (1/0/0/0) |", "the overview row")
    has(md, "Katalog-Features ohne Sheet: p.copy", "the gap")
    has(md, "- p.gui: manual:opens a window", "the marked one")
    has(md, "`lua/z.lua:3` x", "the missing site")
    local base = vim.deepcopy(doc)
    base.repos[1].summary.starts = base.repos[1].summary.starts + 4
    has(report.markdown(doc, base), "(-4)", "the comparison with a baseline")
  end

  -- ── the run's helpers ─────────────────────────────────────────────────
  do
    local run = require("testing.perf.run")
    eq({ run.split_fakes(nil, { "all" }) }, { nil, {} }, "no fakes")
    eq(
      { run.split_fakes({ "xdg-open", "open" }, nil) },
      { { "xdg-open", "open" }, {} },
      "nothing real"
    )
    eq(
      { run.split_fakes({ "xdg-open", "powershell.exe" }, { "powershell" }) },
      { { "xdg-open" }, { "powershell.exe" } },
      "by bare name"
    )
    eq({ run.split_fakes({ "xdg-open" }, { "ALL" }) }, { nil, { "xdg-open" } }, "all")
    local steps = { { n = 1, t0 = 100, t1 = 200 }, { n = 2, t0 = 250, t1 = 300 } }
    eq(run.step_of(steps, 50), "start", "before the first step")
    eq(run.step_of(steps, 150), 1, "inside a step")
    eq(run.step_of(steps, 220), 1, "between two: the one that ended")
    eq(run.step_of(steps, 400), "after", "after the last")
    eq(run.step_of({}, 1), "start", "no steps")
    local two = {
      { n = 1, size = "80x24", t0 = 100, t1 = 200 },
      { n = 2, size = "80x24", t0 = 250, t1 = 300 },
      { n = 1, size = "120x40", t0 = 500, t1 = 600 },
      { n = 2, size = "120x40", t0 = 650, t1 = 700 },
    }
    eq(
      { run.step_of(two, 400) },
      { "start", "120x40" },
      "before the first step of the second size: its start"
    )
    eq({ run.step_of(two, 620) }, { 1, "120x40" }, "between steps of a size")
    eq({ run.step_of(two, 680) }, { 2, "120x40" }, "inside a step, with its size")
    eq({ run.step_of(two, 800) }, { "after", "120x40" }, "after the last")
  end

  -- ── the catalog's perf field ──────────────────────────────────────────
  do
    local features = require("testing.sheet.features")
    ok(
      features.load_text(
        [[return { { id = "a", title = "x", perf = "user" }, { id = "b", title = "y", perf = "skip:not here" } }]],
        "f.lua"
      ),
      "user and skip:<why>"
    )
    for _, bad in ipairs({ "manual", "manual:", "skip:  ", "later", "manual:a\nb" }) do
      local c, err =
        features.load_text(("return { { id = 'a', title = 'x', perf = %q } }"):format(bad), "f.lua")
      ok(c == nil, "refused: " .. bad)
      has(err, '[1].perf is "user", "manual:<why>" or "skip:<why>"', "the message: " .. bad)
    end
  end

  -- ── the command line ──────────────────────────────────────────────────
  do
    local perf = require("testing.perf")
    local o = assert(perf.parse({
      "a",
      "--all",
      "/r",
      "--sheet",
      "s1",
      "--sheet=s2",
      "--real=git, network",
      "--interval",
      "250",
      "--json",
      "x.json",
    }))
    eq(o.roots, { "a" }, "roots")
    eq(o.all, "/r", "--all")
    eq(o.sheets, { "s1", "s2" }, "--sheet twice, also with =")
    eq(o.real, { "git", "network" }, "--real split and trimmed")
    eq(o.interval_ms, 250, "--interval")
    eq(
      { perf.parse({ "--interval", "5" }) },
      { nil, "--interval is a number of ms from 100 to 60000" },
      "a bad interval"
    )
    eq({ perf.parse({ "--json" }) }, { nil, "--json needs a value" }, "a flag without its value")
    eq({ perf.parse({ "--what" }) }, { nil, "unknown option --what" }, "an unknown flag")
    eq(
      { perf.parse({ "--keep-traces=x" }) },
      { nil, "--keep-traces takes no value" },
      "no value for a switch"
    )
    local lines = {}
    local sv = {
      out = function(s)
        lines[#lines + 1] = s
      end,
      err = function(s)
        lines[#lines + 1] = "ERR " .. s
      end,
      trust_check = function(root)
        return root:find("untrusted", 1, true) and "not trusted" or nil
      end,
    }
    eq(perf.main({ tmp .. "/untrusted" }, sv), 2, "every root refused: exit 2")
    has(table.concat(lines, "\n"), "not trusted", "the refusal is said")
    local priority = require("testing.priority")
    ok(priority.heavy({ "perf", "." }), "perf is a heavy run")
    ok(not priority.heavy({ "perf", "scan" }), "perf scan is not")
  end

  -- ── the process tree ──────────────────────────────────────────────────
  do
    local tree = require("testing.perf.tree")
    eq(tree.parse_line("no json"), nil, "not a sample")
    local one = tree.parse_line(
      '{"procs":{"pid":5,"ppid":1,"name":"git.exe","ws":1000,"peak":2000,"cpu":0.5,"cmd":"git --token abc status"}}'
    )
    eq(#one, 1, "a single process as an object")
    eq(one[1].name, "git.exe", "its name")
    local all = {
      [1] = { pid = 1, ppid = 0 },
      [2] = { pid = 2, ppid = 1 },
      [3] = { pid = 3, ppid = 2 },
      [4] = { pid = 4, ppid = 9 },
    }
    eq(
      vim.tbl_map(function(p)
        return p.pid
      end, tree.descendants(all, 1)),
      { 2, 3 },
      "the descendants, not the stranger"
    )
    local per = tree.per_process({
      { us = 1, procs = { { pid = 7, name = "rg", ws = 10, peak = 0, cpu = 1 } } },
      { us = 2, procs = { { pid = 7, name = "rg", ws = 30, peak = 20, cpu = 2 } } },
    })
    eq(
      { per[7].first_us, per[7].last_us, per[7].ws, per[7].peak, per[7].cpu },
      { 1, 2, 30, 30, 2 },
      "per process"
    )
    local T = setmetatable({ list = {}, base = 0 }, { __index = tree._Tree })
    for i = 1, 5 do
      T.list[i] = { us = i, procs = {} }
    end
    T:forget(3)
    eq({ T:count(), #T.list, T.base }, { 5, 2, 3 }, "forgotten samples still count for the marks")
    eq(
      vim.tbl_map(function(x)
        return x.us
      end, T:between(3, 5)),
      { 4, 5 },
      "a window after the forgotten ones"
    )
    eq(#T:between(1, 4), 1, "a window that starts in the forgotten part keeps what is left")
    if vim.uv.fs_stat("/proc/self/stat") then
      local procs = tree.read_proc()
      ok(procs[vim.uv.os_getpid()] ~= nil, "/proc has this editor")
      local mine = tree.enrich({ procs[vim.uv.os_getpid()] })
      ok(mine[1].peak > 0 and mine[1].cmd ~= "", "enrich adds the peak and the command line")
    end
  end

  vim.fn.delete(tmp, "rf")
end
