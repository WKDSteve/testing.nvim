-- TESTS/testing/metrics_export_spec.lua -- the part `metrics` of a repository's document of testing-export/1
-- (`testing.stats.export_part`): only the lines of that repository, the days end at the last run (not at the clock),
-- the pushes count from the day of the first run on and are asked only when there is a line, an unknown kind or
-- verdict is counted as `other` (the file is untrusted), and the same lines give the same part.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local stats = require("testing.stats")

  local function line(ts, kind, extra)
    return vim.tbl_extend(
      "force",
      { v = 1, ts = ts, kind = kind, repo = "r", duration_ms = 60000, verdict = "green" },
      extra or {}
    )
  end

  -- no line of the repository: nil, and the pushes are not asked
  local asked = 0
  local part, rev = stats.export_part(
    { line("2026-11-01T10:00:00Z", "suite", { repo = "other" }) },
    "r",
    function()
      asked = asked + 1
      return {}
    end
  )
  eq(part, nil, "none: no part")
  eq(rev, "metrics:0", "none: the rev line")
  eq(asked, 0, "none: the pushes are not asked")

  -- the days: 90 ending at the last run; an old run counts in the sums, not among the days
  local entries = {
    line("2026-06-01T10:00:00Z", "ci-commit", { duration_s = 120, note = "backfilled: by hand" }),
    line("2026-11-01T10:00:00Z", "suite", {
      wait_ms = 6000,
      files = { selected = 10, cached = 7, ran = 3 },
    }),
    line("2026-11-01T12:00:00Z", "suite", { verdict = "red", duration_ms = 180000 }),
    line("2026-11-02T08:00:00Z", "C:/x/y", { verdict = "Red Thing" }),
    line("2026-11-02T09:00:00Z", "land", { verdict = "landed", ts = "yesterday" }),
  }
  -- an older line: seconds instead of milliseconds
  entries[1].duration_ms = nil
  local june, oct31, nov1 =
    os.time({ year = 2026, month = 5, day = 31, hour = 12 }),
    os.time({ year = 2026, month = 10, day = 31, hour = 12 }),
    os.time({ year = 2026, month = 11, day = 1, hour = 12 })
  part = stats.export_part(entries, "r", function()
    return { june, oct31, nov1 }
  end)
  eq(part.runs, 4, "a line without a time of the contract is not counted")
  eq(part.first, "2026-06-01T10:00:00Z", "first")
  eq(part.last, "2026-11-02T08:00:00Z", "last")
  eq(part.backfilled, 1, "the backfilled line")
  eq(part.minutes, 7, "machine minutes: 2 + 1 + 3 + 1")
  eq(
    vim.tbl_map(function(d)
      return d.day
    end, part.days),
    { "2026-11-01", "2026-11-02" },
    "the days end at the last run"
  )
  eq(part.days[1], { day = "2026-11-01", runs = 2, minutes = 4 }, "a day")
  eq(
    vim.tbl_map(function(k)
      return k.kind
    end, part.kinds),
    { "ci-commit", "other", "suite" },
    "the kinds, sorted, an unknown one is other"
  )
  local suite = part.kinds[3]
  eq(suite.runs, 2, "suite: runs")
  eq(suite.median_s, 120, "suite: the median of 60 and 180 s")
  eq(suite.wait_minutes, 0.1, "suite: the wait")
  eq(suite.waited, 1, "suite: runs that waited")
  eq(
    suite.verdicts,
    { { verdict = "green", n = 1 }, { verdict = "red", n = 1 } },
    "suite: the verdicts"
  )
  eq(part.kinds[2].verdicts, { { verdict = "other", n = 1 } }, "a verdict that is no word")
  eq(part.cache, { selected = 10, cached = 7, ran = 3, hit_rate = 70 }, "the cache")
  eq(part.pushes, 2, "pushes from the day of the first run on (the one of May 31 is left out)")
  eq(part.runs_per_push, 2, "runs per push")

  -- a push before the first run does not count; no push known: null
  part = stats.export_part({ entries[2] }, "r", function()
    return { june, oct31, nov1 }
  end)
  eq(part.pushes, 1, "the pushes before the first day are left out")
  eq(part.cache.hit_rate, 70, "hit rate of one run")
  part = stats.export_part({ entries[3] }, "r", nil)
  eq(part.pushes, vim.NIL, "pushes not known: null")
  eq(part.runs_per_push, vim.NIL, "runs per push not known: null")
  eq(part.cache.hit_rate, vim.NIL, "no selected file: hit rate null")

  -- the same lines in another order: the same part and rev line (an unchanged export is the same bytes)
  local a, ra = stats.export_part(entries, "r")
  local reversed = {}
  for i = #entries, 1, -1 do
    reversed[#reversed + 1] = entries[i]
  end
  local b, rb = stats.export_part(reversed, "r")
  eq(a, b, "order: the same part")
  eq(ra, rb, "order: the same rev line")
  eq(ra, "metrics:4:2026-11-02T08:00:00Z:-", "the rev line")
end
