-- TESTS/testing/case_window_start_spec.lua -- `timeouts.case_ms` starts with the first case. What a busted file
-- does before it (a template built once in a `describe` body) is not a stuck case, only `file_ms` counts, as for the
-- hard limit of a child (docs/CONFIG.md). A file that hangs there is still stopped, and a case that hangs after such
-- a body still has its own window.

-- The clock is a stopwatch inside the throwaway specs below; every assertion reads a status or a message.
-- @cache-allow time

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local inproc = require("testing.run.inproc")
  local timeout = require("testing.run.timeout")

  -- Wide enough that a stalled machine cannot eat it: the setup runs three windows, a pass means no window was running.
  local CASE_MS = 400
  local SETUP_MS = 3 * CASE_MS

  local SPIN = ("local until_ = vim.uv.hrtime() + %d * 1e6\n  while vim.uv.hrtime() < until_ do end\n"):format(
    SETUP_MS
  )

  ---@param body string The text of the spec file
  ---@param timeouts table
  ---@return table report
  local function run(body, timeouts)
    local root = S.new_root()
    local file =
      S.project(root, { ["TESTS/a_spec.lua"] = body }, { "TESTS/a_spec.lua" }, "busted")[1]
    return inproc.run({ root = root, files = { file }, timeouts = timeouts })
  end

  ---@param report table
  ---@return string[]
  local function statuses(report)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      out[#out + 1] = c.name .. ":" .. c.status
    end
    return out
  end

  ---@param report table
  ---@return string
  local function messages(report)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      out[#out + 1] = c.error and tostring(c.error.message) or ""
    end
    return table.concat(out, "\n")
  end

  -- -------------------------------------------------------
  -- The guard
  -- -------------------------------------------------------

  do
    local now = 0
    local function clock()
      return now
    end

    local g = timeout.start({ case_ms = 100, defer_case = true, clock = clock })
    eq(g.case_deadline, nil, "defer_case: no window yet")
    g:first_case()
    eq(g.case_deadline, 100, "the first case opens it")
    now = 50
    g:first_case()
    eq(g.case_deadline, 100, "a later first_case moves nothing")
    now = 60
    g:arm_case()
    eq(g.case_deadline, 160, "arm_case still opens the next one")
    g:stop()

    now = 0
    local late = timeout.start({ case_ms = 100, defer_case = true, clock = clock })
    now = 70
    late:arm_case()
    now = 80
    late:first_case()
    eq(late.case_deadline, 170, "after arm_case (a skipped first case) the window stays")
    late:stop()

    now = 0
    local plain = timeout.start({ case_ms = 100, clock = clock })
    eq(plain.case_deadline, 100, "without defer_case the window opens at once")
    now = 40
    plain:first_case()
    eq(plain.case_deadline, 100, "and first_case does not move it")
    plain:stop()

    local stopped = timeout.start({ case_ms = 100, defer_case = true, clock = clock })
    stopped:stop()
    stopped:first_case()
    eq(stopped.case_deadline, nil, "a stopped guard opens nothing")
  end

  -- -------------------------------------------------------
  -- A file in process
  -- -------------------------------------------------------

  do
    local rep = run(
      'describe("d", function()\n  '
        .. SPIN
        .. '  it("one", function() assert.is_true(true) end)\nend)\n',
      { case_ms = CASE_MS }
    )
    eq(statuses(rep), { "one:pass" }, "a describe body past case_ms: no timeout")
  end

  do
    local rep = run(
      ('describe("d", function()\n  vim.wait(%d, function() return false end)\n'):format(SETUP_MS)
        .. '  it("one", function() assert.is_true(true) end)\nend)\n',
      { case_ms = CASE_MS }
    )
    eq(statuses(rep), { "one:pass" }, "vim.wait in the body is not clamped to case_ms")
  end

  do
    local rep =
      run(SPIN .. 'it("one", function() assert.is_true(true) end)\n', { case_ms = CASE_MS })
    eq(statuses(rep), { "one:pass" }, "the same at the top of the file")
  end

  do
    local rep = run(
      'describe("d", function()\n  '
        .. SPIN
        .. '  it("hung", function() while true do end end)\n  it("after", function() assert.is_true(true) end)\nend)\n',
      { case_ms = CASE_MS, file_ms = 15000 }
    )
    eq(
      statuses(rep),
      { "hung:timeout", "after:pass" },
      "a case that hangs after a long body has its own window, and the next case runs"
    )
    ok(messages(rep):find("case exceeded", 1, true) ~= nil, "named as the case: " .. messages(rep))
  end

  do
    local rep = run(
      'describe("d", function()\n  while true do end\n  it("never", function() end)\nend)\n',
      { case_ms = CASE_MS, file_ms = SETUP_MS }
    )
    local timed_out = false
    for _, c in ipairs(rep.result.cases) do
      timed_out = timed_out or c.status == "timeout"
    end
    ok(timed_out, "a body that hangs is stopped by file_ms: " .. vim.inspect(statuses(rep)))
    ok(messages(rep):find("file exceeded", 1, true) ~= nil, "named as the file: " .. messages(rep))
  end

  -- -------------------------------------------------------
  -- A real child: the guard inside and the hard limit outside say the same
  -- -------------------------------------------------------

  do
    local root = S.new_root()
    -- Past case_ms plus the grace of S.run (300 ms): a case window running here would end the file either way.
    local files = S.project(root, {
      ["TESTS/a_spec.lua"] = 'describe("d", function()\n  '
        .. SPIN
        .. '  it("one", function() assert.is_true(true) end)\nend)\n',
    }, { "TESTS/a_spec.lua" }, "busted")
    local rep = S.run(root, files, { timeouts = { case_ms = CASE_MS, file_ms = 60000 } })
    eq(S.statuses(rep), { "TESTS/a_spec.lua:pass" }, "in a child neither of them fires")
  end

  S.cleanup()
end
