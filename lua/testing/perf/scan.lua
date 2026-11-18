---@module 'testing.perf.scan'
---@brief The places in a repository's Lua that start a process: what a `testing perf` run should reach.
---@description
--- A line scan of `lua/` and `plugin/` (no parser): a line that calls one of the primitives (`vim.system`,
--- `vim.fn.system`/`systemlist`, `jobstart`, `termopen`, `uv.spawn`, `io.popen`, `os.execute`, `vim.lsp.start`) or a
--- process helper of lib.nvim (`spawn_capture`, `run_argv`, `run_*_captured`, `run_blocking`, `run_detached`,
--- `open_default`, `system.job`, `curl.fetch*`) is a **site**. Comment lines and the text after `--` are left out.
---
--- It is a heuristic on purpose: it finds the candidates, the run proves which were reached. A site is **covered**
--- when a start of the run has it as its `site` or `origin` (`testing.perf.trace`), compared as `file:line` relative
--- to the root. A helper whose call spans lines is reached on the line the call starts, which is the line this scan
--- sees. A definition (`function M.spawn(...)`) is no site: the call inside the wrapper is.

local M = {}

---@class Testing.Perf.Site
---@field file string relative to the root, `/` separators
---@field line integer
---@field what string the name that matched
---@field text string the line, trimmed and cut

---The primitives: a line with one of them starts a process itself.
M.PATTERNS = {
  { "vim%.system%s*%(", "vim.system" },
  { "vim%.fn%.systemlist%s*%(", "vim.fn.systemlist" },
  { "vim%.fn%.system%s*%(", "vim.fn.system" },
  { "jobstart%s*%(", "jobstart" },
  { "termopen%s*%(", "termopen" },
  { "[%w_]%.spawn%s*%(", "uv.spawn" },
  { "io%.popen%s*%(", "io.popen" },
  { "os%.execute%s*%(", "os.execute" },
  { "vim%.lsp%.start%s*%(", "vim.lsp.start" },
}

---Rounds of the fixpoint over lib.nvim's modules (a module that requires one that requires one that spawns).
M.LIB_DEPTH = 4

M.DIRS = { "lua", "plugin" }
---Files read at most (a vendored tree must not make the scan endless).
M.MAX_FILES = 5000

---The code part of a line: nil for a comment line, the text before a `--` that is not inside a string otherwise.
---@param line string
---@return string|nil
function M.code_of(line)
  local trimmed = vim.trim(line)
  if trimmed == "" or trimmed:sub(1, 2) == "--" then
    return nil
  end
  -- cut at the first `--` outside a quoted string (good enough for one line; long strings are not followed)
  local quote
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if quote then
      if c == "\\" then
        i = i + 1
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
      return line:sub(1, i - 1)
    end
    i = i + 1
  end
  return line
end

