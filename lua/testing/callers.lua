---@module 'testing.callers'
-- @cache-env REPOS_DIR NVIM_CONFIG_DIR
---@brief `testing callers`: a public function or module that went away, and who in the fleet still calls it.
---@description
--- ```
--- testing callers [<root>] [--base=<rev>] [--head=<rev>] [--roots=<dir>[,<dir>...]] [--no-fleet]
--- ```
---
--- A rename "without consumers" broke one: gopath renamed `resolve_and_open` and searched for callers below
--- `$REPOS_DIR` only, but the nvim config lives in `%LOCALAPPDATA%\nvim` (`$NVIM_CONFIG_DIR`). This command does
--- the search for every such change at once:
---
--- 1. **What went away.** The Lua modules under `lua/` that differ between `--base` (default `@{upstream}`, else
---    `HEAD`) and the working tree (or `--head`): a deleted or renamed module file takes the whole module away; a
---    changed one the exports it no longer has (`function M.name(`, `M.name = ...` at the start of a line, `M` being
---    the table the file returns).
--- 2. **Who calls it.** Every `*.lua` and `*.vim` file below the roots: the project itself, each checkout directly
---    below `$REPOS_DIR` (linked worktrees skipped: they are copies), and `$NVIM_CONFIG_DIR`; `--roots` replaces the
---    fleet with the named directories, `--no-fleet` looks at the project only. A call is `require("mod").name`,
---    `X.name` / `X:name` after `local X = require("mod")` (or `pcall(require, "mod")`, `require("mod").sub`), a
---    field chain through a facade (`g.commands.open` after `local g = require("gopath")` is the field `open` of
---    `gopath.commands`), or any `require` of a module that went away. A checkout is listed by `git ls-files`.
---
--- Text, not a parser: a call through a second alias or a computed name is not seen, and a hit inside a string is
--- reported. It is a smoke detector before a push, not a proof.
---
--- Exit 0 when nothing that went away is still called, 1 when it is (a line per call), 2 usage, 3 when git cannot
--- answer.

local M = {}

M.EXIT_OK, M.EXIT_FOUND, M.EXIT_USAGE, M.EXIT_FAILED = 0, 1, 2, 3

M.USAGE = table.concat({
  "usage: testing callers [<root>] [--base=<rev>] [--head=<rev>] [--roots=<dir>[,<dir>...]] [--no-fleet]",
  "  <root>           the project whose changes are checked (default: the current directory)",
  "  --base=<rev>     compare with this revision (default: @{upstream}, else HEAD)",
  "  --head=<rev>     compare up to this revision (default: the working tree)",
  "  --roots=<dirs>   look for callers below these directories instead of the fleet (comma separated)",
  "  --no-fleet       look for callers in the project only",
  "  fleet: the project, each checkout below $REPOS_DIR and $NVIM_CONFIG_DIR (the nvim config)",
  "  exit: 0 nothing removed is called, 1 callers found, 2 usage, 3 git failed",
}, "\n")

---Directories never walked into (copies of other checkouts, build output, dependencies).
M.SKIP_DIRS = {
  [".git"] = true,
  [".deps"] = true,
  ["node_modules"] = true,
  ["target"] = true,
  ["dist"] = true,
  ["build"] = true,
  [".cache"] = true,
  [".worktrees"] = true,
}

---Files larger than this are not read (generated bundles).
M.MAX_FILE_BYTES = 1024 * 1024

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(p):gsub("/+$", ""))
end

---The module a repository path names: `lua/a/b.lua` and `lua/a/b/init.lua` are `a.b`.
---@param path string Repository-relative, forward slashes.
---@return string|nil module nil outside `lua/` or for a file that is no Lua module
function M.module_of(path)
  local rel = path:match("^lua/(.+)%.lua$")
  if not rel then
    return nil
  end
  rel = rel:gsub("/init$", "")
  if rel == "init" or rel == "" or rel:find("[^%w_/%-]") then
    return nil
  end
  return (rel:gsub("/", "."))
end

---The public names of a module source: the fields of the table it returns, defined at the start of a line.
---@param text string
---@return table<string, true>|nil names nil when the file does not return a named table (nothing to compare)
function M.exports(text)
  local tbl
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local name = line:match("^return%s+([%a_][%w_]*)%s*$")
      or line:match("^return%s+setmetatable%s*%(%s*([%a_][%w_]*)%s*,")
    if name then
      tbl = name
    end
  end
  if not tbl then
    return nil
  end
  local names = {}
  local esc = vim.pesc(tbl)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local n = line:match("^function%s+" .. esc .. "[.:]([%a_][%w_]*)%s*%(")
      or line:match("^" .. esc .. "%.([%a_][%w_]*)%s*=[^=]")
    if n then
      names[n] = true
    end
  end
  return names
end

