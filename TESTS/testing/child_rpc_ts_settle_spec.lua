-- TESTS/testing/child_rpc_ts_settle_spec.lua -- REAL child editors (testing.rpc): treesitter's chunked parse (3 ms a
-- step, then `vim.schedule`) kept `settle` at "scheduled 1" under load. The child parses synchronously by default
-- (`ts_sync`), and "not idle" names where a pending `vim.schedule` came from.

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  if not pcall(vim.treesitter.language.add, "markdown") then
    print("n/a  no markdown parser for treesitter in this editor")
    return
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  -- a long markdown buffer, parsed the way the highlighter does it: asynchronously, with a callback
  local PARSE = [[
    local lines = {}
    for i = 1, 6000 do
      lines[#lines + 1] = ("# heading %d"):format(i)
      lines[#lines + 1] = ""
      lines[#lines + 1] = "some *text* with `code` and a [link](https://example.invalid) ..."
      lines[#lines + 1] = ""
    end
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.g.parsed = false
    vim.treesitter.get_parser(b, "markdown"):parse(true, function()
      vim.g.parsed = true
    end)
  ]]

  S.run(function()
    local c = S.spawn({ minit = S.minit })
    eq(c.g._ts_force_sync_parsing, true, "ts_sync: the child parses synchronously by default")
    c.lua(PARSE)
    local idle, why = c.settle(5000)
    ok(idle, "ts_sync: idle once the parse returned: " .. tostring(why))
    eq(c.g.parsed, true, "ts_sync: ... and the parse is done")

    -- off: the parse goes in steps, and a settle that ends early names languagetree as the source
    local slow = S.spawn({ minit = S.minit, ts_sync = false })
    eq(slow.g._ts_force_sync_parsing, nil, "ts_sync=false: left alone")
    slow.lua(PARSE)
    local early, early_why = slow.settle(1)
    ok(early == false, "ts_sync=false: not idle while the parse goes on in steps")
    has(early_why, "scheduled_by", "not idle: names where the scheduled callback came from")
    has(early_why, "languagetree.lua:", "not idle: ... the treesitter parser")
    ok(slow.settle(60000), "ts_sync=false: idle once the steps are done")
    eq(slow.g.parsed, true, "ts_sync=false: ... and the parse is done")
  end)
end
