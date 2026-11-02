-- TESTS/testing/optspec_spec.lua -- the table-driven option parser (`testing.optspec`) and `testing surface`, whose
-- parser is built on it: `--name value`, `--name=value`, a missing value, an unknown option, a path given twice.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local optspec = require("testing.optspec")

  local specs = {
    ["--on"] = {
      flag = function(a)
        a.on = true
      end,
    },
    ["--name"] = {
      value = function(a, v)
        a.names[#a.names + 1] = v
      end,
    },
    ["--even"] = {
      value = function(a, v)
        if tonumber(v) % 2 ~= 0 then
          return "--even: " .. v .. " is odd"
        end
      end,
    },
  }
  local function parse(argv, positional)
    return optspec.parse(argv, { names = {} }, specs, positional)
  end

  local a = parse({ "--on", "--name", "x", "--name=y" })
  eq(
    a,
    { names = { "x", "y" }, on = true },
    "a flag, a value as the next argument, a value after ="
  )
  eq(
    (parse({ "--on=1" })),
    { names = {}, on = true },
    "a flag ignores a value that is attached to it"
  )
  local _, err = parse({ "--name" })
  eq(err, "--name needs a value", "a value option at the end: it needs a value")
  _, err = parse({ "--even", "3" })
  eq(err, "--even: 3 is odd", "an error text of a value handler ends the parse")
  _, err = parse({ "--nope" })
  eq(err, "unknown option --nope", "an unknown option")
  _, err = parse({ "word" })
  eq(err, "unexpected argument word", "a word with no positional handler")
  _, err = parse({ "--bad" .. string.char(7) })
  eq(err, "unknown option --bad?", "control characters are made visible")
  local seen = {}
  a = parse({ "x", "--on", "y" }, function(res, arg, i)
    seen[#seen + 1] = { arg, i }
    res.last = arg
  end)
  eq(seen, { { "x", 1 }, { "y", 3 } }, "the positional handler gets the word and its place")
  eq(a.last, "y", "and fills the result")

  -- `testing surface` on top of it
  local surface = require("testing.surface")
  local s = assert(surface.parse_args({
    "root",
    "--json",
    "--from",
    "a.json",
    "--from=b.json",
    "--kind",
    "command,binding",
    "--threshold",
    "0.5",
    "--threshold=command=0.9",
    "--fail-on-removed",
  }))
  eq(s.root, "root", "surface: the root")
  eq(s.format, "json", "surface: --json")
  eq(s.from, { "a.json", "b.json" }, "surface: --from twice")
  eq(s.kinds, { "command", "binding" }, "surface: --kind")
  eq(s.thresholds, { overall = 0.5, kinds = { command = 0.9 } }, "surface: thresholds")
  eq(s.fail_on_removed, true, "surface: --fail-on-removed")
  eq(
    select(2, surface.parse_args({ "--from" })),
    "--from needs a value",
    "surface: a missing value"
  )
  eq(
    select(2, surface.parse_args({ "--kind", "nonsense" })),
    '--kind: unknown kind "nonsense" ('
      .. table.concat(require("testing.surface.ids").KINDS, ", ")
      .. ")",
    "surface: an unknown kind"
  )
  eq(
    select(2, surface.parse_args({ "--threshold", "2" })),
    '--threshold: "2" is not a number between 0 and 1',
    "surface: a threshold out of range"
  )
  eq(select(2, surface.parse_args({ "a", "b" })), "only one path is accepted", "surface: two paths")
  eq(
    select(2, surface.parse_args({ "--wat" })),
    "unknown option --wat",
    "surface: an unknown option"
  )
  eq(surface.parse_args({ "list" }).root, nil, "surface: `list` is the one view and no root")
  eq(surface.parse_args({ "-h" }).help, true, "surface: -h")
end
