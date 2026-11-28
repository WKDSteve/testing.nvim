---@module 'testing.perf.scan'
---@brief The places in a repository's Lua that start a process: what a `testing perf` run should reach.
---@description
--- A line scan of `lua/` and `plugin/` (no parser): a line that calls one of the primitives (`vim.system`,
--- `vim.fn.system`/`systemlist`, `jobstart`, `termopen`, `uv.spawn`, `io.popen`, `os.execute`, `vim.lsp.start`, also
--- handed to `pcall` as a value, also wrapped over two lines) or a function of lib.nvim that starts a process is a
--- **site**. Which functions of lib.nvim those are is computed per function (`spawning_modules`): a top-level function
--- whose body calls a primitive, or a function of its own module or of a required one that does (a fixpoint).
--- Comment lines and the text after `--` are left out.
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
---@field span? integer lines the site covers (2 for a call wrapped onto the next line)
---@field tail_local? boolean the tail call's function is local: only an unqualified call in its own file reaches it
---@field tail_fn? string a tail call (`return f(...)`): the name of the function around it; its frame is gone at run
---time, so the site counts as reached when a caller of that function is on a start's stack

---The primitives: a line with one of them starts a process itself.
M.PATTERNS = {
  { "vim%.system%s*%(", "vim.system" },
  { "vim%.fn%.systemlist%s*%(", "vim.fn.systemlist" },
  { "vim%.fn%.system%s*%(", "vim.fn.system" },
  { "jobstart%s*%(", "jobstart" },
  { "termopen%s*%(", "termopen" },
  { "%f[%w_]uv%.spawn%s*%(", "uv.spawn" },
  { "%f[%w_]loop%.spawn%s*%(", "uv.spawn" },
  { "io%.popen%s*%(", "io.popen" },
  { "os%.execute%s*%(", "os.execute" },
  { "vim%.lsp%.start%s*%(", "vim.lsp.start" },
  -- a primitive handed to pcall as a value: `pcall(vim.system, argv)`, `pcall(fn.jobstart, cmd, opts)`
  { "x?pcall%s*%(%s*[%w_.]*%.system%s*[,%)]", "pcall(system)" },
  { "x?pcall%s*%(%s*[%w_.]*%.systemlist%s*[,%)]", "pcall(systemlist)" },
  { "x?pcall%s*%(%s*[%w_.]*jobstart%s*[,%)]", "pcall(jobstart)" },
  { "x?pcall%s*%(%s*[%w_.]*termopen%s*[,%)]", "pcall(termopen)" },
  { "x?pcall%s*%(%s*[%w_.]*%f[%w_]uv%.spawn%s*[,%)]", "pcall(uv.spawn)" },
  { "x?pcall%s*%(%s*io%.popen%s*[,%)]", "pcall(io.popen)" },
  { "x?pcall%s*%(%s*os%.execute%s*[,%)]", "pcall(os.execute)" },
}

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

