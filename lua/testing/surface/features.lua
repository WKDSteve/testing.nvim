---@module 'testing.surface.features'
---@brief The feature catalog against the surface: which functionality rests on an entry, and which entry it names wrongly.
---@description
--- The catalog (`TESTS/sheets/features.lua`, `testing.sheet.features`) lists per functionality the surface entries it
--- rests on (`surface = { "command:Hover copy", "binding:Y" }`); `testing surface` knows the entries and which of them
--- a tracked run reached. Together:
---
---   * an entry that is not covered names the functionality that rests on it and whether that one has a sheet
---     (`binding:Y - feature hover.copy has no sheet`), so the gap is read as a missing check of a function, not of a
---     key;
---   * an entry the catalog names and the surface does not have is a finding (a typo, a renamed command): a note,
---     never a failure, since the catalog is documentation;
---   * the sheet report lists per functionality its entries that the last baseline of the surface gate
---     (`surface.baseline.json`) has as not exercised.
---
--- Pure apart from `load`, which reads the catalog and the sheets of a project.

local M = {}

---@class Testing.Surface.FeatureRef
---@field id string The functionality (an id of the catalog).
---@field sheet boolean Whether a sheet names it (`feature = "<id>"`).

---@class Testing.Surface.Features
---@field by_entry table<string, Testing.Surface.FeatureRef[]> Per surface id the functionalities that rest on it, in the catalog's order.
---@field unknown { feature: string, entry: string }[] Entries the catalog names that the surface does not have.

---Index a catalog by surface entry and check its entries against the surface.
---@param catalog Testing.Sheet.Feature[]
---@param with_sheet table<string, true> The ids of the functionalities a sheet names.
---@param known? table<string, true> The ids of the surface; nil: not checked (no unknown entries are reported).
---@return Testing.Surface.Features
function M.index(catalog, with_sheet, known)
  local by_entry, unknown = {}, {}
  for _, f in ipairs(catalog) do
    for _, entry in ipairs(f.surface or {}) do
      if type(entry) == "string" then
        if known and not known[entry] then
          unknown[#unknown + 1] = { feature = f.id, entry = entry }
        end
        local list = by_entry[entry] or {}
        list[#list + 1] = { id = f.id, sheet = with_sheet[f.id] == true }
        by_entry[entry] = list
      end
    end
  end
  return { by_entry = by_entry, unknown = unknown }
end

---What a not covered entry says after its id: the functionalities that rest on it, or that no test of a function
---reaches it.
---@param refs Testing.Surface.FeatureRef[]|nil
---@return string
function M.gap_text(refs)
  if not refs or #refs == 0 then
    return "no feature test"
  end
  local parts = {}
  for _, r in ipairs(refs) do
    parts[#parts + 1] = ("feature %s %s"):format(r.id, r.sheet and "has a sheet" or "has no sheet")
  end
  return table.concat(parts, "; ")
end

---The ids of the functionalities that a sheet of the project names.
---@param root string
---@return table<string, true>
function M.with_sheet(root)
  local sheet = require("testing.sheet")
  local out = {}
  for _, path in ipairs(sheet.files(root .. "/TESTS/sheets")) do
    local s = sheet.load(path)
    if s and type(s.feature) == "string" then
      out[s.feature] = true
    end
  end
  return out
end

---The catalog of a project against its surface. No catalog: nil (nothing to say); a catalog that does not load: nil
---and the reason.
---@param root string
---@param entries? { id: string }[] The entries of the surface; nil: unknown entries are not checked.
---@return Testing.Surface.Features|nil features, string|nil err
function M.load(root, entries)
  local catalog, err = require("testing.sheet.features").load(root)
  if not catalog then
    return nil, err
  end
  local known
  if entries then
    known = {}
    for _, e in ipairs(entries) do
      known[e.id] = true
    end
  end
  return M.index(catalog, M.with_sheet(root), known), nil
end

---The baseline of the surface gate of a project (`surface.baseline.json`, `testing.ci.derive`): the status of each
---entry that counts, nil without the file or when it does not parse.
---@param root string
---@return table<string, string>|nil statuses
function M.baseline_statuses(root)
  local path = root .. "/" .. require("testing.ci.derive").SURFACE_BASELINE
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read(4 * 1024 * 1024 + 1) or ""
  f:close()
  if #text > 4 * 1024 * 1024 then
    return nil
  end
  local base = require("testing.surface.coverage").parse_baseline(text)
  return base and base.entries or nil
end

---The entries of a functionality that the baseline has as not exercised (`missing`), in the catalog's order.
---@param feature Testing.Sheet.Feature
---@param statuses table<string, string>
---@return string[]
function M.unmeasured(feature, statuses)
  local out = {}
  for _, entry in ipairs(feature.surface or {}) do
    if statuses[entry] == "missing" then
      out[#out + 1] = entry
    end
  end
  return out
end

return M
