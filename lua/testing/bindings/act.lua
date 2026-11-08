---@module 'testing.bindings.act'
---@brief `:Testing act`: the finding under the cursor (or of the quickfix entry, or a choice) to a task, a rule or the AI.
---@description
--- The editor side of `testing act` (`testing.act`). The target is, in this order: the current quickfix entry when it
--- points at a finding, the line under the cursor when a finding is there, else a choice of the findings of the last
--- run. Then two steps, each with a heading that names the target: *what* (task, rule, AI) and *how* (the modes the
--- target takes; skipped when there is one).
---
--- Nothing is written before a person said yes: a task and a rule are a dry run of the target's engine first, then a
--- question; a duplicate only names the task that is already there. A rule in mode `ai-draft` goes to `:Rules agent
--- --intent=<file>` when rules.nvim is loaded (its form asks before anything is sent to a model). The AI gets a hand-over
--- file in testing's own state folder and the command for Claude Code in the clipboard register `+`; nothing is started
--- or sent (rule `PRIN-60`).

local M = {}

---Seams for specs: the engines (`testing.act` `Testing.Act.Engines`), the question, the choice and the input.
---@type Testing.Act.Engines
M.engines = {}

---@param question string
---@param choices string[]
---@param cb fun(index: integer, dismissed: boolean)
M.ask = function(question, choices, cb)
  require("testing.bindings.usrcmds").ask(question, choices, cb)
end

---@param items any[]
---@param opts table
---@param cb fun(item: any|nil, index: integer|nil)
M.select = function(items, opts, cb)
  vim.ui.select(items, opts, cb)
end

---@param opts table
---@param cb fun(text: string|nil)
M.input = function(opts, cb)
  vim.ui.input(opts, cb)
end

---@return table
local function notify()
  return require("testing.notify").get()
end

