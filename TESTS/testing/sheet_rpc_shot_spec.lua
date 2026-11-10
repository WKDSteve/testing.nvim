-- TESTS/testing/sheet_rpc_shot_spec.lua -- `shot = name` in an rpc sheet: the screen of the child drawn as a page
-- (`testing.screen.html`: every cell with its colours and styles, wide characters, the cursor, the text escaped, only
-- `#rrggbb` colours) and photographed by the browser engine; the picture lands as
-- `TESTS/sheets/out/<id>.<name>.<cols>x<rows>.png`. Without a browser the step is a reported skip: the steps after it
-- run, and the sheet ends as `skip` (never green without its picture), or `fail` when a later step fails. The browser
-- runner is a stand-in here (a fixed PNG); where node and playwright-core are installed the real one draws a picture too.
-- @cache-allow spawn
-- (it starts child editors and, where installed, node with the browser runner)
---@diagnostic disable: missing-fields, param-type-mismatch
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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local screen = require("testing.screen")
  local sheet = require("testing.sheet")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  -- ---------------------------------------------------------------- the page of a screen
  do
    local html, unknown = screen.html({
      size = { rows = 2, cols = 4 },
      cursor = { row = 2, col = 1 },
      cells = { { "a", "<", "世", "" }, { "x", " ", " ", "&" } },
      hl_cell_attrs = { "ab  ", "   c" },
      hl = {
        a = { groups = { "Bold" }, fg = "#ff0000", bg = "#000000", bold = true },
        b = {
          groups = { "Spell" },
          fg = "#00ff00",
          italic = true,
          undercurl = true,
          sp = "#0000ff",
        },
        c = { groups = { "Evil" }, fg = "red;}body{display:none", bg = "#123456" },
        [" "] = { groups = {}, fg = "#111111", bg = "#222222" },
      },
    })
    eq(unknown, 0, "every attribute of this screen is known")
    has(
      html,
      "{color:#ff0000;background:#000000;font-weight:bold}",
      "a cell has its colours and bold"
    )
    has(
      html,
      "font-style:italic;text-decoration-line:underline;text-decoration-style:wavy;text-decoration-color:#0000ff",
      "italic, undercurl, sp"
    )
    has(html, ">&lt;</span>", "the text is escaped")
    has(html, ">&amp;</span>", "... every character of it")
    ok(html:find(' w">世</span>', 1, true) ~= nil, "a wide character takes two cells: " .. html)
    ok(
      not html:find("display:none", 1, true),
      "a colour that is not #rrggbb never reaches the page"
    )
    has(html, "{color:#111111;background:#123456}", "... the default colour is taken instead")
    has(html, "{color:#222222;background:#111111}", "the cursor is a block (colours swapped)")
    has(html, '">x</span>', "... a box of its own")
    has(
      html,
      'style="width:2ch">  </span>',
      "neighbouring ASCII cells of one look are one box of their width"
    )
    has(
      html,
      "html,body{margin:0;padding:0;background:#222222}",
      "the page has the default background"
    )
    local boxes = 0
    for _ in html:gmatch('<span class="c') do
      boxes = boxes + 1
    end
    eq(boxes, 6, "a box per look and run, none for the second half of a wide character")
    local nocur = screen.html({
      size = { rows = 1, cols = 1 },
      cursor = { row = 1, col = 1 },
      cells = { { "x" } },
      hl_cell_attrs = { " " },
      hl = {},
    }, { cursor = false })
    has(nocur, "{color:#e0e2ea;background:#14161b}", "no cursor, Neovim's default colours")
  end

  -- a wavy underline and a strike together: both lines (one `text-decoration` value with both is dropped whole)
  do
    local html = screen.html({
      size = { rows = 1, cols = 2 },
      cells = { { "d", "e" } },
      hl_cell_attrs = { "aa" },
      hl = {
        a = { groups = { "Deprecated" }, undercurl = true, strikethrough = true, sp = "#ff0000" },
      },
    })
    has(html, "text-decoration-line:underline;text-decoration-style:wavy", "the wavy underline")
    has(html, "<s>de</s>", "the strike on an inner box")
    has(html, "s{text-decoration:line-through}", "drawn straight")
    ok(not html:find("wavy line-through", 1, true), "never one value with both")
  end

  -- an attribute the screen could not name (`?`: more attributes than letters): counted and outlined, not plain
  do
    local html, unknown = screen.html({
      size = { rows = 1, cols = 3 },
      cells = { { "a", "b", "c" } },
      hl_cell_attrs = { "?? " },
      hl = { [" "] = { groups = {}, fg = "#111111", bg = "#222222" } },
    })
    eq(unknown, 2, "two cells with an attribute without a name")
    has(html, "outline:1px dashed", "they are outlined in the picture")
  end

  -- ---------------------------------------------------------------- the step, with a stand-in browser runner
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-rpc-shot"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local PNG = "\137PNG\r\n\26\n" .. string.rep("\0", 16)
  local pages = {}
  ---A browser runner that photographs nothing: it keeps the page it was given and writes a fixed PNG where the real one
  ---would. `answer` = "skip" behaves like a machine without a browser.
  local function runner(answer)
    return function(argv)
      local plan = vim.json.decode(table.concat(vim.fn.readfile(argv[3], "b"), "\n"))
      if answer == "skip" then
        return { code = 77, stdout = "SKIP: chromium cannot be started\n", stderr = "" }
      end
      pages[#pages + 1] = table.concat(vim.fn.readfile(plan.steps[1].open, "b"), "\n")
      eq(plan.steps[2].element, "#screen", "the grid is photographed, not the viewport")
      local tag = ("%dx%d"):format(plan.sizes[1].cols, plan.sizes[1].rows)
      local file = ("%s/%s.%s.%s.png"):format(plan.out_dir, plan.id, plan.steps[2].shot, tag)
      vim.fn.mkdir(plan.out_dir, "p")
      local f = assert(io.open(file, "wb"))
      f:write(PNG)
      f:close()
      return {
        code = 0,
        stdout = vim.json.encode({ failures = {}, shots = { "screenshot " .. file } }) .. "\n",
        stderr = "",
      }
    end
  end
  local function the_sheet(after)
    local steps = {
      { lua = "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello shot' })" },
      { shot = "hello", note = "the picture" },
    }
    if after then
      steps[#steps + 1] = after
    end
    local s = assert(sheet.validate({
      id = "demo.shot",
      title = "a picture of the screen",
      minit = S.minit,
      sizes = { { rows = 10, cols = 40 } },
      steps = steps,
    }))
    s.path = root .. "/TESTS/sheets/shot.sheet.lua"
    return s
  end
  local function opts(answer)
    return {
      root = root,
      ci = false,
      update = false,
      browser = { node = "node", playwright_dir = root, run = runner(answer) },
    }
  end

  do
    local res = sheet.run(the_sheet(), opts())
    eq({ res.ok, res.status, res.failures }, { true, "pass", {} }, "a shot step passes")
    local want = root .. "/TESTS/sheets/out/demo.shot.hello.40x10.png"
    eq(
      res.snapshots,
      { "screenshot " .. want },
      "the picture is named by the sheet, the shot and the size in cells"
    )
    local fh = io.open(want, "rb")
    eq(fh and fh:read("*a"), PNG, "and holds what the browser made")
    if fh then
      fh:close()
    end
    local text = (pages[1] or ""):gsub("<[^>]+>", "")
    has(text, "hello shot", "the page shows what the child's screen shows")
  end

  -- without a browser: a skip of the step, the steps after it run, the sheet is no green run
  do
    local skipped =
      sheet.run(the_sheet({ expect = "true", note = "after the picture" }), opts("skip"))
    eq(
      { skipped.ok, skipped.status },
      { true, "skip" },
      "a shot without a browser: the sheet is a skip"
    )
    has(skipped.skipped, "step 2, the picture (shot hello)", "the skip names the step")
    has(skipped.skipped, "chromium cannot be started", "and why")
    local failed =
      sheet.run(the_sheet({ expect = "false", note = "after the picture" }), opts("skip"))
    eq(
      { failed.ok, failed.status },
      { false, "fail" },
      "a step after the skipped one still runs, and its failure counts"
    )
  end

  -- the page and the browser's folder are gone on every way out: after a picture, and after the browser engine raised
  do
    local shot = require("testing.sheet.shot")
    local seen = {}
    local real_browser = package.loaded["testing.sheet.browser"]
    local fake = {
      run = function(plan, bopts)
        seen[#seen + 1] = { page = plan.steps[1].open, work = bopts.out_dir }
        if #seen == 1 then
          vim.fn.mkdir(bopts.out_dir, "p")
          local file = bopts.out_dir .. "/x.png"
          local f = assert(io.open(file, "wb"))
          f:write(PNG)
          f:close()
          return { ok = true, status = "pass", failures = {}, snapshots = { "screenshot " .. file } }
        end
        error("the engine broke")
      end,
    }
    package.loaded["testing.sheet.browser"] = fake
    local small =
      { size = { rows = 1, cols = 1 }, cells = { { "x" } }, hl_cell_attrs = { " " }, hl = {} }
    local o = {
      sheet = { id = "demo.clean" },
      size = { rows = 1, cols = 1 },
      root = root,
      name = "c",
      out_dir = root .. "/clean-out",
    }
    local made = shot.take(small, o)
    local p2, failure = shot.take(small, o)
    package.loaded["testing.sheet.browser"] = real_browser
    ok(made ~= nil and vim.uv.fs_stat(made) ~= nil, "a picture: " .. tostring(made))
    eq(p2, nil, "a browser engine that raises: no picture")
    has(failure, "the engine broke", "... and the failure says why")
    for i, s in ipairs(seen) do
      eq(vim.uv.fs_stat(s.page), nil, ("the page is gone (%d)"):format(i))
      eq(vim.uv.fs_stat(s.work), nil, ("the browser's folder is gone (%d)"):format(i))
    end
  end

  -- the real browser, where it is installed: a picture with the size of the grid
  local browser = require("testing.sheet.browser")
  local pw = browser.playwright_dir(root)
    or browser.playwright_dir(vim.fs.normalize(vim.fn.getcwd()))
  local node = vim.fn.exepath("node")
  if not pw or node == "" then
    print(
      "sheet_rpc_shot_spec: node or playwright-core is not installed: the real picture is not taken"
    )
  else
    local res = sheet.run(the_sheet(), {
      root = root,
      ci = false,
      update = false,
      browser = { node = node, playwright_dir = pw },
    })
    if res.status == "skip" then
      print("sheet_rpc_shot_spec: the real browser cannot start here: " .. tostring(res.skipped))
      has(res.skipped, "shot", "a browser that cannot start is a reported skip of the step")
    else
      eq(
        { res.ok, res.status },
        { true, "pass" },
        "the real browser takes the picture: " .. vim.inspect(res.failures)
      )
      local png = root .. "/TESTS/sheets/out/demo.shot.hello.40x10.png"
      local f = io.open(png, "rb")
      local head = f and f:read(24) or ""
      if f then
        f:close()
      end
      eq(head:sub(1, 8), "\137PNG\r\n\26\n", "a PNG")
      local function u32(s, i)
        local a, b, c, d = s:byte(i, i + 3)
        return ((a or 0) * 16777216) + ((b or 0) * 65536) + ((c or 0) * 256) + (d or 0)
      end
      local w, h = u32(head, 17), u32(head, 21)
      ok(w >= 40 * 6 and w <= 40 * 20, "as wide as 40 cells: " .. w)
      ok(h >= 10 * 16 and h <= 10 * 24, "as high as 10 lines: " .. h)
      -- another screen is another picture: an empty or a constant picture would be the same twice
      local function bytes(path)
        local fh = io.open(path, "rb")
        local all = fh and fh:read("*a") or ""
        if fh then
          fh:close()
        end
        return all
      end
      local first = bytes(png)
      local other = the_sheet()
      other.steps[1].lua =
        "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a different text', 'and a line' })"
      sheet.run(
        other,
        { root = root, ci = false, update = false, browser = { node = node, playwright_dir = pw } }
      )
      local second = bytes(png)
      ok(
        #first > 0 and #second > 0 and first ~= second,
        "the picture shows the screen: other text, other bytes"
      )
    end
  end
  vim.fn.delete(root, "rf")
end
