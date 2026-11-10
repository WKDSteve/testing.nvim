---@module 'testing.child.winproc'
---@brief The Windows process tree without a process start: children, identity and the kill of a process.
---@description
--- The tree kill of `testing.child` read the process table with a PowerShell start (about a second) and ended the tree
--- with `taskkill` (most of another second): two process starts for every child editor that is killed, a sheet's RPC
--- child at its end included. This module answers the same questions inside the editor:
---
---   children(pid)  the pids whose parent id is `pid`: `vim.api.nvim_get_proc_children` (Neovim reads the process
---                  table natively, a Toolhelp32 snapshot)
---   open(pid)      a handle on the process (`OpenProcess`), with its creation time (`GetProcessTimes`, 100-ns ticks,
---                  compared only). While the handle is open, Windows does not give the number to another process:
---                  a pid that was looked at stays the same process until `close`.
---   terminate(p)   `TerminateProcess` through that handle (never by number)
---   wait(p, ms)    until the process has ended (`WaitForSingleObject`, at most `ms`)
---   close(p)       `CloseHandle`
---
--- `load()` returns these functions, or nil where they cannot be had (not Windows, no FFI, a 32-bit build, whose
--- `__stdcall` calls are not declared here, or a declaration that failed): the caller then reads the table with
--- PowerShell as before. The FFI calls take plain numbers and a struct of this module; a declaration of the same
--- function by another plugin with other types makes a call raise (caught), never crash.

local M = {}

-- OpenProcess rights: PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE
local RIGHTS = 0x0001 + 0x1000 + 0x00100000
-- how long the walk waits for a terminated process to be gone before it asks for its children (TerminateProcess
-- returns before the process has ended; a `CreateProcess` it was in the middle of could still add a child)
M.WAIT_MS = 200

---@class Testing.Winproc.Proc
---@field pid integer
---@field created any Creation time (100-ns ticks since 1601 as `uint64_t` cdata, or a number in a spec): compared only.
---@field handle any The open process handle (cdata).

---@class Testing.Winproc
---@field children fun(pid: integer): integer[]|nil  nil when the table cannot be read
---@field open fun(pid: integer): Testing.Winproc.Proc|nil  nil when the process cannot be opened (gone, access denied)
---@field terminate fun(p: Testing.Winproc.Proc): boolean
---@field wait? fun(p: Testing.Winproc.Proc, ms: integer)
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
    "uint32_t WaitForSingleObject(void *h, uint32_t ms);",
    "int CloseHandle(void *h);",
  }
  for _, d in ipairs(declarations) do
    -- a function another plugin declared already keeps its declaration (redefining raises); its calls are checked
    pcall(ffi.cdef, d)
  end
  local C = ffi.C
  local probe = pcall(function()
    return C.OpenProcess
      and C.GetProcessTimes
      and C.TerminateProcess
      and C.WaitForSingleObject
      and C.CloseHandle
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
    local ok_open, h = pcall(C.OpenProcess, RIGHTS, 0, pid)
    if not ok_open or h == nil then
      return nil
    end
    local ok, created = pcall(function()
      local t = ffi.new("struct testing_winproc_filetime[4]")
      if C.GetProcessTimes(h, t, t + 1, t + 2, t + 3) == 0 then
        return nil
      end
      -- uint64_t cdata times a number stays uint64_t: exact to the 100 ns of the FILETIME
      return ffi.cast("uint64_t", t[0].hi) * 4294967296 + t[0].lo
    end)
    if not ok or created == nil then
      -- the handle never leaves this function without its creation time: closed here, also after a raise
      pcall(C.CloseHandle, h)
      return nil
    end
    return { pid = pid, created = created, handle = h }
  end

  function W.terminate(p)
    local ok, r = pcall(C.TerminateProcess, p.handle, 1)
    return ok and r ~= 0
  end

  function W.wait(p, ms)
    pcall(C.WaitForSingleObject, p.handle, ms)
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

---@param list integer[]|nil
---@param pid integer
---@return boolean
local function listed(list, pid)
  for _, p in ipairs(list or {}) do
    if p == pid then
      return true
    end
  end
  return false
end

---Take the trees below `roots`, with the functions of `w` (a spec passes its own). Nothing is touched unless the table
---can be read for every root (false: the caller takes the slow way while the roots still live). Then each process is
---opened (its number stays its own), terminated, waited for, and only THEN asked for its children: a process that has
---ended starts no new one, so the list of its children is complete when it is read. A child counts when it is not
---older than its parent (a parent id can name a process that ended and whose number went to another one; the open
---handle keeps the number of the parent fixed meanwhile) AND the table still names it as a child of that parent after
---it was opened (between the first look and the open, a child can end and its number go to a stranger). A process
---that cannot be opened is left alone with everything below it, and a table that cannot be read later leaves that
---part of the tree: what cannot be identified is never killed.
---@param w Testing.Winproc
---@param roots { pid: integer, kill: fun(): boolean }[]  `kill` ends a root (its libuv handle); false when it could not
---@return boolean done  false: nothing was touched (a table could not be read)
function M.kill_trees(w, roots)
  for _, r in ipairs(roots) do
    if w.children(r.pid) == nil then
      return false
    end
  end
  local open, seen = {}, {}
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
    if w.wait then
      w.wait(item.p, M.WAIT_MS)
    end
    local kids = w.children(item.p.pid)
    for _, pid in ipairs(kids or {}) do
      if not seen[pid] then
        seen[pid] = true
        local c = w.open(pid)
        if c then
          open[#open + 1] = c
          if c.created >= item.p.created and listed(w.children(item.p.pid), pid) then
            queue[#queue + 1] = { p = c }
          end
        end
      end
    end
  end
  for _, p in ipairs(open) do
    w.close(p)
  end
  return true
end

return M