---@param root string
---@param file string
---@return string|nil rel
local function relative(root, file)
  if not file or file == "" then
    return nil
  end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  local prefix = vim.fs.normalize(root) .. "/"
  if vim.fn.has("win32") == 1 then
    if abs:lower():sub(1, #prefix) == prefix:lower() then
      return abs:sub(#prefix + 1)
    end
  elseif abs:sub(1, #prefix) == prefix then
    return abs:sub(#prefix + 1)
  end
  return nil
end

---The finding at a place: the same file (repository-relative) and, when the finding has one, the same line.
---@param docs table[]
---@param rel string|nil
---@param line integer|nil
---@return table|nil
local function at(docs, rel, line)
  if not rel then
    return nil
  end
  local same_file
  for _, d in ipairs(docs) do
    local where = type(d.where) == "table" and d.where or nil
    if where and where.file == rel then
      if type(where.line) == "number" and where.line == line then
        return d
      end
      same_file = same_file or d
    end
  end
  -- a file with one finding and a cursor somewhere in it: that finding
  local count = 0
  for _, d in ipairs(docs) do
    if type(d.where) == "table" and d.where.file == rel then
      count = count + 1
    end
  end
  return count == 1 and same_file or nil
end

---The target among the findings: the quickfix entry, then the cursor.
---@param docs table[]
---@param root string
---@param place? { qf?: { file: string, line: integer }, file?: string, line?: integer } Specs pass it; default the editor's.
---@return table|nil
function M.target(docs, root, place)
  if not place then
    place = {}
    local qf = vim.fn.getqflist({ idx = 0, items = 1 })
    local item = qf.items and qf.items[qf.idx or 0]
    if item and item.bufnr and item.bufnr > 0 then
      place.qf = { file = vim.api.nvim_buf_get_name(item.bufnr), line = item.lnum }
    end
    place.file = vim.api.nvim_buf_get_name(0)
    place.line = vim.api.nvim_win_get_cursor(0)[1]
  end
  if place.qf then
    local d = at(docs, relative(root, place.qf.file), place.qf.line)
    if d then
      return d
    end
  end
  return at(docs, relative(root, place.file), place.line)
end

---@param doc table
---@return string
local function label(doc)
  return ("%s: %s"):format(doc.kind, (tostring(doc.title):gsub("%c+", " ")))
end

M.WHAT = {
  { id = "task", text = "Task (tasks.nvim)" },
  { id = "rule", text = "Rule (rules.nvim)" },
  { id = "ai", text = "AI (hand-over for Claude Code)" },
}

M.HOW = {
  form = "Form: the target's form, filled in",
  ["ai-draft"] = "AI draft: the target drafts the text, then its form",
  agent = "Agent: a hand-over file and the command for Claude Code",
}

---Show a result.
---@param doc table
---@param res Testing.Act.Result|nil
---@param err string|nil
local function report(doc, res, err)
  if not res then
    notify().error(("testing act %s: %s"):format(doc.fp, tostring(err)))
  else
    notify().info(("testing act %s: %s"):format(doc.fp, res.text))
  end
end

---A task or a rule: the dry run, then the question, then the engine again with yes.
---@param doc table
---@param once fun(yes: boolean): Testing.Act.Result|nil, string|nil
local function confirm_then(doc, once)
  local res, err = once(false)
  if not res or res.outcome ~= "would_create" then
    return report(doc, res, err)
  end
  M.ask(("%s\n%s"):format(label(doc), res.text), { "Cancel", "Create" }, function(index)
    if index == 2 then
      report(doc, once(true))
    end
  end)
end

---Do one action on one finding.
---@param root string
---@param doc table
---@param what "task"|"rule"|"ai"
---@param mode string
function M.perform(root, doc, what, mode)
  local act = require("testing.act")
  local intent, ierr = act.intent(doc, what, mode)
  if not intent then
    return report(doc, nil, ierr)
  end
  if what == "task" then
    local call, cerr = M.engines.tasks, nil
    if not call then
      call, cerr = act.tasks_caller({}, vim.uv.os_getenv)
    end
    if not call then
      return report(doc, nil, cerr)
    end
    return confirm_then(doc, function(yes)
      return act.to_task(intent, yes, call)
    end)
  end
  if what == "rule" then
    if mode == "ai-draft" and vim.fn.exists(":Rules") == 2 and not M.engines.rules then
      -- the editor form of rules.nvim: it drafts, shows what goes to the model and asks before it creates
      local file = act.handoff_file(root, doc.fp) .. ".rule.json"
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      vim.fn.writefile({ vim.json.encode(intent) }, file)
      return vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(file))
    end
    local run = M.engines.rules
    if not run then
      local cli, lerr = act.locate_rules(root)
      if not cli then
        return report(doc, nil, lerr)
      end
      run = act.rules_runner(cli)
    end
    -- the engine takes the family from a rule id only (`LUA-12`); anything else is asked for
    local family = type(doc.rule) == "string" and doc.rule:match("^(%a+)%-%d+$") or nil
    local function go(fam)
      confirm_then(doc, function(yes)
        return act.to_rule(intent, { yes = yes, family = fam }, run)
      end)
    end
    if family then
      return go(nil)
    end
    return M.input({ prompt = "Rule family for " .. label(doc) .. " (e.g. LUA): " }, function(text)
      if text and text:match("^%a+$") then
        go(text:upper())
      elseif text and text ~= "" then
        report(doc, nil, "a family is letters only: " .. text)
      end
    end)
  end
  local file = act.handoff_file(root, doc.fp)
  M.ask(
    ("%s\nWrite the hand-over %s? Nothing is sent or started."):format(label(doc), file),
    { "Cancel", "Write" },
    function(index)
      if index ~= 2 then
        return
      end
      local res, err = act.to_ai(intent, true, file)
      if res and res.command then
        pcall(vim.fn.setreg, "+", res.command)
        res.text = res.text .. "\n(the command is in register +)"
      end
      report(doc, res, err)
    end
  )
end

---Ask what and how, then perform.
---@param root string
---@param doc table
function M.choose(root, doc)
  local act = require("testing.act")
  M.select(M.WHAT, {
    prompt = ("Testing act: %s -- what?"):format(label(doc)),
    format_item = function(w)
      return w.text
    end,
  }, function(w)
    if not w then
      return
    end
    local modes = act.MODES[w.id]
    if #modes == 1 then
      return M.perform(root, doc, w.id, modes[1])
    end
    M.select(modes, {
      prompt = ("Testing act: %s -- how?"):format(label(doc)),
      format_item = function(m)
        return M.HOW[m] or m
      end,
    }, function(m)
      if m then
        M.perform(root, doc, w.id, m)
      end
    end)
  end)
end

---`:Testing act [--root=<dir>]`.
---@param root string
---@param place? table See `M.target`.
function M.run(root, place)
  local docs, err = require("testing.act").findings(root)
  if not docs then
    return notify().error("testing act: " .. tostring(err))
  end
  if #docs == 0 then
    return notify().info("testing act: no findings in the last run of " .. root)
  end
  local doc = M.target(docs, root, place)
  if doc then
    return M.choose(root, doc)
  end
  M.select(docs, { prompt = "Testing act: which finding?", format_item = label }, function(d)
    if d then
      M.choose(root, d)
    end
  end)
end

return M
