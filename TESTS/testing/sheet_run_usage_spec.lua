-- TESTS/testing/sheet_run_usage_spec.lua -- `testing sheets run --sheet`: one id per flag. The usage line says so
-- (`--sheet <id> [--sheet <id>]...`, not `--sheet <id>...`, which read like several ids after one flag), and
-- `--sheet a b` is refused with the form that works. Nothing runs: the arguments are refused before a root is read.
return function(H)
  local ok = H.ok
  local run = require("testing.sheet.run")

  local function main(argv)
    local out, err = {}, {}
    local code = run.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return code, table.concat(err, "\n")
  end

  ok(
    run.USAGE:find("--sheet <id> [--sheet <id>]...", 1, true) ~= nil,
    "the usage names one id per --sheet: " .. run.USAGE
  )
  ok(
    not run.USAGE:find("--sheet <id>... ", 1, true),
    "and no longer reads like several ids after one flag"
  )

  local code, err = main({ "--sheet", "a.one", "b.two", "--root", "/nowhere" })
  ok(code == 2, "--sheet a b is a usage error (exit 2), got " .. tostring(code))
  ok(
    err:find("one id per --sheet: --sheet a.one --sheet b.two", 1, true) ~= nil,
    "and says the form that works: " .. err
  )

  local code2, err2 = main({ "--all", "stray" })
  ok(code2 == 2, "an unknown argument elsewhere is still refused")
  ok(not err2:find("one id per --sheet", 1, true), "without the --sheet hint: " .. err2)
end
