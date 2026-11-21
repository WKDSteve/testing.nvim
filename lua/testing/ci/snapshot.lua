---@module 'testing.ci.snapshot'
-- handrolled-ok: the age of a leftover snapshot directory, not a clock subtraction of a measurement
---@brief The snapshot of one commit: a detached `git worktree` outside the repository, for `testing ci commit`.
---@description
--- `create(root, rev)` checks the commit out with `git worktree add --detach` into a directory of its own below the
--- state directory (`<state>/testing/snap/<sha8>-<random>/tree`, with a throwaway state directory beside it; on Windows
--- below the temp directory instead, `M.in_temp`). Only
--- objects are read: the working tree, the index and the branches of the checkout stay as they are, so another session
--- may keep editing, committing and rebasing there while the snapshot is tested. The repository's hooks do not run
--- (an empty `core.hooksPath`), submodules are not checked out.
---
--- `remove(snap)` takes the worktree away again (`git worktree remove --force`, the directory as a fallback); `sweep()`
--- removes the snapshots a crashed run left behind (older than `M.MAX_AGE`) and prunes their entries in `root`.
--- Nothing here raises: a failure is `nil` and a message.

local M = {}

---Seconds after which a leftover snapshot is swept (a run never takes that long).
M.MAX_AGE = 12 * 3600

---@class Testing.Ci.Snapshot
---@field root string The repository the snapshot belongs to.
---@field sha string The full commit id.
---@field dir string The directory of the snapshot (holds `tree` and `state`).
---@field tree string The worktree: the commit's files.
---@field state string A throwaway state directory for the run on the snapshot.
---@field warm? boolean The warm snapshot of the repository (`M.warm`): it stays, `remove` gives its lock back.
---@field lock? string The lock file of a warm snapshot.

---Replaced by a spec: `vim.system`.
---@type function
M.system = vim.system

---@param argv string[]
---@param cwd string
---@return integer code
---@return string stdout
---@return string stderr
local function git(argv, cwd)
  local ok, res = pcall(function()
    return M.system(vim.list_extend({ "git" }, argv), { cwd = cwd, text = true }):wait(120000)
  end)
  if not ok or not res then
    return 127, "", tostring(res)
  end
  return res.code or 1, res.stdout or "", res.stderr or ""
end

---Replaced by a spec: whether snapshots go below the temp directory instead of the state directory (Windows). The
---state directory is below `AppData`, and a packaged app (MSIX, such as the Claude desktop app) writes there into a
---private copy of its own that WSL and a container engine cannot see: a container spec of the snapshot then fails
---with "no such file or directory". The temp directory is not redirected. Elsewhere the state directory stays (the
---podman machine of macOS mounts `/Users`, not the temp directory below `/var/folders`).
---@type boolean
M.in_temp = require("testing.platform").is_windows()

---Replaced by a spec: the temp directory.
---@type fun(): string
M.temp_dir = vim.uv.os_tmpdir

---The base directory of all snapshots: `<temp>/testing/snap` on Windows, else `<state>/testing/snap`.
---@param opts? { state_dir?: string }
---@return string
function M.base(opts)
  local dir = M.in_temp and M.temp_dir() or (opts and opts.state_dir) or vim.fn.stdpath("state")
  return vim.fs.normalize(dir) .. "/testing/snap"
end

---A revision as the command line may name it: no leading `-` (an option to git), no blank, no shell character.
---@param rev string
---@return boolean
function M.valid_rev(rev)
  return type(rev) == "string"
    and rev ~= ""
    and #rev <= 200
    and rev:sub(1, 1) ~= "-"
    and not rev:find("[%s%c;&|`$<>\"'\\]")
end

