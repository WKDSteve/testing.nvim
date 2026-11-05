-- TESTS/testing/runlog_spec.lua -- the log of the runs: what a run leaves in it, its bounds, a file that is untrusted
-- input, the statistics, and `testing history` with the words it prints.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local runlog = require("testing.runlog")
  local cli = require("testing.cli")

  local base = vim.fn.tempname() .. "-runlog"
  local root = base .. "/repo"
  vim.fn.mkdir(root, "p")
  local NOW = 1793448000
  local DAY = 86400

  local function entry(over)
    return vim.tbl_extend("force", {
      ts = NOW,
      run = "r",
      kind = "run",
      scope = "full",
      verdict = "green",
      red = {},
    }, over or {})
  end

  local function fresh(name)
    return { state_dir = base .. "/" .. name }
  end

  -- ── appending and reading ──
  do
    local o = fresh("append")
    ok(runlog.append(root, entry({ run = "a", ms = 10, sha = string.rep("a", 40) }), o))
    ok(runlog.append(root, entry({ run = "b", ts = NOW + 1, verdict = "red", red = { "x" } }), o))
    local list, days, notes = runlog.read(runlog.path(root, o))
    eq(#list, 2, "two runs")
    eq(list[1].run, "a", "oldest first")
    eq(list[1].ms, 10, "the duration")
    eq(list[2].red, { "x" }, "the red cases")
    eq(next(days), nil, "no older counts")
    eq(notes, {}, "nothing dropped")
    local refused, why = runlog.append(root, entry({ kind = "other" }), o)
    eq(refused, false, "what is no entry is not written")
    has(why, "not an entry", "and says so")
    eq(#runlog.read(runlog.path(root, o)), 2, "the log is unchanged")
  end

  -- ── a run leaves what it was ──
  do
    local e = runlog.entry_of_run({
      run = { id = "run1", duration_ms = 12, git = { sha = string.rep("b", 40), dirty = true } },
      summary = { pass = 1, fail = 25 },
      cases = (function()
        local cases = { { id = "ok", status = "pass" } }
        for i = 1, 25 do
          cases[#cases + 1] = { id = "red" .. i, status = "fail" }
        end
        return cases
      end)(),
    }, { verdict = "red", full = false, now = NOW })
    eq(e.scope, "partial", "a selection is partial")
    eq(#e.red, runlog.MAX_RED, "the named red cases are bounded")
    eq(e.red_more, 5, "the others are counted")
    eq(e.dirty, true, "a dirty tree is said")
    eq(e.sha, string.rep("b", 40), "the commit")
    ok(runlog.validate(vim.tbl_extend("force", { v = 1 }, e)), "and it is an entry")
    eq(
      runlog.entry_of_run({ run = { id = "x" }, cases = {} }, { verdict = "green", full = true }).scope,
      "full",
      "whole"
    )
  end

  -- ── the file is untrusted ──
  do
    local o = fresh("hostile")
    local path = runlog.path(root, o)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local good = vim.json.encode(vim.tbl_extend("force", { v = 1 }, entry({ run = "good" })))
    local lines = {
      good,
      "not json",
      "[]",
      vim.json.encode({
        v = 2,
        ts = 1,
        run = "r",
        kind = "run",
        scope = "full",
        verdict = "green",
        red = {},
      }),
      vim.json.encode({
        v = 1,
        ts = -5,
        run = "r",
        kind = "run",
        scope = "full",
        verdict = "green",
        red = {},
      }),
      vim.json.encode({
        v = 1,
        ts = 1,
        run = "r",
        kind = "x",
        scope = "full",
        verdict = "green",
        red = {},
      }),
      vim.json.encode({
        v = 1,
        ts = 1,
        run = "r",
        kind = "run",
        scope = "full",
        verdict = "$(x)",
        red = {},
      }),
      vim.json.encode({
        v = 1,
        ts = 1,
        run = "r",
        kind = "run",
        scope = "full",
        verdict = "green",
        red = { 7 },
      }),
    }
    vim.fn.writefile(lines, path)
    local list, _, notes = runlog.read(path)
    eq(#list, 1, "only the good line is read")
    eq(list[1].run, "good", "that one")
    has(notes[1], "7 unusable", "the others are counted")
    local e = runlog.validate({
      v = 1,
      ts = 1,
      run = "r",
      kind = "run",
      scope = "full",
      verdict = "green",
      red = {},
      sha = "not hex",
      profile = "a b",
      ms = -1,
    })
    eq({ e.sha, e.profile, e.ms }, {}, "a field of another form is left out, the line stays")
    vim.fn.mkdir(runlog.path(root, fresh("dir")), "p")
    local _, _, dir_notes = runlog.read(runlog.path(root, fresh("dir")))
    has(dir_notes[1], "not a regular file", "a folder of that name is said")
    vim.fn.writefile({ "not json" }, vim.fs.dirname(path) .. "/runlog-days.json")
    local _, days, day_notes = runlog.read(path)
    eq(next(days), nil, "counts that are no counts are ignored")
    ok(
      vim.tbl_contains(
        vim.tbl_map(function(n)
          return n:find("older runs", 1, true) ~= nil
        end, day_notes),
        true
      ),
      "and said"
    )
  end

  -- ── bounded: old runs become counts ──
  do
    local o = fresh("old")
    local path = runlog.path(root, o)
    ok(
      runlog.append(
        root,
        entry({ ts = NOW - 100 * DAY, run = "old-green" }),
        { state_dir = o.state_dir, now = NOW - 100 * DAY }
      )
    )
    ok(
      runlog.append(
        root,
        entry({ ts = NOW - 100 * DAY, run = "old-red", verdict = "red" }),
        { state_dir = o.state_dir, now = NOW - 100 * DAY }
      )
    )
    ok(
      runlog.append(root, entry({ ts = NOW, run = "new" }), { state_dir = o.state_dir, now = NOW })
    )
    local list, days = runlog.read(path)
    eq(#list, 1, "the old lines left the file")
    eq(list[1].run, "new", "the new one stayed")
    local day = os.date("!%Y-%m-%d", NOW - 100 * DAY)
    eq(days[day], { n = 2, green = 1, red = 1 }, "and they are counted")
    -- a second compaction adds to the counts
    ok(
      runlog.append(
        root,
        entry({ ts = NOW - 100 * DAY, run = "late", verdict = "green" }),
        { state_dir = o.state_dir, now = NOW }
      )
    )
    ok(
      runlog.append(
        root,
        entry({ ts = NOW + 1, run = "next" }),
        { state_dir = o.state_dir, now = NOW + 1 }
      )
    )
    local _, again = runlog.read(path)
    ok(again[day].n >= 2, "the counts stay")

    -- too large: the newest part stays, the rest is counted, and it is not compacted again at the next run
    local big = fresh("big")
    local big_path = runlog.path(root, big)
    local saved = runlog.MAX_BYTES
    runlog.MAX_BYTES = 2000
    for i = 1, 60 do
      ok(
        runlog.append(
          root,
          entry({ ts = NOW + i, run = "run" .. i }),
          { state_dir = big.state_dir, now = NOW + i }
        )
      )
    end
    runlog.MAX_BYTES = saved
    local kept, counted = runlog.read(big_path)
    ok(#kept > 0 and #kept < 60, "too large: only the newest stay: " .. #kept)
    eq(kept[#kept].run, "run60", "the newest of all")
    local total = #kept
    for _, d in pairs(counted) do
      total = total + d.n
    end
    eq(total, 60, "no run is lost: lines and counts add up")
  end

  -- ── the statistics ──
  do
    local sha = string.rep("c", 40)
    local list = {
      entry({ ts = NOW - 40 * DAY, run = "before", verdict = "red", red = { "old" } }),
      entry({
        ts = NOW - 3 * DAY,
        run = "a",
        verdict = "red",
        ms = 100,
        sha = sha,
        dirty = false,
        red = { "flaky", "always" },
      }),
      entry({
        ts = NOW - 2 * DAY,
        run = "b",
        verdict = "red",
        ms = 300,
        sha = sha,
        dirty = false,
        red = { "always" },
      }),
      entry({
        ts = NOW - 2 * DAY,
        run = "sel",
        scope = "partial",
        verdict = "red",
        ms = 9999,
        sha = sha,
        red = { "selected" },
      }),
      entry({
        ts = NOW - 1 * DAY,
        run = "c",
        ms = 200,
        sha = string.rep("d", 40),
        dirty = true,
        red = {},
      }),
      entry({ ts = NOW, run = "ci", kind = "ci", verdict = "red", ms = 5000 }),
    }
    local s = runlog.stats(list, {}, NOW)
    eq({ s.n, s.green, s.red }, { 3, 1, 2 }, "whole runs of the suite only: no selection, no ci")
    eq(s.previous, { n = 1, green = 0, red = 1 }, "the period before")
    eq(s.ms_median, 200, "the median of the whole runs")
    eq(s.ms_p90, 300, "and the 90th percentile")
    eq(s.flaky, { "flaky" }, "red in one whole run of a commit and not in another of the same")
    eq(s.red_top[1], { id = "always", n = 2 }, "most often red first")
    eq(s.red_since, nil, "the last whole run was green")
    eq(#s.days, 4, "the days with a run")
    eq(s.days[#s.days].day, os.date("!%Y-%m-%d", NOW), "the last one is the newest")

    local red_now = runlog.stats({
      entry({ ts = NOW - 2, run = "1" }),
      entry({ ts = NOW - 1, run = "2", verdict = "red" }),
      entry({ ts = NOW - 1, run = "s", scope = "partial" }),
      entry({ ts = NOW, run = "3", verdict = "red" }),
    }, {}, NOW)
    eq(red_now.red_since, NOW - 1, "red since the first of the red whole runs in a row")

    local empty = runlog.stats({}, {}, NOW)
    eq({ empty.n, empty.ms_median }, { 0 }, "no run: nothing to say, no error")
    -- a dirty tree is no statement about the commit
    local dirty = runlog.stats({
      entry({ run = "1", sha = sha, dirty = true, red = { "x" }, verdict = "red" }),
      entry({ run = "2", sha = sha, dirty = false }),
    }, {}, NOW)
    eq(dirty.flaky, {}, "a run with changes in the tree says nothing about the commit")
  end

  -- ── testing history ──
  do
    local o = fresh("cli")
    local function call(...)
      local out, err = {}, {}
      local code = cli.main(vim.list_extend({ "history", root }, { ... }), {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = o.state_dir,
        now = NOW,
      })
      return code, table.concat(out, "\n"), table.concat(err, "\n")
    end
    local code, out = call()
    eq(code, 0, "no log: exit 0")
    has(out, "no run", "and says so")
    ok(
      runlog.append(
        root,
        entry({ ts = NOW - DAY, run = "one", ms = 1500, sha = string.rep("e", 40) }),
        o
      )
    )
    ok(
      runlog.append(
        root,
        entry({ ts = NOW, run = "two", kind = "ci", verdict = "red", profile = "full" }),
        o
      )
    )
    code, out = call()
    eq(code, 0, "exit 0")
    ok(out:find("ci", 1, true) < out:find("eeeeeee", 1, true), "newest first: " .. out)
    local _
    has(out, "1.5s", "the duration")
    _, out = call("--kind=ci")
    eq(out:find("eeeeeee", 1, true), nil, "--kind")
    _, out = call("--verdict=red")
    eq(out:find("eeeeeee", 1, true), nil, "--verdict")
    _, out = call("--since=" .. os.date("!%Y-%m-%d", NOW))
    eq(out:find("eeeeeee", 1, true), nil, "--since")
    _, out = call("--limit=1")
    has(out, "1 more", "--limit says what is left out")
    _, out = call("--format=json")
    eq(#vim.json.decode(out), 2, "json: all of them")
    _, out = call("--format=csv")
    has(out, "time,kind,scope,profile,verdict,ms,sha,dirty,red,run", "csv: its head")
    has(out, "ci,full,full,red", "csv: a line")
    _, out = call("--stats")
    has(out, "last 30 days: 1 whole runs, 1 green, 0 red, 100% green", "the statistics in words")
    _, out = call("--stats", "--format=json")
    eq(vim.json.decode(out).n, 1, "the same numbers as json")
    for _, bad in ipairs({
      "--since=yesterday",
      "--kind=x",
      "--verdict=x",
      "--limit=0",
      "--format=xml",
      "--nope",
    }) do
      eq((call(bad)), 2, bad .. ": exit 2")
    end
    -- a line that could be read as a formula by a spreadsheet stays text
    ok(runlog.append(root, entry({ ts = NOW + 1, run = "=HYPERLINK(1)" }), o))
    _, out = call("--format=csv")
    has(out, "'=HYPERLINK(1)", "csv: a formula stays text")
  end

  vim.fn.delete(base, "rf")
end
