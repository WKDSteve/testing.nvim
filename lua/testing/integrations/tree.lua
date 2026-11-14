---@module 'testing.integrations.tree'
--- The last test result in a tree view (filetree.nvim's own tree): a badge on spec files, and a view `tests`.
---
--- Registers two entries at `lib.nvim.tree.registry`:
---
---  - a decorator `tests`: per spec file the worst of its cases, with the count of red ones, and "stale" when
---    the file changed since the result was recorded. A folder shows the worst result below it; that roll-up
---    is the tree's, from the `all()` this module answers
---  - a source `tests`: folder, spec file, describe and case of the last result plus the spec files that never
---    ran (`testing.explorer.nodes` builds them), with the actions "run this node" and "run what failed last
---    time", and what a red case said as its preview
---
--- Soft in both directions. Nothing here requires a tree plugin: the registry is lib.nvim's, and without
--- a reader the entries are never looked at. Nothing is loaded before a tree asks either: the result
--- file is read on the first `subscribe` (or when the view is first shown), and again when it changes on disk
--- or the directory changes.
---
--- The result file is the one `testing.state` reads (`last.json` of the project the current directory
--- belongs to); it is untrusted input there and stays so here, this module only asks the store.

local M = {}

M.DECORATOR = "tests"
M.SOURCE = "tests"
M.ACTION_RUN = "tests.run"
M.ACTION_FAILED = "tests.run_failed"

--- Keys of the view `tests`. They are the view's own: in another view the keys keep their meaning.
---@type table<string, string>
M.KEYS = { run = "r", failed = "R" }

--- A spec file larger than this is not read for the cases of a file that never ran.
M.MAX_SPEC_BYTES = 1024 * 1024

--- Worst first. `skipped` ranks above `passed`: a folder of green and skipped files is not green.
M.SEVERITY = { "failed", "stale", "skipped", "passed" }

---@type table<string, { text: string, hl: string }>
local LOOK = {
  failed = { text = "✗", hl = "DiagnosticError" },
  stale = { text = "~", hl = "Comment" },
  skipped = { text = "○", hl = "DiagnosticWarn" },
  passed = { text = "✓", hl = "DiagnosticOk" },
}

--- Statuses that count as green.
local GREEN = { pass = true, xfail = true }
--- Statuses that are neither green nor red: the case did not run.
local IDLE = { skip = true }

---@class Testing.Tree.Opts
---@field root? fun(): string  The project root to show (default: the project of the current directory).
---@field state_opts? Testing.State.Opts  Handed to `testing.state.load`.
---@field keys? { run?: string|string[]|false, failed?: string|string[]|false }  Keys in the view `tests` (default `r` and `R`; false: the action is in the menu only).
---@field files? fun(root: string): string[]  The spec files there are, relative to the root (default: `*_spec.lua` below `TESTS`).
---@field run? fun(opts: { root: string, flags: table })  Starts a run (default: `require("testing").run`).

---@type Testing.Tree.Opts
local options = {}
---@type table<string, table>  absolute spec file -> badge
local badges = {}
---@type Testing.State|nil  the result the badges and the view were made from
local loaded = nil
---@type fun(keys?: string[])|nil
local emit = nil
---@type table<table, true>  the `emit` of every view that shows the source
local views = {}
---@type fun()[]
local removers = {}
---@type { stop: fun() }|nil
local watcher = nil
---@type integer|nil
local augroup = nil

---One spelling for a path, the one a tree asks with: `/`-separated, drive letter upper case.
---@param path string
---@return string
local function norm(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  return path
end

---The badge of one spec file's summary.
---@param sum Testing.State.FileSummary
---@return { text: string, hl: string, status: string, count: integer }
function M.badge(sum)
  local status = "passed"
  if #sum.failed > 0 then
    status = "failed"
  elseif sum.stale then
    status = "stale"
  else
    for name, n in pairs(sum.counts) do
      if n > 0 and IDLE[name] then
        status = "skipped"
      elseif n > 0 and not GREEN[name] and status == "passed" then
        -- a status this module does not know is not called green
        status = "skipped"
      end
    end
  end
  local look = LOOK[status]
  local text = look.text
  if status == "failed" then
    text = ("%s %d/%d"):format(look.text, #sum.failed, sum.total)
  end
  return { text = text, hl = look.hl, status = status, count = #sum.failed }
end

---The badges of a result: absolute path of every spec file the store has cases of -> its badge.
---@param st Testing.State
---@return table<string, table>
function M.badges(st)
  local state = require("testing.state")
  local seen, out = {}, {}
  for _, case in ipairs(st.cases) do
    local file = case.file
    if type(file) == "string" and not seen[file] then
      seen[file] = true
      local sum = state.file_summary(st, file)
      if sum then
        out[norm(st.root .. "/" .. sum.file)] = M.badge(sum)
      end
    end
  end
  return out
end

---@return string
local function project_root()
  if options.root then
    return options.root()
  end
  return require("testing.bindings.usrcmds").resolve_root(nil, nil)
end

local function stop_watching()
  if watcher then
    pcall(watcher.stop)
    watcher = nil
  end
end

---Whether a tree reads this module right now: one draws the badges, or one shows the view.
---@return boolean
local function in_use()
  return emit ~= nil or next(views) ~= nil
end

---The nearest folder above `path` that exists.
---@param path string
---@return string|nil
local function existing_ancestor(path)
  local parent = vim.fs.dirname(path)
  while parent and parent ~= path do
    if vim.uv.fs_stat(parent) then
      return parent
    end
    path, parent = parent, vim.fs.dirname(parent)
  end
  return nil
end

---Follow the result file of a project: `M.reload` runs when it changes.
---@param root string
local function watch(root)
  -- the directory, not the file: a run replaces `last.json`, and a watch on the old file would end with it.
  -- A project that never ran has no directory yet: the nearest one above it is watched until it appears,
  -- so the first run shows without a restart.
  local dir = require("testing.state").dir(root, options.state_opts)
  local target = vim.uv.fs_stat(dir) and dir or existing_ancestor(dir)
  if target then
    watcher = require("lib.nvim.fs.watch").start(target, function()
      vim.schedule(M.reload)
    end, { debounce_ms = 200 })
  end
end

---Read the result of the current project and tell the tree. Follows the result file from then on, while a
---tree is subscribed.
function M.reload()
  local state = require("testing.state")
  local root = project_root()
  local st = state.load(root, options.state_opts)
  badges = emit and M.badges(st) or {}
  stop_watching()
  loaded = nil
  if in_use() then
    loaded = st
    watch(root)
    if emit then
      emit()
    end
    for view in pairs(views) do
      -- the nodes are merged by id: what is there again keeps its place and its open state
      pcall(view.reset)
    end
  end
end

---Follow the directory of the editor while a tree reads this module.
local function follow_directory()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("testing_tree_badges", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    desc = "[testing] Show the test results of the project the directory belongs to",
    callback = function()
      vim.schedule(M.reload)
    end,
  })
end

---Stop following anything once no tree reads this module any more.
local function release()
  if in_use() then
    return
  end
  stop_watching()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  loaded = nil
end

---The spec files there are, relative to the root.
---@param root string
---@return string[]
local function spec_files(root)
  if options.files then
    return options.files(root)
  end
  local ok, files = pcall(require("testing.bindings.usrcmds").spec_files, root)
  return ok and files or {}
end

---The describe/it calls of a spec file, read from its text.
---@param root string
---@param file string
---@return Testing.Position[]|nil
local function positions_of(root, file)
  local path = root .. "/" .. file
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > M.MAX_SPEC_BYTES then
    return nil
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil
  end
  return require("testing.discover.positions").scan(text).positions
end

---The root node of the view `tests`: the last result of the project plus the spec files that never ran.
---@return table
function M.root_node()
  local state = require("testing.state")
  local nodes = require("testing.explorer.nodes")
  local root = project_root()
  -- what was read is current only while the result file is followed, and only for that project
  local st = (watcher and loaded and loaded.root == root) and loaded
    or state.load(root, options.state_opts)
  local stale, seen = {}, {}
  for _, case in ipairs(st.cases) do
    if not seen[case.file] then
      seen[case.file] = true
      stale[case.file] = state.is_stale(st, case.file) or nil
    end
  end
  return nodes.build({
    root = root,
    cases = st.cases,
    stale = stale,
    files = spec_files(root),
    positions = function(file)
      return positions_of(root, file)
    end,
  })
end

---Start a run of the current project with these flags.
---@param flags table
function M.start(flags)
  local opts = { root = project_root(), flags = flags }
  if options.run then
    options.run(opts)
    return
  end
  local ok, err = require("testing").run(opts)
  local notify = require("testing.notify").get()
  if not ok then
    notify.error(("cannot start the test process: %s"):format(tostring(err)))
    return
  end
  notify.info(("testing run: %s"):format(opts.root))
end

---Start the run the marked nodes (or the node under the cursor) stand for.
---@param list table[]
function M.run(list)
  local nodes = require("testing.explorer.nodes")
  local files, filters, whole, any = {}, {}, false, false
  for _, node in ipairs(list or {}) do
    local flags = nodes.run_flags(node)
    if flags then
      any = true
      if not flags.file then
        whole = true
      end
      vim.list_extend(files, flags.file or {})
      -- a file marked next to a case: `--filter` narrows every selected file, so the file is a filter too
      vim.list_extend(filters, flags.filter or flags.file or {})
    end
  end
  if not any then
    return
  end
  local flags = {}
  if not whole then
    flags.file, flags.filter = files, filters
  end
  M.start(flags)
end

---Run what failed last time (`--lf`).
function M.run_failed()
  M.start({ raw = { "--lf" } })
end

---@param key any
---@param default string
---@return string|string[]|nil
local function key_of(key, default)
  if key == false then
    return nil
  end
  if type(key) == "string" or type(key) == "table" then
    return key
  end
  return default
end

---Whether the view is at a registry right now, for `:checkhealth testing`.
---@return "registered"|"not registered"|"no tree registry"
function M.status()
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok or type(registry.source) ~= "function" then
    return "no tree registry"
  end
  if #removers > 0 and registry.get("source", M.SOURCE) ~= nil then
    return "registered"
  end
  return "not registered"
end

---Register the decorator and the view. Without `lib.nvim.tree.registry` (an older lib.nvim) nothing happens.
---@param opts? Testing.Tree.Opts
---@return boolean registered
function M.register(opts)
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok or type(registry.decorator) ~= "function" or type(registry.source) ~= "function" then
    return false
  end
  M.unregister()
  options = opts or {}
  local nodes = require("testing.explorer.nodes")
  local keys = type(options.keys) == "table" and options.keys or {}

  removers[#removers + 1] = registry.decorator({
    name = M.DECORATOR,
    key = "path",
    slot = "badge",
    priority = 70,
    roll_up = "worst",
    severity = M.SEVERITY,
    get = function(path, node)
      -- a node of the view `tests` says the same itself, with its sign and its counts
      if node and nodes.data(node) then
        return nil
      end
      return badges[path]
    end,
    all = function()
      return badges
    end,
    subscribe = function(on_change)
      emit = on_change
      follow_directory()
      M.reload()
      return function()
        emit = nil
        badges = {}
        release()
      end
    end,
  })

  removers[#removers + 1] = registry.source({
    name = M.SOURCE,
    title = "Tests",
    mutable = false,
    root = M.root_node,
    severity = nodes.SEVERITY,
    aggregate = nodes.aggregate,
    preview = function(node)
      return nodes.preview(node)
    end,
    subscribe = function(_, view)
      views[view] = true
      follow_directory()
      -- the view was built from what `root` read; from here on the result file is followed
      if not watcher then
        watch(project_root())
      end
      return function()
        views[view] = nil
        release()
      end
    end,
    actions = {
      {
        name = M.ACTION_RUN,
        desc = "Run the tests of this node (testing.nvim)",
        key = key_of(keys.run, M.KEYS.run),
        when = function(node)
          return nodes.run_flags(node) ~= nil
        end,
        run = M.run,
      },
      {
        name = M.ACTION_FAILED,
        desc = "Run what failed last time (testing.nvim)",
        key = key_of(keys.failed, M.KEYS.failed),
        run = M.run_failed,
      },
    },
  })
  return true
end

---Take the entries out again.
function M.unregister()
  for _, remove in ipairs(removers) do
    pcall(remove)
  end
  removers = {}
end

return M
