---@module 'testing.finding'
---@brief The document `testing-finding/1`: one finding (a red case, a flake, a guard, a red CI run, a lint finding, a sheet) in a redacted, stable form.
---@description
--- Only the engine builds findings, never a UI. A finding is what the three actions (a task, a rule, the AI) need
--- together; `testing-handoff/1` holds findings plus context, so there is one format.
---
--- * `fp` is 16 hex of `sha256(kind, repo, identity)`: the identity is the case id, the check id or workflow+job, never
---   the commit or a line number, so the same failure after a commit that only moves lines is the same finding.
--- * The text is redacted as the export redacts it (absolute paths, the home directory, secrets), bounded to 4 KiB at a
---   UTF-8 boundary. No `root`.
--- * `class` and `area` come from the data classes of this device (`lib.nvim.data_classes`, fail-closed): a repository
---   that is `private` or `unclassified` gives no finding (`nil, reason, REFUSED`; exit 2 of `testing call finding`).
---
--- `M.build` makes a document from a source record of any kind (the guard findings of a run, a lint report and a sheet
--- are built by their callers); `M.collect` reads the findings of a repository from its state: the red and flaky
--- cases of `last.json` and the red pipeline of `ci.json`. Reads only, runs nothing.

local M = {}

M.SCHEMA = "testing-finding/1"

M.KINDS = { case = true, flaky = true, guard = true, ["ci-run"] = true, lint = true, sheet = true }

---The bytes of the excerpt and of the pieces around it.
M.EXCERPT_MAX = 4096
M.TITLE_MAX = 120
M.REPRO_MAX = 300

---The kind of error of a finding the data classes of this device do not release.
M.REFUSED = "refused"

---@class Testing.Finding.Source
---@field kind "case"|"flaky"|"guard"|"ci-run"|"lint"|"sheet"
---@field identity string The stable identity: case id, check id, workflow and job.
---@field title string
---@field excerpt? string
---@field where? { file: string, line?: integer }
---@field run? { source: "local"|"ci", id?: string, os?: string, url?: string }
---@field sha? string 40 hex
---@field repro? string A command, repository-relative.
---@field rule? string

---@class Testing.Finding.Ctx
---@field dir string The repository.
---@field state_dir? string
---@field classes? table The options of `lib.nvim.data_classes.load` (specs name their own file).
---@field classified? { class: string, area: string|nil } Filled by the first `M.build` of this context.

---The fingerprint: stable over commits and moved lines.
---@param kind string
---@param repo string The directory name.
---@param identity string
---@return string fp 16 hex
function M.fingerprint(kind, repo, identity)
  return vim.fn.sha256(table.concat({ kind, repo, identity }, "\n")):sub(1, 16)
end

---@param s any
---@param ctx Testing.Finding.Ctx
---@param max integer
---@param keep_newlines? boolean
---@return string|nil
local function clean(s, ctx, max, keep_newlines)
  return require("testing.export").clean(s, ctx.dir, ctx.state_dir, max, keep_newlines)
end

---The class and area of a repository on this device; `unclassified` and no area where nothing says otherwise.
---@param ctx Testing.Finding.Ctx
---@return string class
---@return string|nil area
local function classify(ctx)
  -- once per context: a repository with many findings reads `areas.json` once, not once per finding
  if ctx.classified then
    return ctx.classified.class, ctx.classified.area
  end
  local class, area = M.classify_uncached(ctx)
  ctx.classified = { class = class, area = area }
  return class, area
end

---@param ctx Testing.Finding.Ctx
---@return string class
---@return string|nil area
function M.classify_uncached(ctx)
  local okl, dc = pcall(require, "lib.nvim.data_classes")
  if not okl then
    return "unclassified", nil
  end
  local classes = dc.load(ctx.classes or {})
  if classes.problem then
    return "unclassified", nil
  end
  local class, matches = classes:class_of_repo(ctx.dir)
  local area = matches and matches[1] and matches[1].area or nil
  return class, area
end

