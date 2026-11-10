---@module 'testing.screen'
-- @cache-env CI TESTING_UPDATE_SNAPSHOTS TESTING_SNAPSHOTS_DIR
---@brief Screen snapshots: compare what an RPC child shows with a reviewed text file.
---@description
--- `testing.rpc` drives a real editor (`input`, `feed`, `mouse`, `settle`) and reads its screen
--- (`child.screen()`). This module turns such a screen into an assertion:
---
---   local screen = require("testing.screen")
---   screen.expect(H.ok, "dialog", child.screen(), { masks = { "%d%d:%d%d", { row = 24 } } })
---
--- * `normalize(shot, opts)` masks what changes between runs: Lua patterns (`"%d%d:%d%d"`), plain
---   text (`{ text = "..." }`) and rectangles by screen cell (`{ row = 24 }`, `{ row = 1, col = 70,
---   cols = 11 }`; 1-based, `rows`/`cols` default to one row / the rest of the row). A masked cell
---   shows `#` and its attribute `#`; a wide character is masked as a whole. `replace` /
---   `roots` put placeholders (`<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`) in place of paths (this changes the
---   width of the text row, not of the attribute row). Attribute letters are given again in order
---   of first appearance AFTER masking, so a masked clock with its own highlight does not shift the
---   letters of everything behind it.
--- * `render(norm)` is the file format: a header (size, cursor, mode), the text rows, the attribute
---   rows, each row numbered, trailing blanks cut, LF line endings. It is meant to be read in a diff.
--- * `compare(name, shot, opts)` reads `<dir>/<spec>/<name>.snap` (`dir` default
---   `TESTS/__snapshots__`, `<spec>` the spec file without `TESTS/` and `.lua`) and decides:
---
---     match     the file has the same bytes                                    ok
---     written   no file yet, not on CI: the file is written                    ok (the message says so)
---     updated   it differs and updating is on: the file is rewritten          ok (the message says so)
---     missing   no file on CI (`CI` set): never written there                 fail
---     differ    it differs: the message shows the first differing rows        fail
---     error     the file could not be read or written, or was refused        fail
---
---   The file is read as untrusted (a pull request can write it, SEC-33): only a plain file (no link, no
---   folder) inside the project (links of the folders resolved; a new file is not written through a linked
---   folder either), at most `MAX_BYTES` (1 MiB); control characters in the diff are shown as `\xNN`.
---   Updating is on with `opts.update = true` or `TESTING_UPDATE_SNAPSHOTS=1` (what
---   `testing run --update-snapshots` sets; the variable reaches child editors).
--- * `expect(ok_fn, name, shot, opts)` hands the verdict to the harness (`H.ok`, a collecting
---   `a.ok`, ...); `check(name, shot, opts)` raises instead (busted style specs).
--- * `opts.groups = true` adds `--- groups` to the file: the highlight groups of each attribute letter left after
---   masking (`shot.hl`, from `child.screen()`). Without it a file is as before.
--- * `hl_check(shot, want, resolved)` checks how a place is drawn (`text` or `row`/`col`; `group`, colours, styles):
---   nil or the failure line. `hl_cells` finds the cells of a place.
---
--- Cache: the files are read by this module, not by the spec, but the cache key of a spec that loads this module
--- (a literal `require`) contains the snapshot folder of that spec by itself. Files of another spec's folder, or read
--- through a path the scanner cannot follow, are declared with `-- @cache-inputs <dir>/`.
--- Folder: `opts.dir`, else the project's `snapshots.dir` (TESTING_SNAPSHOTS_DIR), else `TESTS/__snapshots__`.

local M = {}

M.VERSION = 1
M.DEFAULT_DIR = "TESTS/__snapshots__"
M.FILL = "#"

local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local MAX_DIFF_ROWS = 12

---@class Testing.Screen.Shot
---@field size? { rows: integer, cols: integer } Default: the row count and the widest row.
---@field cursor? { row: integer, col: integer }
---@field mode? string
---@field lines string[]
---@field attrs? string[]
---@field cells? string[][] One entry per screen column, `""` for the second cell of a wide character.
---@field cell_attrs? string[] One attribute letter per screen column.
---@field hl? table<string, Testing.Screen.Hl> What each letter of `hl_attrs` is (`child.screen()`; `" "` = no highlight).
---@field hl_attrs? string[] Like `attrs`, one letter per ATTRIBUTE (two groups that look the same have two).
---@field hl_cell_attrs? string[] Like `cell_attrs`, by attribute.
---@field look_groups? table<string, string[]> The groups drawn with each letter of `attrs` (a letter is a look).