---A line with the contents of its string literals blanked (the quotes stay): `"vim.system() failed"` in a message is
---no call.
---@param code string
---@return string
function M.strip_strings(code)
  local out, quote, i = {}, nil, 1
  while i <= #code do
    local c = code:sub(i, i)
    if quote then
      if c == "\\" then
        out[#out + 1] = "  "
        i = i + 1
      elseif c == quote then
        quote = nil
        out[#out + 1] = c
      else
        out[#out + 1] = " "
      end
    else
      if c == '"' or c == "'" then
        quote = c
      end
      out[#out + 1] = c
    end
    i = i + 1
  end
  return table.concat(out)
end

---The alias a line binds to a module: `local git = require("m")` or `local ok, git = pcall(require, "m")`.
---@param code string
---@return string|nil alias, string|nil module
function M.alias_of(code)
  local alias, name =
    code:match("local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*$")
  if alias then
    return alias, name
  end
  return code:match(
    "local%s+[%w_]+%s*,%s*([%w_]+)%s*=%s*pcall%s*%(%s*require%s*,%s*[\"']([%w_%.@%-]+)[\"']"
  )
end

---The names a file gives `vim.fn` and its process functions: `local fn = vim.fn` (`tables.fn`: `fn.system(` and
---`fn.systemlist(` start a process) and `local system = vim.fn.system` (`funcs.system = "vim.fn.system"`: `system(`
---does). The patterns of `M.PATTERNS` know `vim.fn.system(` only in full (mdview.nvim, reposcope.nvim).
---@param lines string[]
---@return { tables: table<string, boolean>, funcs: table<string, string> }
function M.vim_fn_aliases(lines)
  local out = { tables = {}, funcs = {} }
  for _, line in ipairs(lines) do
    local code = M.code_of(line)
    if code then
      local tbl = code:match("^%s*local%s+([%w_]+)%s*=%s*vim%.fn%s*$")
      if tbl then
        out.tables[tbl] = true
      end
      local name, fn = code:match("^%s*local%s+([%w_]+)%s*=%s*vim%.fn%.(system[%w]*)%s*$")
      if name and (fn == "system" or fn == "systemlist") then
        out.funcs[name] = "vim.fn." .. fn
      end
      -- `local system = vim.system`, `local system = (opts.system or vim.system)`, `... = a or vim.system`
      local sys = code:match("^%s*local%s+([%w_]+)%s*=%s*vim%.system%s*$")
        or code:match("^%s*local%s+([%w_]+)%s*=%s*%(?[%w_.%s]-%f[%w_]or%s+vim%.system%s*%)?%s*$")
      if sys then
        out.funcs[sys] = "vim.system"
      end
    end
  end
  return out
end

---What a line starts, or nil: a primitive, a call on an alias of a spawning module (`git.run_async(`), a call on
---such a module required in place (`require("lib.nvim.git").run_async(`).
---@param line string
---@param ctx? { aliases?: table<string, string>, spawning?: table<string, table<string, boolean>>, funcs?: table<string, string>, fields?: table<string, string> }
---@return string|nil what
function M.match(line, ctx)
  local code = M.code_of(line)
  if not code then
    return nil
  end
  -- a definition (`function M.spawn(`, `local function jobstart(`) is no call: its signature is left out
  code =
    code:gsub("^%s*local%s+function%s+[%w_]+%s*%b()", ""):gsub("^%s*function%s+[%w_.:]+%s*%b()", "")
  local bare = M.strip_strings(code)
  for _, p in ipairs(M.PATTERNS) do
    if bare:find(p[1]) then
      return p[2]
    end
  end
  if not ctx then
    return nil
  end
  -- `vim.fn` under a name of the file (`M.vim_fn_aliases`): `fn.system(`, `fn.systemlist(`
  for tbl in pairs(ctx.tables or {}) do
    local t = tbl:gsub("%p", "%%%0")
    for _, fn in ipairs({ "systemlist", "system" }) do
      if bare:find("%f[%w_.:]" .. t .. "%." .. fn .. "%s*%(") then
        return "vim.fn." .. fn
      end
    end
  end
  -- a spawning function bound to a name of the plugin: `local resolve = path.resolve` -> `resolve(`, a field
  -- `M.request = helper.request` -> `.request(` / `:request(`
  for name, what in pairs(ctx.funcs or {}) do
    if bare:find("%f[%w_]" .. name .. "%s*%(") and not bare:find("[%.:]" .. name .. "%s*%(") then
      return what
    end
    -- the name handed to pcall as a value: `pcall(system, argv, ...)`
    if bare:find("x?pcall%s*%(%s*" .. name .. "%s*[,%)]") then
      return what
    end
  end
  for key, what in pairs(ctx.fields or {}) do
    -- `M.request = helper.request`: a call `M.request(` / `M:request(` on that table, not `client:request(`
    local tbl, name = key:match("^([%w_]+)%.([%w_]+)$")
    if tbl and bare:find("%f[%w_]" .. tbl .. "[%.:]" .. name .. "%s*%(") then
      return what
    end
  end
  local spawning = ctx.spawning or {}
  for name, rest in code:gmatch("require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*([%.%(:][^%)]*)") do
    -- `require("m").f(` (f starts a process) or `require("m")(` (the module is callable and does); a field read
    -- (`require("m").f` alone) is no call
    local fns = spawning[name]
    if fns then
      local fn = rest:match("^[%.:]([%w_]+)%s*%(")
      if (fn and fns[fn]) or (rest:match("^%(") and fns.__call) then
        return name .. (fn and ("." .. fn) or "")
      end
    end
  end
  for alias, mod in pairs(ctx.aliases or {}) do
    local fns = spawning[mod] or {}
    local a = alias:gsub("%p", "%%%0")
    -- `git.run_async(` when run_async starts a process; `open_default(` when the module is callable and does
    for fn in bare:gmatch("%f[%w_]" .. a .. "[%.:]([%w_]+)%s*%(") do
      if fns[fn] then
        return mod .. "." .. fn
      end
    end
    if fns.__call and bare:find("%f[%w_]" .. a .. "%s*%(") then
      return mod
    end
  end
  return nil
end

---Whether a line is a tail call: `return f(...)`, also after a signature on the same line.
---@param line string
---@return boolean
function M.is_tail(line)
  local code = M.code_of(line)
  if not code then
    return false
  end
  code =
    code:gsub("^%s*local%s+function%s+[%w_]+%s*%b()", ""):gsub("^%s*function%s+[%w_.:]+%s*%b()", "")
  local rest = code:match("^%s*return%s+(.*)$")
  if not rest then
    return false
  end
  -- the returned expression must be one call: `return f(args)`. A chain (`f(x):wait()`: the method is the tail call
  -- and the site keeps its frame) or an operator (`cmd and f(cmd)`) is none. `require("m").f(` is one callee.
  rest = M.strip_strings((rest:gsub("require%s*%(?%s*[\"'][^\"']*[\"']%s*%)?", "require_m")))
  local callee, after = rest:match("^([%w_%.:]+)%s*%b()(.*)$")
  if not callee then
    -- a call whose arguments go on over the next lines: nothing after it can be seen on this one
    return rest:match("^[%w_%.:]+%s*%(") ~= nil and not rest:find("%b()")
  end
  after = after:gsub("%s*end%s*$", "")
  return after:match("^%s*;?%s*$") ~= nil
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

---A line joined with the next when a call is wrapped after `(` or after `vim` (stylua's `vim\n.system(`).
---@param lines string[]
---@param n integer
---@return string
function M.joined(lines, n)
  local line = lines[n]
  local nxt = lines[n + 1]
  if nxt and (line:match("%(%s*$") or line:match("%f[%w_]vim%s*$")) then
    return (line:gsub("%s+$", "")) .. vim.trim(nxt)
  end
  return line
end

---The top-level functions of a file (stylua: a definition at column 0, its `end` at column 0) with what their bodies
---call. `exported` are the names the module returns (`function M.x`, `M.x = function`, `M.x = local_fn`).
---@param lines string[]
---@return { fns: table<string, { direct: boolean, locals: table<string, boolean>, ext: { mod: string, fn: string }[] }>, exported: table<string, string>, callable: string|nil }
local function analyse(lines)
  local aliases, modvar = {}, "M"
  for i = #lines, 1, -1 do
    local r = lines[i]:match("^return%s+([%w_]+)%s*$")
    if r then
      modvar = r
      break
    end
  end
  for _, line in ipairs(lines) do
    local code = M.code_of(line)
    if code then
      local alias, name = M.alias_of(code)
      if alias then
        aliases[alias] = name
      end
    end
  end
  local mv = modvar:gsub("%p", "%%%0")
  local fn_al = M.vim_fn_aliases(lines)
  local fn_ctx = { tables = fn_al.tables, funcs = fn_al.funcs }
  local fns, exported, callable = {}, {}, nil
  local cur
  for n, line in ipairs(lines) do
    local exp = line:match("^function%s+" .. mv .. "[%.:]([%w_]+)%s*%(")
      or line:match("^" .. mv .. "%.([%w_]+)%s*=%s*function%s*%(")
    local loc = line:match("^local%s+function%s+([%w_]+)%s*%(")
      or line:match("^local%s+([%w_]+)%s*=%s*function%s*%(")
    if line:match("^return%s+function%s*%(") then
      loc, callable = "__call", "__call"
    end
    local body
    if exp or loc then
      local key = exp and ("." .. exp) or loc
      cur = { direct = false, locals = {}, ext = {} }
      fns[key] = cur
      if exp then
        exported[exp] = key
      end
      -- what follows the signature on the same line (`function M.go(a) return vim.system(a) end`)
      body = line:gsub("^.-%b()", "", 1)
    elseif line == "end" or line:match("^end[%s%)]") then
      cur = nil
    elseif cur then
      body = M.joined(lines, n)
    end
    if cur and body then
      local code = M.code_of(body)
      if code then
        for _, p in ipairs(M.PATTERNS) do
          if code:find(p[1]) then
            cur.direct = true
          end
        end
        -- `vim.fn` under a name of the file (`local fn = vim.fn`, `local system = vim.fn.system`)
        if not cur.direct and M.match(body, fn_ctx) then
          cur.direct = true
        end
        local bare = M.strip_strings(code)
        for at, fname in bare:gmatch("()%f[%w_]([%w_]+)%s*%(") do
          local before = at > 1 and bare:sub(at - 1, at - 1) or ""
          if before ~= "." and before ~= ":" then
            cur.locals[fname] = true
          end
        end
        for fname in code:gmatch("%f[%w_]" .. mv .. "[%.:]([%w_]+)%s*%(") do
          cur.locals["." .. fname] = true
        end
        for alias, fname in code:gmatch("%f[%w_]([%w_]+)[%.:]([%w_]+)%s*%(") do
          if aliases[alias] then
            cur.ext[#cur.ext + 1] = { mod = aliases[alias], fn = fname }
          end
        end
        for mod, fname in
          code:gmatch("require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*[%.:]([%w_]+)%s*%(")
        do
          cur.ext[#cur.ext + 1] = { mod = mod, fn = fname }
        end
      end
      if (exp or loc) and line:match("%send%s*$") then
        cur = nil -- a definition on one line
      end
    end
    -- `M.x = helper`: an export of a local function
    local ex, target = line:match("^" .. mv .. "%.([%w_]+)%s*=%s*([%w_]+)%s*$")
    if ex and target ~= "function" then
      exported[ex] = target
    end
    -- a re-export: `M.x = require("m").f`, `M.x = alias.f`
    local rx, rmod, rfn = line:match(
      "^" .. mv .. "%.([%w_]+)%s*=%s*require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%.([%w_]+)%s*$"
    )
    if not rx then
      local ralias
      rx, ralias, rfn = line:match("^" .. mv .. "%.([%w_]+)%s*=%s*([%w_]+)%.([%w_]+)%s*$")
      rmod = ralias and aliases[ralias]
    end
    if rx and rmod then
      fns["=" .. rx] = { direct = false, locals = {}, ext = { { mod = rmod, fn = rfn } } }
      exported[rx] = "=" .. rx
    end
  end
  -- a module that returns a table: `return { run = run, find = M.find }` (on one line or over several)
  for i = #lines, 1, -1 do
    if lines[i]:match("^return%s*{") then
      local text = {}
      for j = i, #lines do
        text[#text + 1] = lines[j]
        if lines[j]:match("}%s*$") then
          break
        end
      end
      for k, v in table.concat(text, " "):gmatch("([%w_]+)%s*=%s*([%w_%.]+)%s*[,}]") do
        if v ~= "function" then
          local tbl, f = v:match("^([%w_]+)%.([%w_]+)$")
          if tbl == modvar then
            exported[k] = exported[f] or ("." .. f)
          elseif tbl and aliases[tbl] then
            fns["=" .. k] =
              { direct = false, locals = {}, ext = { { mod = aliases[tbl], fn = f } } }
            exported[k] = "=" .. k
          elseif not tbl then
            exported[k] = v
          end
        end
      end
      break
    end
  end
  return { fns = fns, exported = exported, callable = callable }
end

---The functions of a library's modules that start processes: `spawning[module][fn] = true` (`__call` for a callable
---module). A function spawns when its body calls a primitive, a spawning function of its own module, or one of a
---required module (a fixpoint). Cached per root for the life of this editor.
---@param lib_root string
---@return table<string, table<string, boolean>>
function M.spawning_modules(lib_root)
  lib_root = vim.fs.normalize(lib_root):gsub("/+$", "")
  if spawning_cache[lib_root] then
    return spawning_cache[lib_root]
  end
  local mods = {}
  for _, rel in ipairs(M.lua_files(lib_root, { "lua" })) do
    local mod = M.module_of(rel)
    if mod and not mod:find("@", 1, true) then
      local f = io.open(lib_root .. "/" .. rel, "rb")
      if f then
        local lines = {}
        for line in f:lines() do
          lines[#lines + 1] = line
        end
        f:close()
        mods[mod] = analyse(lines)
      end
    end
  end
  -- spawns[mod][key]: key is a local name or "." .. exported name
  local spawns = {}
  for mod, a in pairs(mods) do
    spawns[mod] = {}
    for key, fn in pairs(a.fns) do
      if fn.direct then
        spawns[mod][key] = true
      end
    end
  end
  local function exported_spawns(mod, fname)
    local a = mods[mod]
    if not a then
      return false
    end
    local key = a.exported[fname]
    return key ~= nil and spawns[mod][key] == true
  end
  for _ = 1, 10000 do -- monotone: it ends when nothing grows (the bound only guards a mistake)
    local grew = false
    for mod, a in pairs(mods) do
      for key, fn in pairs(a.fns) do
        if not spawns[mod][key] then
          local yes = false
          for name in pairs(fn.locals) do
            local target = name
            if name:sub(1, 1) == "." then
              target = a.exported[name:sub(2)] or name
            end
            if spawns[mod][target] then
              yes = true
              break
            end
          end
          if not yes then
            for _, e in ipairs(fn.ext) do
              if exported_spawns(e.mod, e.fn) then
                yes = true
                break
              end
            end
          end
          if yes then
            spawns[mod][key], grew = true, true
          end
        end
      end
    end
    if not grew then
      break
    end
  end
  local out = {}
  for mod, a in pairs(mods) do
    local fns
    for ex, key in pairs(a.exported) do
      if spawns[mod][key] then
        fns = fns or {}
        fns[ex] = true
      end
    end
    if a.callable and spawns[mod].__call then
      fns = fns or {}
      fns.__call = true
    end
    out[mod] = fns
  end
  spawning_cache[lib_root] = out
  return out
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
---@param spawning? table<string, table<string, boolean>>
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
      local aliases, funcs, fields = {}, {}, {}
      for _, line in ipairs(lines) do
        local code = M.code_of(line)
        if code then
          local alias, name = M.alias_of(code)
          if alias and spawning and spawning[name] then
            aliases[alias] = name
          end
        end
      end
      -- a spawning function bound to a name: `local x = git.status`, `M.x = git.status`,
      -- `local x = require("m").f` (no call on that line)
      for _, line in ipairs(lines) do
        local code = M.code_of(line)
        if code and spawning then
          local lhs, mod, fn = code:match("^%s*local%s+([%w_]+)%s*=%s*([%w_]+)%.([%w_]+)%s*$")
          local field
          if not lhs then
            local tbl
            tbl, field, mod, fn = code:match("^%s*([%w_]+)%.([%w_]+)%s*=%s*([%w_]+)%.([%w_]+)%s*$")
            field = field and (tbl .. "." .. field)
          end
          local target = mod and aliases[mod]
          if not lhs and not field then
            lhs, target, fn = code:match(
              "^%s*local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%.([%w_]+)%s*$"
            )
          end
          if target and fn and spawning[target] and spawning[target][fn] then
            if lhs then
              funcs[lhs] = target .. "." .. fn
            elseif field then
              fields[field] = target .. "." .. fn
            end
          end
        end
      end
      local fn_al = M.vim_fn_aliases(lines)
      for name, what in pairs(fn_al.funcs) do
        funcs[name] = funcs[name] or what
      end
      local ctx = {
        aliases = aliases,
        spawning = spawning or {},
        funcs = funcs,
        fields = fields,
        tables = fn_al.tables,
      }
      local fn_name, fn_local -- the function the current line is in (the nearest definition above), and its kind
      for n, line in ipairs(lines) do
        local loc = line:match("^local%s+function%s+([%w_]+)%s*%(")
          or line:match("^local%s+([%w_]+)%s*=%s*function%s*%(")
        local def = loc
          or line:match("^function%s+[%w_.:]-([%w_]+)%s*%(")
          or line:match("^[%w_.]-([%w_]+)%s*=%s*function%s*%(")
        if def then
          fn_name, fn_local = def, loc ~= nil
        end
        local what = M.match(line, ctx)
        local wrapped = false
        local joined = M.joined(lines, n)
        if
          not what
          and joined ~= line
          and M.code_of(line)
          and not M.match(lines[n + 1] or "", ctx)
        then
          -- a call wrapped after `(` or `vim`: only the primitives, on the line where the call starts
          what = M.match(joined)
          wrapped = what ~= nil
        end
        if what then
          local text = vim.trim(line)
          out[#out + 1] = {
            file = rel,
            line = n,
            what = what,
            text = #text > 120 and (text:sub(1, 117) .. "...") or text,
            -- a wrapped call may be reported on its next line at run time
            span = wrapped and 2 or nil,
            tail_fn = M.is_tail(line) and fn_name or nil,
            tail_local = M.is_tail(line) and fn_name and fn_local or nil,
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

---The line of a file below the root (cached for one coverage).
local function line_at(cache, root, rel, n)
  if cache[rel] == nil then
    local f = io.open(root .. "/" .. rel, "rb")
    local lines = {}
    if f then
      for l in f:lines() do
        lines[#lines + 1] = l
      end
      f:close()
    end
    cache[rel] = lines
  end
  return cache[rel][n]
end

---Which sites the starts reached: a site is reached when any frame of a start's stack lies on it (its `site`,
---`origin` and every caller up to `MAX_STACK`), or a reach record's (an in-process LSP client); a tail-call site when
---a frame on a stack calls the function it is in.
---@param sites Testing.Perf.Site[]
---@param spawns Testing.Perf.Spawn[]
---@param root string
---@param ci? boolean case-insensitive paths (Windows)
---@param reaches? { stack: string[] }[]
---@return { covered: Testing.Perf.Site[], missing: Testing.Perf.Site[], ratio: number|nil }
function M.coverage(sites, spawns, root, ci, reaches)
  local hit, frames = {}, {}
  local seen = {}
  local function take(place)
    local rel = M.relative(place, root, ci)
    if rel and not seen[rel] then
      seen[rel] = true
      hit[ci and rel:lower() or rel] = true
      local file, n = rel:match("^(.*):(%d+)$")
      if file then
        frames[#frames + 1] = { file = file, line = tonumber(n) }
      end
    end
  end
  for _, s in ipairs(spawns) do
    take(s.site)
    take(s.origin)
    for _, place in ipairs(s.stack or {}) do
      take(place)
    end
  end
  for _, r in ipairs(reaches or {}) do
    for _, place in ipairs(r.stack or {}) do
      take(place)
    end
  end
  -- the calls on the lines of the frames: what a tail-call site needs. An unqualified call (`f(`) reaches a local
  -- function of its own file; a qualified one (`x.f(`, `x:f(`) a field function of the module `x` stands for: an alias
  -- `local x = require("<module>")` of the caller's file, the module table of the caller's own file, or
  -- `require("<module>").f(` in place. `vim.ui.open(` is no call of a plugin's `M.open`.
  local qualified, plain, cache, file_aliases = {}, {}, {}, {}
  local base = vim.fs.normalize(root):gsub("/+$", "")
  local function aliases_of(file)
    if not file_aliases[file] then
      local t = {}
      line_at(cache, base, file, 1)
      for _, l in ipairs(cache[file] or {}) do
        local c = M.code_of(l)
        if c then
          local a, m = M.alias_of(c)
          if a then
            t[a] = m
          end
        end
      end
      local own = M.module_of(file)
      if own then
        -- the module table of the file itself (`M.f(` inside it), whatever it is called
        for i = #(cache[file] or {}), 1, -1 do
          local r = cache[file][i]:match("^return%s+([%w_]+)%s*$")
          if r then
            t[r] = own
            break
          end
        end
        t.M = t.M or own
      end
      file_aliases[file] = t
    end
    return file_aliases[file]
  end
  for _, fr in ipairs(frames) do
    local text = line_at(cache, base, fr.file, fr.line)
    local code = text and M.code_of(text) or ""
    for mod, name in
      code:gmatch("require%s*%(?%s*[\"']([%w_%.@%-]+)[\"']%s*%)?%s*[%.:]([%w_]+)%s*%(")
    do
      qualified[mod .. "\0" .. name] = true
    end
    local bare = M.strip_strings(code)
    local al = aliases_of(fr.file)
    for q, name in bare:gmatch("([%w_]+)[%.:]([%w_]+)%s*%(") do
      if al[q] then
        qualified[al[q] .. "\0" .. name] = true
      end
    end
    for at, name in bare:gmatch("()%f[%w_]([%w_]+)%s*%(") do
      local before = at > 1 and bare:sub(at - 1, at - 1) or ""
      if before ~= "." and before ~= ":" then
        plain[fr.file .. "\0" .. name] = true
      end
    end
  end
  local covered, missing = {}, {}
  for _, site in ipairs(sites) do
    local reached = false
    if site.tail_fn then
      if site.tail_local then
        reached = plain[site.file .. "\0" .. site.tail_fn] == true
      else
        local mod = M.module_of(site.file)
        reached = mod ~= nil and qualified[mod .. "\0" .. site.tail_fn] == true
      end
    end
    for line = site.line, site.line + (site.span or 1) - 1 do
      local key = ("%s:%d"):format(site.file, line)
      reached = reached or hit[ci and key:lower() or key] == true
    end
    if reached then
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
