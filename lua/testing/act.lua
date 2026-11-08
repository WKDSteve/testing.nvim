---@module 'testing.act'
---@brief `testing act`: hand a finding to a task, a rule or the AI, as an intent `wkd-intent/1`; the target's engine writes.
---@description
--- One way in for the actions on a finding (`testing-finding/1`, `testing.finding`), from the command line and the
--- editor (`:Testing act`, `testing.bindings.act`):
---
---   testing act [--root=<dir>] --list [--json]
---   testing act [--root=<dir>] <fp> --do=task|rule|ai [--mode=form|ai-draft|agent] [--yes]
---
--- * `--list` prints the findings of the last run and, per finding, the tasks that already name it (the way back: a
---   lookup through `tasks call find` with the ref `testing-finding:<fp>`, nothing written back) and its rule id.
--- * `--do=task` hands `tasks.new` to the tasks engine (`tasks call intent`), `--do=rule` hands `rules.new` to the rules
---   engine (`rules.lua intent -`). Without `--yes` both are a dry run (`would_create`); a task that already names the
---   finding is `exists`, shown as "already there: <id>".
--- * `--do=ai` writes the intent `ai.handoff` into this repository's own state folder and prints the command that hands it
---   to Claude Code. Nothing is started and nothing is sent (rule `PRIN-60`); without `--yes` it only says where it would
---   write.
---
--- testing never writes into another vault: every write is a call of the target's engine, after a dry run or `--yes`.
--- The engines are found like dependencies: the tasks CLI from the vault (`--vault`, `$TASKS_VAULT`;
--- `testing.sheet.tasks.locate`), the rules CLI next to the repository (`$RULES_NVIM_DIR`, `.deps`, a sibling checkout).

local M = {}

M.SCHEMA = "wkd-intent/1"

---`--do` and the action of the intent.
M.ACTIONS = { task = "tasks.new", rule = "rules.new", ai = "ai.handoff" }

---The modes per target, the first is the default. The headless engines of tasks and rules take `form` only; `ai-draft`
---of a rule goes through `:Rules agent` in the editor.
M.MODES = {
  task = { "form" },
  rule = { "form", "ai-draft" },
  ai = { "agent", "form" },
}

---The ref a task carries for a finding (decision D5, tasks.nvim `ops.REF_NAMESPACES`).
M.REF_PREFIX = "testing-finding:"

---At most this many refs per `tasks call find` (tasks.nvim `find.MAX_REFS`).
M.FIND_CHUNK = 50

---The size limit of an intent (the target refuses more).
M.MAX_BYTES = 64 * 1024

M.TIMEOUT_MS = 60000

M.EXIT_OK = 0
M.EXIT_FAILED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

---@class Testing.Act.Engines
---@field tasks? Testing.SheetTasks.Call `call <method> {params}` of the tasks engine.
---@field rules? fun(intent: table, opts: { yes: boolean, family?: string, severity?: string }): table|nil, string|nil `rules.lua intent -`.

---The findings of a repository (`testing.finding.collect`, secrets known to the export redacted).
---@param dir string
---@param opts? { state_dir?: string, areas?: string }
---@return table[]|nil docs
---@return string|nil err
---@return string|nil kind `testing.finding.REFUSED` for a repository the data classes do not release.
function M.findings(dir, opts)
  opts = opts or {}
  local finding = require("testing.finding")
  local docs, err, kind
  require("testing.export").with_secrets(function()
    docs, err, kind = finding.collect({
      dir = dir,
      state_dir = opts.state_dir,
      classes = opts.areas and { path = opts.areas } or nil,
    })
  end)
  return docs, err, kind
end

