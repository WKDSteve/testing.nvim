---@module 'testing.discover.known'
---@brief The spec files of a project as far as they are known without running anything of it.
---@description
--- The real discovery needs `.testing.lua`, which only a run executes (behind the trust gate). A reader
--- that must not run code (the view `tests` of a tree, the completion of `--file=`) puts two things
--- together instead:
---
---  - the list the last run discovered (`specs` of the result file, data like the rest of it): what the
---    project's own `roots` and `spec_pattern` make a spec, minus what is gone since
---  - the files named `*_spec.lua` below `TESTS`. Before the first run that is all there is. After it,
---    such a file the run did not list counts only when it was written since: an older one is a file
---    the project's pattern leaves out (a fixture), a newer one a spec the next run will find
---
--- `merge` is that rule on a state somebody has in hand; `of` reads the result file itself and keeps
--- what it needs of it until the file changes (one `stat` per call).

local M = {}

local uv = vim.uv

---The files named `*_spec.lua` below `<root>/TESTS`, relative to the root, sorted.
---@param root string
---@return string[]
function M.named(root)
  local found = vim.fs.find(function(name)
    return name:match("_spec%.lua$") ~= nil
  end, { path = root .. "/TESTS", type = "file", limit = 1000 })
  local out = {}
  for _, path in ipairs(found) do
    out[#out + 1] = require("lib.nvim.fs.relpath")(path, root)
  end
  table.sort(out)
  return out
end

---What `merge` reads of a state.
---@class Testing.Discover.Known.State
---@field specs? string[]  The spec files the last run discovered; nil: no run recorded a list.
---@field specs_ts? integer  When that list was made (Unix time).
---@field cases? { file: string }[]  The recorded cases: a file that has one is there.
---@field has_cases? table<string, true>  The same as a set, in place of `cases`.

---The spec files there are, relative to the root: the recorded list first (in its order), then the
---files found by name that were written since. See the module description for the rule.
---@param root string
---@param st Testing.Discover.Known.State
---@param named? string[]  What `named(root)` answered, for a caller that has it already.
---@return string[]
function M.merge(root, st, named)
  if not named then
    local ok, found = pcall(M.named, root)
    named = ok and found or {}
  end
  local specs = st.specs
  if not specs then
    return named
  end
  local on_disk, has_cases = {}, st.has_cases
  for _, file in ipairs(named) do
    on_disk[file] = true
  end
  if not has_cases then
    has_cases = {}
    for _, case in ipairs(st.cases or {}) do
      has_cases[case.file] = true
    end
  end
  local out, listed = {}, {}
  for _, file in ipairs(specs) do
    listed[file] = true
    -- a file with cases is known anyway, and one the walk just saw is there: only the rest is asked for
    local there = on_disk[file] or has_cases[file]
    if not there then
      local stat = uv.fs_stat(root .. "/" .. file)
      there = stat ~= nil and stat.type == "file"
    end
    if there then
      out[#out + 1] = file
    end
  end
  local since = st.specs_ts or 0
  for _, file in ipairs(named) do
    if not listed[file] then
      local stat = uv.fs_stat(root .. "/" .. file)
      if stat and stat.mtime.sec >= since then
        out[#out + 1] = file
      end
    end
  end
  return out
end

---What was read of a result file, and the `stat` it was read at.
---@class Testing.Discover.Known.Entry
---@field stamp string  mtime and size of the result file; "" while there is none.
---@field st Testing.Discover.Known.State

---@type table<string, Testing.Discover.Known.Entry>  by the path of the result file
local cache = {}

---How many result files `of` read so far (specs: a second call on an unchanged file reads none).
M.stats = { loads = 0 }

---Forget what was read (specs).
function M.reset()
  cache = {}
end

---The spec files of the project at `root`, from its result file and the files found by name. The
---result file is read again only when its time or size changed since the last call; nothing of the
---project is executed.
---@param root string
---@param opts? Testing.State.Opts
---@return string[]
function M.of(root, opts)
  local state = require("testing.state")
  local path = state.path(root, opts)
  local stat = uv.fs_stat(path)
  local stamp = ""
  if stat and stat.type == "file" then
    local mt = stat.mtime or { sec = 0, nsec = 0 }
    stamp = ("%d.%09d.%d"):format(mt.sec or 0, mt.nsec or 0, stat.size or 0)
  end
  local entry = cache[path]
  if not entry or entry.stamp ~= stamp then
    ---@type Testing.Discover.Known.State
    local slim = {}
    if stamp ~= "" then
      M.stats.loads = M.stats.loads + 1
      local st = state.load(root, opts)
      local has_cases = {}
      for _, case in ipairs(st.cases or {}) do
        has_cases[case.file] = true
      end
      slim = { specs = st.specs, specs_ts = st.specs_ts, has_cases = has_cases }
    end
    entry = { stamp = stamp, st = slim }
    cache[path] = entry
  end
  return M.merge(root, entry.st)
end

return M
