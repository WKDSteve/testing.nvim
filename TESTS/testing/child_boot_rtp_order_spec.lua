-- TESTS/testing/child_boot_rtp_order_spec.lua -- REAL child editors (testing.run.isolated): the FIRST entry of
-- `rtp_prepend` ends up first on the child's runtimepath, as in the rpc child (`testing.child.rpc_init`). `boot.lua`
-- prepended the list in order, so the LAST entry came first: a runner that put the project before a copy of the same
-- plugin (lib.nvim) got the copy's modules.

return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")

  local root = S.new_root()
  local first, second = root .. "/first", root .. "/second"
  S.write(first .. "/lua/order_probe.lua", "return 'first'\n")
  S.write(second .. "/lua/order_probe.lua", "return 'second'\n")
  local PROBE = [==[
return function(H)
  local f = assert(io.open(vim.fn.getcwd() .. "/order.txt", "wb"))
  f:write(require("order_probe"))
  f:close()
end
]==]
  local entries = S.project(root, { ["TESTS/probe_spec.lua"] = PROBE }, { "TESTS/probe_spec.lua" })
  local prepend =
    require("testing.run.options").child_rtp({ root = root, project = { deps = {} }, args = {} })
  local list = { first, second }
  vim.list_extend(list, prepend)
  S.run(root, entries, { rtp_prepend = list })
  local got = S.slurp(root .. "/order.txt")
  ok(got == "first", "the first entry of rtp_prepend comes first (got " .. tostring(got) .. ")")
  S.cleanup()
end