---The finding of a fingerprint, or of a unique prefix of at least 4 hex.
---@param docs table[]
---@param fp string
---@return table|nil doc
---@return string|nil err
function M.pick(docs, fp)
  if type(fp) ~= "string" or not fp:match("^%x%x%x%x+$") or #fp > 16 then
    return nil, ("%s is not a fingerprint (4 to 16 hex)"):format(tostring(fp))
  end
  fp = fp:lower()
  local hits = {}
  for _, d in ipairs(docs) do
    if d.fp == fp then
      return d
    end
    if d.fp:sub(1, #fp) == fp then
      hits[#hits + 1] = d
    end
  end
  if #hits == 1 then
    return hits[1]
  end
  if #hits > 1 then
    return nil, ("%s names %d findings, give more of it"):format(fp, #hits)
  end
  return nil, ("no finding %s in the last run of this repository"):format(fp)
end

---The intent of one action on one finding.
---@param doc table A document of `testing-finding/1`.
---@param what "task"|"rule"|"ai"
---@param mode? string
---@return table|nil intent
---@return string|nil err
function M.intent(doc, what, mode)
  local action = M.ACTIONS[what]
  if not action then
    return nil, ("--do must be task, rule or ai, not %s"):format(tostring(what))
  end
  mode = mode or M.MODES[what][1]
  if not vim.tbl_contains(M.MODES[what], mode) then
    return nil,
      ("--do=%s takes the mode %s, not %s"):format(
        what,
        table.concat(M.MODES[what], " or "),
        tostring(mode)
      )
  end
  if doc.class ~= "public" and doc.class ~= "internal" then
    -- a finding is never built for another class; this is the second lock
    return nil, ("a finding of class %s does not leave this machine"):format(tostring(doc.class))
  end
  local intent = {
    schema = M.SCHEMA,
    action = action,
    mode = mode,
    source = { app = "testing", finding = doc.fp },
    finding = doc,
    target = vim.NIL,
  }
  if #vim.json.encode(intent) > M.MAX_BYTES then
    return nil, "the intent is larger than 64 KiB"
  end
  return intent
end

---The tasks that name these findings, open or finished: `{ [fp] = { { id, status, location }... } }`.
---@param docs table[]
---@param call Testing.SheetTasks.Call
---@return table<string, table[]>|nil links
---@return string|nil err
function M.links(docs, call)
  local out = {}
  for i = 1, #docs, M.FIND_CHUNK do
    local refs = {}
    for j = i, math.min(i + M.FIND_CHUNK - 1, #docs) do
      refs[#refs + 1] = M.REF_PREFIX .. docs[j].fp
    end
    local doc, err = call("find", { refs = refs })
    if not doc then
      return nil, err
    end
    for _, m in ipairs(type(doc.matches) == "table" and doc.matches or {}) do
      local fp = type(m.ref) == "string"
        and m.ref:sub(1, #M.REF_PREFIX) == M.REF_PREFIX
        and m.ref:sub(#M.REF_PREFIX + 1)
      if fp then
        out[fp] = out[fp] or {}
        table.insert(out[fp], { id = m.id, status = m.status, location = m.location })
      end
    end
  end
  return out
end

---@param v any
---@return string
local function one_line(v)
  return (tostring(v):gsub("[%c]+", " "))
end

---One line of `--list`.
---@param doc table
---@param tasks? table[]
---@return string
function M.list_line(doc, tasks)
  local parts = { doc.fp, doc.kind, one_line(doc.title) }
  for _, t in ipairs(tasks or {}) do
    parts[#parts + 1] = ("task %s (%s)"):format(one_line(t.id), one_line(t.status))
  end
  if type(doc.rule) == "string" then
    parts[#parts + 1] = "rule " .. one_line(doc.rule)
  end
  return table.concat(parts, "  ")
end

---The result of one action, in words: `{ outcome, id?, text }`.
---@class Testing.Act.Result
---@field outcome "would_create"|"created"|"exists"|"would_write"|"written"
---@field id? string
---@field file? string
---@field command? string
---@field text string

---Hand `tasks.new` to the tasks engine.
---@param intent table
---@param yes boolean
---@param call Testing.SheetTasks.Call
---@return Testing.Act.Result|nil
---@return string|nil err
function M.to_task(intent, yes, call)
  local doc, err = call("intent", { intent = intent, yes = yes })
  if not doc then
    return nil, err
  end
  local outcome = doc.outcome
  if outcome == "exists" then
    return {
      outcome = "exists",
      id = doc.id,
      text = ("already there: %s (%s)"):format(one_line(doc.id), one_line(doc.status)),
    }
  elseif outcome == "created" then
    return { outcome = "created", id = doc.id, text = "created task " .. one_line(doc.id) }
  elseif outcome == "would_create" then
    return {
      outcome = "would_create",
      text = ("would create a task in %s: %s (--yes creates it)"):format(
        one_line(doc.area),
        one_line(doc.title)
      ),
    }
  end
  return nil, ("the tasks engine answered %s"):format(one_line(outcome))
end

---Hand `rules.new` to the rules engine.
---@param intent table
---@param opts { yes: boolean, family?: string, severity?: string }
---@param run fun(intent: table, opts: table): table|nil, string|nil
---@return Testing.Act.Result|nil
---@return string|nil err
function M.to_rule(intent, opts, run)
  local res, err = run(intent, opts)
  if not res then
    return nil, err
  end
  local doc = type(res.document) == "table" and res.document or {}
  local entry = type(doc.results) == "table" and doc.results[1] or {}
  local id = type(entry) == "table" and (entry.id or entry.rule) or nil
  if res.dry_run == false then
    return {
      outcome = "created",
      id = id,
      text = "created rule " .. one_line(id or "(the engine named no id)"),
    }
  end
  return {
    outcome = "would_create",
    id = id,
    text = ("would create rule %s: %s (--yes creates it)"):format(
      one_line(id or opts.family or "?"),
      one_line(intent.finding.title)
    ),
  }
end

---The file of an AI hand-over: this repository's own state folder, never a vault.
---@param dir string
---@param fp string
---@param state_dir? string
---@return string
function M.handoff_file(dir, fp, state_dir)
  return require("testing.history").dir(dir, { state_dir = state_dir }) .. "/act/" .. fp .. ".json"
end

---The command that hands a file to Claude Code; printed or copied, never run.
---@param file string
---@return string
function M.claude_command(file)
  return ('claude "Read %s: a finding of testing.nvim (wkd-intent/1, ai.handoff). Explain the failure and propose a fix; change nothing before I confirm."'):format(
    file
  )
end

---Write the intent `ai.handoff` (with `yes`) and name the command for Claude Code.
---@param intent table
---@param yes boolean
---@param file string
---@return Testing.Act.Result|nil
---@return string|nil err
function M.to_ai(intent, yes, file)
  if not yes then
    return {
      outcome = "would_write",
      file = file,
      text = ("would write the hand-over %s (--yes writes it; nothing is sent or started)"):format(
        file
      ),
    }
  end
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local text = require("testing.export").encode(intent)
  if not text then
    return nil, "the intent could not be encoded"
  end
  local tmp = file .. ".tmp"
  local f, oerr = io.open(tmp, "wb")
  if not f then
    return nil, ("cannot write %s: %s"):format(tmp, tostring(oerr))
  end
  f:write(text, "\n")
  f:close()
  -- Windows does not rename over an existing file: the second try after removing the old hand-over
  if not os.rename(tmp, file) then
    os.remove(file)
    local okr, rerr = os.rename(tmp, file)
    if not okr then
      os.remove(tmp)
      return nil, ("cannot write %s: %s"):format(file, tostring(rerr))
    end
  end
  local command = M.claude_command(file)
  return {
    outcome = "written",
    file = file,
    command = command,
    text = ("wrote the hand-over %s; hand it to Claude Code with:\n%s"):format(file, command),
  }
end

---The last line of a process's stdout that reads as a JSON object.
---@param stdout string|nil
---@return table|nil
local function last_json(stdout)
  local last
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    last = line
  end
  local okj, doc = pcall(vim.json.decode, last or "", { luanil = { object = true, array = true } })
  return okj and type(doc) == "table" and doc or nil
end

---A runner of `rules.lua intent -` in a headless editor of its own.
---@param cli string
---@param opts? { nvim?: string, timeout_ms?: integer }
---@return fun(intent: table, o: { yes: boolean, family?: string, severity?: string }): table|nil, string|nil
function M.rules_runner(cli, opts)
  opts = opts or {}
  return function(intent, o)
    local argv = { opts.nvim or vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n" }
    vim.list_extend(argv, { "-l", cli, "intent", "-" })
    if o.family then
      argv[#argv + 1] = "--family=" .. o.family
    end
    if o.severity then
      argv[#argv + 1] = "--severity=" .. o.severity
    end
    if o.yes then
      argv[#argv + 1] = "--yes"
    end
    local okp, res = pcall(function()
      return vim
        .system(argv, { stdin = vim.json.encode(intent), text = true })
        :wait(opts.timeout_ms or M.TIMEOUT_MS)
    end)
    if not okp then
      return nil, ("rules.nvim intent could not start: %s"):format(tostring(res))
    end
    local doc = res.code == 0 and last_json(res.stdout) or nil
    if not doc then
      local why = ((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
        :gsub("%s+", " ")
        :sub(1, 300)
      return nil, ("rules.nvim intent (exit %s): %s"):format(tostring(res.code), why)
    end
    return doc
  end
end

---The CLI of rules.nvim, found like a dependency of the repository.
---@param dir string
---@param opts? { cli?: string, getenv?: fun(name: string): string|nil }
---@return string|nil cli
---@return string|nil err
function M.locate_rules(dir, opts)
  opts = opts or {}
  if opts.cli then
    if vim.uv.fs_stat(opts.cli) then
      return opts.cli
    end
    return nil, "rules.nvim CLI not found: " .. opts.cli
  end
  local r, err = require("testing.deps").resolve(
    "rules.nvim",
    dir,
    { marker = "lua/rules", fallback = false, getenv = opts.getenv }
  )
  if not r then
    return nil, err
  end
  return r.dir .. "/scripts/rules.lua"
end

---The caller of the tasks engine for a vault (`--vault`, else `$TASKS_VAULT`).
---@param flags table
---@param getenv fun(name: string): string|nil
---@return Testing.SheetTasks.Call|nil
---@return string|nil err
function M.tasks_caller(flags, getenv)
  local vault = flags.vault or getenv("TASKS_VAULT")
  if not vault or vault == "" then
    return nil, "no task vault: pass --vault=<dir> or set TASKS_VAULT"
  end
  local tasks = require("testing.sheet.tasks")
  local cli, err = tasks.locate(vault, { cli = flags["tasks-cli"], getenv = getenv })
  if not cli then
    return nil, err
  end
  return tasks.caller(cli, vault)
end

M.USAGE = table.concat({
  "usage: testing act [--root=<dir>] --list [--json] [--vault=<dir>]",
  "       testing act [--root=<dir>] <fp> --do=task|rule|ai [--mode=form|ai-draft|agent] [--yes]",
  "                   [--vault=<dir>] [--tasks-cli=<tasks.lua>] [--rules-cli=<rules.lua>]",
  "                   [--family=<FAM>] [--severity=<s>] [--areas=<areas.json>] [--state-dir=<dir>]",
}, "\n")

local VALUE = {
  root = true,
  ["do"] = true,
  mode = true,
  vault = true,
  ["tasks-cli"] = true,
  ["rules-cli"] = true,
  family = true,
  severity = true,
  areas = true,
  ["state-dir"] = true,
}
local BOOL = { list = true, json = true, yes = true }

---@param argv string[]
---@return table|nil flags
---@return string[]|string positional_or_err
local function parse(argv)
  local flags, pos = {}, {}
  for _, a in ipairs(argv) do
    local name, value = a:match("^%-%-([%w-]+)=(.*)$")
    if name then
      if not VALUE[name] then
        return nil, ("unknown option --%s"):format(name)
      end
      flags[name] = value
    elseif a:match("^%-%-") then
      local b = a:sub(3)
      if not BOOL[b] then
        return nil, ("unknown option %s"):format(a)
      end
      flags[b] = true
    else
      pos[#pos + 1] = a
    end
  end
  return flags, pos
end

---`testing act ...`.
---@param argv string[] The arguments after `act`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string, getenv?: fun(name: string): string|nil, act?: Testing.Act.Engines }
---@return integer exit_code
function M.main(argv, sv)
  local flags, pos = parse(argv)
  if not flags then
    sv.err("testing act: " .. tostring(pos))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  ---@cast pos string[]
  if argv[1] == "--help" or argv[1] == "-h" then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  if (flags.list and #pos > 0) or (not flags.list and #pos ~= 1) then
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  local getenv = sv.getenv or vim.uv.os_getenv
  local dir = flags.root or "."
  if vim.fn.isdirectory(dir) ~= 1 then
    sv.err(("testing act: %s is not a directory"):format(dir))
    return M.EXIT_USAGE
  end
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("([^:/])/+$", "%1")
  local state_dir = flags["state-dir"] or sv.state_dir
  local docs, err, kind = M.findings(dir, { state_dir = state_dir, areas = flags.areas })
  if not docs then
    sv.err("testing act: " .. tostring(err))
    return kind == require("testing.finding").REFUSED and M.EXIT_USAGE or M.EXIT_INFRA
  end
  local engines = sv.act or {}

  if flags.list then
    local call, cerr = engines.tasks, nil
    if not call then
      call, cerr = M.tasks_caller(flags, getenv)
    end
    local links = {}
    if #docs > 0 and call then
      local l, lerr = M.links(docs, call)
      if l then
        links = l
      else
        cerr = lerr
      end
    end
    if cerr and #docs > 0 then
      sv.err("testing act: note: tasks unknown: " .. tostring(cerr))
    end
    for _, d in ipairs(docs) do
      if flags.json then
        local tasks = {}
        for _, t in ipairs(links[d.fp] or {}) do
          tasks[#tasks + 1] = { id = t.id, status = t.status }
        end
        sv.out(vim.json.encode({
          fp = d.fp,
          kind = d.kind,
          title = d.title,
          rule = d.rule,
          tasks = tasks,
        }))
      else
        sv.out(M.list_line(d, links[d.fp]))
      end
    end
    if #docs == 0 and not flags.json then
      sv.out("no findings in the last run")
    end
    return M.EXIT_OK
  end

  local doc, perr = M.pick(docs, pos[1])
  if not doc then
    sv.err("testing act: " .. tostring(perr))
    return M.EXIT_USAGE
  end
  local what = flags["do"]
  if not what then
    sv.err("testing act: --do=task|rule|ai is missing")
    return M.EXIT_USAGE
  end
  local intent, ierr = M.intent(doc, what, flags.mode)
  if not intent then
    sv.err("testing act: " .. tostring(ierr))
    return M.EXIT_USAGE
  end
  local yes = flags.yes == true
  local res, rerr
  if what == "task" then
    local call, cerr = engines.tasks, nil
    if not call then
      call, cerr = M.tasks_caller(flags, getenv)
    end
    if not call then
      sv.err("testing act: " .. tostring(cerr))
      return M.EXIT_INFRA
    end
    res, rerr = M.to_task(intent, yes, call)
  elseif what == "rule" then
    local run = engines.rules
    if not run then
      local cli, lerr = M.locate_rules(dir, { cli = flags["rules-cli"], getenv = getenv })
      if not cli then
        sv.err("testing act: " .. tostring(lerr))
        return M.EXIT_INFRA
      end
      run = M.rules_runner(cli)
    end
    res, rerr =
      M.to_rule(intent, { yes = yes, family = flags.family, severity = flags.severity }, run)
  else
    res, rerr = M.to_ai(intent, yes, M.handoff_file(dir, doc.fp, state_dir))
  end
  if not res then
    sv.err("testing act: " .. tostring(rerr))
    return M.EXIT_FAILED
  end
  sv.out(("%s  %s"):format(doc.fp, one_line(doc.title)))
  for line in res.text:gmatch("[^\n]+") do
    sv.out(line)
  end
  return M.EXIT_OK
end

return M
