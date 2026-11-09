---@module 'testing.stats'
-- @cache-allow env
-- (the reading side resolves the metrics file from the environment; nothing a spec sees depends on it)
---@brief `testing stats`: what the heavy runs of this machine cost, from the lines of `testing.metrics`.
---@description
--- ```
--- testing stats [--since=<YYYY-MM-DD|<n>d>] [--repo=<name>] [--json] [--file=<metrics.jsonl>]
--- ```
---
--- Per kind of run (`suite`, `suite-partial`, `ci`, `ci-commit`, `ci-commit-quick`, `land`): how many, the machine
--- minutes in all, the median duration, the wait in the queue, the verdicts; per day the runs and machine minutes; per
--- repository the same; for the suites the share of spec files that came from the cache; for `land` the median time
--- until landed. `--json` prints the document `testing-stats/1` (what the history page of testing-desktop reads). It
--- only reads: allowed on the workstation too.

local M = {}

M.SCHEMA = "testing-stats/1"

M.USAGE = table.concat({
  "usage: testing stats [--since=<YYYY-MM-DD|<n>d>] [--repo=<name>] [--json] [--file=<metrics.jsonl>]",
  "  --since=<day>|<n>d  only runs from that day (UTC) on, or of the last n days",
  "  --repo=<name>       only runs of one repository (its directory name)",
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
      local d = type(e.duration_s) == "number" and e.duration_s or 0
      local k = kinds[e.kind]
      if not k then
        k = { runs = 0, seconds = 0, durations = {}, wait = 0, waited = 0, verdicts = {} }
        kinds[e.kind] = k
      end
      k.runs = k.runs + 1
      k.seconds = k.seconds + d
      k.durations[#k.durations + 1] = d
      if type(e.wait_s) == "number" and e.wait_s > 0 then
        k.wait = k.wait + e.wait_s
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

---@param map table<string, any>
---@return string[]
local function sorted_keys(map)
  local keys = vim.tbl_keys(map)
  table.sort(keys)
  return keys
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
