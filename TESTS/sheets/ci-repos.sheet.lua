-- TESTS/sheets/ci-repos.sheet.lua -- `:Testing ci repos --repos-root=<dir>` in a real (child) editor over a folder with
-- two small fixture repositories: one child runs the pipeline of each, the verdict of the fleet is notified.
return {
  id = "testing.ci-repos-editor",
  feature = "testing.fleet",
  title = ":Testing ci repos over a folder of repositories",
  task = "testing.nvim/performance-pruefung-luecken-schliessen-katalog-feature-shee",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a folder with two fixture repositories, each with a one-step pipeline; the editor sits in the first",
      timeout = 30000,
      lua = [==[
        local fleet = vim.fs.normalize(vim.fn.tempname()) .. "-fleet-sheet"
        local nv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "+qa!" }
        local quoted = vim.tbl_map(function(a) return string.format("%q", a) end, nv)
        for _, name in ipairs({ "alpha", "beta" }) do
          local root = fleet .. "/" .. name
          vim.fn.mkdir(root, "p")
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
        end
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(fleet .. "/alpha"))
        _G.sheet_fleet = fleet
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
      ]==],
    },
    {
      lua = [[vim.cmd("Testing ci repos --repos-root=" .. vim.fn.fnameescape(_G.sheet_fleet))]],
      note = ":Testing ci repos --repos-root=<the folder>",
    },
    { wait = [[_G.said("testing ci repos: started")]], timeout = 10000, note = "one child starts" },
    {
      wait = [[_G.said("ci repos: all")]],
      timeout = 180000,
      note = "both pipelines are green: the verdict of the fleet",
    },
    {
      expect = [[#vim.fn.getqflist() == 0]],
      note = "nothing red, no quickfix list",
    },
  },
}
