---@module 'testing.explorer.ci'
---@brief The last pipeline run of a project (`testing ci`) as tree nodes: the pipeline, its steps, their findings.
---@description
---   Pipeline fast            ci          the worst of its steps, red over all, the time
---     stylua                 ci_step     `status` from its state
---     luacheck               ci_step
---       lua/x.lua:3: ...     ci_finding  `path`, `data.lnum`, `data.col`
---
--- The document is `ci.json` in the state folder of the project (`testing-ci/1`, the one `:Testing ci status`
--- shows). **It is untrusted input** like every file there: a size cap before decoding, `pcall` around the decode,
--- every field checked, lists bounded, the words of tools (finding texts, reasons) cleaned of control characters
--- and cut. A step or profile name becomes an argument of the next run (`--step=<name>`): one that is not a plain
--- name is dropped. The file of a finding is only a place to jump to when it stays inside the project.
---
--- A step is one unit for the tree, like a case: its state is its status, its findings stand below it and count
--- nothing. `testing.explorer.nodes` draws and adds up the nodes built here.
---
--- **A run that is going** (`M.live_start`, `M.live_feed`): the events of a pipeline run started from the editor
--- (`testing.ci.editor.listen`, testing-ci-events/1) make a document of their own, laid over the last one while
--- the run goes. Pure: no file, no timer, no window.
---
---   run_start       the planned steps are `queued`; the pipeline node asks to be open
---   step_start      the step is `running`
---   suite_progress  the running step shows how far it is ("12/187")
---   step_end        the step has its state and its time. The findings are not in the event: a step that has
---                   some says how many, and lists them when the run has ended
---   run_done        the session is over, whether the run ended or was killed: `ci.json` is read again, and that
---                   is the document the run wrote, or the last one when it wrote none
---
--- The events are untrusted like the document: the same checks, field by field.

local M = {}

---Largest `ci.json` read (bytes).
M.MAX_BYTES = 4 * 1024 * 1024
---Most steps of a pipeline shown.
M.MAX_STEPS = 200
---Most findings shown below one step.
M.MAX_FINDINGS = 200

--- The state of a step as the status the tree adds up with (`testing.explorer.nodes.SEVERITY`). A state this
--- module does not know is `never`: not green.
---@type table<string, string>
M.STATUS = {
  green = "pass",
  proven = "pass",
  red = "fail",
  infra = "error",
  error = "error",
  skipped = "skip",
  running = "running",
  queued = "queued",
}

---@class Testing.Explorer.Ci.Finding
---@field file? string  Relative to the project, inside it; nil when the tool named none that is usable.
---@field line? integer
---@field col? integer  1-based, as tools print it.
---@field text string

---@class Testing.Explorer.Ci.Step
---@field name string
---@field state string
---@field ms number
---@field reason? string
---@field findings Testing.Explorer.Ci.Finding[]
---@field findings_total integer
---@field progress? string  How far a running step is (a run that is going).

---@class Testing.Explorer.Ci.Doc
---@field profile string
---@field verdict string
---@field time? string
---@field steps Testing.Explorer.Ci.Step[]
---@field live? boolean  The document of a run that is going (`M.live_start`).

---A name that may go on a command line as `--step=<name>` / a profile.
---@param s any
---@return string|nil
local function name_of(s)
  if type(s) == "string" and #s <= 64 and s:match("^[%w_][%w_.:%-]*$") then
    return s
  end
  return nil
end

---@param n any
---@param max number
---@return integer|nil
local function whole(n, max)
  if type(n) == "number" and n == math.floor(n) and n >= 1 and n <= max then
    return n
  end
  return nil
end

