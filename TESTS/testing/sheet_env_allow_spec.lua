-- TESTS/testing/sheet_env_allow_spec.lua -- the child of an rpc sheet inherits the names in `env_allow` of the
-- project's `.testing.lua`, as a spec child does (hover.nvim: MAGICK_* for an ImageMagick that finds its modules
-- through it), and nothing it does not name.
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
  local sheet = require("testing.sheet")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-envallow"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local f = assert(io.open(root .. "/.testing.lua", "wb"))
  f:write('return { env_allow = { "SHEETENV_KEEP_*" } }\n')
  f:close()

  local saved = { keep = vim.env.SHEETENV_KEEP_A, drop = vim.env.SHEETENV_DROP }
  vim.env.SHEETENV_KEEP_A = "kept"
  vim.env.SHEETENV_DROP = "dropped"
  local s = assert(sheet.validate({
    id = "e.sheet",
    minit = S.minit,
    title = "env_allow",
    sizes = { { rows = 10, cols = 40 } },
    steps = {
      { expect = "vim.env.SHEETENV_KEEP_A == 'kept'", note = "a name env_allow lets through" },
      { expect = "vim.env.SHEETENV_DROP == nil", note = "a name it does not" },
    },
  }))
  local res = sheet.run(s, { root = root, ci = true })
  vim.env.SHEETENV_KEEP_A = saved.keep
  vim.env.SHEETENV_DROP = saved.drop
  eq(
    { res.status, res.failures },
    { "pass", {} },
    "the sheet child sees what env_allow names and nothing else"
  )

  vim.fn.delete(root, "rf")
end