---The modules a line requires.
---@param code string
---@return string[]
local function requires_of(code)
  local out = {}
  for name in code:gmatch("require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']") do
    out[#out + 1] = name
  end
  return out
end

---What a line starts, or nil: a primitive, a call on an alias of a spawning module (`git.run_async(`), a call on
---such a module required in place (`require("lib.nvim.git").run_async(`).
---@param line string
---@param ctx? { aliases?: table<string, string>, spawning?: table<string, boolean> }
---@return string|nil what
function M.match(line, ctx)
  local code = M.code_of(line)
  if not code then
    return nil
  end
  -- a definition (`function M.spawn(`, `local function jobstart(`) is no call: its signature is left out
  code =
    code:gsub("^%s*local%s+function%s+[%w_]+%s*%b()", ""):gsub("^%s*function%s+[%w_.:]+%s*%b()", "")
  for _, p in ipairs(M.PATTERNS) do
    if code:find(p[1]) then
      return p[2]
    end
  end
  if not ctx then
    return nil
  end
  local spawning = ctx.spawning or {}
  for name in code:gmatch("require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*[%.%(:]") do
    if spawning[name] then
      return name
    end
  end
  for alias, mod in pairs(ctx.aliases or {}) do
    local a = alias:gsub("%p", "%%%0")
    -- `git.run_async(`, `git:run(`, `open_default(`; not the `local git = require(...)` line itself
    if code:find("%f[%w_]" .. a .. "[%.:][%w_]+%s*%(") or code:find("%f[%w_]" .. a .. "%s*%(") then
      return mod
    end
  end
  return nil
end

---The module name of a file below `lua/`: `lua/lib/nvim/git/init.lua` -> `lib.nvim.git`.
---@param rel string
---@return string|nil
function M.module_of(rel)
  local inner = rel:match("^lua/(.+)%.lua$")
  if not inner then
    return nil
  end
  inner = inner:gsub("/init$", "")
  return (inner:gsub("/", "."))
end

local spawning_cache = {}

---The modules of a library that start processes: a primitive in their code, or a require of such a module
---(`M.LIB_DEPTH` rounds). Cached per root for the life of this editor.
---@param lib_root string
---@return table<string, boolean>
function M.spawning_modules(lib_root)
  lib_root = vim.fs.normalize(lib_root):gsub("/+$", "")
  if spawning_cache[lib_root] then
    return spawning_cache[lib_root]
  end
  local direct, reqs = {}, {}
  for _, rel in ipairs(M.lua_files(lib_root, { "lua" })) do
    local mod = M.module_of(rel)
    if mod and not mod:find("@", 1, true) then
      local f = io.open(lib_root .. "/" .. rel, "rb")
      if f then
        local r = {}
        for line in f:lines() do
          local code = M.code_of(line)
          if code then
            if not direct[mod] and M.match(code) then
              direct[mod] = true
            end
            vim.list_extend(r, requires_of(code))
          end
        end
        f:close()
        reqs[mod] = r
      end
    end
  end
  local spawning = vim.deepcopy(direct)
  for _ = 1, M.LIB_DEPTH do
    local grew = false
    for mod, r in pairs(reqs) do
      if not spawning[mod] then
        for _, name in ipairs(r) do
          if spawning[name] then
            spawning[mod], grew = true, true
            break
          end
        end
      end
    end
    if not grew then
      break
    end
  end
  spawning_cache[lib_root] = spawning
  return spawning
end

---@param root string
---@param dirs? string[] default `M.DIRS`
---@return string[] files relative to the root
function M.lua_files(root, dirs)
  local out = {}
  for _, dir in ipairs(dirs or M.DIRS) do
    local base = root .. "/" .. dir
    if vim.uv.fs_stat(base) then
      for name, kind in vim.fs.dir(base, { depth = 20 }) do
        if kind == "file" and name:match("%.lua$") then
          out[#out + 1] = dir .. "/" .. name:gsub("\\", "/")
          if #out >= M.MAX_FILES then
            return out
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

---The sites of a repository. `spawning` (`spawning_modules` of lib.nvim) adds the calls into the library.
---@param root string
---@param spawning? table<string, boolean>
---@return Testing.Perf.Site[]
function M.sites(root, spawning)
  root = vim.fs.normalize(root):gsub("/+$", "")
  local out = {}
  for _, rel in ipairs(M.lua_files(root)) do
    local f = io.open(root .. "/" .. rel, "rb")
    if f then
      local lines = {}
      for line in f:lines() do
        lines[#lines + 1] = line
      end
      f:close()
      -- first the aliases of the file: `local git = require("lib.nvim.git")`
      local aliases = {}
      for _, line in ipairs(lines) do
        local code = M.code_of(line)
        if code then
          local alias, name =
            code:match("local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*$")
          if alias and spawning and spawning[name] then
            aliases[alias] = name
          end
        end
      end
      local ctx = { aliases = aliases, spawning = spawning or {} }
      for n, line in ipairs(lines) do
        local what = M.match(line, ctx)
        if what then
          local text = vim.trim(line)
          out[#out + 1] = {
            file = rel,
            line = n,
            what = what,
            text = #text > 120 and (text:sub(1, 117) .. "...") or text,
          }
        end
      end
    end
  end
  return out
end

---`file:line` of a trace place relative to the root, or nil when it lies elsewhere. Case-insensitive on Windows.
---@param place string|nil `C:/x/repo/lua/a.lua:12`
---@param root string
---@param ci? boolean
---@return string|nil
function M.relative(place, root, ci)
  if not place then
    return nil
  end
  local p = place:gsub("\\", "/")
  local r = vim.fs.normalize(root):gsub("/+$", "") .. "/"
  local head = p:sub(1, #r)
  if (ci and head:lower() == r:lower()) or head == r then
    return p:sub(#r + 1)
  end
  return nil
end

---Which sites the starts reached.
---@param sites Testing.Perf.Site[]
---@param spawns Testing.Perf.Spawn[]
---@param root string
---@param ci? boolean case-insensitive paths (Windows)
---@return { covered: Testing.Perf.Site[], missing: Testing.Perf.Site[], ratio: number|nil }
function M.coverage(sites, spawns, root, ci)
  local hit = {}
  for _, s in ipairs(spawns) do
    for _, place in ipairs({ s.site, s.origin }) do
      local rel = M.relative(place, root, ci)
      if rel then
        hit[ci and rel:lower() or rel] = true
      end
    end
  end
  local covered, missing = {}, {}
  for _, site in ipairs(sites) do
    local key = ("%s:%d"):format(site.file, site.line)
    if hit[ci and key:lower() or key] then
      covered[#covered + 1] = site
    else
      missing[#missing + 1] = site
    end
  end
  return {
    covered = covered,
    missing = missing,
    ratio = #sites > 0 and (#covered / #sites) or nil,
  }
end

return M
