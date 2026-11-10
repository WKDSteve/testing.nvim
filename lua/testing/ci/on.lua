-- @cache-env TESTING_CI_TARGET
---@module 'testing.ci.on'
---@brief `testing ci --on=host,linux,devcontainer`: the pipeline on this machine and in containers, one after the other.
---@description
--- ```
--- testing ci --on=<host|linux|devcontainer>[,...] [the options of testing ci]
--- ```
---
--- `host` is the run as without `--on` (`testing.ci`). A container target starts the same run inside a container of the
--- engine of `testing.container` (Podman): `testing ci --on=host` again, there, on the repository mounted READ-ONLY at
--- `/repo` (the runner's checkout and every dependency checkout too, `$<NAME>_DIR` pointing at them), with one output
--- folder that is writable (`/out`: the document and the state of the inner run). No network unless
--- `ci.container.network = true`; the container is called `testing-ci-<repo>-<target>` and removed when it ends.
---
---   linux         the image of `containers/ci/Containerfile` (`localhost/testing-ci:1`: nvim, stylua, luacheck and git at
---                 the versions of the hosted CI), or `ci.container.image`
---   devcontainer  the image of the repository's `.devcontainer/devcontainer.json` (`image`, or `build.dockerfile`,
---                 built once and tagged by the digest of the Dockerfile); it must have nvim and the tools of the steps
---
--- Without the engine, its machine or the image the target is exit 3 with what to do; the targets before it have run.
--- The document of each container run comes back, carries `target` and `image` (the image id: what the run proved is
--- the run in that image) and the commit and tree of this checkout (the inner git sees a read-only mount), and is kept
--- beside the host's: `ci.<target>.json`, and `ci-<profile>.<target>.json` for a complete run, the proof
--- `testing ci verify --on=<target>` reads. The host document gets `targets` with every container document of the run.
--- The report ends with a table: a row per step, a column per target. The exit code is the worst of the targets.

local M = {}

M.TARGETS = { host = true, linux = true, devcontainer = true }
M.ORDER = { "host", "linux", "devcontainer" }

---The image of the `linux` target (`containers/ci/Containerfile`).
M.DEFAULT_IMAGE = "localhost/testing-ci:1"

---How long the run in a container may take, all steps together (each step keeps its own deadline in there).
M.TIMEOUT_MS = 2 * 60 * 60 * 1000

---The inner run: set in the container, read by `testing.ci` (the document says where it ran; the repository is
---read-only there, so nothing is written into it).
M.TARGET_ENV = "TESTING_CI_TARGET"

---`--on=<a,b>` as a list in the order given, without repeats; nil and the problem for a name that is not a target.
---@param value string
---@return string[]|nil targets
---@return string|nil problem
function M.parse(value)
  local out, seen = {}, {}
  for _, t in ipairs(vim.split(value or "", ",", { trimempty = true })) do
    t = vim.trim(t)
    if not M.TARGETS[t] then
      return nil, ("--on: unknown target %s (targets: %s)"):format(t, table.concat(M.ORDER, ", "))
    end
    if not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  if #out == 0 then
    return nil, "--on names no target"
  end
  return out
end

