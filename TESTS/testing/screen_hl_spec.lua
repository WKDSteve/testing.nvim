-- TESTS/testing/screen_hl_spec.lua -- the highlight groups and colours of a screen: what the attached UI of a REAL
-- child editor is told about each attribute (`ext_hlstate`), joined to the letters of `child.screen()`; the `groups`
-- section of a snapshot, and the `hl` step of a sheet.
-- @cache-allow processes

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
      msg .. " (got " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end
  local screen = require("testing.screen")
  local sheet = require("testing.sheet")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  -- 1. the check, on a screen made by hand ----------------------------------------------------------------------------
  do
    local shot = {
      size = { rows = 2, cols = 6 },
      lines = { "ab cd ", "xy    " },
      attrs = { "aa bb ", "      " },
      cells = { { "a", "b", " ", "c", "d", " " }, { "x", "y", " ", " ", " ", " " } },
      cell_attrs = { "aa bb ", "      " },
      hl = {
        a = { groups = { "DiffText" }, fg = "#FF0000", bold = true },
        b = { groups = { "Comment", "CursorLine" }, fg = "#00ff00" },
        [" "] = { groups = {}, fg = "#ffffff" },
      },
    }
    eq(
      screen.hl_check(shot, { text = "ab", group = "DiffText" }),
      nil,
      "every cell of the text has the group"
    )
    eq(
      screen.hl_check(shot, { text = "ab", group = "Mine" }, "DiffText"),
      nil,
      "a group that links to it"
    )
    eq(
      screen.hl_check(shot, { text = "ab", fg = "#ff0000", bold = true }),
      nil,
      "colour in any case, a style"
    )
    eq(
      screen.hl_check(shot, { text = "cd", group = "CursorLine" }),
      nil,
      "one of the groups it is made of"
    )
    eq(
      screen.hl_check(shot, { row = 1, col = 4, cols = 2, fg = "#00ff00" }),
      nil,
      "a place by row and column"
    )
    eq(
      screen.hl_check(shot, { text = "xy", fg = "#ffffff" }),
      nil,
      "no highlight: the default colours"
    )
    has(
      screen.hl_check(shot, { text = "b c", group = "DiffText" }),
      'row 1, cell 3 (" ") has groups -, fg #ffffff; expected group DiffText',
      "the first cell that does not hold, what it has and what was expected"
    )
    has(
      screen.hl_check(shot, { text = "ab", group = "Mine", italic = true }, "Error"),
      "expected group Mine (= Error), italic",
      "the group a link ends in is named"
    )
    has(
      screen.hl_check(shot, { text = "zz", bold = true }),
      '"zz" is not on the screen',
      "text not found"
    )
    has(
      screen.hl_check(shot, { row = 9, col = 1, bold = true }),
      "row 9, column 1 is not on the screen",
      "off the screen"
    )
    has(
      screen.hl_check({ lines = shot.lines, attrs = shot.attrs }, { text = "ab", bold = true }),
      "does not say what its highlights are",
      "a screen without hl"
    )

    -- the groups of a snapshot: only with groups = true, only the letters left after masking
    eq(screen.normalize(shot).groups, nil, "no groups unless asked: an old snapshot stays as it is")
    local plain = screen.render(screen.normalize(shot))
    ok(not plain:find("--- groups", 1, true), "... and the file has no groups section")
    local n = screen.normalize(shot, { groups = true, masks = { { text = "ab" } } })
    eq(
      n.groups,
      { { letter = "a", groups = { "Comment", "CursorLine" } } },
      "a masked cell has no group"
    )
    has(
      screen.render(n),
      "--- attrs\n1|## aa\n2|\n--- groups\na Comment+CursorLine\n",
      "the groups section"
    )
    local okn, errn = pcall(
      screen.normalize,
      { lines = { "x" }, attrs = { "a" } },
      { groups = true }
    )
    ok(
      not okn and tostring(errn):find("groups needs", 1, true) ~= nil,
      "groups of a screen without hl"
    )
  end

  -- 2. the shape of the step ------------------------------------------------------------------------------------------
  do
    local function sheet_with(step, engine)
      return sheet.validate({ id = "h", title = "T", engine = engine, steps = { step } })
    end
    ok(sheet_with({ hl = { text = "x", group = "DiffText" } }), "text and a group")
    ok(
      sheet_with({ hl = { row = 2, col = 3, cols = 4, fg = "#a0B0c0", bold = false } }),
      "a place and colours"
    )
    ok(sheet_with({ screen = "s", groups = true }), "a screen step with groups")
    for _, c in ipairs({
      { { hl = { group = "X" } }, "text = s or row = n" },
      { { hl = { text = "x", row = 1, col = 1, group = "X" } }, "one of them" },
      { { hl = { text = "x" } }, "nothing to check" },
      { { hl = { text = "", bold = true } }, "text must not be empty" },
      { { hl = { row = 1, bold = true } }, "row needs col" },
      { { hl = { text = "x", col = 1, bold = true } }, "col and cols belong to row" },
      { { hl = { row = 0, col = 1, bold = true } }, "whole number from 1" },
      { { hl = { text = "x", fg = "red" } }, "colour #rrggbb" },
      { { hl = { text = "x", blink = true } }, "unknown field blink" },
      { { hl = { text = "x", bold = "yes" } }, "bold must be a boolean" },
      { { keys = "x", groups = true }, "groups belong to a screen step" },
    }) do
      local s, err = sheet_with(c[1])
      ok(s == nil, "refused: " .. vim.inspect(c[1]))
      has(err, c[2], "... says so")
    end
    local _, berr = sheet_with({ hl = { text = "x", bold = true } }, "browser")
    ok(berr ~= nil, "hl is a step of an rpc sheet only")
  end

  -- 3. a real child ----------------------------------------------------------------------------------------------------
  S.run(function()
    local c = S.spawn({ minit = S.minit, size = { rows = 8, cols = 40 } })
    c.lua([[
      vim.api.nvim_set_hl(0, "TestingMine", { fg = "#ff0000", bold = true })
      vim.api.nvim_set_hl(0, "TestingLinked", { link = "TestingMine" })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "plain mine linked" })
      local ns = vim.api.nvim_create_namespace("t")
      vim.api.nvim_buf_set_extmark(0, ns, 0, 6, { end_col = 10, hl_group = "TestingMine" })
      vim.api.nvim_buf_set_extmark(0, ns, 0, 11, { end_col = 17, hl_group = "TestingLinked" })
    ]])
    local shot = c.screen()
    ok(type(shot.hl) == "table", "the screen says what its attribute letters are")
    eq(shot.attr_ids, nil, "the ids of the child are not part of the shot")
    eq(
      screen.hl_check(shot, { text = "mine", group = "TestingMine", fg = "#ff0000", bold = true }),
      nil,
      "a group"
    )
    eq(
      screen.hl_check(shot, { text = "linked", group = "TestingMine" }),
      nil,
      "a linked group is drawn as the group it ends in"
    )
    has(
      screen.hl_check(shot, { text = "plain", group = "TestingMine" }),
      'row 1, cell 1 ("p") has groups -',
      "plain text has none"
    )
    local status = shot.hl[shot.attrs[#shot.attrs - 1]:sub(1, 1)]
      or shot.hl[shot.attrs[#shot.attrs]:sub(1, 1)]
    ok(status and #status.groups > 0, "a UI element has its group too: " .. vim.inspect(status))
    -- a restart numbers attributes anew: what the UI said before is not kept
    c.restart({ keep_sandbox = true })
    local again = c.screen()
    ok(type(again.hl) == "table", "after a restart the screen still says what its letters are")
    c.kill()
  end)

  -- 4. a sheet: hl steps and a screen with groups -----------------------------------------------------------------------
  do
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-hl"
    local function write(rel, text)
      local p = root .. "/" .. rel
      vim.fn.mkdir(vim.fs.dirname(p), "p")
      local f = assert(io.open(p, "wb"))
      f:write(text)
      f:close()
      return p
    end
    write("TESTS/minimal_init.lua", "vim.o.swapfile = false\n")
    local path = write(
      "TESTS/sheets/colours.sheet.lua",
      [=[return {
  id = "hl.colours",
  title = "Colours",
  sizes = { { rows = 6, cols = 30 } },
  steps = {
    { lua = [[
      vim.api.nvim_set_hl(0, "SheetConflict", { link = "DiffText" })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "ok conflict 12:34" })
      vim.api.nvim_buf_set_extmark(0, vim.api.nvim_create_namespace("s"), 0, 3, { end_col = 11, hl_group = "SheetConflict" })
    ]] },
    { hl = { text = "conflict", group = "SheetConflict" }, note = "conflict colour" },
    { hl = { text = "ok", group = "DiffText" }, note = "plain is not" },
    { hl = { text = "ok", group = "NoSuchGroup" } },
    { screen = "colours", groups = true, masks = { "%d%d:%d%d" } },
  },
}
]=]
    )
    local s = assert(sheet.load(path))
    local res = sheet.run(s, { root = root })
    eq(res.status, "fail", "a cell drawn otherwise fails the sheet")
    eq(#res.failures, 1, "the first failed step ends its size")
    has(
      res.failures[1],
      'step 3, plain is not (hl "ok" group=DiffText)',
      "the step that failed, and what it asked"
    )
    eq(
      sheet.value_text({ row = 2, col = 3, cols = 4, fg = "#aabbcc", bold = false }),
      "2,3+4 fg=#aabbcc not bold",
      "a place by row and column, in the line of a step"
    )
    has(res.failures[1], 'row 1, cell 1 ("o") has groups -', "... with what the cell has")
    -- without the failing steps: the group by its link, a missing group, the snapshot with groups
    table.remove(s.steps, 3)
    local missing = sheet.run(s, { root = root })
    has(
      missing.failures[1],
      "there is no highlight group NoSuchGroup",
      "a group that is not defined"
    )
    table.remove(s.steps, 3)
    local green = sheet.run(s, { root = root })
    eq(
      { green.status, green.failures },
      { "pass", {} },
      "the group of a link, and the snapshot written"
    )
    local snap = vim.fn.glob(root .. "/TESTS/__snapshots__/**/colours.30x6.snap", false, true)[1]
    ok(snap ~= nil, "the snapshot file")
    local text = table.concat(snap and vim.fn.readfile(snap) or {}, "\n")
    has(text, "--- groups", "it has the groups")
    has(text, "DiffText", "... with the group of the conflict")
    ok(not text:find("12:34", 1, true), "the masked clock")
    eq(sheet.run(s, { root = root, ci = true }).status, "pass", "and it matches on the next run")
    vim.fn.delete(root, "rf")
  end
end
