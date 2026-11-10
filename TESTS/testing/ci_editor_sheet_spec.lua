-- @cache-inputs TESTS/sheets/ TESTS/__snapshots__/
-- TESTS/testing/ci_editor_sheet_spec.lua -- the test sheets of this repository (TESTS/sheets, docs/SHEETS.md) as cases
-- `sheet:<id>`; `:Testing ci` in a child editor is the one there is so far.

return function(H)
  local sheet = require("testing.sheet")
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local root = vim.fs.dirname(vim.fs.dirname(here))
  local files = sheet.files(root .. "/TESTS/sheets")
  H.ok(#files > 0, "there is a sheet")
  -- the pictures of `shot` steps go to a temp folder: a run of the suite writes nothing into the checkout
  local out_dir = vim.fn.tempname() .. "-sheets-out"
  for _, path in ipairs(files) do
    local s, err = sheet.load(path)
    H.ok(s ~= nil, "loads: " .. tostring(err))
    if s then
      sheet.expect(H.ok, s, { root = root, out_dir = out_dir })
    end
  end
  vim.fn.delete(out_dir, "rf")
end
