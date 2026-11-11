---@module 'testing.sheet'
---@brief Test sheets: a live check written down as data and run by the RPC klicker.
---@description
--- A live check used to be prose ("open :UI, look whether the rows read well"). A sheet keeps the
--- same check as data in `TESTS/sheets/<name>.sheet.lua`, so that the part a machine can do runs with
--- the suite and only the judgement is left for a person:
---
---   return {
---     id = "ui.option-float",                -- stable; the spec case is called `sheet:<id>`
---     title = ":UI option float",
---     task = "ui.nvim/try-the-ui-option-float-in-a-real-session",
---     engine = "rpc",                         -- "rpc" (testing.rpc) or "manual" (nothing to run)
---     sizes = { { rows = 24, cols = 80 } },   -- one run per size; default 24x80
---     args = { "+Session load x" },           -- the child's command line after its own (rpc; no shell)
---     steps = {
---       { keys = ":UI<CR>", note = "open the float" },
---       { wait = "vim.api.nvim_win_get_config(0).relative ~= ''" },
---       { screen = "float", masks = { { row = 24 } } },
---       { keys = "q" },
---       { expect = "vim.api.nvim_win_get_config(0).relative == ''", note = "the float is gone" },
---     },
---     judge = { "rows and texts read well" },  -- criteria for a person (or later an AI reviewer)
---     manual = { "press <M-h> in the real config" },  -- steps only a person can do
---   }
---
--- Steps (exactly one action each, `note` optional):
---
---   keys = s      typed through `child.feed` (mappings apply; returns when the typeahead is empty);
---                 an error message the keys cause (`v:errmsg`) fails the step, unless
---                 `ignore_errmsg = true` (a mapping that runs `silent! cmd` on purpose still sets it)
---   input = s     queued through `child.input` (returns at once)
---   lua = s       run in the child (`child.lua`)
---   settle = ms   wait until the child is idle (`child.settle`; not idle is a failure)
---   wait = expr   poll a Lua expression in the child until it is truthy (`timeout` ms, default 2000)
---   expect = expr a Lua expression in the child must be truthy now
---   screen = name compare the screen with a snapshot (`testing.screen`; `masks`, `cursor`, `mode`
---                 pass through, `groups = true` adds the highlight group of each attribute letter);
---                 the name gets the size: `float.80x24`
---   hl = { ... }  how a place on the screen is drawn: `text = s` (its first appearance, every cell of it) or
---                 `row`, `col` (`cols` wide), and what must hold: `group` (by name or the group a link
---                 ends in), `fg`, `bg`, `sp` (`#rrggbb`), `bold`, `italic`, `underline`, `undercurl`,
---                 `strikethrough`, `reverse`
---   restart = true  quit the child as a person does (`:qall!`, `VimLeavePre` runs) and start it again in the
---                 same sandbox (its stdpath and temp directories stay), the UI attached again; `args = { ... }`
---                 on the step is the command line of this start, without it the sheet's `args`
---
--- `args` (of the sheet and of a restart) is a list, no shell: `+cmd` and `-c cmd` (at most 10, as the editor takes),
--- `--cmd cmd` (at most 9: the harness puts the sheet's size first, `set lines=.. columns=..`, so that what runs at
--- startup lays out for it) and file names; any other option is refused, the harness owns the rest of the command line.
---
--- The file is loaded as DATA: `load` with an empty environment, so a sheet cannot call anything
--- while it is read; what runs is the Lua of its steps, in the child editor. `load` checks the shape
--- and names the field of a mistake.

local M = {}

