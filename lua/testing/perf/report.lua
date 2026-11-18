---@module 'testing.perf.report'
---@brief The findings and the report of a `testing perf` run: Markdown for a person, JSON for the next run.
---@description
--- Findings (`M.THRESHOLDS`, a report, never a gate):
---
--- * `freeze`     a start that blocked the editor longer than `freeze_ms` (a synchronous call, a `wait()`);
--- * `burst`      more than `burst` starts of the plugin in one step (one user action);
--- * `memory`     a process whose working set peaked above `memory_mb`;
--- * `cpu`        a process that used more than `cpu_s` CPU seconds;
--- * `left`       a process the plugin started that still runs after the last step (an LSP server is named as such);
--- * `repeat`     the same command line again within `repeat_ms` in one sheet (a missing cache).
---
--- Starts of the sheet's own preparation (`plugin = "sheet"`, or a start in a `lua` step without any plugin frame) are
--- counted apart and never a finding. Coverage: the spawn sites of `testing.perf.scan` the run reached; the catalog's
--- functionalities without a sheet and those marked `perf = "user" | "manual:..." | "skip:..."`.

local M = {}

M.SCHEMA = "testing-perf/1"

M.THRESHOLDS = {
  freeze_ms = 50,
  burst = 5,
  memory_mb = 300,
  cpu_s = 10,
  repeat_ms = 2000,
}

---Names of language servers: a server that runs to the end is how it works, not a leftover.
M.LSP_NAMES = {
  "language%-server",
  "lua%-language%-server",
  "marksman",
  "rust%-analyzer",
  "clangd",
  "gopls",
  "pyright",
  "tsserver",
  "typescript%-language%-server",
  "vscode%-",
  "ltex",
  "harper",
}

---@param text string|nil
---@return boolean
function M.is_lsp(text)
  text = (text or ""):lower()
  for _, pat in ipairs(M.LSP_NAMES) do
    if text:find(pat) then
      return true
    end
  end
  return false
end

---The program of an argv text: the file name of its first word, without `.exe`.
---@param argv string
---@return string
function M.program(argv)
  local first = argv:match('^"([^"]+)"') or argv:match("^(%S+)") or "?"
  first = first:gsub("\\", "/"):match("([^/]+)$") or first
  return (first:gsub("%.[eE][xX][eE]$", ""))
end

---Whether a start belongs to the sheet's preparation, not to the plugin.
---@param sp Testing.Perf.Spawn
---@param steps Testing.Perf.Step[]
---@return boolean
function M.is_preparation(sp, steps)
  if sp.plugin == "sheet" then
    return true
  end
  if sp.plugin == "?" and type(sp.step) == "number" then
    for _, st in ipairs(steps) do
      if st.n == sp.step then
        return st.action == "lua" and not M.is_lsp(sp.argv)
      end
    end
  end
  return false
end

---How findings are ordered: what a user feels first.
M.ORDER = { freeze = 1, memory = 2, cpu = 3, left = 4, burst = 5, ["repeat"] = 6 }

---@class Testing.Perf.Finding
---@field kind string
---@field repo string
---@field sheet string
---@field feature? string
---@field step? integer|string
---@field program string
---@field argv string
---@field plugin string
---@field value number
---@field unit string
---@field text string
---@field place string `file:line` of the call (origin, else site)
---@field count integer how many starts the line stands for
---@field steps string[] the steps they happened in

