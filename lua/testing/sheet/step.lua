---@module 'testing.sheet.step'
-- @cache-env NVIM_MACHINE_ROLE TESTING_ALLOW_WORKSTATION
---@brief `testing sheets step`: one test sheet step by step, events on stdout, commands on stdin.
---@description
--- The one way into a stepped run for every surface (`:Testing sheet step`, testing-desktop, testing-web): a client
--- reads events (`testing-sheet-session/1`, one JSON line each) and writes commands (`next`, `continue`, `until <n>`,
--- `abort`). Closed stdin is `abort`, so a client that dies leaves no editor or browser behind.
---
--- A question of a sheet (`ask`) stops the run for `answer yes|no [text]`. With `--run` nobody can answer: it is passed
--- over and stays a `judge` criterion.
---
--- It writes no state and no snapshot (as on CI, a missing snapshot is a failure). Whether a run counts as a verdict is
--- what the `verdict` field of `end` says: only a run that went through without an abort. Only such a run writes
--- anything: with `--tasks <vault>` its state goes into the task's block, and a question answered yes ticks its box.
--- Same gates as `testing sheets run`: the workstation rule and the trust of the root.

local M = {}

M.SCHEMA = "testing-sheet-session/1"
M.USAGE =
  "usage: testing sheets step <sheet> [--root <dir>] [--headed] [--delay <ms>] [--break <n>]... [--run [--format=json|text]] [--tasks <vault> [--tasks-cli <tasks.lua>]]"

---The longest note, in bytes: one line of a task, not a document.
M.MAX_NOTE = 1000
---The most notes of one run: the file of the run, the page of testing-desktop and the task stay small.
M.MAX_NOTES = 200

---@class Testing.SheetStep.Note
---@field size string
---@field n integer
---@field text string
---@field time string UTC, `YYYY-MM-DDTHH:MM:SSZ`.

---@class Testing.SheetStep.Reader
---@field start fun(on_abort: fun(), on_note?: fun(text: string)) Begin reading; `on_abort` fires as soon as `abort` or the end of stdin arrives, `on_note` as soon as a `note` arrives (a reader that has no live stdin hands it out through `next`).
---@field next fun(): string|nil The next command line (waits for it); nil at the end of stdin.
---@field stop fun()

---@class Testing.SheetStep.Deps
---@field emit? fun(line: string): boolean|nil A stand-in for stdout (specs); nil or false = the client is gone.
---@field reader? Testing.SheetStep.Reader A stand-in for stdin (specs).
---@field getenv? fun(name: string): string|nil
---@field trust_check? fun(root: string): string|nil
---@field session_opts? table Merged into the options of the session (specs: `spawn`, `node`, ...).
---@field call? Testing.SheetTasks.Call A stand-in for the engine of tasks.nvim (specs).

---The text of a `note <text>` command ("" for a bare `note`), nil for any other line. Control characters become blanks.
---@param line string
---@return string|nil
function M.note_text(line)
  if line ~= "note" and not line:match("^note%s") then
    return nil
  end
  return vim.trim((line:sub(5):gsub("%c", " ")))
end

---The commands from stdin, read without blocking the loop: an abort reaches a running step.
---@return Testing.SheetStep.Reader
local function stdin_reader()
  local uv = vim.uv
  local lines, partial, eof = {}, "", false
  local handle, abort_fn, note_fn
  local function push(line)
    line = vim.trim(line)
    if line == "abort" and abort_fn then
      abort_fn()
    end
    -- a note belongs to where the run stands when it arrives, not to the next stop: taken at once
    local text = note_fn and M.note_text(line)
    if text then
      note_fn(text)
    elseif line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return {
    start = function(on_abort, on_note)
      abort_fn = on_abort
      local kind = uv.guess_handle(0)
      if kind == "tty" then
        handle = uv.new_tty(0, true)
      elseif kind == "pipe" then
        handle = uv.new_pipe(false)
        if handle and not handle:open(0) then
          handle = nil
        end
      end
      if not handle then
        -- a file (`< commands.txt`) or nothing at all: all of it now, then the end
        for line in ((io.stdin:read("*a") or "") .. "\n"):gmatch("([^\n]*)\n") do
          push(line)
        end
        eof = true
        on_abort()
        return
      end
      note_fn = on_note
      handle:read_start(function(_, data)
        if data then
          partial = partial .. data
          for line in partial:gmatch("([^\n]*)\n") do
            push(line)
          end
          partial = partial:match("([^\n]*)$") or ""
        else
          eof = true
          on_abort()
        end
      end)
    end,
    next = function()
      while #lines == 0 and not eof do
        vim.wait(1000, function()
          return #lines > 0 or eof
        end, 10)
      end
      return table.remove(lines, 1)
    end,
    stop = function()
      if handle then
        pcall(handle.read_stop, handle)
        pcall(handle.close, handle)
        handle = nil
      end
    end,
  }
