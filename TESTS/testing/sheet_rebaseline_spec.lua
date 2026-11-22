-- TESTS/testing/sheet_rebaseline_spec.lua -- the sheet step `{ rebaseline = true }`: a plugin that starts a timer that
-- repeats for ever when it is set up (color_my_ascii.nvim on its first FileType) never lets `settle` be idle; the step
-- takes what is active now as the new quiet, so a later `settle` passes, while work started after it still counts.
-- The step validates like `restart` (only `true`) and belongs to the rpc engine.
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
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-rebaseline"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/minimal_init.lua", "wb"))
  f:write("vim.o.swapfile = false\n")
  f:close()

  -- the plugin: set up on the first FileType, with a cleanup timer that repeats for ever
  local SETUP = "vim.api.nvim_create_autocmd('FileType', { once = true, callback = function() "
    .. "local t = vim.uv.new_timer(); t:start(200, 200, function() end) end }); "
    .. "vim.bo.filetype = 'markdown'"

  local function run(steps)
    local s = assert(sheet.validate({
      id = "t.rebaseline",
      title = "R",
      sizes = { { rows = 12, cols = 50 } },
      steps = steps,
    }))
    return sheet.run(s, { root = root, ci = true })
  end

  local without = run({ { lua = SETUP }, { settle = 400 } })
  eq(without.status, "fail", "a timer that repeats for ever: settle is never idle")
  ok(
    tostring(without.failures[1]):find("timer", 1, true) ~= nil,
    "and the failure names the timer: " .. vim.inspect(without.failures)
  )

  local with = run({ { lua = SETUP }, { rebaseline = true }, { settle = 400 } })
  eq(
    with.status,
    "pass",
    "after rebaseline the endless timer is the quiet: " .. vim.inspect(with.failures)
  )

  local later = run({
    { lua = SETUP },
    { rebaseline = true },
    { lua = "local t = vim.uv.new_timer(); t:start(200, 200, function() end)" },
    { settle = 400 },
  })
  eq(later.status, "fail", "a timer started after the rebaseline still keeps the child busy")

  -- ---- validation ------------------------------------------------------------------------------------------
  local _, err = sheet.validate({
    id = "t.bad",
    title = "B",
    steps = { { rebaseline = false } },
  })
  ok(
    tostring(err):find("rebaseline must be true", 1, true) ~= nil,
    "rebaseline = false is refused: " .. tostring(err)
  )
  local _, err2 = sheet.validate({
    id = "t.browser",
    title = "B",
    engine = "browser",
    url = "http://localhost:1",
    steps = { { rebaseline = true } },
  })
  ok(err2 ~= nil, "a browser sheet has no rebaseline step: " .. tostring(err2))
  vim.fn.delete(root, "rf")
end
