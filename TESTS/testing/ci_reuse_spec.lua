-- TESTS/testing/ci_reuse_spec.lua -- `testing ci reuse` / `testing ci superseded`: a green job of an ancestor's push run
-- (also of a cancelled run) is taken over when its paths and the workflow file are unchanged; a red one there, a run
-- that is no push of this repository and workflow, a commit off the line of history and every error decide `run`;
-- `--full` and `TESTING_REUSE=off` run everything; `superseded` answers from the tip of the branch. GitHub, git and
-- the environment are fakes.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end

  local reuse = require("testing.ci.reuse")
  local saved = vim.deepcopy(reuse.deps)
  local REPO, WF = "o/app", ".github/workflows/ci.yml"
  local B, A, P, X = ("b"):rep(40), ("a"):rep(40), ("9"):rep(40), ("e"):rep(40)

  local function run(id, sha, jobs, over)
    local r = {
      id = id,
      head_sha = sha,
      event = "push",
      path = WF,
      head_repository = { full_name = REPO },
      jobs = jobs,
    }
    return vim.tbl_extend("force", r, over or {})
  end
  local function job(name, conclusion)
    return {
      name = name,
      status = "completed",
      conclusion = conclusion,
      html_url = "https://github.com/o/app/actions/runs/1/job/" .. name,
    }
  end

  ---One world: `o.runs` (newest first), `o.compare[sha] = status of sha...B`, `o.changed(a, paths)` true when the
  ---diff of a..B touches the pathspecs, `o.env` the environment. Returns what was said and written.
  local function world(o)
    local w = { out = {}, err = {}, files = {}, gh = {}, diffs = {} }
    local env = vim.tbl_extend("force", {
      GITHUB_SHA = B,
      GITHUB_REPOSITORY = REPO,
      GITHUB_RUN_ID = "500",
      GITHUB_WORKFLOW_REF = REPO .. "/" .. WF .. "@refs/heads/main",
      GITHUB_OUTPUT = "/out",
      GITHUB_STEP_SUMMARY = "/summary",
    }, o.env or {})
    reuse.deps.getenv = function(name)
      return env[name]
    end
    reuse.deps.append = function(path, text)
      w.files[path] = (w.files[path] or "") .. text
      return true
    end
    reuse.deps.gh_api = function(path)
      w.gh[#w.gh + 1] = path
      if o.gh_fail and path:find(o.gh_fail, 1, true) then
        return 1, "", "HTTP 502"
      end
      if path:match("/actions/workflows/ci%.yml/runs%?event=push") then
        local runs = {}
        for _, r in ipairs(o.runs or {}) do
          local copy = vim.deepcopy(r)
          copy.jobs = nil
          runs[#runs + 1] = copy
        end
        return 0, vim.json.encode({ workflow_runs = runs }), ""
      end
      local id = path:match("/actions/runs/(%d+)/jobs")
      if id then
        for _, r in ipairs(o.runs or {}) do
          if r.id == tonumber(id) then
            return 0, vim.json.encode({ jobs = r.jobs }), ""
          end
        end
        return 1, "", "HTTP 404"
      end
      local a, b = path:match("/compare/(%x+)%.%.%.(%x+)$")
      if a then
        local status = (o.compare or {})[a .. "..." .. b] or (o.compare or {})[a]
        if not status then
          return 1, "", "HTTP 404"
        end
        return 0, vim.json.encode({ status = status }), ""
      end
      local ref = path:match("/commits/([%w_./%-]+)$")
      if ref then
        if not o.tip then
          return 1, "", "HTTP 404"
        end
        return 0, vim.json.encode({ sha = o.tip }), ""
      end
      return 1, "", "unexpected " .. path
    end
    reuse.deps.git = function(_, args)
      if args[1] == "cat-file" then
        return 0, "", ""
      elseif args[1] == "diff" then
        local a = args[4]
        local paths = vim.list_slice(args, 7)
        w.diffs[#w.diffs + 1] = { a = a, paths = paths }
        local touched = o.changed and o.changed(a, paths)
        if touched == nil then
          return 128, "", "fatal: bad object"
        end
        return touched and 1 or 0, "", ""
      end
      return 1, "", "unexpected git " .. args[1]
    end
    w.code = require("testing.ci").main(o.argv, {
      out = function(s)
        w.out[#w.out + 1] = s
      end,
      err = function(s)
        w.err[#w.err + 1] = s
      end,
    })
    w.text = table.concat(w.out, "\n")
    w.output = w.files["/out"] or ""
    w.summary = w.files["/summary"] or ""
    return w
  end

  local JOBS = { "reuse", "--job=rust=src-tauri,Cargo.lock", "--job=ui=ui", "--name=ui:ui (node)" }

  -- the overtaken run: rust went green before the cancel, ui was cancelled; an older run had both green
  do
    local w = world({
      argv = JOBS,
      runs = {
        run(400, A, { job("rust", "success"), job("ui (node)", "cancelled") }),
        run(300, P, { job("rust", "success"), job("ui (node)", "success") }),
      },
      compare = { [A] = "ahead", [P] = "ahead" },
      changed = function(a, paths)
        -- ui changed between P and B; nothing of rust since A
        return a == P and paths[1] == "ui"
      end,
    })
    eq(w.code, 0, "overtaken: exit")
    has(
      w.output,
      "rust=reuse\nrust_from=" .. A,
      "overtaken: rust taken over from the cancelled run"
    )
    has(
      w.output,
      "ui=run\nui_from=\n",
      "overtaken: ui runs (a cancelled job is passed over, the older one changed)"
    )
    has(w.text, "reuse  rust  green at aaaaaaa", "overtaken: the report says from where")
    has(
      w.text,
      "run    ui  green at 9999999, but ui or the workflow changed since",
      "overtaken: and why ui runs"
    )
    has(w.summary, "| ui (node) | run |", "overtaken: the summary names the job")
    has(w.summary, "1 of 2 jobs taken over", "overtaken: the summary counts")
    -- the workflow file is always part of the pathspec
    eq(w.diffs[1].paths, { "src-tauri", "Cargo.lock", WF }, "overtaken: the workflow file counts")
  end

  -- a red job at the newest ancestor decides, even when an older run had it green
  do
    local w = world({
      argv = JOBS,
      runs = {
        run(400, A, { job("rust", "failure"), job("ui (node)", "success") }),
        run(300, P, { job("rust", "success") }),
      },
      compare = { [A] = "ahead", [P] = "ahead" },
      changed = function()
        return false
      end,
    })
    has(w.output, "rust=run", "red: rust runs")
    has(w.text, "red at aaaaaaa (failure)", "red: the reason")
    has(w.output, "ui=reuse", "red: ui is taken over")
  end

  -- runs that cannot stand for this commit: a pull request, a fork, another workflow, this very run, another line
  do
    local w = world({
      argv = { "reuse", "--job=rust=src-tauri" },
      runs = {
        run(500, B, { job("rust", "success") }),
        run(450, A, { job("rust", "success") }, { event = "pull_request" }),
        run(440, A, { job("rust", "success") }, { head_repository = { full_name = "fork/app" } }),
        run(430, A, { job("rust", "success") }, { path = ".github/workflows/other.yml" }),
        run(420, X, { job("rust", "success") }),
      },
      compare = { [A] = "ahead", [X] = "diverged" },
      changed = function()
        return false
      end,
    })
    has(w.output, "rust=run", "untrusted: nothing is taken over")
    has(w.text, "no completed job of this name for an ancestor", "untrusted: the reason")
    for _, path in ipairs(w.gh) do
      ok(not path:find("/runs/4[345]0/jobs"), "untrusted: the jobs of " .. path .. " are not read")
      ok(not path:find("/runs/500/jobs"), "untrusted: this run is not read")
    end
  end

  -- the same commit green on a check branch (ci land): the whole tree, nothing changed
  do
    local w = world({
      argv = { "reuse", "--job=all=" },
      runs = { run(400, B, { job("all", "success") }) },
      changed = function()
        return false
      end,
    })
    has(w.output, "all=reuse\nall_from=" .. B, "same commit: taken over")
    eq(#w.diffs, 1, "same commit: one diff")
    eq(w.diffs[1].paths, {}, "same commit: no pathspec, the whole tree")
    has(w.text, "the tree unchanged since", "same commit: the report")
  end

  -- errors decide `run`
  do
    local w = world({ argv = JOBS, runs = {}, gh_fail = "/runs?event" })
    has(w.output, "rust=run", "api down: rust runs")
    has(w.text, "the runs of the workflow could not be read: HTTP 502", "api down: the reason")
    w = world({
      argv = { "reuse", "--job=rust=src" },
      runs = { run(400, A, { job("rust", "success") }) },
    })
    has(w.text, "compare aaaaaaa...bbbbbbb: HTTP 404", "compare fails: the reason")
    has(w.output, "rust=run", "compare fails: runs")
    w = world({
      argv = { "reuse", "--job=rust=src" },
      runs = { run(400, A, { job("rust", "success") }) },
      compare = { [A] = "ahead" },
    })
    has(w.text, "git diff: fatal: bad object", "diff fails: the reason")
    has(w.output, "rust=run", "diff fails: runs")
  end

  -- a full run on request: no question to GitHub
  for _, o in ipairs({
    { argv = vim.list_extend(vim.deepcopy(JOBS), { "--full" }), why = "(--full)" },
    { argv = JOBS, env = { TESTING_REUSE = "off" }, why = "(TESTING_REUSE=off)" },
  }) do
    local w = world({
      argv = o.argv,
      env = o.env,
      runs = { run(400, A, { job("rust", "success") }) },
      compare = { [A] = "ahead" },
      changed = function()
        return false
      end,
    })
    has(w.output, "rust=run", "full " .. o.why .. ": rust runs")
    has(w.text, "a full run was asked for " .. o.why, "full: the reason")
    eq(#w.gh, 0, "full " .. o.why .. ": GitHub is not asked")
  end

  -- usage
  for _, argv in ipairs({
    { "reuse" },
    { "reuse", "--job=bad key=x" },
    { "reuse", "--job=rust=-x" },
    { "reuse", "--job=rust=a", "--job=rust=b" },
    { "reuse", "--job=rust=a", "--name=ui:ui" },
    { "reuse", "--job=rust=a", "--runs=0" },
    { "superseded", "--ref=../x" },
  }) do
    local w = world({ argv = argv })
    eq(w.code, 2, "usage: " .. table.concat(argv, " "))
  end
  do
    local w = world({ argv = { "reuse", "--job=rust=a" }, env = { GITHUB_WORKFLOW_REF = "" } })
    eq(w.code, 2, "usage: no workflow file")
  end

  -- superseded
  do
    local w = world({ argv = { "superseded" }, tip = X, compare = { [B .. "..." .. X] = "ahead" } })
    eq(w.code, 0, "superseded: exit")
    eq(w.output, "superseded=true\nby=" .. X .. "\n", "superseded: a descendant on main")
    w = world({ argv = { "superseded" }, tip = B })
    eq(w.output, "superseded=false\nby=\n", "superseded: the tip itself")
    w = world({ argv = { "superseded" }, tip = X, compare = { [B .. "..." .. X] = "diverged" } })
    eq(w.output, "superseded=false\nby=\n", "superseded: another line")
    w = world({ argv = { "superseded", "--ref=release" } })
    eq(w.output, "superseded=false\nby=\n", "superseded: an error answers false")
    has(w.text, "the tip of release could not be read", "superseded: and says so")
  end

  for k, v in pairs(saved) do
    reuse.deps[k] = v
  end
end
