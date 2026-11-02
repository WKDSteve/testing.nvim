-- Regenerates the golden block of the sheet block in a task (docs/SHEETS.md, "The block is a contract").
--
--   nvim -n -i NONE --headless -u NONE -l TESTS/golden/regenerate_sheet_block.lua
--
-- The golden file is the text tasks-desktop parses (the sheet line, `Judge:`, `By hand:`, `Look at:`, the boxes) byte
-- for byte: a change of it is a change of the contract. Run this on purpose, read `git diff TESTS/golden`, and update
-- the copy in tasks-desktop together with its checksum (TESTS/golden/sheet-block/SHA256).

local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local plugin_root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.rtp:prepend(plugin_root)

local deps = require("testing.deps")
local lib = deps.resolve("lib.nvim", plugin_root)
if not lib then
  io.stderr:write("regenerate_sheet_block: lib.nvim was not found\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

local entries, opts = dofile(here .. "/sheet-block/entries.lua")
local block = require("testing.sheet.tasks").render_block(entries, opts) .. "\n"
local dir = here .. "/sheet-block"
local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
write(dir .. "/sheet-block.golden.md", block)
write(dir .. "/SHA256", vim.fn.sha256(block) .. "  sheet-block.golden.md\n")
io.stdout:write(("wrote sheet-block.golden.md (%d bytes) and SHA256\n"):format(#block))
os.exit(0)