M.VERSION = 1
M.ENGINES = { rpc = true, manual = true, browser = true, desktop = true }
M.ACTIONS = {
  "keys",
  "input",
  "lua",
  "settle",
  "wait",
  "expect",
  "screen",
  "open",
  "press",
  "click",
  "hover",
  "focus",
  "blur",
  "scheme",
  "shot",
  "toggle",
  "set",
  "ask",
  "restart",
  "hl",
}
---The steps of each engine: `wait` and `expect` exist in both, in the browser they are JavaScript in the page.
M.ENGINE_ACTIONS = {
  rpc = {
    keys = true,
    input = true,
    lua = true,
    settle = true,
    wait = true,
    expect = true,
    screen = true,
    ask = true,
    restart = true,
    hl = true,
    -- the screen drawn as a page and photographed by the browser engine (`testing.sheet.shot`)
    shot = true,
  },
  browser = {
    open = true,
    press = true,
    click = true,
    hover = true,
    focus = true,
    blur = true,
    scheme = true,
    wait = true,
    expect = true,
    shot = true,
    ask = true,
  },
  -- by accessible name, `wait` and `expect` also as { name, state, value }
  desktop = {
    wait = true,
    expect = true,
    toggle = true,
    click = true,
    set = true,
    shot = true,
    ask = true,
  },
}
M.DEFAULT_MINIT = "TESTS/minimal_init.lua"
M.DEFAULT_WAIT_MS = 2000
M.MAX_BYTES = 256 * 1024
M.MAX_LOAD_INSTRUCTIONS = 1000000
---The form of an `id`, a `feature` and an id of the feature catalog.
M.ID_PATTERN = "^[%w][%w_.%-]*$"

