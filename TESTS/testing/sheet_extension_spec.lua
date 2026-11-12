-- TESTS/testing/sheet_extension_spec.lua -- `extension = "<dir>"` in a browser sheet: the field is checked (browser
-- only, a folder relative to the root), and where node, playwright-core and Chromium exist, Chromium loads the
-- fixture extension (fixtures/sheet_extension, a fixed id through its `key`) and a step opens its own page.
-- @cache-allow time processes
-- @cache-inputs TESTS/testing/fixtures/sheet_extension/
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local browser = require("testing.sheet.browser")
  local here =
    vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local repo = vim.fs.dirname(vim.fs.dirname(here))
  -- the id Chromium derives from the `key` of the fixture's manifest
  local ID = "jnkemndpamljmeokialekifcnbnobgph"

  local function sheet_of(fields)
    return vim.tbl_extend("force", {
      id = "ext.page",
      title = "extension",
      engine = "browser",
      steps = { { open = "chrome-extension://" .. ID .. "/page.html" } },
    }, fields)
  end

  -- 1. the form ---------------------------------------------------------------------------------------------------------
  ok(sheet.validate(sheet_of({ extension = "ext" })) ~= nil, "an extension loads")
  local function refused(fields, needle, msg)
    local s, err = sheet.validate(sheet_of(fields))
    ok(s == nil, msg .. ": refused")
    has(err, needle, msg)
  end
  refused({ extension = "../ext" }, "relative to the project root", "a folder above the root")
  refused({ extension = "/abs/ext" }, "relative to the project root", "an absolute path")
  refused({ extension = "C:/ext" }, "relative to the project root", "a drive letter")
  refused({ extension = "" }, "relative to the project root", "empty")
  refused({ extension = "a,b" }, "no comma", "a comma (Chromium would load two folders)")
  refused({ extension = 1 }, "extension must be a string", "not a string")
  refused({
    extension = "ext",
    engine = "rpc",
    steps = { { expect = "true" } },
  }, "extension belongs to a browser sheet", "an rpc sheet")

  -- 2. the plan names the absolute folder -----------------------------------------------------------------------------
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-ext"
  vim.fn.mkdir(root .. "/ext", "p")
  for _, name in ipairs({ "manifest.json", "page.html" }) do
    vim.uv.fs_copyfile(here .. "/fixtures/sheet_extension/" .. name, root .. "/ext/" .. name)
  end
  local s = assert(sheet.validate(sheet_of({
    extension = "ext",
    steps = {
      { open = "chrome-extension://" .. ID .. "/page.html" },
      {
        wait = "document.getElementById('ok') !== null",
        timeout = 20000,
        note = "the page of the extension is there",
      },
      { expect = "document.title === 'sheet extension'" },
    },
  })))
  local planned
  browser.run(s, {
    root = root,
    node = "node",
    playwright_dir = root,
    run = function(argv)
      planned = vim.json.decode(table.concat(vim.fn.readfile(argv[#argv]), "\n"))
      return { code = 0, stdout = '{"failures":[],"shots":[]}', stderr = "" }
    end,
  })
  has(planned and planned.extension, "ext", "the plan names the extension folder")
  ok(
    planned and vim.fs.normalize(planned.extension) == vim.fs.normalize(root .. "/ext"),
    "absolute, below the root"
  )
  -- the project's branded browser (sheets.browser.channel) refuses an unpacked extension: such a sheet runs in Chromium
  planned = nil
  browser.run(s, {
    root = root,
    node = "node",
    playwright_dir = root,
    channel = "chrome",
    run = function(argv)
      planned = vim.json.decode(table.concat(vim.fn.readfile(argv[#argv]), " "))
      return { code = 0, stdout = '{"failures":[],"shots":[]}', stderr = "" }
    end,
  })
  ok(planned and planned.channel == nil, "an extension sheet leaves the project's channel aside")
  local plain = vim.deepcopy(s)
  plain.extension = nil
  ok(
    browser.channel_for(plain, { channel = "chrome" }) == "chrome",
    "... a sheet without one keeps it"
  )

  -- 3. a real Chromium, where node, playwright-core and Chromium exist --------------------------------------------------
  local pw_dir = browser.playwright_dir(repo)
  local real = sheet.run(s, { root = root, playwright_dir = pw_dir })
  if real.status == "skip" then
    print("n/a  " .. tostring(real.skipped) .. ": the real extension is skipped")
  else
    ok(real.ok, "Chromium loaded the extension: " .. table.concat(real.failures, "; "))
    -- without the field the page of the extension does not exist
    local without = vim.deepcopy(s)
    without.extension = nil
    local red = sheet.run(without, { root = root, playwright_dir = pw_dir })
    ok(not red.ok, "without the extension its page is not there")
  end
  vim.fn.delete(root, "rf")
end
