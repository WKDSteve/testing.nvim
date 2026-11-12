---@module 'testing.sheet.explain'
---@brief An AI explanation of one step of a sheet, through ai.nvim, only when a person asks for it.
---@description
--- The panel of `:Testing sheet step` (`E` on a step) asks ai.nvim to explain the step: what it does, what to watch
--- out for, or what its result means. Nothing here talks to a model on its own (rule PRIN-60): the request is built
--- from what the run already reported (the `start` event, the `step-after` of the step, its notes), shown in full
--- before anything is sent, and sent through `require("ai").stream` only on a yes. Without ai.nvim there is no
--- explanation and the panel stays as it is.

local M = {}

---The questions, in the order they are offered.
M.KINDS = {
  { id = "what", label = "What does this step do?" },
  { id = "watch", label = "What should I watch out for in this step?" },
  { id = "result", label = "What does the result of this step mean?" },
}

---The most rows of the child's screen that go into a request, and the most characters of one row or value.
M.MAX_ROWS = 60
M.MAX_TEXT = 400

M.SYSTEM = table.concat({
  "You explain one step of a test sheet of testing.nvim, a test runner for Neovim plugins.",
  "A sheet is a list of declarative steps (keys, lua, expect, wait, screen, shot, ask, ...) that run one after",
  "another against a target: a child Neovim (engine rpc), a browser page (engine browser) or a desktop app.",
  "Answer briefly and concretely, refer to the step and its values, and say when the information given is not",
  "enough to tell.",
}, " ")

---@param v any
---@param max? integer
---@return string
local function clip(v, max)
  max = max or M.MAX_TEXT
  local s = tostring(v == nil and "" or v):gsub("[%c]", " ")
  if vim.fn.strchars(s) > max then
    s = vim.fn.strcharpart(s, 0, max - 3) .. "..."
  end
  return s
end

---The questions that fit a step: the result only once the step ran.
---@param mark? table The `step-after` event of the step.
---@return { id: string, label: string }[]
function M.kinds(mark)
  return vim.tbl_filter(function(k)
    return k.id ~= "result" or mark ~= nil
  end, M.KINDS)
end

---@param id string
---@return { id: string, label: string }|nil
local function kind_of(id)
  for _, k in ipairs(M.KINDS) do
    if k.id == id then
      return k
    end
  end
  return nil
end

---The request for ai.nvim: what the run reported about the step, and the question. Pure, no editor state.
---@param ctx { doc: table, size?: string, n: integer, mark?: table, notes?: string[] } `doc` is the `start` event.
---@param kind string One of `M.KINDS`.
---@return { system: string, prompt: string }|nil req, string|nil err
function M.request(ctx, kind)
  local k = kind_of(kind)
  if not k then
    return nil, "unknown question: " .. tostring(kind)
  end
  local doc = ctx.doc or {}
  local steps = doc.steps or {}
  local step = steps[ctx.n]
  if not step then
    return nil, ("the sheet has no step %s"):format(tostring(ctx.n))
  end
  if kind == "result" and not ctx.mark then
    return nil, ("step %d has not run yet"):format(ctx.n)
  end

  local out = {}
  local function put(s)
    out[#out + 1] = s
  end
  put(
    ("Sheet %s: %s (engine %s%s)"):format(
      clip(doc.id, 100),
      clip(doc.title, 200),
      clip(doc.engine, 20),
      doc.app and (", app " .. clip(doc.app, 60)) or ""
    )
  )
  if ctx.size then
    put("Size: " .. clip(ctx.size, 20))
  end
  put("")
  put("Steps:")
  for _, s in ipairs(steps) do
    put(
      ("%s %d. %s %s%s"):format(
        s.n == ctx.n and ">" or " ",
        s.n,
        clip(s.action, 20),
        clip(s.value, s.n == ctx.n and M.MAX_TEXT or 80),
        s.note and ("  -- " .. clip(s.note, 120)) or ""
      )
    )
  end
  put("")
  put(("The step in question is step %d of %d."):format(ctx.n, #steps))

  local mark = ctx.mark
  if mark then
    put(
      ("It ran: %s in %s ms."):format(
        clip(mark.status, 10),
        clip(mark.ms ~= nil and mark.ms or "?", 12)
      )
    )
    if mark.reason then
      put("Reason: " .. clip(mark.reason))
    end
    if mark.failure then
      put("Failure: " .. clip(mark.failure))
    end
    if type(mark.measure) == "table" then
      put("Measured: " .. clip(vim.json.encode(mark.measure)))
    end
    if mark.image or mark.shot then
      put("(It left a picture, which is not sent.)")
    end
    if type(mark.screen) == "table" then
      local rows = {}
      for i, row in ipairs(mark.screen) do
        if i > M.MAX_ROWS then
          break
        end
        rows[#rows + 1] = (clip(row, 300):gsub("%s+$", ""))
      end
      while #rows > 0 and rows[#rows]:match("^%s*~?%s*$") do
        rows[#rows] = nil
      end
      put("The child editor's screen after the step, as text:")
      put("```")
      vim.list_extend(out, rows)
      put("```")
    end
  else
    put("It has not run yet.")
  end
  for _, note in ipairs(ctx.notes or {}) do
    put("Note of the person: " .. clip(note))
  end
  put("")
  put("Question: " .. k.label)
  return { system = M.SYSTEM, prompt = table.concat(out, "\n") }, nil
end

---ai.nvim, when it is there.
---@param require_fn? fun(name: string): any
---@return table|nil ai, string|nil why
function M.ai(require_fn)
  local ok, ai = pcall(require_fn or require, "ai")
  if not ok or type(ai) ~= "table" or type(ai.stream) ~= "function" then
    return nil, "ai.nvim is not installed"
  end
  return ai, nil
end

---Where a request goes, in words: the provider ai.nvim would use.
---@param ai table
---@return string
function M.target(ai)
  local ok, cfg = pcall(function()
    return ai.config()
  end)
  local provider = ok and type(cfg) == "table" and cfg.provider or nil
  return ("ai.nvim, provider %s"):format(provider and tostring(provider) or "(its default)")
end

return M