---@class Testing.Sheet.Step
---@field keys? string
---@field input? string
---@field lua? string
---@field settle? integer
---@field wait? string
---@field timeout? integer Milliseconds of a `wait`.
---@field expect? string
---@field screen? string
---@field open? string
---@field press? string
---@field click? string
---@field hover? string A CSS selector the pointer moves over (browser): a later `shot` shows the `:hover` state.
---@field focus? string A CSS selector that gets the keyboard focus (browser).
---@field blur? boolean Takes the keyboard focus from whatever has it (browser); red when something but the page itself holds it afterwards.
---@field scheme? "light"|"dark" The page's `prefers-color-scheme` from now on (browser).
---@field shot? string
---@field toggle? string
---@field set? string
---@field value? number What a `set` step sets.
---@field ask? string A question to a person: asked in a stepped run, a `judge` criterion in any other.
---@field masks? (string|table)[]
---@field cursor? boolean
---@field mode? boolean
---@field note? string
---@field ignore_errmsg? boolean
---@field restart? boolean Quit the child and start it again in the same sandbox.
---@field args? string[] The command line of a `restart` (else the sheet's `args`).

---@class Testing.Sheet
---@field id string
---@field title string
---@field task? string
---@field feature? string The functionality of the plugin this sheet checks, an `id` of the repository's feature
---catalog (`TESTS/sheets/features.lua`, `testing.sheet.features`); a sheet with it is a feature sheet.
---@field engine "rpc"|"manual"|"browser"
---@field minit? string Relative to the root (default `TESTS/minimal_init.lua`).
---@field config? "user" The child runs the user's installed config, read only, instead of the minit (rpc only).
---@field args? string[] The child's command line after its own (`+cmd`, `-c cmd`, `--cmd cmd`, a file): rpc only.
---@field sizes { rows: integer, cols: integer }[]
---@field steps Testing.Sheet.Step[]
---@field judge string[]
---@field manual string[]
---@field notes? string
---@field requires? Testing.Sheet.Requirement[] Conditions the child editor must meet, else the sheet is a reported skip.
---@field app? string The name of a program in `sheets.apps` of the project's `.testing.lua` (`testing.sheet.app`).
---@field path? string Where it was loaded from.

---@class Testing.Sheet.Requirement
---@field lua string A Lua expression evaluated in the child before the first step; falsy = the sheet is skipped.
---@field reason string The `n/a` text.

---@class Testing.Sheet.Result
---@field ok boolean
---@field status "pass"|"fail"|"manual"|"skip"|"aborted" `aborted` only from a session that was cancelled.
---@field skipped? string Why a sheet was skipped (a browser sheet without node, Playwright or chromium).
---@field failures string[] One line per failed step (size, step number, what).
---@field snapshots string[] The messages of the screen steps (written, matched, updated).

local STEP_KEYS = {
  keys = "string",
  input = "string",
  lua = "string",
  settle = "number",
  wait = "string",
  timeout = "number",
  expect = "string",
  screen = "string",
  open = "string",
  press = "string",
  click = "string",
  hover = "string",
  focus = "string",
  blur = "boolean",
  scheme = "string",
  shot = "string",
  toggle = "string",
  set = "string",
  value = "number",
  ask = "string",
  masks = "table",
  cursor = "boolean",
  mode = "boolean",
  note = "string",
  ignore_errmsg = "boolean",
  restart = "boolean",
  args = "table",
  hl = "table",
  groups = "boolean",
}
local SHEET_KEYS = {
  id = "string",
  title = "string",
  task = "string",
  engine = "string",
  minit = "string",
  sizes = "table",
  steps = "table",
  judge = "table",
  manual = "table",
  notes = "string",
  requires = "table",
  app = "string",
  args = "table",
  config = "string",
  feature = "string",
}

---@param v any
---@return boolean
local function is_list(v)
  if type(v) ~= "table" then
    return false
  end
  -- every key an integer 1..n and n keys: `{ nil, x, y = 1 }` has `#v == 2` and two keys, yet
  -- `ipairs` sees nothing of it
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if v[i] == nil then
      return false
    end
  end
  return true
end

---Upper bounds: an endless wait (`timeout = 1/0`) or a screen of a billion rows is a mistake, not a check.
M.MAX_MS = 10 * 60 * 1000
M.MAX_CELLS = 1000
---A browser or desktop sheet's size is pixels, not cells: a page taller than a screen is a normal thing to shoot.
M.MAX_PIXELS = 4000

---@param v any
---@param max number
---@return boolean
local function pos_int(v, max)
  return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= max
end

---@param list any
---@param what string
---@return string|nil err
local function check_strings(list, what)
  if list == nil then
    return nil
  end
  if not is_list(list) then
    return what .. " must be a list of strings"
  end
  for i, s in ipairs(list) do
    if type(s) ~= "string" or s == "" then
      return ("%s[%d] must be a non-empty string"):format(what, i)
    end
  end
  return nil
end

---@param list any
---@return string|nil err
local function check_requires(list)
  if list == nil then
    return nil
  end
  if not is_list(list) then
    return "requires must be a list of { lua = ..., reason = ... }"
  end
  for i, r in ipairs(list) do
    if type(r) ~= "table" then
      return ("requires[%d] must be a table"):format(i)
    end
    for k in pairs(r) do
      if k ~= "lua" and k ~= "reason" then
        return ("requires[%d]: unknown field %s"):format(i, tostring(k))
      end
    end
    if type(r.lua) ~= "string" or r.lua == "" then
      return ("requires[%d].lua must be a non-empty string"):format(i)
    end
    if type(r.reason) ~= "string" or r.reason == "" then
      return ("requires[%d].reason must be a non-empty string"):format(i)
    end
  end
  return nil
end

M.MAX_ARGS = 20
M.MAX_ARG_BYTES = 1000
---How many `+cmd` and `-c cmd` the editor takes.
M.MAX_ARG_COMMANDS = 10
---How many `--cmd cmd` a sheet may give: the editor takes 10, the first is the harness's (the sheet's size).
M.MAX_ARG_PRE_COMMANDS = 9

