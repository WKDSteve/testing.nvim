---@module 'testing.runlog'
---@brief The log of the runs of a project: what ran when with which result, and what can be said about it.
---@description
---   stdpath('state')/testing/<project>/runlog.jsonl        one line per run, for 90 days
---   stdpath('state')/testing/<project>/runlog-days.json    what is left of older runs: counts per day
---
--- `runs.jsonl` (`testing.history`) keeps 20 runs for `--lf`; `last.json` (`testing.state`) keeps the last result per
--- case. Neither is a log. This one is only read by `testing history` and the export: **it is never part of a verdict**,
--- and a failing read or write is a note, as for the other stores.
---
--- A line is appended under the lock of the file, so the cost of a run does not grow with the log. When the oldest line
--- is past `RETENTION_DAYS`, or the file past `MAX_BYTES`, the old lines move into the counts of their day (a whole
--- rewrite, atomic), so the file stays bounded and the counts stay right.
---
--- **Untrusted input (SEC-32/33).** The files are read back like the other stores: a size cap before decoding, `pcall`
--- around each line, every field checked, a line that fails is dropped and counted in the notes. Nothing from them is
--- used as a path. A case id is the id of the run: relative to the repository, cut, and cleaned again where it leaves
--- the machine (`testing.export`).

local M = {}

M.VERSION = 1
---How long a run stays a line of its own.
M.RETENTION_DAYS = 90
---The file is compacted past this, and not read past twice this.
M.MAX_BYTES = 4 * 1024 * 1024
---Red cases named per run; the rest are counted.
M.MAX_RED = 20
M.MAX_ID_BYTES = 300
---What `stats` looks at, and the period before it that it is compared with.
M.PERIOD_DAYS = 30

local DAY = 86400

---@class Testing.Runlog.Entry
---@field v integer
---@field ts integer Unix time of the end of the run.
---@field run string The id of the run.
---@field kind "run"|"ci"
---@field scope "full"|"partial" `partial`: a selection of the suite; not a statement about the whole of it.
---@field verdict string `green`, `green-partial`, `red`, `error`, `infra` ...
---@field ms? number
---@field sha? string The commit; none when it is not known.
---@field dirty? boolean The tree had changes the commit does not hold.
---@field profile? string `ci` only.
---@field summary? table<string, integer>
---@field red string[] The ids of the red cases, at most `MAX_RED`.
---@field red_more? integer The red cases not named.

---@class Testing.Runlog.Day
---@field n integer
---@field green integer
---@field red integer

---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/runlog.jsonl"
end

---@param path string The path of the log.
---@return string
local function days_path(path)
  return (path:gsub("runlog%.jsonl$", "runlog-days.json"))
end

---@param verdict any
---@return "green"|"red"|"other"
local function tone(verdict)
  if verdict == "green" or verdict == "green-partial" then
    return "green"
  end
  if verdict == "red" or verdict == "error" then
    return "red"
  end
  return "other"
end
M.tone = tone

---A line as it was decoded: the fields that are what they should be, or nil.
---@param raw any
---@return Testing.Runlog.Entry|nil
function M.validate(raw)
  if type(raw) ~= "table" or raw.v ~= M.VERSION then
    return nil
  end
  local ts = raw.ts
  if type(ts) ~= "number" or ts ~= ts or ts < 0 or ts > 4102444800 then
    return nil
  end
  if type(raw.run) ~= "string" or raw.run == "" or #raw.run > 100 then
    return nil
  end
  if raw.kind ~= "run" and raw.kind ~= "ci" then
    return nil
  end
  if raw.scope ~= "full" and raw.scope ~= "partial" then
    return nil
  end
  if type(raw.verdict) ~= "string" or not raw.verdict:match("^[%a%-]+$") or #raw.verdict > 30 then
    return nil
  end
  if type(raw.red) ~= "table" or #raw.red > M.MAX_RED then
    return nil
  end
  local red = {}
  for i = 1, #raw.red do
    local id = raw.red[i]
    if type(id) ~= "string" or id == "" or #id > M.MAX_ID_BYTES then
      return nil
    end
    red[i] = id
  end
  local out = {
    v = M.VERSION,
    ts = ts,
    run = raw.run,
    kind = raw.kind,
    scope = raw.scope,
    verdict = raw.verdict,
    red = red,
  }
  if type(raw.ms) == "number" and raw.ms == raw.ms and raw.ms >= 0 then
    out.ms = raw.ms
  end
  if type(raw.sha) == "string" and raw.sha:match("^%x+$") and #raw.sha <= 64 then
    out.sha = raw.sha
  end
  if type(raw.dirty) == "boolean" then
    out.dirty = raw.dirty
  end
  if type(raw.profile) == "string" and raw.profile:match("^[%w%._%-]+$") and #raw.profile <= 40 then
    out.profile = raw.profile
  end
  if
    type(raw.red_more) == "number"
    and raw.red_more > 0
    and raw.red_more == math.floor(raw.red_more)
  then
    out.red_more = raw.red_more
  end
  if type(raw.summary) == "table" then
    local summary = {}
    for k, v in pairs(raw.summary) do
      if type(k) == "string" and #k <= 20 and type(v) == "number" and v == v and v >= 0 then
        summary[k] = v
      end
    end
    out.summary = summary
  end
  return out
