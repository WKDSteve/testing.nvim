---@module 'testing.export.call'
---@brief `testing call fleet|repo`: print a document of the contract `testing-export/1` on stdout.
---@description
--- ```
--- testing call fleet [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]
---                    [--export] [--remote] [--state-dir=<dir>]
--- testing call repo [<dir>] [--export] [--remote] [--state-dir=<dir>]
--- ```
---
--- One line of canonical JSON (keys sorted, no whitespace) on stdout, nothing else; a problem is one line on stderr.
--- The local form (default) carries the absolute `root` of the repositories, for a process on this machine;
--- `--export` gives the form of an export folder: no absolute path, refused when the leak detector still finds one,
--- and only the repositories the data classes of this device release (`public`, `internal`; `lib.nvim.data_classes`,
--- fail-closed as `testing export --out`): `fleet` counts the others in `excluded_by` without naming them, `repo` of
--- a repository that is not released prints nothing and exits 2. A shallow clone among them (its key differs from that
--- of a full clone) is a warning on stderr, never part of the document.
--- `--remote` asks the CI adapter (`testing ci remote`: GitHub, network, a read-only token); without it `ci_remote`
--- is `null` (not asked); asked without a record it is `state = "unknown"`. Runs nothing: no suite, no pipeline, no `.testing.lua`; it writes nothing
--- either, except the CI adapter's ETag cache in the state directory with `--remote`.
---
--- Exit codes: 0 the document was printed, 2 usage (an unknown method or option, a root that is not a directory, no
--- repository) or `repo --export` of a repository the data classes do not release, 3 the document could not be built
--- (it would leak a path, it is too large, an internal error).
---
--- The hub of testing-desktop asks the way `appkit_hub::engine::CliEngine` asks every engine: `call hello` first
--- (what this engine is, `testing.export.hello`), then `call <method> --params=-` with one JSON object on stdin
--- instead of the switches (`M.PARAMS`). The engine is its child with an allow-listed environment: the repositories
--- root comes in `$TESTING_REPOS_ROOT` (what `fleet` reads when it is given no root, and where `repo` and `finding`
--- look for `params.repo`, a key of `fleet`), and the state folder, the data classes and the metrics file (`state_dir`,
--- `areas`, `metrics`) as parameters, never through the environment, since the child cannot find them by itself.

local M = {}

M.EXIT_OK, M.EXIT_USAGE, M.EXIT_INFRA = 0, 2, 3

M.METHODS = { fleet = true, repo = true, finding = true, hello = true }

---The variable that names the repositories root of a call without one (the hub sets it for its child).
M.ROOT_VAR = "TESTING_REPOS_ROOT"

---The most bytes of the parameters on stdin; more is a usage error, not a cut.
M.MAX_PARAMS = 64 * 1024

---The length of a token in `params.github_token`: longer than `testing.export.SECRET_MIN`, so that it is redacted.
M.TOKEN_MIN = 20
M.TOKEN_MAX = 512
---The longest `params.remote_max_age`, in seconds: a day.
M.REMOTE_MAX_AGE_MAX = 86400

---The keys of `--params`, with their type and the methods that take them.
---@type table<string, { type: "string"|"boolean"|"number"|"names", methods: table<string, true> }>
M.PARAMS = {
  state_dir = { type = "string", methods = { fleet = true, repo = true, finding = true } },
  areas = { type = "string", methods = { fleet = true, repo = true, finding = true } },
  metrics = { type = "string", methods = { repo = true } },
  export = { type = "boolean", methods = { fleet = true, repo = true } },
  remote = { type = "boolean", methods = { fleet = true, repo = true } },
  github_token = { type = "string", methods = { fleet = true, repo = true } },
  remote_max_age = { type = "number", methods = { fleet = true, repo = true } },
  repo = { type = "string", methods = { repo = true, finding = true } },
  fp = { type = "string", methods = { finding = true } },
  include = { type = "names", methods = { fleet = true } },
  exclude = { type = "names", methods = { fleet = true } },
}