---The full commit id of `rev` in `root`.
---@param root string
---@param rev string
---@return string|nil sha
---@return string|nil problem
function M.resolve(root, rev)
  if not M.valid_rev(rev) then
    return nil, ("not a revision: %q"):format(rev)
  end
  local code, out, err = git({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, root)
  local sha = vim.trim(out)
  if code ~= 0 or not sha:match("^%x+$") then
    return nil, ("unknown revision %s%s"):format(rev, err ~= "" and (": " .. vim.trim(err)) or "")
  end
  return sha
end

---The first parent of a commit, nil for a root commit.
---@param root string
---@param sha string
---@return string|nil
function M.parent(root, sha)
  local code, out = git({ "rev-parse", "--verify", "--quiet", sha .. "^1^{commit}" }, root)
  local p = vim.trim(out)
  return code == 0 and p:match("^%x+$") and p or nil
end

---The files a commit changes against `base` (all its files for a root commit), slash separated.
---@param root string
---@param sha string
---@param base? string
---@return string[]|nil files
---@return string|nil problem
function M.changed_files(root, sha, base)
  local argv = base and { "diff", "--name-only", "--no-renames", "-z", base, sha }
    or { "ls-tree", "-r", "--name-only", "-z", sha }
  local code, out, err = git(argv, root)
  if code ~= 0 then
    return nil, "git " .. argv[1] .. ": " .. vim.trim(err)
  end
  local files = vim.split(out, "\0", { trimempty = true })
  table.sort(files)
  return files
end

---@param n integer
---@return string
local function random_hex(n)
  local t = {}
  for i = 1, n do
    t[i] = ("%x"):format(math.random(0, 15))
  end
  return table.concat(t)
end

---Check the commit `sha` of `root` out into a snapshot of its own.
---@param root string
---@param sha string A full commit id (`resolve`).
---@param opts? { state_dir?: string }
---@return Testing.Ci.Snapshot|nil snap
---@return string|nil problem
function M.create(root, sha, opts)
  if not sha:match("^%x+$") then
    return nil, "not a commit id: " .. tostring(sha)
  end
  math.randomseed(vim.uv.hrtime() % 2 ^ 31)
  local dir = ("%s/%s-%s"):format(M.base(opts), sha:sub(1, 8), random_hex(6))
  local tree, state, hooks = dir .. "/tree", dir .. "/state", dir .. "/no-hooks"
  if vim.fn.mkdir(state, "p") ~= 1 or vim.fn.mkdir(hooks, "p") ~= 1 then
    return nil, "cannot create " .. dir
  end
  local code, _, err = git({
    "-c",
    "core.hooksPath=" .. hooks,
    "worktree",
    "add",
    "--detach",
    "--quiet",
    tree,
    sha,
  }, root)
  if code ~= 0 then
    vim.fn.delete(dir, "rf")
    return nil, ("git worktree add %s: %s"):format(sha:sub(1, 12), vim.trim(err))
  end
  return { root = root, sha = sha, dir = dir, tree = tree, state = state }
end

---Seconds after which an unused warm snapshot is swept.
M.WARM_MAX_AGE = 7 * 24 * 3600

---The directory of the warm snapshot of a repository (one per repository, its key from the path).
---@param root string
---@param opts? { state_dir?: string }
---@return string dir
---@return string lock
function M.warm_dir(root, opts)
  local key = vim.fn.sha256(vim.fs.normalize(root)):sub(1, 12)
  local dir = ("%s/warm-%s"):format(M.base(opts), key)
  return dir, dir .. ".lock"
end

---Is the process alive? (Another user's process answers EPERM: alive.)
---@param pid integer
---@return boolean
local function alive(pid)
  local ok, err = vim.uv.kill(pid, 0)
  return ok == 0 or (type(err) == "string" and err:find("EPERM", 1, true) ~= nil)
end

---Take the lock of a warm snapshot; a lock whose process is gone is taken over.
---@param lock string
---@return boolean
local function take_lock(lock)
  local create = require("lib.nvim.fs.create_exclusive")
  local body = vim.json.encode({ pid = vim.uv.os_getpid(), started = os.time() })
  if create(lock, body) then
    return true
  end
  local okd, doc = pcall(vim.json.decode, require("lib.nvim.fs.read")(lock) or "")
  local pid = okd and type(doc) == "table" and tonumber(doc.pid) or nil
  if pid and alive(pid) then
    return false
  end
  -- a dead holder's lock: only the run that makes the takeover mark may remove it, so two runs that both saw the dead
  -- lock cannot remove each other's new one (that would put two runs into one tree); the other one takes a fresh
  -- snapshot. A mark left by a crash in these few lines is older than a minute and is removed.
  local mark = lock .. ".takeover"
  local st = vim.uv.fs_stat(mark)
  if st and os.time() - st.mtime.sec > 60 then
    os.remove(mark)
  end
  if not create(mark, body) then
    return false
  end
  -- read again under the mark: another run may have taken it over just before
  local okd2, doc2 = pcall(vim.json.decode, require("lib.nvim.fs.read")(lock) or "")
  local pid2 = okd2 and type(doc2) == "table" and tonumber(doc2.pid) or nil
  local taken = false
  if not (pid2 and alive(pid2)) then
    os.remove(lock)
    taken = create(lock, body) and true or false
  end
  os.remove(mark)
  return taken
end

---Check the commit `sha` out into the WARM snapshot of `root`: one worktree per repository that stays between runs and
---is moved to the next commit with `checkout --force --detach` and `clean -ffdx`, so only the files that differ are
---written. A fresh worktree writes every file of the commit, and on Windows the first read of each new file is what costs
---(tasks-vault, 7863 files: the gate took 24.5 s on a fresh worktree and 2.8 s on the second run; a whole run of
---`ci --snapshot` 36 s). The content is the commit's exactly, as with `create`; the throwaway state is emptied each
---time.
---nil while another run holds the warm snapshot (the caller takes a fresh one) or when it cannot be made.
---@param root string
---@param sha string A full commit id.
---@param opts? { state_dir?: string }
---@return Testing.Ci.Snapshot|nil snap `warm = true`, `lock`: `remove` only gives the lock back
---@return string|nil problem
function M.warm(root, sha, opts)
  if not sha:match("^%x+$") then
    return nil, "not a commit id: " .. tostring(sha)
  end
  local dir, lock = M.warm_dir(root, opts)
  if vim.fn.mkdir(M.base(opts), "p") == 0 and vim.fn.isdirectory(M.base(opts)) ~= 1 then
    return nil, "cannot create " .. M.base(opts)
  end
  if not take_lock(lock) then
    return nil, "the warm snapshot is in use"
  end
  local tree, state, hooks = dir .. "/tree", dir .. "/state", dir .. "/no-hooks"
  local function fail(why)
    os.remove(lock)
    return nil, why
  end
  vim.fn.mkdir(hooks, "p")
  local moved = false
  if vim.fn.isdirectory(tree .. "/.git") == 1 or vim.fn.filereadable(tree .. "/.git") == 1 then
    local c1 = git(
      { "-c", "core.hooksPath=" .. hooks, "checkout", "--force", "--detach", "--quiet", sha },
      tree
    )
    local c2 = c1 == 0 and git({ "clean", "-ffdxq" }, tree) or 1
    moved = c1 == 0 and c2 == 0
    if not moved then
      -- a broken warm tree: start it again
      git({ "worktree", "remove", "--force", tree }, root)
      vim.fn.delete(tree, "rf")
      git({ "worktree", "prune" }, root)
    end
  end
  if not moved then
    local code, _, err = git({
      "-c",
      "core.hooksPath=" .. hooks,
      "worktree",
      "add",
      "--detach",
      "--quiet",
      "--force",
      tree,
      sha,
    }, root)
    if code ~= 0 then
      vim.fn.delete(tree, "rf")
      return fail(("git worktree add %s: %s"):format(sha:sub(1, 12), vim.trim(err)))
    end
  end
  vim.fn.delete(state, "rf")
  if vim.fn.mkdir(state, "p") ~= 1 then
    return fail("cannot create " .. state)
  end
  -- its age for `sweep`: the directory's time is the last use
  pcall(vim.uv.fs_utime, dir, os.time(), os.time())
  return {
    root = root,
    sha = sha,
    dir = dir,
    tree = tree,
    state = state,
    warm = true,
    lock = lock,
  }
end

---Take a snapshot away: its worktree entry in the repository and its directory. A warm snapshot stays: only its lock
---is given back.
---@param snap Testing.Ci.Snapshot
---@return boolean ok
---@return string|nil problem
function M.remove(snap)
  if snap.warm then
    os.remove(snap.lock)
    return true
  end
  local code, _, err = git({ "worktree", "remove", "--force", snap.tree }, snap.root)
  vim.fn.delete(snap.dir, "rf")
  if code ~= 0 then
    -- the directory is gone now: prune takes the entry that pointed at it
    git({ "worktree", "prune" }, snap.root)
  end
  if vim.fn.isdirectory(snap.dir) == 1 then
    return false, ("cannot remove %s: %s"):format(snap.dir, vim.trim(err))
  end
  return true
end

---Remove the snapshots older than `M.MAX_AGE` (a crashed run's) and prune the entries they left in `root`.
---@param root string
---@param opts? { state_dir?: string, now?: integer }
---@return integer removed
function M.sweep(root, opts)
  local base = M.base(opts)
  local now = (opts and opts.now) or os.time()
  local removed = 0
  for name, kind in vim.fs.dir(base) do
    if kind == "directory" and name:match("^%x+%-%x+$") then
      local st = vim.uv.fs_stat(base .. "/" .. name)
      if st and now - st.mtime.sec > M.MAX_AGE then
        vim.fn.delete(base .. "/" .. name, "rf")
        removed = removed + 1
      end
    elseif kind == "directory" and name:match("^warm%-%x+$") then
      -- a warm snapshot nobody used for a week, and that no run holds now
      local st = vim.uv.fs_stat(base .. "/" .. name)
      local held = vim.uv.fs_stat(base .. "/" .. name .. ".lock") ~= nil
      if st and not held and now - st.mtime.sec > M.WARM_MAX_AGE then
        vim.fn.delete(base .. "/" .. name, "rf")
        removed = removed + 1
      end
    end
  end
  if removed > 0 then
    git({ "worktree", "prune" }, root)
  end
  return removed
end

return M
