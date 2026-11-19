-- TESTS/sheets/ci-hook.sheet.lua -- `:Testing ci hook install`, `:Testing ci verify` and `:Testing ci hook remove` in a
-- real (child) editor against a small fixture repository: the hook lands in the repository's own hooks folder, the
-- proof check answers that no run is recorded yet, and the hook is gone again after `remove`.
return {
  id = "testing.ci-hook-editor",
  feature = "testing.pre-push",
  title = ":Testing ci hook install / verify / remove in the editor",
  task = "testing.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a fixture repository whose pipeline has the profile fast the hook runs; the editor sits in it",
      timeout = 30000,
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-hook-sheet"
        vim.fn.mkdir(root, "p")
        local nv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "+qa!" }
        local quoted = vim.tbl_map(function(a) return string.format("%q", a) end, nv)
        vim.fn.writefile({
          "return { ci = { default = 'fast', profiles = { fast = { 'ok' } }, steps = {",
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
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_root = root
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
        _G.since = 0
        function _G.mark()
          _G.since = #_G.sheet_notes
        end
        function _G.said(s)
          for i = _G.since + 1, #_G.sheet_notes do
            if _G.sheet_notes[i]:find(s, 1, true) then
              return true
            end
          end
          return false
        end
        function _G.hook()
          return vim.uv.fs_stat(root .. "/.git/hooks/pre-push") ~= nil
        end
      ]==],
    },
    { expect = [[not _G.hook()]], note = "no pre-push hook before" },
    { lua = [[_G.mark(); vim.cmd("Testing ci hook install")]], note = ":Testing ci hook install" },
    {
      wait = [[_G.said("pre-push hook installed")]],
      timeout = 60000,
      note = "the child answers: installed",
    },
    { expect = [[_G.hook()]], note = "the hook is in the repository's own hooks folder" },
    { lua = [[_G.mark(); vim.cmd("Testing ci verify")]], note = ":Testing ci verify" },
    {
      wait = [[_G.said("ci verify: no-stamp")]],
      timeout = 60000,
      note = "no run is recorded yet: no proof for a push",
    },
    { lua = [[_G.mark(); vim.cmd("Testing ci hook remove")]], note = ":Testing ci hook remove" },
    {
      wait = [[_G.said("pre-push hook removed")]],
      timeout = 60000,
      note = "the child answers: removed",
    },
    { expect = [[not _G.hook()]], note = "the hook is gone" },
  },
}
