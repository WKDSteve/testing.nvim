---@module 'testing.perf.trace'
-- @cache-env TESTING_PERF_REAL TMPDIR TEMP TMP
---@brief The spawn trace of a `testing perf` child: every process the editor starts, one JSON line each.
---@description
--- Installed by the child's `-u` file before the project's minimal init (`job.preload`, `testing.child.rpc_init`), so
--- that the starts of a plugin's `setup()` are seen too. It wraps the primitives a process can be started through:
---
---   vim.system, vim.fn.system, vim.fn.systemlist, vim.fn.jobstart, vim.fn.termopen, vim.uv.spawn, io.popen, os.execute
---
--- and writes a line per start into `opts.out` (appended, flushed at once, so a child that is killed keeps its lines):
---
---   { ev = "start", id, us, kind, argv, sync?, pid?, site?, origin?, plugin }
---   { ev = "end", id, us, ms, code? }       -- a process ended (its exit callback) or a synchronous call returned
---   { ev = "wait", id, us, ms }             -- `vim.system(...):wait()` blocked the editor this long
---
--- `us` is `vim.uv.hrtime()` in microseconds: the clock is the machine's monotonic one, so the parent compares it with
--- the bounds of its sheet steps. `vim.system` starts through `uv.spawn`: the two are folded into one start of kind
--- `vim.system` whose end comes from the exit callback of the spawn. `site` is the first frame outside Neovim's own
--- runtime (where the start was asked for, maybe in lib.nvim), `origin` the first frame outside lib.nvim too (the
--- plugin's own line), `plugin` the repository of `origin`. The argv is redacted (`testing.core.ledger.format_argv`).
---
--- `real(name)` tells a sheet which stand-ins the run wants real (`TESTING_PERF_REAL`, `testing perf --real=...`): a
--- step can skip its network stub with `if not require("testing.perf.trace").real("network") then ... end`.

local M = {}

---Lines written at most (a feature that starts processes in a loop must not fill the disk).
M.MAX_LINES = 20000
---Characters of an argv kept.
M.MAX_ARGV = 400

local uv = vim.uv or vim.loop
-- the fields of the standard libraries are replaced on purpose, through a setter (luacheck reads `io.x =` as a mistake)
local io_lib, os_lib = io, os
local function set(t, k, v)
  t[k] = v
end

---@class Testing.Perf.TraceState
---@field fd file*
---@field lines integer
---@field next_id integer
---@field outer? { kind: string, id: integer }
---@field orig table<string, any>
---@field config_dir? string
---@type Testing.Perf.TraceState|nil
local S

---Whether `name` (a program of `fakes`, or `network`) is to be real in this run.
---@param name string
---@return boolean
function M.real(name)
  local v = vim.env.TESTING_PERF_REAL or ""
  if v == "" then
    return false
  end
  for part in v:gmatch("[^,]+") do
    part = vim.trim(part):lower()
    if part == "all" or part == tostring(name):lower() then
      return true
    end
  end
  return false
end

local function now_us()
  return math.floor(uv.hrtime() / 1000)
end

local function write(rec)
  if not S or S.lines >= M.MAX_LINES then
    return
  end
  local ok, text = pcall(vim.json.encode, rec)
  if not ok then
    return
  end
  S.lines = S.lines + 1
  if S.lines == M.MAX_LINES then
    text = vim.json.encode({ ev = "truncated", us = now_us(), lines = S.lines })
  end
  pcall(S.fd.write, S.fd, text, "\n")
  pcall(S.fd.flush, S.fd)
end

---@param src string
---@return string
local function norm_source(src)
  return (src:gsub("^@", ""):gsub("\\", "/"))
end

---A frame of Neovim itself (its Lua runtime, compiled in or on disk), or of this file.
---@param src string
local function is_runtime(src)
  if src:sub(1, 1) ~= "@" then
    return true -- C, a string chunk: nothing a plugin wrote down
  end
  local p = norm_source(src)
  return p:match("^vim/") ~= nil
    or p:find("/runtime/lua/vim/", 1, true) ~= nil
    or p:find("/share/nvim/runtime/", 1, true) ~= nil
    or p:find("testing/perf/trace.lua", 1, true) ~= nil
end

---@param p string
local function is_lib(p)
  return p:find("/lua/lib/nvim/", 1, true) ~= nil
end

---The repository a source file belongs to: `<repo>/lua/...`, `<repo>/plugin/...`, the lazy.nvim folder, the config.
---@param p string
---@return string
function M.repo_of(p)
  if
    S
    and S.config_dir
    and p:sub(1, #S.config_dir + 1):lower() == (S.config_dir .. "/"):lower()
  then
    return "nvim-config"
  end
  local repo = p:match("/lazy/([^/]+)/")
    or p:match("([^/]+)/lua/[^/]+")
    or p:match("([^/]+)/plugin/[^/]+")
  return repo or "?"
end

---@return string|nil site, string|nil origin, string plugin
local function callers()
  local site, origin, from_rpc
  for level = 3, 60 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      break
    end
    local src = info.source or ""
    if src == "<nvim>" then
      -- a chunk sent over RPC (a sheet's `lua` step) asked for it before any plugin frame did
      from_rpc = true
      break
    end
    if not is_runtime(src) then
      local p = norm_source(src)
      local here = ("%s:%d"):format(p, info.currentline or 0)
      site = site or here
      if not is_lib(p) then
        origin = here
        break
      end
    end
  end
  local plugin
  if from_rpc and not origin then
    plugin = "sheet"
  elseif origin and (origin:match("^TESTS/") or origin:find("/TESTS/", 1, true)) then
    -- the sheet's own preparation (a fixture repository, a file), not the plugin
    plugin = "sheet"
  elseif origin then
    plugin = M.repo_of((origin:gsub(":%d+$", "")))
  elseif site then
    plugin = "lib.nvim"
  else
    -- only Neovim's runtime and string chunks on the stack: a sheet's `lua` step, or the runtime itself (LSP)
    plugin = "?"
  end
  return site, origin, plugin
end

---@param cmd any
---@return string
local function argv_text(cmd)
  local ok, text = pcall(require("testing.core.ledger").format_argv, cmd)
  if not ok then
    text = type(cmd) == "table" and table.concat(vim.tbl_map(tostring, cmd), " ") or tostring(cmd)
  end
  text = text:gsub("[%c]", " ")
  -- the child's temporary folders (its sandbox) differ on every run: one placeholder keeps lines comparable
  for _, dir in ipairs({
    os.getenv("TMPDIR") or "",
    os.getenv("TEMP") or "",
    os.getenv("TMP") or "",
  }) do
    if #dir > 3 then
      for _, form in ipairs({ dir, (dir:gsub("\\", "/")) }) do
        local at = text:find(form, 1, true)
        while at do
          text = text:sub(1, at - 1) .. "<TMP>" .. text:sub(at + #form)
          at = text:find(form, at + 5, true)
        end
      end
    end
  end
  if #text > M.MAX_ARGV then
    text = text:sub(1, M.MAX_ARGV) .. "..."
  end
  return text
end

---@param kind string
---@param cmd any
---@param extra? table
---@return integer id
local function start(kind, cmd, extra)
  S.next_id = S.next_id + 1
  local id = S.next_id
  local site, origin, plugin = callers()
  local rec = vim.tbl_extend("force", {
    ev = "start",
    id = id,
    us = now_us(),
    kind = kind,
    argv = argv_text(cmd),
    site = site,
    origin = origin,
    plugin = plugin,
  }, extra or {})
  write(rec)
  return id
end

local function finish(id, t0, code, ev)
  local us = now_us()
  write({ ev = ev or "end", id = id, us = us, ms = (us - t0) / 1000, code = code })
end

---A synchronous primitive: the start, the call, the end with how long the editor waited.
local function timed(kind, orig)
  return function(cmd, ...)
    if not S then
      return orig(cmd, ...)
    end
    local id = start(kind, cmd, { sync = true })
    local t0 = now_us()
    local res = { pcall(orig, cmd, ...) }
    finish(id, t0, kind:match("system") and vim.v.shell_error or nil)
    if not res[1] then
      error(res[2], 0)
    end
    return unpack(res, 2, table.maxn(res))
  end
end

---@param opts? { out: string, config_dir?: string, real?: string }
---@return boolean ok, string|nil err
function M.install(opts)
  if S then
    return true, nil
  end
  opts = opts or {}
  if type(opts.out) ~= "string" or opts.out == "" then
    return false, "testing.perf.trace: opts.out is required"
  end
  local fd, err = io.open(opts.out, "ab")
  if not fd then
    return false, ("testing.perf.trace: cannot open %s: %s"):format(opts.out, tostring(err))
  end
  -- the config as this editor sees it (a `config = "user"` child reads it through a link in its sandbox)
  local config_dir = opts.config_dir or vim.fn.stdpath("config") --[[@as string]]
  if type(opts.real) == "string" and opts.real ~= "" then
    vim.env.TESTING_PERF_REAL = opts.real
  end
  S = {
    fd = fd,
    lines = 0,
    next_id = 0,
    orig = {},
    config_dir = config_dir and (config_dir:gsub("\\", "/"):gsub("/+$", "")) or nil,
  }
  local O = S.orig
  write({ ev = "install", us = now_us(), pid = uv.os_getpid(), config_dir = S.config_dir })

  O.system = vim.system
  vim.system = function(cmd, sopts, on_exit)
    if not S then
      return O.system(cmd, sopts, on_exit)
    end
    local id = start("vim.system", cmd, { sync = on_exit == nil and nil or false })
    S.outer = { kind = "vim.system", id = id }
    local ok, obj = pcall(O.system, cmd, sopts, on_exit)
    S.outer = nil
    if not ok then
      finish(id, now_us(), -1)
      error(obj, 0)
    end
    if type(obj) == "table" and type(obj.wait) == "function" then
      local wait = obj.wait
      obj.wait = function(self, ...)
        local t0 = now_us()
        local r = { wait(self, ...) }
        if S then
          write({ ev = "wait", id = id, us = now_us(), ms = (now_us() - t0) / 1000 })
        end
        return unpack(r, 1, table.maxn(r))
      end
    end
    return obj
  end

  O.spawn = uv.spawn
  uv.spawn = function(path, sopts, on_exit)
    if not S then
      return O.spawn(path, sopts, on_exit)
    end
    local id
    if S.outer then
      id, S.outer = S.outer.id, nil
    else
      local argv = { path }
      for _, a in ipairs((sopts and sopts.args) or {}) do
        argv[#argv + 1] = a
      end
      id = start("uv.spawn", argv, { sync = false })
    end
    local t0 = now_us()
    local wrapped = on_exit
        and function(code, signal)
          finish(id, t0, code)
          return on_exit(code, signal)
        end
      or function(code)
        finish(id, t0, code)
      end
    local handle, pid = O.spawn(path, sopts, wrapped)
    if type(pid) == "number" then
      write({ ev = "pid", id = id, pid = pid })
    else
      finish(id, t0, -1)
    end
    return handle, pid
  end

  O.fn_system = vim.fn.system
  O.fn_systemlist = vim.fn.systemlist
  vim.fn.system = timed("fn.system", O.fn_system)
  vim.fn.systemlist = timed("fn.systemlist", O.fn_systemlist)

  for _, name in ipairs({ "jobstart", "termopen" }) do
    local orig = vim.fn[name]
    if orig then
      O[name] = orig
      vim.fn[name] = function(cmd, jopts)
        if not S then
          return orig(cmd, jopts)
        end
        local id = start(name == "jobstart" and "jobstart" or "termopen", cmd, { sync = false })
        local t0 = now_us()
        jopts = vim.tbl_extend("force", {}, jopts or {})
        local user_exit = jopts.on_exit
        jopts.on_exit = function(job, code, event)
          finish(id, t0, code)
          if user_exit then
            return user_exit(job, code, event)
          end
        end
        local job = orig(cmd, jopts)
        if type(job) == "number" and job > 0 then
          local ok, pid = pcall(vim.fn.jobpid, job)
          if ok then
            write({ ev = "pid", id = id, pid = pid })
          end
        else
          finish(id, t0, -1)
        end
        return job
      end
    end
  end

  O.popen = io_lib.popen
  set(io_lib, "popen", function(cmd, mode)
    if not S then
      return O.popen(cmd, mode)
    end
    start("io.popen", cmd, { sync = true })
    return O.popen(cmd, mode)
  end)
  O.execute = os_lib.execute
  set(os_lib, "execute", function(cmd)
    if not S or cmd == nil then
      return O.execute(cmd)
    end
    local id = start("os.execute", cmd, { sync = true })
    local t0 = now_us()
    local r = { O.execute(cmd) }
    finish(id, t0, type(r[1]) == "number" and r[1] or nil)
    return unpack(r, 1, table.maxn(r))
  end)
  return true, nil
end

---Put every primitive back and close the file. Safe to call twice.
function M.uninstall()
  if not S then
    return
  end
  local O = S.orig
  vim.system = O.system
  uv.spawn = O.spawn
  vim.fn.system = O.fn_system
  vim.fn.systemlist = O.fn_systemlist
  for _, name in ipairs({ "jobstart", "termopen" }) do
    if O[name] then
      vim.fn[name] = O[name]
    end
  end
  set(io_lib, "popen", O.popen)
  set(os_lib, "execute", O.execute)
  pcall(S.fd.close, S.fd)
  S = nil
end

---Whether the trace is installed.
function M.installed()
  return S ~= nil
end

---Read a trace file: the records in order (a line that does not decode is skipped).
---@param path string
---@return table[] records
function M.read(path)
  local out = {}
  local f = io.open(path, "rb")
  if not f then
    return out
  end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == "table" then
      out[#out + 1] = rec
    end
  end
  f:close()
  return out
end

---The starts of a trace with their end, wait and pid folded in: one table per process.
---@param records table[]
---@return Testing.Perf.Spawn[]
function M.fold(records)
  ---@class Testing.Perf.Spawn
  ---@field id integer
  ---@field us integer start, microseconds of the monotonic clock
  ---@field kind string
  ---@field argv string
  ---@field sync? boolean
  ---@field pid? integer
  ---@field ms? number how long it ran (nil: still running when the trace ended)
  ---@field blocked_ms? number how long the editor waited for it (sync calls, `wait()`)
  ---@field code? integer
  ---@field site? string
  ---@field origin? string
  ---@field plugin string
  ---@field step? integer|string the step it happened in (`testing.perf.run`)
  ---@field peak? integer bytes, from the process tree
  ---@field cpu? number seconds, from the process tree
  ---@field alive_at_end? boolean
  local by_id, list = {}, {}
  for _, r in ipairs(records) do
    if r.ev == "start" and r.id then
      local s = {
        id = r.id,
        us = r.us,
        kind = r.kind,
        argv = r.argv,
        sync = r.sync,
        pid = r.pid,
        site = r.site,
        origin = r.origin,
        plugin = r.plugin or "?",
      }
      by_id[r.id] = s
      list[#list + 1] = s
    elseif r.id and by_id[r.id] then
      local s = by_id[r.id]
      if r.ev == "end" then
        s.ms, s.code = r.ms, r.code
        if s.sync then
          s.blocked_ms = r.ms
        end
      elseif r.ev == "wait" then
        s.blocked_ms = (s.blocked_ms or 0) + (r.ms or 0)
        s.sync = true
      elseif r.ev == "pid" then
        s.pid = r.pid
      end
    end
  end
  return list
end

return M
