---@module 'testing.ci.remote_history'
---@brief `testing ci remote --history[=N]`: the last N push runs of the CI workflow per repository, per system.
---@description
--- `testing ci remote` knows the run of the head commit only. Whether macOS is the only problem shows over several
--- runs: per repository the newest N completed push runs of the workflow (`ci_remote.workflow`) on the branch, the jobs
--- of each, counted per system (success, failure, cancelled, skipped), and every RED job of a system compared with the
--- SAME job on the other systems of the SAME run:
---
---   * `only`     the same job was not red on any other system: this system is the problem;
---   * `also`     the same job was red on another system too: not a problem of this system;
---   * `no_peer`  no such job on another system: no comparison, counted apart.
---
--- "The same job" is the job name without the system words (`ubuntu`, `windows`, `macos`, `linux`, an image version,
--- `latest`): `suite (macos-latest)` and `suite (ubuntu-latest)` are one job. Only `failure` counts as red (a job
--- cancelled by a newer push says nothing). Jobs of non-gating names (`ci_remote.non_gating`) are left out.
---
--- Requests: one for the run list (conditional, with an ETag) and one per completed run for its jobs; the jobs of a
--- completed run never change, so they are stored (`<state>/testing/ci-remote/history_<owner>_<repo>_<hash>.json`) and
--- asked for once. The run list answers at most `MAX` (100) runs of the branch, among them other workflows; fewer than N
--- runs of the workflow can come back, which the record says.
---
--- Document `testing-ci-remote-history/1` (`--json`); exit codes: 0 every repository was read, 3 one could not be.

local M = {}

M.SCHEMA = "testing-ci-remote-history/1"

---Runs looked at when `--history` has no number.
M.DEFAULT = 30

---The most runs one repository answers (one page of the run list).
M.MAX = 100

---@type string[]
M.SYSTEMS = { "ubuntu", "windows", "macos" }

local STATES = { "success", "failure", "cancelled", "skipped", "other" }

---The name of a job without the system: the key under which the same job of the other systems is found.
---@param name string
---@return string
function M.job_key(name)
  local s = (" " .. name:lower() .. " ")
  -- the system word with an image version right after it (`windows-2022`, `macos 14`, `ubuntu-22.04`), then the word
  -- alone; never a following word (`suite windows test` and `suite ubuntu test` are one job)
  for _, sys in ipairs({ "ubuntu", "windows", "macos", "linux" }) do
    s = s:gsub(sys .. "[%-_ ]?%d[%d%.]*", " "):gsub(sys, " ")
  end
  s = s:gsub("%f[%w]latest%f[%W]", " "):gsub("[^%w%.]+", " ")
  return vim.trim(s)
end

---@return table<string, integer>
local function zero_counts()
  local c = {}
  for _, s in ipairs(STATES) do
    c[s] = 0
  end
  return c
end

