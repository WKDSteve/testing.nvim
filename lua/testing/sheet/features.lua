---@module 'testing.sheet.features'
---@brief The feature catalog of a repository: the functionalities of the plugin as its user sees them.
---@description
--- `TESTS/sheets/features.lua` returns a list, read as data like a sheet (`testing.sheet.load_data`: an empty
--- environment, the size and instruction limits):
---
---   return {
---     { id = "hover.http-preview", title = "A hover over an http(s) link shows the page", surface = { ... }, docs = "..." },
---   }
---
--- `id` has the form of a sheet id and is unique, `title` is a non-empty line, `surface` (optional) lists the entries
--- of the surface it rests on (`command:Hover show`, `binding:Y`), `docs` (optional) names where it is described.
--- A sheet names its functionality with `feature = "<id>"`; `testing sheets report` says which functionality has no
--- sheet, K16 warns about a `feature` the catalog does not know. A repository without the file has no catalog: there
--- is nothing to compare with, and nothing is said.

local M = {}

M.FILE = "TESTS/sheets/features.lua"
---Entries a catalog may have (more is a mistake of the file, not a big plugin).
M.MAX_ENTRIES = 500
M.MAX_TITLE = 300

---@class Testing.Sheet.Feature
---@field id string
---@field title string
---@field surface? string[]
---@field docs? string

local KEYS = { id = "string", title = "string", surface = "table", docs = "string" }

---Check the shape of a catalog; the message names the entry and the field.
---@param list any
---@return Testing.Sheet.Feature[]|nil catalog, string|nil err
function M.validate(list)
  if type(list) ~= "table" then
    return nil, "the catalog returns a list of { id, title, surface?, docs? }"
  end
  local n = 0
  for k in pairs(list) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return nil, ("the catalog is a list: key %s is no position"):format(tostring(k))
    end
    n = n + 1
  end
  if n ~= #list then
    return nil, "the catalog is a list without holes"
  end
  if n > M.MAX_ENTRIES then
    return nil, ("the catalog has %d entries, at most %d"):format(n, M.MAX_ENTRIES)
  end
  local seen = {}
  for i, f in ipairs(list) do
    if type(f) ~= "table" then
      return nil, ("[%d] must be a table { id, title, ... }"):format(i)
    end
    for k, v in pairs(f) do
      local want = KEYS[k]
      if not want then
        return nil, ("[%d]: unknown field %s"):format(i, tostring(k))
      end
      if type(v) ~= want then
        return nil, ("[%d].%s must be a %s"):format(i, k, want)
      end
    end
    if not f.id or not f.id:match(require("testing.sheet").ID_PATTERN) then
      return nil, ("[%d].id: letters, digits, '_', '-', '.'"):format(i)
    end
    if seen[f.id] then
      return nil, ("[%d].id %s is there already ([%d])"):format(i, f.id, seen[f.id])
    end
    seen[f.id] = i
    if not f.title or vim.trim(f.title) == "" or f.title:find("[\r\n]") then
      return nil, ("[%d].title is required, one line"):format(i)
    end
    if vim.fn.strchars(f.title) > M.MAX_TITLE then
      return nil, ("[%d].title is longer than %d characters"):format(i, M.MAX_TITLE)
    end
    if f.surface ~= nil then
      if #f.surface ~= vim.tbl_count(f.surface) then
        return nil, ("[%d].surface must be a list of strings"):format(i)
      end
      for j, entry in ipairs(f.surface) do
        if type(entry) ~= "string" or entry == "" then
          return nil, ("[%d].surface[%d] must be a non-empty string"):format(i, j)
        end
      end
    end
    if f.docs ~= nil and (f.docs == "" or f.docs:find("[\r\n]")) then
      return nil, ("[%d].docs must be a path on one line"):format(i)
    end
  end
  return list, nil
end

---Read the text of a catalog as data and check it; `name` stands for the file in messages.
---@param text string
---@param name string
---@return Testing.Sheet.Feature[]|nil catalog, string|nil err
function M.load_text(text, name)
  local value, derr = require("testing.sheet").load_data(text, name, "feature catalog")
  if derr then
    return nil, derr
  end
  local list, err = M.validate(value)
  if not list then
    return nil, ("%s: %s"):format(name, err)
  end
  return list, nil
end

---The catalog of a repository. No file: `nil, nil` (no catalog); a file that does not load: `nil, err`.
---@param root string
---@return Testing.Sheet.Feature[]|nil catalog, string|nil err
function M.load(root)
  local path = root .. "/" .. M.FILE
  local f = io.open(path, "rb")
  if not f then
    return nil, nil
  end
  local sheet = require("testing.sheet")
  local text = f:read(sheet.MAX_BYTES + 1) or ""
  f:close()
  return M.load_text(text, M.FILE)
end

---The entries by id.
---@param catalog Testing.Sheet.Feature[]
---@return table<string, Testing.Sheet.Feature>
function M.by_id(catalog)
  local out = {}
  for _, f in ipairs(catalog) do
    out[f.id] = f
  end
  return out
end

return M
