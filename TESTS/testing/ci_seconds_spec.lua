-- TESTS/testing/ci_seconds_spec.lua -- every output of `testing ci` writes seconds the same way: the live line
-- (`-- step: state (x s)`), the summary of the report, the editor's table and the repositories table. They used
-- `%.1f` while the report rounded half up, so a step of 1250 ms read "1.2 s" live and "1.3 s" in the summary.

return function(H)
  local ok, eq = H.ok, H.eq
  local report = require("testing.ci.report")

  eq(report.seconds(1250), "1.3 s", "seconds: an exact half rounds up")
  eq(report.seconds(1249), "1.2 s", "seconds: below the half rounds down")
  eq(report.seconds(0), "0.0 s", "seconds: zero")
  eq(report.seconds(61950), "62.0 s", "seconds: a carry into the whole seconds")
  eq(report.seconds(nil), "0.0 s", "seconds: no duration is zero, not an error")

  -- no other way of writing seconds is left in the ci modules: `%.1f` decides an exact half by the C library
  local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
  local offenders = {}
  for name, kind in vim.fs.dir(root .. "/lua/testing/ci") do
    if kind == "file" and name:match("%.lua$") then
      local n = 0
      for line in io.lines(root .. "/lua/testing/ci/" .. name) do
        n = n + 1
        if line:find("%.1f s", 1, true) then
          offenders[#offenders + 1] = ("%s:%d"):format(name, n)
        end
      end
    end
  end
  ok(
    #offenders == 0,
    "seconds: no `%.1f s` left in lua/testing/ci: " .. table.concat(offenders, ", ")
  )
end
