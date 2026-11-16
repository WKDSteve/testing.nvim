-- TESTS/sheets/sheet-explain-live.sheet.lua -- `E` in the panel of `:Testing sheet step` in a real (child) editor, with a
-- stand-in for ai.nvim: on a red rpc step every question shows its target and the whole request first; Cancel sends
-- nothing, Send streams the stand-in's answer into the buffer beside the panel, and the run stays where it stood.
-- Whether the answer of a real provider helps stays a hand check
-- (testing.nvim/handtest-erklaer-knopf-im-sheet-panel-mit-echtem-provider).
return {
  id = "testing.sheet-explain-live",
  feature = "testing.sheet-step",
  title = "E in the panel of :Testing sheet step, with a stand-in provider",
  task = "testing.nvim/sheet-erklaer-knopf-mit-stand-in-provider",
  engine = "rpc",
  sizes = { { rows = 30, cols = 140 } },
  steps = {
    {
      note = "a fixture project with a sheet that is red at step 2, a stand-in ai.nvim, a scripted vim.ui.select",
      lua = [==[
        local root = vim.fs.normalize(vim.fn.tempname()) .. "-explain-sheet"
        vim.fn.mkdir(root .. "/TESTS/sheets", "p")
        vim.fn.writefile({ "vim.o.swapfile = false" }, root .. "/TESTS/minimal_init.lua")
        vim.fn.writefile({
          'return { id = "fixture.red", title = "Red in the middle", steps = {',
          "  { lua = 'vim.g.one = 1', note = 'first' },",
          "  { expect = 'vim.g.never == 1', note = 'the red one' },",
          "  { lua = 'vim.g.three = 1', note = 'third' },",
          "} }",
        }, root .. "/TESTS/sheets/red.sheet.lua")
        vim.env.TESTING_TRUST = "1"
        vim.cmd.cd(vim.fn.fnameescape(root))
        _G.sheet_notes = {}
        vim.notify = function(msg) table.insert(_G.sheet_notes, tostring(msg)) end
        -- the stand-in: records each request and streams a fixed answer in three chunks
        _G.ai_calls = {}
        package.loaded.ai = nil
        package.preload.ai = function()
          return {
            config = function() return { provider = "stand-in" } end,
            stream = function(req, cb)
              _G.ai_calls[#_G.ai_calls + 1] = req
              local chunks = { "The step ", "expects vim.g.never, ", "which nobody set." }
              for i, c in ipairs(chunks) do
                vim.defer_fn(function() cb.on_chunk(c) end, 30 * i)
              end
              vim.defer_fn(function() cb.on_done({}) end, 30 * (#chunks + 1))
              return { kill = function() end }
            end,
          }
        end
        -- vim.ui.select answers from `_G.answers` (a label each), and keeps every prompt it was asked
        _G.answers, _G.asked = {}, {}
        vim.ui.select = function(items, opts, on_choice)
          _G.asked[#_G.asked + 1] = opts.prompt
          local want = table.remove(_G.answers, 1)
          for _, it in ipairs(items) do
            local label = opts.format_item and opts.format_item(it) or it
            if label == want then
              return on_choice(it)
            end
          end
          on_choice(nil)
        end
        local function text_of(ft)
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) and (vim.bo[b].filetype == ft or vim.api.nvim_buf_get_name(b):find(ft, 1, true)) then
              return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"), b
            end
          end
          return ""
        end
        _G.panel_text = function() return (text_of("testing-sheet")) end
        _G.explain_text = function() return (text_of("testing://sheet-explain/")) end
        ---Put the cursor of the panel on the step whose note is `note` and press E with these answers.
        function _G.explain(note, answers)
          local _, buf = text_of("testing-sheet")
          for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if line:find(note, 1, true) then
              vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
              vim.api.nvim_win_set_cursor(0, { i, 0 })
              break
            end
          end
          _G.answers = answers
          vim.api.nvim_feedkeys("E", "mx", false)
        end
      ]==],
    },
    { lua = 'vim.cmd("Testing sheet step red")', note = "the command" },
    {
      wait = [[_G.panel_text():find("paused before step 1", 1, true) ~= nil]],
      timeout = 30000,
      note = "it stops before the first step",
    },
    { keys = "n", note = "step 1" },
    {
      wait = [[_G.panel_text():find("paused before step 2", 1, true) ~= nil]],
      timeout = 30000,
      note = "step 1 is green",
    },
    { keys = "n", note = "step 2, the red one" },
    {
      wait = [[_G.panel_text():find("vim.g.never", 1, true) ~= nil and not _G.panel_text():find("paused before step 2", 1, true)]],
      timeout = 30000,
      note = "step 2 ran and is red",
    },
    { lua = [[_G.before = _G.panel_text()]], note = "where the run stands now" },
    {
      lua = [[_G.explain("the red one", { "What does the result of this step mean?", "Cancel" })]],
      note = "E on the red step, the result question, Cancel",
    },
    {
      wait = [[_G.explain_text():find("(not sent)", 1, true) ~= nil]],
      timeout = 5000,
      note = "the preview stays, marked as not sent",
    },
    {
      expect = [[_G.explain_text():find("Goes to ai.nvim, provider stand-in:", 1, true) ~= nil
        and _G.explain_text():find("Question: What does the result of this step mean?", 1, true) ~= nil
        and _G.explain_text():find("vim.g.never", 1, true) ~= nil]],
      note = "the preview names the target and shows the whole request (the step and the question)",
    },
    { expect = [[#_G.ai_calls == 0]], note = "Cancel sent nothing: the provider was not called" },
    {
      expect = [[vim.deep_equal(_G.asked, { "Explain step 2 with AI:", "Send this to ai.nvim, provider stand-in?" })]],
      note = "it asked which question, then whether to send",
    },
    {
      lua = [[_G.explain("the red one", { "What does this step do?", "Send" })]],
      note = "E again, the first question, Send",
    },
    {
      wait = [[_G.explain_text():find("(done)", 1, true) ~= nil]],
      timeout = 5000,
      note = "the answer streams in and ends",
    },
    {
      expect = [[_G.explain_text():find("The step expects vim.g.never, which nobody set.", 1, true) ~= nil
        and #_G.ai_calls == 1 and _G.ai_calls[1].prompt:find("Question: What does this step do?", 1, true) ~= nil]],
      note = "the chunks are one answer; one request went out, with the question asked",
    },
    {
      lua = [[_G.explain("the red one", { "What should I watch out for in this step?", "Send" })]],
      note = "E again, the second question, Send",
    },
    {
      wait = [[_G.explain_text():find("(done)", 1, true) ~= nil and #_G.ai_calls == 2]],
      timeout = 5000,
      note = "the third question is answered too",
    },
    {
      expect = [[_G.ai_calls[2].prompt:find("Question: What should I watch out for in this step?", 1, true) ~= nil]],
      note = "with its own question",
    },
    {
      expect = [[_G.panel_text() == _G.before]],
      note = "the run stayed where it stood: explaining does not step it",
    },
  },
  judge = {
    "the preview reads well: where it goes, then the request, before anything is sent",
  },
}
