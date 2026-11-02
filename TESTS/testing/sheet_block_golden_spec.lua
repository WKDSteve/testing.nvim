-- TESTS/testing/sheet_block_golden_spec.lua -- the block that `testing sheets report --tasks` writes into a task is a
-- contract: tasks-desktop parses its text (the sheet line, Judge:, By hand:, Look at:, the boxes) and ticks the boxes
-- back. The golden file is compared byte for byte, so one changed word in `render_block` turns this red; the SHA256
-- file next to it is what a copy in tasks-desktop is checked against.

---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local dir = vim.fs.dirname(here) .. "/golden/sheet-block"
  local function read(path)
    local f = assert(io.open(path, "rb"), path .. " is missing")
    local t = f:read("*a")
    f:close()
    return t
  end

  local entries, opts = dofile(dir .. "/entries.lua")
  local block = require("testing.sheet.tasks").render_block(entries, opts) .. "\n"
  local golden = read(dir .. "/sheet-block.golden.md")
  ok(
    block == golden,
    "render_block no longer gives the golden block (tasks-desktop reads that text); if the change is meant, run "
      .. "TESTS/golden/regenerate_sheet_block.lua and update the copy in tasks-desktop"
  )
  eq(
    vim.fn.sha256(golden) .. "  sheet-block.golden.md\n",
    read(dir .. "/SHA256"),
    "SHA256 belongs to the golden file"
  )

  -- the lines a reader looks for are there, as the reader spells them
  for _, needle in ipairs({
    "- **The picker opens and closes** (`picker`, `ui.nvim/TESTS/sheets/picker.sheet.lua`): ",
    "\n  - Judge:\n    - [x] the border is visible\n    - [ ] the title is centred\n",
    "\n  - By hand:\n    - [ ] open it with the real mouse\n",
    "\n  - Look at: `ui.nvim/TESTS/__snapshots__/sheets/picker.sheet/open.80x24.snap`, ",
    "\n<!-- testing:sheets:states picker=inbox menu=manual broken=red -->\n",
  }) do
    ok(golden:find(needle, 1, true) ~= nil, "the golden block holds " .. vim.inspect(needle))
  end
end