---The findings of one sheet.
---@param repo string
---@param sh Testing.Perf.SheetRun
---@param t? table thresholds
---@return Testing.Perf.Finding[]
function M.findings(repo, sh, t)
  t = vim.tbl_extend("force", M.THRESHOLDS, t or {})
  local out = {}
  -- one finding per kind, program and place in the code: the same call in a loop is one line with a count
  local groups = {}
  local function add(kind, sp, value, unit, text)
    local place = sp.origin or sp.site or "?"
    local program = M.program(sp.argv or "")
    local key = table.concat({ kind, program, place, sp.plugin or "?" }, "\0")
    local g = groups[key]
    if not g then
      g = {
        kind = kind,
        repo = repo,
        sheet = sh.id,
        feature = sh.feature,
        step = sp.step,
        steps = {},
        program = program,
        argv = sp.argv or "",
        plugin = sp.plugin or "?",
        place = place,
        value = value,
        unit = unit,
        text = text,
        count = 0,
      }
      groups[key] = g
      out[#out + 1] = g
    end
    g.count = g.count + 1
    -- the worst of the group: the largest value, for `repeat` the shortest gap
    local worse = kind == "repeat" and (value or 0) < (g.value or 0)
      or (value or 0) > (g.value or 0)
    if worse then
      g.value, g.text, g.argv, g.step = value, text, sp.argv or "", sp.step
    end
    g.steps[tostring(sp.step)] = true
  end
  local per_step = {}
  local last_seen = {}
  for _, sp in ipairs(sh.spawns or {}) do
    if not M.is_preparation(sp, sh.steps or {}) then
      if sp.blocked_ms and sp.blocked_ms > t.freeze_ms then
        add(
          "freeze",
          sp,
          math.floor(sp.blocked_ms),
          "ms",
          ("blocked the editor %d ms"):format(sp.blocked_ms)
        )
      end
      if sp.peak and sp.peak > t.memory_mb * 1e6 then
        add(
          "memory",
          sp,
          math.floor(sp.peak / 1e6),
          "MB",
          ("working set peaked at %d MB"):format(sp.peak / 1e6)
        )
      end
      if sp.cpu and sp.cpu > t.cpu_s then
        add("cpu", sp, math.floor(sp.cpu * 10) / 10, "s", ("%.1f s CPU"):format(sp.cpu))
      end
      if sp.alive_at_end then
        local lsp = M.is_lsp(sp.argv)
        if not lsp then
          add("left", sp, 1, "", "still runs after the last step")
        end
      end
      if type(sp.step) == "number" then
        local key = sp.step .. "\0" .. (sp.plugin or "?")
        per_step[key] = per_step[key] or { n = 0, sp = sp }
        per_step[key].n = per_step[key].n + 1
      end
      local prev = last_seen[sp.argv]
      if prev and sp.us and prev.us and (sp.us - prev.us) / 1000 < t.repeat_ms then
        add(
          "repeat",
          sp,
          math.floor((sp.us - prev.us) / 1000),
          "ms",
          ("same command again after %d ms"):format((sp.us - prev.us) / 1000)
        )
      end
      last_seen[sp.argv] = sp
    end
  end
  for _, e in pairs(per_step) do
    if e.n > t.burst then
      add("burst", e.sp, e.n, "starts", ("%d starts in one step"):format(e.n))
    end
  end
  for _, g in ipairs(out) do
    local steps = vim.tbl_keys(g.steps)
    table.sort(steps)
    g.steps = steps
  end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then
      return (M.ORDER[a.kind] or 99) < (M.ORDER[b.kind] or 99)
    end
    if a.kind == "repeat" then
      return (a.count or 0) > (b.count or 0)
    end
    return (a.value or 0) > (b.value or 0)
  end)
  return out
end

---Per program of a repository: starts, synchronous ones, blocked ms, the longest run, peak, CPU, plugins, features.
---@param sheets Testing.Perf.SheetRun[]
---@return table[]
function M.programs(sheets)
  local by = {}
  for _, sh in ipairs(sheets) do
    for _, sp in ipairs(sh.spawns or {}) do
      local prep = M.is_preparation(sp, sh.steps or {})
      local name = M.program(sp.argv or "") .. (prep and " (sheet)" or "")
      local e = by[name]
      if not e then
        e = {
          program = name,
          starts = 0,
          sync = 0,
          blocked_ms = 0,
          max_ms = 0,
          peak = 0,
          cpu = 0,
          plugins = {},
          features = {},
          preparation = prep,
        }
        by[name] = e
      end
      e.starts = e.starts + 1
      if sp.sync then
        e.sync = e.sync + 1
      end
      e.blocked_ms = e.blocked_ms + (sp.blocked_ms or 0)
      e.max_ms = math.max(e.max_ms, sp.ms or 0)
      e.peak = math.max(e.peak, sp.peak or 0)
      e.cpu = math.max(e.cpu, sp.cpu or 0)
      e.plugins[sp.plugin or "?"] = true
      if sh.feature then
        e.features[sh.feature] = true
      end
    end
  end
  local out = vim.tbl_values(by)
  table.sort(out, function(a, b)
    if a.preparation ~= b.preparation then
      return not a.preparation
    end
    if a.blocked_ms ~= b.blocked_ms then
      return a.blocked_ms > b.blocked_ms
    end
    return a.starts > b.starts
  end)
  return out
