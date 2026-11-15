---@module 'testing.state_prune'
---@brief `testing state prune`: remove the state folders of projects that are gone (a removed worktree).
---@description
--- Every project has a folder `<state>/testing/<name>-<hash12>` (last.json, runs.jsonl, ci.json, the kept results of
--- `ci commit`); its name comes from a hash of the project's path, which cannot be turned back. A run therefore leaves
--- a marker `root.json` (`{ "v": 1, "root": "<project key>" }`) in it (`mark`, from `testing.state.record`), and
--- `prune` removes a folder whose marker names a path that no longer exists: a worktree of a sabotage probe or a
--- session, long gone, left dozens of them.
---
--- Never removed: a folder without a marker (written before markers; listed as a count), a folder whose marker does
--- not belong to it (its hash is not the one of the path it names), a link, a folder with a lock file younger than
--- `BUSY_S` (a run writing there), and anything that is not directly below `<state>/testing/` with the name form
--- `<name>-<12 hex>`.

local M = {}

M.MARKER = "root.json"
M.VERSION = 1
---A `*.lock` file younger than this means a run may be writing there (seconds).
M.BUSY_S = 3600

M.USAGE = {
  "usage: testing state prune [--dry-run] [--state-dir=<dir>]",
  "  removes <state>/testing/<project>-<hash> folders whose project path is gone (a removed worktree);",
  "  folders without the marker root.json, with a fresh lock or of another form stay",
  "exit: 0 done, 2 usage, 3 a folder could not be removed",
}

---@param dir string
---@return string
local function marker_path(dir)
  return dir .. "/" .. M.MARKER
end

---The marker of a folder: the project key it belongs to, or nil.
---@param dir string
---@return string|nil key
function M.read(dir)
  local text = require("lib.nvim.fs.read")(marker_path(dir))
  if not text or #text > 64 * 1024 then
    return nil
  end
  local ok, doc = pcall(vim.json.decode, text)
  if ok and type(doc) == "table" and doc.v == M.VERSION and type(doc.root) == "string" then
    return doc.root
  end
  return nil
end

---Leave the marker in a project's state folder (once: an existing one that names the same project stays).
---@param dir string The state folder (`testing.history.dir`).
---@param root string The project root.
---@return boolean ok
---@return string|nil err
function M.mark(dir, root)
  local key = require("lib.nvim.fs.project_key")(root)
  if M.read(dir) == key then
    return true
  end
  vim.fn.mkdir(dir, "p")
  local f, err = io.open(marker_path(dir), "wb")
  if not f then
    return false, err
  end
  f:write(vim.json.encode({ v = M.VERSION, root = key }), "\n")
  f:close()
  return true
end

---Does the folder hold a lock file younger than `BUSY_S` (anywhere below it, a few levels deep)?
---@param dir string
---@param now integer
---@return boolean
local function busy(dir, now)
  for name, kind in vim.fs.dir(dir, { depth = 3 }) do
    if kind == "file" and name:match("%.lock$") then
      local st = vim.uv.fs_stat(dir .. "/" .. name)
      if st and now - st.mtime.sec < M.BUSY_S then
        return true
      end
    end
  end
  return false
end

---@class Testing.StatePrune.Entry
---@field dir string
---@field name string
---@field root? string The project key of the marker.
---@field state "gone"|"present"|"unmarked"|"foreign"|"busy"

---Look at every project folder below `<base>/testing/`.
---@param base string The state directory (`stdpath('state')`).
---@param now? integer
---@return Testing.StatePrune.Entry[]
function M.scan(base, now)
  now = now or os.time()
  local top = vim.fs.normalize(base) .. "/testing"
  local out = {}
  if not vim.uv.fs_stat(top) then
    return out
  end
  local names = {}
  for name, kind in vim.fs.dir(top) do
    -- `kind` from the directory listing: a link is "link", never followed
    if kind == "directory" and name:match("^.+%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local dir = top .. "/" .. name
    local key = M.read(dir)
    local e = { dir = dir, name = name, root = key }
    if not key then
      e.state = "unmarked"
    elseif vim.fn.sha256(key):sub(1, 12) ~= name:sub(-12) then
      e.state = "foreign"
    elseif vim.uv.fs_stat(key) then
      e.state = "present"
    elseif busy(dir, now) then
      e.state = "busy"
    else
      e.state = "gone"
    end
    out[#out + 1] = e
  end
  return out
end

---`testing state prune ...`
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer code
function M.main(argv, sv)
  if argv[1] ~= "prune" then
    for _, l in ipairs(M.USAGE) do
      sv.err(l)
    end
    return (argv[1] == "--help" or argv[1] == "-h") and 0 or 2
  end
  local dry, base = false, nil
  for i = 2, #argv do
    local a = argv[i]
    if a == "--dry-run" then
      dry = true
    elseif a:match("^%-%-state%-dir=.") then
      base = a:sub(#"--state-dir=" + 1)
    elseif a == "--help" or a == "-h" then
      for _, l in ipairs(M.USAGE) do
        sv.out(l)
      end
      return 0
    else
      sv.err("testing state prune: unknown argument " .. a)
      for _, l in ipairs(M.USAGE) do
        sv.err(l)
      end
      return 2
    end
  end
  base = base or vim.fn.stdpath("state") --[[@as string]]
  local count = { gone = 0, present = 0, unmarked = 0, foreign = 0, busy = 0 }
  local failed = 0
  for _, e in ipairs(M.scan(base)) do
    count[e.state] = count[e.state] + 1
    if e.state == "gone" then
      if dry then
        sv.out(("would remove %s (%s is gone)"):format(e.name, e.root))
      elseif vim.fn.delete(e.dir, "rf") == 0 then
        sv.out(("removed %s (%s is gone)"):format(e.name, e.root))
      else
        failed = failed + 1
        sv.err(("testing state prune: could not remove %s"):format(e.dir))
      end
    elseif e.state == "busy" then
      sv.out(("kept %s: %s is gone, but a lock there is fresh (a run?)"):format(e.name, e.root))
    end
  end
  sv.out(
    ("testing state prune: %d %s, %d kept (project there), %d without a marker (older than markers: left alone)%s"):format(
      count.gone,
      dry and "to remove" or "removed",
      count.present,
      count.unmarked,
      count.foreign > 0 and (", %d with a marker of another folder"):format(count.foreign) or ""
    )
  )
  return failed > 0 and 3 or 0
end

return M