---The document of one finding.
---@param src Testing.Finding.Source
---@param ctx Testing.Finding.Ctx
---@return table|nil doc
---@return string|nil err
---@return string|nil kind `M.REFUSED` when the data classes do not release the repository.
function M.build(src, ctx)
  if not M.KINDS[src.kind] then
    return nil, ("unknown kind %s"):format(tostring(src.kind))
  end
  if type(src.identity) ~= "string" or src.identity == "" then
    return nil, "a finding needs a stable identity"
  end
  local class, area = classify(ctx)
  if class ~= "public" and class ~= "internal" then
    return nil,
      ("the data classes of this device do not release this repository (%s): no finding"):format(
        class
      ),
      M.REFUSED
  end
  local repo = vim.fs.basename(ctx.dir)
  local NIL = vim.NIL
  local where = NIL
  if src.where and type(src.where.file) == "string" then
    local line = tonumber(src.where.line)
    where = {
      file = clean(src.where.file, ctx, 1000) or "",
      line = (line and line > 0 and line == math.floor(line)) and line or NIL,
    }
  end
  local run = NIL
  if src.run then
    local url = type(src.run.url) == "string" and src.run.url:match("^https://github%.com/[^%s]*$")
      or nil
    run = {
      source = src.run.source == "ci" and "ci" or "local",
      id = clean(src.run.id, ctx, 200) or NIL,
      os = clean(src.run.os, ctx, 50) or NIL,
      url = url or NIL,
    }
  end
  local sha = type(src.sha) == "string"
      and src.sha:match("^%x+$")
      and #src.sha == 40
      and src.sha:lower()
    or nil
  return {
    schema = M.SCHEMA,
    fp = M.fingerprint(src.kind, repo, src.identity),
    kind = src.kind,
    repo = repo,
    area = area or NIL,
    sha = sha or NIL,
    class = class,
    where = where,
    run = run,
    title = clean(src.title, ctx, M.TITLE_MAX) or src.kind,
    excerpt = clean(src.excerpt, ctx, M.EXCERPT_MAX, true) or "",
    repro = clean(src.repro, ctx, M.REPRO_MAX) or NIL,
    rule = clean(src.rule, ctx, 100) or NIL,
  }
end

---The sources of a repository's findings, from its state: red cases, flaky cases, a red pipeline.
---@param dir string
---@param state_dir? string
---@return Testing.Finding.Source[]
function M.sources(dir, state_dir)
  local out = {}
  local state = require("testing.state")
  local sopts = { state_dir = state_dir }
  local st = state.load(dir, sopts)
  local green = require("testing.run.green").load(dir, sopts)
  for _, c in ipairs(state.failures(st)) do
    local msg = c.message
    if not msg and c.fails and c.fails[1] then
      msg = c.fails[1].msg
    end
    out[#out + 1] = {
      kind = "case",
      identity = c.id,
      title = ("%s: %s"):format(c.status, c.name or c.id),
      excerpt = msg,
      where = c.file and { file = c.file, line = c.line } or nil,
      run = { source = "local", id = st.run },
      sha = green and green.run == st.run and green.sha or nil,
      repro = ("testing . --file %s"):format(c.file or ""),
    }
  end
  for _, c in ipairs(st.cases or {}) do
    if c.flaky then
      out[#out + 1] = {
        kind = "flaky",
        identity = c.id,
        title = ("flaky: %s"):format(c.name or c.id),
        excerpt = c.message,
        where = c.file and { file = c.file, line = c.line } or nil,
        run = { source = "local", id = st.run },
        repro = ("testing . --file %s"):format(c.file or ""),
      }
    end
  end
  local f = io.open(require("testing.history").dir(dir, sopts) .. "/ci.json", "rb")
  if f then
    local text = f:read("*a")
    f:close()
    local okj, doc = pcall(vim.json.decode, text)
    if okj and type(doc) == "table" and (doc.verdict == "red" or doc.verdict == "error") then
      local step = type(doc.first_red) == "string" and doc.first_red or "pipeline"
      local detail
      for _, s in ipairs(type(doc.steps) == "table" and doc.steps or {}) do
        if type(s) == "table" and s.name == step then
          detail = s.output or s.tail or s.message
        end
      end
      out[#out + 1] = {
        kind = "ci-run",
        identity = "ci:" .. (type(doc.profile) == "string" and doc.profile or "-") .. ":" .. step,
        title = ("pipeline red at %s"):format(step),
        excerpt = type(detail) == "string" and detail or nil,
        run = { source = "local", id = type(doc.time) == "string" and doc.time or nil },
        sha = type(doc.commit) == "string" and doc.commit or nil,
        repro = ("testing ci --step=%s"):format(step),
      }
    end
  end
  return out
