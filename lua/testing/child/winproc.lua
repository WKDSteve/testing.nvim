---@module 'testing.child.winproc'
---@brief The Windows process tree without a process start: children, identity and the kill of a process.
---@description
--- The tree kill of `testing.child` read the process table with a PowerShell start (about a second) and ended the tree
--- with `taskkill` (most of another second): two process starts for every child editor that is killed, a sheet's RPC
--- child at its end included. This module answers the same questions inside the editor:
---
---   children(pid)  the pids whose parent id is `pid`: `vim.api.nvim_get_proc_children` (Neovim reads the process
---                  table natively, a Toolhelp32 snapshot)
---   open(pid)      a handle on the process (`OpenProcess`), with its creation time (`GetProcessTimes`, milliseconds
---                  since the epoch). While the handle is open, Windows does not give the number to another process:
---                  a pid that was looked at stays the same process until `close`.
---   terminate(p)   `TerminateProcess` through that handle (never by number)
---   close(p)       `CloseHandle`
---
--- `load()` returns these functions, or nil where they cannot be had (not Windows, no FFI, a 32-bit build, whose
--- `__stdcall` calls are not declared here, or a declaration that failed): the caller then reads the table with
--- PowerShell as before. The FFI calls take plain numbers and a struct of this module; a declaration of the same
--- function by another plugin with other types makes a call raise (caught), never crash.

local M = {}

-- OpenProcess rights: PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION
local RIGHTS = 0x0001 + 0x1000
-- 100-ns intervals between 1601-01-01 and 1970-01-01, in milliseconds
local EPOCH_MS = 11644473600000

---@class Testing.Winproc.Proc
---@field pid integer
---@field created integer Creation time in milliseconds since the epoch.
---@field handle any The open process handle (cdata).

---@class Testing.Winproc
---@field children fun(pid: integer): integer[]|nil  nil when the table cannot be read
---@field open fun(pid: integer): Testing.Winproc.Proc|nil  nil when the process cannot be opened (gone, access denied)
---@field terminate fun(p: Testing.Winproc.Proc): boolean
---@field close fun(p: Testing.Winproc.Proc)

---@type Testing.Winproc|false|nil
local loaded

---@return Testing.Winproc|nil
local function build()
  local has_ffi, ffi = pcall(require, "ffi")
  if not has_ffi or ffi.os ~= "Windows" or not ffi.abi("64bit") then
    return nil
  end
  local declarations = {
    "struct testing_winproc_filetime { uint32_t lo; uint32_t hi; };",
    "void *OpenProcess(uint32_t access, int inherit, uint32_t pid);",
    "int GetProcessTimes(void *h, struct testing_winproc_filetime *c, struct testing_winproc_filetime *e,"
      .. " struct testing_winproc_filetime *k, struct testing_winproc_filetime *u);",
    "int TerminateProcess(void *h, uint32_t code);",
    "int CloseHandle(void *h);",
  }
  for _, d in ipairs(declarations) do
    -- a function another plugin declared already keeps its declaration (redefining raises); its calls are checked
    pcall(ffi.cdef, d)
  end
  local C = ffi.C
  local probe = pcall(function()
    return C.OpenProcess and C.GetProcessTimes and C.TerminateProcess and C.CloseHandle
  end)
  if not probe then
    return nil
  end

  ---@diagnostic disable-next-line: missing-fields
  local W = {} ---@type Testing.Winproc

  function W.children(pid)
    local ok, list = pcall(vim.api.nvim_get_proc_children, pid)
    if not ok or type(list) ~= "table" then
      return nil
    end
    return list
  end

  function W.open(pid)
    local ok, p = pcall(function()
      local h = C.OpenProcess(RIGHTS, 0, pid)
      if h == nil then
        return nil
      end
      local t = ffi.new("struct testing_winproc_filetime[4]")
      if C.GetProcessTimes(h, t, t + 1, t + 2, t + 3) == 0 then
        C.CloseHandle(h)
        return nil
      end
      local created = math.floor((t[0].hi * 4294967296 + t[0].lo) / 10000 - EPOCH_MS)
      return { pid = pid, created = created, handle = h }
    end)
    return ok and p or nil
  end

  function W.terminate(p)
    local ok, r = pcall(function()
      return C.TerminateProcess(p.handle, 1)
    end)
    return ok and r ~= 0
  end

  function W.close(p)
    if p.handle ~= nil then
      pcall(C.CloseHandle, p.handle)
      p.handle = nil
    end
  end

  return W
end

---The native functions, or nil (see the module header). Built once.
---@return Testing.Winproc|nil
function M.load()
  if loaded == nil then
    local ok, w = pcall(build)
    loaded = ok and w or false
  end
  return loaded or nil
end

---Take the trees below `roots`, with the functions of `w` (a spec passes its own). Each process is opened (its number
---stays its own), checked, terminated, and only THEN asked for its children: a process that has ended starts no new
---one, so the list of its children is complete when it is read. A child counts only when it is not older than its
---parent (a parent id names a process that ended and whose number went to another one; the open handle keeps the
---number of the parent fixed while its children are looked up). A process that cannot be opened is left alone with
---everything below it: what cannot be identified is not killed.
---@param w Testing.Winproc
---@param roots { pid: integer, kill: fun(): boolean }[]  `kill` ends a root (its libuv handle); false when it could not
---@return boolean complete  false when a process table could not be read (the caller then takes the slow way)
function M.kill_trees(w, roots)
  local open, seen, complete = {}, {}, true
  local queue = {}
  for _, r in ipairs(roots) do
    local p = w.open(r.pid)
    if p then
      open[#open + 1] = p
      seen[r.pid] = true
      queue[#queue + 1] = { p = p, kill = r.kill }
    else
      -- the root has ended already (or cannot be opened): its own libuv kill is all that is left
      r.kill()
    end
  end
  local i = 1
  while i <= #queue do
    local item = queue[i]
    i = i + 1
    local killed = item.kill and item.kill() or false
    if not killed then
      w.terminate(item.p)
    end
    local kids = w.children(item.p.pid)
    if kids == nil then
      complete = false
    else
      for _, pid in ipairs(kids) do
        if not seen[pid] then
          seen[pid] = true
          local c = w.open(pid)
          if c then
            open[#open + 1] = c
            if c.created >= item.p.created then
              queue[#queue + 1] = { p = c }
            end
          end
        end
      end
    end
  end
  for _, p in ipairs(open) do
    w.close(p)
  end
  return complete
end

return M
