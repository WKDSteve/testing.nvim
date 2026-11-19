-- TESTS/sheets/ci-commit.sheet.lua -- `:Testing ci commit` in a real (child) editor against a small fixture repository
-- with two commits: the completion offers the latest commits (git log), the check of HEAD runs in a child against its
-- parent and its verdict is notified.
return {
  id = "testing.ci-commit-editor",
  feature = "testing.ci-commit",
  title = ":Testing ci commit in the editor",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a fixture repository with a one-step pipeline and two commits; the editor sits in it",
      timeout = 30000,
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-commit-sheet"
        vim.fn.mkdir(root, "p")
        local nv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "+qa!" }
        local quoted = vim.tbl_map(function(a) return string.format("%q", a) end, nv)
        vim.fn.writefile({
          "return { ci = { default = 'quick', profiles = { quick = { 'ok' } }, steps = {",
          "  ok = { run = { " .. table.concat(quoted, ", ") .. " } },",
          "} } }",
        }, root .. "/.testing.lua")
        local function git(...)
          local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", "-C", root, ... }
          local res = vim.system(argv, { text = true }):wait(20000)
          assert(res.code == 0, table.concat(argv, " ") .. ": " .. tostring(res.stderr))
        end
        git("init", "-q", "-b", "main")
        git("add", ".testing.lua")
        git("commit", "-q", "-m", "first")
        vim.fn.writefile({ "two" }, root .. "/notes.txt")
        git("add", "notes.txt")
        git("commit", "-q", "-m", "second")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_root = root
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
        ---The verdict of the check: `ci commit: <sha> <verdict> ...` after the notify prefix (not `testing ci commit:`).
        function _G.verdict()
          for _, m in ipairs(_G.sheet_notes) do
            if m:find("ci commit: %x%x%x%x%x%x%x ") then
              return m
            end
          end
        end
      ]==],
    },
    {
      input = ":Testing ci commit <C-a>",
      note = "complete the commit argument like a person (all matches); input, keys would leave the command line",
    },
    {
      wait = [[vim.fn.getcmdline():find("HEAD [%x]+ [%x]+") ~= nil]],
      timeout = 10000,
      note = "the completion offers HEAD and the two commits of the repository",
    },
    { input = "<C-u><Esc>", note = "leave the command line" },
    { wait = [[vim.api.nvim_get_mode().mode == "n"]], note = "back in normal mode" },
    { lua = [[vim.cmd("Testing ci commit HEAD")]], note = ":Testing ci commit HEAD" },
    {
      wait = [[_G.said("testing ci commit: ")]],
      timeout = 10000,
      note = "the check starts in a child",
    },
    {
      wait = [[_G.verdict() ~= nil]],
      timeout = 180000,
      note = "the verdict of HEAD against its parent is notified",
    },
    {
      expect = [[_G.verdict():find(" clean", 1, true) ~= nil]],
      note = "a commit that only adds a text file breaks nothing: clean",
    },
  },
}
