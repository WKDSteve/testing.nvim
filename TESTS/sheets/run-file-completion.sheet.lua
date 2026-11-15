-- TESTS/sheets/run-file-completion.sheet.lua -- `:Testing run --file=<Tab>` typed in the command line of a real
-- (child) editor that sits in a small fixture project: the popup offers the spec files of the project, a typed
-- beginning narrows the offer, and what is taken is what `:Testing run` gets. The rule behind the offer has its spec
-- (`usrcmds_spec`, `testing.discover.known`); here it is the typing: the wildmenu, the popup and the command line.
-- Acceptance of what stays for a person: testing.nvim/abnahme-tests-view-and-file-completion.
return {
  id = "testing.run-file-completion",
  feature = "testing.run",
  title = ":Testing run --file=<Tab> offers the spec files of the project in the command line",
  task = "testing.nvim/abnahme-tests-view-and-file-completion",
  engine = "rpc",
  sizes = { { rows = 24, cols = 80 } },
  steps = {
    {
      note = "a fixture project with three spec files, one of them in a folder; the editor sits in it",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-completion-sheet"
        for _, rel in ipairs({ "TESTS/alpha_spec.lua", "TESTS/beta_spec.lua", "TESTS/unit/gamma_spec.lua" }) do
          vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
          vim.fn.writefile({ "return function(H)", "  H.ok(true, 'fine')", "end" }, root .. "/" .. rel)
        end
        -- no spec by its name: the completion must not offer it
        vim.fn.writefile({ "return {}" }, root .. "/TESTS/helper.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        vim.opt.shortmess:append("I")
        vim.o.laststatus = 0
        vim.o.ruler = false
      ]==],
    },
    { input = ":Testing run --file=<Tab>", note = "type the command up to the flag, then <Tab>" },
    { wait = [[vim.fn.mode() == "c" and vim.fn.wildmenumode() == 1]], note = "the offer is up" },
    {
      expect = [[vim.fn.getcmdline() == "Testing run --file=TESTS/alpha_spec.lua"]],
      note = "the first spec file is taken into the command line",
    },
    {
      expect = [[vim.deep_equal(vim.fn.getcompletion("Testing run --file=", "cmdline"), { "--file=TESTS/alpha_spec.lua", "--file=TESTS/beta_spec.lua", "--file=TESTS/unit/gamma_spec.lua" })]],
      note = "the offer is the three spec files, by path; helper.lua is not among them",
    },
    { screen = "offer", note = "the popup with the three files above the command line" },
    { input = "<Tab>", note = "<Tab> again steps to the next file" },
    { wait = [[vim.fn.getcmdline() == "Testing run --file=TESTS/beta_spec.lua"]] },
    {
      input = "<C-e><C-u>Testing run --file=TESTS/un<Tab>",
      note = "start over with a typed beginning",
    },
    {
      wait = [[vim.fn.getcmdline() == "Testing run --file=TESTS/unit/gamma_spec.lua"]],
      note = "one file is left: it is completed in place",
    },
    { input = "<Esc>", note = "leave the command line without running anything" },
    { wait = [[vim.fn.mode() == "n"]] },
  },
  judge = {
    "The popup lists the three spec files one per row, readable at 80 columns, the selected one stands out",
  },
  manual = {
    "In the real config (with its cmdline plugin, e.g. noice or cmp-cmdline): :Testing run --file=<Tab> offers the spec files of the project you are in",
    "In a project with its own roots or spec_pattern (filetree.nvim: TESTS/units.lua), after one run: the offer has the files the run discovered",
  },
}
