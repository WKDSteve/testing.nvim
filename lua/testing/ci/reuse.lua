---@module 'testing.ci.reuse'
---@brief `testing ci reuse` and `testing ci superseded`: which jobs of a hosted run another run already proved green.
---@description
--- ```
--- testing ci reuse --job=<key>=<pathspec>[,<pathspec>...] [--job=...] [--name=<key>:<job name>] [--root=.]
---                  [--sha=<sha>] [--repo=<owner/name>] [--workflow=<path>] [--runs=50] [--full]
--- testing ci superseded [--ref=main] [--sha=<sha>] [--repo=<owner/name>]
--- ```
---
--- For any GitHub workflow, also a hand-written one (docs/WORKFLOW-CI.md, "Overtaken runs and reused jobs"). A first
--- job `plan` calls `testing ci reuse` with every job and its paths; each job then carries
--- `if: needs.plan.outputs.<key> != 'reuse'`.
---
--- Where the verdict per job and commit lies: in the job results of the GitHub Actions API. Every run can read them
--- (`actions: read`), they are bound to the commit, nobody without write access to the repository can make one, and a
--- cancelled run leaves the jobs that were green before it was cancelled.
---
--- A green job of commit A counts for commit B when all of this holds:
--- - the run is one of this workflow (`path`), in this repository (`head_repository`, never a fork), of the event
---   `push` (never `pull_request`, never a run by hand) and not this run;
--- - the job of that name is the newest completed one of the key among the runs of ancestors (newest run first): a red
---   one there decides `run`, a cancelled or skipped one is passed over (a skipped job reused something itself);
--- - A is an ancestor of B or B itself (the compare API: `ahead` or `identical`);
--- - `git diff --quiet A B -- <paths> <workflow file>` finds nothing: the workflow file always counts, a job without
---   paths is the whole tree (only a commit with the same tree then counts).
---
--- Everything that is not sure (an API error, a commit that cannot be fetched, a job never seen) decides `run`, with
--- its reason: in doubt the job runs. `--full` or `TESTING_REUSE=off` runs every job. The command never starts
--- anything, so it cannot bring an untrusted commit to a runner (CI-13): a green job of a self-hosted runner became
--- green only after the runner guard let its commit run.
---
--- Output: one line per job on stdout, `<key>=reuse|run` (and `<key>_from=<sha>`) to `$GITHUB_OUTPUT`, a table to
--- `$GITHUB_STEP_SUMMARY`. Exit 0 whenever every job got a decision, 2 on usage errors.
---
--- `testing ci superseded`: is the tip of `--ref` (default `main`) a strict descendant of the commit? `superseded=true`
--- and `by=<sha>` to `$GITHUB_OUTPUT` (a rolling build that would otherwise build an older commit); an error answers
--- `false` (then it builds, never silently not). Exit 0, 2 on usage errors.

local M = {}

M.EXIT_OK, M.EXIT_USAGE = 0, 2

---How many runs of the workflow are looked at, newest first (`--runs`).
M.DEFAULT_RUNS = 50
M.MAX_RUNS = 100

M.USAGE = table.concat({
  "usage: testing ci reuse --job=<key>=<pathspec>[,<pathspec>...] [--job=...] [--name=<key>:<job name>] [--root=.]",
  "                        [--sha=<sha>] [--repo=<owner/name>] [--workflow=<path>] [--runs=50] [--full]",
  "       testing ci superseded [--ref=main] [--sha=<sha>] [--repo=<owner/name>]",
  "  --job=<key>=<paths>  a job of the workflow and the git pathspecs it depends on (comma-separated; empty: the",
  "                       whole tree); <key> is the output name (letters, digits, _ and -) and the job's name",
  "  --name=<key>:<name>  the job's name in the run when it is not <key> (`name:` of the job)",
  "  --root=<dir>         the checkout (default .)",
  "  --sha, --repo        default $GITHUB_SHA, $GITHUB_REPOSITORY",
  "  --workflow=<path>    default from $GITHUB_WORKFLOW_REF (.github/workflows/<file>)",
  "  --runs=<n>           how many runs of the workflow are looked at, newest first (default 50, at most 100)",
  "  --full               every job runs (also TESTING_REUSE=off)",
  "writes <key>=reuse|run to $GITHUB_OUTPUT and a table to $GITHUB_STEP_SUMMARY; in doubt a job runs",
  "exit: 0 decided, 2 usage",
}, "\n")