---Check a decoded document. Never raises.
---@param raw any
---@return Testing.Explorer.Ci.Doc|nil
function M.validate(raw)
  if type(raw) ~= "table" or raw.schema ~= "testing-ci/1" or type(raw.steps) ~= "table" then
    return nil
  end
  local state = require("testing.state")
  local profile = name_of(raw.profile)
  if not profile then
    return nil
  end
  local doc = {
    profile = profile,
    verdict = name_of(raw.verdict) or "unknown",
    time = type(raw.time) == "string" and state.title(raw.time:sub(1, 40)) or nil,
    steps = {},
  }
  local seen = {}
  for i = 1, math.min(#raw.steps, M.MAX_STEPS) do
    local step = raw.steps[i]
    local name = type(step) == "table" and name_of(step.name) or nil
    if name and not seen[name] then
      seen[name] = true
      local findings = {}
      local list = type(step.findings) == "table" and step.findings or {}
      for j = 1, math.min(#list, M.MAX_FINDINGS) do
        local f = list[j]
        local text = type(f) == "table" and state.title(f.text) or nil
        if text then
          local file = f.file
          if type(file) == "string" then
            file = file:gsub("\\", "/")
          end
          findings[#findings + 1] = {
            file = state.inside(file) and file or nil,
            line = whole(f.line, 1e7),
            col = whole(f.col, 1e5),
            text = text,
          }
        end
      end
      local ms = step.ms
      if type(ms) ~= "number" or ms ~= ms or ms < 0 or ms > 1e12 then
        ms = 0
      end
      local total = whole(step.findings_total, 1e9) or #findings
      doc.steps[#doc.steps + 1] = {
        name = name,
        state = name_of(step.state) or "unknown",
        ms = ms,
        reason = state.title(step.reason),
        findings = findings,
        findings_total = math.max(total, #findings),
      }
    end
  end
  return doc
end

---Where the last document of a project is (the state folder the child writes to).
---@param root string
---@param opts? Testing.State.Opts
---@return string
function M.path(root, opts)
  return require("testing.state").dir(root, opts) .. "/ci.json"
end

---Read the last pipeline run of a project. nil: there is none, or the file is not usable.
---@param root string
---@param opts? Testing.State.Opts
---@return Testing.Explorer.Ci.Doc|nil
function M.read(root, opts)
  local path = M.path(root, opts)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return nil
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok then
    return nil
  end
  return M.validate(decoded)
end

---The node of a pipeline run, to stand first in the view `tests`.
---@param root string  Absolute project root, as the nodes spell it (`nodes.norm`).
---@param doc Testing.Explorer.Ci.Doc
---@return table node
function M.node(root, doc)
  local steps = {}
  for _, step in ipairs(doc.steps) do
    local children = {}
    for i, f in ipairs(step.findings) do
      local where = f.file and (f.line and ("%s:%d"):format(f.file, f.line) or f.file) or nil
      children[#children + 1] = {
        id = ("tests:ci:finding:%s:%d"):format(step.name, i),
        label = f.text,
        kind = "ci_finding",
        hl = "DiagnosticError",
        path = f.file and (root .. "/" .. f.file) or nil,
        columns = where and { where } or nil,
        data = {
          lnum = f.line,
          col = f.col and f.col - 1 or nil,
          testing = { kind = "ci_finding", profile = doc.profile, step = step.name },
        },
      }
    end
    if step.findings_total > #step.findings then
      children[#children + 1] = {
        id = ("tests:ci:finding:%s:more"):format(step.name),
        -- a run that is going knows the count only: the findings are in the document it writes at its end
        label = doc.live and ("%d finding(s), listed when the run has ended"):format(
          step.findings_total
        ) or ("... and %d more"):format(step.findings_total - #step.findings),
        kind = "note",
      }
    end
    local status = M.STATUS[step.state] or "never"
    if #children == 0 and step.reason and status ~= "pass" then
      children[1] =
        { id = ("tests:ci:reason:%s"):format(step.name), label = step.reason, kind = "note" }
    end
    steps[#steps + 1] = {
      id = "tests:ci:step:" .. step.name,
      label = step.name,
      kind = "ci_step",
      status = status,
      children = #children > 0 and children or nil,
      data = {
        testing = {
          kind = "ci_step",
          profile = doc.profile,
          step = step.name,
          recorded = step.state,
          duration_ms = step.ms,
          progress = step.progress,
        },
      },
    }
  end
  return {
    id = "tests:ci",
    label = "Pipeline " .. doc.profile,
    kind = "ci",
    children = steps,
    data = {
      testing = {
        kind = "ci",
        profile = doc.profile,
        verdict = doc.verdict,
        time = doc.time,
        -- a run that is going is watched: its steps are in sight
        unfold = doc.live or nil,
      },
    },
  }
end

---@class Testing.Explorer.Ci.Live
---@field doc Testing.Explorer.Ci.Doc  What the view shows while the run goes.
---@field by_name table<string, Testing.Explorer.Ci.Step>

---Begin the session of a run from its `run_start`. nil: the event is none, or names no profile and no step that
---could be shown.
---@param ev any
---@return Testing.Explorer.Ci.Live|nil
function M.live_start(ev)
  if type(ev) ~= "table" or ev.event ~= "run_start" or type(ev.steps) ~= "table" then
    return nil
  end
  local profile = name_of(ev.profile)
  if not profile then
    return nil
  end
  local doc = { profile = profile, verdict = "running", steps = {}, live = true }
  local by_name = {}
  for i = 1, math.min(#ev.steps, M.MAX_STEPS) do
    local name = name_of(ev.steps[i])
    if name and not by_name[name] then
      local step = { name = name, state = "queued", ms = 0, findings = {}, findings_total = 0 }
      by_name[name] = step
      doc.steps[#doc.steps + 1] = step
    end
  end
  if #doc.steps == 0 then
    return nil
  end
  return { doc = doc, by_name = by_name }
end

---Take one event of the run in.
---@param live Testing.Explorer.Ci.Live
---@param ev any
---@return "step"|"reset"|"done"|nil what  `step`: that step shows something else (a push is enough); `reset`: the lines below it changed (the view asks for the root again); `done`: the run is over; nil: nothing changed
---@return string|nil step
function M.live_feed(live, ev)
  local kind = type(ev) == "table" and ev.event or nil
  if kind == "run_done" then
    return "done", nil
  end
  local step = kind and type(ev.step) == "string" and live.by_name[ev.step] or nil
  if not step then
    return nil, nil
  end
  -- a count of findings or a reason is a line below the step
  local function below()
    return step.findings_total > 0
      or (step.reason ~= nil and (M.STATUS[step.state] or "never") ~= "pass")
  end
  if kind == "step_start" then
    local had = below()
    step.state, step.ms, step.reason, step.progress, step.findings_total = "running", 0, nil, nil, 0
    return had and "reset" or "step", step.name
  elseif kind == "suite_progress" then
    if step.state ~= "running" then
      return nil, nil
    end
    local done = (ev.done == 0 and 0) or whole(ev.done, 1e7)
    local total = whole(ev.total, 1e7)
    local text = done and (total and ("%d/%d"):format(done, total) or tostring(done)) or nil
    if text == step.progress then
      return nil, nil
    end
    step.progress = text
    return "step", step.name
  elseif kind == "step_end" then
    local had = below()
    local ms = ev.ms
    if type(ms) ~= "number" or ms ~= ms or ms < 0 or ms > 1e12 then
      ms = 0
    end
    step.state, step.ms, step.progress = name_of(ev.state) or "unknown", ms, nil
    step.reason = require("testing.state").title(ev.reason)
    step.findings_total = whole(ev.findings_total, 1e9) or 0
    return (had or below()) and "reset" or "step", step.name
  end
  return nil, nil
end

---The pipeline run the marked nodes stand for: the profile, and the steps when only steps (or their findings)
---are marked. nil when no node is of a pipeline.
---@param list table[]
---@return { profile: string, steps?: string[] }|nil
function M.run_of(list)
  local nodes = require("testing.explorer.nodes")
  local profile, steps, seen, whole_run = nil, {}, {}, false
  for _, node in ipairs(list or {}) do
    local data = nodes.data(node)
    if data and (data.kind == "ci" or data.kind == "ci_step" or data.kind == "ci_finding") then
      profile = profile or data.profile
      if data.kind == "ci" then
        whole_run = true
      elseif data.step and not seen[data.step] and data.profile == profile then
        seen[data.step] = true
        steps[#steps + 1] = data.step
      end
    end
  end
  if not profile then
    return nil
  end
  return { profile = profile, steps = (not whole_run and #steps > 0) and steps or nil }
end

return M
