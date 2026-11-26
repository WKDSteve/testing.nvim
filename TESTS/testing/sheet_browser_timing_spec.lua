-- TESTS/testing/sheet_browser_timing_spec.lua -- how long the steps of a browser sheet take, and `measure` in the page:
-- the runner times each step next to the page (`ms`, a `wait` also `after_ms` since the step that acted), the result
-- carries `timings` and `measures`, a stepped run carries them on the step's event; `testing sheets run --repeat N`
-- folds N runs into median and spread per step (a table, and the document of `--result`). With a fake runner, and
-- where node, playwright-core and chromium exist on a real page (in Playwright's Chromium, and in Chrome where it is
-- installed).
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
  local browser = require("testing.sheet.browser")
  local timing = require("testing.sheet.timing")
  local runcli = require("testing.sheet.run")
  local schema = require("testing.export.schema")
  local here = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
  local pw_dir = browser.playwright_dir(repo)

  -- 1. the form: measure is a step of a browser sheet -------------------------------------------------------------
  do
    local s, err = sheet.validate({
      id = "m.b",
      title = "m",
      engine = "browser",
      steps = { { open = "p.html" }, { measure = "performance.now()", name = "now", runs = 2 } },
    })
    ok(s ~= nil, "a measure loads in a browser sheet: " .. tostring(err))
    local _, why = sheet.validate({
      id = "m.b",
      title = "m",
      engine = "browser",
      steps = { { measure = "1", name = "x", min = 2, max = 1 } },
    })
    has(why, "min is above max", "its bounds are checked as in an rpc sheet")
  end

  -- 2. the runner's answer, with a fake runner -----------------------------------------------------------------------
  local s2 = assert(sheet.validate({
    id = "t.fake",
    title = "fake",
    engine = "browser",
    sizes = { { rows = 700, cols = 1000 }, { rows = 600, cols = 400 } },
    steps = {
      { open = "p.html" },
      { click = "#b" },
      { wait = "ok()" },
      { measure = "x()", name = "load", max = 10, unit = "ms" },
    },
  }))
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-browser-timing"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function fake(answer)
    return sheet.run(s2, {
      root = root,
      node = "node",
      playwright_dir = root,
      run = function()
        return { code = 0, stdout = vim.json.encode(answer) .. "\n", stderr = "" }
      end,
    })
  end
  do
    local res = fake({
      failures = { "400x600 step 2, click #b: Timeout 5000ms exceeded." },
      shots = {},
      steps = {
        { size = "1000x700", n = 1, ms = 30.5 },
        { size = "1000x700", n = 2, ms = 12 },
        { size = "1000x700", n = 3, ms = 400, after_ms = 412.3, after_n = 2 },
        { size = "1000x700", n = 4, ms = 50, values = { 5, 100, 7 } },
        { size = "400x600", n = 1, ms = 20 },
      },
    })
    eq(res.status, "fail", "a red step of the second size is red")
    eq(res.timings[3], {
      size = "1000x700",
      n = 3,
      step = "wait ok()",
      ms = 400,
      after_ms = 412.3,
      after_n = 2,
    }, "a wait is timed, also since the step that acted")
    eq(#res.timings, 5, "every step that ran has its duration")
    local m = res.measures and res.measures[1] or {}
    eq(
      { m.name, m.value, m.values, m.unit, m.size, m.n },
      { "load", 7, { 5, 100, 7 }, "ms", "1000x700", 4 },
      "the readings of the page become a measure (median of the runs)"
    )
    eq(res.failures, { "400x600 step 2, click #b: Timeout 5000ms exceeded." }, "within its bound")

    local broke = fake({
      failures = { "400x600 step 2, click #b: boom" },
      shots = {},
      steps = {
        { size = "1000x700", n = 4, ms = 50, values = { 42 } },
      },
    })
    eq(broke.failures, {
      "1000x700 step 4, measure x(): load = 42 ms (max 10): above the max",
      "400x600 step 2, click #b: boom",
    }, "a broken bound is a failure line of its size, in the order of the sizes")
    eq(broke.measures[1].value, 42, "... and the value is kept")
    local odd = fake({
      failures = { "400x600 step 2, click #b: boom", "9x9 step 1, open p.html: a size of no plan" },
      shots = {},
      steps = { { size = "1000x700", n = 4, ms = 50, values = { 42 } } },
    })
    eq(odd.failures, {
      "9x9 step 1, open p.html: a size of no plan",
      "1000x700 step 4, measure x(): load = 42 ms (max 10): above the max",
      "400x600 step 2, click #b: boom",
    }, "no failure line of the runner is lost, also one of a size the sheet does not name")
    local old = fake({ failures = {}, shots = {} })
    eq(
      { old.status, old.timings },
      { "pass", nil },
      "a runner without steps (an older one) is no failure"
    )
  end

  -- 3. median and spread --------------------------------------------------------------------------------------------
  do
    local st = timing.stats({ 10, 30, 20 })
    eq({ st.runs, st.median, st.min, st.max, st.sd }, { 3, 20, 10, 30, 10 }, "the stats of three")
    eq(timing.stats({ 7 }).sd, 0, "one reading spreads by 0")
    local rows, measures = timing.aggregate({
      {
        timings = {
          { size = "1000x700", n = 2, step = "click #b", ms = 10 },
          { size = "1000x700", n = 3, step = "wait ok()", ms = 100, after_ms = 110, after_n = 2 },
        },
        measures = {
          { size = "1000x700", n = 4, name = "load", unit = "ms", value = 5, values = { 5 } },
        },
      },
      {
        timings = {
          { size = "1000x700", n = 2, step = "click #b", ms = 20 },
          { size = "1000x700", n = 3, step = "wait ok()", ms = 300, after_ms = 330, after_n = 2 },
        },
        measures = {
          { size = "1000x700", n = 4, name = "load", unit = "ms", value = 9, values = { 9 } },
        },
      },
      -- a run that broke off after the click
      { timings = { { size = "1000x700", n = 2, step = "click #b", ms = 30 } } },
    })
    eq(
      vim.tbl_map(function(r)
        return { r.n, r.kind, r.values, r.median }
      end, rows),
      {
        { 2, "step", { 10, 20, 30 }, 20 },
        { 3, "step", { 100, 300 }, 200 },
        { 3, "after", { 110, 330 }, 220 },
      },
      "one row per step and per wait since its acting step, the readings of every run"
    )
    eq(
      { measures[1].name, measures[1].values, measures[1].median },
      { "load", { 5, 9 }, 7 },
      "a measure"
    )
    local text = timing.text("t.fake", 3, rows, measures)
    has(text, "timings of t.fake (3 runs, ms): median, min, max, sd", "the table's head")
    has(text, "wait ok() since step 2", "the wait since its acting step")
    ok(text:find("click #b%s+20%.0%s+10%.0%s+30%.0%s+10%.0") ~= nil, "a row: " .. text)
    has(text, "measure load (ms)", "a measure with its unit")
  end

  -- 4. --repeat on the command line, with a stand-in engine -----------------------------------------------------------
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local schema_file = repo .. "/schemas/testing-sheet-run/1/testing-sheet-run.schema.json"
  local sdoc = vim.json.decode(table.concat(vim.fn.readfile(schema_file), "\n"))
  local cli_root = vim.fs.normalize(vim.fn.tempname()) .. "-repeat"
  write(
    cli_root .. "/TESTS/sheets/r.sheet.lua",
    'return { id = "r", title = "R", engine = "browser", steps = { { open = "p.html" }, { click = "#b" } } }\n'
  )
  local function main(argv, run)
    local out, err = {}, {}
    local code = runcli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    }, {
      getenv = function()
        return nil
      end,
      trust_check = function()
        return nil
      end,
      run = run,
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end
  do
    local n = 0
    local function steady(_, opts)
      n = n + 1
      eq(opts.root, cli_root, "it runs in its root")
      return {
        ok = true,
        status = "pass",
        failures = {},
        snapshots = {},
        timings = { { size = "1000x700", n = 2, step = "click #b", ms = n * 10 } },
      }
    end
    local code, out =
      main({ "--sheet", "r", "--root", cli_root, "--repeat", "3", "--result" }, steady)
    eq({ code, n }, { 0, 3 }, "three runs, green")
    has(out, "timings of r (3 runs, ms)", "the table")
    local doc = vim.json.decode(out:match("([^\n]+)$"))
    local valid, problems = schema.validate(sdoc, doc)
    ok(valid, "the document is a testing-sheet-run/1: " .. vim.inspect(problems))
    local row = doc.sheets[1].timings[1]
    eq(
      { doc.sheets[1].runs, row.values, row.median, row.min, row.max, row.kind },
      { 3, { 10, 20, 30 }, 20, 10, 30, "step" },
      "median and spread per step in the document"
    )
    local plain = select(2, main({ "--sheet", "r", "--root", cli_root, "--result" }, steady))
    local pdoc = vim.json.decode(plain:match("([^\n]+)$"))
    eq(pdoc.sheets[1].timings, nil, "without --repeat the document is as before")
    ok(not plain:find("timings of", 1, true), "... and so are the lines")

    n = 0
    local function red_second(s, opts)
      local res = steady(s, opts)
      if n == 2 then
        res.ok, res.status, res.failures = false, "fail", { "1000x700 step 2, click #b: boom" }
      end
      return res
    end
    local rcode, rout = main({ "--sheet", "r", "--root", cli_root, "--repeat=5" }, red_second)
    eq({ rcode, n }, { 1, 2 }, "a red run ends the repeats and the run is red")
    has(rout, "stopped after run 2 of 5", "... and says so")

    for _, bad in ipairs({ "0", "51", "2.5", "x" }) do
      local bcode, _, berr = main({ "--sheet", "r", "--root", cli_root, "--repeat", bad }, steady)
      eq(bcode, 2, "--repeat " .. bad .. " is refused")
      has(berr, "--repeat takes a whole number from 1 to 50", "... with the range")
    end
    local tcode, _, terr = main({ "--task", "x/y", "--tasks", cli_root, "--repeat", "2" }, steady)
    eq(tcode, 2, "--repeat with --tasks is refused")
    has(terr, "writes no task", "... with the reason")
  end

  -- 5. a real page --------------------------------------------------------------------------------------------------
  write(
    root .. "/page.html",
    [[<!doctype html><button id="b" onclick="setTimeout(() => { document.getElementById('done').hidden = false }, 200)">go</button>
<p id="done" hidden>done</p>]]
  )
  -- the time from a click until the page shows its result, read in the page itself
  local click_to_done = [[(async () => {
  const done = document.getElementById('done');
  done.hidden = true;
  const t = performance.now();
  document.getElementById('b').click();
  while (done.hidden) await new Promise((r) => setTimeout(r, 5));
  return performance.now() - t;
})()]]
  local function real_raw(max)
    return {
      id = "t.real",
      title = "real",
      engine = "browser",
      steps = {
        { open = "page.html" },
        { click = "#b" },
        { wait = "!document.getElementById('done').hidden", timeout = 5000 },
        { measure = click_to_done, name = "click to done", runs = 3, unit = "ms", max = max },
        { expect = "true" },
      },
    }
  end
  local function real_sheet(max)
    return assert(sheet.validate(real_raw(max)))
  end
  local function check_real(res, label)
    ok(res.ok, label .. ": " .. table.concat(res.failures, "; "))
    eq(#(res.timings or {}), 5, label .. ": every step is timed")
    local wait = res.timings and res.timings[3] or {}
    ok(
      wait.after_n == 2 and (wait.after_ms or 0) >= 180,
      label .. ": the wait since the click covers the page's 200 ms: " .. vim.inspect(wait)
    )
    ok(
      (wait.ms or -1) >= 0 and (wait.ms or 0) <= (wait.after_ms or -1),
      label .. ": the wait alone is a part of it"
    )
    local m = res.measures and res.measures[1] or {}
    ok(
      #(m.values or {}) == 3 and m.value >= 180 and m.value < 5000,
      label .. ": three readings in the page, the median about 200 ms: " .. vim.inspect(m)
    )
  end
  local real = sheet.run(real_sheet(5000), { root = root, playwright_dir = pw_dir })
  if real.status == "skip" then
    print("n/a  " .. tostring(real.skipped) .. ": the real page is skipped")
  else
    check_real(real, "chromium")

    local red = sheet.run(real_sheet(1), { root = root, playwright_dir = pw_dir })
    eq(red.status, "fail", "a median above its max is red")
    has(red.failures[1], "1000x700 step 4, measure ", "... at its step")
    has(red.failures[1], "; max 1): above the max", "... with the value")
    eq(#red.timings, 4, "the size ends there: the step after it did not run")

    -- a stepped run: the driver's answer carries the durations and the readings
    local session = require("testing.sheet.session").open(
      real_sheet(5000),
      { root = root, playwright_dir = pw_dir }
    )
    local marks = {}
    while session:peek() do
      local r = session:step()
      marks[r.n] = r
    end
    session:close()
    local sres = session:result()
    check_real(sres, "stepped")
    ok(
      marks[3].after_n == 2 and marks[3].after_ms >= 180,
      "the step's event carries the time since the click: " .. vim.inspect(marks[3])
    )
    ok(marks[4].measure and #marks[4].measure.values == 3, "... and a measure its readings")

    -- the command line, three runs of a real page: median and spread of the click until the page showed its result
    write(root .. "/TESTS/sheets/real.sheet.lua", "return " .. vim.inspect(real_raw(5000)) .. "\n")
    local rcode, rout = main(
      { "--sheet", "t.real", "--root", root, "--repeat", "3", "--result" },
      function(s, o)
        return sheet.run(s, vim.tbl_extend("force", o, { playwright_dir = pw_dir }))
      end
    )
    eq(rcode, 0, "three real runs are green: " .. rout)
    has(
      rout,
      "wait !document.getElementById('done').hidden since step 2",
      "the table names the wait"
    )
    local doc = vim.json.decode(rout:match("([^\n]+)$"))
    local after
    for _, row in ipairs(doc.sheets[1].timings or {}) do
      if row.kind == "after" then
        after = row
      end
    end
    ok(
      after and after.runs == 3 and after.median >= 180,
      "the wait since the click, three times: " .. vim.inspect(after)
    )
    eq(#doc.sheets[1].measures[1].values, 3, "the measure, one reading per run")
  end

  -- 6. Chrome, as the sheets of an app run (sheets.browser.channel = "chrome") ---------------------------------------
  if real.status ~= "skip" then
    local chrome =
      sheet.run(real_sheet(5000), { root = root, playwright_dir = pw_dir, channel = "chrome" })
    if chrome.status == "skip" then
      print("n/a  " .. tostring(chrome.skipped) .. ": Chrome is not installed here")
    else
      check_real(chrome, "chrome")
    end
  end
end