end

---The longest value of a step in a text line, in bytes: a line per step, not the step's source.
M.MAX_TEXT_VALUE = 80

---A value of a step on one line: a string as it is, anything else compact; control characters become blanks.
---@param v any
---@return string
local function one_line(v)
  local text = type(v) == "string" and v or vim.inspect(v, { newline = " ", indent = "" })
  text = text:gsub("%c", " ")
  if #text > M.MAX_TEXT_VALUE then
    text = text:sub(1, M.MAX_TEXT_VALUE - 3) .. "..."
  end
  return text
end

---An event of the run as a line for a person or an agent (`--format=text`), nil for an event that has none.
---
---A step is one line when it ran: `<size> <n>/<total> <status> <ms> ms <action> <value>`, then `# <note>` and
---`: <reason>` when there are any. `before` holds the `step-before` events by `<size>:<n>` (filled here), since
---`step-after` names neither the action nor the note.
---@param ev table An event of `testing-sheet-session/1`.
---@param before table<string, table>
---@return string|nil
function M.text_line(ev, before)
  local e = ev.event
  if e == "start" then
    local sizes = {}
    for _, sz in ipairs(ev.sizes or {}) do
      sizes[#sizes + 1] = ("%sx%s"):format(tostring(sz.cols), tostring(sz.rows))
    end
    return ("sheet %s: %s (%s, %d steps, %s)"):format(
      tostring(ev.id),
      one_line(ev.title or ""),
      tostring(ev.engine or "rpc"),
      #(ev.steps or {}),
      table.concat(sizes, " ")
    )
  elseif e == "size" then
    return ("size %s %s%s"):format(
      tostring(ev.size),
      tostring(ev.state),
      ev.reason and (": " .. one_line(ev.reason)) or ""
    )
  elseif e == "step-before" then
    before[("%s:%s"):format(tostring(ev.size), tostring(ev.n))] = ev
    return nil
  elseif e == "step-after" then
    local b = before[("%s:%s"):format(tostring(ev.size), tostring(ev.n))] or {}
    local why = ev.failure or ev.reason
    return ("%s %s/%s %s %d ms %s%s%s%s%s"):format(
      tostring(ev.size),
      tostring(ev.n),
      tostring(b.total or "?"),
      tostring(ev.status),
      tonumber(ev.ms) or 0,
      tostring(b.action or "?"),
      b.value ~= nil and (" " .. one_line(b.value)) or "",
      b.note and (" # " .. one_line(b.note)) or "",
      why and (": " .. one_line(why)) or "",
      ev.shot and (" -> " .. tostring(ev.shot))
        or (ev.measure and not why) and (" => " .. one_line(
          require("testing.sheet").measure_text(ev.measure)
        ))
        or ""
    )
  elseif e == "note" then
    return ("note %s %s: %s"):format(tostring(ev.size), tostring(ev.n), tostring(ev.text))
  elseif e == "task" then
    return ("task %s %s%s"):format(
      tostring(ev.id),
      tostring(ev.outcome),
      ev.message and (": " .. one_line(ev.message)) or ""
    )
  elseif e == "error" then
    return "error: " .. one_line(ev.message or "")
  elseif e == "end" then
    local lines = {
      ("end %s %d ms%s"):format(
        tostring(ev.status),
        tonumber(ev.ms) or 0,
        ev.skipped and (": " .. one_line(ev.skipped)) or ""
      ),
    }
    for _, f in ipairs(ev.failures or {}) do
      lines[#lines + 1] = "  " .. (tostring(f):gsub("\r?\n", "\n  "))
    end
    return table.concat(lines, "\n")
  end
  -- `paused` and `ask` need a client; `--format=text` is `--run`, which has none
  return nil
end

---The folder of the last stepped run of a sheet (pictures of its steps, its notes), below `stdpath("cache")`.
---@param id string
---@return string
function M.evidence_dir(id)
  return ("%s/testing/sheet-evidence/%s"):format(
    vim.fn.stdpath("cache"),
    (id:gsub("[^%w._-]", "_"))
  )
end

M.NOTES_FILE = "notes.json"

---@class Testing.SheetStep.NotesDoc
---@field id string
---@field root string
---@field date string Local date of the run, `YYYY-MM-DD`.
---@field status string How the run ended (`pass`, `fail`, `aborted`, ...).
---@field notes Testing.SheetStep.Note[]

---Two roots of one project: where the file system ignores case (Windows, macOS), so does this.
---@param a any
---@param b string
---@return boolean
local function same_root(a, b)
  if type(a) ~= "string" then
    return false
  end
  if require("testing.platform").is_case_insensitive() then
    return a:lower() == b:lower()
  end
  return a == b
end

---The notes of the last stepped run of a sheet of this project, nil when it had none (or ran in another project).
---@param root string
---@param id string
---@return Testing.SheetStep.NotesDoc|nil
function M.last_notes(root, id)
  local f = io.open(M.evidence_dir(id) .. "/" .. M.NOTES_FILE, "rb")
  if not f then
    return nil
  end
  local text = f:read(1024 * 1024) or ""
  f:close()
  local ok, doc = pcall(vim.json.decode, text)
  if
    not ok
    or type(doc) ~= "table"
    or doc.id ~= id
    or not same_root(doc.root, root)
    or type(doc.notes) ~= "table"
    or #doc.notes == 0
  then
    return nil
  end
  local notes = {}
  for _, n in ipairs(doc.notes) do
    if
      type(n) == "table"
      and type(n.text) == "string"
      and type(n.n) == "number"
      and type(n.size) == "string"
    then
      notes[#notes + 1] = { size = n.size, n = n.n, text = n.text, time = tostring(n.time or "") }
    end
  end
  if #notes == 0 then
    return nil
  end
  return {
    id = id,
    root = root,
    date = tostring(doc.date or ""),
    status = tostring(doc.status or ""),
    notes = notes,
  }
end

---@param v any
---@param max number
---@return boolean
local function whole(v, max)
  return v ~= nil and v == math.floor(v) and v >= 0 and v <= max
end

---@param argv string[]
---@return table|nil options, string|nil err
local function parse(argv)
  local o = { breaks = {}, break_list = {} }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--headed" then
      o.headed = true
      i = i + 1
    elseif a == "--run" then
      o.run = true
      i = i + 1
    elseif a == "--format" or a:match("^%-%-format=") then
      local v = a:match("^%-%-format=(.*)$")
      if not v then
        v = argv[i + 1]
        i = i + 1
      end
      if v ~= "json" and v ~= "text" then
        return nil, ("--format is json or text, got %s"):format(tostring(v))
      end
      o.format = v
      i = i + 1
    elseif a == "--tasks" or a == "--tasks-cli" then
      if not argv[i + 1] then
        return nil, a .. " needs a value"
      end
      o[a == "--tasks" and "vault" or "cli"] = argv[i + 1]
      i = i + 2
    elseif a == "--root" or a == "--delay" or a == "--break" then
      local v = argv[i + 1]
      if not v then
        return nil, a .. " needs a value"
      end
      if a == "--root" then
        o.root = v
      else
        local n = tonumber(v)
        local max = require("testing.sheet").MAX_MS
        if not whole(n, max) or (a == "--break" and n < 1) then
          return nil, ("%s needs a whole number, got %s"):format(a, v)
        end
        if a == "--delay" then
          o.delay = n
        elseif not o.breaks[n] then
          o.breaks[n] = true
          o.break_list[#o.break_list + 1] = n
        end
      end
      i = i + 2
    elseif a:sub(1, 2) == "--" then
      return nil, "unknown argument " .. a
    elseif o.target then
      return nil, "one sheet at a time, got also " .. a
    else
      o.target = a
      i = i + 1
    end
  end
  if not o.target then
    return nil, "which sheet?"
  end
  if o.format == "text" and not o.run then
    return nil, "--format=text belongs to --run: a client that sends commands reads the JSON events"
  end
  if o.run and #o.break_list > 0 then
    return nil, "--run reads no commands, nothing could go on after a --break"
  end
  if o.cli and not o.vault then
    return nil, "--tasks-cli belongs to --tasks <vault>"
  end
  return o, nil
end

---A file, or an id or file name below `<root>/TESTS/sheets`. The root of a file below `TESTS/sheets` is its project.
---@param o table
---@return Testing.Sheet|nil sheet, string root_or_err
local function find_sheet(o)
  local sheet = require("testing.sheet")
  local target = o.target
  local path
  local function abs(p)
    return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
  end
  if vim.fn.filereadable(target) == 1 then
    path = abs(target)
  elseif o.root and vim.fn.filereadable(o.root .. "/" .. target) == 1 then
    path = abs(o.root .. "/" .. target)
  end
  local root = o.root and abs(o.root):gsub("/+$", "")
    or (path and path:match("^(.*)/TESTS/sheets/"))
    or abs("."):gsub("/+$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    return nil, ("--root %s is not a directory"):format(root)
  end
  if not path then
    for _, file in ipairs(sheet.files(root .. "/TESTS/sheets")) do
      local s = sheet.load(file)
      local base = vim.fs.basename(file):gsub("%.sheet%.lua$", "")
      if base == target or (s and s.id == target) then
        path = file
        break
      end
    end
  end
  if not path then
    return nil, ("no sheet %s in %s/TESTS/sheets"):format(target, root)
  end
  local s, err = sheet.load(path)
  if not s then
    return nil, tostring(err)
  end
  return s, root
end

---`answer yes|no [text]`.
---@param cmd string
---@return { yes: boolean, note?: string }|nil
local function parse_answer(cmd)
  local word, note = cmd:match("^answer%s+(%a+)%s*(.-)%s*$")
  if word ~= "yes" and word ~= "no" then
    return nil
  end
  return { yes = word == "yes", note = note ~= "" and note or nil }
end

---@param cmd string
---@param at Testing.Sheet.NextStep|nil The step that is next; nil when nothing is left in this size.
---@return { mode?: string, until_n?: integer, abort?: boolean, break_n?: integer, clear?: boolean }|nil plan, string|nil err
local function parse_command(cmd, at)
  if cmd == "next" then
    return { mode = "step" }
  elseif cmd == "continue" then
    return { mode = "continue" }
  elseif cmd == "abort" then
    return { abort = true }
  end
  local word, step = cmd:match("^(%a+)%s+(%d+)$")
  if word == "break" or word == "clear" then
    local b = tonumber(step)
    if at and (b < 1 or b > at.total) then
      return nil, ("%s needs a step of the sheet, 1 to %d"):format(word, at.total)
    end
    return { break_n = b, clear = word == "clear" }
  end
  local n = tonumber(cmd:match("^until%s+(%d+)$"))
  if n then
    if at and (n <= at.n or n > at.total) then
      return nil, ("until needs a later step, %d to %d"):format(at.n + 1, at.total)
    end
    return { mode = "until", until_n = n }
  end
  return nil, "unknown command: " .. cmd
end

---`testing sheets step`: exit 0 green (or a skip), 1 a step failed, 2 bad usage or refused, 3 aborted.
---@param argv string[] The arguments after `step`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetStep.Deps
---@return integer
function M.main(argv, sv, deps)
  deps = deps or {}
  local o, perr = parse(argv)
  if not o then
    sv.err("testing sheets: " .. tostring(perr) .. "\n" .. M.USAGE)
    return 2
  end
  local gate = require("testing.sheet.run")
  local getenv = deps.getenv or vim.uv.os_getenv
  -- the workstation decides once the sheet is loaded as data (only a manual one runs there); a typo stops here
  if not gate.manual_only_here(getenv) then
    local refused = gate.refused(getenv)
    if refused then
      sv.err(refused)
      return 2
    end
  end
  local s, root = find_sheet(o)
  if not s then
    -- on the workstation too: a sheet that does not load is never run
    sv.err("testing sheets: " .. tostring(root))
    return 2
  end
  local refused = gate.refused(getenv, { { sheet = s } })
  if refused then
    sv.err(refused)
    return 2
  end
  for _, n in ipairs(o.break_list) do
    if n > #s.steps then
      sv.err(("testing sheets: --break %d: the sheet has %d steps"):format(n, #s.steps))
      return 2
    end
  end
  local trust_check = deps.trust_check or require("testing.trust").check
  local refusal = trust_check(root)
  if refusal then
    sv.err("testing sheets: " .. refusal)
    return 2
  end

  -- the block is written whole: the state of another sheet of the task would be lost, so that is said before anything runs
  local call = deps.call
  if o.vault then
    if not s.task then
      sv.err("testing sheets: --tasks: the sheet names no task")
      return 2
    end
    local entries = require("testing.sheet.report").collect({ root }, { cases = {} })
    for _, e in ipairs(entries) do
      if e.sheet and e.sheet.task == s.task and e.sheet.id ~= s.id then
        sv.err(
          ("testing sheets: --tasks: %s also has the sheet %s, whose state this run would lose: use `testing sheets run --task`"):format(
            s.task,
            e.sheet.id
          )
        )
        return 2
      end
    end
    if not call then
      local tasks = require("testing.sheet.tasks")
      local vault = vim.fs.normalize(vim.fn.fnamemodify(o.vault, ":p")):gsub("/+$", "")
      local cli, lerr = tasks.locate(vault, { cli = o.cli })
      if not cli then
        sv.err("testing sheets: " .. tostring(lerr))
        return 3
      end
      call = tasks.caller(cli, vault)
    end
  end

  local session
  local write = deps.emit
    or function(line)
      local ok = io.stdout:write(line, "\n")
      io.stdout:flush()
      return ok and true or false
    end
  local before = {}
  local function emit(event, fields)
    fields = fields or {}
    fields.schema, fields.event = M.SCHEMA, event
    local line
    if o.format == "text" then
      line = M.text_line(fields, before)
      if not line then
        return
      end
    else
      line = vim.json.encode(fields)
    end
    -- nobody reads any more: nothing is left to do but clean up
    if not write(line) and session then
      session:cancel()
    end
  end

  local started = vim.uv.hrtime()
  local action_of = require("testing.sheet.session").action_of
  local steps = {}
  for n, step in ipairs(s.steps) do
    local action, value = action_of(step)
    steps[n] = { n = n, action = action, value = value, note = step.note }
  end
  -- One folder per sheet, emptied here: what a person looks at is the last run.
  local evidence_dir = M.evidence_dir(s.id)
  vim.fn.delete(evidence_dir, "rf")
  local opts = vim.tbl_extend("force", {
    root = root,
    ci = true,
    capture_screen = true,
    headed = o.headed,
    evidence_dir = evidence_dir,
    on_size = function(tag, state, reason)
      emit("size", { size = tag, state = state, reason = reason })
    end,
  }, deps.session_opts or {})
  session = require("testing.sheet.session").open(s, opts)
  local reader = not o.run and (deps.reader or stdin_reader()) or nil

  emit("start", {
    id = s.id,
    title = s.title,
    engine = s.engine,
    task = s.task,
    app = s.app,
    path = s.path,
    root = root,
    sizes = s.sizes,
    steps = steps,
    headed = o.headed == true and s.engine == "browser",
    delay_ms = o.delay or 0,
    breaks = o.break_list,
    judge = s.judge,
    manual = s.manual,
  })

  local mode, until_n = o.run and "continue" or "step", nil
  local stopped_once = false
  local answers, answered = {}, {}
  ---@type Testing.SheetStep.Note[]
  local notes = {}
  -- the step the run stands before, else the one that ran last (set before a step, kept after it): where a note belongs
  local pos ---@type { size: string, n: integer }|nil

  ---@param text string
  local function add_note(text)
    if text == "" then
      emit("error", { message = "note needs a text: note <text>" })
    elseif #text > M.MAX_NOTE then
      emit("error", { message = ("a note is at most %d bytes"):format(M.MAX_NOTE) })
    elseif not pos then
      emit("error", { message = "no step yet to put a note on" })
    elseif #notes >= M.MAX_NOTES then
      emit("error", { message = ("at most %d notes in a run"):format(M.MAX_NOTES) })
    else
      local note =
        { size = pos.size, n = pos.n, text = text, time = os.date("!%Y-%m-%dT%H:%M:%SZ") }
      notes[#notes + 1] = note
      emit("note", vim.deepcopy(note))
    end
  end

  ---A question: waits for its answer. Nil when the run is to end.
  ---@param at Testing.Sheet.NextStep
  ---@return { yes: boolean, note?: string }|nil
  local function ask(at)
    ---@cast reader -nil
    emit("ask", { size = at.size, n = at.n, text = at.value })
    while not session.aborted do
      local cmd = reader.next()
      if not cmd or cmd == "abort" then
        session:cancel()
        return nil
      end
      local note = M.note_text(cmd)
      local plan = not note and parse_command(cmd, at) or nil
      local answer = parse_answer(cmd)
      if note then
        add_note(note)
      elseif plan and plan.break_n then
        -- the panel does not wait for a stop to send a breakpoint: no error, and the question still stands
        o.breaks[plan.break_n] = not plan.clear or nil
      elseif answer then
        answers[#answers + 1] = {
          size = at.size,
          n = at.n,
          text = at.value,
          answer = answer.yes and "yes" or "no",
          note = answer.note,
        }
        if answer.yes then
          answered[#answered + 1] = at.value
        end
        return answer
      else
        emit("error", { message = "this step waits for: answer yes|no [text]" })
      end
    end
    return nil
  end

  ---Paused until a command says how to go on; false when the run is to end.
  ---@param reason string
  ---@param n integer
  ---@param size string
  ---@param at Testing.Sheet.NextStep|nil
  ---@return boolean
  local function pause(reason, n, size, at)
    if session.aborted then
      return false
    end
    ---@cast reader -nil
    emit("paused", { size = size, n = n, reason = reason })
    while true do
      local cmd = reader.next()
      if not cmd then
        session:cancel()
        return false
      end
      local note = M.note_text(cmd)
      local plan, err
      if not note then
        plan, err = parse_command(cmd, at)
      end
      if note then
        add_note(note)
      elseif not plan then
        emit("error", { message = err })
      elseif plan.abort then
        session:cancel()
        return false
      elseif plan.break_n then
        -- holds in every size, from now on; the run stays paused
        o.breaks[plan.break_n] = not plan.clear or nil
      else
        mode, until_n = plan.mode, plan.until_n
        return true
      end
    end
  end

  local function loop()
    if reader then
      reader.start(function()
        session:cancel()
      end, add_note)
    end
    while true do
      local at = session:peek()
      if not at then
        return
      end
      pos = { size = at.size, n = at.n }
      emit("step-before", {
        size = at.size,
        n = at.n,
        total = at.total,
        action = at.action,
        value = at.value,
        note = at.note,
      })
      local reason
      local answer
      if at.action == "ask" and reader then
        -- the question is its own stop, under `continue` too
        stopped_once = true
        answer = ask(at)
        if not answer then
          return
        end
      elseif mode == "step" then
        reason = stopped_once and "step" or "start"
      elseif mode == "until" and until_n == at.n then
        reason = "until"
      elseif o.breaks[at.n] then
        reason = "break"
      end
      if reason then
        stopped_once = true
        if not pause(reason, at.n, at.size, at) then
          return
        end
      elseif o.delay and o.delay > 0 then
        vim.wait(o.delay, function()
          return session.aborted
        end, 10)
        if session.aborted then
          return
        end
      end
      local res = session:step(answer)
      if not res then
        return
      end
      emit("step-after", {
        size = res.size,
        n = res.n,
        status = res.status,
        ms = res.ms,
        reason = res.reason,
        failure = res.failure,
        shot = res.shot,
        image = res.image,
        screen = res.screen,
        measure = res.measure,
      })
      -- a measured value is a note of the run, as a person would take it: kept, and with --tasks in the task
      if res.measure then
        add_note(require("testing.sheet").measure_text(res.measure))
      end
      -- a failure is where a person wants to look, before the next size or the end takes the target away
      if res.status == "fail" and reader then
        if not pause("failed", res.n, res.size, nil) then
          return
        end
      end
    end
  end

  local task_failed = false
  local ok, err = xpcall(loop, debug.traceback)
  if reader then
    reader.stop()
  end
  -- first clean up, then say so: after `end` nothing of the run is left
  session:close()
  if not ok then
    session:cancel()
    sv.err("testing sheets: " .. tostring(err))
  end
  local res = session:result()
  local verdict = res.status == "pass" or res.status == "fail" or res.status == "manual"
  local run_date = os.date("%Y-%m-%d") --[[@as string]]
  if #notes > 0 then
    -- kept beside the pictures of the run, for `testing sheets report`; an aborted run's notes too
    local doc = { id = s.id, root = root, date = run_date, status = res.status, notes = notes }
    local wok, werr = require("lib.nvim.fs.write.atomic")(
      evidence_dir .. "/" .. M.NOTES_FILE,
      vim.json.encode(doc),
      { mkdirp = true }
    )
    if not wok then
      sv.err("testing sheets: the notes were not kept: " .. tostring(werr))
    end
  end
  if verdict and o.vault then
    local tasks = require("testing.sheet.tasks")
    local entries = require("testing.sheet.report").collect({ root }, { cases = {} })
    entries = vim.tbl_filter(function(e)
      return e.sheet and e.sheet.id == s.id
    end, entries)
    for _, e in ipairs(entries) do
      e.result = res
      e.answered = answered
      e.new_notes = #notes > 0 and { date = run_date, notes = notes } or nil
      e.case = {
        name = require("testing.sheet").spec_name(s),
        status = res.status == "fail" and "fail" or "pass",
        file = "TESTS/sheets_spec.lua",
        message = res.status == "fail" and require("testing.sheet.run").first_failure(res) or nil,
        duration_ms = math.floor((vim.uv.hrtime() - started) / 1e6),
      }
    end
    local results, serr = tasks.sync(entries, { call = call })
    if not results then
      sv.err("testing sheets: " .. tostring(serr))
    end
    for _, r in ipairs(results or {}) do
      emit("task", { id = r.id, outcome = r.outcome, message = r.message })
      task_failed = task_failed or not (r.outcome == "changed" or r.outcome == "unchanged")
    end
    task_failed = task_failed or not results
  end
  emit("end", {
    status = res.status,
    ok = res.ok,
    verdict = verdict,
    answers = answers,
    notes = #notes > 0 and notes or nil,
    failures = res.failures,
    snapshots = res.snapshots,
    skipped = res.skipped,
    ms = math.floor((vim.uv.hrtime() - started) / 1e6),
  })
  if res.status == "aborted" then
    return 3
  end
  return (res.status == "fail" or task_failed) and 1 or 0
end

return M