---The child's command line: a list without a shell, `+cmd`, `-c cmd`, `--cmd cmd` and file names. Every other
---option is refused: the harness owns the rest of the command line (`--embed`, `-u`, `--clean`, `-i NONE`), and an
---option such as `--listen`, `-l` or `-s` would change what the sheet is a check of.
---@param list any
---@param at string
---@return string|nil err
function M.check_args(list, at)
  if not is_list(list) then
    return at .. " must be a list of strings"
  end
  if #list > M.MAX_ARGS then
    return ("%s: at most %d arguments"):format(at, M.MAX_ARGS)
  end
  local commands, pre, i = 0, 0, 1
  while i <= #list do
    local a = list[i]
    local here = ("%s[%d]"):format(at, i)
    if type(a) ~= "string" or a == "" then
      return here .. " must be a non-empty string"
    end
    if #a > M.MAX_ARG_BYTES or a:find("%c") then
      return ("%s: at most %d bytes, no control character"):format(here, M.MAX_ARG_BYTES)
    end
    if a == "-c" or a == "--cmd" then
      local v = list[i + 1]
      if type(v) ~= "string" or v == "" or v:find("%c") or #v > M.MAX_ARG_BYTES then
        return ("%s: %s takes a command after it"):format(here, a)
      end
      if a == "-c" then
        commands = commands + 1
      else
        pre = pre + 1
      end
      i = i + 2
    elseif a:sub(1, 1) == "+" then
      commands, i = commands + 1, i + 1
    elseif a:sub(1, 1) == "-" then
      return ("%s: %q is refused (only +cmd, -c, --cmd and file names)"):format(here, a)
    else
      i = i + 1
    end
  end
  if commands > M.MAX_ARG_COMMANDS then
    return ("%s: at most %d commands (+cmd, -c)"):format(at, M.MAX_ARG_COMMANDS)
  end
  if pre > M.MAX_ARG_PRE_COMMANDS then
    return ("%s: at most %d --cmd (the first is the sheet's size)"):format(
      at,
      M.MAX_ARG_PRE_COMMANDS
    )
  end
  return nil
end

---What a desktop `wait` or `expect` asks of an element.
---@param v table
---@param at string
---@return string|nil err
local function check_want(v, at)
  for k in pairs(v) do
    if k ~= "name" and k ~= "state" and k ~= "value" then
      return ("%s: unknown field %s"):format(at, tostring(k))
    end
  end
  if type(v.name) ~= "string" or v.name == "" then
    return at .. ".name must be a non-empty string"
  end
  if v.state ~= nil and v.state ~= "on" and v.state ~= "off" then
    return at .. '.state must be "on" or "off"'
  end
  if v.value ~= nil and type(v.value) ~= "number" then
    return at .. ".value must be a number"
  end
  return nil
end

---@param step any
---@param i integer
---@param engine string
---@return string|nil err
local function check_step(step, i, engine)
  local at = ("steps[%d]"):format(i)
  if type(step) ~= "table" then
    return at .. " must be a table"
  end
  for k, v in pairs(step) do
    local want = STEP_KEYS[k]
    if not want then
      return ("%s: unknown field %s"):format(at, tostring(k))
    end
    if engine == "desktop" and (k == "wait" or k == "expect") and type(v) == "table" then
      local werr = check_want(v, ("%s.%s"):format(at, k))
      if werr then
        return werr
      end
    elseif type(v) ~= want then
      return ("%s.%s must be a %s"):format(at, k, want)
    end
  end
  local action
  for _, a in ipairs(M.ACTIONS) do
    if step[a] ~= nil then
      if action then
        return ("%s has two actions (%s and %s): one per step"):format(at, action, a)
      end
      action = a
    end
  end
  if not action then
    return at .. " has no action (one of " .. table.concat(M.ACTIONS, ", ") .. ")"
  end
  if
    (action == "settle" and not pos_int(step.settle, M.MAX_MS))
    or (step.timeout and not pos_int(step.timeout, M.MAX_MS))
  then
    return at .. ": milliseconds must be a whole number from 1 to " .. M.MAX_MS
  end
  if step.ignore_errmsg ~= nil and action ~= "keys" then
    return at .. ": ignore_errmsg belongs to a keys step"
  end
  if step.timeout and action ~= "wait" then
    return at .. ": timeout belongs to a wait step"
  end
  if
    (step.masks or step.cursor ~= nil or step.mode ~= nil or step.groups ~= nil)
    and action ~= "screen"
  then
    return at .. ": masks, cursor, mode and groups belong to a screen step"
  end
  if action == "hl" then
    local herr = M.check_hl(step.hl, at .. ".hl")
    if herr then
      return herr
    end
  end
  if action == "screen" and not step.screen:match("^[%w][%w_%-]*$") then
    return at .. ".screen: letters, digits, '_' and '-'"
  end
  -- `shot` is a part of a file name (`<id>.<shot>.<size>.png`): no path separators, no `..`
  if action == "shot" and not step.shot:match("^[%w][%w_%-]*$") then
    return at .. ".shot: letters, digits, '_' and '-'"
  end
  if
    (
      action == "open"
      or action == "press"
      or action == "click"
      or action == "hover"
      or action == "focus"
      or action == "toggle"
      or action == "set"
      or action == "ask"
    ) and step[action] == ""
  then
    return ("%s.%s must not be empty"):format(at, action)
  end
  if action == "scheme" and step.scheme ~= "light" and step.scheme ~= "dark" then
    return at .. '.scheme: "light" or "dark"'
  end
  if (step.value ~= nil) ~= (action == "set") then
    return at .. ": a set step takes a value, nothing else does"
  end
  if action == "restart" and step.restart ~= true then
    return at .. ".restart must be true"
  end
  if action == "blur" and step.blur ~= true then
    return at .. ".blur must be true"
  end
  if step.args ~= nil then
    if action ~= "restart" then
      return at .. ": args belongs to a restart step"
    end
    local aerr = M.check_args(step.args, at .. ".args")
    if aerr then
      return aerr
    end
  end
  return nil
