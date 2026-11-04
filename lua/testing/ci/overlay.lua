---@module 'testing.ci.overlay'
---@brief `testing ci --snapshot --with=<paths>`: the files of the working tree the caller names, laid over the snapshot.
---@description
--- A run on "the committed state plus my own changes": the snapshot of the commit gets, for each path named, what the
--- working tree has there now (a file, a directory with everything below it) or loses the file when the working tree has
--- none. Everything else in the working tree, i.e. the uncommitted work of other sessions, is not looked at. The checkout,
--- its index and its branches are not touched: files are only read from the working tree and written into the snapshot.
---
--- Paths are relative to the root, inside it, never below `.git`. At most `MAX_FILES` files are copied.
local M = {}

M.MAX_FILES = 2000

---@param path string
---@return string|nil clean  The path as `a/b/c`, nil when it is not one this module takes.
---@return string|nil problem
function M.clean(path)
  if type(path) ~= "string" or path == "" then
    return nil, "an empty path"
  end
  local p = path:gsub("\\", "/"):gsub("/+$", ""):gsub("^%./", "")
  if p == "" or p:find("^/") or p:find("^%a:") then
    return nil, ("%s: a path relative to the root is expected"):format(path)
  end
  if p:find("%c") then
    return nil, ("%s: control characters in a path"):format(path)
  end
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      return nil, ("%s: leaves the root"):format(path)
    end
    if part:lower() == ".git" then
      return nil, ("%s: below .git"):format(path)
    end
  end
  return p, nil
end

---@param dir string
---@param out string[]
---@param rel string
local function walk(dir, rel, out)
  for name, kind in vim.fs.dir(dir) do
    local child = rel .. "/" .. name
    if kind == "directory" then
      if name:lower() ~= ".git" then
        walk(dir .. "/" .. name, child, out)
      end
    elseif kind == "file" then
      out[#out + 1] = child
    end
    if #out > M.MAX_FILES then
      return
    end
  end
end

---Lay the named paths of `root` over `tree`.
---@param root string The working tree.
---@param tree string The snapshot's worktree.
---@param paths string[]
---@return integer|nil files  How many files were copied or removed.
---@return string|nil problem
function M.apply(root, tree, paths)
  local files = {}
  for _, raw in ipairs(paths) do
    local p, problem = M.clean(raw)
    if not p then
      return nil, problem
    end
    local st = vim.uv.fs_lstat(root .. "/" .. p)
    if st and st.type == "directory" then
      walk(root .. "/" .. p, p, files)
    else
      files[#files + 1] = p
    end
    if #files > M.MAX_FILES then
      return nil, ("more than %d files: name fewer paths"):format(M.MAX_FILES)
    end
  end
  -- a directory also loses the files it no longer has
  local count = 0
  for _, p in ipairs(files) do
    local src, dst = root .. "/" .. p, tree .. "/" .. p
    local st = vim.uv.fs_lstat(src)
    if st and st.type == "file" then
      vim.fn.mkdir(vim.fs.dirname(dst), "p")
      local ok, err = vim.uv.fs_copyfile(src, dst)
      if not ok then
        return nil, ("%s: %s"):format(p, tostring(err))
      end
      count = count + 1
    elseif st == nil then
      local gone = vim.uv.fs_lstat(dst)
      if gone then
        if gone.type == "directory" then
          vim.fn.delete(dst, "rf")
        else
          os.remove(dst)
        end
        count = count + 1
      end
    else
      return nil, ("%s: only files and directories can be laid over a snapshot"):format(p)
    end
  end
  return count, nil
end

return M
