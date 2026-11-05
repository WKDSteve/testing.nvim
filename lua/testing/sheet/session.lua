---@module 'testing.sheet.session'
---@brief One run of a test sheet, one step at a time: open, peek, step, close.
---@description
--- `testing.sheet.run` is the loop over this for the rpc engine, `testing sheets step` the same loop with a client
--- in it. Sizes run in order, the first failed step ends a size, and a sheet skipped by `requires` ends the run.
---
---   local session = require("testing.sheet.session").open(s, opts)
---   while session:peek() do       -- what comes next (starts the target of the next size when needed)
---     session:step()              -- exactly that step, returns its result
---   end
---   session:close()               -- always; a second call does nothing
---   local result = session:result()
---
--- Who stops a run: `cancel` makes `result` report `aborted`. It can be called from a libuv callback (it only
--- sets a flag); a `wait` step sees it at its next poll, a browser step at once, anything else when it returns.

local M = {}

---@class Testing.Sheet.NextStep
---@field size string The size as a tag: `80x24`.
---@field n integer The number of the step, from 1.
---@field total integer How many steps a size has.
---@field action string `keys`, `wait`, ...
---@field value any The action's value.
---@field note? string

---@class Testing.Sheet.StepResult: Testing.Sheet.NextStep
---@field status "pass"|"fail"
---@field ms integer
---@field reason? string Why the step failed.
---@field failure? string The failure line, as in `Testing.Sheet.Result.failures`.
---@field shot? string The file of a `shot` step.
---@field screen? string[] The child's screen after the step (`capture_screen`).

---@class Testing.Sheet.Session
---@field sheet Testing.Sheet
---@field opts table
---@field root string
---@field driver? table `testing.sheet.driver_rpc` or `testing.sheet.browser`; none for a manual sheet.
---@field failures string[]
---@field snapshots string[]
---@field skipped? string
---@field aborted boolean
---@field closed boolean
---@field tag? string The size that is running.
---@field size_i integer
---@field step_i integer
---@field size_open boolean
---@field size_done boolean
local Session = {}
Session.__index = Session

---@param step Testing.Sheet.Step
---@return string action, any value
local function action_of(step)
  for _, a in ipairs(require("testing.sheet").ACTIONS) do
    if step[a] ~= nil then
      return a, step[a]
    end
  end
  return "?", nil
end
M.action_of = action_of

---@param s Testing.Sheet
---@param opts? table As `testing.sheet.run`, and: `capture_screen`, `headed`, `on_size(tag, state, reason)`.
---@return Testing.Sheet.Session
function M.open(s, opts)
  opts = opts or {}
  local self = setmetatable({
    sheet = s,
    opts = opts,
    root = vim.fs.normalize(vim.fn.fnamemodify(opts.root or vim.fn.getcwd(), ":p")):gsub("/+$", ""),
    failures = {},
    snapshots = {},
    aborted = false,
    size_i = 0,
    step_i = 0,
    size_open = false,
    size_done = false,
    closed = false,
  }, Session)
  local ctx = {
    root = self.root,
    snapshots = self.snapshots,
    cancelled = function()
      return self.aborted
    end,
  }
  if s.engine == "rpc" then
    self.driver = require("testing.sheet.driver_rpc").new(s, opts, ctx)
  elseif s.engine == "browser" then
    self.driver = require("testing.sheet.browser").driver(s, opts, ctx)
  end
  return self
end

---Stop the run; `result` reports `aborted`. Only sets a flag: safe in a libuv callback.
function Session:cancel()
  self.aborted = true
end

---@param tag string
---@param state string
---@param reason? string
function Session:_notify(tag, state, reason)
  if self.opts.on_size then
    self.opts.on_size(tag, state, reason)
  end
end

---Start sizes until one has a step to run. Nil when the run has nothing left.
---@return Testing.Sheet.NextStep|nil
function Session:peek()
  if self.closed or self.aborted or not self.driver then
    return nil
  end
  local s = self.sheet
  while true do
    if self.size_open then
      if not self.size_done and self.step_i < #s.steps then
        local step = s.steps[self.step_i + 1]
        local action, value = action_of(step)
        return {
          size = self.tag,
          n = self.step_i + 1,
          total = #s.steps,
          action = action,
          value = value,
          note = step.note,
        }
      end
      self.driver.close_size()
      self.size_open = false
    end
    if self.skipped or self.size_i >= #s.sizes then
      return nil
    end
    self.size_i = self.size_i + 1
    local size = s.sizes[self.size_i]
    self.tag = ("%dx%d"):format(size.cols, size.rows)
    local answer = self.driver.open_size(size)
    if answer and answer.skip then
      self.skipped = answer.skip
      self:_notify(self.tag, "skip", answer.skip)
    elseif answer and answer.failure then
      self.failures[#self.failures + 1] = answer.failure
      self:_notify(self.tag, "failed", answer.failure)
    else
      self.size_open, self.size_done, self.step_i = true, false, 0
      self:_notify(self.tag, "open")
    end
  end
end

---Run the step `peek` names.
---@return Testing.Sheet.StepResult|nil
function Session:step()
  local next_step = self:peek()
  if not next_step then
    return nil
  end
  ---@cast next_step Testing.Sheet.StepResult
  local sheet = require("testing.sheet")
  local step = self.sheet.steps[next_step.n]
  local started = vim.uv.hrtime()
  local out = self.driver.run(step, next_step.n)
  next_step.ms = math.floor((vim.uv.hrtime() - started) / 1e6)
  next_step.status = "pass"
  next_step.screen, next_step.shot = out.screen, out.shot
  if out.shot then
    self.snapshots[#self.snapshots + 1] = "screenshot " .. out.shot
  end
  local line
  if out.raised then
    line = ("%s: %s"):format(self.tag, out.raised)
    next_step.reason = out.raised
  elseif out.reason then
    line = ("%s step %d, %s: %s"):format(self.tag, next_step.n, sheet._describe(step), out.reason)
    next_step.reason = out.reason
  end
  if line then
    next_step.status, next_step.failure = "fail", line
    self.failures[#self.failures + 1] = line
    self.size_done = true
  end
  self.step_i = next_step.n
  return next_step
end

---The target and everything else goes away. Safe to call twice, and after an abort.
function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.driver then
    pcall(self.driver.close_size)
    pcall(self.driver.close)
  end
end

---The verdict so far, in the shape of `testing.sheet.run`; `aborted` only when `cancel` was called.
---@return Testing.Sheet.Result
function Session:result()
  local result =
    { ok = true, status = "pass", failures = self.failures, snapshots = self.snapshots }
  if self.sheet.engine == "manual" then
    result.status = "manual"
  elseif self.aborted then
    -- nothing is proved by half a run, whatever its steps did so far
    result.ok, result.status = false, "aborted"
  elseif #self.failures > 0 then
    result.ok, result.status = false, "fail"
  elseif self.skipped then
    -- a missing prerequisite is information, never a green run
    result.status, result.skipped = "skip", self.skipped
  end
  return result
end

return M
