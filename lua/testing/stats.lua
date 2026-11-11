---@module 'testing.stats'
-- @cache-allow env
-- (the reading side resolves the metrics file from the environment; nothing a spec sees depends on it)
---@brief `testing stats`: what the heavy runs of this machine cost, from the lines of `testing.metrics`.
---@description
--- ```
--- testing stats [--since=<YYYY-MM-DD|<n>d>] [--repo=<name>] [--repos-root=<dir>] [--json] [--file=<metrics.jsonl>]
--- ```
---
--- Per kind of run (`suite`, `suite-partial`, `ci`, `ci-commit`, `ci-commit-quick`, `land`): how many, the machine
--- minutes in all, the median duration, the wait in the queue, the verdicts; per day the runs and machine minutes; per
--- repository the same; for the suites the share of spec files that came from the cache; for `land` the median time
--- until landed. With `--repos-root` also the pushes: each repository's reflog of `refs/remotes/origin/main` has an
--- "update by push" entry per push (a `testing ci land` too), so runs per push need no record of their own. `--json` prints the document `testing-stats/1` (what the history page of testing-desktop reads). It
--- only reads: allowed on the workstation too.

local M = {}

M.SCHEMA = "testing-stats/1"

M.USAGE = table.concat({
  "usage: testing stats [--since=<YYYY-MM-DD|<n>d>] [--repo=<name>] [--repos-root=<dir>] [--json] [--file=<metrics.jsonl>]",
  "  --since=<day>|<n>d  only runs from that day (UTC) on, or of the last n days",
  "  --repo=<name>       only runs of one repository (its directory name)",
  "  --repos-root=<dir>  also the pushes of each repository below <dir> (its reflog of origin/main): runs per push",
  "  --json              the document testing-stats/1 instead of the table",
  "  --file=<path>       another metrics file (default: the one the runs write, testing.metrics)",
}, "\n")

