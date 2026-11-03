-- TESTS/testing/finding_spec.lua -- `testing-finding/1`: the fingerprint is stable over commits and moved lines, the
-- excerpt is redacted and bounded at a UTF-8 boundary (a path smuggled in is gone), the data classes gate the
-- document (private and unclassified give none, exit 2), every document validates against the schema file, and
-- `testing call finding` prints them.

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local finding = require("testing.finding")
  local cli = require("testing.cli")
  local schema = require("testing.export.schema")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local base = fixture.base("finding")
  local fx = fixture.build(base)
  local ctx = { dir = fx.beta, state_dir = fx.state, classes = { path = fx.areas } }

  -- ── the fingerprint: no commit, no line ──
  local a = finding.build({
    kind = "case",
    identity = "TESTS/x::a",
    title = "t",
    where = { file = "x", line = 10 },
    sha = string.rep("a", 40),
  }, ctx)
  local b = finding.build({
    kind = "case",
    identity = "TESTS/x::a",
    title = "t",
    where = { file = "x", line = 99 },
    sha = string.rep("b", 40),
  }, ctx)
  eq(a.fp, b.fp, "same case after a commit that only moves lines: the same fp")
  local c = finding.build({ kind = "case", identity = "TESTS/x::b", title = "t" }, ctx)
  ok(a.fp ~= c.fp, "another case: another fp")
  local d = finding.build({ kind = "flaky", identity = "TESTS/x::a", title = "t" }, ctx)
  ok(a.fp ~= d.fp, "the kind is part of the identity")

  -- the data classes are read once per context, not once per finding
  do
    local dc = require("lib.nvim.data_classes")
    local real_load, loads = dc.load, 0
    dc.load = function(...)
      loads = loads + 1
      return real_load(...)
    end
    local once = { dir = fx.beta, state_dir = fx.state, classes = { path = fx.areas } }
    for i = 1, 5 do
      assert(finding.build({ kind = "case", identity = "x" .. i, title = "t" }, once))
    end
    dc.load = real_load
    eq(loads, 1, "five findings of one context read areas.json once")
  end
  ok(a.fp:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil, "16 hex")

  -- ── redaction and the bound ──
  local home_file = fx.home_file
  local r = finding.build({
    kind = "case",
    identity = "x",
    title = "failed in " .. home_file,
    excerpt = "boom at "
      .. fx.beta
      .. "/lua/beta/parser.lua:4 and "
      .. home_file
      .. " "
      .. string.rep("ä", 5000),
    where = { file = fx.beta .. "/lua/x.lua", line = 3 },
  }, ctx)
  ok(r.excerpt:find(fx.beta, 1, true) == nil, "the repository path is not in the excerpt")
  ok(
    r.excerpt:find(home_file, 1, true) == nil,
    "a file below the home directory is not in the excerpt"
  )
  ok(r.title:find(home_file, 1, true) == nil, "nor in the title")
  ok(#r.excerpt <= 4096, "bounded to 4 KiB")
  ok(vim.fn.strchars(r.excerpt) > 0 and select(1, pcall(vim.fn.strchars, r.excerpt)), "readable")
  ok(vim.str_utf_pos and #vim.str_utf_pos(r.excerpt) > 0, "valid UTF-8 after the cut")
  eq(r.root, nil, "no root")

  -- ── the data classes gate it ──
  local doc, err, kind = finding.build({ kind = "case", identity = "x", title = "t" }, {
    dir = fx.vault,
    state_dir = fx.state,
    classes = { path = fx.areas },
  })
  eq(doc, nil, "an unclassified repository gives no finding")
  eq(kind, finding.REFUSED, "refused")
  has(err, "unclassified", "and says the class")

  -- ── what a repository's state gives ──
  local docs = finding.collect(ctx)
  local kinds = {}
  for _, f in ipairs(docs) do
    kinds[f.kind] = (kinds[f.kind] or 0) + 1
  end
  eq(kinds, { case = 2, flaky = 1, ["ci-run"] = 1 }, "two red cases, one flake, one red pipeline")
  eq(
    finding.collect({ dir = fx.alpha, state_dir = fx.state, classes = { path = fx.areas } }),
    {},
    "a green repository has none"
  )

  -- ── guard, lint and sheet findings (built by testing.finding.from_*) ──
  local guard_src = finding.from_guards({
    id = "TESTS/x::g",
    file = "TESTS/x_spec.lua",
    line = 5,
    guards = {
      {
        guard = "fs",
        severity = "warn",
        message = "wrote " .. fx.beta .. "/f.txt",
        stack = "at x",
      },
    },
  })
  eq(#guard_src, 1, "one finding per guard finding")
  local gd = finding.build(guard_src[1], ctx)
  eq(gd.kind, "guard", "kind guard")
  ok(gd.excerpt:find(fx.beta, 1, true) == nil, "the path in a guard message is redacted")
  local moved = finding.from_guards({
    id = "TESTS/x::g",
    file = "TESTS/x_spec.lua",
    line = 90,
    guards = {
      {
        guard = "fs",
        severity = "warn",
        message = "wrote " .. fx.beta .. "/f.txt",
        stack = "at y",
      },
    },
  })
  eq(
    finding.build(moved[1], ctx).fp,
    gd.fp,
    "a guard finding that moved (line, stack) keeps its fp"
  )

  local lint_src = finding.from_lint({
    checks = {
      {
        name = "stylua",
        findings = { { file = "lua/a.lua", line = 3, message = "format", check = "stylua" } },
      },
      { name = "luacheck", findings = {} },
    },
  })
  eq(#lint_src, 1, "one finding per lint finding")
  local ld = finding.build(lint_src[1], ctx)
  eq(
    { ld.kind, ld.rule, ld.where.file, ld.where.line },
    { "lint", "stylua", "lua/a.lua", 3 },
    "lint finding"
  )
  local lint_moved = finding.from_lint({
    checks = {
      {
        name = "stylua",
        findings = { { file = "lua/a.lua", line = 40, message = "format", check = "stylua" } },
      },
    },
  })
  eq(finding.build(lint_moved[1], ctx).fp, ld.fp, "a lint finding that moved keeps its fp")

  local sheet = require("testing.sheet")
  local sh = assert(
    sheet.validate({ id = "s1", title = "S one", task = "a/one", steps = { { keys = "x" } } })
  )
  local sheet_src = finding.from_sheets({
    {
      root = fx.beta,
      rel = "TESTS/sheets/s1.sheet.lua",
      sheet = sh,
      case = { status = "fail", message = "boom" },
      snapshots = {},
    },
    {
      root = fx.beta,
      rel = "TESTS/sheets/ok.sheet.lua",
      sheet = assert(sheet.validate({ id = "ok", title = "Ok", steps = { { keys = "x" } } })),
      case = { status = "pass" },
      snapshots = {},
    },
    { root = fx.beta, rel = "TESTS/sheets/bad.sheet.lua", error = "does not load", snapshots = {} },
  })
  eq(#sheet_src, 2, "red and unloadable sheets give findings, a green one does not")
  local sd = finding.build(sheet_src[1], ctx)
  eq(
    { sd.kind, sd.repro },
    { "sheet", "testing sheets run --task a/one" },
    "sheet finding with its repro"
  )

  -- all of them in one list, next to the findings of the state
  local all = finding.collect(
    ctx,
    vim.list_extend(vim.list_extend(vim.list_slice(guard_src), lint_src), sheet_src)
  )
  eq(#all, 4 + 1 + 1 + 2, "collect adds the extra sources to those of the state")

  -- ── every document validates against the schema file ──
  local schema_file = vim.fs.normalize(
    vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
      .. "/../../schemas/testing-finding/1/testing-finding.schema.json"
  )
  local sf = assert(io.open(schema_file, "rb"))
  local sdoc = vim.json.decode(sf:read("*a"))
  sf:close()
  for _, f in ipairs(docs) do
    local text = vim.json.encode(f)
    local valid, problems = schema.validate(sdoc, vim.json.decode(text))
    eq(problems, {}, "valid: " .. f.kind)
    ok(valid, "valid: " .. f.kind)
  end

  -- ── testing call finding ──
  local function call(args)
    local out, errs = {}, {}
    local code =
      cli.main(vim.list_extend({ "call", "finding", fx.beta, "--state-dir=" .. fx.state }, args), {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          errs[#errs + 1] = s
        end,
      })
    return code, out, errs
  end
  local restore = fixture.install()
  local real_dc = package.loaded["lib.nvim.data_classes"]
  -- the device's areas.json is the fixture's
  local dc = require("lib.nvim.data_classes")
  local real_load = dc.load
  dc.load = function(o)
    return real_load(vim.tbl_extend("force", { path = fx.areas }, o or {}))
  end
  local code, out = call({})
  eq(code, 0, "call finding: exit 0")
  eq(#out, 4, "one line per finding")
  local one = vim.json.decode(out[1])
  local code2, out2 = call({ "--fp=" .. one.fp })
  eq(code2, 0, "--fp: exit 0")
  eq(#out2, 1, "only that finding")
  local code3 = call({ "--fp=0000000000000000" })
  eq(code3, 2, "an unknown fp: exit 2")
  dc.load = real_load
  package.loaded["lib.nvim.data_classes"] = real_dc
  restore()

  vim.fn.delete(base, "rf")
end