end

---The lines of the log, oldest first, and the counts of the days before them.
---@param path string
---@return Testing.Runlog.Entry[] entries
---@return table<string, Testing.Runlog.Day> days By `YYYY-MM-DD`.
---@return string[] notes What was dropped or ignored.
function M.read(path)
  local entries, days, notes = {}, {}, {}
  local json = require("lib.nvim.json")
  local read = require("lib.nvim.fs.read")
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type ~= "file" then
    notes[#notes + 1] = "the run log is not a regular file: ignored"
  elseif stat and stat.size > M.MAX_BYTES * 2 then
    notes[#notes + 1] = ("the run log is larger than %d bytes: ignored"):format(M.MAX_BYTES * 2)
  elseif stat then
    local text, err = read(path)
    if not text then
      notes[#notes + 1] = "the run log cannot be read: " .. tostring(err)
    else
      local dropped = 0
      for line in text:gmatch("[^\r\n]+") do
        local ok, decoded = pcall(json.decode, line)
        local entry = ok and M.validate(decoded) or nil
        if entry then
          entries[#entries + 1] = entry
        else
          dropped = dropped + 1
        end
      end
      if dropped > 0 then
        notes[#notes + 1] = ("the run log: %d unusable line(s) ignored"):format(dropped)
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.ts < b.ts
  end)
  local dpath = days_path(path)
  local dstat = vim.uv.fs_stat(dpath)
  if dstat and dstat.type == "file" and dstat.size <= M.MAX_BYTES then
    local text = read(dpath)
    local ok, decoded = pcall(json.decode, text or "")
    if
      ok
      and type(decoded) == "table"
      and decoded.v == M.VERSION
      and type(decoded.days) == "table"
    then
      for day, d in pairs(decoded.days) do
        if
          type(day) == "string"
          and day:match("^%d%d%d%d%-%d%d%-%d%d$")
          and type(d) == "table"
          and type(d.n) == "number"
          and type(d.green) == "number"
          and type(d.red) == "number"
        then
          days[day] = { n = d.n, green = d.green, red = d.red }
        end
      end
    else
      notes[#notes + 1] = "the counts of older runs cannot be read: ignored"
    end
  end
  return entries, days, notes
end

---@param ts number
---@return string
local function day_of(ts)
  return os.date("!%Y-%m-%d", ts) --[[@as string]]
end

---@param days table<string, Testing.Runlog.Day>
---@param entry Testing.Runlog.Entry
local function count(days, entry)
  local day = day_of(entry.ts)
  local d = days[day] or { n = 0, green = 0, red = 0 }
  d.n = d.n + 1
  local t = tone(entry.verdict)
  if t == "green" then
    d.green = d.green + 1
  elseif t == "red" then
    d.red = d.red + 1
  end
  days[day] = d
end

---Move what is past the retention, or too much for the file, into the counts of its day. The lock of `path` is held.
---@param path string
---@param now number
---@return boolean ok
---@return string|nil err
local function compact_locked(path, now)
  local entries, days = M.read(path)
  local json = require("lib.nvim.json")
  local atomic = require("lib.nvim.fs.write.atomic")
  local cut = now - M.RETENTION_DAYS * DAY
  local kept = {}
  for _, entry in ipairs(entries) do
    if entry.ts < cut then
      count(days, entry)
    else
      kept[#kept + 1] = entry
    end
  end
  -- the newest half stays when the file is too large even so: a compaction is not needed again at the next run
  local lines = {}
  local size = 0
  for i = #kept, 1, -1 do
    local text = json.encode(kept[i])
    if text and size + #text + 1 <= M.MAX_BYTES / 2 then
      size = size + #text + 1
      table.insert(lines, 1, text)
    else
      for j = i, 1, -1 do
        count(days, kept[j])
      end
      break
    end
  end
  -- the counts first: a crash between the two counts a run twice rather than losing it
  local encoded = json.encode({ v = M.VERSION, days = days })
  if not encoded then
    return false, "cannot encode the counts of older runs"
  end
  local ok, err = atomic(days_path(path), encoded .. "\n", { mkdirp = true })
  if not ok then
    return false, tostring(err)
  end
  return atomic(path, #lines > 0 and (table.concat(lines, "\n") .. "\n") or "", { mkdirp = true })
end

---The time of the first line of the log, without reading the file.
---@param path string
---@return number|nil
local function first_ts(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local line = f:read("*l")
  f:close()
  local ok, decoded = pcall(require("lib.nvim.json").decode, line or "")
  return ok and type(decoded) == "table" and type(decoded.ts) == "number" and decoded.ts or nil
end

---Add a run to the log.
---@param root string
---@param entry table The fields of `Testing.Runlog.Entry` without `v`.
---@param opts? { state_dir?: string, now?: number }
---@return boolean ok
---@return string|nil err
function M.append(root, entry, opts)
  local path = M.path(root, opts)
  local line = vim.tbl_extend("force", { v = M.VERSION }, entry)
  if not M.validate(line) then
    return false, "not an entry of the run log"
  end
  local encoded, eerr = require("lib.nvim.json").encode(line)
  if not encoded then
    return false, "cannot encode the entry: " .. tostring(eerr)
  end
  local locked, ok, err = require("testing.statelock").with(path, function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f, oerr = io.open(path, "ab")
    if not f then
      return false, tostring(oerr)
    end
    local wrote, werr = f:write(encoded, "\n")
    f:close()
    if not wrote then
      return false, tostring(werr)
    end
    local now = (opts and opts.now) or os.time()
    local stat = vim.uv.fs_stat(path)
    local oldest = first_ts(path)
    if
      (stat and stat.size > M.MAX_BYTES)
      or (oldest and oldest < now - (M.RETENTION_DAYS + 1) * DAY)
    then
      return compact_locked(path, now)
    end
    return true
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err
end

---The red cases of a result, as a line holds them.
---@param cases table[]
---@return string[] red
---@return integer|nil more
local function red_of(cases)
  local bad = { fail = true, error = true, timeout = true, crash = true, xpass = true }
  local red, more = {}, 0
  for _, c in ipairs(cases or {}) do
    if bad[c.status] and type(c.id) == "string" then
      if #red < M.MAX_RED and #c.id <= M.MAX_ID_BYTES then
        red[#red + 1] = c.id
      else
        more = more + 1
      end
    end
  end
  return red, more > 0 and more or nil
end

---The line of one `testing run`.
---@param res table The Result-IR.
---@param o { verdict: string, full: boolean, now?: number }
---@return table
function M.entry_of_run(res, o)
  local red, more = red_of(res.cases)
  local git = res.run and res.run.git
  local summary = {}
  for k, v in pairs(res.summary or {}) do
    if type(v) == "number" then
      summary[k] = v
    end
  end
  return {
    ts = o.now or os.time(),
    run = res.run and res.run.id or "unknown",
    kind = "run",
    scope = o.full and "full" or "partial",
    verdict = o.verdict,
    ms = res.run and res.run.duration_ms,
    sha = type(git) == "table" and git.sha or nil,
    dirty = type(git) == "table" and git.dirty or nil,
    summary = summary,
    red = red,
    red_more = more,
  }
end

---The median and the 90th percentile of a list of numbers.
---@param list number[]
---@return number|nil median
---@return number|nil p90
local function spread(list)
  if #list == 0 then
    return nil, nil
  end
  local sorted = vim.deepcopy(list)
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)], sorted[math.ceil(#sorted * 0.9)]
end

---@param entries Testing.Runlog.Entry[]
---@return { n: integer, green: integer, red: integer }
local function tally(entries)
  local t = { n = 0, green = 0, red = 0 }
  for _, e in ipairs(entries) do
    t.n = t.n + 1
    local which = tone(e.verdict)
    if which ~= "other" then
      t[which] = t[which] + 1
    end
  end
  return t
end

---What can be said about the log: the last `PERIOD_DAYS` days, against the period before them. Only whole runs of the
---suite count for the rates and durations: a run of one file says nothing about the suite.
---@param entries Testing.Runlog.Entry[] Oldest first.
---@param days table<string, Testing.Runlog.Day>
---@param now number
---@return table
function M.stats(entries, days, now)
  local from = now - M.PERIOD_DAYS * DAY
  local before = from - M.PERIOD_DAYS * DAY
  local current, previous, ms = {}, {}, {}
  local by_day = {}
  for day, d in pairs(days or {}) do
    by_day[day] = { n = d.n, green = d.green, red = d.red }
  end
  local red_count = {}
  -- by commit: the cases that were red in a run of it, and the whole runs of it
  local commits = {}
  for _, e in ipairs(entries) do
    if e.kind == "run" and e.scope == "full" then
      if e.ts >= from then
        current[#current + 1] = e
        if e.ms then
          ms[#ms + 1] = e.ms
        end
      elseif e.ts >= before then
        previous[#previous + 1] = e
      end
      if e.ts >= from and e.sha and not e.dirty then
        local c = commits[e.sha] or { runs = 0, red = {} }
        c.runs = c.runs + 1
        for _, id in ipairs(e.red) do
          c.red[id] = (c.red[id] or 0) + 1
        end
        commits[e.sha] = c
      end
    end
    if e.ts >= from then
      count(by_day, e)
      for _, id in ipairs(e.red) do
        red_count[id] = (red_count[id] or 0) + 1
      end
    end
  end
  -- flaky: red in one whole run of a commit and not in another whole run of the same commit
  local flaky_set = {}
  for _, c in pairs(commits) do
    for id, n in pairs(c.red) do
      if n < c.runs then
        flaky_set[id] = true
      end
    end
  end
  local flaky = vim.tbl_keys(flaky_set)
  table.sort(flaky)
  local red_top = {}
  for id, n in pairs(red_count) do
    red_top[#red_top + 1] = { id = id, n = n }
  end
  table.sort(red_top, function(a, b)
    if a.n ~= b.n then
      return a.n > b.n
    end
    return a.id < b.id
  end)
  red_top = vim.list_slice(red_top, 1, 10)
  local day_list = {}
  for i = M.PERIOD_DAYS - 1, 0, -1 do
    local day = day_of(now - i * DAY)
    local d = by_day[day]
    if d then
      day_list[#day_list + 1] = { day = day, n = d.n, green = d.green, red = d.red }
    end
  end
  local median, p90 = spread(ms)
  local cur = tally(current)
  -- how long it has been red: the newest whole runs that are red in a row
  local red_since
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.kind == "run" and e.scope == "full" then
      if tone(e.verdict) ~= "red" then
        break
      end
      red_since = e.ts
    end
  end
  return {
    period_days = M.PERIOD_DAYS,
    n = cur.n,
    green = cur.green,
    red = cur.red,
    previous = tally(previous),
    ms_median = median,
    ms_p90 = p90,
    days = day_list,
    flaky = vim.list_slice(flaky, 1, 20),
    red_top = red_top,
    red_since = red_since,
  }
end

M.USAGE = table.concat({
  "usage: testing history [<dir>] [--since=YYYY-MM-DD] [--kind=run|ci] [--verdict=green|red] [--limit=<n>]",
  "                       [--format=text|json|csv] [--stats] [--state-dir=<dir>]",
  "  what ran when with which result, newest first (the log of this project; never part of a verdict)",
  "  --since=<day>     only runs of this day (UTC) and later",
  "  --kind=<kind>     run (testing run, scripts/test.sh) or ci (testing ci)",
  "  --verdict=<v>     green or red",
  "  --limit=<n>       at most this many (default 50; text only: json and csv list all that match)",
  "  --format=<f>      text (default), json, csv",
  "  --stats           the rates, durations, flaky and most often red cases instead of the list",
}, "\n")

---@param argv string[]
---@return table|nil args
---@return string|nil problem
local function parse(argv)
  local args = { format = "text", limit = 50 }
  for _, a in ipairs(argv) do
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    if a == "-h" or a == "--help" then
      args.help = true
    elseif a == "--stats" then
      args.stats = true
    elseif key == "since" then
      if not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        return nil, "--since needs a day: YYYY-MM-DD"
      end
      args.since = value
    elseif key == "kind" then
      if value ~= "run" and value ~= "ci" then
        return nil, "--kind is run or ci"
      end
      args.kind = value
    elseif key == "verdict" then
      if value ~= "green" and value ~= "red" then
        return nil, "--verdict is green or red"
      end
      args.verdict = value
    elseif key == "limit" then
      local n = tonumber(value)
      if not n or n < 1 or n ~= math.floor(n) then
        return nil, "--limit needs a whole number"
      end
      args.limit = n
    elseif key == "format" then
      if value ~= "text" and value ~= "json" and value ~= "csv" then
        return nil, "--format is text, json or csv"
      end
      args.format = value
    elseif key == "state-dir" and value ~= "" then
      args.state_dir = value
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    elseif args.dir then
      return nil, "one directory only"
    else
      args.dir = a
    end
  end
  return args
end

---A field of a CSV line: quoted when it must be, and never read as a formula by a spreadsheet.
---@param value any
---@return string
local function csv_field(value)
  if value == nil then
    return ""
  end
  local s = tostring(value)
  if s:match("^[=+%-@\t\r]") then
    s = "'" .. s
  end
  if s:find('[",\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

---@param entries Testing.Runlog.Entry[]
---@param args table
---@return Testing.Runlog.Entry[] Newest first.
local function selected(entries, args)
  local out = {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    local keep = (not args.kind or e.kind == args.kind)
      and (not args.verdict or tone(e.verdict) == args.verdict)
      and (not args.since or day_of(e.ts) >= args.since)
    if keep then
      out[#out + 1] = e
    end
  end
  return out
end

---`testing history`.
---@param argv string[] The arguments after `history`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string, now?: number }
---@return integer exit 0 printed, 2 usage
function M.main(argv, sv)
  local args, problem = parse(argv)
  if not args then
    sv.err("testing history: " .. tostring(problem))
    sv.err(M.USAGE)
    return 2
  end
  if args.help then
    sv.out(M.USAGE)
    return 0
  end
  local dir = args.dir or "."
  if vim.fn.isdirectory(dir) ~= 1 then
    sv.err(("testing history: %s is not a directory"):format(dir))
    return 2
  end
  local path = M.path(
    vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")),
    { state_dir = args.state_dir or sv.state_dir }
  )
  local entries, days, notes = M.read(path)
  for _, n in ipairs(notes) do
    sv.err("testing history: note: " .. n)
  end
  local now = sv.now or os.time()
  local json = require("lib.nvim.json")
  if args.stats then
    local s = M.stats(entries, days, now)
    if args.format == "json" then
      sv.out((json.encode(s)))
      return 0
    end
    local rate = function(t)
      return t.green + t.red > 0
          and ("%d%%"):format(math.floor(t.green / (t.green + t.red) * 100 + 0.5))
        or "-"
    end
    sv.out(
      ("last %d days: %d whole runs, %d green, %d red, %s green"):format(
        s.period_days,
        s.n,
        s.green,
        s.red,
        rate(s)
      )
    )
    sv.out(
      ("the %d days before: %d whole runs, %s green"):format(
        s.period_days,
        s.previous.n,
        rate(s.previous)
      )
    )
    if s.ms_median then
      sv.out(
        ("duration: median %.1f s, 90%% below %.1f s"):format(s.ms_median / 1000, s.ms_p90 / 1000)
      )
    end
    if s.red_since then
      sv.out("red since " .. os.date("!%Y-%m-%d %H:%M", s.red_since) .. " UTC")
    end
    for _, id in ipairs(s.flaky) do
      sv.out("flaky: " .. id)
    end
    for _, r in ipairs(s.red_top) do
      sv.out(("red %d x: %s"):format(r.n, r.id))
    end
    return 0
  end
  local list = selected(entries, args)
  if args.format == "json" then
    sv.out((json.encode(list)))
    return 0
  end
  if args.format == "csv" then
    sv.out("time,kind,scope,profile,verdict,ms,sha,dirty,red,run")
    for _, e in ipairs(list) do
      local fields = {
        os.date("!%Y-%m-%dT%H:%M:%SZ", e.ts),
        e.kind,
        e.scope,
        e.profile,
        e.verdict,
        e.ms,
        e.sha,
        e.dirty,
        #e.red + (e.red_more or 0),
        e.run,
      }
      for i = 1, 10 do
        fields[i] = csv_field(fields[i])
      end
      sv.out(table.concat(fields, ",", 1, 10))
    end
    return 0
  end
  if #list == 0 then
    sv.out("testing history: no run")
    return 0
  end
  for i = 1, math.min(#list, args.limit) do
    local e = list[i]
    sv.out(
      ("%s  %-3s %-7s %-13s %8s  %s%s"):format(
        os.date("!%Y-%m-%d %H:%M", e.ts),
        e.kind,
        e.scope,
        e.verdict,
        e.ms and ("%.1fs"):format(e.ms / 1000) or "-",
        e.sha and e.sha:sub(1, 7) or "-",
        (#e.red + (e.red_more or 0)) > 0 and ("  %d red"):format(#e.red + (e.red_more or 0)) or ""
      )
    )
  end
  if #list > args.limit then
    sv.out(("... %d more (--limit)"):format(#list - args.limit))
  end
  return 0
end

return M
