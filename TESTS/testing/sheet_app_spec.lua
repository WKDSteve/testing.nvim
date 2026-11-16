-- TESTS/testing/sheet_app_spec.lua -- the program a sheet runs against (testing.sheet.app, `sheets.apps` of
-- .testing.lua): the description is checked, build and ready and stop, nothing of it left behind, and
-- `testing sheets run --all` with its Result-IR. A real page where node, playwright-core and chromium exist.
-- @cache-allow time processes
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

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
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local app = require("testing.sheet.app")
  local session_mod = require("testing.sheet.session")
  local run_cli = require("testing.sheet.run")
  local browser = require("testing.sheet.browser")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-app"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function write(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end

  -- the program: says where its page is, writes where it runs and its pid, waits
  write(
    "fake_app.lua",
    [[
local mode, dir = _G.arg[1], _G.arg[2]
local f = assert(io.open(os.getenv("APP_DIR") .. "/seen", "wb"))
f:write(tostring(vim.fn.getpid()), "\n", dir, "\n")
f:close()
local out = assert(io.open(_G.arg[3], "ab"))
out:write(tostring(vim.fn.getpid()), "\n", dir, "\n")
out:close()
if mode == "die" then
  io.stderr:write("no sound card\n")
  os.exit(4)
end
if mode ~= "silent" then
  io.stdout:write("starting up\n")
  io.stdout:write("  file:///" .. _G.arg[4] .. "  \n")
  io.stdout:flush()
end
vim.wait(120000)
]]
  )
  local page = write(
    "page.html",
    '<!doctype html><title>the app</title><button id="a">A</button><button id="b">B</button>'
  )
  local nvim = vim.v.progpath:gsub("\\", "/")
  local log = root .. "/app.log"
  local link_log = root .. "/link.log"
  -- the program of `start = "link"`: writes its pid, the kind of each standard handle (GetFileType: 3 is a pipe) and
  -- the folder of the run it found in its environment
  write(
    "fake_link.lua",
    [[
local kinds = {}
if jit.os == "Windows" then
  local ffi = require("ffi")
  ffi.cdef("void *GetStdHandle(uint32_t which); uint32_t GetFileType(void *h);")
  for i, which in ipairs({ -10, -11, -12 }) do
    kinds[i] = tostring(ffi.C.GetFileType(ffi.C.GetStdHandle(which)))
  end
end
local out = assert(io.open(_G.arg[2], "ab"))
out:write(tostring(vim.fn.getpid()), " ", table.concat(kinds, ","), " ", tostring(os.getenv("LINK_SEEN")), "\n")
out:close()
if _G.arg[1] == "early" then
  os.exit(0)
end
vim.wait(120000)
]]
  )
  local function app_entry(mode, extra)
    return vim.tbl_extend("force", {
      run = {
        nvim,
        "--headless",
        "-u",
        "NONE",
        "-l",
        "fake_app.lua",
        mode,
        "${temp}",
        log,
        page,
      },
      env = { APP_DIR = "${temp}" },
      ready = { stdout = "^%s*file:", as = "link", timeout_ms = 20000 },
    }, extra or {})
  end
  write(".testing.lua", "return { sheets = { apps = " .. vim.inspect({
    good = app_entry("good"),
    dies = app_entry("die"),
    silent = app_entry("silent", { ready = { stdout = "^ready", timeout_ms = 300 } }),
    built = app_entry(
      "good",
      { build = { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "fine" } }
    ),
    unbuilt = app_entry(
      "good",
      { build = { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "broken" } }
    ),
    multi = app_entry("good", {
      build = {
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "fine" },
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "second" },
      },
    }),
    multifail = app_entry("good", {
      build = {
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "fine" },
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "broken" },
      },
    }),
    shim = app_entry("good", { build = { "shim-tool" } }),
    shimbad = app_entry("good", { build = { "shim-tool", "a&b" } }),
    prepared = app_entry("good", {
      prepare = {
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "into", "${temp}" },
        { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "check", "${temp}" },
      },
    }),
    cleaned = app_entry("good", {
      cleanup = { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "cleanup", "${temp}" },
    }),
    prepfail = app_entry("good", {
      prepare = { nvim, "--headless", "-u", "NONE", "-l", "fake_build.lua", "broken" },
    }),
    linked = {
      run = { nvim, "--headless", "-u", "NONE", "-l", "fake_link.lua", "stay", link_log },
      start = "link",
      env = { LINK_SEEN = "${temp}" },
    },
    linkearly = {
      run = { nvim, "--headless", "-u", "NONE", "-l", "fake_link.lua", "early", link_log },
      start = "link",
      window = "never",
      ended_early = "handed over to another",
    },
    nameless = { run = { "${nope}" } },
    bad = { run = "a string" },
  }) .. " } }\n")
  write(
    "fake_build.lua",
    [[
if _G.arg[1] == "broken" then
  io.stderr:write("error: a Rust thing\n")
  os.exit(101)
end
if _G.arg[1] == "into" then
  local f = assert(io.open(_G.arg[2] .. "/prepared", "wb"))
  f:write("settings")
  f:close()
  return
end
if _G.arg[1] == "cleanup" then
  local seen = vim.uv.fs_stat(_G.arg[2]) ~= nil
  local f = assert(io.open("cleaned.txt", "wb"))
  f:write(_G.arg[2], string.char(10), tostring(seen))
  f:close()
  return
end
if _G.arg[1] == "check" then
  local f = assert(io.open(_G.arg[2] .. "/prepared", "rb"))
  f:close()
  local g = assert(io.open(_G.arg[2] .. "/checked", "wb"))
  g:close()
  return
end
local f = assert(io.open(_G.arg[1] == "second" and "built2.txt" or "built.txt", "wb"))
f:write("yes")
f:close()
]]
  )

  local function last_pid()
    local lines = vim.fn.readfile(log)
    return tonumber(lines[#lines - 1]), lines[#lines]
  end

  -- 1. the description -----------------------------------------------------------------------------------------------
  do
    eq(app.check({ run = { "a" } }), nil, "a run is enough")
    eq(app.check({ run = { "a" }, build = { "b", "c" } }), nil, "a build is one argv")
    eq(app.check({ run = { "a" }, build = { { "b" }, { "c", "d" } } }), nil, "or a list of them")
    eq(
      app.check({ run = { "a" }, prepare = { { "b", "${temp}" } } }),
      nil,
      "a prepare is like a build"
    )
    eq(app.check({ run = { "a" }, start = "link", window = "w" }), nil, "a start as by a link")
    for _, c in ipairs({
      { "x", "must be a table" },
      { {}, "run must be" },
      { { run = "a b" }, "run must be" },
      { { run = {} }, "run must be" },
      { { run = { "a", 1 } }, "run must be" },
      { { run = { "a" }, build = "cargo build" }, "build must be" },
      { { run = { "a" }, build = { { "a" }, "b" } }, "build must be" },
      { { run = { "a" }, build = { { "a" }, {} } }, "build must be" },
      { { run = { "a" }, build = {} }, "build must be" },
      { { run = { "a" }, shell = true }, "unknown field shell" },
      { { run = { "a" }, env = { A = 1 } }, "env must be" },
      { { run = { "a" }, ready = {} }, "ready needs stdout" },
      { { run = { "a" }, ready = { stdout = "x", as = "temp" } }, "ready.as" },
      { { run = { "a" }, ready = { stdout = "x", as = "a b" } }, "ready.as" },
      { { run = { "a" }, ready = { stdout = "x", timeout_ms = -1 } }, "timeout_ms" },
      { { run = { "a" }, ready = { stdout = "[" } }, "not a Lua pattern" },
      { { run = { "a" }, prepare = "node prep.mjs" }, "prepare must be" },
      { { run = { "a" }, prepare = {} }, "prepare must be" },
      { { run = { "a" }, cleanup = "close it" }, "cleanup must be" },
      { { run = { "a" }, start = "shell" }, 'start must be "link"' },
      { { run = { "a" }, window_ms = 0 }, "window_ms must be" },
      { { run = { "a" }, window_ms = "60s" }, "window_ms must be" },
      { { run = { "a" }, start = "link", ready = { stdout = "x" } }, "takes no ready" },
    }) do
      has(app.check(c[1]), c[2], "refused: " .. vim.inspect(c[1]))
    end
    eq(app.expand("a${x}b", { x = "%1" }), "a%1b", "a value is text, not a pattern")
    local none, why = app.expand("${y}", {})
    ok(none == nil, "an unknown name is no empty string")
    has(why, "unknown ${y}", "... it is named")
    local copy = app.expand_step({ open = "${x}/p", note = "n" }, { x = "u" })
    eq(copy, { open = "u/p", note = "n" }, "open takes the names")
    local press = { press = "${x}" }
    eq(app.expand_step(press, { x = "u" }), press, "nothing else does")
    local refused = sheet.validate({ id = "a", title = "T", app = "x", steps = { { keys = "x" } } })
    ok(refused == nil, "app belongs to a browser sheet")
    local bad_name = sheet.validate({
      id = "a",
      title = "T",
      engine = "browser",
      app = "../x",
      steps = { { press = "x" } },
    })
    ok(bad_name == nil, "app is a name")
  end

  -- 2. start and stop --------------------------------------------------------------------------------------------------
  do
    local started, err = app.start("good", root)
    ok(started ~= nil, "it starts: " .. tostring(err))
    has(started.vars.link, "file:///", "ready: the line, as the name of `as`")
    ok(started.vars.link == vim.trim(started.vars.link), "... trimmed")
    local pid, temp = last_pid()
    eq(temp, started.vars.temp, "${temp} reaches its argv")
    ok(vim.uv.fs_stat(temp .. "/seen") ~= nil, "... and its env, and it is a folder")
    ok(vim.uv.kill(pid, 0) == 0, "it runs")
    started.stop()
    started.stop()
    vim.wait(5000, function()
      return vim.uv.kill(pid, 0) ~= 0
    end, 50)
    ok(vim.uv.kill(pid, 0) ~= 0, "stop ends it")
    ok(vim.uv.fs_stat(temp) == nil, "... and takes the folder")

    local _, e1 = app.start("nosuch", root)
    has(e1, "no app nosuch", "an app that is not described")
    local _, e2 = app.start("bad", root)
    has(e2, "run must be", "a description that is wrong")
    local _, e3 = app.start("nameless", root)
    has(e3, "unknown ${nope}", "a name nobody fills in")
    local _, e4 = app.start("dies", root)
    has(e4, "exit 4", "an app that dies before it is ready")
    has(e4, "no sound card", "... with what it said")
    local _, e5 = app.start("silent", root)
    has(e5, "no line matched", "an app that never gets ready")
    local silent_pid = last_pid()
    vim.wait(5000, function()
      return vim.uv.kill(silent_pid, 0) ~= 0
    end, 50)
    ok(vim.uv.kill(silent_pid, 0) ~= 0, "... is not left running")

    local _, e6 = app.start("unbuilt", root)
    has(e6, "build failed (exit 101)", "a build that fails")
    has(e6, "a Rust thing", "... with what it said")
    -- a runner that cannot start is red, and the app of the sheet does not stay behind
    local raised = sheet.run(
      assert(sheet.validate({
        id = "app.raise",
        title = "T",
        engine = "browser",
        app = "good",
        steps = { { open = "${link}" } },
      })),
      {
        root = root,
        node = "node",
        playwright_dir = root,
        run = function()
          error("no such program")
        end,
      }
    )
    ok(not raised.ok, "a runner that raises is red")
    has(raised.failures[1], "no such program", "... with what it said")
    local raised_pid = last_pid()
    vim.wait(5000, function()
      return vim.uv.kill(raised_pid, 0) ~= 0
    end, 50)
    ok(vim.uv.kill(raised_pid, 0) ~= 0, "... and takes the app with it")

    local built = assert(app.start("built", root))
    built.stop()
    ok(vim.uv.fs_stat(root .. "/built.txt") ~= nil, "the build runs in the project root")

    -- a build of several steps runs them one after the other, and the first that fails ends it, named by its number
    os.remove(root .. "/built.txt")
    local multi = assert(app.start("multi", root))
    multi.stop()
    ok(
      vim.uv.fs_stat(root .. "/built.txt") ~= nil and vim.uv.fs_stat(root .. "/built2.txt") ~= nil,
      "both steps of the build ran"
    )
    os.remove(root .. "/built2.txt")
    local _, e7 = app.start("multifail", root)
    has(e7, "build (step 2) failed (exit 101)", "the second step fails, and says which")
    ok(vim.uv.fs_stat(root .. "/built2.txt") == nil, "nothing runs after a failed step")

    -- Windows: a bare name finds a batch file on the PATH (`pnpm` is `pnpm.cmd`), and an argument that cmd.exe would
    -- read as its own is refused, not quoted
    if vim.fn.has("win32") == 1 then
      local bin = root .. "/bin"
      vim.fn.mkdir(bin, "p")
      local f = assert(io.open(bin .. "/shim-tool.cmd", "wb"))
      f:write("@echo off\r\necho shimmed> shim.txt\r\n")
      f:close()
      -- what sits beside a shim in a real install (pnpm): a shell script of the same name, which Windows cannot run
      local decoy = assert(io.open(bin .. "/shim-tool", "wb"))
      decoy:write("#!/bin/sh\nexit 1\n")
      decoy:close()
      local saved = vim.env.PATH
      vim.env.PATH = bin:gsub("/", "\\") .. ";" .. saved
      local ok_shim, shim = pcall(function()
        local plain = assert(app.start("shim", root))
        plain.stop()
        local _, bad = app.start("shimbad", root)
        return bad
      end)
      vim.env.PATH = saved
      ok(ok_shim, "the shim run did not raise: " .. tostring(shim))
      ok(
        vim.uv.fs_stat(root .. "/shim.txt") ~= nil,
        "a bare name finds shim-tool.cmd through PATHEXT"
      )
      has(shim, "cmd.exe would read", "an argument with an ampersand for a batch file is refused")
    end
  end

  -- 2b. prepare, and the start as by a link ---------------------------------------------------------------------------
  do
    -- prepare runs after the folder of the run exists, ${temp} filled in, its steps one after the other
    local prepared = assert(app.start("prepared", root))
    local temp = prepared.vars.temp
    ok(vim.uv.fs_stat(temp .. "/prepared") ~= nil, "prepare wrote into the folder of the run")
    ok(vim.uv.fs_stat(temp .. "/checked") ~= nil, "... and its second step saw it")
    prepared.stop()
    ok(vim.uv.fs_stat(temp) == nil, "the folder goes with the stop")
    local before = #vim.fn.readfile(log)
    local _, perr = app.start("prepfail", root)
    has(perr, "its prepare failed (exit 101)", "a prepare that fails")
    has(perr, "a Rust thing", "... with what it said")
    eq(#vim.fn.readfile(log), before, "... and the app does not start")
    -- cleanup runs at the stop, after the app, while the folder of the run is still there
    local cleaned = assert(app.start("cleaned", root))
    local cpid = last_pid()
    ok(vim.uv.fs_stat(root .. "/cleaned.txt") == nil, "cleanup does not run at the start")
    cleaned.stop()
    eq(
      vim.fn.readfile(root .. "/cleaned.txt"),
      { cleaned.vars.temp, "true" },
      "cleanup ran at the stop, ${temp} filled in, the folder still there"
    )
    ok(vim.uv.kill(cpid, 0) ~= 0, "... after the app ended")
    ok(vim.uv.fs_stat(cleaned.vars.temp) == nil, "... and the folder goes afterwards")

    if vim.fn.has("win32") == 1 then
      local linked, lerr = app.start("linked", root)
      ok(linked ~= nil, "a start as by a link: " .. tostring(lerr))
      local line = ""
      vim.wait(15000, function()
        line = vim.uv.fs_stat(link_log) and vim.fn.readfile(link_log)[1] or ""
        return line ~= ""
      end, 50)
      local pid, kinds, seen = line:match("^(%d+) ([%d,]+) (.*)$")
      eq(tonumber(pid), linked.pid, "the pid is the program's, not the starter's")
      ok(kinds ~= nil and not kinds:find("3", 1, true), "no stream of the run is a pipe: " .. line)
      eq(seen, linked.vars.temp, "the environment of the app reaches the program")
      ok(vim.uv.kill(linked.pid, 0) == 0, "it runs")
      linked.stop()
      vim.wait(5000, function()
        return vim.uv.kill(linked.pid, 0) ~= 0
      end, 50)
      ok(vim.uv.kill(linked.pid, 0) ~= 0, "stop ends the program behind the starter")

      local none, eerr, skip = app.start("linkearly", root)
      ok(none == nil, "a program that ends at once")
      has(eerr, "exit 0", "... with its own exit code")
      eq(skip, "handed over to another", "... is the skip of ended_early")
    end
  end

  -- 3. `testing sheets run --all` ---------------------------------------------------------------------------------------
  do
    local other = vim.fs.normalize(vim.fn.tempname()) .. "-all"
    local function sw(rel, text)
      local p = other .. "/" .. rel
      vim.fn.mkdir(vim.fs.dirname(p), "p")
      local f = assert(io.open(p, "wb"))
      f:write(text)
      f:close()
    end
    sw(
      "TESTS/sheets/green.sheet.lua",
      'return { id = "a.green", title = "G", task = "x/y", steps = { { keys = "x" } } }\n'
    )
    sw(
      "TESTS/sheets/red.sheet.lua",
      'return { id = "a.red", title = "R", steps = { { keys = "x" } } }\n'
    )
    sw(
      "TESTS/sheets/skip.sheet.lua",
      'return { id = "a.skip", title = "S", steps = { { keys = "x" } } }\n'
    )
    sw("TESTS/sheets/broken.sheet.lua", 'return { id = "a.broken" }\n')
    local out, errs = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        errs[#errs + 1] = s
      end,
    }
    local answers = {
      ["a.green"] = { ok = true, status = "pass", failures = {} },
      ["a.red"] = { ok = false, status = "fail", failures = { "80x24 step 1, keys x: boom" } },
      ["a.skip"] = { ok = true, status = "skip", skipped = "no browser", failures = {} },
    }
    local deps = {
      getenv = function()
        return nil
      end,
      trust_check = function()
        return nil
      end,
      run = function(s)
        return answers[s.id]
      end,
    }
    local ir = other .. "/ir.json"
    local code = run_cli.main({ "--all", "--root", other, "--json", ir }, sv, deps)
    eq(code, 1, "a red sheet: exit 1")
    has(table.concat(out, "\n"), "a.red: fail", "each sheet says how it went")
    local doc = vim.json.decode(table.concat(vim.fn.readfile(ir), "\n"))
    local valid, problems = require("testing.core.result").validate(doc)
    eq(problems, {}, "the IR is a valid Result-IR")
    ok(valid, "... valid")
    local report = require("testing.sheet.report")
    local cases = assert(report.cases_from_ir(ir))
    eq(cases["sheet:a.green"].status, "pass", "the report reads the green one")
    eq(cases["sheet:a.red"].status, "fail", "... the red one")
    eq(cases["sheet:a.red"].message, "80x24 step 1, keys x: boom", "... with its line")
    eq(cases["sheet:a.skip"].status, "skip", "... the skip")
    ok(cases["sheet:broken.sheet.lua"].status == "fail", "... and one that does not load is red")

    answers["a.red"] = answers["a.green"]
    vim.fn.delete(other .. "/TESTS/sheets/broken.sheet.lua")
    eq(run_cli.main({ "--all", "--root", other }, sv, deps), 0, "a skip alone does not make it red")
    eq(
      run_cli.main({ "--all", "--root", other, "--strict" }, sv, deps),
      1,
      "... with --strict it does"
    )
    answers["a.skip"] = answers["a.green"]
    eq(
      run_cli.main({ "--all", "--root", other, "--strict" }, sv, deps),
      0,
      "--strict and all green"
    )

    -- `--sheet <id>`: only the named sheets, by id or file name, and a name that is not there is said
    local ran = {}
    local run_all = deps.run
    deps.run = function(s)
      ran[#ran + 1] = s.id
      return run_all(s)
    end
    eq(run_cli.main({ "--sheet", "a.green", "--root", other }, sv, deps), 0, "--sheet runs")
    eq(ran, { "a.green" }, "... only that sheet")
    ran = {}
    eq(
      run_cli.main({ "--sheet", "red", "--sheet", "a.skip", "--root", other }, sv, deps),
      0,
      "--sheet twice"
    )
    table.sort(ran)
    eq(ran, { "a.red", "a.skip" }, "... by file name and by id")
    errs, ran = {}, {}
    eq(run_cli.main({ "--sheet", "a.nope", "--root", other }, sv, deps), 2, "an unknown sheet")
    has(table.concat(errs, "\n"), "no sheet a.nope", "... is named")
    eq(ran, {}, "... and nothing ran")
    errs = {}
    eq(
      run_cli.main({ "--sheet", "a.green", "--task", "x/y", "--root", other }, sv, deps),
      2,
      "--sheet and --task"
    )
    has(table.concat(errs, "\n"), "without a task", "... says why")
    deps.run = run_all

    errs = {}
    eq(run_cli.main({ "--all", "--task", "a/b", "--root", other }, sv, deps), 2, "--all and --task")
    has(table.concat(errs, "\n"), "without a task", "... says why")
    eq(
      run_cli.main(
        { "--all", "--root", other, "--json", other .. "/no/such/dir/ir.json" },
        sv,
        deps
      ),
      3,
      "an IR that cannot be written"
    )
    vim.fn.mkdir(other .. "/empty", "p")
    eq(run_cli.main({ "--all", "--root", other .. "/empty" }, sv, deps), 2, "no sheet at all")
    deps.trust_check = function()
      return "no trust"
    end
    eq(run_cli.main({ "--all", "--root", other }, sv, deps), 2, "the trust gate holds")
    deps.trust_check = nil
    vim.fn.delete(other, "rf")
  end

  -- 4. a real page through the app, where node, playwright-core and chromium exist --------------------------------------
  do
    local s = assert(sheet.validate({
      id = "app.page",
      title = "The page of the app",
      engine = "browser",
      app = "good",
      steps = {
        { open = "${link}" },
        { expect = "document.title === 'the app'", note = "the page of the link" },
        { press = "Tab" },
        { expect = "document.activeElement.id === 'a'" },
      },
    }))
    local pw_dir = browser.playwright_dir(repo)
    local o = { root = root, playwright_dir = pw_dir }
    local whole = sheet.run(s, o)
    if whole.status == "skip" then
      print("n/a  " .. tostring(whole.skipped) .. ": the real page is skipped")
    else
      ok(whole.ok, "the whole plan through the app: " .. table.concat(whole.failures, "; "))
      local whole_pid = last_pid()
      vim.wait(5000, function()
        return vim.uv.kill(whole_pid, 0) ~= 0
      end, 50)
      ok(vim.uv.kill(whole_pid, 0) ~= 0, "the app ends with the plan")

      local session = session_mod.open(s, o)
      while session:peek() do
        session:step()
      end
      local pid = last_pid()
      ok(pid ~= whole_pid, "a session starts its own")
      ok(vim.uv.kill(pid, 0) == 0, "... which runs up to the close")
      session:close()
      eq(session:result().failures, {}, "stepped through the app")
      vim.wait(5000, function()
        return vim.uv.kill(pid, 0) ~= 0
      end, 50)
      ok(vim.uv.kill(pid, 0) ~= 0, "the app ends with the session")

      -- a good page refuses `eval`: a wait must still work there, and still time out
      write(
        "csp.html",
        [[<!doctype html><meta http-equiv="Content-Security-Policy" content="script-src 'self'">]]
          .. "<title>strict</title>"
      )
      local csp = sheet.run(
        assert(sheet.validate({
          id = "app.csp",
          title = "T",
          engine = "browser",
          steps = {
            { open = "csp.html" },
            { wait = "document.title === 'strict'", note = "under a CSP" },
            { wait = "document.title === 'never'", timeout = 200, note = "still ends" },
          },
        })),
        o
      )
      eq(
        #csp.failures,
        1,
        "only the wait that cannot hold fails: " .. table.concat(csp.failures, "; ")
      )
      has(csp.failures[1], "step 3, still ends", "... the third")
      has(csp.failures[1], "Timeout 200ms exceeded", "... by its timeout")

      local no_app = sheet.run(
        assert(sheet.validate({
          id = "app.none",
          title = "T",
          engine = "browser",
          app = "dies",
          steps = { { open = "${link}" } },
        })),
        o
      )
      ok(not no_app.ok, "an app that does not start is red")
      has(no_app.failures[1], "the app dies did not start", "... by name")

      local unknown = sheet.run(
        assert(sheet.validate({
          id = "app.unknown",
          title = "T",
          engine = "browser",
          app = "good",
          steps = { { open = "${nope}" } },
        })),
        o
      )
      ok(not unknown.ok, "a name nobody fills in is red")
      has(unknown.failures[1], "unknown ${nope}", "... by name")
    end
  end

  vim.fn.delete(root, "rf")
end