---@class Testing.Screen.Hl
---@field groups string[] The highlight groups the attribute is made of (a linked group by its target).
---@field fg? string `#rrggbb` as drawn.
---@field bg? string
---@field sp? string
---@field bold? boolean
---@field italic? boolean
---@field underline? boolean
---@field undercurl? boolean
---@field strikethrough? boolean
---@field reverse? boolean

---@class Testing.Screen.Opts
---@field masks? (string|table)[] Lua patterns, `{ text = s }`, `{ pattern = p }` or `{ row, col?, rows?, cols? }`.
---@field replace? { from: string, to: string }[] Plain replacements in the text rows.
---@field roots? { repo?: string, home?: string, tmp?: string, state?: string } Paths shown as `<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`.
---@field cursor? boolean Keep the cursor in the snapshot (default true).
---@field mode? boolean Keep the mode in the snapshot (default true).
---@field dir? string Snapshot directory relative to `root` (default `TESTS/__snapshots__`).
---@field root? string Project root (default the current directory).
---@field file? string The spec file (default: found on the call stack, the nearest `*_spec.lua`).
---@field update? boolean Rewrite a differing file (default: `TESTING_UPDATE_SNAPSHOTS`).
---@field ci? boolean Missing files fail instead of being written (default: `CI`).
---@field groups? boolean Add the highlight groups of each attribute letter (`--- groups`; needs `shot.hl`).

---@class Testing.Screen.Norm
---@field size { rows: integer, cols: integer }
---@field cursor? { row: integer, col: integer }
---@field mode? string
---@field text string[]
---@field attrs string[]
---@field groups? { letter: string, groups: string[] }[] With `opts.groups`: in the order of the letters.

---@class Testing.Screen.Result
---@field ok boolean
---@field status "match"|"written"|"updated"|"missing"|"differ"|"error"
---@field path? string Absolute path of the snapshot file.
---@field rel? string The same relative to the root, `/` separated.
---@field message string
---@field actual? string The rendered screen.

---Split a row into cells by screen column, from `cells`/`cell_attrs` when the shot has them, else from
---`lines`/`attrs` (one cell per character; older children, hand-made shots).
---@param shot Testing.Screen.Shot
---@param r integer
---@return string[] cells, string[] marks
local function row_cells(shot, r)
  local cells, marks = {}, {}
  if shot.cells and shot.cells[r] then
    local ca = shot.cell_attrs and shot.cell_attrs[r] or ""
    for c, s in ipairs(shot.cells[r]) do
      cells[c] = s
      local m = ca:sub(c, c)
      marks[c] = m ~= "" and m or " "
    end
    return cells, marks
  end
  local line, attr = shot.lines[r] or "", shot.attrs and shot.attrs[r] or ""
  -- `\zs` splits by character and keeps a composing character with its base, like `screenstring`
  for i, ch in ipairs(vim.fn.split(line, [[\zs]])) do
    cells[i] = ch
    local m = attr:sub(i, i)
    marks[i] = m ~= "" and m or " "
  end
  return cells, marks
end

---Mask the cell in column `c` and, for a wide character, its other half.
---@param cells string[]
---@param marks string[]
---@param c integer
local function mask_cell(cells, marks, c)
  if cells[c] == nil then
    return
  end
  local head = c
  while head > 1 and cells[head] == "" do
    head = head - 1
  end
  cells[head], marks[head] = M.FILL, M.FILL
  local k = head + 1
  while cells[k] == "" do
    cells[k], marks[k] = M.FILL, M.FILL
    k = k + 1
  end
end

---@param v any
---@param name string
---@return integer|nil
local function int_field(v, name)
  if v == nil then
    return nil
  end
  if type(v) ~= "number" or v ~= math.floor(v) or v < 1 then
    error(
      ("testing.screen: mask field %s must be a positive integer, got %s"):format(name, tostring(v)),
      3
    )
  end
  return v
end

