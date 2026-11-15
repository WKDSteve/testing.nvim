-- TESTS/sheets/tests-view-pipeline.sheet.lua -- the view `tests` in the real own tree of filetree.nvim while a
-- pipeline goes: the planned steps stand queued, one runs, ends green, the next turns red and says how many findings
-- wait, the suite counts its files; when the run has ended the findings stand below the red step; `r` on that step
-- asks for exactly that step again, and the second run turns it green.
--
-- The pipeline is played in: the events are the words `testing ci --events` writes (the recording of
-- `tree_ci_spec`), handed to the listener the view registered, and `ci.json` is written as a run writes it. No
-- process is started: `r` reaches a stand-in that records what it was asked to run (`Testing.Tree.Opts.ci_run`). What
-- a real run adds (the child process, its timing) is `testing.ci-editor-live` and a manual line below.
-- Acceptance of what stays for a person: testing.nvim/abnahme-tests-view-and-file-completion.
-- filetree.nvim and ui.nvim come from .deps/ (CI: ci.workflow.checkouts in .testing.lua) or beside this repository;
-- without them the sheet is a reported skip (n/a) on a developer's machine and red on CI.

-- A picture of the tree alone: the editor beside it and the command line are not what the sheet is about.
local TREE_ONLY = {
  { row = 1, col = 48, cols = 53, rows = 20 },
  { row = 21 },
  { row = 22 },
  { row = 23 },
  { row = 24 },
}

