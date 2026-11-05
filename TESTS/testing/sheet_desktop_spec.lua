-- TESTS/testing/sheet_desktop_spec.lua -- the "desktop" engine of test sheets: the shape of its steps, the skip without
-- a driver, what the driver is told (with a driver in memory that speaks the protocol), a second instance that hands
-- over. The real window is pult's sheet with appkit's sheet-driver, by hand: not on every machine.
-- @cache-allow time processes
-- @cache-env TESTING_DESKTOP_DRIVER
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
  local session_mod = require("testing.sheet.session")
  local schema = require("testing.export.schema")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")
  local driver_schema =
    schema.load(repo .. "/schemas/testing-sheet-driver/1/testing-sheet-driver.schema.json")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-desktop"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function write(rel, text)
    local p = root .. "/" .. rel
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end
  local nvim = vim.v.progpath:gsub("\\", "/")
  write(
    "fake_app.lua",
    [[
if _G.arg[1] == "handover" then os.exit(0) end
if _G.arg[1] == "crash" then os.exit(1) end
vim.wait(120000)
]]
  )
  local function app_entry(mode, extra)
    return vim.tbl_extend("force", {
      run = { nvim, "--headless", "-u", "NONE", "-l", "fake_app.lua", mode },
      window = "demo",
    }, extra or {})
  end
  write(".testing.lua", "return { sheets = { apps = " .. vim.inspect({
    window = app_entry("stay"),
    second = app_entry("handover", { ended_early = "it runs already" }),
    second_silent = app_entry("handover"),
    crashes = app_entry("crash", { ended_early = "it runs already" }),
  }) .. " } }\n")
  local fake = write(
    "fake_driver.lua",
    [[
local log = _G.arg[1]
local function say(t)
  t.schema = "testing-sheet-driver/1"
  io.stdout:write(vim.json.encode(t), "\n")
  io.stdout:flush()
end
while true do
  local line = io.stdin:read("*l")
  if not line then break end
  local f = assert(io.open(log, "ab")); f:write(line, "\n"); f:close()
  local cmd = vim.json.decode(line)
  if cmd.cmd == "open" then say({ ok = true })
  elseif cmd.cmd == "close" then say({ ok = true }); break
  elseif cmd.step.toggle == "nope" then say({ ok = false, reason = "no element is called nope" })
  elseif cmd.step.shot then say({ ok = true, shot = "out/x.png" })
  else say({ ok = true }) end
end
]]
  )

  local function loaded(t)
    return assert(sheet.validate(t))
  end
  local function desktop(app, steps)
    return loaded({ id = "d.x", title = "T", engine = "desktop", app = app, steps = steps })
  end
  local log = root .. "/driver.log"
  local function opts()
    return {
      root = root,
      driver_argv = { nvim, "--headless", "-u", "NONE", "-l", fake, log },
      driver_margin_ms = 20000,
      driver_stop_ms = 2000,
    }
  end

  -- 1. the shape -------------------------------------------------------------------------------------------------------
  do
    local s = desktop("window", {
      { wait = { name = "mute", state = "on", value = 1 }, timeout = 100 },
      { wait = "mute" },
      { expect = { name = "gain" } },
      { toggle = "mute" },
      { click = "Matrix" },
      { set = "gain", value = -12 },
      { shot = "desk" },
    })
    eq(s.sizes, { { rows = 700, cols = 1000 } }, "its default size is a window in pixels")
    for _, c in ipairs({
      { { keys = "x" }, "keys is not a step of a desktop sheet" },
      { { open = "x" }, "open is not a step of a desktop sheet" },
      { { wait = {} }, "name must be" },
      { { wait = { name = "" } }, "name must be" },
      { { wait = { name = "a", state = "red" } }, 'must be "on" or "off"' },
      { { wait = { name = "a", value = "x" } }, "value must be a number" },
      { { wait = { name = "a", role = "x" } }, "unknown field role" },
      { { toggle = "" }, "must not be empty" },
      { { set = "", value = 1 }, "must not be empty" },
      { { set = "gain" }, "takes a value" },
      { { toggle = "a", value = 1 }, "takes a value" },
    }) do
      local none, why = sheet.validate({
        id = "x",
        title = "T",
        engine = "desktop",
        app = "a",
        steps = { c[1] },
      })
      ok(none == nil, "refused: " .. vim.inspect(c[1]))
      has(why, c[2], "... says so")
    end
    local _, no_app =
      sheet.validate({ id = "x", title = "T", engine = "desktop", steps = { { wait = "a" } } })
    has(no_app, "names its app", "a desktop sheet needs an app")
    local _, e_rpc =
      sheet.validate({ id = "x", title = "T", steps = { { wait = { name = "a" } } } })
    has(e_rpc, "wait must be a string", "a table is for a desktop wait only")
    local _, e_browser = sheet.validate({
      id = "x",
      title = "T",
      engine = "browser",
      steps = { { toggle = "a" } },
    })
    has(e_browser, "toggle is not a step of a browser sheet", "toggle is not for a browser")
    eq(
      sheet._describe({ wait = { name = "mute", state = "on" }, note = nil }),
      "wait mute state=on",
      "a failure line names what was asked"
    )
  end

  -- 2. the driver --------------------------------------------------------------------------------------------------------
  do
    vim.fn.delete(log)
    local s = desktop("window", {
      { wait = { name = "mute", state = "off" } },
      { toggle = "mute" },
      { set = "gain", value = -12 },
      { shot = "desk" },
      { toggle = "nope", note = "fails" },
      { click = "never" },
    })
    local res = sheet.run(s, opts())
    eq(res.status, "fail", "sheet.run of a desktop sheet goes through the driver")
    eq(
      res.failures,
      { "1000x700 step 5, fails (toggle nope): no element is called nope" },
      "the line"
    )
    eq(res.snapshots, { "screenshot out/x.png" }, "the picture")
    local cmds = {}
    for _, line in ipairs(vim.fn.readfile(log)) do
      local doc = vim.json.decode(line)
      local valid, problems = schema.validate(driver_schema, doc)
      eq(problems, {}, "a command fits the schema: " .. line)
      ok(valid, "... valid")
      cmds[#cmds + 1] = doc
    end
    eq(cmds[1].cmd, "open", "first it opens")
    eq(cmds[1].options.window, "demo", "... with the part of the title")
    ok(type(cmds[1].options.pid) == "number" and cmds[1].options.pid > 0, "... and the process")
    eq(cmds[1].size, { rows = 700, cols = 1000 }, "... and the size")
    eq(cmds[2].step.wait, { name = "mute", state = "off" }, "a step goes as it stands")
    eq(cmds[4].step, { set = "gain", value = -12 }, "... a set with its value")
    eq(cmds[#cmds].cmd, "close", "at the end it closes")
    ok(vim.uv.kill(cmds[1].options.pid, 0) ~= 0, "the app is gone with the sheet")

    -- the session shows a table as one text, the same way
    local session =
      session_mod.open(desktop("window", { { wait = { name = "mute", state = "on" } } }), opts())
    local next_step = session:peek()
    eq(next_step.value, "mute state=on", "a step-before reads as text")
    session:step()
    session:close()
    eq(session:result().status, "pass", "and a green run is green")
  end

  -- 3. no driver, a second instance -----------------------------------------------------------------------------------
  do
    local s = desktop("window", { { wait = "a" } })
    local o = opts()
    o.driver_argv = nil
    o.desktop_driver = root .. "/no-such-driver"
    local none = sheet.run(s, o)
    eq({ none.ok, none.status }, { true, "skip" }, "a driver that cannot run: a reported skip")
    has(none.skipped, "cannot be run", "... says why")

    local handed = sheet.run(desktop("second", { { wait = "a" } }), opts())
    eq(
      { handed.status, handed.skipped },
      { "skip", "it runs already" },
      "a second instance is a skip"
    )
    local silent = sheet.run(desktop("second_silent", { { wait = "a" } }), opts())
    eq(silent.status, "fail", "without ended_early it is a failure")
    has(silent.failures[1], "before its window", "... by name")
    local crash = sheet.run(desktop("crashes", { { wait = "a" } }), opts())
    eq(crash.status, "fail", "ended_early is for success only, a crash stays a failure")
    has(crash.failures[1], "exit 1", "... with its code")
  end

  -- 4. `--engine` -------------------------------------------------------------------------------------------------------
  do
    write(
      "TESTS/sheets/a.sheet.lua",
      'return { id = "e.rpc", title = "R", steps = { { keys = "x" } } }\n'
    )
    write(
      "TESTS/sheets/b.sheet.lua",
      'return { id = "e.desk", title = "D", engine = "desktop", app = "window", steps = { { wait = "x" } } }\n'
    )
    local run = {}
    local out = {}
    local deps = {
      getenv = function()
        return nil
      end,
      trust_check = function()
        return nil
      end,
      run = function(s)
        run[#run + 1] = s.id
        return { ok = true, status = "pass", failures = {} }
      end,
    }
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        out[#out + 1] = s
      end,
    }
    local cli = require("testing.sheet.run")
    eq(cli.main({ "--all", "--root", root, "--engine", "rpc" }, sv, deps), 0, "--engine runs")
    eq(run, { "e.rpc" }, "... only that engine")
    eq(
      cli.main({ "--task", "a/b", "--root", root, "--engine", "rpc" }, sv, deps),
      2,
      "--engine is for --all"
    )
    eq(
      cli.main({ "--all", "--root", root, "--engine", "nope" }, sv, deps),
      2,
      "an engine without sheets"
    )
  end

  vim.fn.delete(root, "rf")
end
