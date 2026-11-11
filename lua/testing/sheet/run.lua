---@module 'testing.sheet.run'
-- @cache-env NVIM_MACHINE_ROLE TESTING_ALLOW_WORKSTATION REPOS_DIR
---@brief `testing sheets run --task <id>`: run the test sheets of one task now and write the result into it.
---@description
--- The way from a live-check task to its result without running a whole suite: the sheets of the given roots
--- that name the task (`task = "<area/slug>"`, a sheet that does not load too) run here, one child editor each,
--- and with `--tasks <vault>` their state goes into the task's block as `testing sheets report --tasks` writes
--- it (`testing.sheet.tasks.sync`). tasks.nvim's `:Tasks sheet-run` calls this command; the two plugins meet
--- only on the command line and the block.
---
--- * The roots are `--root <dir>` (repeatable), else the task's area as a repository: `$REPOS_DIR/<area>`,
---   else `<vault>/../<area>`; with `--tasks` also the projects the task's block names (it is written whole).
--- * Each root passes the workspace trust gate (`testing.trust`) first: a sheet runs the project's minimal init.
--- * A missing snapshot is a failure, as on CI (`ci = true`): a run from a task never writes a reference image.
--- * On the workstation (`NVIM_MACHINE_ROLE=workstation`) only manual sheets run (`engine = "manual"`: questions, no
---   process), decided after every sheet of the run is loaded as data; any other sheet, or one that does not load,
---   refuses the whole run, unless `TESTING_ALLOW_WORKSTATION=1`. Another value than `workstation` / `default` is
---   refused as a typo.
--- * A red sheet carries its first failure line into the block (`red: <line>`).

local M = {}

M.USAGE = "usage: testing sheets run --task <area/slug> [--root <dir>]... [--tasks <vault> [--tasks-cli <tasks.lua>] [--dry-run]]\n"
  .. "       testing sheets run --all [--root <dir>]... [--engine <name>] [--json <ir>] [--strict]\n"
  .. "       testing sheets run --sheet <id>... [--root <dir>]... [--json <ir>] [--strict]"

---@class Testing.SheetRun.Deps
---@field call? Testing.SheetTasks.Call A stand-in for the engine of tasks.nvim (specs).
---@field getenv? fun(name: string): string|nil
---@field run? fun(s: Testing.Sheet, opts: table): Testing.Sheet.Result A stand-in for `testing.sheet.run` (specs).
---@field trust_check? fun(root: string): string|nil A stand-in for `testing.trust.check` (specs).
---@field on_ran? fun(entries: Testing.SheetReport.Entry[]) Called with the task's sheets after they ran (`e.result`).
---@field no_write? boolean Run only, never write the task (`testing sheets prompt explain`).

---The first line of the first failure: what the block shows of a red run.
---@param res Testing.Sheet.Result
---@return string
function M.first_failure(res)
  local first = res.failures and res.failures[1]
  if not first then
    return res.status or "fail"
  end
  return (tostring(first):match("^[^\r\n]*"))
end