---Replaced by a spec: processes and the environment.
M.deps = {
  ---@param dir string
  ---@param args string[]
  ---@return integer code
  ---@return string stdout
  ---@return string stderr
  git = function(dir, args)
    local ok, res = pcall(function()
      return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait(120000)
    end)
    if not ok or not res then
      return 127, "", tostring(res)
    end
    return res.code or 1, res.stdout or "", res.stderr or ""
  end,
  ---`gh api <path>`: the token comes from `$GH_TOKEN` of the step.
  ---@param path string
  ---@return integer code
  ---@return string stdout
  ---@return string stderr
  gh_api = function(path)
    local ok, res = pcall(function()
      return vim
        .system({ "gh", "api", "-H", "Accept: application/vnd.github+json", path }, { text = true })
        :wait(60000)
    end)
    if not ok or not res then
      return 127, "", tostring(res)
    end
    return res.code or 1, res.stdout or "", res.stderr or ""
  end,
  getenv = os.getenv,
  ---Append to a file (`$GITHUB_OUTPUT`, `$GITHUB_STEP_SUMMARY`).
  ---@param path string
  ---@param text string
  ---@return boolean ok
  append = function(path, text)
    local f = io.open(path, "a")
    if not f then
      return false
    end
    f:write(text)
    f:close()
    return true
  end,
}

local SHA_PAT = "^%x%x%x%x%x%x%x+$"

---@class Testing.Ci.Reuse.Job
---@field key string
---@field name string
---@field paths string[]

---@class Testing.Ci.Reuse.Args
---@field verb "reuse"|"superseded"
---@field jobs Testing.Ci.Reuse.Job[]
---@field root string
---@field sha? string
---@field repo? string
---@field workflow? string
---@field ref string
---@field runs integer
---@field full boolean
---@field help boolean

---A pathspec as the caller wrote it: no option, no line break, nothing empty.
---@param p string
---@return boolean
local function good_path(p)
  return p ~= "" and p:sub(1, 1) ~= "-" and not p:find("[%c]")
end

