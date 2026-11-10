-- TESTS/sheets/sheet-panel-live.sheet.lua -- `:Testing sheet step` in a real (child) editor with a UI: the command, the
-- window beside the code, the real keys, the child's screen in the tile, q leaves nothing. A sheet that runs a sheet.
return {
  id = "testing.sheet-panel-live",
  title = ":Testing sheet step in the editor",
  task = "testing.nvim/scheibe-3-neovim-panel-fuer-sheets-step",
  engine = "rpc",
  sizes = { { rows = 30, cols = 140 } },
  steps = {
    {
      note = "a fixture project with a small sheet; the editor sits in it",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-panel-sheet"
        vim.fn.mkdir(root .. "/TESTS/sheets", "p")
        vim.fn.writefile({ "vim.o.swapfile = false" }, root .. "/TESTS/minimal_init.lua")
        vim.fn.writefile({
          'return { id = "fixture.walk", title = "A fixture walk", steps = {',
          "  { lua = \"vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello tile' })\", note = 'write' },",
          "  { expect = \"vim.fn.getline(1) == 'hello tile'\", note = 'it is there' },",
          "} }",
        }, root .. "/TESTS/sheets/walk.sheet.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
        _G.panel_text = function()
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].filetype == "testing-sheet" then
              return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
            end
          end
          return ""
        end
      ]==],
    },
    { lua = 'vim.cmd("Testing sheet step walk")', note = "the command" },
    {
      wait = [[_G.panel_text():find("paused before step 1", 1, true) ~= nil]],
      timeout = 30000,
      note = "it stops before the first step and says so",
    },
    {
      expect = [[vim.bo.filetype == "testing-sheet" and vim.fn.winnr("$") == 2 and vim.api.nvim_win_get_width(0) == 90]],
      note = "a window of its own beside the code, with the focus",
    },
    {
      expect = [[_G.panel_text():find("write", 1, true) ~= nil and _G.panel_text():find("it is there", 1, true) ~= nil]],
      note = "every step is listed with its note",
    },
    { keys = "n", note = "the key: one step" },
    {
      wait = [[_G.panel_text():find("paused before step 2", 1, true) ~= nil]],
      timeout = 30000,
      note = "one step, not two",
    },
    {
      expect = [[_G.panel_text():find("hello tile", 1, true) ~= nil]],
      note = "the child's screen as text in the tile",
    },
    -- the README picture (assets/screenshots/sheet-panel.png is this file, copied): a skip where no browser is installed
    { shot = "panel", note = "a picture of the panel beside the code" },
    { keys = "c", note = "the key: to the end" },
    {
      wait = [[_G.panel_text():find("finished: pass", 1, true) ~= nil]],
      timeout = 30000,
      note = "the end",
    },
    {
      expect = [[table.concat(_G.sheet_notes, "\n"):find("fixture.walk: pass", 1, true) ~= nil]],
      note = "the verdict is notified",
    },
    { keys = "q", note = "the key: close" },
    {
      expect = [[_G.panel_text() == "" and vim.fn.winnr("$") == 1]],
      note = "the panel is gone, the window of the code stays",
    },
  },
  judge = {
    "the list of steps and the tile read well beside the code",
    "n, c, u, b, a and q are easy to find in the third line",
  },
  manual = {
    "in pult: `:Testing sheet step remote-control` opens a visible Chrome next to the editor, and the page follows the keys",
  },
}