---@param area string
---@param vault string|nil
---@param getenv fun(name: string): string|nil
---@return string|nil root, string|nil tried
function M.area_root(area, vault, getenv)
  local tried, bases = {}, {}
  local repos = getenv("REPOS_DIR")
  if repos and repos ~= "" then
    bases[#bases + 1] = repos
  end
  if vault then
    bases[#bases + 1] = vim.fs.dirname(vault)
  end
  for _, base in ipairs(bases) do
    local dir = vim.fs.normalize(base .. "/" .. area)
    tried[#tried + 1] = dir
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil, table.concat(tried, ", ")
end

---Which name of `wanted` picks the entry: its id, else its file name without `.sheet.lua` (a sheet that does not load
---has only that). Nil when none does.
---@param e Testing.SheetReport.Entry
---@param wanted table<string, true>
---@return string|nil
function M.picked(e, wanted)
  if e.sheet and wanted[e.sheet.id] then
    return e.sheet.id
  end
  local base = vim.fs.basename(tostring(e.rel)):gsub("%.sheet%.lua$", "")
  if wanted[base] then
    return base
  end
  return nil
end

---Whether every entry is a sheet that starts nothing: loaded (as data) and `engine = "manual"`. False for none.
---@param entries { sheet?: Testing.Sheet }[]
---@return boolean
function M.only_manual(entries)
  if #entries == 0 then
    return false
  end
  for i = 1, #entries do
    local s = entries[i] and entries[i].sheet
    -- a sheet that does not load has no engine anyone could trust
    if type(s) ~= "table" or s.engine ~= "manual" then
      return false
    end
  end
  return true
end

---Why sheets must not run on this machine: a role that is a typo, or the workstation. Nil when they may.
---
---On the workstation (`NVIM_MACHINE_ROLE=workstation`, unless `TESTING_ALLOW_WORKSTATION=1`) only manual sheets may:
---they start nothing, a person answers their questions. `entries` are the sheets that would run, loaded as data
---before this is asked (`{ sheet = s }`, a sheet that does not load as `{}`); without them the workstation is refused.
---A command that cannot know its sheets yet asks `manual_only_here` first and this once they are loaded.
---@param getenv fun(name: string): string|nil
---@param entries? { sheet?: Testing.Sheet }[]
---@return string|nil
function M.refused(getenv, entries)
  -- trimmed: `set NVIM_MACHINE_ROLE=workstation ` in cmd keeps the blank (the nvim config's machine.lua trims too)
  local role = vim.trim(getenv("NVIM_MACHINE_ROLE") or ""):lower()
  if role ~= "" and role ~= "default" and role ~= "workstation" then
    return ("testing sheets: NVIM_MACHINE_ROLE=%q is neither workstation nor default (a typo?): refused until it is set right"):format(
      role
    )
  end
  if role == "workstation" and getenv("TESTING_ALLOW_WORKSTATION") ~= "1" then
    if entries and M.only_manual(entries) then
      return nil
    end
    return "testing sheets: refused on the workstation (NVIM_MACHINE_ROLE=workstation): a sheet starts editors and runs "
      .. 'the project\'s code; only manual sheets (engine = "manual", questions only) run here; set '
      .. "TESTING_ALLOW_WORKSTATION=1 where the others are allowed"
  end
  return nil
end

---Whether the machine is the workstation without the permission for the other sheets: the decision then waits until
---the sheets are loaded (`refused(getenv, entries)`).
---@param getenv fun(name: string): string|nil
---@return boolean
function M.manual_only_here(getenv)
  return vim.trim(getenv("NVIM_MACHINE_ROLE") or ""):lower() == "workstation"
    and getenv("TESTING_ALLOW_WORKSTATION") ~= "1"
end

---The result of the run as a Result-IR, the input of `testing sheets report --from`: a repository without a Lua spec
---gets its checklist and its task block this way. A sheet that does not load is a failed case of its file.
---@param path string
---@param entries Testing.SheetReport.Entry[]
---@param root string
---@return string|nil err
function M.write_ir(path, entries, root)
  local R = require("testing.core.result")
  local result = R.new({ project_key = vim.fs.basename(root), nvim = "sheets run" })
  local sheet = require("testing.sheet")
  for _, e in ipairs(entries) do
    local name = e.sheet and sheet.spec_name(e.sheet)
      or ("sheet:" .. vim.fs.basename(tostring(e.rel)))
    local case = R.new_case({ file = e.case and e.case.file or tostring(e.rel), name = name })
    local status = e.case and e.case.status or "fail"
    local message = e.case and e.case.message
      or (not e.sheet and ("does not load: " .. tostring(e.error)) or nil)
    case.status = status
    case.duration_ms = e.case and e.case.duration_ms or 0
    if status == "fail" then
      case.assertions[1] = { ok = false, kind = "sheet", msg = message or "failed" }
    else
      case.assertions[1] = { ok = true, kind = "sheet" }
      if status == "skip" then
        case.notes[1] = message
      end
    end
    R.add_case(result, case)
  end
  R.finalize(result)
  -- paths as placeholders, as in the IR of a run: this file may land in a CI artifact
  local text, eerr = R.encode(result, {
    roots = require("testing.run.inproc").path_roots(root),
    case_insensitive = require("testing.child").platform.windows == true,
  })
  if not text then
    return tostring(eerr)
  end
  local f = io.open(path, "wb")
  if not f then
    return "cannot write " .. path
  end
  f:write(text)
  f:close()
  return nil
end

---`testing sheets run`: exit 0 every sheet green (or waiting for a person) and the task written, 1 a sheet is
---red or the task could not be written, 2 bad usage, refused (trust, workstation) or no sheet names the task, 3
---the engine of tasks.nvim could not be reached.
---@param argv string[] The arguments after `run`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetRun.Deps
---@return integer
function M.main(argv, sv, deps)
  deps = deps or {}
  local getenv = deps.getenv or vim.uv.os_getenv
  ---@type table<string, any>
  local o = { dry_run = false, all = false, strict = false }
  local roots = {}
  -- `--sheet <id>` (repeatable): these sheets of the roots, by id or file name, as `--all` runs them
  local wanted, wanted_list = {}, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--dry-run" or a == "--all" or a == "--strict" then
      o[a:sub(3):gsub("-", "_")] = true
      i = i + 1
    else
      local key = ({
        ["--task"] = "id",
        ["--root"] = "root",
        ["--tasks"] = "vault",
        ["--tasks-cli"] = "cli",
        ["--json"] = "json",
        ["--engine"] = "engine",
        ["--sheet"] = "sheet",
      })[a]
      if not key or not argv[i + 1] then
        sv.err(
          (
            key and ("testing sheets: " .. a .. " needs a value")
            or ("testing sheets: unknown argument " .. tostring(a))
          )
            .. "\n"
            .. M.USAGE
        )
        return 2
      end
      if key == "root" then
        roots[#roots + 1] = argv[i + 1]
      elseif key == "sheet" then
        if not wanted[argv[i + 1]] then
          wanted[argv[i + 1]] = true
          wanted_list[#wanted_list + 1] = argv[i + 1]
        end
      else
        o[key] = argv[i + 1]
      end
      i = i + 2
    end
  end
  if #wanted_list > 0 then
    if o.id or o.vault then
      sv.err(
        "testing sheets: --sheet picks sheets of the roots, without a task (the block is written whole)\n"
          .. M.USAGE
      )
      return 2
    end
    o.all = true
  end
  if o.all and (o.id or o.vault) then
    sv.err("testing sheets: --all runs every sheet of the roots, without a task\n" .. M.USAGE)
    return 2
  end
  if o.engine and not o.all then
    sv.err("testing sheets: --engine belongs to --all\n" .. M.USAGE)
    return 2
  end
  if o.all and #roots == 0 then
    roots = { "." }
  end
  if not o.all and not o.id or (o.id and not o.id:match("^[%w_][%w_.%-]*/[%w_.%-]+$")) then
    sv.err("testing sheets: --task <area/slug> is required\n" .. M.USAGE)
    return 2
  end
  if (o.cli or o.dry_run) and not o.vault then
    sv.err("testing sheets: --tasks-cli and --dry-run belong to --tasks <vault>\n" .. M.USAGE)
    return 2
  end
  -- the workstation decides once the sheets are loaded as data (only manual ones run there); a typo stops here
  if not M.manual_only_here(getenv) then
    local refused = M.refused(getenv)
    if refused then
      sv.err(refused)
      return 2
    end
  end
  local vault = o.vault and vim.fs.normalize(vim.fn.fnamemodify(o.vault, ":p")):gsub("/+$", "")
    or nil
  local tasks = require("testing.sheet.tasks")
  -- the engine first: nothing runs when the result could not be written, and the task's block names the
  -- projects its sheets live in
  local call = deps.call
  if vault and not call then
    local cli, lerr = tasks.locate(vault, { cli = o.cli })
    if not cli then
      sv.err("testing sheets: " .. tostring(lerr))
      return 3
    end
    call = tasks.caller(cli, vault)
  end
  if #roots == 0 then
    local r, tried = M.area_root(o.id:match("^[^/]+"), vault, getenv)
    if not r then
      sv.err(
        "testing sheets: no repository for the area of "
          .. o.id
          .. " (tried "
          .. tostring(tried)
          .. "); pass --root"
      )
      return 2
    end
    roots = { r }
  end
  for k, r in ipairs(roots) do
    if vim.fn.isdirectory(r) ~= 1 then
      sv.err("testing sheets: --root " .. r .. " is not a directory")
      return 2
    end
    roots[k] = vim.fs.normalize(vim.fn.fnamemodify(r, ":p")):gsub("/+$", "")
  end
  -- the block is written whole: a sheet of the task in another project must run too, or it drops out of it
  if vault then
    local have = {}
    for _, r in ipairs(roots) do
      have[vim.fs.basename(r)] = true
    end
    ---@cast call -?
    local doc = call("bodies", { ids = { o.id } })
    local item = type(doc) == "table" and type(doc.items) == "table" and doc.items[1] or nil
    local block = item
      and type(item.body) == "string"
      and tasks.extract((item.body:gsub("\r\n?", "\n")))
    for project in (block or ""):gmatch("`([%w_.%-]+)/TESTS/sheets/[^`\n]-%.sheet%.lua`") do
      if not have[project] then
        local r = M.area_root(project, vault, getenv)
        if not r then
          sv.err(
            (
              "testing sheets: the block of %s names sheets of %s, which is not found: pass --root <dir> for it, "
              .. "or its sheets would drop out of the block"
            ):format(o.id, project)
          )
          return 2
        end
        have[project] = true
        roots[#roots + 1] = r
      end
    end
  end
  local trust_check = deps.trust_check or require("testing.trust").check
  for _, r in ipairs(roots) do
    local refusal = trust_check(r)
    if refusal then
      sv.err("testing sheets: " .. refusal)
      return 2
    end
  end

  local report = require("testing.sheet.report")
  local mine, found = {}, {}
  for _, e in ipairs(report.collect(roots, { cases = {} })) do
    local id = e.sheet and e.sheet.task or (not e.sheet and tasks.task_of_unloadable(e))
    -- a sheet that does not load has no engine and stays in: it is red in every job
    local engine_fits = not o.engine or not e.sheet or e.sheet.engine == o.engine
    local picked = M.picked(e, wanted)
    if picked then
      found[picked] = true
    end
    if (o.all and engine_fits and (#wanted_list == 0 or picked)) or id == o.id then
      mine[#mine + 1] = e
    end
  end
  for _, name in ipairs(wanted_list) do
    if not found[name] then
      sv.err(
        ("testing sheets: no sheet %s (id or file name) in %s"):format(
          name,
          table.concat(roots, ", ")
        )
      )
      return 2
    end
  end
  if #mine == 0 then
    sv.err(
      o.all and ("testing sheets: no sheet in %s"):format(table.concat(roots, ", "))
        or ("testing sheets: no sheet in %s names the task %s"):format(
          table.concat(roots, ", "),
          o.id
        )
    )
    return 2
  end

  -- before anything runs: on the workstation every sheet of the run must be a manual one
  local refused = M.refused(getenv, mine)
  if refused then
    sv.err(refused)
    return 2
  end

  local run = deps.run or require("testing.sheet").run
  local sheet = require("testing.sheet")
  local red, skipped = false, false
  for _, e in ipairs(mine) do
    if not e.sheet then
      red = true
      sv.out(("sheet %s: does not load: %s"):format(e.rel, (tostring(e.error):match("^[^\r\n]*"))))
    else
      local started = vim.uv.hrtime()
      local res = run(e.sheet, { root = e.root, ci = true })
      e.result = res
      -- a skip (a browser sheet without node, Playwright or chromium) is no green result: the report lists it
      -- under "not run" with its reason, and it does not make the run red
      local status = res.status == "fail" and "fail" or res.status == "skip" and "skip" or "pass"
      e.case = {
        name = sheet.spec_name(e.sheet),
        status = status,
        file = "TESTS/sheets_spec.lua",
        message = status == "fail" and M.first_failure(res) or status == "skip" and tostring(
          res.skipped
        ) or nil,
        duration_ms = math.floor((vim.uv.hrtime() - started) / 1e6),
      }
      red = red or status == "fail"
      skipped = skipped or status == "skip"
      sv.out(
        ("sheet %s: %s%s"):format(
          e.sheet.id,
          res.status,
          status == "fail" and (": " .. e.case.message) or ""
        )
      )
    end
  end

  if deps.on_ran then
    deps.on_ran(mine)
  end
  if o.json then
    local werr = M.write_ir(o.json, mine, roots[1])
    if werr then
      sv.err("testing sheets: " .. werr)
      return 3
    end
  end
  -- a job that exists to prove something must not stay green because the browser is missing
  red = red or (o.strict and skipped)
  if not o.vault or deps.no_write then
    return red and 1 or 0
  end
  ---@cast call -?
  local results, serr = tasks.sync(mine, { call = call, dry_run = o.dry_run })
  if not results then
    sv.err("testing sheets: " .. tostring(serr))
    return 3
  end
  local failed = false
  for _, r in ipairs(results) do
    sv.out(
      ("testing sheets: task %s %s%s"):format(
        r.id,
        r.outcome,
        r.message and (": " .. r.message) or ""
      )
    )
    failed = failed
      or not (r.outcome == "changed" or r.outcome == "unchanged" or r.outcome == "would_change")
  end
  return (red or failed) and 1 or 0
end

return M
