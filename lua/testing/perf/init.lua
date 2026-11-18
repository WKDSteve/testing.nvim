---@module 'testing.perf'
---@brief `testing perf`: run the feature sheets of one or many repositories and report every process they start.
---@description
--- The recurring performance check of a fleet of plugins (docs/PERF.md). It measures, it never gates: the exit code
--- says whether the run could be done, not whether the numbers are good.
---
---   testing perf [<root>...] [--all <dir>] [--sheet <id>]... [--feature <id>]... [--real <prog,...|all>]
---                [--interval <ms>] [--json <file>] [--markdown <file>] [--baseline <json>] [--keep-traces]
---   testing perf scan [<root>]    the spawn sites of a repository (`testing.perf.scan`), nothing runs
---
--- Exit codes: 0 the run is done (the report says what it found), 2 bad usage or every root refused (trust), 3 nothing
--- to run (no root with sheets).

local M = {}

M.USAGE = "usage: testing perf [<root>...] [--all <dir>] [--sheet <id>]... [--feature <id>]... [--real <prog,...|all>]\n"
  .. "                    [--interval <ms>] [--json <file>] [--markdown <file>] [--baseline <json>] [--keep-traces]\n"
  .. "       testing perf scan [<root>]"

---@param argv string[]
---@return table|nil opts, string|nil err
function M.parse(argv)
  local o = { roots = {}, sheets = {}, features = {} }
  local i = 1
  local function value(flag)
    local v = argv[i + 1]
    if v == nil or v:sub(1, 2) == "--" then
      return nil, flag .. " needs a value"
    end
    i = i + 1
    return v, nil
  end
  while i <= #argv do
    local a = argv[i]
    local flag, inline = a:match("^(%-%-[%w%-]+)=(.*)$")
    if flag then
      -- `--real=all` is `--real all`
      table.insert(argv, i + 1, inline)
      a = flag
    end
    local v, err
    if a == "--all" then
      v, err = value(a)
      o.all = v
    elseif a == "--sheet" then
      v, err = value(a)
      o.sheets[#o.sheets + 1] = v
    elseif a == "--feature" then
      v, err = value(a)
      o.features[#o.features + 1] = v
    elseif a == "--real" then
      v, err = value(a)
      if v then
        o.real = vim.tbl_filter(function(x)
          return x ~= ""
        end, vim.tbl_map(vim.trim, vim.split(v, ",", { plain = true })))
      end
    elseif a == "--interval" then
      v, err = value(a)
      o.interval_ms = tonumber(v)
      if v and (not o.interval_ms or o.interval_ms < 100 or o.interval_ms > 60000) then
        return nil, "--interval is a number of ms from 100 to 60000"
      end
    elseif a == "--json" then
      v, err = value(a)
      o.json = v
    elseif a == "--markdown" then
      v, err = value(a)
      o.markdown = v
    elseif a == "--baseline" then
      v, err = value(a)
      o.baseline = v
    elseif a == "--keep-traces" then
      o.keep_traces = true
    elseif a:sub(1, 1) == "-" then
      return nil, "unknown option " .. a
    else
      o.roots[#o.roots + 1] = a
    end
    if err then
      return nil, err
    end
    i = i + 1
  end
  return o, nil
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(vim.fn.fnamemodify(path, ":p")), "p")
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(text)
  f:close()
  return true, nil
end

local function machine()
  local u = (vim.uv or vim.loop).os_uname()
  return {
    host = (vim.uv or vim.loop).os_gethostname(),
    os = ("%s %s"):format(u.sysname, u.release),
    nvim = tostring(vim.version()),
    role = vim.env.NVIM_MACHINE_ROLE or "",
  }
end

---@param argv string[]
---@param sv { out: (fun(s: string)), err: (fun(s: string)), getenv?: (fun(n: string): string|nil), trust_check?: (fun(root: string): string|nil), run_root?: function }
---@return integer exit_code
function M.main(argv, sv)
  argv = vim.deepcopy(argv or {})
  if argv[1] == "--help" or argv[1] == "-h" or argv[1] == "help" then
    sv.out(M.USAGE)
    return 0
  end
  if argv[1] == "scan" then
    local root =
      vim.fs.normalize(vim.fn.fnamemodify(argv[2] or vim.fn.getcwd(), ":p")):gsub("/+$", "")
    local scan = require("testing.perf.scan")
    local lib = require("testing.deps").resolve("lib.nvim", root)
    local sites = scan.sites(root, lib and scan.spawning_modules(lib.dir) or nil)
    for _, s in ipairs(sites) do
      sv.out(("%s:%d\t%s\t%s"):format(s.file, s.line, s.what, s.text))
    end
    sv.out(("%d sites"):format(#sites))
    return 0
  end
  local o, err = M.parse(argv)
  if not o then
    sv.err("testing perf: " .. tostring(err) .. "\n" .. M.USAGE)
    return 2
  end
  local run = require("testing.perf.run")
  local roots = vim.deepcopy(o.roots)
  if o.all then
    vim.list_extend(roots, run.roots_below(o.all))
  end
  if #roots == 0 then
    roots = { vim.fn.getcwd() }
  end
  local base
  if o.baseline then
    local f = io.open(o.baseline, "rb")
    if not f then
      sv.err("testing perf: cannot read the baseline " .. o.baseline)
      return 2
    end
    local ok, doc =
      pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
    f:close()
    if not ok or type(doc) ~= "table" or doc.schema ~= require("testing.perf.report").SCHEMA then
      sv.err(
        "testing perf: the baseline is no " .. require("testing.perf.report").SCHEMA .. " document"
      )
      return 2
    end
    base = doc
  end
  local trust_check = sv.trust_check or require("testing.trust").check
  local user = require("testing.child.user_config").locate(sv.getenv)
  local dir = vim.fn.tempname() .. "-perf"
  vim.fn.mkdir(dir, "p")
  local tree = require("testing.perf.tree").start({ interval_ms = o.interval_ms })
  if tree.error then
    sv.err("testing perf: no process tree (" .. tree.error .. "): memory and CPU stay empty")
  end
  local results, ran = {}, 0
  local run_root = sv.run_root or run.run_root
  for _, r in ipairs(roots) do
    local root = vim.fs.normalize(vim.fn.fnamemodify(r, ":p")):gsub("/+$", "")
    local refusal = trust_check(root)
    if refusal then
      sv.err(("testing perf: %s: %s"):format(vim.fs.basename(root), refusal))
      results[#results + 1] = {
        root = root,
        repo = vim.fs.basename(root),
        sheets = {},
        unloadable = {},
        sites = {},
        coverage = {},
        refused = refusal,
      }
    else
      ran = ran + 1
      results[#results + 1] = run_root(root, {
        dir = dir,
        real = o.real,
        sheets = o.sheets,
        features = o.features,
        tree = tree,
        getenv = sv.getenv,
        user_config_dir = user and user.config and vim.fs.normalize(user.config) or nil,
        keep_traces = o.keep_traces,
        on_sheet = function(sh)
          sv.out(
            ("%s  %-44s %-6s %3d starts %6d ms"):format(
              vim.fs.basename(root),
              sh.id,
              sh.status,
              #(sh.spawns or {}),
              sh.ms or 0
            )
          )
        end,
      })
    end
  end
  tree:stop()
  if ran == 0 then
    sv.err("testing perf: no root could run")
    return 2
  end
  local report = require("testing.perf.report")
  local doc = report.document({
    started = os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
    machine = machine(),
    real = o.real,
    interval_ms = o.interval_ms or require("testing.perf.tree").DEFAULT_INTERVAL_MS,
    roots = results,
  })
  local sheets = 0
  for _, rr in ipairs(results) do
    sheets = sheets + #rr.sheets
  end
  if sheets == 0 then
    sv.err("testing perf: no sheet ran (no TESTS/sheets, or the filters left none)")
  end
  local md = report.markdown(doc, base)
  if o.json then
    local ok, werr = write_file(o.json, vim.json.encode(doc))
    if not ok then
      sv.err("testing perf: cannot write " .. o.json .. ": " .. tostring(werr))
      return 2
    end
  end
  if o.markdown then
    local ok, werr = write_file(o.markdown, md)
    if not ok then
      sv.err("testing perf: cannot write " .. o.markdown .. ": " .. tostring(werr))
      return 2
    end
    sv.out("report: " .. o.markdown)
  else
    sv.out(md)
  end
  if o.keep_traces then
    sv.out("traces: " .. dir)
  else
    vim.fn.delete(dir, "rf")
  end
  return sheets == 0 and 3 or 0
end

return M
