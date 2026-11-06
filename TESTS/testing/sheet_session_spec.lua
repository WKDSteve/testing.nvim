-- TESTS/testing/sheet_session_spec.lua -- one test sheet step by step: the session under `sheet.run`, the driver
-- protocol with a fake driver process, `testing sheets step` (events against the schema file, commands, breakpoints,
-- abort, the gates) in this process and as a real process, and a real page where node, playwright-core and chromium
-- exist. Whether `sheet.run` still does what it did is `sheet_spec`'s and `sheet_browser_spec`'s business, unchanged.
-- @cache-allow time processes
-- @cache-inputs schemas/testing-sheet-session/ schemas/testing-sheet-driver/ TESTS/golden/testing-sheet-session-1/
-- (the clock only bounds how long a step may take; it decides nothing else)
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch, undefined-field

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
  local step_cli = require("testing.sheet.step")
  local schema = require("testing.export.schema")
  local browser = require("testing.sheet.browser")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.normalize(here .. "/../..")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-session"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function write(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end
  write("TESTS/minimal_init.lua", "vim.o.swapfile = false\n")
  local function loaded(t)
    return assert(sheet.validate(t))
  end
  local run_opts = { root = root, ci = true, update = false }

  local session_schema =
    schema.load(repo .. "/schemas/testing-sheet-session/1/testing-sheet-session.schema.json")
  local driver_schema =
    schema.load(repo .. "/schemas/testing-sheet-driver/1/testing-sheet-driver.schema.json")
  ok(session_schema ~= nil and driver_schema ~= nil, "the schema files load")

  -- the transcript `contract/check.mjs` reads too: both validators must agree
  do
    local kinds = {}
    for _, line in
      ipairs(vim.fn.readfile(repo .. "/TESTS/golden/testing-sheet-session-1/run.jsonl"))
    do
      local doc = vim.json.decode(line)
      local valid, problems = schema.validate(session_schema, doc)
      eq(problems, {}, "golden transcript: " .. line)
      ok(valid, "... valid")
      kinds[doc.event] = true
    end
    for _, event in ipairs({
      "start",
      "size",
      "step-before",
      "step-after",
      "paused",
      "ask",
      "task",
      "error",
      "end",
    }) do
      ok(kinds[event], "the golden transcript has " .. event)
    end
    local bad =
      schema.validate(session_schema, { schema = "testing-sheet-session/1", event = "end" })
    ok(not bad, "an end event without its fields is refused")
  end

  -- 1. the session -------------------------------------------------------------------------------------------------
  do
    local two = loaded({
      id = "s.two",
      title = "T",
      sizes = { { rows = 24, cols = 80 }, { rows = 10, cols = 40 } },
      steps = {
        { lua = "vim.g.x = 1", note = "set" },
        { expect = "vim.g.x == 1" },
        { expect = "vim.o.columns == 80", note = "only the first size" },
        { lua = "vim.g.y = 2" },
      },
    })
    local session = session_mod.open(two, run_opts)
    local first = session:peek()
    eq(
      { first.size, first.n, first.total, first.action, first.value, first.note },
      { "80x24", 1, 4, "lua", "vim.g.x = 1", "set" },
      "peek names the next step"
    )
    eq(session:peek().n, 1, "peek does not run it")
    local r1 = session:step()
    eq({ r1.status, r1.n }, { "pass", 1 }, "step runs exactly one")
    ok(type(r1.ms) == "number", "... and says how long")
    eq(session:peek().n, 2, "the next one is next")
    local seen = { 1 }
    while session:peek() do
      seen[#seen + 1] = session:step().n
    end
    eq(seen, { 1, 2, 3, 4, 1, 2, 3 }, "the first failed step ends its size, the next size runs")
    session:close()
    session:close()
    local res = session:result()
    local plain = sheet.run(two, run_opts)
    eq({ res.ok, res.status }, { plain.ok, plain.status }, "the same verdict as sheet.run")
    eq(res.failures, plain.failures, "the same failure lines as sheet.run")
    eq(session:peek(), nil, "a closed session has nothing next")

    -- a step that raises keeps its line, without a step number
    local raising = loaded({ id = "s.raise", title = "T", steps = { { lua = "error('boom')" } } })
    local rs = session_mod.open(raising, run_opts)
    local rr = rs:step()
    rs:close()
    eq(rr.status, "fail", "a raising step fails")
    eq(rr.failure, rs:result().failures[1], "... with the line of the result")
    ok(
      rr.failure:match("^80x24: ") ~= nil,
      "... as a normal run writes it: " .. tostring(rr.failure)
    )

    -- requires: a skip ends the run, never green
    local skipped = session_mod.open(
      loaded({
        id = "s.skip",
        title = "T",
        requires = { { lua = "false", reason = "nope" } },
        steps = { { lua = "vim.g.x = 1" } },
      }),
      run_opts
    )
    eq(skipped:peek(), nil, "a requirement not met: no step")
    skipped:close()
    eq(
      { skipped:result().status, skipped:result().skipped },
      { "skip", "nope" },
      "... a reported skip"
    )

    -- a manual sheet has nothing to step through
    local manual = session_mod.open(
      loaded({ id = "s.manual", title = "T", engine = "manual", manual = { "by hand" } }),
      run_opts
    )
    eq(manual:peek(), nil, "a manual sheet has no steps")
    manual:close()
    eq(manual:result().status, "manual", "... and stays manual")

    -- cancel reaches a running wait step, and the child is gone afterwards
    local long = session_mod.open(
      loaded({
        id = "s.long",
        title = "T",
        steps = {
          { lua = ("vim.fn.writefile({ tostring(vim.fn.getpid()) }, %q)"):format(root .. "/pid") },
          { wait = "false", timeout = 60000 },
        },
      }),
      run_opts
    )
    long:step()
    local pid = tonumber(vim.fn.readfile(root .. "/pid")[1])
    local timer = assert(vim.uv.new_timer())
    timer:start(100, 0, function()
      long:cancel()
    end)
    local t0 = vim.uv.hrtime()
    local cancelled = long:step()
    timer:close()
    ok((vim.uv.hrtime() - t0) / 1e6 < 20000, "cancel ends a wait of a minute at once")
    eq(cancelled.reason, "aborted", "... and says so")
    eq(long:peek(), nil, "nothing comes after an abort")
    long:close()
    eq(
      { long:result().ok, long:result().status },
      { false, "aborted" },
      "an aborted run proves nothing"
    )
    vim.wait(5000, function()
      return vim.uv.kill(pid, 0) ~= 0
    end, 50)
    ok(vim.uv.kill(pid, 0) ~= 0, "no child editor is left after an abort")
  end

  -- 2. the driver protocol, with a driver that is not a browser ------------------------------------------------------
  do
    local fake = write(
      "fake_driver.lua",
      [[
local mode = _G.arg[1]
local function say(t)
  t.schema = "testing-sheet-driver/1"
  io.stdout:write(vim.json.encode(t), "\n")
  io.stdout:flush()
end
local log = {}
while true do
  local line = io.stdin:read("*l")
  if not line then
    local e = assert(io.open(_G.arg[2], "ab")); e:write('{"cmd":"close","eof":true}\n'); e:close()
    break
  end
  local cmd = vim.json.decode(line)
  log[#log + 1] = line
  local f = assert(io.open(_G.arg[2], "ab")); f:write(line, "\n"); f:close()
  if cmd.cmd == "open" then
    if mode == "skip" then say({ ok = false, skip = "no such thing" }) else say({ ok = true }) end
  elseif cmd.cmd == "step" then
    if mode == "die" and cmd.n == 2 then io.stderr:write("it broke\n"); os.exit(5) end
    if mode == "hang" and cmd.n == 2 then vim.wait(30000) end
    if mode == "garbage" and cmd.n == 2 then io.stdout:write("not json\n"); io.stdout:flush() end
    if cmd.step.expect == "bad" then say({ ok = false, reason = "got false" })
    elseif cmd.step.shot then say({ ok = true, shot = "out/x.png" })
    else say({ ok = true }) end
  elseif cmd.cmd == "close" then
    say({ ok = true })
    break
  end
end
]]
    )
    local function fake_opts(mode)
      local logfile = root .. "/driver-" .. mode .. ".log"
      return vim.tbl_extend("force", run_opts, {
        driver_argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", fake, mode, logfile },
        -- a started editor takes seconds on a hosted runner; only the hang waits for this to run out
        driver_margin_ms = mode == "hang" and 5000 or 60000,
        driver_stop_ms = 500,
      }),
        logfile
    end
    local function steps_sheet(steps)
      return loaded({
        id = "d.x",
        title = "T",
        engine = "browser",
        sizes = { { rows = 7, cols = 9 } },
        steps = steps,
      })
    end
    local function drive(mode, steps)
      local o, logfile = fake_opts(mode)
      local session = session_mod.open(steps_sheet(steps), o)
      local results = {}
      while session:peek() do
        results[#results + 1] = session:step()
      end
      session:close()
      return session:result(), results, logfile
    end

    local res, results, logfile = drive("good", {
      { open = "p.html" },
      { shot = "one" },
      { expect = "bad", note = "wrong" },
      { press = "Tab" },
    })
    eq({ res.ok, res.status }, { false, "fail" }, "a failed step of the driver is red")
    eq(#results, 3, "the first failed step ends the size")
    eq(results[2].shot, "out/x.png", "a shot names its file")
    eq(res.snapshots, { "screenshot out/x.png" }, "... like the whole plan does")
    eq(res.failures, { "9x7 step 3, wrong (expect bad): got false" }, "the failure line")
    local sent = {}
    for _, line in ipairs(vim.fn.readfile(logfile)) do
      local msg = vim.json.decode(line)
      sent[#sent + 1] = msg.cmd
      local valid, problems = schema.validate(driver_schema, msg)
      eq(problems, {}, "a command fits the schema: " .. line)
      ok(valid, "... valid")
    end
    eq(sent, { "open", "step", "step", "step", "close" }, "open, the steps, close, in order")

    local skip_res = drive("skip", { { open = "p.html" } })
    eq(
      { skip_res.ok, skip_res.status, skip_res.skipped },
      { true, "skip", "no such thing" },
      "a skip from open"
    )

    local dead = drive("die", { { open = "p.html" }, { press = "Tab" }, { press = "Tab" } })
    ok(not dead.ok, "a driver that dies is red, never green")
    has(dead.failures[1], "exit 5", "... with its exit code")
    has(dead.failures[1], "it broke", "... and what it said")

    local hung = drive("hang", { { open = "p.html" }, { press = "Tab" } })
    ok(not hung.ok, "a driver that hangs is red")
    has(hung.failures[1], "did not answer", "... by name")

    local garbled = drive("garbage", { { open = "p.html" }, { press = "Tab" } })
    ok(not garbled.ok, "a driver that talks nonsense is red")
    has(garbled.failures[1], "answered something else", "... by name")

    -- an abort closes stdin, so that the driver takes its browser with it; no kill first
    do
      local o, log_file = fake_opts("eof")
      local session = session_mod.open(steps_sheet({ { open = "p.html" }, { press = "Tab" } }), o)
      session:step()
      session:cancel()
      session:close()
      local last = vim.json.decode(vim.fn.readfile(log_file)[#vim.fn.readfile(log_file)])
      ok(last.eof == true, "an abort ends the driver through its stdin: " .. vim.inspect(last))
      local log_lines = vim.fn.readfile(log_file)
      eq(#log_lines, 3, "... open, the step, the end of stdin: no close command in between")
    end

    -- a driver that cannot be started is a failure of the size, not an error out of the session
    local no_proc = session_mod.open(
      steps_sheet({ { open = "p.html" } }),
      vim.tbl_extend("force", run_opts, { driver_argv = { "any" } })
    )
    local real_system = vim.system
    vim.system = function()
      error("ENOENT: no such file")
    end
    local no_next = no_proc:peek()
    vim.system = real_system
    eq(no_next, nil, "no driver: nothing to step")
    no_proc:close()
    ok(not no_proc:result().ok, "no driver: red")
    has(no_proc:result().failures[1], "did not start", "... by name")

    -- no node at all: a reported skip, as in a whole run
    local no_node = session_mod.open(
      steps_sheet({ { open = "p.html" } }),
      vim.tbl_extend("force", run_opts, { node = "node", playwright_dir = false })
    )
    if not browser.playwright_dir(root) then
      eq(no_node:peek(), nil, "no playwright: nothing to step")
      no_node:close()
      eq(no_node:result().status, "skip", "no playwright: a skip")
    else
      no_node:close()
    end
  end

  -- 3. `testing sheets step` in this process ---------------------------------------------------------------------------
  write(
    "TESTS/sheets/green.sheet.lua",
    [[return {
  id = "cli.green",
  title = "Three steps",
  task = "testing.nvim/a-task",
  steps = {
    { lua = "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello sheet' })", note = "write" },
    { settle = 50 },
    { expect = "vim.fn.getline(1) == 'hello sheet'", note = "it is there" },
  },
}
]]
  )
  write(
    "TESTS/sheets/sizes.sheet.lua",
    [[return {
  id = "cli.sizes",
  title = "Two sizes",
  sizes = { { rows = 24, cols = 80 }, { rows = 30, cols = 100 } },
  steps = { { settle = 50 }, { settle = 50 }, { settle = 50 } },
}
]]
  )
  write(
    "TESTS/sheets/red.sheet.lua",
    [[return {
  id = "cli.red",
  title = "Red in the middle",
  sizes = { { rows = 24, cols = 80 }, { rows = 10, cols = 40 } },
  steps = {
    { lua = "vim.g.a = 1" },
    { expect = "false", note = "never" },
    { lua = "vim.g.b = 1" },
  },
}
]]
  )

  ---Run the command in this process with the commands given; every event checked against the schema file.
  ---@return integer code, table[] events, string errs, integer aborts
  local function step_run(argv, commands, deps)
    local events, errs = {}, {}
    local queue = vim.deepcopy(commands or {})
    local aborts = 0
    local reader = {
      start = function() end,
      next = function()
        aborts = aborts + (#queue == 0 and 1 or 0)
        return table.remove(queue, 1)
      end,
      stop = function() end,
    }
    local code = step_cli.main(
      argv,
      {
        out = function() end,
        err = function(s)
          errs[#errs + 1] = s
        end,
      },
      vim.tbl_extend("force", {
        emit = function(line)
          local doc = vim.json.decode(line)
          local valid, problems = schema.validate(session_schema, doc)
          eq(problems, {}, "an event fits the schema: " .. line)
          ok(valid, "... valid")
          events[#events + 1] = doc
          return true
        end,
        reader = reader,
        trust_check = function()
          return nil
        end,
        getenv = function()
          return nil
        end,
      }, deps or {})
    )
    return code, events, table.concat(errs, "\n"), aborts
  end
  local function names(events)
    local out = {}
    for _, e in ipairs(events) do
      out[#out + 1] = e.event == "paused" and ("paused:" .. e.reason .. ":" .. e.n)
        or (e.n and (e.event .. ":" .. e.n))
        or e.event
    end
    return out
  end

  do
    -- next, step by step: what it will do, stopped, what it did
    local code, events = step_run({ "cli.green", "--root", root }, { "next", "next", "next" })
    eq(code, 0, "a green run: exit 0")
    eq(names(events), {
      "start",
      "size",
      "step-before:1",
      "paused:start:1",
      "step-after:1",
      "step-before:2",
      "paused:step:2",
      "step-after:2",
      "step-before:3",
      "paused:step:3",
      "step-after:3",
      "end",
    }, "the events of a stepped run")
    local start = events[1]
    eq(start.schema, "testing-sheet-session/1", "the schema")
    eq(
      { start.id, start.engine, start.task, #start.steps },
      { "cli.green", "rpc", "testing.nvim/a-task", 3 },
      "start"
    )
    eq(start.steps[1].note, "write", "start names every step")
    eq(start.headed, false, "an rpc sheet has no window")
    eq(events[3].note, "write", "step-before says what it will do")
    local after = events[5]
    eq(after.status, "pass", "step-after says how it went")
    ok(
      table.concat(after.screen, "\n"):find("hello sheet", 1, true) ~= nil,
      "E3: the screen text of the child"
    )
    local last = events[#events]
    eq(
      { last.status, last.ok, last.verdict },
      { "pass", true, true },
      "a run without an abort may count"
    )

    -- continue runs to the end, a breakpoint stops it, until goes to a later step
    local _, cont = step_run({ root .. "/TESTS/sheets/green.sheet.lua" }, { "continue" })
    eq(names(cont), {
      "start",
      "size",
      "step-before:1",
      "paused:start:1",
      "step-after:1",
      "step-before:2",
      "step-after:2",
      "step-before:3",
      "step-after:3",
      "end",
    }, "continue runs to the end; the root of a sheet file is its project")
    eq(cont[1].root, root, "... the root")
    local _, brk = step_run({ "green", "--root", root, "--break", "3" }, { "continue", "continue" })
    ok(
      vim.tbl_contains(names(brk), "paused:break:3"),
      "--break stops before its step, by file name"
    )
    local _, unt = step_run({ "cli.green", "--root", root }, { "until 3", "continue" })
    ok(vim.tbl_contains(names(unt), "paused:until:3"), "until stops before its step")
    ok(not vim.tbl_contains(names(unt), "paused:step:2"), "... and not before")

    -- a bad command leaves it paused
    local _, bad = step_run(
      { "cli.green", "--root", root },
      { "answer yes", "until 1", "until 9", "continue" }
    )
    local errors = vim.tbl_filter(function(e)
      return e.event == "error"
    end, bad)
    eq(#errors, 3, "three commands it could not do")
    has(errors[1].message, "unknown command", "the first")
    has(errors[2].message, "later step", "until to an earlier step")
    eq(bad[#bad].status, "pass", "the run goes on after them")

    -- a stepped run keeps a picture of every step, in a folder of the run; only a driver's run does
    local shooter = write(
      "shooting_driver.lua",
      [[
local out_dir
while true do
  local line = io.stdin:read("*l")
  if not line then break end
  local cmd = vim.json.decode(line)
  local answer = { schema = "testing-sheet-driver/1", ok = true }
  if cmd.cmd == "open" then
    out_dir = cmd.sheet.out_dir
  elseif cmd.cmd == "step" and cmd.step.shot then
    vim.fn.mkdir(out_dir, "p")
    answer.shot = out_dir .. "/" .. cmd.step.shot .. ".png"
    vim.fn.writefile({ "png" }, answer.shot)
  elseif cmd.cmd == "close" then
    io.stdout:write(vim.json.encode(answer), "\n")
    io.stdout:flush()
    break
  end
  io.stdout:write(vim.json.encode(answer), "\n")
  io.stdout:flush()
end
]]
    )
    write(
      "TESTS/sheets/shots.sheet.lua",
      [[return {
  id = "cli.shots",
  title = "Pictures",
  engine = "browser",
  sizes = { { rows = 7, cols = 9 } },
  steps = { { press = "a" }, { shot = "mine" } },
}
]]
    )
    local shot_deps = {
      session_opts = {
        driver_argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", shooter },
        driver_margin_ms = 60000,
        driver_stop_ms = 500,
      },
    }
    local _, shots = step_run({ "cli.shots", "--root", root, "--run" }, {}, shot_deps)
    local afters = vim.tbl_filter(function(e)
      return e.event == "step-after"
    end, shots)
    eq(#afters, 2, "both steps ran")
    for i, shown in ipairs(afters) do
      ok(shown.image ~= nil, "step-after names the picture of step " .. i)
      eq(vim.fn.filereadable(shown.image), 1, "and it is there")
      ok(not shown.image:find("TESTS/sheets/out", 1, true), "not among the shots of the project")
    end
    has(afters[2].shot, "mine", "a shot step keeps its own file")
    eq(vim.fn.filereadable(afters[2].shot), 1, "in its own place")
    eq(
      #vim.fn.glob(root .. "/TESTS/sheets/out/*step-*", false, true),
      0,
      "no picture of a step is left among the shots"
    )

    -- a breakpoint set while paused holds in every size, and goes away again
    local _, broke = step_run(
      { "cli.sizes", "--root", root },
      { "break 3", "clear 3", "break 2", "break 0", "clear 9", "continue", "continue", "continue" }
    )
    local stops = vim.tbl_filter(function(name)
      return name:find("paused:", 1, true) == 1
    end, names(broke))
    eq(
      stops,
      { "paused:start:1", "paused:break:2", "paused:break:2" },
      "in both sizes, not at the cleared one"
    )
    local refused = vim.tbl_filter(function(e)
      return e.event == "error"
    end, broke)
    eq(#refused, 2, "a step the sheet does not have is refused")
    has(refused[1].message, "1 to 3", "and says which there are")
    eq(broke[#broke].status, "pass", "the run goes on")

    -- the end of stdin and abort
    local c1, eof, _, reads = step_run({ "cli.green", "--root", root }, { "next" })
    eq(c1, 3, "closed stdin is an abort: exit 3")
    eq(reads, 1, "... noticed when the next command is due")
    eq(
      { eof[#eof].status, eof[#eof].ok, eof[#eof].verdict },
      { "aborted", false, false },
      "an abort is no verdict"
    )
    local c2, ab = step_run({ "cli.green", "--root", root }, { "abort" })
    eq(c2, 3, "abort: exit 3")
    ok(not vim.tbl_contains(names(ab), "step-after:1"), "abort before the first step runs nothing")

    -- a failure stops, before the next size takes the target away
    local c3, red = step_run(
      { "cli.red", "--root", root },
      { "continue", "continue", "continue", "continue" }
    )
    eq(c3, 1, "a red run: exit 1")
    ok(vim.tbl_contains(names(red), "paused:failed:2"), "a failed step pauses")
    local rl = red[#red]
    eq(
      { rl.status, rl.verdict, #rl.failures },
      { "fail", true, 2 },
      "both sizes ran, a red run is a verdict"
    )
    has(rl.failures[1], "80x24 step 2, never (expect false)", "the failure line of a normal run")
    eq(
      rl.failures,
      sheet.run(assert(sheet.load(root .. "/TESTS/sheets/red.sheet.lua")), run_opts).failures,
      "the same as sheet.run"
    )

    -- --run reads no commands
    local c4, ran = step_run({ "cli.red", "--root", root, "--run", "--delay", "1" }, {}, {
      reader = {
        start = function()
          error("--run must not read stdin")
        end,
      },
    })
    eq(c4, 1, "--run: the verdict of the run")
    ok(vim.tbl_filter(function(e)
      return e.event == "paused"
    end, ran)[1] == nil, "--run never pauses")
  end

  -- the gates ------------------------------------------------------------------------------------------------------
  do
    local function refused(argv, needle, msg, deps)
      local code, events, errs = step_run(argv, {}, deps)
      eq(code, 2, msg .. ": exit 2")
      eq(events, {}, msg .. ": no event, nothing ran")
      has(errs, needle, msg)
    end
    refused({}, "which sheet", "no sheet")
    refused({ "a", "b" }, "one sheet", "two sheets")
    refused({ "cli.green", "--root", root, "--delay" }, "needs a value", "--delay without a value")
    refused({ "cli.green", "--root", root, "--break", "0" }, "whole number", "--break 0")
    refused({ "cli.green", "--root", root, "--delay", "x" }, "whole number", "--delay x")
    refused({ "cli.green", "--root", root, "--nope" }, "unknown argument", "an unknown flag")
    refused(
      { "cli.green", "--root", root, "--run", "--break", "1" },
      "--run reads no commands",
      "--run and --break"
    )
    refused(
      { "cli.green", "--root", root, "--break", "9" },
      "has 3 steps",
      "a breakpoint past the end"
    )
    refused({ "no.such", "--root", root }, "no sheet no.such", "a sheet that is not there")
    refused({ "x", "--root", root .. "/nope" }, "not a directory", "a root that is not there")
    refused({ "cli.green", "--root", root }, "the trust says no", "an untrusted root", {
      trust_check = function()
        return "the trust says no"
      end,
    })
    refused({ "cli.green", "--root", root }, "refused on the workstation", "the workstation", {
      getenv = function(name)
        return name == "NVIM_MACHINE_ROLE" and "Workstation " or nil
      end,
    })
    refused({ "cli.green", "--root", root }, "a typo", "a role that is a typo", {
      getenv = function(name)
        return name == "NVIM_MACHINE_ROLE" and "worktsation" or nil
      end,
    })
    write("TESTS/sheets/broken.sheet.lua", "return { id = 'x' }\n")
    refused(
      { root .. "/TESTS/sheets/broken.sheet.lua" },
      "title is required",
      "a sheet that does not load"
    )
  end

  -- 4. the real process: stdout as it happens, closed stdin ends it, no child left -------------------------------------
  do
    local pid_sheet = write(
      "TESTS/sheets/pid.sheet.lua",
      ([[return {
  id = "cli.pid",
  title = "Writes its pid",
  steps = {
    { lua = [=[vim.fn.writefile({ tostring(vim.fn.getpid()) }, %q)]=] },
    { wait = "false", timeout = 120000, note = "takes long" },
  },
}
]]):format(root .. "/cli.pid")
    )
    local lines, partial, code = {}, "", nil
    local proc = vim.system({
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      repo .. "/scripts/testing.lua",
      "sheets",
      "step",
      pid_sheet,
    }, {
      stdin = true,
      env = { TESTING_AGENT = "0", TESTING_TRUST = "1" },
      stdout = function(_, data)
        if data then
          partial = partial .. data
          for line in partial:gmatch("([^\n]*)\n") do
            lines[#lines + 1] = vim.trim(line)
          end
          partial = partial:match("([^\n]*)$") or ""
        end
      end,
    }, function(done)
      code = done.code
    end)
    local function saw(event, reason)
      return vim.wait(60000, function()
        if code ~= nil then
          return true
        end
        for _, line in ipairs(lines) do
          if
            line:find('"event":"' .. event .. '"', 1, true)
            and (not reason or line:find(reason, 1, true))
          then
            return true
          end
        end
        return false
      end, 20)
    end
    ok(saw("paused", '"start"'), "the process pauses before the first step and says so at once")
    proc:write("next\n")
    ok(saw("step-after"), "next runs one step")
    ok(saw("paused", '"step"'), "... and pauses again")
    local pid = tonumber(vim.fn.readfile(root .. "/cli.pid")[1])
    ok(vim.uv.kill(pid, 0) == 0, "the child runs while it is paused")
    proc:write("next\n")
    ok(saw("step-before"), "the long step starts")
    vim.wait(300)
    local t0 = vim.uv.hrtime()
    proc:write(nil) -- closed stdin, in the middle of a wait of two minutes
    vim.wait(30000, function()
      return code ~= nil
    end, 20)
    eq(code, 3, "closed stdin during a step: an abort, exit 3")
    ok((vim.uv.hrtime() - t0) / 1e6 < 25000, "... without waiting for the step")
    has(lines[#lines], '"status":"aborted"', "the last line says so")
    vim.wait(5000, function()
      return vim.uv.kill(pid, 0) ~= 0
    end, 50)
    ok(vim.uv.kill(pid, 0) ~= 0, "no child editor is left behind")
  end

  -- 5. a real page, where node, playwright-core and chromium exist ------------------------------------------------------
  do
    local pw_dir = browser.playwright_dir(repo)
    write("page.html", '<!doctype html><button id="a">A</button><button id="b">B</button>')
    local s = loaded({
      id = "page.step",
      title = "Tab order",
      engine = "browser",
      sizes = { { rows = 300, cols = 400 }, { rows = 200, cols = 300 } },
      steps = {
        { open = "page.html" },
        { press = "Tab" },
        { expect = "document.activeElement.id === 'a'", note = "first Tab" },
        { shot = "focus" },
        { expect = "innerWidth === 400", note = "only the first size" },
        { press = "Tab" },
      },
    })
    local o = { root = root, playwright_dir = pw_dir }
    local whole = sheet.run(s, o)
    if whole.status == "skip" then
      print("n/a  " .. tostring(whole.skipped) .. ": the real page is skipped")
    else
      local session = session_mod.open(s, o)
      local before = session:peek()
      eq(before.size, "400x300", "the page is open for the first size")
      local count = 0
      while session:peek() do
        session:step()
        count = count + 1
      end
      session:close()
      local stepped = session:result()
      eq(count, 6 + 5, "every step of the first size, up to the failed one in the second")
      eq(
        { stepped.ok, stepped.status },
        { whole.ok, whole.status },
        "the same verdict as the whole plan"
      )
      eq(stepped.failures, whole.failures, "the same failure lines")
      eq(stepped.snapshots, whole.snapshots, "the same screenshots")
      ok(#whole.failures == 1, "... one size is red: " .. table.concat(whole.failures, "; "))

      -- the driver takes the skip and the abort too: cancel during a long wait, nothing hangs
      local long = session_mod.open(
        loaded({
          id = "page.long",
          title = "Long",
          engine = "browser",
          steps = { { open = "page.html" }, { wait = "false", timeout = 120000 } },
        }),
        o
      )
      long:step()
      local timer = assert(vim.uv.new_timer())
      timer:start(200, 0, function()
        long:cancel()
      end)
      local t0 = vim.uv.hrtime()
      local r = long:step()
      timer:close()
      long:close()
      eq(r.reason, "aborted", "cancel reaches a running browser step")
      ok((vim.uv.hrtime() - t0) / 1e6 < 20000, "... at once")
      eq(long:result().status, "aborted", "... and the run is aborted")
    end
  end

  vim.fn.delete(root, "rf")
end