end

local HL_KEYS = {
  text = "string",
  row = "number",
  col = "number",
  cols = "number",
  group = "string",
  fg = "string",
  bg = "string",
  sp = "string",
  bold = "boolean",
  italic = "boolean",
  underline = "boolean",
  undercurl = "boolean",
  strikethrough = "boolean",
  reverse = "boolean",
}

---The table of an `hl` step: one place (`text`, or `row` and `col`) and at least one thing that must hold.
---@param hl table
---@param at string
---@return string|nil err
function M.check_hl(hl, at)
  for k, v in pairs(hl) do
    local want = HL_KEYS[k]
    if not want then
      return ("%s: unknown field %s"):format(at, tostring(k))
    end
    if type(v) ~= want then
      return ("%s.%s must be a %s"):format(at, k, want)
    end
  end
  if (hl.text ~= nil) == (hl.row ~= nil) then
    return at .. ": a place is text = s or row = n, col = n (one of them)"
  end
  if hl.text == "" then
    return at .. ".text must not be empty"
  end
  if hl.text and (hl.col or hl.cols) then
    return at .. ": col and cols belong to row"
  end
  if hl.row and not hl.col then
    return at .. ": row needs col"
  end
  for _, k in ipairs({ "row", "col", "cols" }) do
    if hl[k] ~= nil and not pos_int(hl[k], 10000) then
      return ("%s.%s must be a whole number from 1"):format(at, k)
    end
  end
  if hl.group == "" then
    return at .. ".group must not be empty"
  end
  for _, k in ipairs({ "fg", "bg", "sp" }) do
    if hl[k] and not hl[k]:match("^#%x%x%x%x%x%x$") then
      return ("%s.%s must be a colour #rrggbb"):format(at, k)
    end
  end
  local checks = 0
  for k in pairs(hl) do
    if k ~= "text" and k ~= "row" and k ~= "col" and k ~= "cols" then
      checks = checks + 1
    end
  end
  if checks == 0 then
    return at .. ": nothing to check (group, fg, bg, sp or a style)"
  end
  return nil
end

