-- TESTS/testing/ci_runners_spec.lua -- a red process step without an error format of its own names its red tests
-- (testing.ci.runners): Vitest, cargo test, pytest and unittest lines become findings, a log line does not, a green
-- step and a step with its own error format are left alone, and `ci commit` then finds a new red test behind a step
-- that was red at the base already (it used to be "0 new"). A step that names no test is marked "compared as a whole".

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(s, needle, msg)
    return ok(
      type(s) == "string" and s:find(needle, 1, true) ~= nil,
      ("%s: %q not in %q"):format(msg, needle, tostring(s))
    )
  end

  local report = require("testing.ci.report")
  local runners = require("testing.ci.runners")
  local baseline = require("testing.ci.baseline")
  local commit = require("testing.ci.commit")
  local internal = require("testing.ci").internal

  ---The findings the runners' formats read from `lines` (what a red step gets).
  local function read(lines)
    local m = runners.matcher()
    for _, l in ipairs(lines) do
      m.feed(l)
    end
    return m.list
  end

  -- ------------------------------------------------------------- the formats

  do
    for _, item in ipairs(runners.EFM) do
      ok(pcall(report.compile, item), "the runner format compiles: " .. item)
    end

    local vitest = read({
      " ❯ src/lib/a.test.ts (2 tests | 1 failed) 5ms",
      "   × a > fails 3ms",
      "⎯⎯⎯⎯⎯⎯⎯ Failed Tests 2 ⎯⎯⎯⎯⎯⎯⎯",
      "\27[31m FAIL \27[39m src/lib/a.test.ts > a > fails",
      "AssertionError: expected 1 to be 2",
      " FAIL  src/lib/b.test.ts [ src/lib/b.test.ts ]",
      " FAIL  src/lib/a.test.ts > a > fails",
    })
    eq(vitest, {
      { file = "src/lib/a.test.ts", text = "a > fails" },
      { file = "src/lib/b.test.ts", text = "src/lib/b.test.ts" },
    }, "vitest: one finding per red test, a file that failed to load, a repeat once")

    eq(
      read({
        "running 3 tests",
        "test launch::starts ... ok",
        "test launch::the_fake_program_opens_no_console_window ... FAILED",
        "test result: FAILED. 2 passed; 1 failed",
      }),
      {
        { file = "launch::the_fake_program_opens_no_console_window", text = "" },
      },
      "cargo test: the test path"
    )

    eq(
      read({
        "FAILED tests/test_a.py::test_x - AssertionError: assert 1 == 2",
        "FAILED tests/test_a.py::TestB::test_y",
        "ERROR tests/test_c.py - ImportError: no module named z",
      }),
      {
        { file = "tests/test_a.py::test_x", text = "AssertionError: assert 1 == 2" },
        { file = "tests/test_a.py::TestB::test_y", text = "" },
        { file = "tests/test_c.py", text = "ImportError: no module named z" },
      },
      "pytest: the short summary"
    )

    eq(
      read({
        "FAIL: test_install (test_release_kit.InstallTest.test_install)",
        "ERROR: test_sums (test_release_kit.SumsTest.test_sums)",
      }),
      {
        { file = "test_release_kit.InstallTest.test_install", text = "test_install" },
        { file = "test_release_kit.SumsTest.test_sums", text = "test_sums" },
      },
      "unittest: the dotted name"
    )

    eq(
      read({ "ERROR 12:30:01", "ERROR timeout", "FAILED everything", "error: test failed" }),
      {},
      "a log line that names no test is no finding"
    )
  end

  -- ------------------------------------------------------------- a process step

  ---Run a stand-in process step that prints `lines` and exits with `code`.
  local function step(lines, code, extra)
    local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-runner.lua"
    local body = {}
    for _, l in ipairs(lines) do
      body[#body + 1] = ("io.stdout:write(%q .. '\\n')"):format(l)
    end
    body[#body + 1] = ("os.exit(%d)"):format(code)
    local f = assert(io.open(tmp, "wb"))
    f:write(table.concat(body, "\n"))
    f:close()
    local planned = {
      step = vim.tbl_extend("force", { name = "ui-test", timeout_ms = 60000 }, extra or {}),
      argv = { vim.v.progpath, "--headless", "--clean", "-l", tmp },
    }
    local r = internal.run_process(planned, vim.fn.getcwd(), {
      out = function() end,
      err = function() end,
    })
    os.remove(tmp)
    return r
  end

  local BASE_OUT = { " FAIL  src/a.test.ts > a > old" }
  local HEAD_OUT = { " FAIL  src/a.test.ts > a > old", " FAIL  src/b.test.ts > b > new" }

  do
    local head = step(HEAD_OUT, 1)
    eq(head.state, "red", "step: red (" .. table.concat(head.errors or {}, "\n") .. ")")
    eq(#head.findings, 2, "step: a red step without an error format names its red tests")
    eq(head.findings_total, 2, "step: ... and counts them")

    local green = step(HEAD_OUT, 0)
    eq(green.state, "green", "step: green")
    eq(#green.findings, 0, "step: the output of a green step is not searched")

    local own = step(HEAD_OUT, 1, { efm = "%f:%l: %m" })
    eq(#own.findings, 0, "step: a step with its own error format keeps it")

    local none = step({ "Segmentation fault" }, 1)
    eq(#none.findings, 0, "step: output that names no test leaves the step whole")

    -- what `ci commit` compares: the new red test behind a step that was red at the base already
    local base = step(BASE_OUT, 1)
    local cls = baseline.classify({ steps = { head } }, { steps = { base } })
    eq(#cls.new, 1, 'commit: the new red test is new (it was "0 new" before)')
    eq(cls.new[1].file, "src/b.test.ts", "commit: ... which")
    eq(#cls.known, 1, "commit: the old one is known")
    eq(cls.known[1].whole, nil, "commit: ... by its test, not as a whole step")
  end

  -- ------------------------------------------------------------- the report

  do
    local r = {
      sha = "abcdef1234567890",
      verdict = "known-red",
      exit = 0,
      exact = true,
      new = {},
      known = { { step = "ui-test", text = "red", whole = true } },
      fixed = {},
      problems = {},
    }
    eq(
      commit.headline(r),
      "ci commit abcdef1 KNOWN-RED 0 new, 1 known (1 compared as a whole), 0 fixed exit 0",
      "report: the headline says a step was compared as a whole"
    )
    local agent = commit.lines(r, true)
    has(agent[2], "known ui-test: red", "report: the known whole step (agent)")
    has(agent[2], commit.WHOLE_NOTE, "report: ... with what that means")
    local term = commit.lines(r, false)
    has(term[2], commit.WHOLE_NOTE, "report: ... in the terminal too")

    r.known = { { step = "ui-test", file = "src/a.test.ts", text = "a > old" } }
    eq(
      commit.headline(r),
      "ci commit abcdef1 KNOWN-RED 0 new, 1 known, 0 fixed exit 0",
      "report: a known test says nothing extra"
    )
  end
end
