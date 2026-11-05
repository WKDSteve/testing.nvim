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
local f = assert(io.open("built.txt", "wb"))
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
    for _, c in ipairs({
      { "x", "must be a table" },
      { {}, "run must be" },
      { { run = "a b" }, "run must be" },
      { { run = {} }, "run must be" },
      { { run = { "a", 1 } }, "run must be" },
      { { run = { "a" }, build = "cargo build" }, "build must be" },
      { { run = { "a" }, shell = true }, "unknown field shell" },
      { { run = { "a" }, env = { A = 1 } }, "env must be" },
      { { run = { "a" }, ready = {} }, "ready needs stdout" },
      { { run = { "a" }, ready = { stdout = "x", as = "temp" } }, "ready.as" },
      { { run = { "a" }, ready = { stdout = "x", as = "a b" } }, "ready.as" },
      { { run = { "a" }, ready = { stdout = "x", timeout_ms = -1 } }, "timeout_ms" },
      { { run = { "a" }, ready = { stdout = "[" } }, "not a Lua pattern" },
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
