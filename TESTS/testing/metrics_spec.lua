-- TESTS/testing/metrics_spec.lua -- one line per heavy run (testing.metrics) and `testing stats` over them: where the
-- file lives (never below a throwaway stdpath), the switches that stop writing (off, a child of a heavy run, CI), the
-- line itself, the move aside at the size limit, broken lines, the sums of `testing stats`, and that a suite run and a
-- `testing ci` with its suite write one line each (never a second line for the suite inside the pipeline).

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end
  local metrics = require("testing.metrics")
  local stats = require("testing.stats")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-metrics"
  vim.fn.mkdir(tmp, "p")

  -- where, and when not
  local function env(map)
    return function(name)
      return map[name]
    end
  end
  eq(
    metrics.from_env(env({ LOCALAPPDATA = "C:/U/AppData/Local" })).path,
    "C:/U/AppData/Local/testing/metrics.jsonl",
    "where: LOCALAPPDATA on Windows"
  )
  eq(
    metrics.from_env(env({ XDG_DATA_HOME = "/x" })).path,
    "/x/testing/metrics.jsonl",
    "where: XDG_DATA_HOME"
  )
  eq(
    metrics.from_env(env({ HOME = "/h" })).path,
    "/h/.local/share/testing/metrics.jsonl",
    "where: ~/.local/share"
  )
  eq(
    metrics.from_env(env({ TESTING_METRICS_FILE = "/f.jsonl", HOME = "/h" })).path,
    "/f.jsonl",
    "where: TESTING_METRICS_FILE"
  )
  eq(metrics.from_env(env({ HOME = "/h", TESTING_METRICS = "off" })), nil, "off by hand")
  eq(metrics.from_env(env({ HOME = "/h", CI = "true" })), nil, "off in CI")
  eq(
    metrics.from_env(env({ HOME = "/h", TESTING_HEAVY_RUN = "tok" })),
    nil,
    "off in a child of a heavy run (its line is the parent's)"
  )
  eq(metrics.from_env(env({})), nil, "nowhere to write: off")

  -- a line, and nothing without the entry's metrics
  local m = { path = tmp .. "/m.jsonl", host = "h1" }
  ok(not metrics.record(nil, { kind = "suite" }), "record: no metrics, no line")
  ok(
    metrics.record(m, {
      kind = "ci-commit",
      repo = "r",
      sha = "abc",
      duration_s = 12.345,
      wait_s = 3,
      verdict = "clean",
    }),
    "record: written"
  )
  local entries, broken = metrics.read(m.path)
  eq(#entries, 1, "read: one line")
  eq(broken, 0, "read: nothing broken")
  local e = entries[1]
  eq(
    { e.v, e.kind, e.repo, e.host, e.duration_s, e.wait_s },
    { 1, "ci-commit", "r", "h1", 12.3, 3 },
    "the line"
  )
  ok(type(e.ts) == "string" and e.ts:match("^%d%d%d%d%-%d%d%-%d%dT") ~= nil, "the line: a UTC time")
  ok(e.os == "windows" or e.os == "linux" or e.os == "macos", "the line: the system")

  -- broken lines are skipped and counted
  local f = assert(io.open(m.path, "ab"))
  f:write("not json\n", '{"v":99,"kind":"x"}\n')
  f:close()
  entries, broken = metrics.read(m.path)
  eq({ #entries, broken }, { 1, 2 }, "read: a broken line and another version are skipped")

  -- the move aside at the limit
  local saved_max = metrics.MAX_BYTES
  metrics.MAX_BYTES = 10
  metrics.record(m, { kind = "land", repo = "r", duration_s = 1, verdict = "landed" })
  metrics.MAX_BYTES = saved_max
  ok(vim.uv.fs_stat(tmp .. "/m.1.jsonl") ~= nil, "limit: the old file moved aside")
  entries = metrics.read(m.path)
  eq(#entries, 2, "limit: both parts are read")

  -- the sums
  local doc = stats.aggregate({
    {
      ts = "2026-11-08T10:00:00Z",
      kind = "ci-commit",
      repo = "a",
      duration_s = 600,
      verdict = "clean",
    },
    {
      ts = "2026-11-09T10:00:00Z",
      kind = "ci-commit",
      repo = "a",
      duration_s = 720,
      wait_s = 120,
      verdict = "regression",
    },
    {
      ts = "2026-11-09T11:00:00Z",
      kind = "suite",
      repo = "b",
      duration_s = 60,
      verdict = "green",
      files = { selected = 10, cached = 4, ran = 6 },
    },
    {
      ts = "2026-11-09T12:00:00Z",
      kind = "land",
      repo = "a",
      duration_s = 300,
      verdict = "landed",
    },
  })
  eq(doc.runs, 4, "stats: runs")
  eq(doc.minutes, 28, "stats: machine minutes (1680 s)")
  eq(doc.kinds["ci-commit"].runs, 2, "stats: per kind")
  eq(doc.kinds["ci-commit"].median_s, 660, "stats: the median of a kind")
  eq(doc.kinds["ci-commit"].wait_minutes, 2, "stats: the wait")
  eq(doc.kinds["ci-commit"].verdicts, { clean = 1, regression = 1 }, "stats: the verdicts")
  eq(doc.cache.hit_rate, 40, "stats: the cache share of the suites")
  eq(doc.days["2026-11-09"], { runs = 3, minutes = 18 }, "stats: per day")
  eq(doc.repos.a.runs, 3, "stats: per repository")
  eq(
    stats.aggregate({ { ts = "2026-11-08T10:00:00Z", kind = "x" } }, { since = "2026-11-09" }).runs,
    0,
    "stats: --since"
  )
  eq(
    stats.aggregate({ { ts = "2026-11-09T10:00:00Z", kind = "x", repo = "a" } }, { repo = "b" }).runs,
    0,
    "stats: --repo"
  )

  -- the command
  local out, err = {}, {}
  local function sv()
    out, err = {}, {}
    return {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      now = function()
        return os.time({ year = 2026, month = 11, day = 10, hour = 12 })
      end,
    }
  end
  eq(stats.main({ "--file=" .. m.path }, sv()), 0, "stats main: exit 0")
  has(table.concat(out, "\n"), "ci-commit", "stats main: the table names the kinds")
  has(table.concat(err, "\n"), "could not be read", "stats main: says that lines were broken")
  eq(stats.main({ "--file=" .. m.path, "--json" }, sv()), 0, "stats main --json")
  local jdoc = vim.json.decode(out[1])
  eq(jdoc.schema, "testing-stats/1", "stats main --json: the document")
  eq(stats.main({ "--since=x" }, sv()), 2, "stats main: a bad --since")
  eq(stats.main({ "--frob" }, sv()), 2, "stats main: an unknown argument")

  -- the wiring: a suite run writes one line; `testing ci` with its suite one `ci` line, no second `suite` line
  local proj = tmp .. "/proj"
  local function put(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put(proj .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  put(proj .. "/lua/proj/init.lua", "return {}\n")
  put(
    proj .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  local wired = { path = tmp .. "/wired.jsonl", host = "h" }
  local cli = require("testing.cli")
  local function main(argv)
    return cli.main(argv, {
      out = function() end,
      err = function() end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      metrics = wired,
      affected = { getenv = function() end, provider = false },
    })
  end
  main({ proj, "--no-cache" })
  entries = metrics.read(wired.path)
  eq(#entries, 1, "wiring: a suite run writes one line")
  eq(entries[1] and entries[1].kind, "suite", "wiring: ... of kind suite")
  eq(
    entries[1] and entries[1].files and entries[1].files.ran,
    1,
    "wiring: ... with the spec files that ran"
  )
  main({ "ci", "--root=" .. proj, "--step=suite", "--no-agent" })
  entries = metrics.read(wired.path)
  eq(#entries, 2, "wiring: testing ci writes one more line, not two")
  eq(entries[2] and entries[2].kind, "ci", "wiring: ... of kind ci")
  ok(
    entries[2] and type(entries[2].steps) == "table" and entries[2].steps.suite ~= nil,
    "wiring: ... with its steps"
  )
  main({ "stats", "--file=" .. wired.path })
  main({ proj, "--no-cache", "--file", "TESTS/a_spec.lua" })
  entries = metrics.read(wired.path)
  eq(entries[3] and entries[3].kind, "suite-partial", "wiring: a selected suite is suite-partial")

  vim.fn.delete(tmp, "rf")
end
