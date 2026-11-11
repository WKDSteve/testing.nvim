-- TESTS/testing/sheet_prompt_spec.lua -- prompts of the child editor (hit-enter, more, `confirm()`) in an rpc sheet.
-- While one is up the editor runs no call; a step `prompt = name` waits for it through `nvim_get_mode`, which it still
-- answers, `screen` reads it from what the attached UI was told, an `input` answers it, and any other step that runs
-- into it fails at once with its name and how to answer it, instead of the RPC timeout killing the child.
-- @cache-allow spawn
-- (it starts child editors)
---@diagnostic disable: missing-fields
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local session_mod = require("testing.sheet.session")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-prompt"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()

  ---Run a sheet step by step; every step's answer (with the screen after it) in order, and the result.
  local function stepped(t)
    local s = assert(sheet.validate(t))
    local session = session_mod.open(s, { root = root, ci = true, capture_screen = true })
    local answers = {}
    while session:peek() do
      local started = vim.uv.hrtime()
      local res = session:step()
      if not res then
        break
      end
      res.wall_ms = (vim.uv.hrtime() - started) / 1e6
      answers[#answers + 1] = res
    end
    session:close()
    return answers, session:result()
  end
  local size = { { rows = 12, cols = 50 } }

  -- 1. hit-enter: wait for it, see it, answer it, go on ---------------------------------------------------------------
  do
    local answers, res = stepped({
      id = "p.hit-enter",
      title = "hit-enter",
      sizes = size,
      steps = {
        { input = [[:echo "a\nb\nc"<CR>]] },
        { prompt = "hit-enter", note = "the prompt is up" },
        { input = "<CR>" },
        { wait = "vim.api.nvim_get_mode().mode == 'n'" },
        { expect = "vim.fn.mode() == 'n'" },
      },
    })
    eq(
      res.status,
      "pass",
      "a sheet that answers its prompt is green: " .. vim.inspect(res.failures)
    )
    local seen = table.concat(answers[2].screen or {}, "\n")
    has(seen, "Press ENTER", "the screen of the prompt step shows the prompt (read from the UI)")
    has(seen, "b", "... with the message")
  end

  -- 2. a step that runs into the prompt fails at once, with what to do, and the child lives -----------------------------
  do
    local answers, res = stepped({
      id = "p.stuck",
      title = "stuck",
      sizes = size,
      steps = {
        { input = [[:echo "a\nb\nc"<CR>]] },
        { settle = 200 },
        { wait = "vim.g.never == 1", timeout = 5000 },
      },
    })
    eq(res.status, "fail", "the step fails")
    local failed = answers[#answers]
    has(
      failed.reason,
      'the child shows a hit-enter prompt; answer it with { input = "<CR>" }',
      "it says which prompt and how to answer it"
    )
    ok(
      not tostring(failed.reason):find("died", 1, true),
      "no child died: " .. tostring(failed.reason)
    )
    ok(failed.wall_ms < 4000, ("it does not wait for a timeout (%d ms)"):format(failed.wall_ms))
    has(
      table.concat(failed.screen or {}, "\n"),
      "Press ENTER",
      "the screen after it shows the prompt"
    )
  end

  -- 3. confirm() and the more prompt ------------------------------------------------------------------------------------
  do
    local _, res = stepped({
      id = "p.confirm",
      title = "confirm",
      sizes = size,
      steps = {
        { input = [[:let g:answer = confirm("Save?", "&Yes\n&No")<CR>]] },
        { prompt = "confirm" },
        { input = "n" },
        { wait = "vim.g.answer == 2" },
        { lua = "vim.o.more = true" },
        { input = [[:for i in range(1, 60) | echo i | endfor<CR>]] },
        { prompt = "more" },
        { input = "q" },
        { wait = "vim.api.nvim_get_mode().mode == 'n'" },
      },
    })
    eq(res.status, "pass", "confirm and more are answered: " .. vim.inspect(res.failures))
  end

  -- 4. a prompt that does not come, and the wrong one -------------------------------------------------------------------
  do
    local answers, res = stepped({
      id = "p.none",
      title = "none",
      sizes = size,
      steps = { { prompt = "hit-enter", timeout = 150 } },
    })
    eq(res.status, "fail", "no prompt: the step fails")
    has(answers[1].reason, "no hit-enter prompt after 150 ms", "... and says so")
    local wrong = stepped({
      id = "p.wrong",
      title = "wrong",
      sizes = size,
      steps = {
        { input = [[:echo "a\nb\nc"<CR>]] },
        { prompt = "confirm", timeout = 300 },
      },
    })
    has(wrong[2].reason, "(the child shows a hit-enter prompt)", "another prompt is named")
  end

  -- 5. the screen from the UI is the screen of the child ----------------------------------------------------------------
  do
    local child = assert(require("testing.rpc").spawn({
      root = root,
      minit = root .. "/TESTS/minimal_init.lua",
      size = { rows = 10, cols = 40 },
      guard = false,
      watch_prompts = true,
    }))
    child.lua([[
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two wide 世界", "three" })
      vim.o.laststatus = 2
      vim.cmd("normal! G$")
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "float" })
      vim.api.nvim_open_win(buf, false, { relative = "editor", row = 2, col = 10, width = 8, height = 1, border = "single" })
      for i = 1, 30 do vim.api.nvim_buf_set_lines(0, -1, -1, false, { "line " .. i }) end
      vim.cmd("normal! G")
    ]])
    local real = child.screen()
    local same = vim.wait(2000, function()
      local ui = child.ui_screen(real.mode)
      return ui ~= nil
        and vim.deep_equal(ui.lines, real.lines)
        and vim.deep_equal(ui.attrs, real.attrs)
        and vim.deep_equal(ui.cursor, real.cursor)
    end, 20)
    local ui = child.ui_screen(real.mode) or {}
    ok(
      same,
      ("the UI's screen is the child's: %s\nvs\n%s"):format(
        table.concat(ui.lines or {}, "\n"),
        table.concat(real.lines, "\n")
      )
    )
    eq(ui.cursor, real.cursor, "... the cursor too")
    eq(child.prompt(), nil, "no prompt")
    -- the watch does not touch a call that is not held back
    eq(child.lua_get("1 + 1"), 2, "a call goes through")
    child.kill()
  end

  vim.fn.delete(root, "rf")
end