---@param list number[]
---@return number|nil
local function median(list)
  if #list == 0 then
    return nil
  end
  local s = vim.deepcopy(list)
  table.sort(s)
  local mid = math.floor((#s + 1) / 2)
  if #s % 2 == 1 then
    return s[mid]
  end
  return (s[mid] + s[mid + 1]) / 2
end

---@param x number
---@return number
local function round1(x)
  return math.floor(x * 10 + 0.5) / 10
end

---The UTC day `n` days before `now` (`YYYY-MM-DD`).
---@param n integer
---@param now integer
---@return string
local function days_ago(n, now)
  return os.date("!%Y-%m-%d", now - n * 86400) --[[@as string]]
end

---Sum up the lines.
---@param entries table[] The lines of `testing.metrics.read`.
---@param opts? { since?: string, repo?: string }
---@return table doc `testing-stats/1`
function M.aggregate(entries, opts)
  opts = opts or {}
  local kinds, days, repos = {}, {}, {}
  local first, last
  local n = 0
  local cache = { selected = 0, cached = 0, ran = 0 }
  for _, e in ipairs(entries) do
    local day = type(e.ts) == "string" and e.ts:sub(1, 10) or "?"
    local wanted = (not opts.since or day >= opts.since) and (not opts.repo or e.repo == opts.repo)
    if wanted then
      n = n + 1
      first = (not first or e.ts < first) and e.ts or first
      last = (not last or e.ts > last) and e.ts or last
      local metrics = require("testing.metrics")
      local d = metrics.seconds_of(e, "duration")
      local w = metrics.seconds_of(e, "wait")
      local k = kinds[e.kind]
      if not k then
        k = { runs = 0, seconds = 0, durations = {}, wait = 0, waited = 0, verdicts = {} }
        kinds[e.kind] = k
      end
      k.runs = k.runs + 1
      k.seconds = k.seconds + d
      k.durations[#k.durations + 1] = d
      if w > 0 then
        k.wait = k.wait + w
        k.waited = k.waited + 1
      end
      local v = tostring(e.verdict or "?")
      k.verdicts[v] = (k.verdicts[v] or 0) + 1
      local dd = days[day] or { runs = 0, seconds = 0 }
      dd.runs, dd.seconds = dd.runs + 1, dd.seconds + d
      days[day] = dd
      local repo = tostring(e.repo or "?")
      local rr = repos[repo] or { runs = 0, seconds = 0 }
      rr.runs, rr.seconds = rr.runs + 1, rr.seconds + d
      repos[repo] = rr
      if (e.kind == "suite" or e.kind == "suite-partial") and type(e.files) == "table" then
        cache.selected = cache.selected + (tonumber(e.files.selected) or 0)
        cache.cached = cache.cached + (tonumber(e.files.cached) or 0)
        cache.ran = cache.ran + (tonumber(e.files.ran) or 0)
      end
    end
  end
  local doc = {
    schema = M.SCHEMA,
    since = opts.since or vim.NIL,
    repo = opts.repo or vim.NIL,
    runs = n,
    first = first or vim.NIL,
    last = last or vim.NIL,
    kinds = {},
    days = {},
    repos = {},
    cache = {
      selected = cache.selected,
      cached = cache.cached,
      ran = cache.ran,
      hit_rate = cache.selected > 0 and round1(100 * cache.cached / cache.selected) or vim.NIL,
    },
  }
  local total = 0
  for name, k in pairs(kinds) do
    total = total + k.seconds
    doc.kinds[name] = {
      runs = k.runs,
      minutes = round1(k.seconds / 60),
      median_s = round1(median(k.durations) or 0),
      wait_minutes = round1(k.wait / 60),
      waited = k.waited,
      verdicts = k.verdicts,
    }
  end
  doc.minutes = round1(total / 60)
  for day, dd in pairs(days) do
    doc.days[day] = { runs = dd.runs, minutes = round1(dd.seconds / 60) }
  end
  for repo, rr in pairs(repos) do
    doc.repos[repo] = { runs = rr.runs, minutes = round1(rr.seconds / 60) }
  end
  return doc
end

---The pushes of a checkout: the epoch seconds of the "update by push" entries in its reflog of
---`refs/remotes/<remote>/<branch>` (every `git push` of that branch writes one, `testing ci land` too).
---@param dir string
---@param git? fun(argv: string[], dir: string): integer, string Replaced by a spec.
---@return integer[]
function M.pushes(dir, git)
  git = git
    or function(argv, cwd)
      local ok, res = pcall(function()
        return vim.system(vim.list_extend({ "git" }, argv), { cwd = cwd, text = true }):wait(30000)
      end)
      if not ok or not res then
        return 127, ""
      end
      return res.code or 1, res.stdout or ""
    end
  local code, out = git({
    "reflog",
    "show",
    "--date=unix",
    "--format=%gd %gs",
    "refs/remotes/origin/main",
    "--",
  }, dir)
  local list = {}
  if code ~= 0 then
    return list
  end
  for line in out:gmatch("[^\n]+") do
    local ts, what = line:match("@{(%d+)} (.*)$")
    if ts and what == "update by push" then
      list[#list + 1] = tonumber(ts) --[[@as integer]]
    end
  end
  return list
end

---Add the pushes of each repository of `doc` (a checkout `<root>/<name>`) to it: `pushes` and `runs_per_push` per
---repository, and in all.
---@param doc table `testing-stats/1`
---@param root string
---@param since? string `YYYY-MM-DD` (UTC)
---@param git? fun(argv: string[], dir: string): integer, string
function M.add_pushes(doc, root, since, git)
  local total, runs = 0, 0
  for name, rr in pairs(doc.repos) do
    local dir = vim.fs.joinpath(root, name)
    if vim.uv.fs_stat(dir .. "/.git") then
      local n = 0
      for _, ts in ipairs(M.pushes(dir, git)) do
        if not since or os.date("!%Y-%m-%d", ts) >= since then
          n = n + 1
        end
      end
      rr.pushes = n
      rr.runs_per_push = n > 0 and round1(rr.runs / n) or vim.NIL
      total, runs = total + n, runs + rr.runs
    end
  end
  doc.pushes = total
  doc.runs_per_push = total > 0 and round1(runs / total) or vim.NIL
end

---@param map table<string, any>
---@return string[]
local function sorted_keys(map)
  local keys = vim.tbl_keys(map)
  table.sort(keys)
  return keys
end

-- ── the part `metrics` of testing-export/1 ───────────────────────────────────

---The kinds of run a document names; a line of another kind counts as `other` (the file is untrusted).
---@type table<string, true>
M.EXPORT_KINDS = {
  suite = true,
  ["suite-partial"] = true,
  ci = true,
  ["ci-commit"] = true,
  ["ci-commit-quick"] = true,
  land = true,
}

---Days of the part `metrics` (ending at the last run, not at the clock).
M.EXPORT_DAYS = 90

---The longest run a line may claim; a longer (or negative, or not finite) duration is a broken line and counts 0.
M.EXPORT_MAX_SECONDS = 7 * 86400
---The most spec files a line may claim; more (or a fraction, or not finite) counts 0.
M.EXPORT_MAX_FILES = 100000

---Seconds a document may hold: finite, 0 to `EXPORT_MAX_SECONDS`, else 0 (the canonical encoder refuses `inf`).
---@param x any
---@return number
local function export_seconds(x)
  if type(x) ~= "number" or x ~= x or x < 0 or x > M.EXPORT_MAX_SECONDS then
    return 0
  end
  return x
end

---A count of spec files a document may hold: a whole number, 0 to `EXPORT_MAX_FILES`, else 0.
---@param x any
---@return integer
local function export_files(x)
  x = tonumber(x)
  if not x or x ~= x or x < 0 or x > M.EXPORT_MAX_FILES or x ~= math.floor(x) then
    return 0
  end
  return x --[[@as integer]]
end

---A verdict as a document names it: a short word, else `other`.
---@param v any
---@return string
local function verdict_word(v)
  if type(v) == "string" and #v <= 32 and v:match("^[a-z][a-z0-9%-]*$") then
    return v
  end
  return "other"
end

---@param map table<string, integer>
---@param name string
---@return { [string]: any }[]
local function counted(map, name)
  local list = {}
  for _, key in ipairs(sorted_keys(map)) do
    list[#list + 1] = { [name] = key, n = map[key] }
  end
  return list
end

---The part `metrics` of the document of one repository (testing-export/1, capability `metrics`): what its heavy runs on
---this machine cost, from the lines of `testing.metrics` whose `repo` is the repository's directory name. The days end
---at the last run, not at the clock, and the pushes are counted from the day of the first run on: an export without a
---new run or push stays the same bytes.
---@param entries table[] The lines of `testing.metrics.read`.
---@param name string The directory name of the repository.
---@param pushes? fun(): integer[]|nil The epoch seconds of its pushes (`M.pushes`), asked only when there is a line;
---nil or a nil answer: not known.
---@return table|nil part nil: no line of this repository.
---@return string line What the `rev` of the document follows.
function M.export_part(entries, name, pushes)
  local metrics = require("testing.metrics")
  local mine = {}
  for _, e in ipairs(entries) do
    if
      e.repo == name
      and type(e.ts) == "string"
      and e.ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
    then
      mine[#mine + 1] = e
    end
  end
  if #mine == 0 then
    return nil, "metrics:0"
  end
  table.sort(mine, function(a, b)
    return a.ts < b.ts
  end)
  local first, last = mine[1].ts, mine[#mine].ts
  local y, mo, d = last:match("^(%d+)%-(%d+)%-(%d+)")
  local noon = os.time({
    year = tonumber(y) --[[@as integer]],
    month = tonumber(mo) --[[@as integer]],
    day = tonumber(d) --[[@as integer]],
    hour = 12,
  })
  local cut = os.date("!%Y-%m-%d", noon - (M.EXPORT_DAYS - 1) * 86400) --[[@as string]]
  local kinds, days = {}, {}
  local cache = { selected = 0, cached = 0, ran = 0 }
  local total, backfilled = 0, 0
  for _, e in ipairs(mine) do
    local kind = M.EXPORT_KINDS[e.kind] and e.kind or "other"
    local dur = export_seconds(metrics.seconds_of(e, "duration"))
    local wait = export_seconds(metrics.seconds_of(e, "wait"))
    local k = kinds[kind]
    if not k then
      k = { runs = 0, seconds = 0, durations = {}, wait = 0, waited = 0, verdicts = {} }
      kinds[kind] = k
    end
    k.runs = k.runs + 1
    k.seconds = k.seconds + dur
    k.durations[#k.durations + 1] = dur
    if wait > 0 then
      k.wait, k.waited = k.wait + wait, k.waited + 1
    end
    local v = verdict_word(e.verdict)
    k.verdicts[v] = (k.verdicts[v] or 0) + 1
    total = total + dur
    local day = e.ts:sub(1, 10)
    if day >= cut then
      local dd = days[day] or { runs = 0, seconds = 0 }
      dd.runs, dd.seconds = dd.runs + 1, dd.seconds + dur
      days[day] = dd
    end
    if (kind == "suite" or kind == "suite-partial") and type(e.files) == "table" then
      -- never more from the cache than selected: the hit rate stays a percentage
      local selected = export_files(e.files.selected)
      cache.selected = cache.selected + selected
      cache.cached = cache.cached + math.min(export_files(e.files.cached), selected)
      cache.ran = cache.ran + export_files(e.files.ran)
    end
    if type(e.note) == "string" and e.note:find("^backfilled") then
      backfilled = backfilled + 1
    end
  end
  local kind_list = {}
  for _, kind in ipairs(sorted_keys(kinds)) do
    local k = kinds[kind]
    kind_list[#kind_list + 1] = {
      kind = kind,
      runs = k.runs,
      minutes = round1(k.seconds / 60),
      median_s = round1(median(k.durations) or 0),
      wait_minutes = round1(k.wait / 60),
      waited = k.waited,
      verdicts = counted(k.verdicts, "verdict"),
    }
  end
  local day_list = {}
  for _, day in ipairs(sorted_keys(days)) do
    day_list[#day_list + 1] =
      { day = day, runs = days[day].runs, minutes = round1(days[day].seconds / 60) }
  end
  local n_push = vim.NIL
  local push_list = pushes and pushes() or nil
  if push_list then
    local count = 0
    for _, ts in ipairs(push_list) do
      if os.date("!%Y-%m-%d", ts) >= first:sub(1, 10) then
        count = count + 1
      end
    end
    n_push = count
  end
  local part = {
    runs = #mine,
    minutes = round1(total / 60),
    first = first,
    last = last,
    backfilled = backfilled,
    kinds = kind_list,
    days = day_list,
    cache = {
      selected = cache.selected,
      cached = cache.cached,
      ran = cache.ran,
      hit_rate = cache.selected > 0 and round1(100 * cache.cached / cache.selected) or vim.NIL,
    },
    pushes = n_push,
    runs_per_push = (n_push ~= vim.NIL and n_push > 0) and round1(#mine / n_push) or vim.NIL,
  }
  return part,
    ("metrics:%d:%s:%s"):format(#mine, last, n_push == vim.NIL and "-" or tostring(n_push))
end

---The table for a terminal.
---@param doc table
---@return string[]
function M.lines(doc)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  if doc.runs == 0 then
    add(
      "testing stats: no run recorded" .. (doc.since ~= vim.NIL and (" since " .. doc.since) or "")
    )
    return out
  end
  add(
    ("testing stats: %d run(s), %.1f machine minute(s), %s .. %s%s"):format(
      doc.runs,
      doc.minutes,
      tostring(doc.first):sub(1, 16),
      tostring(doc.last):sub(1, 16),
      doc.repo ~= vim.NIL and ("  (repo " .. doc.repo .. ")") or ""
    )
  )
  add("")
  add(
    ("%-16s %5s %9s %9s %10s  %s"):format(
      "kind",
      "runs",
      "minutes",
      "median s",
      "wait min",
      "verdicts"
    )
  )
  for _, name in ipairs(sorted_keys(doc.kinds)) do
    local k = doc.kinds[name]
    local v = {}
    for _, verdict in ipairs(sorted_keys(k.verdicts)) do
      v[#v + 1] = ("%s %d"):format(verdict, k.verdicts[verdict])
    end
    add(
      ("%-16s %5d %9.1f %9.1f %10.1f  %s"):format(
        name,
        k.runs,
        k.minutes,
        k.median_s,
        k.wait_minutes,
        table.concat(v, ", ")
      )
    )
  end
  if doc.cache.selected > 0 then
    add("")
    add(
      ("suites: %d spec file(s) selected, %d from the cache (%.1f %%), %d ran"):format(
        doc.cache.selected,
        doc.cache.cached,
        doc.cache.hit_rate,
        doc.cache.ran
      )
    )
  end
  add("")
  add(("%-10s %5s %9s"):format("day", "runs", "minutes"))
  for _, day in ipairs(sorted_keys(doc.days)) do
    add(("%-10s %5d %9.1f"):format(day, doc.days[day].runs, doc.days[day].minutes))
  end
  add("")
  if doc.pushes ~= nil then
    add(
      ("pushes: %d, runs per push: %s (runs of the repositories with a checkout)"):format(
        doc.pushes,
        doc.runs_per_push == vim.NIL and "-" or ("%.1f"):format(doc.runs_per_push)
      )
    )
    add("")
    add(("%-24s %5s %9s %6s %9s"):format("repository", "runs", "minutes", "pushes", "runs/push"))
    for _, repo in ipairs(sorted_keys(doc.repos)) do
      local r = doc.repos[repo]
      add(
        ("%-24s %5d %9.1f %6s %9s"):format(
          repo,
          r.runs,
          r.minutes,
          r.pushes and tostring(r.pushes) or "-",
          (r.runs_per_push == nil or r.runs_per_push == vim.NIL) and "-"
            or ("%.1f"):format(r.runs_per_push)
        )
      )
    end
    return out
  end
  add(("%-24s %5s %9s"):format("repository", "runs", "minutes"))
  for _, repo in ipairs(sorted_keys(doc.repos)) do
    add(("%-24s %5d %9.1f"):format(repo, doc.repos[repo].runs, doc.repos[repo].minutes))
  end
  return out
end

---`testing stats ...`
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), metrics?: Testing.Metrics, now?: fun(): integer }
---@return integer
function M.main(argv, sv)
  local opts, json, file = {}, false, nil
  for _, a in ipairs(argv) do
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    if a == "--help" or a == "-h" then
      sv.out(M.USAGE)
      return 0
    elseif a == "--json" then
      json = true
    elseif key == "since" then
      local n = value:match("^(%d+)d$")
      if n then
        opts.since = days_ago(tonumber(n) --[[@as integer]], (sv.now or os.time)())
      elseif value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        opts.since = value
      else
        sv.err("testing stats: --since: a day (2026-11-09) or a number of days (7d)")
        return 2
      end
    elseif key == "repo" and value ~= "" then
      opts.repo = value
    elseif key == "file" and value ~= "" then
      file = value
    elseif key == "repos-root" and value ~= "" then
      opts.repos_root = value
    else
      sv.err("testing stats: unknown argument " .. a)
      sv.err(M.USAGE)
      return 2
    end
  end
  local metrics = require("testing.metrics")
  if not file then
    local m = sv.metrics
      or metrics.from_env(function(name)
        -- the reading side ignores the switches that stop the writing (a child, CI): it reads the user's file
        if name == metrics.OFF_ENV or name == "CI" or name == "TESTING_HEAVY_RUN" then
          return nil
        end
        return os.getenv(name)
      end)
    if not m then
      sv.err("testing stats: no metrics file (set TESTING_METRICS_FILE or --file)")
      return 2
    end
    file = m.path
  end
  local entries, broken = metrics.read(file)
  local doc = M.aggregate(entries, opts)
  if opts.repos_root then
    M.add_pushes(doc, opts.repos_root, opts.since, sv.git)
  end
  doc.file = file
  doc.broken = broken
  if json then
    sv.out(vim.json.encode(doc))
  else
    for _, line in ipairs(M.lines(doc)) do
      sv.out(line)
    end
    if broken > 0 then
      sv.err(("testing stats: %d line(s) of %s could not be read"):format(broken, file))
    end
  end
  return 0
end

return M
