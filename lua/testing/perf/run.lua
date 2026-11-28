---@module 'testing.perf.run'
-- @cache-env *_DIR
---@brief Run the sheets of a repository with the spawn trace and the process tree: the data of a `testing perf` report.
---@description
--- Each rpc sheet of `TESTS/sheets` runs as `testing.sheet.run` would run it (one child editor per size, the steps in
--- order, a missing snapshot is a failure and is never written), with three additions:
---
--- * the child installs `testing.perf.trace` before the project's minimal init (`preload`), so every process start of
---   the setup and of every step is a line in a trace file;
--- * the bounds of each step are taken here (monotonic clock), and each start is put into the step it happened in
---   (`start`: before the first step, the editor and the plugin's setup; `after`: after the last);
--- * the process tree of this editor is sampled (`testing.perf.tree`): memory and CPU of the longer processes, and
---   what still runs when the last step is done.
---
--- `real` (`--real=<prog>,...|all`) takes those programs out of a sheet's `fakes`, so they run for real, and tells the
--- child through `TESTING_PERF_REAL` (a step may skip its network stub, `testing.perf.trace.real("network")`).
--- Sheets of another engine (browser, desktop, webview, manual) are listed, not measured.

local M = {}

local uv = vim.uv or vim.loop

local function now_us()
  return math.floor(uv.hrtime() / 1000)
end

---@class Testing.Perf.Step
---@field n integer
---@field size string
---@field action string
---@field note? string
---@field t0 integer
---@field t1 integer
---@field ms integer
---@field status string

---@class Testing.Perf.SheetRun
---@field id string
---@field rel string
---@field title? string
---@field feature? string
---@field engine string
---@field config? string
---@field status string pass, fail, skip, error, not-measured
---@field failures? string[]
---@field skipped? string
---@field steps Testing.Perf.Step[]
---@field spawns Testing.Perf.Spawn[] with `step` (number, "start" or "after") and the tree's `peak`/`cpu` when seen
---@field procs table[] the processes the tree saw while the sheet ran (`alive_at_end` for those in its last sample)
---@field ms integer the whole sheet
---@field real? string[] the programs taken out of `fakes`
---@field reaches? { kind: string, stack: string[] }[] lines that ran without a process of their own (`vim.lsp.start`)

---Which of a list of fake programs stay stand-ins under `real`.
---@param fakes string[]|nil
---@param real string[]|nil
---@return string[]|nil kept, string[] made_real
function M.split_fakes(fakes, real)
  if not fakes then
    return nil, {}
  end
  local want, all = {}, false
  for _, r in ipairs(real or {}) do
    r = r:lower()
    if r == "all" then
      all = true
    end
    want[r] = true
  end
  local kept, made = {}, {}
  for _, name in ipairs(fakes) do
    local bare = name:lower():gsub("%.exe$", "")
    if all or want[name:lower()] or want[bare] then
      made[#made + 1] = name
    else
      kept[#kept + 1] = name
    end
  end
  return #kept > 0 and kept or nil, made
end

---The step a moment belongs to, and the size it ran at. Every size has its own child: a moment before the first step
---of a size is that child's `start` (its editor and the plugin's setup), one after the last step of the sheet `after`.
---@param steps Testing.Perf.Step[]
---@param us integer
---@return integer|string step, string|nil size
function M.step_of(steps, us)
  if #steps == 0 then
    return "start", nil
  end
  local prev, nxt
  for _, st in ipairs(steps) do
    if us >= st.t0 and us <= st.t1 then
      return st.n, st.size
    end
    if st.t1 < us then
      prev = st
    elseif not nxt and st.t0 > us then
      nxt = st
    end
  end
  if nxt and (not prev or nxt.n == 1) then
    -- before the first step of a size: its child booting
    return "start", nxt.size
  end
  if not nxt then
    return "after", prev and prev.size or nil
  end
  -- between two steps of one size (the driver's own calls): the step that just ended
  return prev.n, prev.size
end

---Replace the sandbox path of the user's config by the real one in a trace place.
local function map_config(place, from, to)
  if not place or not from or not to then
    return place
  end
  local p = place:gsub("\\", "/")
  if p:sub(1, #from + 1):lower() == (from .. "/"):lower() then
    return to .. p:sub(#from + 1)
  end
  return place
end

---The options of the measured child: the spawn trace before the minit, and treesitter parsing in steps as in a real
---editor (`ts_sync = false`; a sheet child parses synchronously, which would show the parse as one long freeze).
---@param trace_file string
---@param real? string[]
---@return table
function M.spawn_opts(trace_file, real)
  return {
    preload = {
      {
        module = "testing.perf.trace",
        opts = { out = trace_file, real = real and table.concat(real, ",") or nil },
      },
    },
    ts_sync = false,
  }
end

---@param o table
---@param root string
---@param s Testing.Sheet
---@param rel string
---@param tree Testing.Perf.Tree
---@return Testing.Perf.SheetRun
local function run_sheet(o, root, s, rel, tree)
  local res = {
    id = s.id,
    rel = rel,
    title = s.title,
    feature = s.feature,
    engine = s.engine or "rpc",
    config = s.config,
    steps = {},
    spawns = {},
    procs = {},
  }
  if res.engine ~= "rpc" then
    res.status = "not-measured"
    res.skipped = ("engine %s: only rpc sheets are measured"):format(res.engine)
    return res
  end
  local copy = vim.deepcopy(s)
  local made
  copy.fakes, made = M.split_fakes(s.fakes, o.real)
  if #made > 0 then
    res.real = made
  end
  local trace_file = o.dir .. "/" .. s.id .. ".jsonl"
  os.remove(trace_file)
  local spawn = M.spawn_opts(trace_file, o.real)
  local session_mod = o.session or require("testing.sheet.session")
  local mark0 = tree:count()
  local t_start = now_us()
  local session = session_mod.open(copy, {
    root = root,
    ci = true, -- a missing snapshot is a failure; a measuring run never writes a reference
    update = false,
    spawn = spawn,
    getenv = o.getenv,
  })
  while true do
    local nxt = session:peek()
    if not nxt then
      break
    end
    local t0 = now_us()
    local st = session:step()
    local t1 = now_us()
    if not st then
      break
    end
    res.steps[#res.steps + 1] = {
      n = st.n,
      size = st.size,
      action = st.action,
      note = st.note,
      t0 = t0,
      t1 = t1,
      ms = math.floor((t1 - t0) / 1000),
      status = st.status,
    }
  end
  -- one more sample before the child goes: what still runs when the last step is done
  local before = tree:count()
  if not tree.error and not tree.done then
    vim.wait(o.settle_ms or 3000, function()
      return tree:count() > before
    end, 50)
  end
  local mark1 = tree:count()
  session:close()
  local samples = tree:between(mark0, mark1)
  -- what this sheet saw is taken: the samples before go, so a long run never fills the bound of the tree
  tree:forget(mark1)
  local result = session:result()
  res.ms = math.floor((now_us() - t_start) / 1000)
  res.status = result.status
  res.failures = #result.failures > 0 and result.failures or nil
  res.skipped = result.skipped

  local records = require("testing.perf.trace").read(trace_file)
  local config_from
  for _, r in ipairs(records) do
    if r.ev == "install" and r.config_dir then
      config_from = r.config_dir
    end
  end
  local spawns = require("testing.perf.trace").fold(records)
  local config_to = s.config == "user" and o.user_config_dir or nil
  local per = require("testing.perf.tree").per_process(samples)
  local last = samples[#samples]
  local alive = {}
  for _, p in ipairs(last and last.procs or {}) do
    alive[p.pid] = true
  end
  for _, sp in ipairs(spawns) do
    sp.step, sp.size = M.step_of(res.steps, sp.us)
    if config_to then
      sp.site = map_config(sp.site, config_from, config_to)
      sp.origin = map_config(sp.origin, config_from, config_to)
    end
    local p = sp.pid and per[sp.pid]
    if p then
      sp.peak, sp.cpu = p.peak, p.cpu
      sp.alive_at_end = alive[sp.pid] == true
    end
  end
  res.spawns = spawns
  res.reaches = require("testing.perf.trace").reaches(records)
  for _, p in pairs(per) do
    p.alive_at_end = alive[p.pid] == true
    res.procs[#res.procs + 1] = p
  end
  table.sort(res.procs, function(a, b)
    return a.pid < b.pid
  end)
  if not o.keep_traces then
    os.remove(trace_file)
  end
  return res
end

---@class Testing.Perf.RootRun
---@field root string
---@field repo string
---@field sheets Testing.Perf.SheetRun[]
---@field unloadable { rel: string, error: string }[]
---@field catalog? Testing.Sheet.Feature[]
---@field catalog_error? string
---@field sites Testing.Perf.Site[]
---@field coverage table
---@field refused? string

---Run the sheets of one repository.
---@param root string
---@param o { dir: string, real?: string[], sheets?: string[], features?: string[], tree?: Testing.Perf.Tree, getenv?: (fun(n: string): string|nil), user_config_dir?: string, session?: table, settle_ms?: integer, keep_traces?: boolean, on_sheet?: (fun(r: Testing.Perf.SheetRun)), interval_ms?: integer, lib_root?: string }
---@return Testing.Perf.RootRun
function M.run_root(root, o)
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
  local main = M.main_checkout(root)
  -- a worktree is named after its repository, and finds the dependencies its siblings would give the checkout
  local repo = vim.fs.basename(main or root)
  local provided = main and M.provide_deps(root, main, repo) or {}
  local out = { root = root, repo = repo, sheets = {}, unloadable = {}, sites = {}, coverage = {} }
  local sheet = require("testing.sheet")
  out.catalog, out.catalog_error = require("testing.sheet.features").load(root)
  local scan = require("testing.perf.scan")
  local lib = o.lib_root
  if not lib then
    local found = require("testing.deps").resolve("lib.nvim", root)
    lib = found and found.dir or nil
  end
  out.sites = scan.sites(root, lib and scan.spawning_modules(lib) or nil)
  local want_sheet, want_feature
  if o.sheets and #o.sheets > 0 then
    want_sheet = {}
    for _, id in ipairs(o.sheets) do
      want_sheet[id] = true
    end
  end
  if o.features and #o.features > 0 then
    want_feature = {}
    for _, id in ipairs(o.features) do
      want_feature[id] = true
    end
  end
  local own_tree = not o.tree
  local tree = o.tree or require("testing.perf.tree").start({ interval_ms = o.interval_ms })
  local all_spawns, all_reaches = {}, {}
  for _, path in ipairs(sheet.files(root .. "/TESTS/sheets")) do
    local rel = path:sub(#root + 2)
    local s, err = sheet.load(path)
    if not s then
      out.unloadable[#out.unloadable + 1] = { rel = rel, error = tostring(err) }
    elseif
      (not want_sheet or want_sheet[s.id]) and (not want_feature or want_feature[s.feature or ""])
    then
      local r = run_sheet(o, root, s, rel, tree)
      if main then
        -- the trace names a source by its folder: in a worktree that is the worktree's, not the repository's
        local folder = vim.fs.basename(root)
        for _, sp in ipairs(r.spawns) do
          if sp.plugin == folder then
            sp.plugin = repo
          end
        end
      end
      out.sheets[#out.sheets + 1] = r
      vim.list_extend(all_spawns, r.spawns)
      vim.list_extend(all_reaches, r.reaches or {})
      if o.on_sheet then
        o.on_sheet(r)
      end
    end
  end
  if own_tree then
    tree:stop()
  end
  M.restore_deps(provided)
  out.tree_error = tree.error
  out.coverage = require("testing.perf.scan").coverage(
    out.sites,
    all_spawns,
    root,
    require("testing.platform").is_windows(),
    all_reaches
  )
  return out
end

---The main checkout of a linked Git worktree (`.git` is a file `gitdir: <main>/.git/worktrees/<name>`), else nil.
---@param root string
---@return string|nil
function M.main_checkout(root)
  local st = uv.fs_stat(root .. "/.git")
  if not st or st.type ~= "file" then
    return nil
  end
  local f = io.open(root .. "/.git", "rb")
  if not f then
    return nil
  end
  local text = f:read("*l") or ""
  f:close()
  local gitdir = text:match("^gitdir:%s*(.-)%s*$")
  if not gitdir then
    return nil
  end
  if not gitdir:match("^%a:[/\\]") and not gitdir:match("^[/\\]") then
    -- `worktree.useRelativePaths`: relative to the worktree
    gitdir = uv.fs_realpath(root .. "/" .. gitdir) or (root .. "/" .. gitdir)
  end
  local main = vim.fs.normalize(gitdir):match("^(.*)/%.git/worktrees/[^/]+$")
  return main
end

---Set `$<NAME>_DIR` for every dependency of a worktree that the main checkout resolves and nothing set yet: the
---child editors of the sheets resolve them from there (an override wins in `testing.deps`).
---The repository itself is left out (its worktree is what is measured, not the main checkout). Returns the names it
---set, for `restore_deps` when the root is done (`--all`: the next root must not inherit them).
---@param root string
---@param main string
---@param repo string
---@return string[] set
function M.provide_deps(root, main, repo)
  local deps = require("testing.deps")
  local names = vim.list_extend({ "lib.nvim", "testing.nvim" }, deps.declared(root))
  local set = {}
  for _, name in ipairs(names) do
    local var = deps.env_name(name)
    if name ~= repo and (vim.env[var] or "") == "" then
      local found = deps.resolve(name, main)
      if found then
        vim.env[var] = found.dir
        set[#set + 1] = var
      end
    end
  end
  return set
end

---Unset what `provide_deps` set.
---@param set string[]
function M.restore_deps(set)
  for _, var in ipairs(set or {}) do
    vim.env[var] = nil
  end
end

---The repositories below a directory that have test sheets or a feature catalog.
---@param dir string
---@return string[]
function M.roots_below(dir)
  dir = vim.fs.normalize(dir):gsub("/+$", "")
  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" or kind == "link" then
      local root = dir .. "/" .. name
      if
        uv.fs_stat(root .. "/.testing.lua")
        and (uv.fs_stat(root .. "/TESTS/sheets") or uv.fs_stat(root .. "/lua"))
      then
        out[#out + 1] = root
      end
    end
  end
  table.sort(out)
  return out
end

return M
