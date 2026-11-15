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
---    time", and what a red case said as its preview. The last pipeline run of the project stands first
---    (`testing.explorer.ci`): its steps with their state and findings, and "run this step again"
---
--- **While a pipeline goes.** A pipeline started from this editor (`testing.ci.editor.listen`) moves its step
--- nodes the same way: the planned steps are `queued`, the one that is going is `running` (the suite with "file n
--- of m"), each gets its state and time when it ends. When the run has ended, or was killed, `ci.json` is read
--- again: the document the run wrote, or the last one.
---
--- **While a run goes.** A run started from this editor is followed case by case (`testing.bindings.live`,
--- `testing.explorer.live`): the cases of a file that is being run show `running`, the ones still to come
--- `queued`, and each result moves its case, everything above it and the badge of its file the moment it is
--- recorded. When the run has ended, or was killed, the stored result is read again: no case stays `running`.
--- A run from elsewhere (a terminal, the CI) shows when it has written its result, as before.
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
M.ACTION_CI = "tests.ci"

--- Keys of the view `tests`. They are the view's own: in another view the keys keep their meaning.
---@type table<string, string>
M.KEYS = { run = "r", failed = "R" }

--- A spec file larger than this is not read for the cases of a file that never ran.
M.MAX_SPEC_BYTES = 1024 * 1024

--- Worst first. `skipped` ranks above `passed`: a folder of green and skipped files is not green.
M.SEVERITY = { "failed", "running", "stale", "skipped", "passed" }

---@type table<string, { text: string, hl: string }>
local LOOK = {
  failed = { text = "✗", hl = "DiagnosticError" },
  running = { text = "●", hl = "DiagnosticInfo" },
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
---@field files? fun(root: string): string[]  The spec files there are, relative to the root (default: what the last run discovered, and `*_spec.lua` below `TESTS`; see `M.spec_files`).
---@field run? fun(opts: { root: string, flags: table })  Starts a run (default: `require("testing").run`).
---@field ci_run? fun(opts: { root: string, profile: string, steps?: string[] })  Starts a pipeline run (default: `testing.ci.editor.run`).

---@type Testing.Tree.Opts
local options = {}
---@type table<string, table>  absolute spec file -> badge
local badges = {}
---@type Testing.State|nil  the result the badges and the view were made from
local loaded = nil
---@type Testing.Explorer.Live|nil  the run that is going, laid over `loaded`
local session = nil
---@type Testing.Explorer.Index|nil  the nodes of the view as they were last built
local shown = nil
---@type fun()|nil
local unlisten = nil
---@type fun()|nil
local unlisten_ci = nil
---@type table<string, Testing.Explorer.Ci.Live>  project root -> its pipeline run that is going, laid over `ci.json`
local pipelines = {}
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

---Tell every view to ask for the root again. The nodes are merged by id: what is there again keeps its place
---and its open state.
local function reset_views()
  for view in pairs(views) do
    pcall(view.reset)
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
  -- what a run in progress laid over the old result goes with it: the next event starts over on this one
  loaded, session = nil, nil
  if in_use() then
    loaded = st
    watch(root)
    if emit then
      emit()
    end
    reset_views()
  end
end

---Follow the directory of the editor and the runs started from it while a tree reads this module.
local function follow_directory()
  if not unlisten then
    unlisten = require("testing.bindings.live").listen(function(root, events)
      M.on_events(root, events)
    end)
  end
  if not unlisten_ci then
    unlisten_ci = require("testing.ci.editor").listen(function(root, ev)
      M.on_ci_event(root, ev)
    end)
  end
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
  if unlisten then
    unlisten()
    unlisten = nil
  end
  if unlisten_ci then
    unlisten_ci()
    unlisten_ci = nil
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  -- a pipeline that goes on while no tree reads this module is not followed: its end shows as a new `ci.json`
  loaded, session, shown, pipelines = nil, nil, nil, {}
end

---The badge of a spec file while a run goes: running while one of its cases is running or queued, else what
---its cases say so far. A file with a result of this run is not stale, whatever its record says.
---@param live Testing.Explorer.Live
---@param file string
---@return table|nil
function M.live_badge(live, file)
  local sum = require("testing.explorer.live").file_summary(live, file)
  if sum.mark then
    return { text = LOOK.running.text, hl = LOOK.running.hl, status = "running", count = sum.red }
  end
  if sum.total == 0 then
    return nil
  end
  local failed = {}
  for i = 1, sum.red do
    failed[i] = true
  end
  local recorded = require("testing.state").file_summary(live.st, file)
  return M.badge({
    file = file,
    total = sum.total,
    counts = sum.counts,
    failed = failed,
    duration_ms = 0,
    stale = not live.fresh[file] and recorded ~= nil and recorded.stale,
  })
end

---What a spec file without cases of its own in the tree shows while a run goes.
---@param live Testing.Explorer.Live
---@param file string
---@return string
local function file_status(live, file)
  local nodes = require("testing.explorer.nodes")
  local sum = require("testing.explorer.live").file_summary(live, file)
  if sum.mark then
    return sum.mark
  end
  local worst = nil
  for status in pairs(sum.counts) do
    worst = nodes.worse(worst, status)
  end
  return worst or "never"
end

---The events of a run started from this editor (a batch): the store, the badges and the view follow.
---@param root string
---@param events table[]
function M.on_events(root, events)
  if not in_use() or norm(root) ~= norm(project_root()) then
    return
  end
  local state = require("testing.state")
  local live = require("testing.explorer.live")
  local nodes = require("testing.explorer.nodes")
  if not loaded then
    loaded = state.load(project_root(), options.state_opts)
  end
  if not session or session.st ~= loaded then
    session = live.new(loaded)
  end
  local dirty
  for _, ev in ipairs(events) do
    dirty = live.feed(session, ev, dirty)
  end
  if not dirty then
    return
  end
  if dirty.done then
    -- ended or killed: what the run stored (or the last good result) is the truth from here on
    session = nil
    M.reload()
    return
  end
  if emit then
    local paths = {}
    for file in pairs(dirty.files) do
      local path = norm(loaded.root .. "/" .. file)
      badges[path] = M.live_badge(session, file)
      paths[#paths + 1] = path
    end
    if #paths > 0 then
      emit(paths)
    end
  end
  if next(views) == nil or not shown then
    return
  end
  local changes, blind = {}, {}
  for id in pairs(dirty.cases) do
    local case = state.case(loaded, id)
    local change = {
      id = id,
      status = live.status(session, id) or "never",
      duration_ms = case and case.duration_ms or nil,
    }
    if shown.by_case[id] then
      changes[#changes + 1] = change
    else
      blind[#blind + 1] = change
    end
  end
  for file in pairs(dirty.files) do
    local node = shown.by_file[file]
    -- a file that is not a case and has no cases in the tree (it never ran): it shows the run as a whole
    if node and type(node.children) ~= "table" and not nodes.data(node).case then
      changes[#changes + 1] = { file = file, status = file_status(session, file) }
    end
  end
  local updates = nodes.set_many(shown, changes)
  -- a case the tree got from reading a file that never ran: its node is the tree's, not in the index
  for _, change in ipairs(blind) do
    local look = nodes.look(change.status)
    local timed = nodes.GREEN[change.status] or nodes.RED[change.status]
    updates[#updates + 1] = {
      id = "tests:case:" .. change.id,
      status = change.status,
      icon = look.icon,
      hl = look.hl,
      columns = timed and { nodes.duration(change.duration_ms or 0) } or {},
    }
  end
  for view in pairs(views) do
    for _, update in ipairs(updates) do
      pcall(view.push, update)
    end
  end
end

---One event of a pipeline run started from this editor: the step nodes of the view follow.
---@param root string
---@param ev table  As `testing.ci.editor.listen` hands it out: the words of the child, checked by `testing.explorer.ci`.
function M.on_ci_event(root, ev)
  if not in_use() then
    return
  end
  local ci = require("testing.explorer.ci")
  local where = norm(root)
  -- The run is followed whether or not it is in sight: while the view is hidden or shows another project, a
  -- step that ends and the end of the run are taken in all the same, or the view would come back to a step
  -- that runs for ever. Only the telling is for the project on screen.
  local on_screen = next(views) ~= nil and where == norm(project_root())
  if type(ev) == "table" and ev.event == "run_start" then
    pipelines[where] = ci.live_start(ev)
    if on_screen then
      reset_views()
    end
    return
  end
  local live = pipelines[where]
  if not live then
    return
  end
  local what, name = ci.live_feed(live, ev)
  if what == "done" then
    -- ended or killed: the root reads `ci.json` again, the document the run wrote or the last one
    pipelines[where] = nil
  end
  if not on_screen then
    return
  end
  if what == "done" or what == "reset" then
    reset_views()
  elseif what == "step" and shown and shown.by_step[name] then
    local step = live.by_name[name]
    local updates = require("testing.explorer.nodes").set_many(shown, {
      {
        step = name,
        status = ci.STATUS[step.state] or "never",
        duration_ms = step.ms,
        progress = step.progress,
      },
    })
    for view in pairs(views) do
      for _, update in ipairs(updates) do
        pcall(view.push, update)
      end
    end
  end
end

---The spec files there are, relative to the root. No code of the project runs for it (the real discovery needs
---`.testing.lua`, which only a run executes, behind the trust gate). Two things are read instead:
---
---  - the list the last run discovered (`specs` of the result file, data like the rest of it): what the
---    project's own `roots` and `spec_pattern` make a spec, minus what is gone since
---  - the files named `*_spec.lua` below `TESTS`. Before the first run that is all there is. After it, such a
---    file the run did not list is shown only when it was written since: an older one is a file the project's
---    pattern leaves out (a fixture), a newer one a spec the next run will find
---@param root string
---@param st Testing.State
---@return string[]
function M.spec_files(root, st)
  if options.files then
    return options.files(root)
  end
  local ok, named = pcall(require("testing.bindings.usrcmds").spec_files, root)
  named = ok and named or {}
  local specs = st.specs
  if not specs then
    return named
  end
  local on_disk, has_cases = {}, {}
  for _, file in ipairs(named) do
    on_disk[file] = true
  end
  for _, case in ipairs(st.cases) do
    has_cases[case.file] = true
  end
  local out, listed = {}, {}
  for _, file in ipairs(specs) do
    listed[file] = true
    -- a file with cases is in the view anyway, and one the walk just saw is there: only the rest is asked for
    local there = on_disk[file] or has_cases[file]
    if not there then
      local stat = vim.uv.fs_stat(root .. "/" .. file)
      there = stat ~= nil and stat.type == "file"
    end
    if there then
      out[#out + 1] = file
    end
  end
  local since = st.specs_ts or 0
  for _, file in ipairs(named) do
    if not listed[file] then
      local stat = vim.uv.fs_stat(root .. "/" .. file)
      if stat and stat.mtime.sec >= since then
        out[#out + 1] = file
      end
    end
  end
  return out
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
  -- a run that is going: its marks are drawn, and a file with a result of this run is not stale
  local live = (session and session.st == st) and session or nil
  local stale, seen = {}, {}
  for _, case in ipairs(st.cases) do
    if not seen[case.file] then
      seen[case.file] = true
      if not (live and live.fresh[case.file]) then
        stale[case.file] = state.is_stale(st, case.file) or nil
      end
    end
  end
  -- the pipeline of the project, when there is one: it stands first. A run that is going, else the last one
  local ci = require("testing.explorer.ci")
  local going = pipelines[norm(root)]
  local ok_ci, doc = true, going and going.doc or nil
  if not doc then
    ok_ci, doc = pcall(ci.read, root, options.state_opts)
  end
  local top = nodes.build({
    root = root,
    cases = st.cases,
    stale = stale,
    live = live and live.marks or nil,
    first = (ok_ci and doc) and { ci.node(nodes.norm(root), doc) } or nil,
    files = M.spec_files(root, st),
    positions = function(file)
      return positions_of(root, file)
    end,
  })
  shown = nodes.index(top)
  if live then
    local changes = {}
    for file in pairs(live.file_marks) do
      changes[#changes + 1] = { file = file, status = file_status(live, file) }
    end
    nodes.set_many(shown, changes)
  end
  return top
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
  local files, filters, whole, any, narrowed = {}, {}, false, false, false
  for _, node in ipairs(list or {}) do
    local flags = nodes.run_flags(node)
    if flags then
      any = true
      if not flags.file then
        whole = true
      end
      narrowed = narrowed or flags.filter ~= nil
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
    -- no `--filter` unless a case or a describe asked for one: a file that ran with a filter counts as run in
    -- part, and its result would stay outdated
    flags.file, flags.filter = files, narrowed and filters or nil
  end
  M.start(flags)
end

---Start the pipeline the marked nodes stand for: its profile, or only the marked steps of it (`--step=`).
---@param list table[]
function M.ci_run(list)
  local run = require("testing.explorer.ci").run_of(list)
  if not run then
    return
  end
  local opts = { root = project_root(), profile = run.profile, steps = run.steps }
  if options.ci_run then
    options.ci_run(opts)
    return
  end
  local notify = require("testing.notify").get()
  local started, err = require("testing.ci.editor").run(opts)
  if not started then
    notify.error("testing ci: " .. tostring(err))
    return
  end
  notify.info(("testing ci %s: %s"):format(opts.profile, opts.root))
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
        -- the same key on the nodes of the pipeline: there it runs the pipeline, or the step
        name = M.ACTION_CI,
        desc = "Run this pipeline, or this step of it (testing.nvim)",
        key = key_of(keys.run, M.KEYS.run),
        when = function(node)
          return require("testing.explorer.ci").run_of({ node }) ~= nil
        end,
        run = M.ci_run,
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