return {
  id = "testing.tests-view-pipeline",
  feature = "testing.tree",
  title = "The view tests of the own tree follows a pipeline: queued, running, red with findings, run again",
  task = "testing.nvim/abnahme-tests-view-and-file-completion",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  requires = {
    {
      lua = [[(function()
        for _, name in ipairs({ "ui.nvim", "filetree.nvim" }) do
          local found = require("testing.deps").resolve(name, vim.fn.getcwd())
          if not (found and found.dir) then
            return false
          end
          vim.opt.rtp:append(found.dir)
        end
        return true
      end)()]],
      reason = "filetree.nvim or ui.nvim is not beside this repository",
    },
  },
  steps = {
    {
      note = "a fixture project with a spec file and a source file; the editor sits in it, on its README",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-tree-sheet"
        vim.fn.mkdir(root .. "/TESTS", "p")
        vim.fn.mkdir(root .. "/lua", "p")
        vim.fn.writefile({ "local x = 1", "return {}" }, root .. "/lua/x.lua")
        vim.fn.writefile({ 'it("works", function() end)' }, root .. "/TESTS/demo_spec.lua")
        vim.fn.writefile({ "# demo" }, root .. "/README.md")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        vim.cmd.edit("README.md")
        vim.opt.shortmess:append("I")
        vim.o.laststatus = 0
        vim.o.ruler = false
        -- no Nerd Font in a snapshot: the tree draws no file icons
        vim.g.have_nerd_font = false
        -- the root as the editor names it when it starts a pipeline and tells the view (`:Testing ci`, `r` in the
        -- view): resolved, so on macOS /private/var/... and not the /var/... of tempname()
        _G.sheet_root = require("testing.bindings.usrcmds").resolve_root(nil, nil)

        ---The rows of the tree window as the screen shows them: the signs and the columns at the right are drawn
        ---by the tree, they are not text of its buffer.
        function _G.tree_lines()
          vim.cmd.redraw()
          local win = _G.tree.get_winid()
          local pos, out = vim.fn.win_screenpos(win), {}
          for r = pos[1], pos[1] + vim.api.nvim_win_get_height(win) do
            local cells = {}
            for c = pos[2], pos[2] + vim.api.nvim_win_get_width(win) - 1 do
              cells[#cells + 1] = vim.fn.screenstring(r, c)
            end
            out[#out + 1] = table.concat(cells)
          end
          return out
        end
        ---Whether the tree window has drawn the same for `ms` milliseconds: what a snapshot waits for (decorators of
        ---the tree answer debounced, a moment after the rows).
        function _G.steady(ms)
          -- the text and the highlight of every cell: a decorator may only colour a name
          local cells = { table.concat(_G.tree_lines(), "|") }
          local win = _G.tree.get_winid()
          local pos = vim.fn.win_screenpos(win)
          for r = pos[1], pos[1] + vim.api.nvim_win_get_height(win) do
            for c = pos[2], pos[2] + vim.api.nvim_win_get_width(win) - 1 do
              cells[#cells + 1] = vim.fn.screenattr(r, c)
            end
          end
          local shot, now = table.concat(cells, ","), vim.uv.now()
          if shot ~= _G.steady_shot then
            _G.steady_shot, _G.steady_since = shot, now
            return false
          end
          return now - _G.steady_since >= ms
        end
        ---The line of the tree that holds `text` (plain), or nil.
        function _G.line_of(text)
          for i, line in ipairs(_G.tree_lines()) do
            if line:find(text, 1, true) then
              return i, line
            end
          end
          return nil
        end
        ---Whether the line that holds `text` also holds `also` (plain): a step and its sign or its column.
        function _G.shows(text, also)
          local _, line = _G.line_of(text)
          return line ~= nil and line:find(also, 1, true) ~= nil
        end
        ---One event of a pipeline run, as the child of `:Testing ci` says it.
        function _G.feed(ev)
          require("testing.integrations.tree").on_ci_event(_G.sheet_root, ev)
        end
        ---Write `ci.json` of the project, as a run does before it says it is done.
        function _G.write_doc(steps, verdict)
          local path = require("testing.explorer.ci").path(_G.sheet_root)
          vim.fn.mkdir(vim.fs.dirname(path), "p")
          vim.fn.writefile({
            vim.json.encode({
              schema = "testing-ci/1",
              profile = "fast",
              verdict = verdict,
              time = "2026-11-15T10:00:00Z",
              steps = steps,
            }),
          }, path)
        end
      ]==],
    },
    {
      note = "filetree.nvim on its own tree; testing.nvim registers its view, the pipeline run a stand-in that records",
      lua = [==[
        require("filetree").setup({ adapter = "native", deps_popup = false, native = { width = 46 } })
        _G.tree = require("filetree").adapter()
        _G.asked = {}
        assert(require("testing.integrations.tree").register({
          ci_run = function(opts)
            _G.asked[#_G.asked + 1] = opts
          end,
        }))
      ]==],
    },
    { keys = ":Filetree source tests<CR>", note = "the tree, on the view tests" },
    {
      wait = [[_G.tree.is_open() and _G.line_of("demo_spec.lua") ~= nil]],
      timeout = 10000,
      note = "the spec file of the project is listed; no pipeline ran yet",
    },
    { expect = [[_G.line_of("Pipeline") == nil]] },
    {
      lua = [[_G.feed({ event = "run_start", profile = "fast", root = "proj", steps = { "stylua", "luacheck", "suite" } })]],
      note = "a pipeline starts",
    },
    {
      wait = [[_G.line_of("Pipeline fast") ~= nil and _G.shows("stylua", "◌") and _G.shows("suite", "◌")]],
      note = "it stands first, open, its three steps queued",
    },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "queued", masks = TREE_ONLY },
    { lua = [[_G.feed({ event = "step_start", step = "stylua", index = 1, total = 3 })]] },
    { wait = [[_G.shows("stylua", "●")]], note = "the first step runs" },
    {
      lua = [[_G.feed({ event = "step_end", step = "stylua", state = "green", ms = 700, exit = 0, findings_total = 0 })
      _G.feed({ event = "step_start", step = "luacheck", index = 2, total = 3 })]],
    },
    {
      wait = [[_G.shows("stylua", "✓") and _G.shows("stylua", "700ms") and _G.shows("luacheck", "●")]],
      note = "it ended green with its time; the second step runs",
    },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "running", masks = TREE_ONLY },
    {
      lua = [[_G.feed({ event = "step_end", step = "luacheck", state = "red", ms = 1500, exit = 1, findings_total = 2 })]],
    },
    {
      wait = [[_G.shows("luacheck", "✗") and _G.line_of("2 finding(s), listed when the run has") ~= nil]],
      note = "the step is red and open: it says how many findings wait for the end of the run",
    },
    {
      lua = [[_G.feed({ event = "step_start", step = "suite", index = 3, total = 3 })
      _G.feed({ event = "suite_progress", step = "suite", done = 1, total = 2 })]],
    },
    {
      wait = [[_G.shows("suite", "●") and _G.shows("suite", "1/2")]],
      note = "the suite counts its files",
    },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "red", masks = TREE_ONLY },
    {
      lua = [[_G.feed({ event = "step_end", step = "suite", state = "green", ms = 4000, exit = 0, findings_total = 0 })
      _G.write_doc({
        { name = "stylua", state = "green", ms = 700, findings = {}, findings_total = 0 },
        {
          name = "luacheck",
          state = "red",
          ms = 1500,
          findings = {
            { file = "lua/x.lua", line = 1, col = 7, text = "unused variable 'x'" },
            { file = "lua/x.lua", line = 2, text = "line is too long" },
          },
          findings_total = 2,
        },
        { name = "suite", state = "green", ms = 4000, findings = {}, findings_total = 0 },
      }, "red")
      _G.feed({ event = "run_done", exit = 1, first_red = "luacheck", verdict = "red" })]],
      note = "the suite ends, the run writes its document and says it is done",
    },
    {
      wait = [[_G.line_of("unused variable 'x'") ~= nil and _G.line_of("line is too long") ~= nil]],
      timeout = 5000,
      note = "the findings of the red step stand below it",
    },
    { expect = [[_G.shows("suite", "✓") and _G.shows("suite", "4.0s")]] },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "findings", masks = TREE_ONLY },
    {
      lua = [[vim.api.nvim_set_current_win(_G.tree.get_winid())
      vim.api.nvim_win_set_cursor(0, { vim.fn.search("luacheck", "nw"), 0 })]],
      note = "into the tree, on the red step",
    },
    { keys = "r", note = "run this step again" },
    { wait = [[#_G.asked == 1]], note = "a pipeline run was asked for" },
    {
      expect = [[_G.asked[1].profile == "fast" and vim.deep_equal(_G.asked[1].steps, { "luacheck" })]],
      note = "the profile of the run, and only the step under the cursor",
    },
    {
      lua = [[_G.feed({ event = "run_start", profile = "fast", root = "proj", steps = { "luacheck" } })
      _G.feed({ event = "step_start", step = "luacheck", index = 1, total = 1 })]],
      note = "the second run starts: one step",
    },
    {
      wait = [[_G.shows("luacheck", "●") and _G.line_of("unused variable 'x'") == nil and _G.line_of("stylua") == nil]],
      note = "it runs again: the findings of the run before are gone, the pipeline shows the steps of this run",
    },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "again", masks = TREE_ONLY },
    {
      lua = [[_G.feed({ event = "step_end", step = "luacheck", state = "green", ms = 900, exit = 0, findings_total = 0 })
      _G.write_doc({ { name = "luacheck", state = "green", ms = 900, findings = {}, findings_total = 0 } }, "green")
      _G.feed({ event = "run_done", exit = 0, verdict = "green" })]],
      note = "this time it is green; the run writes its document and ends",
    },
    {
      wait = [[_G.line_of("Pipeline fast") ~= nil and _G.shows("Pipeline fast", "✓")]],
      timeout = 5000,
      note = "the pipeline is green",
    },
    { wait = [[_G.steady(600)]], timeout = 8000, note = "the tree has drawn the same for a while" },
    { screen = "green", masks = TREE_ONLY },
  },
  judge = {
    "queued, running, red: the signs of the steps tell their state apart at a glance (◌ ● ✓ ✗), the colours fit",
    "findings: the two findings read as lines below the red step, the pipeline row counts one red of three",
    "again: only luacheck stands below the pipeline while the second run goes",
  },
  manual = {
    "In the real config, in a repository with a red step: :Testing ci with the view tests open, the steps move while the run goes, r on the red step runs it again",
    "<CR> on a finding jumps to its file and line",
  },
}
