---@module 'testing.sheet.panel'
---@brief `:Testing sheet step`: a test sheet step by step in a buffer, as with a debugger.
---@description
--- A client of `testing sheets step` like any other: it starts the command in a child, reads the events
--- (`testing-sheet-session/1`) and writes commands. The editor never runs a step itself and never blocks. The steps are
--- listed with their state; below them what the step under the cursor did, for an rpc sheet with the child's screen as
--- text (the child runs unseen, a browser or an app has its own window next to the editor).
---
---   n next   c continue   u until the cursor   b breakpoint   a abort   q close   y / n answer a question
---   N note on the step where the run stands (any time, also while it runs)
---
--- Breakpoints live here: `c` goes to the next one with `until`. They count for the size that runs. Closing the buffer
--- aborts the run: its child sees its stdin close and cleans up.

local M = {}

M.SCHEMA = "testing-sheet-session/1"
M.FILETYPE = "testing-sheet"

---The steps start below these lines.
local HEADER = 4

local ICON = { pass = "✓", fail = "✗", running = "▶", next = "▷", none = " " }
local HL = { pass = "DiagnosticOk", fail = "DiagnosticError", running = "DiagnosticInfo" }
local ns = vim.api.nvim_create_namespace("testing.sheet.panel")
local counter = 0

---@class Testing.Sheet.Panel
---@field root string
---@field target string
---@field opts table
---@field buf integer
---@field proc? table
---@field doc? table The `start` event.
---@field size? string
---@field marks table<string, table<integer, table>> What each step of each size did.
---@field notes table<string, table<integer, string[]>> The notes per size and step.
---@field at? integer The step that runs or runs next.
---@field running boolean
---@field paused? string Why it waits for a command.
---@field question? string What the run asks.
---@field pending_pause? string The pause a command ended, for when the command is refused.
---@field breaks table<integer, true>
---@field finished? table The `end` event.
---@field problem? string Why there is no `end` event.
---@field stderr string[]

---One line, whatever a value contains.
---@param v any
---@param max integer
---@return string
local function one_line(v, max)
  local s = tostring(v):gsub("%s+", " ")
  if vim.fn.strchars(s) > max then
    s = vim.fn.strcharpart(s, 0, max - 3) .. "..."
  end
  return s
end

---What the second line says.
---@param p Testing.Sheet.Panel
---@return string
local function status_line(p)
  if p.finished then
    local f = p.finished
    local text = ("finished: %s in %d ms"):format(tostring(f.status), tonumber(f.ms) or 0)
    if f.skipped then
      text = text .. " (" .. one_line(f.skipped, 100) .. ")"
    end
    return text
  end
  if p.problem then
    return "ended without a result: " .. p.problem
  end
  if p.question then
    return "asks: " .. one_line(p.question, 110) .. "   (y yes, n no)"
  end
  if p.paused then
    local what = p.paused == "failed" and ("step %d failed"):format(p.at or 0)
      or ("before step %d"):format(p.at or 0)
    return ("paused %s (%s)"):format(what, tostring(p.size))
  end
  if p.running and p.at then
    return ("step %d runs (%s)"):format(p.at, tostring(p.size))
  end
  return "starting ..."
end

