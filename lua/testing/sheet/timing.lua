---@module 'testing.sheet.timing'
---@brief How long the steps of a sheet took over several runs (`testing sheets run --repeat N`): median and spread.
---@description
--- Each run of a sheet hands back `timings` (`Testing.Sheet.Timing`, one per step that ran, measured next to the target:
--- the browser runner, the session) and `measures` (`Testing.Sheet.Measure`). `aggregate` folds the runs into one row
--- per step (and one more per browser `wait`: the time since the step that acted, `kind = "after"`) and per measure,
--- each with its readings, median, min, max and the sample standard deviation; `text` is the table a person reads,
--- the rows go as they are into the document of `--result` (`testing-sheet-run/1`).

local M = {}

---@class Testing.SheetTiming.Stats
---@field runs integer How many readings there are.
---@field median number
---@field min number
---@field max number
---@field sd number The sample standard deviation (0 for one reading).
---@field values number[] The readings, in the order of the runs.

---@class Testing.SheetTiming.Row: Testing.SheetTiming.Stats
---@field size string
---@field n integer
---@field step string What the step is (`click #save`).
---@field kind "step"|"after" `step`: the step itself; `after`: a `wait` from the start of the step that acted (`after_n`).
---@field after_n? integer

---@class Testing.SheetTiming.MeasureRow: Testing.SheetTiming.Stats
---@field size string
---@field n integer
---@field name string
---@field unit? string

---Median, min, max and the sample standard deviation of readings.
---@param values number[] At least one.
---@return Testing.SheetTiming.Stats
function M.stats(values)
  local n, sum = #values, 0
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(values) do
    sum = sum + v
    lo, hi = math.min(lo, v), math.max(hi, v)
  end
  local mean, sq = sum / n, 0
  for _, v in ipairs(values) do
    sq = sq + (v - mean) ^ 2
  end
  return {
    runs = n,
    median = require("testing.sheet").median(values),
    min = lo,
    max = hi,
    sd = n > 1 and math.sqrt(sq / (n - 1)) or 0,
    values = values,
  }
end

---One row per step (and per `wait` since its acting step) and one per measure, in the order they first ran.
---A run that broke off (a red step) only adds the steps it got to.
---@param results Testing.Sheet.Result[] The runs of one sheet.
---@return Testing.SheetTiming.Row[] rows, Testing.SheetTiming.MeasureRow[] measures
function M.aggregate(results)
  local rows, by_key = {}, {}
  local function add(key, make, value)
    local row = by_key[key]
    if not row then
      row = make()
      row.values = {}
      by_key[key] = row
      rows[#rows + 1] = row
    end
    row.values[#row.values + 1] = value
  end
  local measures, by_measure = {}, {}
  for _, res in ipairs(results) do
    for _, t in ipairs(res.timings or {}) do
      add(("%s:%d:step"):format(t.size, t.n), function()
        return { size = t.size, n = t.n, step = t.step, kind = "step" }
      end, t.ms)
      if t.after_ms then
        add(("%s:%d:after"):format(t.size, t.n), function()
          return { size = t.size, n = t.n, step = t.step, kind = "after", after_n = t.after_n }
        end, t.after_ms)
      end
    end
    for _, m in ipairs(res.measures or {}) do
      local key = ("%s:%s:%s"):format(tostring(m.size), tostring(m.n), m.name)
      local row = by_measure[key]
      if not row then
        row = { size = m.size, n = m.n, name = m.name, unit = m.unit, values = {} }
        by_measure[key] = row
        measures[#measures + 1] = row
      end
      -- one reading per run: the median of its `runs`
      row.values[#row.values + 1] = m.value
    end
  end
  for _, list in ipairs({ rows, measures }) do
    for k, row in ipairs(list) do
      list[k] = vim.tbl_extend("force", row, M.stats(row.values))
    end
  end
  return rows, measures
end

---A number of a table cell: milliseconds to a tenth, other units at most 4 significant digits.
---@param v number
---@param ms boolean
---@return string
local function cell(v, ms)
  if ms then
    return ("%.1f"):format(v)
  end
  return (("%.4g"):format(v))
end

---The table of a sheet's timings, one line per row (no trailing newline).
---@param id string The sheet.
---@param runs integer How many runs there were.
---@param rows Testing.SheetTiming.Row[]
---@param measures Testing.SheetTiming.MeasureRow[]
---@return string
function M.text(id, runs, rows, measures)
  local out = {
    ("timings of %s (%d run%s, ms): median, min, max, sd"):format(
      id,
      runs,
      runs == 1 and "" or "s"
    ),
  }
  -- the names are short already (a step is named as a failure line names it, cut at 60 characters): the column is as
  -- wide as the longest, so that "... since step 2" is never cut off
  local lines, width = {}, 0
  local function put(size, n, what, s, ms)
    local name = what:gsub("%s+", " ")
    width = math.max(width, #name)
    lines[#lines + 1] = { size, n, name, s, ms }
  end
  if #rows == 0 and #measures == 0 then
    out[#out + 1] = "  (no step was timed)"
  end
  for _, r in ipairs(rows) do
    put(
      r.size,
      r.n,
      r.kind == "after" and ("%s since step %s"):format(r.step, tostring(r.after_n)) or r.step,
      r,
      true
    )
  end
  for _, m in ipairs(measures) do
    put(
      tostring(m.size),
      m.n or 0,
      ("measure %s%s"):format(m.name, m.unit and (" (" .. m.unit .. ")") or ""),
      m,
      false
    )
  end
  for _, l in ipairs(lines) do
    local size, n, name, s, ms = unpack(l)
    out[#out + 1] = ("  %-10s %3d  %s%s %9s %9s %9s %8s"):format(
      size,
      n,
      name,
      (" "):rep(width - #name),
      cell(s.median, ms),
      cell(s.min, ms),
      cell(s.max, ms),
      cell(s.sd, ms)
    )
  end
  return table.concat(out, "\n")
end

return M
