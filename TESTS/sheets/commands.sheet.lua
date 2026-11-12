-- TESTS/sheets/commands.sheet.lua -- the `:Testing` points of the bindings runtime checklist of the nvim config
-- (`Final_Checks/BINDINGS-RUNTIME-CHECKLIST.md`, section `:Testing`) in a real (child) editor against a small fixture
-- project: every subcommand answers, the runs end with their verdict. `:Testing terminal` needs terminal.nvim and a
-- person to look at the terminal (manual below).
return {
  id = "testing.commands",
  feature = "testing.editor",
  title = ":Testing subcommands of the bindings checklist",
  task = "testing.nvim/testblatt-bindings-checkliste",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      note = "a fixture project with one green spec; the editor sits in it, every message is kept",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-commands-sheet"
        vim.fn.mkdir(root .. "/TESTS", "p")
        vim.fn.mkdir(root .. "/lua/demo", "p")
        vim.fn.writefile({ "return { answer = 42 }" }, root .. "/lua/demo/init.lua")
        vim.fn.writefile({
          "return function(H)",
          "  H.ok(require('demo').answer == 42, 'the answer')",
          "end",
        }, root .. "/TESTS/demo_spec.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_root = root
        _G.sheet_notes = {}
        vim.notify = function(msg)
          table.insert(_G.sheet_notes, tostring(msg))
        end
        ---Whether a message since the last `_G.mark()` contains `s` (plain).
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
        ---Whether the child of `:Testing <sub>` has ENDED since the last `_G.mark()`: its verdict (`testing <sub> done`,
        ---`testing <sub>: the report has findings ...`, `testing <sub> failed ...`). Not `testing <sub>: <root>`: that is
        ---said when the child starts, and a step that waited for it let the next command run beside it (surface,
        ---conformance and budget at once; `:checkhealth` and the conformance checks then missed their deadlines on the
        ---hosted runners).
        function _G.ended(sub)
          local head = "testing " .. sub
          return _G.said(head .. " done") or _G.said(head .. ": the report has findings") or _G.said(head .. " failed")
        end
        ---Whether a loaded buffer (the viewer of a report) contains `s` (plain).
        function _G.shown(s)
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
              if text:find(s, 1, true) then
                return true
              end
            end
          end
          return false
        end
      ]==],
    },
    { lua = [[_G.mark(); vim.cmd("Testing config")]], note = ":Testing config" },
    { expect = [[_G.said("notify_prefix")]], note = "the effective configuration is shown" },
    { lua = [[_G.mark(); vim.cmd("Testing cache stats")]], note = ":Testing cache stats" },
    { expect = [[_G.said("result cache of ")]], note = "size and age of the cache" },
    { lua = [[_G.mark(); vim.cmd("Testing list")]], note = ":Testing list" },
    {
      wait = [[_G.said("testing list done") and _G.shown("demo_spec.lua")]],
      timeout = 60000,
      note = "the spec file that would run is listed",
    },
    { lua = [[_G.mark(); vim.cmd("Testing run")]], note = ":Testing run" },
    { wait = [[_G.said("all green: 1 passed")]], timeout = 120000, note = "the run ends green" },
    { lua = [[_G.mark(); vim.cmd("Testing last")]], note = ":Testing last" },
    {
      wait = [[_G.said("all green: 1 passed")]],
      timeout = 120000,
      note = "the last run is repeated",
    },
    {
      lua = [[_G.mark(); vim.cmd.tabedit(vim.fn.fnameescape(_G.sheet_root .. "/TESTS/demo_spec.lua")); vim.cmd("Testing file")]],
      note = ":Testing file in the spec's buffer",
    },
    {
      wait = [[_G.said("all green: 1 passed")]],
      timeout = 120000,
      note = "the spec file of the buffer ran",
    },
    { lua = [[_G.mark(); vim.cmd("Testing doctor")]], note = ":Testing doctor" },
    {
      wait = [[_G.ended("doctor") and _G.shown("lib.nvim")]],
      timeout = 60000,
      note = "the dependency report names lib.nvim",
    },
    { lua = [[_G.mark(); vim.cmd("Testing surface")]], note = ":Testing surface" },
    {
      wait = [[_G.ended("surface")]],
      timeout = 120000,
      note = "the surface report answers (done, or findings that fail its gate)",
    },
    { lua = [[_G.mark(); vim.cmd("Testing conformance")]], note = ":Testing conformance" },
    {
      wait = [[_G.ended("conformance") and _G.shown("K1")]],
      timeout = 120000,
      note = "the conformance checks report by number",
    },
    { lua = [[_G.mark(); vim.cmd("Testing budget")]], note = ":Testing budget" },
    { wait = [[_G.ended("budget")]], timeout = 120000, note = "the budget run ends" },
    { lua = [[_G.mark(); vim.cmd("Testing health")]], note = ":Testing health" },
    {
      wait = [[vim.bo.filetype == "checkhealth"]],
      timeout = 30000,
      note = ":checkhealth testing opens",
    },
    {
      expect = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("testing", 1, true) ~= nil]],
      note = "the report has the section of testing.nvim",
    },
    {
      lua = [[vim.cmd("bwipeout!"); _G.mark(); vim.cmd("Testing")]],
      note = ":Testing without a subcommand",
    },
    {
      wait = [[_G.said("all green: 1 passed")]],
      timeout = 120000,
      note = "without a subcommand it runs the project",
    },
  },
  manual = {
    ":Testing terminal: the last run is repeated in a terminal.nvim terminal (colours, scrollback), with terminal.nvim installed",
  },
}