---Check the shape of a sheet; fills the defaults.
---@param s any
---@return Testing.Sheet|nil sheet, string|nil err
function M.validate(s)
  if type(s) ~= "table" then
    return nil, "a sheet returns a table"
  end
  for k, v in pairs(s) do
    local want = SHEET_KEYS[k]
    if not want then
      return nil, "unknown field " .. tostring(k)
    end
    if type(v) ~= want then
      return nil, ("%s must be a %s"):format(k, want)
    end
  end
  if not s.id or not s.id:match(M.ID_PATTERN) then
    return nil, "id: letters, digits, '_', '-', '.'"
  end
  if not s.title or s.title == "" then
    return nil, "title is required"
  end
  -- only the form: what it means is the catalog's, and a sheet loads without it
  if s.feature ~= nil and not s.feature:match(M.ID_PATTERN) then
    return nil, "feature: letters, digits, '_', '-', '.' (an id of TESTS/sheets/features.lua)"
  end
  s.engine = s.engine or "rpc"
  if not M.ENGINES[s.engine] then
    return nil, "engine must be rpc, browser, desktop or manual"
  end
  s.steps = s.steps or {}
  if not is_list(s.steps) then
    return nil, "steps must be a list"
  end
  for i, step in ipairs(s.steps) do
    local err = check_step(step, i, s.engine)
    if err then
      return nil, err
    end
  end
  if (s.engine == "rpc" or s.engine == "browser" or s.engine == "desktop") and #s.steps == 0 then
    return nil,
      ("%s sheet needs steps"):format(s.engine == "rpc" and "an rpc" or ("a " .. s.engine))
  end
  local allowed = M.ENGINE_ACTIONS[s.engine]
  for i, step in ipairs(s.steps) do
    for _, a in ipairs(M.ACTIONS) do
      if step[a] ~= nil and allowed and not allowed[a] then
        return nil, ("steps[%d]: %s is not a step of a %s sheet"):format(i, a, s.engine)
      end
    end
  end
  if s.engine == "manual" then
    for _, step in ipairs(s.steps) do
      if not step.ask then
        return nil, "a manual sheet has no steps but questions (manual = { ... } instead)"
      end
    end
  end
  -- a browser sheet's size is the viewport in pixels (cols = width, rows = height)
  s.sizes = s.sizes
    or {
      (s.engine == "browser" or s.engine == "desktop") and { rows = 700, cols = 1000 }
        or { rows = 24, cols = 80 },
    }
  if not is_list(s.sizes) or #s.sizes == 0 then
    return nil, "sizes must be a non-empty list"
  end
  local max_size = (s.engine == "browser" or s.engine == "desktop") and M.MAX_PIXELS or M.MAX_CELLS
  for i, size in ipairs(s.sizes) do
    if
      type(size) ~= "table"
      or not pos_int(size.rows, max_size)
      or not pos_int(size.cols, max_size)
    then
      return nil, ("sizes[%d] must be { rows = n, cols = n } with 1 <= n <= %d"):format(i, max_size)
    end
  end
  for _, f in ipairs({ "judge", "manual" }) do
    local err = check_strings(s[f], f)
    if err then
      return nil, err
    end
    s[f] = s[f] or {}
  end
  -- what nobody can answer now waits for a person like any other criterion: the same line in the task, the same inbox
  for _, step in ipairs(s.steps) do
    if step.ask and not vim.tbl_contains(s.judge, step.ask) then
      s.judge[#s.judge + 1] = step.ask
    end
  end
  if s.engine == "manual" and #s.manual == 0 and #s.steps == 0 then
    return nil, "a manual sheet lists its manual steps"
  end
  local rerr = check_requires(s.requires)
  if rerr then
    return nil, rerr
  end
  if s.requires and s.engine ~= "rpc" then
    return nil, "requires belongs to an rpc sheet"
  end
  if s.args ~= nil then
    if s.engine ~= "rpc" then
      return nil, "args belongs to an rpc sheet"
    end
    local aerr = M.check_args(s.args, "args")
    if aerr then
      return nil, aerr
    end
  end
  if s.config ~= nil then
    if s.config ~= "user" then
      return nil, 'config: "user" (the installed config of the user, read only)'
    end
    if s.engine ~= "rpc" then
      return nil, "config belongs to an rpc sheet"
    end
    if s.minit then
      return nil, 'config = "user" runs the user\'s init: no minit'
    end
  end
  if s.app then
    if s.engine ~= "browser" and s.engine ~= "desktop" then
      return nil, "app belongs to a browser or desktop sheet"
    end
    if not s.app:match("^[%w][%w_.%-]*$") then
      return nil, "app: letters, digits, '_', '-', '.'"
    end
  end
  if s.engine == "desktop" and not s.app then
    return nil, "a desktop sheet names its app"
  end
  return s, nil
end

---Read a sheet file as data (empty environment) and validate it.
---@param path string
---@return Testing.Sheet|nil sheet, string|nil err
function M.load(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local text = f:read(M.MAX_BYTES + 1) or ""
  f:close()
  if #text > M.MAX_BYTES then
    return nil, ("%s is larger than %d bytes"):format(path, M.MAX_BYTES)
  end
  local s, err = M.load_text(text, path)
  if not s then
    return nil, err
  end
  s.path = path
  return s, nil
end

---Run the text of a data file (a sheet, the feature catalog) with an empty environment and under the instruction
---limit, and return what it returns; `name` stands for the file in messages, `what` names it in the message of a loop.
---@param text string
---@param name string
---@param what string
---@return any value, string|nil err
function M.load_data(text, name, what)
  if #text > M.MAX_BYTES then
    return nil, ("%s is larger than %d bytes"):format(name, M.MAX_BYTES)
  end
  local chunk, perr = load(text, "@" .. name, "t", {})
  if not chunk then
    return nil, tostring(perr)
  end
  -- data never needs a million instructions: a loop in a sheet (an AI's draft too) ends instead of hanging the reader
  local old_hook, old_mask, old_count = debug.gethook()
  debug.sethook(function()
    error(("%s: reading the %s takes too long (a loop?)"):format(name, what), 0)
  end, "", M.MAX_LOAD_INSTRUCTIONS)
  local ok, value = pcall(chunk)
  if old_hook then
    debug.sethook(old_hook, old_mask, old_count)
  else
    debug.sethook()
  end
  if not ok then
    return nil, tostring(value) -- already starts with `<path>:<line>:` (the chunk name)
  end
  return value, nil
end

---Read the text of a sheet as data (empty environment) and validate it; `name` stands for the file in messages.
---@param text string
---@param name string
---@return Testing.Sheet|nil sheet, string|nil err
function M.load_text(text, name)
  local value, derr = M.load_data(text, name, "sheet")
  if derr then
    return nil, derr
  end
  local path = name
  local s, err = M.validate(value)
  if not s then
    return nil, ("%s: %s"):format(path, err)
  end
  return s, nil
end

---The sheet files below `dir`, sorted (`*.sheet.lua`).
---@param dir string
---@return string[]
function M.files(dir)
  local out = {}
  dir = vim.fs.normalize(dir)
  if vim.fn.isdirectory(dir) == 0 then
    return out
  end
  for name, kind in vim.fs.dir(dir, { depth = 4 }) do
    if (kind == "file" or kind == "link") and name:match("%.sheet%.lua$") then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  table.sort(out)
  return out
end

---The name of the spec case that runs a sheet; the report finds the last result by it.
---@param s Testing.Sheet|string
---@return string
function M.spec_name(s)
  return "sheet:" .. (type(s) == "table" and s.id or s)
end

---The value of an action as one text: a desktop `wait` asks about a name, a state and a value.
---@param v any
---@return string|number
function M.value_text(v)
  if type(v) ~= "table" then
    return v
  end
  if v.name == nil and (v.text ~= nil or v.row ~= nil) then
    -- an `hl` step: the place, then what must hold, in a fixed order
    local parts = {
      v.text and ("%q"):format(v.text) or ("%d,%d"):format(v.row, v.col or 1),
    }
    if v.cols then
      parts[1] = parts[1] .. ("+%d"):format(v.cols)
    end
    for _, k in ipairs({ "group", "fg", "bg", "sp" }) do
      if v[k] ~= nil then
        parts[#parts + 1] = ("%s=%s"):format(k, v[k])
      end
    end
    for _, k in ipairs(require("testing.screen").HL_STYLES) do
      if v[k] ~= nil then
        parts[#parts + 1] = (v[k] and "" or "not ") .. k
      end
    end
    return table.concat(parts, " ")
  end
  local parts = { tostring(v.name) }
  if v.state ~= nil then
    parts[#parts + 1] = "state=" .. tostring(v.state)
  end
  if v.value ~= nil then
    parts[#parts + 1] = "value=" .. tostring(v.value)
  end
  return table.concat(parts, " ")
end

---@param step Testing.Sheet.Step
---@return string
local function describe(step)
  for _, a in ipairs(M.ACTIONS) do
    if step[a] ~= nil then
      -- one short line: a multi-line `wait`/`lua` would push the reason off the first line
      local value = tostring(M.value_text(step[a])):gsub("%s+", " ")
      -- cut by character, not byte: half a multi-byte character is invalid UTF-8 (JUnit XML)
      if vim.fn.strchars(value) > 60 then
        value = vim.fn.strcharpart(value, 0, 57) .. "..."
      end
      local what = ("%s %s"):format(a, value)
      local note = step.note and step.note:gsub("%s+", " ")
      return note and (note .. " (" .. what .. ")") or what
    end
  end
  return "?"
end

---Run a sheet: one child editor per size, the steps in order; the first failed step ends that size. The rpc engine
---is the loop over `testing.sheet.session`; the browser engine runs its plan in one go through the same step function
---of its runner (the suite has no use for a command channel that could hang).
---@param s Testing.Sheet
---@param opts? { root?: string, update?: boolean, ci?: boolean, spawn?: table }
---@return Testing.Sheet.Result
function M.run(s, opts)
  opts = opts or {}
  -- (a question has no answer here: the plan and the loop pass over it, `judge` keeps it)
  if s.engine == "browser" then
    return require("testing.sheet.browser").run(s, opts)
  end
  local session = require("testing.sheet.session").open(s, opts)
  while session:peek() do
    session:step()
  end
  session:close()
  return session:result()
end

---@param target string|Testing.Sheet
---@param opts? table
---@return Testing.Sheet|nil sheet, Testing.Sheet.Result|string result_or_err
local function load_and_run(target, opts)
  if type(target) ~= "string" then
    return target, M.run(target, opts)
  end
  local s, err = M.load(target)
  if not s then
    return nil, tostring(err)
  end
  return s, M.run(s, opts)
end

---Every failed step on the FIRST line: the state and the report keep only that line of a message.
---@param s Testing.Sheet
---@param res Testing.Sheet.Result
---@return string
local function failed_text(s, res)
  -- the first line of each failure (size, step, reason) on the first line; details such as a
  -- snapshot diff follow on the lines below
  local firsts, details = {}, {}
  for _, f in ipairs(res.failures) do
    local first, more = f:match("^([^\n]*)\n?(.*)$")
    firsts[#firsts + 1] = first
    if more and more ~= "" then
      details[#details + 1] = more
    end
  end
  local text = ("test sheet %s failed: %s"):format(s.id, table.concat(firsts, "; "))
  if #details > 0 then
    text = text .. "\n" .. table.concat(details, "\n")
  end
  return text
end
M._failed_text = failed_text -- for the spec
M._describe = describe -- for the spec

---Run a sheet and raise on a failure (busted style specs): `it(sheet.spec_name(s), function() sheet.check(path) end)`.
---@param target string|Testing.Sheet A path or a loaded sheet.
---@param opts? table As `run`.
---@return Testing.Sheet.Result
function M.check(target, opts)
  local s, res = load_and_run(target, opts)
  if not s then
    error("test sheet: " .. tostring(res), 2)
  end
  ---@cast res Testing.Sheet.Result
  if not res.ok then
    error(failed_text(s, res), 2)
  end
  if res.status == "skip" then
    print("n/a  " .. tostring(res.skipped))
  end
  return res
end

---Run a sheet and hand the verdict to the harness: `ok_fn(ok, message)`.
---@param ok_fn fun(ok: boolean, msg?: string): any
---@param target string|Testing.Sheet
---@param opts? table As `run`.
---@return boolean ok, Testing.Sheet.Result|string result
function M.expect(ok_fn, target, opts)
  local s, res = load_and_run(target, opts)
  if not s then
    ok_fn(false, "test sheet: " .. tostring(res))
    return false, res
  end
  ---@cast res Testing.Sheet.Result
  if res.status == "skip" then
    print("n/a  " .. tostring(res.skipped))
  end
  local msg = res.ok and ("test sheet %s: %s"):format(s.id, res.status) or failed_text(s, res)
  ok_fn(res.ok, msg)
  return res.ok, res
end

return M
