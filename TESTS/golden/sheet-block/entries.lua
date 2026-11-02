-- The input of the golden block (TESTS/golden/sheet-block/sheet-block.golden.md): the entries of three sheets of one
-- task and the boxes ticked in the task, as `testing.sheet.tasks.render_block` takes them. Shared by the spec and by
-- TESTS/golden/regenerate_sheet_block.lua; the golden file is the text a program (tasks-desktop) reads.
--
-- Returns the entries and the options of `render_block`.

local sheet = require("testing.sheet")

local function valid(def)
  return assert(sheet.validate(def))
end

local entries = {
  {
    root = "/work/ui.nvim",
    rel = "TESTS/sheets/picker.sheet.lua",
    sheet = valid({
      id = "picker",
      title = "The picker opens and closes",
      task = "ui.nvim/picker",
      steps = { { keys = "x" } },
      judge = { "the border is visible", "the title is centred" },
      manual = { "open it with the real mouse" },
    }),
    case = { status = "pass" },
    snapshots = {
      "TESTS/__snapshots__/sheets/picker.sheet/open.80x24.snap",
      "TESTS/__snapshots__/sheets/picker.sheet/closed.80x24.snap",
    },
  },
  {
    root = "/work/ui.nvim",
    rel = "TESTS/sheets/menu.sheet.lua",
    sheet = valid({
      id = "menu",
      title = "The menu",
      task = "ui.nvim/picker",
      engine = "manual",
      manual = { "right-click a file", "choose Rename" },
    }),
    snapshots = {},
  },
  {
    root = "/work/ui.nvim",
    rel = "TESTS/sheets/broken.sheet.lua",
    error = "boom",
    snapshots = {},
  },
}

return entries, { ticked = { ["the border is visible"] = true } }
