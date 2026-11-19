-- TESTS/sheets/export-editor.sheet.lua -- `:Testing export <dir> --repos-root=<dir> --remote=never` in a real (child)
-- editor over a folder with a fixture repository: the export runs in a child (git state of each repository, no GitHub)
-- and its summary is notified; the folder testing-web reads is written. Which repositories are released is the
-- device's areas.json, so the summary may say 0 here: the sheet checks that the export ran and wrote its folder.
return {
  id = "testing.export-editor",
  feature = "testing.export",
  title = ":Testing export in the editor, without GitHub",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a folder with a fixture repository; the editor sits in it",
      timeout = 30000,
      lua = [==[
        local base = vim.fs.normalize(vim.fn.tempname()) .. "-export-sheet"
        local root = base .. "/repos/alpha"
        vim.fn.mkdir(root, "p")
        vim.fn.mkdir(base .. "/out", "p") -- the argument is a DIR: it must exist
        vim.fn.writefile({ "return {}" }, root .. "/.testing.lua")
        local function git(...)
          local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", "-C", root, ... }
          local res = vim.system(argv, { text = true }):wait(20000)
          assert(res.code == 0, table.concat(argv, " ") .. ": " .. tostring(res.stderr))
        end
        git("init", "-q", "-b", "main")
        git("add", ".testing.lua")
        git("commit", "-q", "-m", "first")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_base = base
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
        function _G.said(s)
          for _, m in ipairs(_G.sheet_notes) do
            if m:find(s, 1, true) then
              return true
            end
          end
          return false
        end
        function _G.said_re(pat)
          for _, m in ipairs(_G.sheet_notes) do
            if m:find(pat) then
              return true
            end
          end
          return false
        end
      ]==],
    },
    {
      lua = [[vim.cmd(("Testing export %s --repos-root=%s --remote=never"):format(
        vim.fn.fnameescape(_G.sheet_base .. "/out"), vim.fn.fnameescape(_G.sheet_base .. "/repos")))]],
      note = ":Testing export <dir> --repos-root=<the folder> --remote=never",
    },
    {
      wait = [[_G.said("testing export: started")]],
      timeout = 10000,
      note = "the export starts in a child",
    },
    {
      wait = [[_G.said_re("export: %d+ repositor")]],
      timeout = 120000,
      note = "its summary is notified (export: <n> repositories ...)",
    },
    {
      expect = [[vim.fn.isdirectory(_G.sheet_base .. "/out") == 1 and #vim.fn.readdir(_G.sheet_base .. "/out") > 0]],
      note = "the export folder is written",
    },
  },
}