---The jobs of completed runs, counted. Pure.
---@param runs { id: integer, created_at?: string, jobs: table[] }[] Completed runs with their trimmed jobs.
---@param non_gating string[] Lowercase texts.
---@param now integer
---@return { systems: table<string, table<string, integer>>, red: table<string, { total: integer, only: integer, also: integer, no_peer: integer, only_runs: integer[] }> }
function M.analyze(runs, non_gating, now)
  local remote = require("testing.ci.remote")
  local systems, red = {}, {}
  for _, sys in ipairs(M.SYSTEMS) do
    systems[sys] = zero_counts()
    red[sys] = { total = 0, only = 0, also = 0, no_peer = 0, only_runs = {} }
  end
  for _, run in ipairs(runs) do
    local rows = {}
    for _, job in ipairs(run.jobs) do
      local lname = job.name:lower()
      local gating = true
      for _, t in ipairs(non_gating) do
        if lname:find(t, 1, true) then
          gating = false
          break
        end
      end
      local sys = remote.job_os(job)
      if gating and systems[sys] then
        local state = remote.job_state(job, now, run.created_at)
        local bucket = (state == "no_runner") and "cancelled"
          or (systems[sys][state] and state)
          or "other"
        systems[sys][bucket] = systems[sys][bucket] + 1
        rows[#rows + 1] = { sys = sys, key = M.job_key(job.name), state = state }
      end
    end
    local alone = {}
    for _, row in ipairs(rows) do
      if row.state == "failure" then
        local peers, peer_red = 0, false
        for _, other in ipairs(rows) do
          if other.sys ~= row.sys and other.key == row.key then
            peers = peers + 1
            peer_red = peer_red or other.state == "failure"
          end
        end
        local r = red[row.sys]
        r.total = r.total + 1
        if peers == 0 then
          r.no_peer = r.no_peer + 1
        elseif peer_red then
          r.also = r.also + 1
        else
          r.only = r.only + 1
          if not alone[row.sys] then
            alone[row.sys] = true
            r.only_runs[#r.only_runs + 1] = run.id
          end
        end
      end
    end
  end
  return { systems = systems, red = red }
end

---The newest `n` completed push runs of `workflow`; the number of runs not completed yet.
---@param runs table[]
---@param workflow string
---@param n integer
---@return table[] completed
---@return integer pending
function M.select(runs, workflow, n)
  workflow = workflow:lower()
  local mine = {}
  for _, r in ipairs(runs) do
    if r.name and r.name:lower() == workflow and r.event == "push" then
      mine[#mine + 1] = r
    end
  end
  table.sort(mine, function(a, b)
    local ka = (a.created_at or "") .. ("%020d"):format(a.id)
    local kb = (b.created_at or "") .. ("%020d"):format(b.id)
    return ka > kb
  end)
  local done, pending = {}, 0
  for i = 1, math.min(n, #mine) do
    if mine[i].status == "completed" then
      done[#done + 1] = mine[i]
    else
      pending = pending + 1
    end
  end
  return done, pending
end

---@param owner string
---@param repo string
---@param dir string
---@param state_dir string
---@return string
local function cache_path(owner, repo, dir, state_dir)
  return ("%s/testing/ci-remote/history_%s_%s_%s.json"):format(
    state_dir,
    owner,
    repo,
    vim.fn.sha256(dir):sub(1, 8)
  )
end

---@param path string
---@return { etag?: string, runs?: table[], jobs: table<string, { updated_at: string, list: table[] }> }
local function read_cache(path)
  local out = { jobs = {} }
  local raw = require("lib.nvim.fs.read_bounded")(path, 8 * 1024 * 1024)
  local ok, doc = pcall(vim.json.decode, raw or "")
  if not ok or type(doc) ~= "table" or doc.v ~= 1 then
    return out
  end
  if type(doc.etag) == "string" and type(doc.runs) == "table" then
    out.etag, out.runs = doc.etag, doc.runs
  end
  if type(doc.jobs) == "table" then
    for id, e in pairs(doc.jobs) do
      if type(e) == "table" and type(e.updated_at) == "string" and type(e.list) == "table" then
        out.jobs[id] = e
      end
    end
  end
  return out
end

---@param path string
---@param cache table
local function write_cache(path, cache)
  cache.v = 1
  local ok, enc = pcall(require("lib.nvim.json.canonical").encode, cache)
  if ok then
    pcall(require("lib.nvim.fs.write.atomic"), path, enc, { mkdirp = true })
  end
end

---Ask GitHub about one repository; `done()` once `rec` is filled.
---@param rec table
---@param ctx { token: string, state_dir: string, n: integer, now: integer, closed?: boolean }
---@param done fun()
local function fetch(rec, ctx, done)
  local github = require("lib.nvim.net.github")
  local remote = require("testing.ci.remote")
  local path = cache_path(rec.owner, rec.repo, rec.dir, ctx.state_dir)
  local cache = read_cache(path)
  local fresh = { jobs = {} }
  local finished = false
  local function finish(err)
    if finished or ctx.closed then
      return
    end
    finished = true
    if err then
      rec.error = tostring(err):gsub(vim.pesc(ctx.token), "***"):sub(1, 300)
      rec.note = rec.error
    else
      write_cache(path, fresh)
    end
    done()
  end
  local function opts(etag, query)
    return { token = ctx.token, etag = etag, query = query, transport = remote.deps.transport }
  end
  local base = ("/repos/%s/%s/actions/runs"):format(rec.owner, rec.repo)

  local function analyse(selected, pending)
    local runs = {}
    for _, r in ipairs(selected) do
      runs[#runs + 1] = { id = r.id, created_at = r.created_at, jobs = r.jobs }
    end
    local result = M.analyze(runs, rec.non_gating, ctx.now)
    rec.runs = { considered = #selected + pending, completed = #selected, pending = pending }
    rec.systems = result.systems
    rec.red = result.red
    if #selected + pending < ctx.n then
      rec.note = ("only %d run(s) of %s found among the last %d of the branch"):format(
        #selected + pending,
        rec.workflow,
        M.MAX
      )
    end
    finish()
  end

  local sent, send_err = pcall(
    github.request,
    base,
    opts(cache.etag, { branch = rec.branch, event = "push", per_page = tostring(M.MAX) }),
    function(res, err)
      if ctx.closed then
        return
      end
      local ok, perr = pcall(function()
        if not res then
          return finish(err)
        end
        local list
        if res.not_modified and cache.runs then
          list = cache.runs
          fresh.etag, fresh.runs = res.etag or cache.etag, list
        else
          local raw = type(res.data) == "table" and res.data.workflow_runs
          if type(raw) ~= "table" then
            return finish("GitHub answered the runs without a workflow_runs list")
          end
          list = {}
          for _, r in ipairs(raw) do
            if type(r) == "table" and type(r.id) == "number" then
              list[#list + 1] = {
                id = r.id,
                name = type(r.name) == "string" and r.name:sub(1, 200) or nil,
                status = type(r.status) == "string" and r.status or nil,
                conclusion = type(r.conclusion) == "string" and r.conclusion or nil,
                created_at = type(r.created_at) == "string" and r.created_at or nil,
                updated_at = type(r.updated_at) == "string" and r.updated_at or nil,
                event = type(r.event) == "string" and r.event or nil,
              }
            end
          end
          fresh.etag, fresh.runs = res.etag, res.etag and list or nil
        end
        local selected, pending = M.select(list, rec.workflow, ctx.n)
        local i = 0
        local function next_run()
          i = i + 1
          local run = selected[i]
          if not run then
            return analyse(selected, pending)
          end
          local stored = cache.jobs[tostring(run.id)]
          if stored and stored.updated_at == run.updated_at then
            fresh.jobs[tostring(run.id)] = stored
            run.jobs = stored.list
            return next_run()
          end
          github.request(
            ("%s/%d/jobs"):format(base, run.id),
            opts(nil, { per_page = "100" }),
            function(res2, err2)
              if ctx.closed then
                return
              end
              local ok2, perr2 = pcall(function()
                if not res2 then
                  return finish(err2)
                end
                local raw = type(res2.data) == "table" and res2.data.jobs
                if type(raw) ~= "table" then
                  return finish("GitHub answered the jobs without a jobs list")
                end
                local jobs = {}
                for _, j in ipairs(raw) do
                  if type(j) == "table" and type(j.id) == "number" then
                    local labels = {}
                    for _, l in ipairs(type(j.labels) == "table" and j.labels or {}) do
                      labels[#labels + 1] = tostring(l):sub(1, 100)
                    end
                    local steps = type(j.steps) == "table" and #j.steps or nil
                    local no_runner = steps == 0
                      and (type(j.runner_name) ~= "string" or j.runner_name == "")
                    jobs[#jobs + 1] = {
                      id = j.id,
                      name = type(j.name) == "string" and j.name:sub(1, 200) or "",
                      status = type(j.status) == "string" and j.status or nil,
                      conclusion = type(j.conclusion) == "string" and j.conclusion or nil,
                      created_at = type(j.created_at) == "string" and j.created_at or nil,
                      labels = labels,
                      no_runner = no_runner,
                    }
                  end
                end
                run.jobs = jobs
                fresh.jobs[tostring(run.id)] = { updated_at = run.updated_at or "", list = jobs }
                next_run()
              end)
              if not ok2 then
                finish("internal error: " .. tostring(perr2))
              end
            end
          )
        end
        next_run()
      end)
      if not ok then
        finish("internal error: " .. tostring(perr))
      end
    end
  )
  if not sent then
    finish("GitHub request failed: " .. tostring(send_err))
  end
end

---The records of `repos`, sorted by name.
---@param repos { dir: string, from_root: boolean }[]
---@param opts { n: integer, workflow?: string, state_dir: string }
---@return table[] records
---@return { token_source?: string, token_error?: string, token?: string } info
function M.collect(repos, opts)
  local remote = require("testing.ci.remote")
  local now = remote.deps.now()
  repos = remote.dedupe_clones(repos)
  local records = {}
  for _, r in ipairs(repos) do
    local cfg = remote.repo_config(r.dir)
    local url = remote.deps.git(r.dir, { "remote", "get-url", "origin" }):wait()
    local owner, repo
    if url.code == 0 then
      owner, repo = remote.parse_origin(url.stdout or "")
    end
    -- as `testing ci remote`: git itself failing is an error (exit 3), an origin that is not GitHub only a note
    local git_failed = url.code ~= 0 and url.code ~= 2
    if owner or git_failed or not r.from_root then
      local rec = {
        repo = repo or vim.fs.basename(r.dir),
        owner = owner,
        dir = r.dir,
        branch = cfg.branch,
        workflow = opts.workflow or cfg.workflow,
        non_gating = vim.tbl_map(string.lower, cfg.non_gating),
      }
      if git_failed then
        rec.error = ("git remote get-url origin failed (exit %s)"):format(tostring(url.code))
        rec.note = rec.error
      elseif not owner then
        rec.note = url.code == 0 and "origin is not on GitHub" or "no origin remote"
      end
      records[#records + 1] = rec
    end
  end
  local info = {}
  local pending = vim.tbl_filter(function(rec)
    return rec.owner ~= nil
  end, records)
  if #pending > 0 then
    local ok, token, source = pcall(remote.deps.token)
    if not ok then
      token, source = nil, tostring(token)
    end
    if not token then
      info.token_error = tostring(source):sub(1, 300)
      for _, rec in ipairs(pending) do
        rec.error = "no GitHub token: " .. info.token_error
        rec.note = "no GitHub token"
      end
    else
      info.token_source, info.token = source, token
      local ctx = { token = token, state_dir = opts.state_dir, n = opts.n, now = now }
      local next_i, open = 1, 0
      local function launch()
        while not ctx.closed and open < remote.PARALLEL and next_i <= #pending do
          local rec = pending[next_i]
          next_i = next_i + 1
          open = open + 1
          fetch(rec, ctx, function()
            open = open - 1
            launch()
          end)
        end
      end
      launch()
      vim.wait(remote.DEADLINE_MS * 4, function()
        return open == 0 and next_i > #pending
      end, 10)
      ctx.closed = true
      for _, rec in ipairs(pending) do
        if not rec.systems and not rec.error then
          rec.error = "no answer within the deadline"
          rec.note = rec.error
        end
      end
    end
  end
  table.sort(records, function(a, b)
    if a.repo ~= b.repo then
      return a.repo < b.repo
    end
    return a.dir < b.dir
  end)
  return records, info
end

---The document `testing-ci-remote-history/1`.
---@param records table[]
---@param info table
---@param opts { n: integer, workflow?: string, state_dir?: string }
---@return table
function M.document(records, info, opts)
  local remote = require("testing.ci.remote")
  local copy = vim.deepcopy(records)
  for _, rec in ipairs(copy) do
    rec.non_gating = nil
  end
  return {
    schema = M.SCHEMA,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", remote.deps.now()),
    n = opts.n,
    workflow = opts.workflow,
    token_source = info.token_source,
    token_error = info.token_error,
    repos = remote.redact_records(copy, info.token, opts.state_dir),
  }
end

---@param c table<string, integer>
---@return string
local function cell(c)
  return ("%d/%d/%d"):format(c.success, c.failure, c.cancelled)
end

---The table: per repository the runs and per system `ok/red/cancelled` jobs, then the red of the systems against the
---others.
---@param records table[]
---@return string[]
function M.render(records)
  local width = 24
  for _, rec in ipairs(records) do
    width = math.max(width, #rec.repo + 1)
  end
  local fmt = "%-" .. width .. "s %-6s %-12s %-12s %-12s %s"
  local lines =
    { (fmt:format("REPO", "RUNS", "UBUNTU", "WINDOWS", "MACOS", "MACOS RED: ONLY/ALSO/NO PEER")) }
  for _, rec in ipairs(records) do
    if rec.systems then
      local m = rec.red.macos
      lines[#lines + 1] = fmt:format(
        rec.repo,
        tostring(rec.runs.completed),
        cell(rec.systems.ubuntu),
        cell(rec.systems.windows),
        cell(rec.systems.macos),
        m.total == 0 and "-" or ("%d / %d / %d"):format(m.only, m.also, m.no_peer)
      )
    else
      lines[#lines + 1] = fmt:format(rec.repo, "?", "?", "?", "?", rec.note or "")
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] =
    "cells are ok/red/cancelled jobs of the completed runs; MACOS RED compares each red macOS job with the same job"
  lines[#lines + 1] =
    "on the other systems of its run: ONLY = not red there, ALSO = red there too, NO PEER = no such job there."
  return lines
end

---@param records table[]
---@return integer
function M.exit_code(records)
  local remote = require("testing.ci.remote")
  for _, rec in ipairs(records) do
    if rec.error then
      return remote.EXIT_INFRA
    end
  end
  return remote.EXIT_OK
end

return M
