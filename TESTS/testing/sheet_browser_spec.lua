-- TESTS/testing/sheet_browser_spec.lua -- the "browser" engine of test sheets (testing.sheet.browser): the shape
-- check per engine, the skip when a prerequisite is missing, the runner's answer with a fake runner and, where
-- node, playwright-core and chromium exist, one real page (Tab moves the focus, a failed expectation is red).
-- @cache-allow time processes
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local sheet = require("testing.sheet")
  local browser = require("testing.sheet.browser")

  -- 1. the shape ----------------------------------------------------------------------------------------------------
  local s, err = sheet.validate({
    id = "page.tab",
    title = "Tab order",
    engine = "browser",
    steps = {
      { open = "page.html" },
      { press = "Tab" },
      { expect = "document.activeElement.id === 'a'" },
    },
  })
  ok(s ~= nil, "a browser sheet loads: " .. tostring(err))
  eq(s.sizes, { { rows = 700, cols = 1000 } }, "its default size is a viewport in pixels")

  local _, e1 =
    sheet.validate({ id = "x", title = "x", engine = "browser", steps = { { keys = "x" } } })
  ok(
    tostring(e1):find("keys is not a step of a browser sheet", 1, true) ~= nil,
    "an rpc step in a browser sheet is refused: " .. tostring(e1)
  )
  local _, e2 = sheet.validate({ id = "x", title = "x", steps = { { press = "Tab" } } })
  ok(
    tostring(e2):find("press is not a step of a rpc sheet", 1, true) ~= nil,
    "a browser step in an rpc sheet is refused: " .. tostring(e2)
  )
  local _, e3 = sheet.validate({ id = "x", title = "x", engine = "browser", steps = {} })
  ok(tostring(e3):find("browser sheet needs steps", 1, true) ~= nil, "a browser sheet needs steps")

  for _, bad in ipairs({
    { shot = "../../escape" },
    { shot = "a/b" },
    { shot = "" },
    { open = "" },
    { press = "" },
    { click = "" },
    { hover = "" },
    { focus = "" },
    { blur = false },
    { blur = "#k" },
    { scheme = "blue" },
    { scheme = "" },
  }) do
    local _, why = sheet.validate({ id = "x", title = "x", engine = "browser", steps = { bad } })
    ok(why ~= nil, "a step with an unusable value is refused at load: " .. vim.inspect(bad))
  end

  -- 2. skips and the runner's answer, with a fake runner -------------------------------------------------------------
  local pw_dir = browser.playwright_dir(
    vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.dirname(
          vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
        )
      )
    )
  )
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-browser-sheet"
  vim.fn.mkdir(root, "p")
  local function run(answer)
    return sheet.run(s, {
      root = root,
      node = "node",
      playwright_dir = root,
      run = function()
        return answer
      end,
    })
  end
  local skipped = run({ code = 77, stdout = "SKIP: chromium cannot be started\n", stderr = "" })
  ok(skipped.ok and skipped.status == "skip", "exit 77 is a reported skip, not a pass")
  eq(skipped.skipped, "chromium cannot be started", "... with the reason")
  local failed = run({
    code = 0,
    stdout = '{"failures":["1000x700 step 2, press Tab: boom"],"shots":[]}\n',
    stderr = "",
  })
  ok(not failed.ok and failed.status == "fail", "a failure of the runner's answer is red")
  eq(failed.failures, { "1000x700 step 2, press Tab: boom" }, "... with its line")
  local broken = run({ code = 1, stdout = "", stderr = "SyntaxError" })
  ok(
    not broken.ok and broken.failures[1]:find("SyntaxError", 1, true) ~= nil,
    "a runner that crashes is red, never green"
  )

  -- 3. a real page, where node, playwright-core and chromium exist --------------------------------------------------
  local f = assert(io.open(root .. "/page.html", "wb"))
  f:write(
    '<!doctype html><button id="a">A</button><button id="b">B</button><button id="c">C</button>'
  )
  f:close()
  local real = sheet.run(
    assert(sheet.validate({
      id = "page.tab",
      title = "Tab order",
      engine = "browser",
      steps = {
        { open = "page.html" },
        { press = "Tab" },
        { expect = "document.activeElement.id === 'a'", note = "first Tab: A" },
        { press = "Tab" },
        { press = "Tab" },
        { wait = "document.activeElement.id === 'c'" },
        { press = "Shift+Tab" },
        { expect = "document.activeElement.id === 'b'", note = "Shift+Tab goes back" },
        { click = "#a" },
        { expect = "document.activeElement.id === 'a'" },
        { shot = "focus" },
      },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  if real.status == "skip" then
    print("n/a  " .. tostring(real.skipped) .. ": the real page is skipped")
    return
  end
  ok(real.ok, "the real page: " .. table.concat(real.failures, "; "))
  ok(
    vim.uv.fs_stat(root .. "/TESTS/sheets/out/page.tab.focus.1000x700.png") ~= nil,
    "the screenshot is an artifact"
  )

  local red = sheet.run(
    assert(sheet.validate({
      id = "page.red",
      title = "Wrong focus",
      engine = "browser",
      steps = {
        { open = "page.html" },
        { press = "Tab" },
        { expect = "document.activeElement.id === 'c'", note = "wrong on purpose" },
      },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  ok(
    not red.ok and red.failures[1]:find("wrong on purpose", 1, true) ~= nil,
    "a wrong expectation is red and names its note"
  )

  -- 4. the looks of a control: under the pointer, with the focus, light and dark (the hand test "hover, focus, colours")
  local looks = assert(io.open(root .. "/looks.html", "wb"))
  looks:write(table.concat({
    "<!doctype html><style>",
    "#k { background: rgb(0, 0, 255); outline: none; }",
    "#k:hover { background: rgb(255, 0, 0); }",
    "#k:focus { outline: 3px solid rgb(0, 128, 0); }",
    "@media (prefers-color-scheme: dark) { body { background: rgb(0, 0, 0); } }",
    '</style><button id="k">K</button><p id="away">away</p>',
  }, "\n"))
  looks:close()
  local function bg(sel)
    return ("getComputedStyle(document.querySelector('%s')).backgroundColor"):format(sel)
  end
  local styled = sheet.run(
    assert(sheet.validate({
      id = "page.looks",
      title = "Hover, focus, scheme",
      engine = "browser",
      steps = {
        { open = "looks.html" },
        { scheme = "light" },
        { expect = bg("#k") .. " === 'rgb(0, 0, 255)'", note = "at rest" },
        { hover = "#k" },
        { expect = bg("#k") .. " === 'rgb(255, 0, 0)'", note = "under the pointer" },
        { shot = "hover" },
        { hover = "#away" },
        { expect = bg("#k") .. " === 'rgb(0, 0, 255)'", note = "the pointer moved away" },
        { focus = "#k" },
        { expect = "document.activeElement.id === 'k'", note = "focused" },
        {
          expect = "getComputedStyle(document.querySelector('#k')).outlineColor === 'rgb(0, 128, 0)'",
          note = "the focus ring shows",
        },
        { scheme = "dark" },
        { expect = bg("body") .. " === 'rgb(0, 0, 0)'", note = "dark scheme" },
        { scheme = "light" },
        { expect = bg("body") .. " !== 'rgb(0, 0, 0)'", note = "back to light" },
      },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  ok(styled.ok, "hover, focus and scheme on a real page: " .. table.concat(styled.failures, "; "))
  ok(
    vim.uv.fs_stat(root .. "/TESTS/sheets/out/page.looks.hover.1000x700.png") ~= nil,
    "the shot under the pointer is an artifact"
  )
  local unhovered = sheet.run(
    assert(sheet.validate({
      id = "page.nohover",
      title = "No hover",
      engine = "browser",
      steps = {
        { open = "looks.html" },
        { expect = bg("#k") .. " === 'rgb(255, 0, 0)'", note = "red only under the pointer" },
      },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  ok(not unhovered.ok, "without a hover step the control is not in its hover state")

  -- 5. blur: the focus leaves; red when a handler hands it on --------------------------------------------------------
  local handed = assert(io.open(root .. "/blur.html", "wb"))
  handed:write(table.concat({
    '<!doctype html><input id="a"><input id="b">',
    '<input id="c" onblur="document.getElementById(\'b\').focus()">',
  }, "\n"))
  handed:close()
  local blurred = sheet.run(
    assert(sheet.validate({
      id = "page.blur",
      title = "Blur",
      engine = "browser",
      steps = {
        { open = "blur.html" },
        { focus = "#a" },
        { expect = "document.activeElement.id === 'a'", note = "focused" },
        { blur = true },
        { expect = "document.activeElement === document.body", note = "the focus is gone" },
      },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  ok(blurred.ok, "blur takes the focus: " .. table.concat(blurred.failures, "; "))
  local passed_on = sheet.run(
    assert(sheet.validate({
      id = "page.blur-handler",
      title = "Blur handed on",
      engine = "browser",
      steps = { { open = "blur.html" }, { focus = "#c" }, { blur = true } },
    })),
    { root = root, playwright_dir = pw_dir }
  )
  ok(
    not passed_on.ok and (passed_on.failures[1] or ""):find("the focus is on", 1, true) ~= nil,
    "a blur whose handler hands the focus to another element is red: "
      .. table.concat(passed_on.failures, "; ")
  )

  -- 6. the size of a browser sheet is pixels: a tall page is fine, the size of a terminal grid stays small ------------
  local tall = {
    id = "t",
    title = "t",
    engine = "browser",
    steps = { { open = "x" } },
    sizes = { { cols = 1000, rows = 2400 } },
  }
  ok(sheet.validate(tall) ~= nil, "a browser sheet may be 2400 pixels tall")
  tall.sizes = { { cols = 1000, rows = 4001 } }
  ok(select(2, sheet.validate(tall)) ~= nil, "but not beyond 4000")
  local grid =
    { id = "g", title = "g", steps = { { keys = "x" } }, sizes = { { cols = 80, rows = 1001 } } }
  ok(select(2, sheet.validate(grid)) ~= nil, "an rpc sheet stays within 1000 cells")
end