---@param argv string[]
---@return string[] argv without `--on`
local function without_on(argv)
  local out, i = {}, 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      vim.list_extend(out, vim.list_slice(argv, i))
      break
    end
    if a == "--on" then
      i = i + 1
    elseif not a:match("^%-%-on=") then
      out[#out + 1] = a
    end
    i = i + 1
  end
  return out
end
M._without_on = without_on

---A comment-free JSON text of a devcontainer.json (JSONC: `//` and `/* */` outside strings, trailing commas).
---@param text string
---@return string
local function strip_jsonc(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == '"' then
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    elseif text:sub(i, i + 1) == "//" then
      local e = text:find("\n", i, true) or (n + 1)
      i = e
    elseif text:sub(i, i + 1) == "/*" then
      local _, e = text:find("*/", i + 2, true)
      i = (e or n) + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return (table.concat(out):gsub(",(%s*[}%]])", "%1"))
end
M._strip_jsonc = strip_jsonc

---@param repo string
---@param target string
---@return string
function M.container_name(repo, target)
  return ("testing-ci-%s-%s"):format(repo:lower():gsub("[^%w%-]", "-"), target)
end

---The image of a target, built when it is a devcontainer with a Dockerfile. Nil and why (and the exit: 2 a usage
---problem of the repository, 3 infrastructure).
---@param target string
---@param root string
---@param pipeline table
---@param copts table `testing.container` options (engine, run).
---@return string|nil image
---@return string|nil why
---@return integer|nil exit
function M.image_of(target, root, pipeline, copts)
  local cfg = pipeline.container or {}
  if target == "linux" then
    return cfg.image or M.DEFAULT_IMAGE
  end
  local dir = root .. "/.devcontainer"
  local path = dir .. "/devcontainer.json"
  if not vim.uv.fs_stat(path) then
    path, dir = root .. "/.devcontainer.json", root
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, "the repository has no .devcontainer/devcontainer.json", 2
  end
  local text = f:read("*a")
  f:close()
  local ok, conf = pcall(vim.json.decode, strip_jsonc(text))
  if not ok or type(conf) ~= "table" then
    return nil, ("%s is not JSON"):format(path), 2
  end
  if type(conf.image) == "string" and conf.image ~= "" then
    return conf.image
  end
  local build = type(conf.build) == "table" and conf.build or {}
  local dockerfile = type(conf.dockerFile) == "string" and conf.dockerFile or build.dockerfile
  if type(dockerfile) ~= "string" then
    return nil, ("%s names no image and no build.dockerfile"):format(path), 2
  end
  local file = vim.fs.normalize(dir .. "/" .. dockerfile)
  local context =
    vim.fs.normalize(dir .. "/" .. (type(build.context) == "string" and build.context or "."))
  local df = io.open(file, "rb")
  if not df then
    return nil, ("the Dockerfile %s of the devcontainer cannot be read"):format(file), 2
  end
  local content = df:read("*a")
  df:close()
  local tag = ("localhost/testing-devcontainer-%s:%s"):format(
    vim.fs.basename(root):lower():gsub("[^%w%-]", "-"),
    vim.fn.sha256(content):sub(1, 12)
  )
  local container = require("testing.container")
  local here = container.available(vim.tbl_extend("force", copts, { image = tag }))
  if here then
    return tag
  end
  -- built once (the build may use the network; the run never does unless the pipeline says so)
  local res = container.build(tag, file, context, copts)
  if res.code ~= 0 then
    return nil,
      ("building the devcontainer image failed (exit %d): %s"):format(
        res.code,
        vim.trim((res.stderr or ""):sub(-400))
      ),
      3
  end
  return tag
end

---The checkouts a run in the container needs read-only, besides the repository: the runner's own and every
---dependency (lib.nvim always). `mounts` host -> container path, `env` the `$<NAME>_DIR` that point at them.
---@param root string
---@param pipeline table
---@return { mounts: table<string, string>, env: table<string, string>, runner: string }|nil
---@return string|nil why
local function checkouts(root, pipeline)
  local deps = require("testing.deps")
  local mounts, env = { [root] = "/repo" }, {}
  local self = deps.self_dir()
  local runner = "/repo"
  if vim.fs.normalize(self) ~= vim.fs.normalize(root) then
    mounts[self] = "/testing"
    runner = "/testing"
  end
  local names = vim.deepcopy(pipeline.deps or deps.declared(root))
  if not vim.tbl_contains(names, "lib.nvim") then
    names[#names + 1] = "lib.nvim"
  end
  local resolved, failures = deps.resolve_all(names, root)
  if #failures > 0 then
    return nil, failures[1]
  end
  for _, r in ipairs(resolved) do
    local where = "/deps/" .. r.name:gsub("[^%w%._%-]", "_")
    mounts[r.dir] = where
    env[deps.env_name(r.name)] = where
  end
  return { mounts = mounts, env = env, runner = runner }
end

---The options of the inner run: what `testing ci` got, without `--on`, `--json`, `--state-dir`, `--root`, `--events`
---and `--junit` (they name places of this machine).
---@param argv string[]
---@return string[]
local function inner_options(argv)
  local out, i = {}, 1
  local drop = {
    json = true,
    ["state-dir"] = true,
    root = true,
    events = true,
    junit = true,
    ["suite-events"] = true,
  }
  argv = without_on(argv)
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      vim.list_extend(out, vim.list_slice(argv, i))
      break
    end
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if key and drop[key] then
      if value == nil then
        i = i + 1
      end
    else
      out[#out + 1] = a
    end
    i = i + 1
  end
  return out
end
M._inner_options = inner_options

---Run the pipeline in a container target. Exit code, the document (nil when the run left none) and the lines to
---report when it could not run.
---@param target string
---@param argv string[] The arguments of `testing ci`.
---@param root string
---@param pipeline table
---@param facts table The git facts of this checkout (`testing.ci.internal.git_facts`).
---@param sv table
---@return integer exit
---@return table|nil doc
---@return string[] problems
function M.run_target(target, argv, root, pipeline, facts, sv)
  local container = require("testing.container")
  local copts = vim.deepcopy(sv.container or {})
  local image, why, code = M.image_of(target, root, pipeline, copts)
  if not image then
    return code or 3, nil, { ("%s: %s"):format(target, why) }
  end
  copts.image = image
  local ok, reason = container.available(copts)
  if not ok then
    return 3,
      nil,
      {
        ("%s: %s"):format(target, reason),
        target == "linux"
            and ("build the image: podman build --tag %s containers/ci (in the testing.nvim checkout), or set ci.container.image"):format(
              M.DEFAULT_IMAGE
            )
          or "start the engine's machine (podman machine start) or build the devcontainer image",
      }
  end
  local digest, dwhy = container.digest(copts)
  if not digest then
    return 3, nil, { ("%s: the image id cannot be read: %s"):format(target, dwhy) }
  end
  local co, cwhy = checkouts(root, pipeline)
  if not co then
    return 3, nil, { ("%s: %s"):format(target, cwhy) }
  end
  local out_dir = vim.fs.normalize(vim.fn.tempname()) .. "-ci-" .. target
  vim.fn.mkdir(out_dir .. "/state", "p")
  local repo = vim.fs.basename(root)
  local name = M.container_name(repo, target)
  container.remove(name, copts)
  local env = vim.tbl_extend("force", co.env, {
    [M.TARGET_ENV] = target,
    -- the outer run was trusted (scripts/testing.lua asked before anything ran)
    TESTING_TRUST = "1",
    -- the mounts belong to another user in there: git must still read them
    GIT_CONFIG_COUNT = "1",
    GIT_CONFIG_KEY_0 = "safe.directory",
    GIT_CONFIG_VALUE_0 = "*",
    HOME = "/tmp/home",
  })
  local command = {
    "nvim",
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    co.runner .. "/scripts/testing.lua",
    "ci",
    "--root=/repo",
    "--state-dir=/out/state",
    "--json=/out/ci.json",
    "--no-agent",
  }
  local rest = inner_options(argv)
  -- the options of the outer run, before a `--` of the suite options
  vim.list_extend(command, rest)
  local res = container.run(
    command,
    vim.tbl_extend("force", copts, {
      mounts = co.mounts,
      writable = { [out_dir] = "/out" },
      env = env,
      network = (pipeline.container or {}).network == true,
      name = name,
      -- the output folder belongs to the user of this machine: root in a rootless container maps to that user
      user = "0",
      workdir = "/repo",
      timeout_ms = M.TIMEOUT_MS,
    })
  )
  local say = sv.out or function() end
  for line in ((res.stdout or "") .. (res.stderr or "")):gmatch("[^\r\n]+") do
    say(("[%s] %s"):format(target, line))
  end
  local f = io.open(out_dir .. "/ci.json", "rb")
  local doc
  if f then
    local okd, d = pcall(vim.json.decode, f:read("*a"))
    f:close()
    doc = okd and type(d) == "table" and d or nil
  end
  vim.fn.delete(out_dir, "rf")
  if not doc then
    local tail = vim.trim(((res.stderr or "") ~= "" and res.stderr or res.stdout or ""):sub(-300))
    local missing = res.code == 127 and " (is nvim in the image?)" or ""
    return 3,
      nil,
      {
        ("%s: the run in the container left no document (exit %d%s): %s"):format(
          target,
          res.code,
          missing,
          tail
        ),
      }
  end
  doc.target = target
  doc.image = digest
  doc.image_name = image
  -- the inner git sees a read-only mount of another owner (a worktree's .git file may not even resolve there)
  doc.commit = facts.commit or vim.NIL
  doc.tree = facts.tree or vim.NIL
  doc.dirty = facts.dirty == nil and vim.NIL or facts.dirty
  local exit = tonumber(doc.exit) or res.code
  if exit < 0 or exit > 3 then
    exit = 3
  end
  return exit, doc, {}
end

---Keep the document of a target beside the host's: `ci.<target>.json`, and the proof `ci-<profile>.<target>.json` for a
---complete green run (as `testing.ci` does for its own).
---@param doc table
---@param root string
---@param state_dir? string
---@return string[] notes
function M.keep(doc, root, state_dir)
  local dir = require("testing.state").dir(root, { state_dir = state_dir })
  local text = require("lib.nvim.json.canonical").encode(doc) .. "\n"
  local paths = { ("%s/ci.%s.json"):format(dir, doc.target) }
  local complete = type(doc.steps) == "table"
    and #doc.steps > 0
    and doc.partial ~= true
    and doc.head_moved ~= true
    and doc.tree_changed ~= true
  if complete and type(doc.profile) == "string" then
    paths[#paths + 1] = ("%s/ci-%s.%s.json"):format(dir, doc.profile, doc.target)
  end
  local notes = {}
  for _, path in ipairs(paths) do
    local ok, err = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
    if not ok then
      notes[#notes + 1] = ("cannot write %s: %s"):format(path, tostring(err))
    end
  end
  return notes
end

---The table at the end: a row per step, a column per target, the verdict last.
---@param order string[] The targets in the order they ran.
---@param docs table<string, table|false> The document of each target (false: none).
---@return string[]
function M.table(order, docs)
  local rows, seen = {}, {}
  for _, t in ipairs(order) do
    for _, s in ipairs(type(docs[t]) == "table" and docs[t].steps or {}) do
      if type(s) == "table" and type(s.name) == "string" and not seen[s.name] then
        seen[s.name] = true
        rows[#rows + 1] = s.name
      end
    end
  end
  local width = #"verdict"
  for _, r in ipairs(rows) do
    width = math.max(width, #r)
  end
  local cols = {}
  for _, t in ipairs(order) do
    cols[t] = math.max(#t, 13)
  end
  local function line(first, cells)
    local parts = { first .. string.rep(" ", width - #first) }
    for i, t in ipairs(order) do
      parts[#parts + 1] = cells[i] .. string.rep(" ", cols[t] - #cells[i])
    end
    return (table.concat(parts, "  "):gsub("%s+$", ""))
  end
  local out = { line("step", order) }
  for _, r in ipairs(rows) do
    local cells = {}
    for i, t in ipairs(order) do
      local state = "-"
      for _, s in ipairs(type(docs[t]) == "table" and docs[t].steps or {}) do
        if type(s) == "table" and s.name == r then
          state = tostring(s.state)
        end
      end
      cells[i] = state
    end
    out[#out + 1] = line(r, cells)
  end
  local verdicts = {}
  for i, t in ipairs(order) do
    verdicts[i] = type(docs[t]) == "table" and tostring(docs[t].verdict) or "infra"
  end
  out[#out + 1] = line("verdict", verdicts)
  return out
end

---`testing ci --on=...` (after `testing.ci.parse`).
---@param argv string[] The arguments of `testing ci`.
---@param args table The parsed arguments (`args.on`).
---@param root string
---@param sv table
---@return integer exit
function M.main(argv, args, root, sv)
  local ci = require("testing.ci")
  local out, err = sv.out, sv.err
  local pipeline, problems = require("testing.ci.schema").load(root)
  if not pipeline then
    for _, p in ipairs(problems or {}) do
      err("testing ci: " .. p)
    end
    return ci.EXIT_USAGE
  end
  local state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p") or sv.state_dir
  local facts = ci.internal.git_facts(root)
  local docs, exits, worst = {}, {}, 0
  local host_doc
  for _, target in ipairs(args.on) do
    local code, doc
    if target == "host" then
      out("== on host")
      -- the sentinel is the last line of the whole run (all targets green), never the host's alone
      local host_sv = vim.tbl_extend("force", sv, {
        out = function(line)
          if line ~= ci.SENTINEL then
            out(line)
          end
        end,
      })
      code = ci.main(without_on(argv), host_sv)
      local dir = require("testing.state").dir(root, { state_dir = state_dir })
      local f = io.open(dir .. "/ci.json", "rb")
      if f then
        local okd, d = pcall(vim.json.decode, f:read("*a"))
        f:close()
        host_doc = okd and type(d) == "table" and d or nil
      end
      doc = host_doc
    else
      out(("== on %s"):format(target))
      local why
      code, doc, why = M.run_target(target, argv, root, pipeline, facts, sv)
      for _, line in ipairs(why) do
        err("testing ci: " .. line)
      end
      if doc then
        for _, note in ipairs(M.keep(doc, root, state_dir)) do
          err("testing ci: " .. note)
          code = math.max(code, ci.EXIT_INFRA)
        end
      end
    end
    docs[target] = doc or false
    exits[target] = code
    worst = math.max(worst, code)
  end
  -- the host's document carries the container documents of this run
  if host_doc then
    host_doc.targets = {}
    for _, t in ipairs(args.on) do
      if t ~= "host" then
        host_doc.targets[t] = docs[t] or { target = t, verdict = "infra", exit = exits[t] }
      end
    end
    local dir = require("testing.state").dir(root, { state_dir = state_dir })
    local text = require("lib.nvim.json.canonical").encode(host_doc) .. "\n"
    require("lib.nvim.fs.write.atomic")(dir .. "/ci.json", text, { mkdirp = true })
    if args.json then
      require("lib.nvim.fs.write.atomic")(
        vim.fn.fnamemodify(args.json, ":p"),
        text,
        { mkdirp = true }
      )
    end
  elseif args.json then
    local first = docs[args.on[1]]
    local merged = type(first) == "table" and vim.deepcopy(first)
      or {
        schema = ci.SCHEMA,
        repo = vim.fs.basename(root),
        verdict = "infra",
        exit = exits[args.on[1]],
      }
    merged.targets = {}
    for _, t in ipairs(args.on) do
      merged.targets[t] = docs[t] or { target = t, verdict = "infra", exit = exits[t] }
    end
    require("lib.nvim.fs.write.atomic")(
      vim.fn.fnamemodify(args.json, ":p"),
      require("lib.nvim.json.canonical").encode(merged) .. "\n",
      { mkdirp = true }
    )
  end
  out("")
  for _, line in ipairs(M.table(args.on, docs)) do
    out(line)
  end
  if worst == ci.EXIT_OK then
    out(ci.SENTINEL)
  end
  return worst
end

return M
