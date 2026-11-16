-- @cache-inputs TESTS/sheets/ TESTS/__snapshots__/
-- TESTS/testing/ci_editor_sheet_spec.lua -- the test sheets of this repository (TESTS/sheets, docs/SHEETS.md), each its
-- own case `sheet:<id>`: busted style on purpose, so `testing sheets report --from <suite IR>` finds every sheet's
-- result by that name (one H case for all of them left every sheet `never`). testing.commands takes about 30 s, so
-- `.testing.lua` gives a case more than the default `case_ms`.
---@diagnostic disable: undefined-global
-- luacheck: read globals describe it teardown

local sheet = require("testing.sheet")
local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
local root = vim.fs.dirname(vim.fs.dirname(here))
-- the pictures of `shot` steps go to a temp folder: a run of the suite writes nothing into the checkout
local out_dir = vim.fn.tempname() .. "-sheets-out"

describe("test sheets", function()
  local files = sheet.files(root .. "/TESTS/sheets")
  it("there is a sheet", function()
    assert(#files > 0, "no sheet in TESTS/sheets")
  end)
  for _, path in ipairs(files) do
    local s, err = sheet.load(path)
    it(s and sheet.spec_name(s) or path, function()
      assert(s, err)
      sheet.check(s, { root = root, out_dir = out_dir })
    end)
  end
  teardown(function()
    vim.fn.delete(out_dir, "rf")
  end)
end)