end

---The catalog side of a repository: functionalities without a sheet, and those marked with `perf`.
---@param rr Testing.Perf.RootRun
---@return { without_sheet: Testing.Sheet.Feature[], marked: Testing.Sheet.Feature[], total: integer }
function M.catalog_gaps(rr)
  local have = {}
  for _, sh in ipairs(rr.sheets or {}) do
    if sh.feature then
      have[sh.feature] = true
    end
  end
  local without, marked = {}, {}
  for _, f in ipairs(rr.catalog or {}) do
    if f.perf then
      marked[#marked + 1] = f
    elseif not have[f.id] then
      without[#without + 1] = f
    end
  end
  return { without_sheet = without, marked = marked, total = #(rr.catalog or {}) }
end

---Summary numbers of a repository (also what a baseline compares).
---@param rr Testing.Perf.RootRun
---@param t? table
---@return table
function M.summary(rr, t)
  local s = {
    repo = rr.repo,
    sheets = #rr.sheets,
    pass = 0,
    fail = 0,
    skip = 0,
    other = 0,
    starts = 0,
    preparation = 0,
    blocked_ms = 0,
    peak = 0,
    findings = 0,
    sites = #(rr.sites or {}),
    covered = #((rr.coverage or {}).covered or {}),
  }
  for _, sh in ipairs(rr.sheets) do
    if sh.status == "pass" or sh.status == "fail" or sh.status == "skip" then
      s[sh.status] = s[sh.status] + 1
    else
      s.other = s.other + 1
    end
    for _, sp in ipairs(sh.spawns or {}) do
      if M.is_preparation(sp, sh.steps or {}) then
        s.preparation = s.preparation + 1
      else
        s.starts = s.starts + 1
        s.blocked_ms = s.blocked_ms + (sp.blocked_ms or 0)
        s.peak = math.max(s.peak, sp.peak or 0)
      end
    end
    s.findings = s.findings + #M.findings(rr.repo, sh, t)
  end
  s.blocked_ms = math.floor(s.blocked_ms)
  return s
end

---The JSON document of a run (no samples, no trace lines: what the next run compares and a reader needs).
---@param run { started: string, machine: table, real?: string[], interval_ms: integer, roots: Testing.Perf.RootRun[] }
---@param t? table
---@return table
function M.document(run, t)
  local repos = {}
  for _, rr in ipairs(run.roots) do
    local sheets = {}
    for _, sh in ipairs(rr.sheets) do
      sheets[#sheets + 1] = {
        id = sh.id,
        feature = sh.feature,
        status = sh.status,
        ms = sh.ms,
        failures = sh.failures,
        skipped = sh.skipped,
        real = sh.real,
        -- what a start's step was (a `lua` step of the sheet prepares, it is no feature's load)
        steps = vim.tbl_map(function(st)
          return { n = st.n, action = st.action, ms = st.ms }
        end, sh.steps or {}),
        spawns = sh.spawns,
        findings = M.findings(rr.repo, sh, t),
      }
    end
    local gaps = M.catalog_gaps(rr)
    repos[#repos + 1] = {
      repo = rr.repo,
      root = rr.root,
      refused = rr.refused,
      summary = M.summary(rr, t),
      sheets = sheets,
      unloadable = rr.unloadable,
      missing_sites = (rr.coverage or {}).missing,
      catalog = {
        total = gaps.total,
        error = rr.catalog_error,
        without_sheet = vim.tbl_map(function(f)
          return f.id
        end, gaps.without_sheet),
        marked = vim.tbl_map(function(f)
          return { id = f.id, perf = f.perf }
        end, gaps.marked),
      },
    }
  end
  return {
    schema = M.SCHEMA,
    started = run.started,
    machine = run.machine,
    real = run.real,
    interval_ms = run.interval_ms,
    thresholds = vim.tbl_extend("force", M.THRESHOLDS, t or {}),
    repos = repos,
  }
end

local function cell(s)
  return (tostring(s or ""):gsub("|", "\\|"):gsub("[\r\n]", " "))
end

local function mb(bytes)
  if not bytes or bytes == 0 then
    return "–"
  end
  return ("%d"):format(math.floor(bytes / 1e6 + 0.5))
end

local function keys(t)
  local out = vim.tbl_keys(t or {})
  table.sort(out)
  return table.concat(out, ", ")
end

---Compare with an earlier document: per repository the change of starts, blocked ms, peak and coverage.
---@param doc table
---@param base table
---@return string[] lines
function M.compare(doc, base)
  local before = {}
  for _, r in ipairs(base.repos or {}) do
    before[r.repo] = r.summary
  end
  local lines = {
    ("Vergleich mit dem Lauf vom %s:"):format(tostring(base.started or "?")),
    "",
    "| Repo | Starts | blockiert ms | Spitze MB | erreichte Stellen |",
    "|---|---|---|---|---|",
  }
  local function delta(a, b)
    if b == nil then
      return tostring(a)
    end
    local d = a - b
    return ("%s (%s%s)"):format(a, d >= 0 and "+" or "", d)
  end
  for _, r in ipairs(doc.repos) do
    local s, b = r.summary, before[r.repo]
    lines[#lines + 1] = ("| %s | %s | %s | %s | %s |"):format(
      cell(r.repo),
      delta(s.starts, b and b.starts),
      delta(s.blocked_ms, b and b.blocked_ms),
      delta(math.floor(s.peak / 1e6), b and math.floor((b.peak or 0) / 1e6)),
      delta(s.covered, b and b.covered) .. "/" .. s.sites
    )
  end
  return lines
end

---The Markdown report.
---@param doc table `M.document`
---@param base? table an earlier document
---@return string
function M.markdown(doc, base)
  local L = {}
  local function add(s)
    L[#L + 1] = s or ""
  end
  local t = doc.thresholds
  add(("# Performance-Lauf %s"):format(doc.started))
  add()
  add(
    ("Maschine: %s (%s), Abtastung %d ms, echt geschaltet: %s. Auffällig: Freeze > %d ms, > %d Starts je Schritt, > %d MB, > %d s CPU, läuft nach dem letzten Schritt, gleiche Zeile binnen %d ms."):format(
      cell(doc.machine.host),
      cell(doc.machine.os),
      doc.interval_ms,
      doc.real and #doc.real > 0 and table.concat(doc.real, ", ")
        or "nichts (Fakes und Stubs bleiben)",
      t.freeze_ms,
      t.burst,
      t.memory_mb,
      t.cpu_s,
      t.repeat_ms
    )
  )
  add()
  add("## Übersicht")
  add()
  add(
    "| Repo | Sheets (ok/rot/skip/sonst) | Starts (Plugin) | Sheet-Vorbereitung | blockiert ms | Spitze MB | Stellen erreicht | Katalog: ohne Sheet / markiert | Auffällig |"
  )
  add("|---|---|---|---|---|---|---|---|---|")
  local all_findings = {}
  for _, r in ipairs(doc.repos) do
    local s = r.summary
    local cat = r.catalog.error and "Fehler"
      or (r.catalog.total == 0 and "kein Katalog")
      or ("%d / %d von %d"):format(#r.catalog.without_sheet, #r.catalog.marked, r.catalog.total)
    add(
      ("| %s | %d (%d/%d/%d/%d) | %d | %d | %d | %s | %d/%d | %s | %d |"):format(
        cell(r.repo),
        s.sheets,
        s.pass,
        s.fail,
        s.skip,
        s.other,
        s.starts,
        s.preparation,
        s.blocked_ms,
        mb(s.peak),
        s.covered,
        s.sites,
        cat,
        s.findings
      )
    )
    for _, sh in ipairs(r.sheets) do
      vim.list_extend(all_findings, sh.findings)
    end
  end
  add()
  add("## Auffälligkeiten")
  add()
  if #all_findings == 0 then
    add("Keine.")
  else
    add(
      "| Art | Repo | Sheet / Feature | Schritte | Programm | Wert (max) | Anzahl | Aufrufstelle | Zeile |"
    )
    add("|---|---|---|---|---|---|---|---|---|")
    for _, f in ipairs(all_findings) do
      local place = tostring(f.place or "?"):gsub("^.*/([^/]+/[^/]+/[^/]+)$", "%1")
      add(
        ("| %s | %s | %s | %s | %s | %s %s | %d | `%s` | `%s` |"):format(
          f.kind,
          cell(f.repo),
          cell(f.sheet .. (f.feature and f.feature ~= f.sheet and (" / " .. f.feature) or "")),
          cell(table.concat(f.steps or { tostring(f.step) }, ",")),
          cell(f.program),
          tostring(f.value),
          f.unit,
          f.count or 1,
          cell(place),
          cell(f.argv:sub(1, 90))
        )
      )
    end
  end
  if base then
    add()
    add("## Vergleich")
    add()
    for _, line in ipairs(M.compare(doc, base)) do
      add(line)
    end
  end
  for _, r in ipairs(doc.repos) do
    add()
    add("## " .. r.repo)
    add()
    if r.refused then
      add("Nicht gelaufen: " .. r.refused)
    else
      add("| Sheet | Feature | Status | ms | Starts | Hinweis |")
      add("|---|---|---|---|---|---|")
      for _, sh in ipairs(r.sheets) do
        local note = sh.failures and sh.failures[1] or sh.skipped or ""
        if sh.real then
          note = ("echt: %s. %s"):format(table.concat(sh.real, ", "), note)
        end
        add(
          ("| %s | %s | %s | %s | %d | %s |"):format(
            cell(sh.id),
            cell(sh.feature or "–"),
            sh.status,
            tostring(sh.ms or "–"),
            #(sh.spawns or {}),
            cell(note:sub(1, 160))
          )
        )
      end
      for _, u in ipairs(r.unloadable or {}) do
        add(
          ("| %s | – | lädt nicht | – | – | %s |"):format(
            cell(u.rel),
            cell(u.error:sub(1, 160))
          )
        )
      end
      local progs = M.programs(r.sheets)
      if #progs > 0 then
        add()
        add(
          "| Programm | Starts | davon sync | blockiert ms | längster ms | Spitze MB | CPU s | Plugins | Features |"
        )
        add("|---|---|---|---|---|---|---|---|---|")
        for _, p in ipairs(progs) do
          add(
            ("| %s | %d | %d | %d | %d | %s | %.1f | %s | %s |"):format(
              cell(p.program),
              p.starts,
              p.sync,
              math.floor(p.blocked_ms),
              math.floor(p.max_ms),
              mb(p.peak),
              p.cpu,
              cell(keys(p.plugins)),
              cell(keys(p.features))
            )
          )
        end
      end
      local missing = r.missing_sites or {}
      if #missing > 0 then
        add()
        add(("Nicht erreichte Startstellen (%d):"):format(#missing))
        add()
        for i, site in ipairs(missing) do
          if i > 40 then
            add(("- … und %d weitere (JSON)"):format(#missing - 40))
            break
          end
          add(("- `%s:%d` %s"):format(site.file, site.line, site.what))
        end
      end
      if #r.catalog.without_sheet > 0 then
        add()
        add("Katalog-Features ohne Sheet: " .. table.concat(r.catalog.without_sheet, ", "))
      end
      if #r.catalog.marked > 0 then
        add()
        add("Markiert (`perf`):")
        add()
        for _, m in ipairs(r.catalog.marked) do
          add(("- %s: %s"):format(m.id, m.perf))
        end
      end
    end
  end
  add()
  return table.concat(L, "\n")
end

return M