M.USAGE = table.concat({
  "usage: testing call fleet [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]",
  "                          [--export] [--remote] [--state-dir=<dir>]",
  "       testing call repo [<dir>] [--export] [--remote] [--state-dir=<dir>]",
  "       testing call finding [<dir>] [--fp=<16 hex>] [--state-dir=<dir>]",
  "       testing call hello",
  "       testing call fleet|repo|finding --params=-|<json>",
  "  hello               what this engine is: its build, the versions of the contract, what it answers",
  "  fleet               one row per repository (document testing-export/1, kind fleet)",
  "  repo                one repository with its red cases (kind repo; <dir> defaults to the current directory)",
  "  finding             the findings of the last run of a repository (documents testing-finding/1), one line each;",
  "                      with --fp only that one (exit 2 when there is none, or the data classes do not release it);",
  "                      with --params one document instead (kind findings), also when there is no finding",
  "  --repos-root=<dir>  the repositories below <dir> (workflows or a .testing.lua; no vault; repeatable)",
  "  --include=<names>   also these directory names below --repos-root (besides lib.nvim)",
  "  --exclude=<names>   leave these directory names out",
  "  --export            the export form: no absolute path, only the repositories the data classes of this",
  "                      device release (default: the local form with root, all repositories)",
  "  --remote            ask the CI adapter (GitHub); without it ci_remote is null",
  "  --state-dir=<dir>   the state directory (default: stdpath('state'))",
  "  --params=-|<json>   the request as one JSON object (on stdin with -), alone, in place of the options:",
  "                      state_dir, areas (the areas.json of the data classes), export, remote, include, exclude",
  "                      (fleet), repo (a key of fleet below $TESTING_REPOS_ROOT; repo, finding), fp (finding),",
  "                      metrics (the metrics.jsonl of the heavy runs; repo);",
  "                      with remote also github_token (on stdin only) and remote_max_age (whole seconds)",
  "  $TESTING_REPOS_ROOT the repositories root of fleet when it is given none",
  "  stdout: one line of canonical JSON; runs nothing (--remote: the adapter's ETag cache)",
  "  exit: 0 printed, 2 usage or a repository not released (repo --export), 3 the document could not be built",
}, "\n")

---@class Testing.Export.Call.Args
---@field method string
---@field roots string[]
---@field repos_roots string[]
---@field include string[]
---@field exclude string[]
---@field export boolean
---@field remote boolean
---@field github_token? string `params.github_token`: the token of the caller, on stdin only.
---@field remote_max_age? integer `params.remote_max_age`: seconds the adapter's stored answers are good for.
---@field state_dir? string
---@field fp? string
---@field help boolean
---@field params? string `--params`: `-` (stdin) or the JSON text itself.
---@field areas? string `params.areas`: the `areas.json` of the data classes.
---@field metrics? string `params.metrics`: the metrics file of the heavy runs (`testing.metrics`), for the part `metrics`.
---@field repo? string `params.repo`: the key of a repository below the repositories root.

local VALUED = {
  ["repos-root"] = true,
  include = true,
  exclude = true,
  ["state-dir"] = true,
  fp = true,
}
local FLEET_ONLY = { ["repos-root"] = true, include = true, exclude = true }