---The lines of the buffer and the highlights of the step lines. No editor state is touched.
---@param p Testing.Sheet.Panel
---@param selected? integer The step whose details are shown.
---@return string[] lines, { line: integer, hl: string }[] marks
function M.render(p, selected)
  local doc = p.doc
  local title = doc
      and ("%s  [%s%s]"):format(
        one_line(doc.title, 80),
        tostring(doc.engine),
        doc.app and (", " .. one_line(doc.app, 40)) or ""
      )
    or p.target
  local lines = {
    title,
    status_line(p),
    "n next  c continue  u until cursor  b breakpoint  N note  a abort  q close",
    "",
  }
  local hls = {}
  local marks = p.size and p.marks[p.size] or {}
  local notes = p.size and p.notes and p.notes[p.size] or {}
  for _, step in ipairs(doc and doc.steps or {}) do
    local mark = marks[step.n]
    local state = mark and mark.status or "none"
    if not mark and step.n == p.at and not p.finished then
      state = p.running and "running" or "next"
    end
    local text = ("%s%s %2d %s %s"):format(
      p.breaks[step.n] and "●" or " ",
      ICON[state] or " ",
      step.n,
      step.action,
      one_line(step.note or step.value, 70)
    )
    if mark and mark.ms then
      text = text .. ("  (%d ms)"):format(mark.ms)
    end
    if notes[step.n] then
      text = text .. ("  [%d note%s]"):format(#notes[step.n], #notes[step.n] == 1 and "" or "s")
    end
    lines[#lines + 1] = text
    if HL[state] then
      hls[#hls + 1] = { line = #lines - 1, hl = HL[state] }
    end
  end

  local failures = p.finished and p.finished.failures or {}
  if #failures > 0 then
    lines[#lines + 1] = ""
    for _, f in ipairs(failures) do
      lines[#lines + 1] = "failed: " .. one_line(f, 400)
    end
  end
  if p.problem and #p.stderr > 0 then
    lines[#lines + 1] = ""
    for _, l in ipairs(vim.split(vim.trim(table.concat(p.stderr)), "\n")) do
      lines[#lines + 1] = l
    end
  end

  -- the tile of the step under the cursor, else of the last one that did something (or got a note)
  local step_n = selected
  if not (step_n and (marks[step_n] or notes[step_n])) then
    step_n = nil
    for n in pairs(marks) do
      step_n = math.max(step_n or 0, n)
    end
    for n in pairs(notes) do
      step_n = math.max(step_n or 0, n)
    end
  end
  local step = doc and step_n and doc.steps[step_n]
  if step then
    local mark = marks[step_n] or {}
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("--- step %d, %s: %s"):format(
      step_n,
      step.action,
      one_line(step.value, 300)
    )
    if mark.reason then
      lines[#lines + 1] = "reason: " .. one_line(mark.reason, 400)
    end
    for _, note in ipairs(notes[step_n] or {}) do
      lines[#lines + 1] = "note: " .. one_line(note, 400)
    end
    if mark.shot then
      lines[#lines + 1] = "screenshot: " .. tostring(mark.shot)
    end
    if mark.image then
      lines[#lines + 1] = "picture: " .. tostring(mark.image)
    end
    if type(mark.screen) == "table" then
      lines[#lines + 1] = "screen:"
      local rows = vim.tbl_map(function(row)
        return "  " .. (tostring(row):gsub("%s+$", ""))
      end, mark.screen)
      while #rows > 0 and rows[#rows]:match("^%s*~?%s*$") do
        rows[#rows] = nil
      end
      vim.list_extend(lines, rows)
    end
  end
  return lines, hls
end

---@param p Testing.Sheet.Panel
---@return integer|nil step The step under the cursor.
local function cursor_step(p)
  local win = vim.fn.bufwinid(p.buf)
  if win == -1 or not p.doc then
    return nil
  end
  local n = vim.api.nvim_win_get_cursor(win)[1] - HEADER
  return (n >= 1 and n <= #p.doc.steps) and n or nil
end

---@param p Testing.Sheet.Panel
local function redraw(p)
  if not vim.api.nvim_buf_is_valid(p.buf) then
    return
  end
  local lines, hls = M.render(p, cursor_step(p))
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
  vim.bo[p.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(p.buf, ns, h.line, 0, { line_hl_group = h.hl })
  end
end

---One event of the stream.
---@param p Testing.Sheet.Panel
---@param ev table
function M.on_event(p, ev)
  if ev.schema ~= M.SCHEMA then
    p.problem = "another schema: " .. tostring(ev.schema)
    M.abort(p)
  elseif ev.event == "start" then
    p.doc = ev
  elseif ev.event == "size" then
    if ev.state == "open" then
      p.size = ev.size
      p.marks[ev.size] = p.marks[ev.size] or {}
    end
  elseif ev.event == "step-before" then
    p.size, p.at, p.paused, p.running = ev.size, ev.n, nil, true
  elseif ev.event == "paused" then
    p.size, p.at, p.paused, p.running = ev.size, ev.n, ev.reason, false
  elseif ev.event == "ask" then
    p.size, p.at, p.paused, p.running, p.question = ev.size, ev.n, "ask", false, ev.text
  elseif ev.event == "step-after" then
    p.question = nil
    p.marks[ev.size] = p.marks[ev.size] or {}
    p.marks[ev.size][ev.n] = ev
    p.running = false
  elseif ev.event == "note" then
    p.notes = p.notes or {}
    p.notes[ev.size] = p.notes[ev.size] or {}
    local list = p.notes[ev.size][ev.n] or {}
    list[#list + 1] = tostring(ev.text)
    p.notes[ev.size][ev.n] = list
  elseif ev.event == "error" then
    require("testing.notify").get().warn("testing sheet: " .. tostring(ev.message))
    p.paused = p.pending_pause
  elseif ev.event == "end" then
    p.finished, p.paused, p.running = ev, nil, false
    local say = require("testing.notify").get()
    local text = ("testing sheet %s: %s"):format(
      p.doc and p.doc.id or p.target,
      tostring(ev.status)
    )
    if ev.ok then
      say.info(text)
    else
      say.warn(text)
    end
  end
  -- unknown events are for a newer reader
end

---Say something to the run, when it waits for it.
---@param p Testing.Sheet.Panel
---@param cmd string
---@return boolean sent
local function send(p, cmd)
  if not p.paused or not p.proc then
    return false
  end
  p.pending_pause = p.paused
  p.paused = nil
  p.running = true
  pcall(p.proc.write, p.proc, cmd .. "\n")
  redraw(p)
  return true
end

---Run this step; to a question this is a no.
---@param p Testing.Sheet.Panel
---@return boolean sent
function M.next(p)
  return send(p, p.question and "answer no" or "next")
end

---Yes to the question.
---@param p Testing.Sheet.Panel
---@return boolean sent
function M.yes(p)
  return p.question ~= nil and send(p, "answer yes")
end

---Run on: to the next breakpoint, in this size or a later one, else to the end.
---@param p Testing.Sheet.Panel
---@return boolean sent
function M.continue(p)
  return send(p, "continue")
end

---Run on up to the step under the cursor.
---@param p Testing.Sheet.Panel
---@param n? integer The step (default: under the cursor).
---@return boolean sent
function M.until_step(p, n)
  n = n or cursor_step(p)
  if not n or n <= (p.at or 0) then
    require("testing.notify").get().warn("testing sheet: put the cursor on a later step")
    return false
  end
  return send(p, ("until %d"):format(n))
end

---@param p Testing.Sheet.Panel
---@param n? integer The step (default: under the cursor).
function M.toggle_break(p, n)
  n = n or cursor_step(p)
  if n then
    p.breaks[n] = not p.breaks[n] and true or nil
    -- The run keeps them: it reads this at its next stop, and they hold in every size.
    if p.proc then
      pcall(p.proc.write, p.proc, ("%s %d\n"):format(p.breaks[n] and "break" or "clear", n))
    end
    redraw(p)
  end
end

---A note on the step where the run stands; the run takes it at once, also while a step runs.
---@param p Testing.Sheet.Panel
---@param text? string Asked for when not given.
---@return boolean sent
function M.note(p, text)
  if not p.proc or p.finished then
    return false
  end
  local function put(t)
    t = vim.trim((tostring(t or ""):gsub("%c", " ")))
    if t == "" or not p.proc then
      return false
    end
    pcall(p.proc.write, p.proc, "note " .. t .. "\n")
    return true
  end
  if text then
    return put(text)
  end
  vim.ui.input({ prompt = ("Note on step %d: "):format(p.at or 0) }, put)
  return true
end

---End the run: its stdin closes, and the child cleans up.
---@param p Testing.Sheet.Panel
function M.abort(p)
  if p.proc then
    pcall(p.proc.write, p.proc, nil)
  end
end

---@param p Testing.Sheet.Panel
local function map_keys(p)
  local function map(lhs, fn, desc)
    vim.keymap.set(
      "n",
      lhs,
      fn,
      { buffer = p.buf, nowait = true, desc = "testing sheet: " .. desc }
    )
  end
  map("n", function()
    M.next(p)
  end, "run this step")
  map("y", function()
    M.yes(p)
  end, "answer yes")
  map("c", function()
    M.continue(p)
  end, "run to the next breakpoint or the end")
  map("u", function()
    M.until_step(p)
  end, "run up to the step under the cursor")
  map("b", function()
    M.toggle_break(p)
  end, "breakpoint on the step under the cursor")
  map("N", function()
    M.note(p)
  end, "note on the step where the run stands")
  map("a", function()
    M.abort(p)
  end, "abort the run")
  map("q", function()
    vim.api.nvim_buf_delete(p.buf, { force = true })
  end, "abort the run and close")
end

---@param p Testing.Sheet.Panel
local function start_process(p)
  local argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    require("testing.bindings.child").driver(),
    "sheets",
    "step",
    p.target,
    "--root",
    p.root,
  }
  if p.opts.headed ~= false then
    argv[#argv + 1] = "--headed"
  end
  if p.opts.delay then
    vim.list_extend(argv, { "--delay", tostring(p.opts.delay) })
  end
  p.stderr, p.problem = {}, nil
  local partial = ""
  local on_stdout = vim.schedule_wrap(function(_, data)
    if not data then
      return
    end
    partial = partial .. data
    for line in partial:gmatch("([^\n]*)\n") do
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" then
        M.on_event(p, ev)
      end
    end
    partial = partial:match("([^\n]*)$") or ""
    redraw(p)
  end)
  local on_exit = vim.schedule_wrap(function(done)
    p.proc = nil
    p.running, p.paused = false, nil
    if not p.finished then
      p.problem = ("exit %d"):format(done.code)
      redraw(p)
    end
    -- the question last: a yes starts the run again, and that run owns the state from then on
    local gate = require("testing.bindings.trust_prompt")
    if gate.refused(done.code, table.concat(p.stderr)) then
      gate.ask(p.root, function(trusted)
        if trusted and vim.api.nvim_buf_is_valid(p.buf) then
          start_process(p)
        end
      end)
    end
  end)
  local ok, proc = pcall(vim.system, argv, {
    stdin = true,
    text = false,
    env = p.opts.env,
    stdout = on_stdout,
    stderr = function(_, data)
      if data and #p.stderr < 50 then
        p.stderr[#p.stderr + 1] = data
      end
    end,
  }, on_exit)
  if not ok then
    p.problem = tostring(proc)
    redraw(p)
    return
  end
  p.proc = proc
end

---Open the panel and start the run.
---@param root string The project root.
---@param target string A sheet: a file, an id or a file name below `TESTS/sheets`.
---@param opts? { headed?: boolean, delay?: integer, env?: table<string, string> } `headed` is on unless it is false.
---@return Testing.Sheet.Panel
function M.open(root, target, opts)
  counter = counter + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, ("testing://sheet/%d/%s"):format(counter, target))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = M.FILETYPE
  ---@type Testing.Sheet.Panel
  local p = {
    root = root,
    target = target,
    opts = opts or {},
    buf = buf,
    marks = {},
    notes = {},
    running = false,
    breaks = {},
    stderr = {},
  }
  -- beside the code: the tile of a step holds a whole screen of the child, a window of 12 lines would not show it
  if #vim.api.nvim_list_uis() > 0 then
    vim.cmd("botright vertical split")
    vim.api.nvim_win_set_width(0, 90)
    vim.api.nvim_win_set_buf(0, buf)
  end
  map_keys(p)
  local group = vim.api.nvim_create_augroup("testing.sheet.panel." .. buf, {})
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M.abort(p)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      redraw(p)
    end,
  })
  redraw(p)
  start_process(p)
  return p
end

return M