---@class Testing.Callers.Removed
---@field module string
---@field name? string nil: the whole module went away
---@field path string The file at the base.

---@class Testing.Callers.Io
---@field git fun(root: string, args: string[]): string|nil, string|nil stdout, or nil and the error
---@field read fun(path: string): string|nil

---@type Testing.Callers.Io
M.io = {
  git = function(root, args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then
      return nil, vim.trim(r.stderr or "") ~= "" and vim.trim(r.stderr) or ("git exited " .. r.code)
    end
    return r.stdout or ""
  end,
  read = function(path)
    local st = vim.uv.fs_stat(path)
    if not st or st.type ~= "file" or st.size > M.MAX_FILE_BYTES then
      return nil
    end
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return text
  end,
}

---What went away between `base` and the working tree (or `head`).
---@param root string
---@param base string
---@param head? string
---@param io_? Testing.Callers.Io
---@return Testing.Callers.Removed[]|nil removed
---@return string|nil err
function M.removed(root, base, head, io_)
  io_ = io_ or M.io
  local args = { "diff", "--name-status", "-M", "--no-color", base }
  if head then
    args[#args + 1] = head
  end
  vim.list_extend(args, { "--", "lua" })
  local out, err = io_.git(root, args)
  if not out then
    return nil, err
  end
  local removed = {}
  local function old_text(path)
    return io_.git(root, { "show", base .. ":" .. path })
  end
  local function new_text(path)
    if head then
      return io_.git(root, { "show", head .. ":" .. path })
    end
    return io_.read(root .. "/" .. path)
  end
  for line in out:gmatch("[^\n]+") do
    local status, a, b = line:match("^(%u)%d*\t([^\t]+)\t?([^\t]*)$")
    local mod = a and M.module_of(a)
    if mod then
      local whole = status == "D" or (status == "R" and M.module_of(b) ~= mod)
      if whole then
        removed[#removed + 1] = { module = mod, path = a }
      elseif status == "M" or status == "R" then
        local before = M.exports(old_text(a) or "")
        local after = M.exports(new_text(status == "R" and b or a) or "")
        if before then
          local gone = {}
          for n in pairs(before) do
            if not (after and after[n]) then
              gone[#gone + 1] = n
            end
          end
          table.sort(gone)
          for _, n in ipairs(gone) do
            removed[#removed + 1] = { module = mod, name = n, path = a }
          end
        end
      end
    end
  end
  table.sort(removed, function(x, y)
    if x.module ~= y.module then
      return x.module < y.module
    end
    return (x.name or "") < (y.name or "")
  end)
  return removed
end

---The directories to look for callers in.
---@param root string The project.
---@param opts { roots?: string[], no_fleet?: boolean, getenv?: fun(name: string): string|nil }
---@return string[] roots
---@return string[] notes What was not looked at, and why.
function M.roots(root, opts)
  local getenv = opts.getenv or function(name)
    return vim.uv.os_getenv(name)
  end
  local list, seen, notes = {}, {}, {}
  local function add(dir)
    dir = norm(dir)
    -- the real path: a temp folder below /var is /private/var to git on macOS, a link is its target
    local key = norm(vim.uv.fs_realpath(dir) or dir)
    key = require("testing.platform").is_case_insensitive() and key:lower() or key
    if not seen[key] and vim.fn.isdirectory(dir) == 1 then
      seen[key] = true
      list[#list + 1] = dir
    end
  end
  add(root)
  if opts.roots then
    for _, d in ipairs(opts.roots) do
      add(d)
    end
    return list, notes
  end
  if opts.no_fleet then
    return list, notes
  end
  local repos = getenv("REPOS_DIR")
  if repos and repos ~= "" and vim.fn.isdirectory(repos) == 1 then
    local names = {}
    for name, kind in vim.fs.dir(repos) do
      if kind == "directory" then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local dir = norm(repos) .. "/" .. name
      -- a checkout of its own: `.git` is a directory (a linked worktree has a `.git` file and is a copy)
      local st = vim.uv.fs_stat(dir .. "/.git")
      if st and st.type == "directory" then
        add(dir)
      end
    end
  else
    notes[#notes + 1] = "REPOS_DIR is not set: the fleet's checkouts were not looked at"
  end
  local config = getenv("NVIM_CONFIG_DIR")
  if config and config ~= "" and vim.fn.isdirectory(config) == 1 then
    add(config)
  else
    notes[#notes + 1] = "NVIM_CONFIG_DIR is not set: the nvim config was not looked at"
  end
  return list, notes
end

---@class Testing.Callers.Hit
---@field module string
---@field name? string
---@field file string Absolute.
---@field line integer
---@field text string

---The `.a.b:c` after a name: the fields read, in order (`sep` is `.` or `:`; nothing is read after a `:`).
---@param chain string
---@return { sep: string, name: string }[]
local function tokens(chain)
  local out = {}
  for sep, name in chain:gmatch("([.:])([%a_][%w_]*)") do
    out[#out + 1] = { sep = sep, name = name }
    if sep == ":" then
      break
    end
  end
  return out
end

---The calls of what went away in one source text. A field chain is followed into submodules: with
---`local g = require("gopath")`, `g.commands.open` is the field `open` of the module `gopath.commands`.
---@param text string
---@param removed Testing.Callers.Removed[]
---@return { module: string, name?: string, line: integer, text: string }[]
function M.scan(text, removed)
  local whole, names, heads = {}, {}, {}
  for _, r in ipairs(removed) do
    if r.name then
      names[r.module] = names[r.module] or {}
      names[r.module][r.name] = true
    else
      whole[r.module] = true
    end
    heads[r.module:match("^[^.]+")] = true
  end
  -- a module is reached through its first segment (`require("gopath")` for `gopath.commands`)
  local any = false
  for head in pairs(heads) do
    any = any or text:find(head, 1, true) ~= nil
  end
  if not any then
    return {}
  end
  ---Whether a module that went away is, or lies below, `mod`.
  local function relevant(mod)
    for _, r in ipairs(removed) do
      if r.module == mod or r.module:sub(1, #mod + 1) == mod .. "." then
        return true
      end
    end
    return false
  end
  local lines = vim.split(text, "\n", { plain = true })
  local hits, aliases = {}, {}
  local function hit(mod, name, i)
    hits[#hits + 1] = { module = mod, name = name, line = i, text = vim.trim(lines[i]) }
  end
  ---Follow a field chain from the module `base`; true when it hit.
  local function follow(base, toks, i)
    local cur = base
    for _, tok in ipairs(toks) do
      if names[cur] and names[cur][tok.name] then
        hit(cur, tok.name, i)
        return true
      end
      if tok.sep == ":" then
        return false
      end
      cur = cur .. "." .. tok.name
      if whole[cur] then
        hit(cur, nil, i)
        return true
      end
    end
    return false
  end
  -- the requires: a module that went away, a field chain read off the require, an alias
  for i, line in ipairs(lines) do
    if not line:match("^%s*%-%-") then
      local pos = 1
      while true do
        local s, e, _, mod = line:find("require%s*%(?%s*,?%s*([\"'])([%w%._%-]+)%1%s*%)?", pos)
        if not s then
          break
        end
        pos = e + 1
        if whole[mod] then
          hit(mod, nil, i)
        elseif relevant(mod) then
          local chain = line:sub(e + 1):match("^[%.:%w_]*")
          local toks = tokens(chain)
          if not follow(mod, toks, i) then
            -- `local x = require("m")`, `local x = require("m").sub`, `local ok, x = pcall(require, "m")`
            local before = line:sub(1, s - 1)
            local alias = before:match("([%a_][%w_]*)%s*=%s*$")
              or before:match("([%a_][%w_]*)%s*=%s*pcall%s*%(%s*$")
            local after = line:sub(e + 1 + #chain)
            if alias and not chain:find(":", 1, true) and not after:match("^%s*[%(%[\"'{]") then
              local target = mod
              for _, tok in ipairs(toks) do
                target = target .. "." .. tok.name
              end
              if relevant(target) then
                aliases[alias] = target
              end
            end
          end
        end
      end
    end
  end
  -- the calls through an alias, anywhere in the file
  if next(aliases) then
    for i, line in ipairs(lines) do
      if not line:match("^%s*%-%-") then
        for alias, mod in pairs(aliases) do
          for chain in line:gmatch("%f[%w_.]" .. vim.pesc(alias) .. "([%.:][%.:%w_]*)") do
            follow(mod, tokens(chain), i)
          end
        end
      end
    end
  end
  table.sort(hits, function(x, y)
    return x.line < y.line
  end)
  return hits
end

---Every call of what went away below the roots.
---@param roots string[]
---@param removed Testing.Callers.Removed[]
---@param io_? Testing.Callers.Io
---@return Testing.Callers.Hit[] hits
---@return integer files How many files were read.
function M.find(roots, removed, io_)
  io_ = io_ or M.io
  local hits, files = {}, 0
  if #removed == 0 then
    return hits, files
  end
  for _, file in ipairs(M.sources(roots)) do
    local text = io_.read(file)
    if text then
      files = files + 1
      for _, h in ipairs(M.scan(text, removed)) do
        hits[#hits + 1] =
          { module = h.module, name = h.name, file = file, line = h.line, text = h.text }
      end
    end
  end
  return hits, files
end

---The `*.lua` and `*.vim` files below the roots. A git checkout answers with `git ls-files` (tracked and untracked,
---not ignored: no build output, no dependency copies), asked of every root at once; any other folder is walked, the
---directories of `M.SKIP_DIRS` left out.
---@param roots string[]
---@return string[] files Absolute.
function M.sources(roots)
  local jobs = {}
  for i, dir in ipairs(roots) do
    if vim.uv.fs_stat(dir .. "/.git") then
      local ok, job = pcall(vim.system, {
        "git",
        "-C",
        dir,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "*.lua",
        "*.vim",
      }, { text = true })
      jobs[i] = ok and job or nil
    end
  end
  local out = {}
  for i, dir in ipairs(roots) do
    local listed = false
    if jobs[i] then
      local r = jobs[i]:wait()
      if r.code == 0 then
        listed = true
        local seen = {}
        for rel in (r.stdout or ""):gmatch("[^%z]+") do
          if not seen[rel] then
            seen[rel] = true
            out[#out + 1] = dir .. "/" .. rel
          end
        end
      end
    end
    if not listed then
      for name, kind in
        vim.fs.dir(dir, {
          depth = math.huge,
          skip = function(d)
            return not M.SKIP_DIRS[vim.fs.basename(d)]
          end,
        })
      do
        if kind == "file" and (name:match("%.lua$") or name:match("%.vim$")) then
          out[#out + 1] = dir .. "/" .. name
        end
      end
    end
  end
  return out
end

---@param argv string[]
---@return { root: string, base?: string, head?: string, roots?: string[], no_fleet: boolean, help: boolean }|nil
---@return string|nil problem
function M.parse(argv)
  local args = { no_fleet = false, help = false }
  for _, a in ipairs(argv) do
    if a == "-h" or a == "--help" then
      args.help = true
    elseif a == "--no-fleet" then
      args.no_fleet = true
    elseif a:match("^%-%-base=.+") then
      args.base = a:match("^%-%-base=(.+)$")
    elseif a:match("^%-%-head=.+") then
      args.head = a:match("^%-%-head=(.+)$")
    elseif a:match("^%-%-roots=.+") then
      args.roots = vim.split(a:match("^%-%-roots=(.+)$"), ",", { plain = true, trimempty = true })
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    elseif args.root then
      return nil, ("one root only (got %s and %s)"):format(args.root, a)
    else
      args.root = a
    end
  end
  if args.roots and args.no_fleet then
    return nil, "--roots and --no-fleet exclude each other"
  end
  return args
end

---@class Testing.Callers.Services
---@field out fun(s: string)
---@field err fun(s: string)
---@field cwd? string
---@field getenv? fun(name: string): string|nil
---@field callers_io? Testing.Callers.Io

---@param argv string[]
---@param sv Testing.Callers.Services
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing callers: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local io_ = sv.callers_io or M.io
  local cwd = sv.cwd or vim.fn.getcwd()
  local root = norm(vim.fn.fnamemodify(args.root or cwd, ":p"))
  local top = io_.git(root, { "rev-parse", "--show-toplevel" })
  if not top then
    sv.err(("testing callers: %s is no git checkout"):format(root))
    return M.EXIT_FAILED
  end
  -- the folder as it was named, when it is the top of the checkout (git answers with the real path: /private/var
  -- for /var on macOS); a folder below the top is replaced by the top
  local given_real, top_real = vim.uv.fs_realpath(root), vim.uv.fs_realpath(vim.trim(top))
  if not (given_real and top_real and norm(given_real) == norm(top_real)) then
    root = norm(vim.trim(top))
  end
  local base = args.base
  if not base then
    base = io_.git(root, { "rev-parse", "--verify", "--quiet", "@{upstream}" }) and "@{upstream}"
      or "HEAD"
  end
  local removed, err = M.removed(root, base, args.head, io_)
  if not removed then
    sv.err(("testing callers: git cannot compare with %s: %s"):format(base, tostring(err)))
    return M.EXIT_FAILED
  end
  local roots, notes =
    M.roots(root, { roots = args.roots, no_fleet = args.no_fleet, getenv = sv.getenv })
  local hits, files = M.find(roots, removed, io_)
  local against = (args.head or "the working tree")
  if #hits == 0 then
    sv.out(
      ("CLEAN | %d removed since %s (to %s), no caller in %d files below %d roots"):format(
        #removed,
        base,
        against,
        files,
        #roots
      )
    )
  else
    sv.out(
      ("CALLERS | %d calls of what went away since %s (to %s) | %d files below %d roots"):format(
        #hits,
        base,
        against,
        files,
        #roots
      )
    )
    for _, h in ipairs(hits) do
      local what = h.name and (h.module .. "." .. h.name .. " (removed)")
        or (h.module .. " (module removed)")
      sv.out(("  %s  %s:%d  %s"):format(what, h.file, h.line, h.text))
    end
  end
  for _, n in ipairs(notes) do
    sv.out("  note: " .. n)
  end
  return #hits == 0 and M.EXIT_OK or M.EXIT_FOUND
end

return M