---@param argv string[] The arguments after `call`.
---@return Testing.Export.Call.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Export.Call.Args
  local args = {
    method = "",
    roots = {},
    repos_roots = {},
    include = {},
    exclude = {},
    export = false,
    remote = false,
    help = false,
  }
  local first = argv[1]
  if first == nil or first == "-h" or first == "--help" then
    args.help = true
    return args
  end
  if not M.METHODS[first] then
    return nil, ("unknown method %s (fleet, repo, finding, hello)"):format(first)
  end
  args.method = first
  -- `hello` takes nothing; `--params` stands alone (the request is the whole of it, not added to switches)
  local others = 0
  local i = 2
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if not (a == "-h" or key == "help" or key == "params") then
      others = others + 1
    end
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "params" then
      if args.method == "hello" then
        return nil, "hello takes no parameters"
      end
      if value == nil or value == "" then
        return nil, "--params needs - (stdin) or a JSON object"
      end
      if args.params then
        return nil, "--params is given twice"
      end
      args.params = value
    elseif args.method == "hello" then
      return nil, ("hello takes no arguments (got %s)"):format(a)
    elseif (key == "export" or key == "remote") and value == nil then
      args[key] = true
    elseif key and VALUED[key] then
      if key == "fp" and args.method ~= "finding" then
        return nil, "--fp is an option of finding"
      end
      if FLEET_ONLY[key] and args.method ~= "fleet" then
        return nil, ("--%s is an option of fleet, not of %s"):format(key, args.method)
      end
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "state-dir" then
        args.state_dir = value
      elseif key == "fp" then
        if not value:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
          return nil, "--fp needs 16 hex characters"
        end
        args.fp = value:lower()
      else
        -- the one VALUED key left: include or exclude
        local list = key == "include" and args.include or args.exclude
        for _, name in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
          if not require("testing.deps").is_valid_name(name) then
            return nil, ("--%s: %s is not a directory name"):format(key, name)
          end
          list[#list + 1] = name
        end
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.roots[#args.roots + 1] = a
    end
    i = i + 1
  end
  if args.params and others > 0 then
    return nil, "--params stands alone: the request holds every option"
  end
  if (args.method == "repo" or args.method == "finding") and #args.roots > 1 then
    return nil, args.method .. " takes one directory"
  end
  return args
end

---Is this a path the engine may be handed by its caller: whole (absolute), with no `..` and no control character?
---@param path string
---@return boolean
local function whole_path(path)
  if path == "" or path:find("%c") then
    return false
  end
  for part in path:gmatch("[^/\\]+") do
    if part == ".." then
      return false
    end
  end
  return path:match("^%a:[/\\]") ~= nil or path:sub(1, 1) == "/" or path:match("^[/\\][/\\]") ~= nil
end

---A key of `fleet`: `<name>-<12 hex>` (`testing.export.repo_key`), nothing that could name a path.
---@param key string
---@return boolean
local function plain_key(key)
  return #key <= 140 and key:match("^[%w_.%-]+%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

---Take a request of `--params` into the arguments: one JSON object, each key of `M.PARAMS` for this method with its
---type, nothing else.
---@param args Testing.Export.Call.Args
---@param text string
---@return Testing.Export.Call.Args|nil args
---@return string|nil problem
function M.apply_params(args, text)
  if #text > M.MAX_PARAMS then
    return nil, ("the parameters are larger than %d bytes"):format(M.MAX_PARAMS)
  end
  local okd, req = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  -- `[]` decodes to the same empty table as `{}`: the text itself must be an object
  if
    not okd
    or type(req) ~= "table"
    or not text:match("^%s*{")
    or (next(req) ~= nil and vim.islist(req))
  then
    return nil, "the parameters are not a JSON object"
  end
  local keys = vim.tbl_keys(req)
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = req[k]
    local spec = type(k) == "string" and M.PARAMS[k] or nil
    if not spec then
      return nil, ("unknown parameter %s"):format(tostring(k))
    end
    if not spec.methods[args.method] then
      return nil, ("%s is not a parameter of %s"):format(k, args.method)
    end
    if spec.type == "names" then
      if type(v) ~= "table" or (next(v) ~= nil and not vim.islist(v)) then
        return nil, ("%s must be a list of directory names"):format(k)
      end
      for _, name in ipairs(v) do
        if type(name) ~= "string" or not require("testing.deps").is_valid_name(name) then
          return nil, ("%s: %s is not a directory name"):format(k, tostring(name))
        end
        table.insert(args[k], name)
      end
    elseif type(v) ~= spec.type then
      return nil, ("%s must be a %s"):format(k, spec.type)
    elseif k == "state_dir" or k == "areas" or k == "metrics" then
      if not whole_path(v) then
        return nil, ("%s must be a whole path, without .. and control characters"):format(k)
      end
      args[k] = v
    elseif k == "repo" then
      if not plain_key(v) then
        return nil, "repo must be a key of fleet (<name>-<12 hex>)"
      end
      args.repo = v
    elseif k == "fp" then
      if not v:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
        return nil, "fp needs 16 hex characters"
      end
      args.fp = v:lower()
    elseif k == "github_token" then
      -- on stdin only: an argument is readable by every process of the machine. The texts here never quote it.
      if args.params ~= "-" then
        return nil, "github_token is taken on stdin only (--params=-)"
      end
      if #v < M.TOKEN_MIN or #v > M.TOKEN_MAX or not v:match("^[%w_%-]+$") then
        return nil, "github_token is not a GitHub token"
      end
      args.github_token = v
    elseif k == "remote_max_age" then
      if v ~= math.floor(v) or v < 1 or v > M.REMOTE_MAX_AGE_MAX then
        return nil,
          ("remote_max_age must be whole seconds from 1 to %d"):format(M.REMOTE_MAX_AGE_MAX)
      end
      args.remote_max_age = v
    else
      args[k] = v
    end
  end
  if (args.github_token or args.remote_max_age) and not args.remote then
    return nil, "github_token and remote_max_age belong to remote = true"
  end
  -- the findings always ask the data classes; fleet and repo only in the export form
  if args.areas and not args.export and args.method ~= "finding" then
    return nil, "areas belongs to the export form (export = true)"
  end
  return args
end

---The repository below the repositories root whose key is `key`, as `fleet` finds them. The key starts with the
---directory name (`testing.export.repo_key`), so only the directories of that name are asked for theirs: a key costs
---git calls, and a root holds dozens of repositories.
---@param root string
---@param key string
---@return string|nil dir
local function dir_of_key(root, key)
  local export = require("testing.export")
  local name = key:match("^(.*)%-%x+$")
  local dirs = export.resolve({ repos_roots = { root } })
  for _, dir in ipairs(dirs or {}) do
    if vim.fs.basename(dir):gsub("[^%w_.%-]", "_") == name then
      local okk, k = pcall(export.deps.key, dir)
      if okk and k == key then
        return dir
      end
    end
  end
  return nil
end

---`testing call finding [<dir>] [--fp=<fp>]`: the findings of a repository as documents of `testing-finding/1`, one
---line each. A hub reads one document per question, so a request by `--params` gets them in one document (kind
---`findings`), which is also there when there is no finding.
---@param args Testing.Export.Call.Args
---@param state_dir? string
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param as_document? boolean
---@return integer exit_code
function M.finding(args, state_dir, sv, as_document)
  local dir = args.roots[1] or "."
  if vim.fn.isdirectory(dir) ~= 1 then
    sv.err(("testing call: %s is not a directory"):format(dir))
    return M.EXIT_USAGE
  end
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("([^:/])/+$", "%1")
  local finding = require("testing.finding")
  local docs, err, kind
  require("testing.export").with_secrets(function()
    docs, err, kind = finding.collect({
      dir = dir,
      state_dir = state_dir,
      classes = args.areas and { path = args.areas } or nil,
    })
  end)
  if not docs then
    sv.err("testing call: " .. tostring(err))
    return kind == finding.REFUSED and M.EXIT_USAGE or M.EXIT_INFRA
  end
  local shown = {}
  for _, d in ipairs(docs) do
    if not args.fp or d.fp == args.fp then
      shown[#shown + 1] = d
    end
  end
  if args.fp and #shown == 0 then
    sv.err(("testing call: no finding %s in the last run of this repository"):format(args.fp))
    return M.EXIT_USAGE
  end
  if as_document then
    local export = require("testing.export")
    -- a key costs git calls: the one of the request was just found to be this repository's
    local key = args.repo
    if not key then
      local okk, k = pcall(export.deps.key, dir)
      if not okk then
        sv.err("testing call: the key of this repository is not known")
        return M.EXIT_INFRA
      end
      key = k
    end
    shown = { export.findings(key, shown) }
  end
  for _, d in ipairs(shown) do
    local text, eerr = require("testing.export").encode(d)
    if not text then
      sv.err("testing call: " .. tostring(eerr))
      return M.EXIT_INFRA
    end
    sv.out(text)
  end
  return M.EXIT_OK
end

---`testing call ...`.
---@param argv string[] The arguments after `call`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string, env?: table<string, string|nil>, stdin?: fun(): string|nil } `stdin` replaces the read of the parameters (specs).
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing call: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local export = require("testing.export")
  if args.method == "hello" then
    local text, eerr = export.encode(export.hello())
    if not text then
      sv.err("testing call: " .. tostring(eerr))
      return M.EXIT_INFRA
    end
    sv.out(text)
    return M.EXIT_OK
  end
  local by_params = args.params ~= nil
  if args.params then
    local text = args.params --[[@as string]]
    if text == "-" then
      -- one byte over the limit is enough to tell a request that is too large
      local read = sv.stdin or function()
        return io.stdin:read(M.MAX_PARAMS + 1)
      end
      local okr, got = pcall(read)
      text = okr and type(got) == "string" and got or ""
    end
    args, problem = M.apply_params(args, text)
    if not args then
      sv.err("testing call: " .. tostring(problem))
      return M.EXIT_USAGE
    end
  end
  -- the repositories root of the caller (`$TESTING_REPOS_ROOT`, read by the entry and handed down)
  local root = sv.env and sv.env[M.ROOT_VAR]
  root = type(root) == "string" and root ~= "" and root or nil
  if root and vim.fn.isdirectory(root) ~= 1 then
    sv.err(("testing call: $%s is not a directory"):format(M.ROOT_VAR))
    return M.EXIT_USAGE
  end
  if args.repo then
    if not root then
      sv.err(("testing call: repo needs $%s"):format(M.ROOT_VAR))
      return M.EXIT_USAGE
    end
    local dir = dir_of_key(root, args.repo)
    if not dir then
      sv.err(("testing call: no repository %s below $%s"):format(args.repo, M.ROOT_VAR))
      return M.EXIT_USAGE
    end
    args.roots = { dir }
  elseif args.method == "fleet" and #args.roots == 0 and #args.repos_roots == 0 and root then
    args.repos_roots = { root }
  end
  local state_dir = args.state_dir
      and vim.fs.normalize(vim.fn.fnamemodify(args.state_dir, ":p")):gsub("([^:/])/+$", "%1")
    or sv.state_dir
  if args.method == "finding" then
    return M.finding(args, state_dir, sv, by_params)
  end
  ---@type Testing.Export.Opts
  local opts = {
    roots = args.roots,
    repos_roots = args.repos_roots,
    include = args.include,
    exclude = args.exclude,
    form = args.export and "export" or "local",
    state_dir = state_dir,
    remote = args.remote,
    github_token = args.github_token,
    remote_max_age = args.remote_max_age,
    -- the metrics of the caller (`params.metrics`, repo); nil: the file the environment names
    metrics_file = args.metrics,
    -- the data classes of the caller's `areas.json` (`params.areas`); nil: this device's own file
    classes = args.areas and { path = args.areas } or nil,
    -- a shallow clone (its key differs from a full clone's): on stderr, never in the document
    warn = function(msg)
      sv.err("testing call: warning: " .. msg)
    end,
  }
  -- what is a usage problem (a directory that is not there, nothing found) is told apart from a build failure
  if args.method == "fleet" then
    for _, dir in ipairs(vim.list_extend(vim.list_slice(args.roots, 1), args.repos_roots)) do
      if vim.fn.isdirectory(dir) ~= 1 then
        sv.err(("testing call: %s is not a directory"):format(dir))
        return M.EXIT_USAGE
      end
    end
    local dirs, info = export.resolve(opts)
    if not dirs or #dirs == 0 then
      sv.err("testing call: " .. (dirs and "no repository found" or tostring(info)))
      return M.EXIT_USAGE
    end
    ---@cast info { excluded: string[], missing: string[] }
    if #info.missing > 0 then
      sv.err(
        "testing call: included but not below any --repos-root: "
          .. table.concat(info.missing, ", ")
      )
    end
  else
    local dir = args.roots[1] or "."
    if vim.fn.isdirectory(dir) ~= 1 then
      sv.err(("testing call: %s is not a directory"):format(dir))
      return M.EXIT_USAGE
    end
  end
  local doc, err, kind
  if args.method == "fleet" then
    doc, err = export.fleet(opts)
  else
    doc, err, kind = export.repo(args.roots[1] or ".", opts)
  end
  if not doc then
    sv.err("testing call: " .. tostring(err))
    return kind == export.REFUSED and M.EXIT_USAGE or M.EXIT_INFRA
  end
  local text, eerr = export.encode(doc)
  if not text then
    sv.err("testing call: " .. tostring(eerr))
    return M.EXIT_INFRA
  end
  -- as `testing export`: an export form that released less than asked for says why (no areas.json, an unusable one)
  if type(doc.classes) == "table" and type(doc.classes.problem) == "string" then
    sv.err("testing call: note: " .. doc.classes.problem)
  end
  sv.out(text)
  return M.EXIT_OK
end

return M
