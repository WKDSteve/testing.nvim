-- TESTS/testing/sheet_features_spec.lua -- feature sheets (testing.sheet.features): the catalog TESTS/sheets/features.lua
-- read as data with its shape checked (the message names the entry and the field), the section "Features" of
-- `testing sheets report` (the worst state of a functionality's sheets, no sheet, sheets without a feature, unknown
-- features; only with a catalog), and `testing sheets new --feature`. No child editor.

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
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 1200))
    )
  end
  local features = require("testing.sheet.features")
  local report = require("testing.sheet.report")
  local sheet = require("testing.sheet")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-features"
  local function write(rel, text)
    local p = tmp .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end

  -- ── the catalog ───────────────────────────────────────────────────────
  local function refused(text, needle, msg)
    local c, err = features.load_text(text, "features.lua")
    ok(c == nil, msg .. ": refused")
    has(err, needle, msg)
  end
  local good = [[return {
    { id = "p.view", title = "The view shows the rows", surface = { "command:P view" }, docs = "docs/view.md" },
    { id = "p.copy", title = "Y copies the row" },
    { id = "p.zoom", title = "The view zooms" },
  }]]
  local c = assert(features.load_text(good, "features.lua"))
  eq(#c, 3, "three functionalities")
  eq(features.by_id(c)["p.copy"].title, "Y copies the row", "by id")
  refused("return { { title = 'x' } }", "[1].id", "an entry without id")
  refused("return { { id = 'a/b', title = 'x' } }", "[1].id", "an id with a slash")
  refused(
    "return { { id = 'a', title = 'x' }, { id = 'a', title = 'y' } }",
    "[2].id a is there already",
    "a duplicate id"
  )
  refused("return { { id = 'a' } }", "[1].title is required", "an entry without title")
  refused(
    "return { { id = 'a', title = 'two\\nlines' } }",
    "[1].title is required, one line",
    "a title of two lines"
  )
  refused(
    "return { { id = 'a', title = 'x', what = 1 } }",
    "[1]: unknown field what",
    "an unknown field"
  )
  refused(
    "return { { id = 'a', title = 'x', surface = 'command:x' } }",
    "[1].surface must be a table",
    "surface no list"
  )
  refused(
    "return { { id = 'a', title = 'x', surface = { '' } } }",
    "[1].surface[1]",
    "an empty surface entry"
  )
  refused("return { a = { id = 'a', title = 'x' } }", "is a list", "a map, not a list")
  refused("return 1", "returns a list", "no table")
  refused("return os.exit(1)", "os", "no globals: the environment is empty")
  refused("while true do end", "takes too long", "a loop ends under the instruction limit")
  refused("return {", "features.lua", "a syntax error names the file")

  -- a repository without the file has no catalog, one with a broken file says why
  eq({ features.load(tmp .. "/none") }, {}, "no file: no catalog, no error")
  write("broken/TESTS/sheets/features.lua", "return { { id = 'x' } }\n")
  local none, berr = features.load(tmp .. "/broken")
  eq(none, nil, "a broken catalog: none")
  has(berr, "TESTS/sheets/features.lua: [1].title is required", "and why, with the file")

  -- ── the report ────────────────────────────────────────────────────────
  local root = vim.fs.normalize(tmp .. "/p.nvim")
  local function entry(id, opts)
    opts = opts or {}
    local s = assert(sheet.validate({
      id = id,
      title = id,
      feature = opts.feature,
      steps = { { keys = "x" } },
      judge = opts.judge,
    }))
    return {
      root = root,
      rel = "TESTS/sheets/" .. id .. ".sheet.lua",
      sheet = s,
      case = opts.status and { status = opts.status, message = opts.message } or nil,
      stale = opts.stale,
      snapshots = {},
    }
  end
  local entries = {
    entry("view-alone", { feature = "p.view", status = "pass", judge = { "reads well" } }),
    entry(
      "view-beside",
      { feature = "p.view", status = "fail", message = "80x24 step 3, wait timed out" }
    ),
    entry("copy", { feature = "p.copy", status = "pass" }),
    entry("legacy", { status = "pass" }),
    entry("typo", { feature = "p.veiw", status = "pass" }),
  }
  local text = report.render(entries, { catalogs = { [root] = { catalog = c } } })
  has(
    text,
    "## Features (p.nvim): 2 of 3 with a sheet",
    "the heading counts the covered functionalities"
  )
  has(
    text,
    "- **p.view** – red: red `view-beside`: 80x24 step 3, wait timed out, inbox `view-alone`",
    "the worst sheet decides, and each sheet says its state"
  )
  has(text, "- **p.copy** – green: green `copy`", "a green functionality")
  ok(
    text:find("**p.view**", 1, true) < text:find("**p.copy**", 1, true),
    "the worst functionality comes first"
  )
  has(text, "- p.zoom – no sheet (The view zooms)", "a functionality without a sheet")
  has(text, "- sheets without a feature: `legacy`", "a sheet without a feature")
  has(
    text,
    "- unknown feature of a sheet: `p.veiw` (`TESTS/sheets/typo.sheet.lua`)",
    "a typo is named"
  )
  -- without a catalog the report is what it was
  local plain = report.render(entries, {})
  ok(not plain:find("## Features", 1, true), "no catalog: no section")
  local broken = report.render(
    entries,
    { catalogs = { [root] = { error = "features.lua: [1].title is required" } } }
  )
  has(broken, "## Features (p.nvim): the catalog does not load", "a broken catalog is said")
  has(broken, "- features.lua: [1].title is required", "with the reason")

  -- the states of a functionality, worst first
  eq(
    report.FEATURE_STATES,
    { "red", "stale", "never", "skipped", "inbox", "manual", "green" },
    "the order of the states"
  )
  eq(report.feature_state(entry("n", { feature = "p.view" })), "never", "no result: never")
  eq(
    report.feature_state(entry("s", { status = "pass", stale = "changed" })),
    "stale",
    "a result that is not current"
  )
  eq(report.feature_state(entry("k", { status = "skip" })), "skipped", "a skip")
  eq(
    report.feature_state({ root = root, rel = "x", error = "no", snapshots = {} }),
    "red",
    "a sheet that does not load"
  )

  -- the CLI reads the catalog of each root
  write("p.nvim/TESTS/sheets/features.lua", good)
  write(
    "p.nvim/TESTS/sheets/copy.sheet.lua",
    'return { id = "copy", title = "copy", feature = "p.copy", engine = "manual", manual = { "press Y" } }\n'
  )
  local out = {}
  local code = report.main({ "report", root, "--from", write("ir.json", '{"cases":[]}') }, {
    out = function(s)
      out[#out + 1] = s
    end,
    err = function(s)
      out[#out + 1] = s
    end,
  })
  eq(code, 0, "the report: exit 0")
  has(
    table.concat(out, "\n"),
    "## Features (p.nvim): 1 of 3 with a sheet",
    "from the files of the root"
  )
  has(table.concat(out, "\n"), "- **p.copy** – manual: manual `copy`", "a manual sheet")
  -- a linked worktree of the repository (its .git file points into <main>/.git/worktrees/): the repository's name
  vim.fn.mkdir(root .. "/.git/worktrees/topic", "p")
  local wt = tmp .. "/p.nvim-topic"
  write("p.nvim-topic/.git", "gitdir: " .. root .. "/.git/worktrees/topic\n")
  local named = report.render({}, { catalogs = { [wt] = { catalog = c } } })
  has(named, "## Features (p.nvim): 0 of 3 with a sheet", "a worktree is named by its repository")

  -- ── sheets new --feature ─────────────────────────────────────────────
  local new = require("testing.sheet.new")
  local function run_new(argv)
    local lines = {}
    local sv = {
      out = function(s)
        lines[#lines + 1] = s
      end,
      err = function(s)
        lines[#lines + 1] = s
      end,
    }
    return new.main(argv, sv, {
      call = function(method, params)
        if method == "task" and params.id == "p/view-check" then
          return {
            task = { title = "Live check of the view", slug = "view-check" },
            body = "## Akzeptanz\n\n- [ ] the rows read well\n",
          }
        end
        return nil, "no such task"
      end,
    }),
      table.concat(lines, "\n")
  end
  local c1, o1 = run_new({ "--feature", "p.zoom", "--repo", root })
  eq(c1, 0, "--feature alone writes a sheet: " .. o1)
  local s1 = assert(sheet.load(root .. "/TESTS/sheets/p.zoom.sheet.lua"))
  eq(
    { s1.feature, s1.title, s1.task },
    { "p.zoom", "The view zooms", nil },
    "feature and title from the catalog"
  )
  local c2, o2 = run_new({ "--from-task", "p/view-check", "--feature", "p.view", "--repo", root })
  eq(c2, 0, "with a task: " .. o2)
  local s2 = assert(sheet.load(root .. "/TESTS/sheets/view-check.sheet.lua"))
  eq(
    { s2.feature, s2.title, s2.task, s2.judge },
    { "p.view", "The view shows the rows", "p/view-check", { "the rows read well" } },
    "the task's acceptance, the catalog's title"
  )
  local c3, o3 = run_new({ "--feature", "p.nope", "--repo", root })
  eq(c3, 2, "an unknown feature: exit 2")
  has(o3, "p.nope is not in TESTS/sheets/features.lua", "and why")
  local c4, o4 = run_new({ "--feature", "p.view", "--repo", tmp .. "/none" })
  eq(c4, 2, "no catalog: exit 2")
  has(o4, "no feature catalog", "and why")
  local c5 = run_new({ "--repo", root })
  eq(c5, 2, "neither a task nor a feature: exit 2")

  vim.fn.delete(tmp, "rf")
end
