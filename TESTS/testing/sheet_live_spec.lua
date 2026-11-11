-- TESTS/testing/sheet_live_spec.lua -- live sheets (`live = { env, hosts, cost }`): real keys and network, only with
-- `testing sheets run --live`, never on CI, a skip without the variable; the child gets the named variables and a
-- network guard for the named hosts, and the values are masked in every failure, screen and snapshot.
-- No real service is reached here: the variable is a stand-in, and the one URL that is let through is 127.0.0.1.
-- @cache-allow spawn
-- (it starts child editors, and curl in one of them against 127.0.0.1)
---@diagnostic disable: missing-fields
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
  local live = require("testing.sheet.live")
  local SECRET = "sk-live-0123456789abcdefXYZ"
  local function base(extra)
    return vim.tbl_extend("force", {
      id = "l.sheet",
      title = "live",
      live = {
        env = { "TESTING_LIVE_PROBE" },
        hosts = { "127.0.0.1" },
        cost = "nothing, a stand-in",
      },
      steps = { { expect = "true" } },
    }, extra or {})
  end

  -- 1. the form ---------------------------------------------------------------------------------------------------------
  do
    ok(sheet.validate(base()) ~= nil, "a live sheet loads")
    local function refused(t, needle, msg)
      local s, err = sheet.validate(t)
      ok(s == nil, msg .. ": refused")
      has(err, needle, msg)
    end
    refused(base({ live = { env = { "X" }, hosts = { "h" } } }), "live.cost", "no cost")
    refused(base({ live = { env = {}, hosts = { "h" }, cost = "c" } }), "live.env", "no variable")
    refused(
      base({ live = { env = { "A B" }, hosts = { "h" }, cost = "c" } }),
      "live.env",
      "a bad name"
    )
    refused(
      base({ live = { env = { "X" }, hosts = { "a/b" }, cost = "c" } }),
      "live.hosts",
      "a bad host"
    )
    refused(
      base({ live = { env = { "NVIM_X" }, hosts = { "h" }, cost = "c" } }),
      "points at",
      "NVIM*"
    )
    refused(
      base({ live = { env = { "X" }, hosts = { "h" }, cost = "c", key = "v" } }),
      "unknown field key",
      "an unknown field"
    )
    refused(base({ steps = { { shot = "x" } } }), "takes no shot", "a shot")
    refused(
      base({ engine = "browser", steps = { { open = "x" } } }),
      "live belongs to an rpc sheet",
      "another engine"
    )
  end

  -- 2. masking ----------------------------------------------------------------------------------------------------------
  do
    local mask = live.masker({ TESTING_LIVE_PROBE = SECRET, SHORT = "abc" })
    local masked = mask("key=" .. SECRET .. " and abc")
    eq(#masked, #("key=" .. SECRET .. " and abc"), "the length stays (a screen keeps its columns)")
    ok(not masked:find(SECRET, 1, true), "the value is gone: " .. masked)
    has(masked, "<TESTING_LIVE_PROBE>", "its name stands there")
    has(masked, "and abc", "a short value is no key and stays")
    eq(
      mask("row ends with " .. SECRET:sub(1, 10)),
      "row ends with " .. ("*"):rep(10),
      "a piece at the end"
    )
    eq(mask(SECRET:sub(-9) .. " next row"), ("*"):rep(9) .. " next row", "a piece at the start")
    eq(mask(nil), nil, "nil stays nil")
    eq(live.mask_of("A", "xy"), "**", "a value shorter than its name")
    local shot =
      live.mask_screen({ lines = { "a " .. SECRET }, text = "a " .. SECRET, cells = { {} } }, mask)
    ok(
      not shot.lines[1]:find(SECRET, 1, true) and not shot.text:find(SECRET, 1, true),
      "a screen is masked"
    )
  end

  -- 3. the gate ---------------------------------------------------------------------------------------------------------
  do
    local s = assert(sheet.validate(base()))
    local function env(t)
      return function(name)
        return t[name]
      end
    end
    has(
      live.gate(s, {}, env({ TESTING_LIVE_PROBE = SECRET })),
      "only with `testing sheets run --live`",
      "no --live"
    )
    has(
      live.gate(s, { live = true }, env({ CI = "true", TESTING_LIVE_PROBE = SECRET })),
      "never runs on CI",
      "CI"
    )
    has(live.gate(s, { live = true }, env({})), "TESTING_LIVE_PROBE not set", "no variable")
    eq(
      live.gate(s, { live = true }, env({ TESTING_LIVE_PROBE = SECRET })),
      nil,
      "--live and the variable: it runs"
    )
    has(live.notice(s), "cost: nothing, a stand-in", "the notice names the cost")
    local hosts = require("testing.guard.process_net").url_hosts({
      "curl",
      "-sS",
      "https://API.example.com:443/v1?x=1",
      "--url=http://other.org/",
    })
    eq(hosts, { "api.example.com", "other.org" }, "the hosts of the URLs of a command")
    eq(
      require("testing.guard.process_net").url_hosts({ "curl", "--version" }),
      nil,
      "a command without one"
    )
  end

  -- 4. a real child: skipped without --live, the variable inside, masked out, the guard -------------------------------
  do
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-live"
    vim.fn.mkdir(root .. "/TESTS", "p")
    local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
    f:write("vim.o.swapfile = false\n")
    f:close()
    local getenv = function(name)
      return name == "TESTING_LIVE_PROBE" and SECRET or nil
    end
    local plain =
      sheet.run(assert(sheet.validate(base())), { root = root, ci = true, getenv = getenv })
    eq(plain.status, "skip", "without --live: a skip")
    has(plain.skipped, "runs only with", "... that says why")

    local s = assert(sheet.validate(base({
      steps = {
        { expect = "#vim.env.TESTING_LIVE_PROBE == " .. #SECRET, note = "the variable is there" },
        { expect = "vim.env.ANTHROPIC_API_KEY == nil", note = "nothing else" },
        {
          lua = "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'key ' .. vim.env.TESTING_LIVE_PROBE })",
        },
        { screen = "masked" },
        {
          expect = "error('the value: ' .. vim.env.TESTING_LIVE_PROBE)",
          note = "a failure that shows it",
        },
      },
    })))
    local res = sheet.run(s, { root = root, update = true, live = true, getenv = getenv })
    eq(res.status, "fail", "the last step fails")
    local failures = table.concat(res.failures, "\n")
    ok(not failures:find(SECRET, 1, true), "no value in a failure: " .. failures)
    has(failures, "<TESTING_LIVE_PROBE>", "... its name instead")
    eq(#res.failures, 1, "only the failing step failed")
    has(failures, "the value: <TESTING_LIVE_PROBE>", "... the one that shows it")
    local snaps = vim.fs.find(function(name)
      return name:find("masked", 1, true) ~= nil
    end, { path = root, type = "file", limit = 10 })
    eq(#snaps, 1, "the snapshot was written")
    local text = table.concat(vim.fn.readfile(snaps[1] or ""), "\n")
    ok(not text:find(SECRET, 1, true), "no value in the snapshot")
    has(text, "key <TESTING_LIVE_PROBE>", "... the masked row")

    -- the guard: a host the sheet does not name is blocked and fails the step; the named one goes through
    local curl = vim.fn.executable("curl") == 1
    local g = sheet.run(
      assert(sheet.validate(base({
        steps = {
          {
            lua = "vim.g.code = vim.system({ 'curl', '-sS', '--max-time', '3', 'http://127.0.0.1:9/' }):wait().code",
            note = "a named host",
          },
          { expect = "vim.g.code ~= nil" },
          {
            lua = "pcall(vim.system, { 'curl', '-sS', '--max-time', '3', 'https://example.org/' })",
            note = "another host",
          },
        },
      }))),
      { root = root, ci = true, live = true, getenv = getenv }
    )
    if curl then
      eq(g.status, "fail", "another host fails the sheet")
      local gf = table.concat(g.failures, "\n")
      has(gf, "step 3", "... at its step, the named host went through")
      has(gf, "reached what it does not name", "... and says why")
      has(gf, "example.org", "... naming it")
    else
      print("n/a  no curl on this machine: the guard part is not checked")
    end
    vim.fn.delete(root, "rf")
  end

  -- 5. the command: --live and the cost before the run ----------------------------------------------------------------
  do
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-live-cli"
    vim.fn.mkdir(root .. "/TESTS/sheets", "p")
    local f = assert(io.open(root .. "/TESTS/sheets/l.sheet.lua", "wb"))
    f:write(
      'return { id = "l.cli", title = "L", live = { env = { "TESTING_LIVE_PROBE" }, hosts = { "127.0.0.1" }, '
        .. 'cost = "nothing" }, steps = { { expect = "true" } } }\n'
    )
    f:close()
    local outs, errs, opts_seen = {}, {}, {}
    local sv = {
      out = function(s)
        outs[#outs + 1] = s
      end,
      err = function(s)
        errs[#errs + 1] = s
      end,
    }
    local env = {}
    local deps = {
      getenv = function(name)
        return env[name]
      end,
      trust_check = function()
        return nil
      end,
      run = function(_, o)
        opts_seen[#opts_seen + 1] = o
        return { ok = true, status = "skip", skipped = "stand-in", failures = {}, snapshots = {} }
      end,
    }
    local run_cli = require("testing.sheet.run")
    eq(run_cli.main({ "--sheet", "l.cli", "--root", root }, sv, deps), 0, "without --live")
    eq(opts_seen[1].live, false, "... the sheet runs without live")
    eq(#errs, 0, "... and no notice")
    eq(
      run_cli.main({ "--sheet", "l.cli", "--root", root, "--live" }, sv, deps),
      0,
      "--live, no key"
    )
    eq(opts_seen[2].live, true, "... live is passed on")
    eq(#errs, 0, "... no notice: a skip costs nothing")
    has(table.concat(outs, "\n"), "l.cli: skip: stand-in", "a skip says why")
    env.TESTING_LIVE_PROBE = SECRET
    eq(run_cli.main({ "--sheet", "l.cli", "--root", root, "--live" }, sv, deps), 0, "with --live")
    has(
      table.concat(errs, "\n"),
      "live sheet l.cli: real keys (TESTING_LIVE_PROBE)",
      "... the notice before it"
    )
    has(table.concat(errs, "\n"), "cost: nothing", "... with the cost")
    vim.fn.delete(root, "rf")
  end
end
