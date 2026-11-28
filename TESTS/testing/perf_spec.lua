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
    local obj = vim.system({ exe, "--version" }, { text = true, cwd = tmp })
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
    local function slash(p)
      return (p:gsub("[/\\]+", "/"):lower())
    end
    eq(slash(spawns[1].cwd or ""), slash(tmp), "cwd: the directory a vim.system was given")
    eq(slash(spawns[2].cwd or ""), slash(vim.uv.cwd()), "cwd: else the editor's")
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
    ok(js.ms ~= nil and js.pid ~= nil, "jobstart: its end and pid")
    -- the vim.wait above that waits for its exit is the editor waiting for it (the keys wait too)
    ok(
      js.sync == true and (js.blocked_ms or 0) > 0,
      "jobstart: the vim.wait for its exit counts as waiting"
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
    -- the common form without a close: the end of the output is the end
    has(assert(io.popen(('"%s" --version'):format(exe))):read("*a"), "NVIM", "read without close")
    -- a poll (timeout 0) of a job still running does not make it synchronous
    local job3 =
      vim.fn.jobstart({ exe, "--headless", "-u", "NONE", "-c", "sleep 300m", "-c", "qa!" })
    eq(vim.fn.jobwait({ job3 }, 0)[1], -1, "the job still runs at the poll")
    vim.fn.jobwait({ job3 }, 20000)
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
    eq(s2[4].kind, "io.popen", "the second popen")
    ok(s2[4].ms ~= nil, "it ended at the end of its output, without a close")
    eq(s2[5].kind, "jobstart", "the polled job")
    local waits = 0
    for _, r in ipairs(trace.read(out2)) do
      if r.ev == "wait" and r.id == s2[5].id then
        waits = waits + 1
      end
    end
    eq(waits, 1, "one wait: the poll that found it running is none")
    ok(
      s2[5].blocked_ms ~= nil and s2[5].blocked_ms > 200,
      "the blocking wait after the poll counts, the poll adds nothing"
    )
    ok(
      trace._is_runtime("@E:/repos/testing.nvim/lua/testing/guard/process_net.lua"),
      "the guard is no caller"
    )
    ok(not trace._is_runtime("@E:/repos/foo.nvim/lua/foo/init.lua"), "a plugin is")
    -- runtime-analysis's telemetry: the wrappers it builds are no caller, its commands are (they start processes)
    local ra = "@E:/repos/runtime-analysis.nvim/lua/runtime-analysis/telemetry/"
    ok(
      trace._is_runtime(ra .. "registry.lua"),
      "telemetry: the wrapper of registry.lua is no caller"
    )
    ok(trace._is_runtime(ra .. "init.lua"), "telemetry: nor that of init.lua")
    ok(
      not trace._is_runtime(ra .. "command.lua"),
      "telemetry: :RATelemetry (command.lua) is a caller"
    )
    ok(not trace._is_runtime(ra .. "report.lua"), "telemetry: so is the report")
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
    local waited = trace.fold({
      { ev = "start", id = 1, us = 1, kind = "jobstart", argv = "cmd", sync = false },
      { ev = "wait", id = 1, us = 2, ms = 3 },
      { ev = "end", id = 1, us = 9, ms = 833 },
      { ev = "start", id = 2, us = 1, kind = "fn.system", argv = "git", sync = true },
      { ev = "end", id = 2, us = 9, ms = 120 },
    })
    eq(
      { waited[1].blocked_ms, waited[1].ms, waited[2].blocked_ms },
      { 3, 833, 120 },
      "a job's end does not turn its short wait into its whole run; a synchronous call blocked as long as it ran"
    )
    eq(trace.repo_of("E:/repos/foo.nvim/lua/foo/init.lua"), "foo.nvim", "repo of a source")
    eq(
      trace.repo_of("C:/x/nvim-data/lazy/gitsigns.nvim/lua/gitsigns/a.lua"),
      "gitsigns.nvim",
      "lazy"
    )
  end

  -- ── the trace: a vim.wait while a started process runs is the editor waiting for it ──
  do
    local trace = require("testing.perf.trace")
    local out = tmp .. "/trace-wait.jsonl"
    assert(trace.install({ out = out }))
    local exe = vim.v.progpath
    local slow =
      { exe, "--headless", "-u", "NONE", "-n", "-i", "NONE", "+lua vim.uv.sleep(300)", "+qa!" }
    -- insights.nvim: start with a callback, then pump vim.wait until it came (the keys wait all that time)
    local done = false
    vim.system(slow, { text = true }, function()
      done = true
    end)
    vim.wait(20000, function()
      return done
    end, 10)
    -- a vim.wait with no process running (a timer) is no process's freeze
    vim.wait(150, function()
      return false
    end, 10)
    -- :wait() runs vim.wait itself: counted once
    local obj = vim.system(slow, { text = true })
    obj:wait(20000)
    trace.uninstall()
    ok(vim.wait ~= nil and not trace.installed(), "vim.wait is back")
    local records = trace.read(out)
    local spawns = trace.fold(records)
    eq(#spawns, 2, "two starts")
    ok(
      (spawns[1].blocked_ms or 0) >= 100,
      "vim.wait for the callback: blocked (" .. tostring(spawns[1].blocked_ms) .. " ms)"
    )
    eq(spawns[1].sync, true, "... and counted as waited for")
    local by_vim_wait = 0
    for _, r in ipairs(records) do
      if r.ev == "wait" and r.by == "vim.wait" then
        by_vim_wait = by_vim_wait + 1
      end
    end
    eq(by_vim_wait, 1, "one vim.wait record: not the timer's, not the one inside :wait()")
    ok(
      (spawns[2].blocked_ms or 0) <= (spawns[2].ms or 0) + 50,
      "wait(): blocked once, not twice ("
        .. tostring(spawns[2].blocked_ms)
        .. " of "
        .. tostring(spawns[2].ms)
        .. " ms)"
    )
    local f = require("testing.perf.report").findings("p.nvim", {
      id = "w",
      steps = { { n = 1, action = "keys" } },
      spawns = { vim.tbl_extend("force", spawns[1], { plugin = "p", step = 1 }) },
    })
    eq(#vim.tbl_filter(function(x)
      return x.kind == "freeze"
    end, f), 1, "a freeze for the vim.wait")
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
    -- vim.fn through a name of the file: `local fn = vim.fn` -> `fn.system(`, `local system = vim.fn.system` ->
    -- `system(` (mdview.nvim, reposcope.nvim)
    do
      local file = {
        "local fn = vim.fn",
        "local system = vim.fn.system",
        "local M = {}",
        "function M.a() return fn.system({ 'curl', 'x' }) end",
        "function M.b() local out = fn.systemlist({ 'git', 'log' }) end",
        "function M.c() local r = system('ls') end",
        "function M.d() local f = fn.system end",
        "function M.e() other.system('x') end",
        "return M",
      }
      local al = scan.vim_fn_aliases(file)
      local ctx = { tables = al.tables, funcs = al.funcs }
      eq(scan.match(file[4], ctx), "vim.fn.system", "fn.system( through local fn = vim.fn")
      eq(scan.match(file[5], ctx), "vim.fn.systemlist", "fn.systemlist( too")
      eq(scan.match(file[6], ctx), "vim.fn.system", "system( through local system = vim.fn.system")
      eq(scan.match(file[7], ctx), nil, "a field read fn.system without a call is none")
      eq(scan.match(file[8], ctx), nil, "M.system of another module is none")
      eq(scan.match(file[4]), nil, "without the aliases of the file: none (as before)")
      -- vim.system under a name: `local system = (opts.system or vim.system)`, then `pcall(system, ...)` on the next
      -- line (testing.nvim's own bindings/child.lua), and the bare alias (the nvim config)
      local sys = {
        "  local system = (opts.system or vim.system) --[[@as function]]",
        "  local ok, started =",
        "    pcall(system, argv, { cwd = root }, finish)",
        "local run = vim.system",
        "  run({ 'git', 'clone', url, target }, {}, cb)",
        "local other = opts.run or helper.go",
        "  other({ 'x' })",
      }
      local sa = scan.vim_fn_aliases(sys)
      local sctx = { tables = sa.tables, funcs = sa.funcs }
      eq(
        scan.match(sys[3], sctx),
        "vim.system",
        "pcall(system, ...) after (opts.system or vim.system)"
      )
      eq(scan.match(sys[5], sctx), "vim.system", "run( after local run = vim.system")
      eq(scan.match(sys[7], sctx), nil, "a name bound to something else is none")
      -- a spawning function of a module alias handed to pcall as a value (ai.nvim's transport)
      local mctx = {
        aliases = { curl = "lib.nvim.net.curl" },
        spawning = { ["lib.nvim.net.curl"] = { fetch_json = true, fetch_stream = true } },
      }
      eq(
        scan.match("  local ok = pcall(curl.fetch_json, url, {}, cb)", mctx),
        "lib.nvim.net.curl.fetch_json",
        "pcall(curl.fetch_json, ...)"
      )
      eq(
        scan.match("  local ok, p = pcall(curl.fetch_stream, url, {", mctx),
        "lib.nvim.net.curl.fetch_stream",
        "pcall(curl.fetch_stream, ... on a wrapped line"
      )
      eq(
        scan.match("  local ok = pcall(curl.encode, x)", mctx),
        nil,
        "pcall of a function of the module that starts nothing: none"
      )
    end
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
    -- round 3 (findings of the second wave)
    eq(
      scan.match('error("vim.system() is missing")'),
      nil,
      "a primitive inside a string is no call"
    )
    eq(
      scan.strip_strings('a("x(") .. b'),
      'a("  ") .. b',
      "string contents are blanked, the quotes stay"
    )
    eq(
      scan.match("local ok, r = xpcall(vim.system, debug.traceback, argv)"),
      "pcall(system)",
      "xpcall too"
    )
    eq(
      { scan.alias_of('local ok, git = pcall(require, "lib.nvim.git")') },
      { "git", "lib.nvim.git" },
      "pcall(require)"
    )
    ok(
      not scan.is_tail("  return vim.system(argv, opts):wait()"),
      "a chained method is the tail call, not the site"
    )
    ok(scan.is_tail("  return git.status(dir)"), "a plain return of a call is one")
    local root3 = tmp .. "/plug3.nvim"
    write("plug3.nvim/lua/plug3/init.lua", {
      'local ok, git = pcall(require, "lib.nvim.git")',
      "local status = git.status",
      "local M = {}",
      "M.request = git.status",
      "local function inner()",
      "  return git.status('.')",
      "end",
      "function M.open()",
      "  return git.status('x')",
      "end",
      "function M.a() return status('.') end",
      "function M.b() return M.request('.') end",
      "function M.c() return inner() end",
      "return M",
    })
    local s3 = scan.sites(root3, spawning)
    eq(
      vim.tbl_map(function(s)
        return ("%d %s %s %s"):format(s.line, s.what, tostring(s.tail_fn), tostring(s.tail_local))
      end, s3),
      {
        "6 lib.nvim.git.status inner true",
        "9 lib.nvim.git.status open nil",
        "11 lib.nvim.git.status a nil",
        "12 lib.nvim.git.status b nil",
      },
      "a pcall(require) alias, a function alias and a field alias are sites; the tail kind is kept"
    )
    write(
      "plug3.nvim/lua/plug3/other.lua",
      { "local function inner() end", "return function() inner() vim.ui.open('x') end" }
    )
    local t3 = scan.coverage(s3, {
      { site = "x", stack = { root3 .. "/lua/plug3/other.lua:2" } },
    }, root3, false)
    eq(
      #t3.covered,
      0,
      "an unqualified call in another file is not the local function; open( unqualified is no field call"
    )
    local t4 = scan.coverage(s3, {
      { site = "x", stack = { root3 .. "/lua/plug3/init.lua:13" } },
    }, root3, false)
    eq(
      vim.tbl_map(function(s)
        return s.line
      end, t4.covered),
      { 6 },
      "inner() in its own file reaches the local function's tail call"
    )
    -- round 4 (review of rounds 2 and 3)
    ok(
      scan.is_tail('  return git.run_async(("log %s"):format(ref), cb)'),
      "a method in the arguments is no chain"
    )
    ok(
      not scan.is_tail("  return cmd and vim.fn.system(cmd)"),
      "an operator before the call is no tail call"
    )
    ok(scan.is_tail('  return require("m").f(x)'), "require(...).f( is one callee")
    ok(scan.is_tail("  return git.status("), "a call going on over the next lines")
    write("lib.nvim/lua/lib/nvim/tbl/init.lua", {
      "local function run(a)",
      "  return vim.system(a)",
      "end",
      "local function open(p)",
      "  return p",
      "end",
      "local function read(p)",
      "  return io.open(p)",
      "end",
      "return { run = run, read = read }",
    })
    write("lib.nvim/lua/lib/nvim/reexp/init.lua", {
      'local tbl = require("lib.nvim.tbl")',
      "local M = {}",
      'M.go = require("lib.nvim.run").go',
      "M.run = tbl.run",
      "return M",
    })
    -- a fresh cache key: a copy of the library with the two new modules
    vim.fn.mkdir(tmp .. "/lib4.nvim", "p")
    for _, rel in ipairs({ "run", "git", "text", "tbl", "reexp" }) do
      local from = tmp .. "/lib.nvim/lua/lib/nvim/" .. rel .. "/init.lua"
      write("lib4.nvim/lua/lib/nvim/" .. rel .. "/init.lua", vim.fn.readfile(from))
    end
    local sp4 = scan.spawning_modules(tmp .. "/lib4.nvim")
    ok(
      sp4["lib.nvim.tbl"] and sp4["lib.nvim.tbl"].run,
      "a module returning a table exports its local functions"
    )
    ok(not (sp4["lib.nvim.tbl"] or {}).read, "io.open( is no call of a local open")
    ok(
      sp4["lib.nvim.reexp"] and sp4["lib.nvim.reexp"].go and sp4["lib.nvim.reexp"].run,
      "re-exports spawn as their target"
    )
    local root4 = tmp .. "/plug4.nvim"
    write("plug4.nvim/lua/plug4/init.lua", {
      'local git = require("lib.nvim.git")',
      "local M = {}",
      "M.request = git.status",
      "function M.run(c)",
      "  local opts = {}",
      "  opts.on_exit = function(r)",
      "    return r",
      "  end",
      "  return vim.system(c, opts)",
      "end",
      "function M.a() return M.request('.') end",
      "function M.b(client) return client:request('x') end",
      'function M.c() print("git.status(") end',
      "function M.d()",
      "  return wrap(",
      "    vim.system({ 'x' })",
      "  )",
      "end",
      "return M",
    })
    eq(
      vim.tbl_map(function(s)
        return ("%d %s"):format(s.line, tostring(s.tail_fn))
      end, scan.sites(root4, sp4)),
      { "9 run", "11 a", "16 nil" },
      "the function around a site is the top-level one; a field alias only on its table; no site in a string; no double site"
    )
    -- a linked worktree: its main checkout from the .git file
    write("wt/.git", { "gitdir: E:/repos/plug.nvim/.git/worktrees/x1" })
    eq(
      require("testing.perf.run").main_checkout(tmp .. "/wt"),
      "E:/repos/plug.nvim",
      "the main checkout of a worktree"
    )
    eq(require("testing.perf.run").main_checkout(root), nil, "a plain folder is none")
    -- a relative gitdir (worktree.useRelativePaths)
    vim.fn.mkdir(tmp .. "/main5/.git/worktrees/w", "p")
    write("main5/wt/.git", { "gitdir: ../.git/worktrees/w" })
    eq(
      vim.fs.basename(require("testing.perf.run").main_checkout(tmp .. "/main5/wt") or ""),
      "main5",
      "a relative gitdir is resolved from the worktree"
    )
    vim.env.PERF_SPEC_X_DIR = "x"
    require("testing.perf.run").restore_deps({ "PERF_SPEC_X_DIR" })
    eq(vim.env.PERF_SPEC_X_DIR, nil, "what provide_deps set is unset again")
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
    -- left: a start that ended before the end of the last step is not left, even when the last sample (up to an
    -- interval earlier) still saw it; one that ends after it is; without an end, the last sample decides
    local run_mod = require("testing.perf.run")
    local alive = { [7] = true }
    local t_end = 10e6
    eq(
      run_mod.alive_at_end({ pid = 7, us = 9e6, ms = 790 }, alive, t_end),
      false,
      "left: ended 210 ms before the end, though the last sample saw it"
    )
    eq(
      run_mod.alive_at_end({ pid = 7, us = 9e6, ms = 1500 }, alive, t_end),
      true,
      "left: ended after the last step"
    )
    eq(
      run_mod.alive_at_end({ pid = 7, us = 9e6 }, alive, t_end),
      true,
      "left: no end, in the last sample"
    )
    eq(run_mod.alive_at_end({ pid = 8, us = 9e6 }, alive, t_end), false, "left: no end, not in it")
    eq(by["repeat"][1].count, 1, "a repeat within 2 s, not the one 15 min later")
    -- the same command in another directory is no repeat (`rustc --print sysroot` answers per project), in the same
    -- one it is
    local function repeats(cwd_b)
      local f2 = report.findings("p.nvim", {
        id = "c",
        steps = { { n = 1, action = "lua" } },
        spawns = {
          { plugin = "p", step = 1, argv = "rustc --print sysroot", cwd = "/a", us = 1000 },
          { plugin = "p", step = 1, argv = "rustc --print sysroot", cwd = cwd_b, us = 90000 },
        },
      })
      return #vim.tbl_filter(function(x)
        return x.kind == "repeat"
      end, f2)
    end
    eq(repeats("/b"), 0, "repeat: the same argv in another cwd is none")
    eq(repeats("/a"), 1, "repeat: the same argv in the same cwd is one")
    -- the same command with another text on stdin is no repeat (a filter, casedesk.nvim); with the same text it is;
    -- a stdin written later (`?`) is never the same
    local function stdin_repeats(a, b)
      local f3 = report.findings("p.nvim", {
        id = "i",
        steps = { { n = 1, action = "lua" } },
        spawns = {
          { id = 1, plugin = "p", step = 1, argv = "nvim --clean -l f.lua", stdin = a, us = 1000 },
          { id = 2, plugin = "p", step = 1, argv = "nvim --clean -l f.lua", stdin = b, us = 9000 },
        },
      })
      return #vim.tbl_filter(function(x)
        return x.kind == "repeat"
      end, f3)
    end
    eq(stdin_repeats("5:0a1b2c3d", "7:00ffee11"), 0, "repeat: another stdin is none")
    eq(stdin_repeats("5:0a1b2c3d", "5:0a1b2c3d"), 1, "repeat: the same stdin is one")
    eq(stdin_repeats("?", "?"), 0, "repeat: a stdin written later is never the same")
    -- one call site asking two repositories: one line per command, each with its own count (gitsuite.nvim)
    local two = {}
    for i, r in ipairs({ "/r/alpha", "/r/bravo", "/r/alpha", "/r/bravo", "/r/alpha" }) do
      two[#two + 1] = {
        plugin = "p",
        step = 1,
        argv = "git -C " .. r .. " status",
        origin = "status.lua:222",
        us = 1000 + i * 100,
      }
    end
    local rep = vim.tbl_filter(
      function(x)
        return x.kind == "repeat"
      end,
      report.findings("p.nvim", { id = "r", steps = { { n = 1, action = "keys" } }, spawns = two })
    )
    local counts = {}
    for _, x in ipairs(rep) do
      counts[x.argv] = x.count
    end
    eq(
      counts,
      { ["git -C /r/alpha status"] = 2, ["git -C /r/bravo status"] = 1 },
      "repeat: one line per repository, with its own count"
    )
    -- the trace keeps a digest of a text on stdin, never the text
    local trace = require("testing.perf.trace")
    eq(trace.stdin_of("abc"), trace.digest("abc"), "stdin_of: a text is its digest")
    eq(trace.stdin_of({ "a", "b" }), trace.digest("a\nb"), "stdin_of: lines joined")
    eq(trace.stdin_of(true), "?", "stdin_of: written later")
    eq(trace.stdin_of(nil), nil, "stdin_of: none")
    ok(trace.digest("abc") ~= trace.digest("abd"), "digest: another text, another digest")
    eq(trace.digest(("x"):rep(100000)):match("^(%d+):"), "100000", "digest: with the length")
    -- a git that changes the repository between two reads makes the second read needed (filetree.nvim: status,
    -- `git add`, status); two reads with only reads between are a repeat
    local function git_repeats(between)
      local spawns = {
        { plugin = "p", step = 1, argv = "git -C /r status --porcelain", cwd = "/x", us = 1000 },
      }
      for i, a in ipairs(between) do
        spawns[#spawns + 1] = { plugin = "p", step = 1, argv = a, cwd = "/x", us = 1000 + i * 10 }
      end
      spawns[#spawns + 1] =
        { plugin = "p", step = 1, argv = "git -C /r status --porcelain", cwd = "/x", us = 90000 }
      return #vim.tbl_filter(
        function(x)
          return x.kind == "repeat"
        end,
        report.findings("p.nvim", {
          id = "g",
          steps = { { n = 1, action = "keys" } },
          spawns = spawns,
        })
      )
    end
    eq(git_repeats({ "git -C /r add -- a.txt" }), 0, "repeat: a git add between two status: none")
    eq(
      git_repeats({ "git -c core.quotepath=off -C /r reset -q -- a.txt" }),
      0,
      "... a reset neither"
    )
    eq(git_repeats({}), 1, "repeat: two status alone: one")
    eq(
      git_repeats({ "git -C /r log -1", "git -C /r rev-parse HEAD" }),
      1,
      "... reads between: still one"
    )
    eq(git_repeats({ "git -C /other add x" }), 1, "... a write in another repository: still one")
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