end

---The sources of the guard findings of one case of a run (`case.guards[]`): one finding per guard and message. The
---identity names the case, the guard and its id (or its first message line), never a line number or a stack.
---@param case table A case of the Result-IR with `id`, `file`, `line`, `guards`.
---@return Testing.Finding.Source[]
function M.from_guards(case)
  local out = {}
  for _, g in ipairs(case.guards or {}) do
    local first = tostring(g.message or ""):match("^[^\r\n]*") or ""
    out[#out + 1] = {
      kind = "guard",
      identity = ("%s|%s|%s"):format(case.id, g.guard, g.id or first),
      title = ("guard %s: %s"):format(tostring(g.guard), first),
      excerpt = g.stack and (tostring(g.message) .. "\n" .. g.stack) or tostring(g.message),
      where = case.file and { file = case.file, line = case.line } or nil,
      run = { source = "local" },
      repro = ("testing . --file %s"):format(case.file or ""),
      rule = g.id,
    }
  end
  return out
end

---The sources of the findings of a `testing-lint/1` document: one per finding of a check. The identity is the check,
---the file and the message, not the line, so a finding that only moved is the same finding.
---@param doc table The document of `testing lint --json`.
---@return Testing.Finding.Source[]
function M.from_lint(doc)
  local out = {}
  for _, check in ipairs(doc.checks or {}) do
    for _, f in ipairs(check.findings or {}) do
      local line = tonumber(f.line)
      out[#out + 1] = {
        kind = "lint",
        identity = ("%s|%s|%s"):format(
          tostring(f.check or check.name),
          tostring(f.file),
          tostring(f.message)
        ),
        title = ("%s: %s"):format(tostring(f.check or check.name), tostring(f.message)),
        excerpt = ("%s%s: %s"):format(
          tostring(f.file),
          line and (":" .. line) or "",
          tostring(f.message)
        ),
        where = f.file and { file = tostring(f.file), line = line } or nil,
        run = { source = "local" },
        repro = ("testing lint %s"):format(tostring(f.file or "")),
        rule = f.check or check.name,
      }
    end
  end
  return out
end

---The sources of the findings of test sheets that need a person to act: red (failed, stale or does not load).
---@param entries table[] The entries of `testing.sheet.report` (`sheet`, `rel`, `case`, `stale`, `error`).
---@return Testing.Finding.Source[]
function M.from_sheets(entries)
  local tasks = require("testing.sheet.tasks")
  local out = {}
  for _, e in ipairs(entries) do
    local word = tasks.state_word(e)
    if word == "red" or word == "stale" then
      local id = e.sheet and e.sheet.id or e.rel
      out[#out + 1] = {
        kind = "sheet",
        identity = ("sheet|%s"):format(id),
        title = ("sheet %s: %s"):format(e.sheet and e.sheet.title or e.rel, word),
        excerpt = e.error or (e.case and (e.case.message or e.case.status)) or e.stale,
        where = { file = e.rel },
        run = { source = "local" },
        repro = e.sheet and e.sheet.task and ("testing sheets run --task %s"):format(e.sheet.task)
          or nil,
      }
    end
  end
  return out
end

---The findings of a repository's state plus extra sources (guard findings of a run, a lint document, sheets).
---@param ctx Testing.Finding.Ctx
---@param extra? Testing.Finding.Source[]

---Sorted by `fp`; a repository the data classes do not release gives none.
---@return table[]|nil docs
---@return string|nil err
---@return string|nil kind
function M.collect(ctx, extra)
  local docs = {}
  local sources = M.sources(ctx.dir, ctx.state_dir)
  vim.list_extend(sources, extra or {})
  for _, src in ipairs(sources) do
    local doc, err, kind = M.build(src, ctx)
    if not doc then
      return nil, err, kind
    end
    docs[#docs + 1] = doc
  end
  table.sort(docs, function(a, b)
    return a.fp < b.fp
  end)
  return docs
end

return M
