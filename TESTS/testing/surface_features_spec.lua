-- TESTS/testing/surface_features_spec.lua -- the feature catalog against the surface (testing.surface.features): a
-- not covered entry of `testing surface` names the functionality that rests on it and whether it has a sheet, an entry
-- the catalog names and the surface does not have is a note (never a failure), and `testing sheets report` lists per
-- functionality the entries the baseline of the surface gate has as not exercised. No child editor.

---@diagnostic disable: missing-fields, need-check-nil

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
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local sf = require("testing.surface.features")
  local surface = require("testing.surface")
  local render = require("testing.surface.render")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-surface-features"
  local function write(rel, text)
    local p = tmp .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end

  -- ── the index, pure ──
  local catalog = {
    { id = "fx.open", title = "Open a thing", surface = { "command:Open", "binding:<leader>a" } },
    { id = "fx.status", title = "The status", surface = { "command:Fx status", "command:Typo" } },
    { id = "fx.plain", title = "Without entries" },
  }
  local idx = sf.index(catalog, { ["fx.open"] = true }, {
    ["command:Open"] = true,
    ["binding:<leader>a"] = true,
    ["command:Fx status"] = true,
  })
  eq(
    idx.by_entry["command:Open"],
    { { id = "fx.open", sheet = true } },
    "an entry names its functionality"
  )
  eq(
    idx.by_entry["command:Fx status"],
    { { id = "fx.status", sheet = false } },
    "... and whether it has a sheet"
  )
  eq(
    idx.unknown,
    { { feature = "fx.status", entry = "command:Typo" } },
    "an entry the surface does not have"
  )
  eq(sf.index(catalog, {}, nil).unknown, {}, "without the surface nothing is called unknown")
  eq(sf.gap_text(nil), "no feature test", "an entry no functionality names")
  eq(
    sf.gap_text({ { id = "a", sheet = true }, { id = "b", sheet = false } }),
    "feature a has a sheet; feature b has no sheet",
    "two functionalities on one entry"
  )

  -- ── testing surface on a project with a catalog ──
  write(
    "TESTS/sheets/features.lua",
    'return {\n  { id = "fx.open", title = "Open a thing", surface = { "command:Open", "binding:<leader>a" } },\n'
      .. '  { id = "fx.status", title = "The status", surface = { "command:Fx status", "command:Typo" } },\n}\n'
  )
  write(
    "TESTS/sheets/open.sheet.lua",
    'return { id = "fx.open-sheet", title = "open", feature = "fx.open", steps = { { keys = ":Open<CR>" } } }\n'
  )
  local function entry(id, kind)
    return { id = id, kind = kind, name = (id:gsub("^%a+:", "")), src = "lua/fx/init.lua:1" }
  end
  local fixed = {
    version = 1,
    plugin = "fx",
    root = tmp,
    notes = {},
    counts = { binding = 1, command = 2, autocmd = 1 },
    entries = {
      entry("binding:<leader>a", "binding"),
      entry("command:Open", "command"),
      entry("command:Fx status", "command"),
      entry("autocmd:g:BufEnter", "autocmd"),
    },
  }
  -- a tracked run that reached the binding only
  local ir = {
    cases = {
      {
        id = "a::x",
        file = "a_spec.lua",
        status = "pass",
        tags = {},
        surface = { hit = { "binding:<leader>a" } },
      },
    },
  }
  local rep =
    surface.report(tmp, { config = { plugin = "fx" }, surface = fixed, hits = { ir = { ir } } })
  eq(rep.exit_code, 0, "a typo in the catalog fails nothing: " .. tostring(rep.error))
  local text = render.text(rep)
  has(
    text,
    "command:Open - feature fx.open has a sheet",
    "a gap under a functionality with a sheet"
  )
  has(text, "command:Fx status - feature fx.status has no sheet", "a gap under one without")
  has(text, "autocmd:g:BufEnter - no feature test", "an entry no functionality names")
  has(
    table.concat(rep.notes, "\n"),
    "feature catalog: fx.status names command:Typo, which the surface does not have",
    "the typo is a note"
  )
  has(
    render.markdown(rep),
    "* not covered: `command:Fx status` - feature fx.status has no sheet",
    "the markdown says the same"
  )
  -- a catalog that does not load is said, the report stays
  write("TESTS/sheets/features.lua", "return 42\n")
  local broken =
    surface.report(tmp, { config = { plugin = "fx" }, surface = fixed, hits = { ir = { ir } } })
  has(table.concat(broken.notes, "\n"), "feature catalog: ", "a broken catalog is a note")
  has(
    render.text(broken),
    "command:Open - no feature test",
    "and the gaps say what they said before"
  )

  -- ── testing sheets report: the entries the baseline has as not exercised ──
  local report = require("testing.sheet.report")
  local c = catalog
  local s = assert(require("testing.sheet").validate({
    id = "fx.open-sheet",
    title = "open",
    feature = "fx.open",
    steps = { { keys = "x" } },
  }))
  local entries = {
    {
      root = tmp,
      rel = "TESTS/sheets/open.sheet.lua",
      sheet = s,
      case = { status = "pass" },
      snapshots = {},
    },
  }
  local without = report.render(entries, { catalogs = { [tmp] = { catalog = c } } })
  ok(not without:find("not exercised", 1, true), "without a baseline nothing is said: " .. without)
  write(
    "surface.baseline.json",
    vim.json.encode({
      version = 1,
      entries = {
        ["command:Open"] = "missing",
        ["binding:<leader>a"] = "hit",
        ["command:Fx status"] = "missing",
      },
    })
  )
  local with = report.render(entries, { catalogs = { [tmp] = { catalog = c } } })
  has(with, "; not exercised: `command:Open`", "a functionality with a sheet: its gap")
  ok(not with:find("`binding:<leader>a`", 1, true), "an exercised entry is not listed")
  has(
    with,
    "fx.status – no sheet (The status); not exercised: `command:Fx status`",
    "one without a sheet too"
  )
  write("surface.baseline.json", "not json")
  ok(
    not report
      .render(entries, { catalogs = { [tmp] = { catalog = c } } })
      :find("not exercised", 1, true),
    "a baseline that does not parse says nothing"
  )

  vim.fn.delete(tmp, "rf")
end
