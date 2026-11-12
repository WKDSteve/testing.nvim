-- TESTS/testing/sheet_explain_spec.lua -- `E` in the panel of `:Testing sheet step`: an AI explanation of one step
-- through ai.nvim (a fake here). The request is built from what the run reported (the step, its result, the child's
-- screen, notes), shown in full before anything is sent, sent only on "Send" (rule PRIN-60), streamed into a buffer
-- beside the panel; without ai.nvim nothing happens beyond a warning.
-- @cache-allow time
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch, undefined-field

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    if type(haystack) == "table" then
      haystack = table.concat(haystack, "\n")
    end
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local explain = require("testing.sheet.explain")
  local panel = require("testing.sheet.panel")
  local SCHEMA = panel.SCHEMA

  local start = {
    schema = SCHEMA,
    event = "start",
    id = "explain.demo",
    title = "Explain demo",
    engine = "rpc",
    steps = {
      { n = 1, action = "lua", value = "vim.cmd('edit x.txt')", note = "open a file" },
      { n = 2, action = "keys", value = "ihello<Esc>" },
      { n = 3, action = "expect", value = "vim.fn.getline(1) == 'hello'", note = "it is there" },
    },
  }
  local after2 = {
    schema = SCHEMA,
    event = "step-after",
    size = "80x24",
    n = 2,
    status = "fail",
    ms = 12,
    reason = "E21: Cannot make changes",
    failure = "80x24 step 2 (keys ihello<Esc>): E21",
    screen = { "hello", "~", "~", "x.txt [RO]                1,1   All", "" },
  }

  -- 1. the request: pure ---------------------------------------------------------------------------------------------
  eq(
    vim.tbl_map(function(k)
      return k.id
    end, explain.kinds(nil)),
    { "what", "watch" },
    "a step that has not run: no result to put in context"
  )
  eq(#explain.kinds(after2), 3, "a step that ran: all three questions")

  local ctx = { doc = start, size = "80x24", n = 2, mark = after2, notes = { "looks read-only" } }
  local what = assert(explain.request(ctx, "what"))
  has(what.system, "testing.nvim", "the system prompt says what a sheet is")
  has(what.prompt, "Sheet explain.demo: Explain demo (engine rpc)", "the sheet")
  has(what.prompt, "> 2. keys ihello<Esc>", "the step in question is marked")
  has(
    what.prompt,
    "  1. lua vim.cmd('edit x.txt')  -- open a file",
    "the steps around it, with their notes"
  )
  has(what.prompt, "It ran: fail in 12 ms.", "its result")
  has(what.prompt, "Reason: E21: Cannot make changes", "the reason")
  has(what.prompt, "Failure: 80x24 step 2", "the failure line")
  has(what.prompt, "x.txt [RO]", "the child's screen as text")
  has(what.prompt, "Note of the person: looks read-only", "the notes")
  has(what.prompt, "Question: What does this step do?", "the question")
  ok(not what.prompt:find("~\n```", 1, true), "trailing empty rows of the screen are dropped")
  local watch = assert(explain.request(ctx, "watch"))
  has(watch.prompt, "Question: What should I watch out for", "the second question")
  local result = assert(explain.request(ctx, "result"))
  has(result.prompt, "Question: What does the result of this step mean?", "the third question")
  ok(what.prompt ~= watch.prompt and watch.prompt ~= result.prompt, "three distinct prompts")

  local not_run, why = explain.request({ doc = start, size = "80x24", n = 3 }, "result")
  eq(not_run, nil, "no result for a step that did not run")
  has(why, "has not run yet", "... and why")
  has(
    assert(explain.request({ doc = start, n = 3 }, "what")).prompt,
    "It has not run yet.",
    "said so"
  )
  eq(explain.request(ctx, "nope"), nil, "an unknown question")
  eq(explain.request({ doc = start, n = 9 }, "what"), nil, "a step the sheet does not have")

  local long = vim.deepcopy(after2)
  long.screen = {}
  for i = 1, 200 do
    long.screen[i] = ("row %d "):format(i) .. ("x"):rep(500)
  end
  local capped = assert(explain.request({ doc = start, n = 2, mark = long }, "what")).prompt
  ok(not capped:find("row 61 ", 1, true), "at most MAX_ROWS rows of the screen")
  ok(#capped < 60 * 320 + 4000, "a row is cut, the request stays small: " .. #capped)

  -- 2. the panel, on events as a real run sends them -------------------------------------------------------------------
  local function new_panel()
    local p = {
      root = "x",
      target = "explain.demo",
      opts = {},
      buf = vim.api.nvim_create_buf(false, true),
      marks = {},
      notes = {},
      running = false,
      breaks = {},
      stderr = {},
    }
    panel.on_event(p, start)
    panel.on_event(p, { schema = SCHEMA, event = "size", size = "80x24", state = "open" })
    panel.on_event(p, after2)
    panel.on_event(
      p,
      { schema = SCHEMA, event = "paused", size = "80x24", n = 2, reason = "failed" }
    )
    return p
  end
  local function answer_lines(p)
    return p.explain_buf and vim.api.nvim_buf_get_lines(p.explain_buf, 0, -1, false) or {}
  end

  ---A fake ai.nvim: records each request, hands the handlers out.
  local function fake_ai()
    local f = { calls = {}, killed = 0 }
    f.mod = {
      config = function()
        return { provider = "fakeprov" }
      end,
      stream = function(req, handlers)
        f.calls[#f.calls + 1] = { req = req, handlers = handlers }
        return {
          kill = function()
            f.killed = f.killed + 1
          end,
        }
      end,
    }
    f.require = function(name)
      assert(name == "ai")
      return f.mod
    end
    return f
  end
  ---Answers the choices in turn: a kind id or a label of the second choice, nil for dismissed.
  local function chooser(answers)
    local asked = {}
    return function(items, opts, on_choice)
      asked[#asked + 1] = opts.prompt
      local want = table.remove(answers, 1)
      for _, item in ipairs(items) do
        if item == want or (type(item) == "table" and item.id == want) then
          return on_choice(item)
        end
      end
      return on_choice(nil)
    end,
      asked
  end

  -- without ai.nvim: no question, nothing sent, the panel unchanged
  do
    local p = new_panel()
    local select, asked = chooser({ "what" })
    local before = vim.deepcopy(p.marks)
    eq(
      panel.explain(p, 2, {
        require = function()
          error("module 'ai' not found")
        end,
        select = select,
      }),
      false,
      "no ai.nvim: no explanation"
    )
    eq(#asked, 0, "... and no question asked")
    eq(p.explain_buf, nil, "... and no buffer")
    eq(p.marks, before, "... and the panel as it was")
  end

  -- cancelled after the preview: nothing goes out
  do
    local p = new_panel()
    local ai = fake_ai()
    local select, asked = chooser({ "result", "Cancel" })
    ok(panel.explain(p, 2, { require = ai.require, select = select }), "asked")
    eq(#asked, 2, "first the question, then whether to send")
    has(asked[2], "ai.nvim, provider fakeprov", "the confirmation names where it goes")
    local shown = answer_lines(p)
    has(shown, "Goes to ai.nvim, provider fakeprov:", "the preview says where it goes")
    has(shown, "> 2. keys ihello<Esc>", "... and shows what is sent")
    has(shown, "Question: What does the result of this step mean?", "... the whole request")
    has(shown, "(not sent)", "a cancel says so")
    eq(#ai.calls, 0, "a cancel sends nothing")
  end

  -- sent: the answer streams in beside the panel, the run is not touched
  do
    local p = new_panel()
    local ai = fake_ai()
    local select = chooser({ "watch", "Send", "what", "Send" })
    ok(panel.explain(p, 2, { require = ai.require, select = select }), "asked")
    eq(#ai.calls, 1, "one request after Send")
    local req = ai.calls[1].req
    eq(req.system, explain.SYSTEM, "the system prompt")
    has(req.prompt, "Question: What should I watch out for", "the chosen question")
    eq(p.paused, "failed", "the run stays where it stood")
    local h = ai.calls[1].handlers
    h.on_chunk("Read-only ")
    h.on_chunk("buffer.\nUse :set ma")
    vim.wait(1000, function()
      return table.concat(answer_lines(p), "\n"):find("Use :set ma", 1, true) ~= nil
    end, 10)
    local got = answer_lines(p)
    has(
      got,
      "## Answer\nRead-only buffer.\nUse :set ma",
      "the chunks, as they come, under the request"
    )
    h.on_done({ text = "Read-only buffer.\nUse :set ma" })
    vim.wait(1000, function()
      return table.concat(answer_lines(p), "\n"):find("(done)", 1, true) ~= nil
    end, 10)
    local done = answer_lines(p)
    has(done, "(done)", "the end of the answer")
    eq(#vim.tbl_filter(function(l)
      return l == "Use :set ma"
    end, done), 1, "the answer once, not once per chunk")

    -- a second question ends the first; a late chunk of the first is dropped
    ok(panel.explain(p, 1, { require = ai.require, select = select }), "asked again")
    eq(#ai.calls, 2, "a second request")
    h.on_chunk("LATE")
    ai.calls[2].handlers.on_error({ kind = "missing_api_key", message = "no key for fakeprov" })
    vim.wait(1000, function()
      return table.concat(answer_lines(p), "\n"):find("no key", 1, true) ~= nil
    end, 10)
    local second = answer_lines(p)
    has(second, "(no answer: no key for fakeprov)", "an error is said, not thrown")
    ok(
      not table.concat(second, "\n"):find("LATE", 1, true),
      "an answer to an earlier question is dropped"
    )
    has(second, "Question: What does this step do?", "the new preview replaced the old one")
  end

  -- the buffer of the answer wiped while the answer streams: the rest is dropped, no new buffer
  do
    local p = new_panel()
    local ai = fake_ai()
    panel.explain(p, 2, { require = ai.require, select = chooser({ "what", "Send" }) })
    local wiped = p.explain_buf
    vim.api.nvim_buf_delete(wiped, { force = true })
    local h = ai.calls[1].handlers
    h.on_chunk("after the wipe")
    h.on_done({ text = "after the wipe" })
    vim.wait(200, function()
      return false
    end, 10)
    eq(p.explain_buf, wiped, "no new buffer for the rest of the answer")
    ok(not vim.api.nvim_buf_is_valid(wiped), "the wiped one stays gone")
  end

  -- a step that has not run: the result is not offered
  do
    local p = new_panel()
    local ai = fake_ai()
    local offered
    panel.explain(p, 3, {
      require = ai.require,
      select = function(items, _, on_choice)
        offered = offered or vim.tbl_map(function(k)
          return k.id
        end, items)
        on_choice(nil)
      end,
    })
    eq(offered, { "what", "watch" }, "no result question for a step that did not run")
    eq(#ai.calls, 0, "dismissed: nothing sent")
  end

  -- the key is there, a quiet one: the header of the panel does not advertise it (rule PRIN-60)
  do
    local p = new_panel()
    local lines = panel.render(p)
    local keys = lines[3]
    has(keys, "n next", "the key line")
    ok(
      not keys:find("E ", 1, true) and not keys:lower():find("explain", 1, true),
      "no AI hint in the key line: " .. keys
    )
  end
end
