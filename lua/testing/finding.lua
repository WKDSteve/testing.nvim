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

---The findings of a repository, sorted by `fp`; a repository the data classes do not release gives none.
---@param ctx Testing.Finding.Ctx
---@return table[]|nil docs
---@return string|nil err
---@return string|nil kind
function M.collect(ctx)
  local docs = {}
  for _, src in ipairs(M.sources(ctx.dir, ctx.state_dir)) do
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
