-- TESTS/sheets/lint-editor.sheet.lua -- `:Testing lint --all` in a real (child) editor against a fixture project whose
-- pipeline has the luacheck preset and one file with an unused variable: the lint runs in a child, its verdict is
-- notified and the finding lands in the quickfix list. Where luacheck is not installed (the windows and macOS legs of
-- the hosted CI install it only on ubuntu) the verdict names the missing check instead: the run is the same.
return {
  id = "testing.lint-editor",
  feature = "testing.lint",
  title = ":Testing lint --all in the editor",
  task = "testing.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a fixture project with the luacheck preset and a file with an unused local; the editor sits in it",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-lint-sheet"
        vim.fn.mkdir(root .. "/lua/demo", "p")
        vim.fn.writefile({ "local unused = 1", "return { answer = 42 }" }, root .. "/lua/demo/init.lua")
        vim.fn.writefile({
          "return { ci = { default = 'quick', profiles = { quick = { 'luacheck' } }, steps = {",
          "  luacheck = { preset = 'luacheck', args = { 'lua' } },",
          "} } }",
        }, root .. "/.testing.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
        ---The verdict of the lint run: the message with `lint <STATE>` (after the notify prefix), nil before.
        function _G.verdict()
          for _, m in ipairs(_G.sheet_notes) do
            if m:find("lint %u%u+") or m:find("testing lint: no result", 1, true) then
              return m
            end
          end
        end
      ]==],
    },
    { lua = [[vim.cmd("Testing lint --all")]], note = ":Testing lint --all" },
    {
      wait = [[_G.verdict() ~= nil]],
      timeout = 120000,
      note = "the verdict of the lint run is notified",
    },
    {
      expect = [[(function()
        if vim.fn.executable("luacheck") == 0 then
          return _G.verdict():find("luacheck", 1, true) ~= nil
        end
        for _, item in ipairs(vim.fn.getqflist()) do
          if item.text:find("unused variable 'unused'", 1, true) then
            return _G.verdict():find("lint RED", 1, true) ~= nil
          end
        end
        return false
      end)()]],
      note = "red with the unused variable in the quickfix list (without luacheck: the verdict names it)",
    },
  },
}