---@param verb "reuse"|"superseded"
---@param argv string[]
---@return Testing.Ci.Reuse.Args|nil
---@return string|nil problem
function M.parse(verb, argv)
  ---@type Testing.Ci.Reuse.Args
  local args = {
    verb = verb,
    jobs = {},
    root = ".",
    ref = "main",
    runs = M.DEFAULT_RUNS,
    full = false,
    help = false,
  }
  local names, by_key = {}, {}
  for _, a in ipairs(argv) do
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif verb == "reuse" and key == "full" and value == nil then
      args.full = true
    elseif verb == "reuse" and key == "job" and value then
      local k, paths = value:match("^([%w_%-]+)=(.*)$")
      if not k then
        return nil, ("--job=%s: <key>=<pathspec>,... (key: letters, digits, _ and -)"):format(value)
      end
      if by_key[k] then
        return nil, ("--job=%s: the key is given twice"):format(k)
      end
      local job = { key = k, name = k, paths = {} }
      for p in (paths .. ","):gmatch("([^,]*),") do
        p = vim.trim(p)
        if p ~= "" then
          if not good_path(p) then
            return nil, ("--job=%s: %q is no pathspec"):format(k, p)
          end
          job.paths[#job.paths + 1] = p
        end
      end
      by_key[k] = job
      args.jobs[#args.jobs + 1] = job
    elseif verb == "reuse" and key == "name" and value then
      local k, name = value:match("^([%w_%-]+):(.+)$")
      if not k or name:find("[%c]") then
        return nil, ("--name=%s: <key>:<job name>"):format(value)
      end
      names[k] = name
    elseif key == "root" and value and value ~= "" then
      args.root = value
    elseif key == "sha" and value then
      if not value:match(SHA_PAT) then
        return nil, ("--sha=%s: a commit id"):format(value)
      end
      args.sha = value
    elseif key == "repo" and value then
      if not value:match("^[%w_.%-]+/[%w_.%-]+$") then
        return nil, ("--repo=%s: owner/name"):format(value)
      end
      args.repo = value
    elseif verb == "reuse" and key == "workflow" and value then
      if not value:match("^[%w_./%-]+%.ya?ml$") or value:find("..", 1, true) then
        return nil, ("--workflow=%s: the path of the workflow file"):format(value)
      end
      args.workflow = value
    elseif verb == "reuse" and key == "runs" and value then
      local n = tonumber(value)
      if not n or n ~= math.floor(n) or n < 1 or n > M.MAX_RUNS then
        return nil, ("--runs=%s: 1 to %d"):format(value, M.MAX_RUNS)
      end
      args.runs = n
    elseif verb == "superseded" and key == "ref" and value then
      if not value:match("^[%w_./%-]+$") or value:find("..", 1, true) then
        return nil, ("--ref=%s: a branch"):format(value)
      end
      args.ref = value
    else
      return nil, ("unknown argument %s"):format(a)
    end
  end
  for k, name in pairs(names) do
    if not by_key[k] then
      return nil, ("--name=%s: no --job=%s"):format(k, k)
    end
    by_key[k].name = name
  end
  if verb == "reuse" and #args.jobs == 0 and not args.help then
    return nil, "no --job given"
  end
  return args
end

---@param text string
---@return table|nil
local function decode(text)
  local ok, doc = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(doc) == "table" and doc or nil
end

---The facts of the run from the arguments and the GitHub environment.
---@param args Testing.Ci.Reuse.Args
---@return table|nil ctx
---@return string|nil problem
local function context(args)
  local env = M.deps.getenv
  local ctx = {
    root = args.root,
    sha = args.sha or env("GITHUB_SHA"),
    repo = args.repo or env("GITHUB_REPOSITORY"),
    run_id = tonumber(env("GITHUB_RUN_ID") or ""),
    workflow = args.workflow,
  }
  if not ctx.workflow then
    -- owner/repo/.github/workflows/ci.yml@refs/heads/main
    local ref = env("GITHUB_WORKFLOW_REF") or ""
    ctx.workflow = ref:match("^[^/]+/[^/]+/(%.github/workflows/[^@]+)@")
  end
  if not (ctx.sha and ctx.sha:match(SHA_PAT)) then
    return nil, "no commit: --sha or $GITHUB_SHA"
  end
  if not (ctx.repo and ctx.repo:match("^[%w_.%-]+/[%w_.%-]+$")) then
    return nil, "no repository: --repo or $GITHUB_REPOSITORY"
  end
  if args.verb == "reuse" and not ctx.workflow then
    return nil, "no workflow file: --workflow or $GITHUB_WORKFLOW_REF"
  end
  return ctx
end

---Is `a` an ancestor of `b` or `b` itself? (The compare API; nil with a reason when it cannot say.)
---@param ctx table
---@param a string
---@param b string
---@return boolean|nil
---@return string|nil problem
local function ancestor(ctx, a, b)
  if a == b then
    return true
  end
  ctx.compare = ctx.compare or {}
  local key = a .. "..." .. b
  if ctx.compare[key] == nil then
    local code, out, err = M.deps.gh_api(("repos/%s/compare/%s...%s"):format(ctx.repo, a, b))
    local doc = code == 0 and decode(out) or nil
    if not doc or type(doc.status) ~= "string" then
      ctx.compare[key] = {
        problem = ("compare %s...%s: %s"):format(
          a:sub(1, 7),
          b:sub(1, 7),
          vim.trim(err ~= "" and err or out)
        ),
      }
    else
      ctx.compare[key] = { status = doc.status }
    end
  end
  local c = ctx.compare[key]
  if c.problem then
    return nil, c.problem
  end
  return c.status == "ahead" or c.status == "identical"
end

---Are `paths` (and the workflow file) the same at `a` and `b`? A missing commit is fetched (a shallow checkout).
---@param ctx table
---@param job Testing.Ci.Reuse.Job
---@param a string
---@return boolean|nil same
---@return string|nil problem
local function unchanged(ctx, job, a)
  local root = ctx.root
  for _, c in ipairs({ a, ctx.sha }) do
    if M.deps.git(root, { "cat-file", "-e", c .. "^{commit}" }) ~= 0 then
      local code, _, err =
        M.deps.git(root, { "fetch", "--no-tags", "--quiet", "--depth=1", "origin", c })
      if code ~= 0 then
        return nil, ("fetch %s: %s"):format(c:sub(1, 7), vim.trim(err))
      end
    end
  end
  local cmd = { "diff", "--quiet", "--no-ext-diff", a, ctx.sha, "--" }
  if #job.paths > 0 then
    vim.list_extend(cmd, job.paths)
    cmd[#cmd + 1] = ctx.workflow
  end
  local code, _, err = M.deps.git(root, cmd)
  if code == 0 then
    return true
  elseif code == 1 then
    return false
  end
  return nil, ("git diff: %s"):format(vim.trim(err))
end

---A run whose jobs may stand for this commit: this workflow, this repository, a push, not this run.
---@param ctx table
---@param run table
---@return boolean
local function trusted(ctx, run)
  if type(run) ~= "table" or type(run.head_sha) ~= "string" or not run.head_sha:match(SHA_PAT) then
    return false
  end
  if run.event ~= "push" or (ctx.run_id and run.id == ctx.run_id) then
    return false
  end
  local head = type(run.head_repository) == "table" and run.head_repository.full_name
  if head ~= ctx.repo then
    return false
  end
  -- `path` is the workflow file (`.github/workflows/ci.yml`, sometimes with `@<ref>`)
  if type(run.path) == "string" and run.path:gsub("@.*$", "") ~= ctx.workflow then
    return false
  end
  return true
end

---@class Testing.Ci.Reuse.Decision
---@field key string
---@field name string
---@field decision "reuse"|"run"
---@field from? string The commit whose green job is taken over.
---@field url? string That job.
---@field why string

---Decide every job.
---@param args Testing.Ci.Reuse.Args
---@param ctx table
---@return Testing.Ci.Reuse.Decision[]
---@return string[] notes
function M.plan(args, ctx)
  local out, open, notes = {}, {}, {}
  for _, job in ipairs(args.jobs) do
    local d = { key = job.key, name = job.name, decision = "run", why = "" }
    out[#out + 1] = d
    open[job.key] = { job = job, d = d }
  end
  local function decide(key, decision, why, from, url)
    local o = open[key]
    o.d.decision, o.d.why, o.d.from, o.d.url = decision, why, from, url
    open[key] = nil
  end
  if args.full or (M.deps.getenv("TESTING_REUSE") or "") == "off" then
    for _, job in ipairs(args.jobs) do
      decide(
        job.key,
        "run",
        args.full and "a full run was asked for (--full)"
          or "a full run was asked for (TESTING_REUSE=off)"
      )
    end
    return out, notes
  end
  local file = ctx.workflow:match("([^/]+)$")
  local code, text, err = M.deps.gh_api(
    ("repos/%s/actions/workflows/%s/runs?event=push&per_page=%d"):format(ctx.repo, file, args.runs)
  )
  local doc = code == 0 and decode(text) or nil
  if not doc or type(doc.workflow_runs) ~= "table" then
    local why = "the runs of the workflow could not be read: "
      .. vim.trim(err ~= "" and err or text)
    for _, job in ipairs(args.jobs) do
      decide(job.key, "run", why)
    end
    return out, notes
  end
  for _, run in ipairs(doc.workflow_runs) do
    if next(open) == nil then
      break
    end
    if trusted(ctx, run) then
      local jobs
      for _, key in ipairs(vim.tbl_keys(open)) do
        local o = open[key]
        if o then
          if jobs == nil then
            local jc, jt = M.deps.gh_api(
              ("repos/%s/actions/runs/%d/jobs?filter=latest&per_page=100"):format(ctx.repo, run.id)
            )
            local jd = jc == 0 and decode(jt) or nil
            jobs = jd and type(jd.jobs) == "table" and jd.jobs or false
            if not jobs then
              notes[#notes + 1] = ("the jobs of run %s could not be read: passed over"):format(
                tostring(run.id)
              )
            end
          end
          local hit
          for _, j in ipairs(jobs or {}) do
            if type(j) == "table" and j.name == o.job.name and j.status == "completed" then
              if
                j.conclusion == "success"
                or j.conclusion == "failure"
                or j.conclusion == "timed_out"
              then
                hit = j
                break
              end
            end
          end
          if hit then
            local short = run.head_sha:sub(1, 7)
            local anc, aproblem = ancestor(ctx, run.head_sha, ctx.sha)
            if anc == nil then
              decide(key, "run", aproblem --[[@as string]])
            elseif anc then
              if hit.conclusion ~= "success" then
                decide(
                  key,
                  "run",
                  ("red at %s (%s)"):format(short, hit.conclusion),
                  run.head_sha,
                  hit.html_url
                )
              else
                local same, uproblem = unchanged(ctx, o.job, run.head_sha)
                if same == nil then
                  decide(key, "run", uproblem --[[@as string]])
                elseif same then
                  decide(
                    key,
                    "reuse",
                    ("green at %s, %s unchanged since"):format(
                      short,
                      #o.job.paths > 0 and table.concat(o.job.paths, ", ") or "the tree"
                    ),
                    run.head_sha,
                    hit.html_url
                  )
                else
                  decide(
                    key,
                    "run",
                    ("green at %s, but %s changed since"):format(
                      short,
                      #o.job.paths > 0 and table.concat(o.job.paths, ", ") .. " or the workflow"
                        or "the tree"
                    ),
                    run.head_sha,
                    hit.html_url
                  )
                end
              end
            end
            -- not an ancestor (another line of history): passed over
          end
        end
      end
    end
  end
  for key in pairs(vim.deepcopy(open)) do
    decide(
      key,
      "run",
      ("no completed job of this name for an ancestor among the last %d runs"):format(args.runs)
    )
  end
  return out, notes
end

---@param args Testing.Ci.Reuse.Args
---@param ctx table
---@return { superseded: boolean, by?: string, why: string }
function M.superseded(args, ctx)
  local code, text, err = M.deps.gh_api(("repos/%s/commits/%s"):format(ctx.repo, args.ref))
  local doc = code == 0 and decode(text) or nil
  local tip = doc and type(doc.sha) == "string" and doc.sha:match(SHA_PAT) and doc.sha or nil
  if not tip then
    return {
      superseded = false,
      why = ("the tip of %s could not be read (%s): not superseded"):format(
        args.ref,
        vim.trim(err ~= "" and err or text)
      ),
    }
  end
  if tip == ctx.sha then
    return { superseded = false, why = ("%s is the tip of %s"):format(ctx.sha:sub(1, 7), args.ref) }
  end
  local anc, problem = ancestor(ctx, ctx.sha, tip)
  if anc == nil then
    return { superseded = false, why = tostring(problem) .. ": not superseded" }
  elseif anc then
    return {
      superseded = true,
      by = tip,
      why = ("%s of %s contains %s"):format(tip:sub(1, 7), args.ref, ctx.sha:sub(1, 7)),
    }
  end
  return {
    superseded = false,
    why = ("%s of %s does not contain %s"):format(tip:sub(1, 7), args.ref, ctx.sha:sub(1, 7)),
  }
end

---Write `lines` to the file of the variable `name`, when it is set.
---@param name string
---@param text string
---@param say fun(s: string)
local function to_env_file(name, text, say)
  local path = M.deps.getenv(name)
  if path and path ~= "" and not M.deps.append(path, text) then
    say(("testing ci reuse: could not write $%s (%s)"):format(name, path))
  end
end

---`testing ci reuse ...` / `testing ci superseded ...`.
---@param verb "reuse"|"superseded"
---@param argv string[]
---@param sv table `out`, `err`
---@return integer
function M.main(verb, argv, sv)
  local args, problem = M.parse(verb, argv)
  if not args then
    sv.err(("testing ci %s: %s"):format(verb, tostring(problem)))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local ctx, why = context(args)
  if not ctx then
    sv.err(("testing ci %s: %s"):format(verb, tostring(why)))
    return M.EXIT_USAGE
  end
  if verb == "superseded" then
    local r = M.superseded(args, ctx)
    sv.out(("superseded=%s  %s"):format(tostring(r.superseded), r.why))
    to_env_file(
      "GITHUB_OUTPUT",
      ("superseded=%s\nby=%s\n"):format(tostring(r.superseded), r.by or ""),
      sv.err
    )
    return M.EXIT_OK
  end
  local decisions, notes = M.plan(args, ctx)
  local outputs, rows =
    {}, {
      "### testing ci reuse",
      "",
      ("Commit `%s`: %d of %d jobs taken over."):format(ctx.sha:sub(1, 7), #vim.tbl_filter(function(d)
        return d.decision == "reuse"
      end, decisions), #decisions),
      "",
      "| job | decision | why |",
      "| --- | --- | --- |",
    }
  for _, d in ipairs(decisions) do
    sv.out(("%-5s  %s  %s"):format(d.decision, d.key, d.why))
    outputs[#outputs + 1] = ("%s=%s"):format(d.key, d.decision)
    outputs[#outputs + 1] = ("%s_from=%s"):format(d.key, d.decision == "reuse" and d.from or "")
    local cell = d.why:gsub("|", "\\|")
    if d.url and d.url:match("^https://") then
      cell = cell .. (" ([job](%s))"):format(d.url)
    end
    rows[#rows + 1] = ("| %s | %s | %s |"):format((d.name:gsub("|", "\\|")), d.decision, cell)
  end
  for _, n in ipairs(notes) do
    sv.out("note: " .. n)
    rows[#rows + 1] = ""
    rows[#rows + 1] = "Note: " .. n
  end
  to_env_file("GITHUB_OUTPUT", table.concat(outputs, "\n") .. "\n", sv.err)
  to_env_file("GITHUB_STEP_SUMMARY", table.concat(rows, "\n") .. "\n", sv.err)
  return M.EXIT_OK
end

return M
