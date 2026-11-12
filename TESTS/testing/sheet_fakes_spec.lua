-- TESTS/testing/sheet_fakes_spec.lua -- `fakes = { ... }` in an rpc sheet: the child finds recording stand-ins
-- (`testing.fake_programs`) first on its PATH, a step reads the calls through `TESTING_FAKES`, and the field is
-- checked (rpc only, program names, no duplicates).
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
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local function sheet_of(fields)
    return vim.tbl_extend("force", {
      id = "f.sheet",
      minit = S.minit,
      title = "fakes",
      sizes = { { rows = 10, cols = 40 } },
      steps = { { expect = "true" } },
    }, fields)
  end

  -- 1. the form ---------------------------------------------------------------------------------------------------------
  ok(sheet.validate(sheet_of({ fakes = { "open", "xdg-open" } })) ~= nil, "fakes load")
  local function refused(fields, needle, msg)
    local s, err = sheet.validate(sheet_of(fields))
    ok(s == nil, msg .. ": refused")
    has(err, needle, msg)
  end
  refused({ fakes = {} }, "a list of 1 to", "an empty list")
  refused({ fakes = "open" }, "fakes must be a table", "not a list")
  refused({ fakes = { "../open" } }, "fakes[1]: a program name", "a path")
  refused({ fakes = { "open.cmd" } }, "fakes[1]: a program name", "an extension")
  refused({ fakes = { "open", "open" } }, "fakes[2]: open twice", "twice")
  refused(
    { fakes = { "open" }, engine = "manual", manual = { "look" }, steps = {} },
    "fakes belongs to an rpc sheet",
    "a manual sheet"
  )

  -- 2. a real child calls the stand-in --------------------------------------------------------------------------------
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-fakes"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local s = assert(sheet.validate(sheet_of({
    fakes = { "xdg-open" },
    steps = {
      {
        lua = "_G.fake_code = vim.system({ 'xdg-open', 'https://example.test/a b' }, { text = true }):wait(10000).code",
      },
      { expect = "_G.fake_code == 0", note = "the stand-in ran" },
      {
        expect = "vim.deep_equal(require('testing.fake_programs').read(vim.env.TESTING_FAKES, 'xdg-open')[1].argv, "
          .. "{ 'https://example.test/a b' })",
        note = "the call was recorded with its argument",
      },
      {
        expect = "#require('testing.fake_programs').read(vim.env.TESTING_FAKES, 'open') == 0",
        note = "nothing else",
      },
    },
  })))
  local res = sheet.run(s, { root = root, ci = true })
  eq(
    { res.status, res.failures },
    { "pass", {} },
    "the child found the stand-in and the step read the call"
  )

  -- a sheet without the field finds no stand-in folder
  local plain =
    assert(sheet.validate(sheet_of({ steps = { { expect = "vim.env.TESTING_FAKES == nil" } } })))
  eq(sheet.run(plain, { root = root, ci = true }).status, "pass", "without fakes: no TESTING_FAKES")

  -- the reader on its own: a folder without a log has no calls
  eq(require("testing.fake_programs").read(root .. "/nothing-here"), {}, "read: no log, no calls")

  vim.fn.delete(root, "rf")
end
