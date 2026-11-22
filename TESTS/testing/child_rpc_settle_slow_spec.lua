-- TESTS/testing/child_rpc_settle_slow_spec.lua -- a REAL child editor: when `settle` runs out of time although no probe
-- found work (the probes themselves were slower than the limit, as on a machine at 100 % CPU), the reason says so
-- instead of an empty "not idle after N ms: ". More quiet probes than fit in the limit stand for the slow machine.
-- @cache-allow spawn
-- (it starts a child editor)
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  S.run(function()
    local c = S.spawn({ minit = S.minit })
    local settled, why = c.settle(50, { rounds = 100000 })
    ok(not settled, "a quiet child whose probes do not fit in the limit does not settle")
    ok(
      tostring(why):find("no probe found work", 1, true) ~= nil,
      "and the reason says no probe found work: " .. tostring(why)
    )
    ok(
      not tostring(why):find("not idle after 50 ms: $"),
      "the reason is not empty: " .. tostring(why)
    )
  end)
end
