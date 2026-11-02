-- TESTS/sheets/ci-editor-live.sheet.lua -- `:Testing ci` in a real (child) editor against a small fixture repository:
-- the live buffer and its progress while the pipeline runs, the verdict when it ended, the quickfix list of a red step.
-- The lualine component and the look of the split are for a person (judge / manual below).
return {
  id = "testing.ci-editor-live",
  title = ":Testing ci in the editor",
  task = "testing.nvim/ci-editor-live-test-von-testing-ci-ci-repos-im-echten-editor",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      note = "a fixture repository whose pipeline has a slow green step and a red one; the editor sits in it",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-ci-sheet"
        vim.fn.mkdir(root, "p")
        local nv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE" }
        local function step(extra)
          local argv = vim.list_extend(vim.deepcopy(nv), extra)
          return "{ " .. table.concat(vim.tbl_map(function(a) return string.format("%q", a) end, argv), ", ") .. " }"
        end
        local lines = {
          "return { ci = { default = 'full', profiles = { full = { 'slow', 'broken' } }, steps = {",
          "  slow = { run = " .. step({ "+lua vim.uv.sleep(2500)", "+qa!" }) .. " },",
          "  broken = { run = " .. step({ "+cq" }) .. " },",
          "} } }",
        }
        vim.fn.writefile(lines, root .. "/.testing.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_root = root
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
      ]==],
    },
    { lua = 'vim.cmd("Testing ci")', note = "start the pipeline" },
    {
      wait = [[vim.fn.bufnr("testing-ci") ~= -1 or #vim.tbl_filter(function(b) return vim.bo[b].filetype == "testing-ci" end, vim.api.nvim_list_bufs()) > 0]],
      timeout = 20000,
      note = "the live buffer opens",
    },
    {
      wait = [[(function() for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == "testing-ci" then return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("== slow", 1, true) ~= nil end end end)()]],
      timeout = 20000,
      note = "progress: the slow step shows up in the buffer while the run is going",
    },
    {
      screen = "live",
      masks = { { row = 11 }, { row = 12 }, { row = 23 } }, -- the step's command line (path of nvim) and the buffer name (temp dir)
      note = "the live view while the slow step runs",
    },
    {
      expect = [[#vim.fn.getqflist() == 0]],
      note = "no quickfix list before the verdict",
    },
    {
      wait = [[#vim.tbl_filter(function(m) return m:find("in the quickfix list", 1, true) ~= nil end, _G.sheet_notes) > 0]],
      timeout = 60000,
      note = "the verdict is notified",
    },
    {
      expect = [[(function() local q = vim.fn.getqflist() return #q >= 1 and q[1].text:find("[broken]", 1, true) ~= nil end)()]],
      note = "quickfix: an entry for the red step",
    },
    {
      expect = [[vim.fn.getqflist({ winid = 0 }).winid ~= 0]],
      note = "the list is opened on red",
    },
    {
      expect = [[(function() local t = table.concat(_G.sheet_notes, "\n") return t:find("broken", 1, true) ~= nil end)()]],
      note = "the verdict names the red step",
    },
  },
  judge = {
    "the live buffer opens in a sensible split and keeps the focus where you work",
    "the section headings and the progress line read well",
  },
  manual = {
    "`:Testing ci repos` with roots=$REPOS_DIR lists the repositories",
    "the lualine component (`require('testing.ci.editor').statusline()`) shows running / red / green",
  },
}
