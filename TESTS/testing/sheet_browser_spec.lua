-- TESTS/testing/sheet_browser_spec.lua -- the "browser" engine of test sheets (testing.sheet.browser): the shape
-- check per engine, the skip when a prerequisite is missing, the runner's answer with a fake runner and, where
-- node, playwright-core and chromium exist, one real page (Tab moves the focus, a failed expectation is red).
-- @cache-allow time processes
---@diagnostic disable: missing-fields

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
end
