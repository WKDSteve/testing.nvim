---@module 'testing.integrations.tree'
--- The last test result as a badge on spec files in a tree view (filetree.nvim's own tree).
---
--- Registers one decorator at `lib.nvim.tree.registry`: per spec file the worst of its cases, with the
--- count of red ones, and "stale" when the file changed since the result was recorded. A folder shows
--- the worst result below it; that roll-up is the tree's, from the `all()` this module answers.
---
--- Soft in both directions. Nothing here requires a tree plugin: the registry is lib.nvim's, and without
--- a reader the entry is never looked at. Nothing is loaded before a tree subscribes either: the result
--- file is read on the first `subscribe`, and again when it changes on disk or the directory changes.
---
--- The result file is the one `testing.state` reads (`last.json` of the project the current directory
--- belongs to); it is untrusted input there and stays so here, this module only asks the store.

local M = {}

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

---@type Testing.Tree.Opts
local options = {}
---@type table<string, table>  absolute spec file -> badge
local badges = {}
---@type fun(keys?: string[])|nil
local emit = nil
---@type fun()|nil
local unregister = nil
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

---Read the result of the current project and tell the tree. Follows the result file from then on, while a
---tree is subscribed.
function M.reload()
  local state = require("testing.state")
  local root = project_root()
  local st = state.load(root, options.state_opts)
  badges = M.badges(st)
  stop_watching()
  if emit then
    -- the directory, not the file: a run replaces `last.json`, and a watch on the old file would end with it.
    -- A project that never ran has no directory yet: the nearest one above it is watched until it appears,
    -- so the first run shows without a restart.
    local dir = state.dir(root, options.state_opts)
    local target = vim.uv.fs_stat(dir) and dir or existing_ancestor(dir)
    if target then
      watcher = require("lib.nvim.fs.watch").start(target, function()
        vim.schedule(M.reload)
      end, { debounce_ms = 200 })
    end
    emit()
  end
end

---Register the decorator. Without `lib.nvim.tree.registry` (an older lib.nvim) nothing happens.
---@param opts? Testing.Tree.Opts
---@return boolean registered
function M.register(opts)
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok then
    return false
  end
  M.unregister()
  options = opts or {}
  unregister = registry.decorator({
    name = "tests",
    key = "path",
    slot = "badge",
    priority = 70,
    roll_up = "worst",
    severity = M.SEVERITY,
    get = function(path)
      return badges[path]
    end,
    all = function()
      return badges
    end,
    subscribe = function(on_change)
      emit = on_change
      augroup = vim.api.nvim_create_augroup("testing_tree_badges", { clear = true })
      vim.api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        desc = "[testing] Show the test results of the project the directory belongs to",
        callback = function()
          vim.schedule(M.reload)
        end,
      })
      M.reload()
      return function()
        emit = nil
        stop_watching()
        if augroup then
          pcall(vim.api.nvim_del_augroup_by_id, augroup)
          augroup = nil
        end
        badges = {}
      end
    end,
  })
  return true
end

---Take the decorator out again.
function M.unregister()
  if unregister then
    unregister()
    unregister = nil
  end
end

return M
