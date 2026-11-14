---@module 'testing.explorer.live'
---@brief A run that is going, laid over the last result: which cases are queued, running, done.
---@description
--- The events of a run (`testing.run.events`, read by `testing.run.events_reader`) go in one by one; what a tree
--- has to draw again comes out. Pure: no file, no timer, no window.
---
---   run_start   the cases of the planned files are `queued`
---   file_start  the cases of the file are `running`
---   case        the case has its result: `testing.state.apply_case`, the mark is gone
---   file_end    cases of the file that got no result (the run was narrowed to others) show what they showed before
---   run_done    every mark is gone, whether the run ended or was killed: no case stays `running`
---
--- `queued` and `running` are marks of this module, never statuses of the store: the store holds what a case
--- last DID, and that is what is left when the marks go. A file that is one case and a file whose cases the store
--- does not know yet (it never ran) are marked as files.
---
--- The events are untrusted like a result file: a file name that does not stay inside the project is not marked
--- (`testing.state.inside`), a case that is not usable is refused by the store.

local M = {}

---@class Testing.Explorer.Live
---@field st Testing.State
---@field marks table<string, string>  case id -> `queued` | `running`
---@field file_marks table<string, string>  spec file -> `queued` | `running` (while it has no case of its own in the store)
---@field fresh table<string, true>  spec files that got a result in this run: what the store says of them is current
---@field active boolean  a run is going
---@field package _by_file table<string, string[]>  spec file -> ids of its cases

---@class Testing.Explorer.Live.Dirty
---@field cases table<string, true>  ids of the cases that show something else now
---@field files table<string, true>  spec files whose summary changed
---@field done boolean  the run is over: read the stored result again

---A session over a state. The state is changed in place by `feed` (`apply_case`).
---@param st Testing.State
---@return Testing.Explorer.Live
function M.new(st)
  local by_file = {}
  for _, case in ipairs(st.cases) do
    local list = by_file[case.file]
    if not list then
      list = {}
      by_file[case.file] = list
    end
    list[#list + 1] = case.id
  end
  return { st = st, marks = {}, file_marks = {}, fresh = {}, active = false, _by_file = by_file }
end

---What a case shows right now: its mark while it has one, else what the store says.
---@param live Testing.Explorer.Live
---@param id string
---@return string|nil
function M.status(live, id)
  local mark = live.marks[id]
  if mark then
    return mark
  end
  local case = require("testing.state").case(live.st, id)
  return case and case.status or nil
end

---@param live Testing.Explorer.Live
---@param file string
---@param mark string|nil  nil takes the marks of the file away
---@param dirty Testing.Explorer.Live.Dirty
local function mark_file(live, file, mark, dirty)
  local ids = live._by_file[file]
  if ids and #ids > 0 then
    for _, id in ipairs(ids) do
      if live.marks[id] ~= mark and (mark ~= nil or live.marks[id] ~= nil) then
        live.marks[id] = mark
        dirty.cases[id] = true
      end
    end
    if live.file_marks[file] ~= nil then
      live.file_marks[file] = nil
    end
  elseif live.file_marks[file] ~= mark then
    live.file_marks[file] = mark
  else
    return
  end
  dirty.files[file] = true
end

---Take one event in.
---@param live Testing.Explorer.Live
---@param ev table  An event as `testing.run.events_reader` hands it out (validated).
---@param dirty? Testing.Explorer.Live.Dirty  Added to (several events, one answer).
---@return Testing.Explorer.Live.Dirty
function M.feed(live, ev, dirty)
  dirty = dirty or { cases = {}, files = {}, done = false }
  local kind = type(ev) == "table" and ev.event or nil
  local inside = require("testing.state").inside
  if kind == "run_start" then
    live.active = true
    for _, file in ipairs(type(ev.files) == "table" and ev.files or {}) do
      if inside(file) then
        mark_file(live, file, "queued", dirty)
      end
    end
  elseif kind == "file_start" and inside(ev.file) then
    live.active = true
    mark_file(live, ev.file, "running", dirty)
  elseif kind == "case" then
    local known = require("testing.state").case(live.st, ev.id) ~= nil
    local case = require("testing.state").apply_case(live.st, ev)
    if case then
      if not known then
        local list = live._by_file[case.file]
        if not list then
          list = {}
          live._by_file[case.file] = list
        end
        list[#list + 1] = case.id
      end
      live.marks[case.id] = nil
      live.fresh[case.file] = true
      dirty.cases[case.id] = true
      dirty.files[case.file] = true
    end
  elseif kind == "file_end" and inside(ev.file) then
    mark_file(live, ev.file, nil, dirty)
  elseif kind == "run_done" then
    for id in pairs(live.marks) do
      dirty.cases[id] = true
    end
    for file in pairs(live.file_marks) do
      dirty.files[file] = true
    end
    for file, ids in pairs(live._by_file) do
      for _, id in ipairs(ids) do
        if live.marks[id] then
          dirty.files[file] = true
          break
        end
      end
    end
    live.marks, live.file_marks, live.active = {}, {}, false
    dirty.done = true
  end
  return dirty
end

---The summary of a spec file as the run stands: its cases by what they show, the marks counted as such.
---@param live Testing.Explorer.Live
---@param file string
---@return { total: integer, counts: table<string, integer>, red: integer, mark: string|nil }
function M.file_summary(live, file)
  local state = require("testing.state")
  local out = { total = 0, counts = {}, red = 0, mark = live.file_marks[file] }
  for _, id in ipairs(live._by_file[file] or {}) do
    local case = state.case(live.st, id)
    if case then
      out.total = out.total + 1
      local mark = live.marks[id]
      if mark then
        -- running wins over queued: a file is running as soon as one of its cases is
        out.mark = (mark == "running" or out.mark == "running") and "running" or mark
      else
        out.counts[case.status] = (out.counts[case.status] or 0) + 1
      end
    end
  end
  local nodes = require("testing.explorer.nodes")
  for status, n in pairs(out.counts) do
    if nodes.RED[status] then
      out.red = out.red + n
    end
  end
  return out
end

return M