---Mask a rectangle `{ row, col?, rows?, cols? }` (1-based screen cells).
---@param grid { cells: string[], marks: string[] }[]
---@param m table
---@param ncols integer
local function mask_rect(grid, m, ncols)
  local row = int_field(m.row, "row") --[[@as integer]]
  local col = int_field(m.col, "col") or 1
  local rows = int_field(m.rows, "rows") or 1
  local cols = int_field(m.cols, "cols") or (ncols - col + 1)
  for r = row, row + rows - 1 do
    local g = grid[r]
    if g then
      for c = col, math.min(col + cols - 1, #g.cells) do
        mask_cell(g.cells, g.marks, c)
      end
    end
  end
end

---Mask every match of `pat` (`plain`: a literal) in each row.
---@param grid { cells: string[], marks: string[] }[]
---@param pat string
---@param plain boolean
local function mask_text(grid, pat, plain)
  if pat == "" then
    error("testing.screen: an empty mask pattern masks nothing", 3)
  end
  for _, g in ipairs(grid) do
    -- byte offset of each column's first byte in the joined row
    local starts, parts, pos = {}, {}, 1
    for c, s in ipairs(g.cells) do
      starts[c] = pos
      parts[c] = s
      pos = pos + #s
    end
    local text = table.concat(parts)
    -- `^` anchors at `init` in Lua, not at the row start: an anchored pattern is looked for once
    local anchored = not plain and pat:sub(1, 1) == "^"
    local init = 1
    while init <= #text do
      local s, e = text:find(pat, init, plain)
      if not s or (anchored and init > 1) then
        break
      end
      if e >= s then
        for c = 1, #g.cells do
          local cs, len = starts[c], #g.cells[c]
          if len > 0 and cs <= e and cs + len - 1 >= s then
            mask_cell(g.cells, g.marks, c)
          end
        end
        init = e + 1
      else
        init = s + 1
      end
    end
  end
end

---@param text string
---@param from string
---@param to string
---@return string
local function replace_plain(text, from, to)
  if from == "" then
    return text
  end
  local out, init = {}, 1
  while true do
    local s, e = text:find(from, init, true)
    if not s then
      out[#out + 1] = text:sub(init)
      break
    end
    out[#out + 1] = text:sub(init, s - 1)
    out[#out + 1] = to
    init = e + 1
  end
  return table.concat(out)
end

---The replacements of `opts.replace` and `opts.roots`, longest first, both slash styles.
---@param opts Testing.Screen.Opts
---@return { from: string, to: string }[]
local function replacements(opts)
  local list = {}
  for _, r in ipairs(opts.replace or {}) do
    list[#list + 1] = { from = r.from, to = r.to }
  end
  local names = { repo = "<REPO>", home = "<HOME>", tmp = "<TMP>", state = "<STATE>" }
  for key, token in pairs(names) do
    local p = opts.roots and opts.roots[key]
    if type(p) == "string" and p ~= "" then
      local fwd = (p:gsub("\\", "/")):gsub("/+$", "")
      list[#list + 1] = { from = fwd, to = token }
      list[#list + 1] = { from = (fwd:gsub("/", "\\")), to = token }
    end
  end
  table.sort(list, function(a, b)
    if #a.from ~= #b.from then
      return #a.from > #b.from
    end
    return a.from < b.from
  end)
  return list
end

---Mask, replace and re-letter a screen.
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Norm
function M.normalize(shot, opts)
  opts = opts or {}
  local nrows = shot.size and shot.size.rows or #shot.lines
  local ncols = shot.size and shot.size.cols
  local grid, widest = {}, 0
  for r = 1, nrows do
    local cells, marks = row_cells(shot, r)
    grid[r] = { cells = cells, marks = marks }
    widest = math.max(widest, #cells)
  end
  -- a shot without a size (hand-made): the widest row, as `nrows` falls back to the row count
  ncols = ncols or widest
  for _, m in ipairs(opts.masks or {}) do
    if type(m) == "string" then
      mask_text(grid, m, false)
    elseif type(m) == "table" and m.text then
      mask_text(grid, m.text, true)
    elseif type(m) == "table" and m.pattern then
      mask_text(grid, m.pattern, false)
    elseif type(m) == "table" and m.row then
      mask_rect(grid, m, ncols)
    else
      error(
        "testing.screen: a mask is a Lua pattern, { text = s }, { pattern = p } or { row = n, ... }",
        2
      )
    end
  end
  local reps = replacements(opts)
  local letters, n, order = {}, 0, {}
  local text, attrs = {}, {}
  for r = 1, nrows do
    local g = grid[r]
    local t, a = {}, {}
    for c, s in ipairs(g.cells) do
      if s ~= "" then
        t[#t + 1] = s
        local m = g.marks[c]
        if m ~= " " and m ~= M.FILL then
          if not letters[m] then
            n = n + 1
            letters[m] = n <= #LETTERS and LETTERS:sub(n, n) or "?"
            order[#order + 1] = m
          end
          m = letters[m]
        end
        a[#a + 1] = m
      end
    end
    local row = table.concat(t)
    for _, rep in ipairs(reps) do
      row = replace_plain(row, rep.from, rep.to)
    end
    text[r] = (row:gsub("%s+$", ""))
    attrs[r] = (table.concat(a):gsub("%s+$", ""))
  end
  local groups
  if opts.groups then
    if type(shot.hl) ~= "table" then
      error(
        "testing.screen: groups needs a screen that says what its letters are (child.screen())",
        2
      )
    end
    -- only the letters left after masking: a masked cell has no group either
    groups = {}
    for _, old in ipairs(order) do
      -- a letter of `attrs` is a look (`child.screen()`): all the groups drawn with it; a hand-made shot has `hl` only
      local names = shot.look_groups and shot.look_groups[old]
      if not names then
        local entry = shot.hl[old]
        names = entry and entry.groups
      end
      -- `?`: past the letters there are, the attribute is not known
      groups[#groups + 1] =
        { letter = letters[old], groups = names or (old == "?" and { "?" }) or {} }
    end
  end
  return {
    size = { rows = nrows, cols = ncols },
    cursor = opts.cursor ~= false and shot.cursor or nil,
    mode = opts.mode ~= false and shot.mode or nil,
    text = text,
    attrs = attrs,
    groups = groups,
  }
end

---The snapshot file of a normalized screen.
---@param norm Testing.Screen.Norm
---@return string
function M.render(norm)
  local out = {
    ("testing.nvim screen v%d"):format(M.VERSION),
    ("size: %dx%d"):format(norm.size.cols, norm.size.rows),
  }
  if norm.cursor then
    out[#out + 1] = ("cursor: %d,%d"):format(norm.cursor.row, norm.cursor.col)
  end
  if norm.mode then
    out[#out + 1] = "mode: " .. norm.mode
  end
  local width = #tostring(#norm.text)
  local fmt = "%0" .. width .. "d|%s"
  out[#out + 1] = "--- text"
  for r, row in ipairs(norm.text) do
    out[#out + 1] = fmt:format(r, row)
  end
  out[#out + 1] = "--- attrs"
  for r, row in ipairs(norm.attrs) do
    out[#out + 1] = fmt:format(r, row)
  end
  if norm.groups then
    out[#out + 1] = "--- groups"
    for _, g in ipairs(norm.groups) do
      out[#out + 1] = ("%s %s"):format(
        g.letter,
        #g.groups > 0 and table.concat(g.groups, "+") or "-"
      )
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- The checks of an `hl` step besides `group`: colours and styles of a cell as drawn.
M.HL_COLORS = { "fg", "bg", "sp" }
M.HL_STYLES = { "bold", "italic", "underline", "undercurl", "strikethrough", "reverse" }

---The cells an `hl` step looks at: `{ row, col, ch, letter }` per cell, or nil and why.
---@param shot Testing.Screen.Shot
---@param where { text?: string, row?: integer, col?: integer, cols?: integer }
---@return table[]|nil cells, string|nil err
function M.hl_cells(shot, where)
  local out = {}
  if where.text then
    for r, line in ipairs(shot.lines or {}) do
      local at = line:find(where.text, 1, true)
      if at then
        -- `lines` has one character per cell (the second half of a wide one left out, a combining character
        -- with its base), the letters one each: count as `\zs` splits, not as strchars() does
        local first = #vim.fn.split(line:sub(1, at - 1), [[\zs]]) + 1
        local per_attr = shot.hl_attrs or shot.attrs
        local attrs = per_attr and per_attr[r] or ""
        local chars = vim.fn.split(where.text, [[\zs]])
        for k, ch in ipairs(chars) do
          local i = first + k - 1
          local letter = attrs:sub(i, i)
          out[#out + 1] = { row = r, col = i, ch = ch, letter = letter ~= "" and letter or " " }
        end
        return out
      end
    end
    return nil, ("%q is not on the screen"):format(where.text)
  end
  local r, c = where.row, where.col or 1
  local cells = shot.cells and shot.cells[r]
  if not cells or not cells[c] then
    return nil, ("row %d, column %d is not on the screen"):format(r, c)
  end
  local by_attr = shot.hl_cell_attrs or shot.cell_attrs
  local marks = by_attr and by_attr[r] or ""
  for col = c, c + (where.cols or 1) - 1 do
    if cells[col] == nil then
      break
    end
    if cells[col] ~= "" then -- the second half of a wide character is its first half's
      local letter = marks:sub(col, col)
      out[#out + 1] =
        { row = r, col = col, ch = cells[col], letter = letter ~= "" and letter or " " }
    end
  end
  return out
end

---What a cell is drawn with, in one line: `groups DiffText, fg #ff0000, bold`.
---@param e Testing.Screen.Hl
---@return string
local function hl_text(e)
  local parts = { "groups " .. (#e.groups > 0 and table.concat(e.groups, "+") or "-") }
  for _, k in ipairs(M.HL_COLORS) do
    if e[k] then
      parts[#parts + 1] = ("%s %s"):format(k, e[k])
    end
  end
  for _, k in ipairs(M.HL_STYLES) do
    if e[k] then
      parts[#parts + 1] = k
    end
  end
  return table.concat(parts, ", ")
end

---Check an `hl` step against a screen: every cell of the place must be drawn with the group (by name, or the group a
---linked one ends in) and have the colours and styles asked for. Nil when it holds, else the failure line.
---@param shot Testing.Screen.Shot
---@param want table The `hl` table of the step.
---@param resolved? string The group `want.group` ends in after its links (asked of the child).
---@return string|nil
function M.hl_check(shot, want, resolved)
  if type(shot.hl) ~= "table" then
    return "the screen does not say what its highlights are (a child of an older testing.nvim)"
  end
  local cells, err = M.hl_cells(shot, want)
  if not cells then
    return err
  end
  if #cells == 0 then
    return "no cell to look at"
  end
  for _, cell in ipairs(cells) do
    local e = shot.hl[cell.letter]
    if not e then
      return ("row %d, cell %d (%q): its attribute is not known (more than %d on the screen?)"):format(
        cell.row,
        cell.col,
        cell.ch,
        #LETTERS
      )
    end
    local wrong = {}
    if want.group then
      local names = e.groups or {}
      if
        not vim.tbl_contains(names, want.group)
        and not (resolved and vim.tbl_contains(names, resolved))
      then
        wrong[#wrong + 1] = "group "
          .. want.group
          .. ((resolved and resolved ~= want.group) and (" (= " .. resolved .. ")") or "")
      end
    end
    for _, k in ipairs(M.HL_COLORS) do
      if want[k] and (e[k] or ""):lower() ~= want[k]:lower() then
        wrong[#wrong + 1] = ("%s %s"):format(k, want[k])
      end
    end
    for _, k in ipairs(M.HL_STYLES) do
      if want[k] ~= nil and (e[k] == true) ~= want[k] then
        wrong[#wrong + 1] = (want[k] and "" or "not ") .. k
      end
    end
    if #wrong > 0 then
      return ("row %d, cell %d (%q) has %s; expected %s"):format(
        cell.row,
        cell.col,
        cell.ch,
        hl_text(e),
        table.concat(wrong, ", ")
      )
    end
  end
  return nil
end

---@param p string
---@return string
local function norm_path(p)
  return (vim.fs.normalize(p):gsub("/+$", ""))
end

---The nearest `*_spec.lua` on the call stack.
---@return string|nil
local function spec_on_stack()
  for level = 3, 60 do
    local info = debug.getinfo(level, "S")
    if not info then
      return nil
    end
    local src = info.source or ""
    if src:sub(1, 1) == "@" and src:match("_spec%.lua$") then
      return vim.fn.fnamemodify(src:sub(2), ":p")
    end
  end
  return nil
end

---Names Windows keeps for devices: `CON.snap` is the console there, with any extension and in any case.
local RESERVED = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 1, 9 do
  RESERVED["COM" .. i] = true
  RESERVED["LPT" .. i] = true
end

---Path of the snapshot `name` for the spec file.
---@param name string
---@param opts? Testing.Screen.Opts
---@return string|nil path, string rel_or_err
function M.path(name, opts)
  opts = opts or {}
  if
    type(name) ~= "string"
    or not name:match("^[%w][%w_.%-]*$")
    or name:find("..", 1, true)
    or #name > 100
    or name:sub(-1) == "."
    or RESERVED[name:match("^[^.]*"):upper()]
  then
    return nil,
      ("snapshot name %q: letters, digits, '_', '-', '.' (no '..', no trailing '.', no Windows device name), at most 100 characters"):format(
        tostring(name)
      )
  end
  -- absolute like the spec path below, or "." and the cwd would name different files
  local root = norm_path(vim.fn.fnamemodify(opts.root or vim.fn.getcwd(), ":p"))
  local spec = opts.file or spec_on_stack()
  if not spec then
    return nil, "no *_spec.lua on the call stack: pass opts.file"
  end
  spec = norm_path(vim.fn.fnamemodify(spec, ":p"))
  local windows = require("testing.platform").is_windows()
  local prefix = root .. "/"
  local head = spec:sub(1, #prefix)
  local inside = windows and head:lower() == prefix:lower() or head == prefix
  local rel = inside and spec:sub(#prefix + 1) or vim.fs.basename(spec)
  rel = rel:gsub("^TESTS/", ""):gsub("%.lua$", "")
  -- `opts.dir`, else the project's `snapshots.dir` (the runner hands it down in TESTING_SNAPSHOTS_DIR), else the default
  local configured = os.getenv("TESTING_SNAPSHOTS_DIR")
  local dir = (opts.dir or (configured and configured ~= "" and configured) or M.DEFAULT_DIR)
    :gsub("\\", "/")
    :gsub("/+$", "")
  local rel_path = dir .. "/" .. rel .. "/" .. name .. ".snap"
  return root .. "/" .. rel_path, rel_path
end

---@param v string|nil
---@return boolean
local function truthy(v)
  return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false"
end

---The first differing rows of two renderings.
---@param expected string
---@param actual string
---@return string diff, integer count
local function diff_rows(expected, actual)
  local e = vim.split(expected, "\n", { plain = true })
  local a = vim.split(actual, "\n", { plain = true })
  local lines, count = {}, 0
  for i = 1, math.max(#e, #a) do
    if e[i] ~= a[i] then
      count = count + 1
      if count <= MAX_DIFF_ROWS then
        lines[#lines + 1] = "  - " .. (e[i] or "<no line>")
        lines[#lines + 1] = "  + " .. (a[i] or "<no line>")
      end
    end
  end
  if count > MAX_DIFF_ROWS then
    lines[#lines + 1] = ("  ... %d more differing lines"):format(count - MAX_DIFF_ROWS)
  end
  return table.concat(lines, "\n"), count
end

---@param path string
---@param text string
---@return boolean ok, string|nil err
local function write(path, text)
  local atomic = require("lib.nvim.fs.write.atomic")
  local function go()
    return atomic(path, text, { mkdirp = true })
  end
  -- the snapshot is testing.nvim's own file, not a write of the spec: a guarded case may write it
  local guard = package.loaded["testing.guard"]
  if type(guard) == "table" and guard.suspended then
    local inner = go
    go = function()
      return guard.suspended(inner)
    end
  end
  local ok, res, err = pcall(go)
  if not ok then
    return false, tostring(res)
  end
  if not res then
    return false, tostring(err)
  end
  return true
end

-- ---------------------------------------------------------------------------------------------- untrusted files

---A snapshot is a file of the repository, so a pull request can write it: it is read as untrusted (SEC-33).
M.MAX_BYTES = 1024 * 1024

---@param a string
---@param b string
---@return boolean
local function same_path(a, b)
  if require("testing.platform").is_windows() then
    return a:lower() == b:lower()
  end
  return a == b
end

---`path` resolved (links followed) lies in `root` resolved. A path that is not there yet is judged by the
---nearest folder above it that is.
---@param path string
---@param root string
---@return boolean
local function inside_root(path, root)
  local uv = vim.uv or vim.loop
  local real_root = uv.fs_realpath(root)
  if not real_root then
    return false
  end
  real_root = norm_path(real_root)
  local p = path
  local real = uv.fs_realpath(p)
  while not real do
    local parent = vim.fs.dirname(p)
    if not parent or parent == p then
      return false
    end
    p = parent
    real = uv.fs_realpath(p)
  end
  real = norm_path(real)
  return same_path(real, real_root) or same_path(real:sub(1, #real_root + 1), real_root .. "/")
end

---Control characters of an untrusted file shown as `\xNN` (a tab stays): nothing reaches the terminal raw.
---@param s string
---@return string
local function visible(s)
  return (
    s:gsub("[%c\127]", function(c)
      return c == "\t" and c or ("\\x%02x"):format(c:byte())
    end)
  )
end

---Read a snapshot as untrusted: a plain file (no link, no folder), inside the project, at most `M.MAX_BYTES`.
---@param path string
---@param root string
---@return string|nil text, string|nil problem (both nil: there is no file)
local function read_untrusted(path, root)
  local uv = vim.uv or vim.loop
  local st = uv.fs_lstat(path)
  if not st then
    return nil, nil
  end
  if st.type ~= "file" then
    return nil,
      ("is a %s, not a plain file: refused (a snapshot is read as untrusted)"):format(st.type)
  end
  if st.size > M.MAX_BYTES then
    return nil, ("has %d bytes, more than %d: refused"):format(st.size, M.MAX_BYTES)
  end
  if not inside_root(path, root) then
    return nil, "leads out of the project (a linked folder): refused"
  end
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "cannot be read: " .. tostring(err)
  end
  local text = f:read(M.MAX_BYTES + 1) or ""
  f:close()
  if #text > M.MAX_BYTES then
    return nil, ("has more than %d bytes: refused"):format(M.MAX_BYTES)
  end
  return text
end

---Compare a screen with its snapshot file (see the module header for the outcomes).
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Result
function M.compare(name, shot, opts)
  opts = opts or {}
  local path, rel = M.path(name, opts)
  if not path then
    return { ok = false, status = "error", message = "screen snapshot: " .. rel }
  end
  local actual = M.render(M.normalize(shot, opts))
  local update = opts.update
  if update == nil then
    update = truthy(os.getenv("TESTING_UPDATE_SNAPSHOTS"))
  end
  local ci = opts.ci
  if ci == nil then
    ci = truthy(os.getenv("CI"))
  end
  local res = { path = path, rel = rel, actual = actual }
  local root = path:sub(1, #path - #rel - 1)
  local function refuse(problem)
    res.ok, res.status = false, "error"
    res.message = ("screen snapshot %s %s"):format(rel, problem)
    return res
  end

  local expected, problem = read_untrusted(path, root)
  if problem then
    return refuse(problem)
  end
  if not expected then
    if not inside_root(path, root) then
      return refuse("would be written out of the project (a linked folder): refused")
    end
    if ci and not update then
      res.ok, res.status = false, "missing"
      res.message = ("screen snapshot %s is missing (CI writes none): run the spec locally and commit the file"):format(
        rel
      )
      return res
    end
    local wrote, err = write(path, actual)
    res.ok = wrote
    res.status = wrote and "written" or "error"
    res.message = wrote and ("screen snapshot %s written (new): review and commit it"):format(rel)
      or ("screen snapshot %s could not be written: %s"):format(rel, err)
    return res
  end
  expected = expected:gsub("\r\n", "\n")
  if expected == actual then
    res.ok, res.status = true, "match"
    res.message = ("screen snapshot %s matches"):format(rel)
    return res
  end
  local diff, count = diff_rows(expected, actual)
  diff = table.concat(vim.tbl_map(visible, vim.split(diff, "\n", { plain = true })), "\n")
  if update then
    local wrote, err = write(path, actual)
    res.ok = wrote
    res.status = wrote and "updated" or "error"
    res.message = wrote and ("screen snapshot %s updated (%d lines changed)"):format(rel, count)
      or ("screen snapshot %s could not be written: %s"):format(rel, err)
    return res
  end
  res.ok, res.status = false, "differ"
  res.message = ("screen snapshot %s differs (%d lines; - snapshot, + screen; accept with --update-snapshots or TESTING_UPDATE_SNAPSHOTS=1):\n%s"):format(
    rel,
    count,
    diff
  )
  return res
end

---Compare and hand the verdict to the harness: `ok_fn(ok, message)`.
---@param ok_fn fun(ok: boolean, msg?: string): any
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return boolean ok, Testing.Screen.Result result
function M.expect(ok_fn, name, shot, opts)
  local res = M.compare(name, shot, opts)
  ok_fn(res.ok, res.message)
  return res.ok, res
end

---Compare and raise on a failure (busted style specs).
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Result
function M.check(name, shot, opts)
  local res = M.compare(name, shot, opts)
  if not res.ok then
    error(res.message, 2)
  end
  return res
end

return M
