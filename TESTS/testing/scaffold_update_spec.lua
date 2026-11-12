-- TESTS/testing/scaffold_update_spec.lua -- `testing init --update` (testing.scaffold.update): scripts/test.sh and
-- TESTS/minimal_init.lua brought to the current templates, keeping the repository's own parts (dependencies, the
-- --sentinel of the run line, a deliberate missing NVIM_APPNAME, what minimal_init sets up after the runtimepath),
-- listing what would be lost, never executing .testing.lua; the CLI's preview, --check and --write.

---@diagnostic disable: need-check-nil, param-type-mismatch

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      ("%s: %q found in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end

  local scaffold = require("testing.scaffold")
  local update = require("testing.scaffold.update")
  local base = vim.fs.normalize(vim.fn.tempname())
  local NOFMT = { format = { exe = false } }

  local function slurp(path)
    local fh = assert(io.open(path, "rb"))
    local s = fh:read("a")
    fh:close()
    return s
  end
  local function put(path, s)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(s)
    fh:close()
  end
  ---A freshly scaffolded project.
  local function project(name)
    local root = base .. "/" .. name
    vim.fn.mkdir(root .. "/lua/" .. name:gsub("%.nvim$", ""), "p")
    eq(scaffold.init(root).errors, {}, name .. ": scaffold")
    return root
  end
  local function file(plan, rel)
    for _, f in ipairs(plan.files) do
      if f.rel == rel then
        return f
      end
    end
  end

  -- ---------------------------------------------------------------- a fresh setup is up to date
  local fresh = project("fresh.nvim")
  local p = update.plan(fresh, NOFMT)
  eq(p.errors, {}, "fresh: no errors")
  eq(p.plugin, "fresh", "fresh: the plugin")
  eq(p.deps, { "lib.nvim" }, "fresh: the dependencies from scripts/test.sh")
  eq(file(p, "scripts/test.sh").changed, false, "fresh: scripts/test.sh is up to date")
  eq(file(p, "TESTS/minimal_init.lua").changed, false, "fresh: minimal_init is up to date")

  -- ---------------------------------------------------------------- an older test.sh: kept parts and lost lines
  local old = project("old.nvim")
  local sh_path = old .. "/scripts/test.sh"
  local sh = slurp(sh_path)
  sh = sh:gsub("DEPS=%(([^)]*)%)", "DEPS=(%1 'ui.nvim')", 1)
  sh =
    sh:gsub("\nexport NVIM_APPNAME=[^\n]*", '\nexport NVIM_APPNAME="${NVIM_APPNAME:-old-tests}"', 1)
  sh = sh:gsub(' run %. "%$@"', " run . --sentinel 'OLD_TESTS_OK' \"$@\"", 1)
  sh = sh:gsub("\nset %-euo pipefail\n", "\nset -euo pipefail\nOPTIONAL_DEPS=('snacks.nvim')\n", 1)
  put(sh_path, sh)
  p = update.plan(old, NOFMT)
  local f = file(p, "scripts/test.sh")
  eq(f.changed, true, "old: scripts/test.sh is out of date")
  has(
    f.after,
    "DEPS=('testing.nvim' 'lib.nvim' 'ui.nvim')",
    "old: the dependencies of the old file are kept"
  )
  has(
    f.after,
    "run . --sentinel 'OLD_TESTS_OK' \"$@\"",
    "old: the --sentinel of the run line is kept"
  )
  has(f.after, 'export NVIM_APPNAME="old-tests"', "old: the throwaway app name is the template's")
  eq(
    f.dropped,
    { "OPTIONAL_DEPS=('snacks.nvim')" },
    "old: the repository's own line is listed as lost"
  )
  has(
    table.concat(f.kept, "\n"),
    "1 line(s) of an older template version replaced",
    "old: the old export is counted (the trap line is the template's own and stays)"
  )
  has(f.diff, "-OPTIONAL_DEPS=('snacks.nvim')", "old: and the diff shows it")
  has(
    table.concat(update.lines(p, { diff = true }), "\n"),
    "only in the old file (1 code line(s)",
    "old: the report"
  )

  -- ---------------------------------------------------------------- a deliberate missing NVIM_APPNAME stays missing
  local noapp = project("noapp.nvim")
  sh = slurp(noapp .. "/scripts/test.sh")
  local own_comment =
    "# NVIM_APPNAME is deliberately not set: the stdpath specs compare with a shim without it."
  sh = sh:gsub("\n#[^\n]*\n#[^\n]*\nexport NVIM_APPNAME=[^\n]*", "\n" .. own_comment, 1)
  lacks(sh, "export NVIM_APPNAME=", "noapp: the fixture has no export")
  put(noapp .. "/scripts/test.sh", sh)
  f = file(update.plan(noapp, NOFMT), "scripts/test.sh")
  lacks(f.after, "export NVIM_APPNAME=", "noapp: no export is added")
  has(f.after, own_comment, "noapp: the file's own reason stays")
  eq(f.changed, false, "noapp: otherwise it is the template")

  -- ---------------------------------------------------------------- minimal_init: what is set up after the runtimepath
  local extra = project("extra.nvim")
  local minit_path = extra .. "/TESTS/minimal_init.lua"
  local tail = "return { root = root, deps = found }"
  local minit = slurp(minit_path):gsub(vim.pesc(tail), "vim.o.swapfile = false\n\n" .. tail, 1)
  put(minit_path, minit)
  f = file(update.plan(extra, NOFMT), "TESTS/minimal_init.lua")
  eq(f.changed, false, "extra: a gate with its own settings after the runtimepath is up to date")
  -- an older gate (one template line missing) keeps them when it is brought up to date
  put(minit_path, (minit:gsub("\nlocal MARKERS", "\n-- old\nlocal MARKERS", 1)))
  f = file(update.plan(extra, NOFMT), "TESTS/minimal_init.lua")
  eq(f.changed, true, "extra: an older gate is out of date")
  has(f.after, "vim.o.swapfile = false", "extra: its own settings are kept")
  ok(loadstring(f.after) ~= nil, "extra: the result compiles")

  -- ---------------------------------------------------------------- minimal_init: dependencies only the sheets load
  -- written by hand as six repositories had it: in DEPS, off the runtimepath, handed over in vim.g
  local sheets = project("sheets.nvim")
  local sheets_path = sheets .. "/TESTS/minimal_init.lua"
  local own_reason =
    "-- Left off the runtimepath: the specs use doubles of ui.nvim, only the sheets press the real one."
  local hand = slurp(sheets_path)
    :gsub(
      'local DEPS = { "testing.nvim", "lib.nvim" }',
      'local DEPS = { "testing.nvim", "lib.nvim", "ui.nvim" }\n\n'
        .. own_reason
        .. '\n---@type table<string, true>\nlocal SHEETS_ONLY = { ["ui.nvim"] = true }',
      1
    )
    :gsub(
      "for _, name in ipairs%(DEPS%) do\n  vim%.opt%.rtp:append%(found%[name%]%)\nend\n",
      "for _, name in ipairs(DEPS) do\n  if not SHEETS_ONLY[name] then\n    vim.opt.rtp:append(found[name])\n  end\nend\n"
        .. 'vim.g.sheets_sheets_ui_nvim = found["ui.nvim"]\n\nvim.o.swapfile = false\n',
      1
    )
  has(hand, "SHEETS_ONLY[name] then", "sheets: the hand-written file is built")
  put(sheets_path, hand)
  f = file(update.plan(sheets, NOFMT), "TESTS/minimal_init.lua")
  eq(f.risks, {}, "sheets: nothing held back")
  has(
    f.after,
    'local DEPS = { "testing.nvim", "lib.nvim", "ui.nvim" }',
    "sheets: the dependency stays in DEPS"
  )
  has(f.after, 'local SHEETS_ONLY = { ["ui.nvim"] = true }', "sheets: ... and in SHEETS_ONLY")
  has(f.after, own_reason, "sheets: the file's own reason stays above it")
  has(f.after, "elseif not SHEETS_ONLY[name] then", "sheets: a missing one is not fatal")
  has(
    f.after,
    "  if not SHEETS_ONLY[name] then\n    vim.opt.rtp:append",
    "sheets: it is kept off the runtimepath"
  )
  local _, handovers = f.after:gsub('vim%.g%.sheets_sheets_ui_nvim = found%["ui%.nvim"%]', "")
  eq(
    handovers,
    1,
    "sheets: the vim.g handover once (the template's, not carried over a second time)"
  )
  has(f.after, "vim.o.swapfile = false", "sheets: its own settings after the runtimepath are kept")
  ok(loadstring(f.after) ~= nil, "sheets: the result compiles")
  eq(update.apply(update.plan(sheets, NOFMT)) ~= nil, true, "sheets: written")
  eq(
    file(update.plan(sheets, NOFMT), "TESTS/minimal_init.lua").changed,
    false,
    "sheets: once written, the file is up to date"
  )
  -- a table this cannot read entry by entry holds the file back
  put(sheets_path, (hand:gsub('{ %["ui%.nvim"%] = true }', '{ ["ui.nvim"] = 1 }', 1)))
  f = file(update.plan(sheets, NOFMT), "TESTS/minimal_init.lua")
  has(
    table.concat(f.risks, "\n"),
    "SHEETS_ONLY has entries",
    "sheets: an unreadable SHEETS_ONLY is a risk"
  )
  eq(update.sheets_only_of('x\nlocal SHEETS_ONLY = { ["a.nvim"] = true, ["b.nvim"] = true }\n'), {
    "a.nvim",
    "b.nvim",
  }, "sheets_only_of: the names in order")

  -- a minimal_init that is not the gate is replaced by it, with what it set up carried over
  local legacy = project("legacy.nvim")
  put(
    legacy .. "/TESTS/minimal_init.lua",
    "vim.opt.rtp:prepend(vim.fn.getcwd())\nvim.g.legacy_marker = 1\n"
  )
  f = file(update.plan(legacy, NOFMT), "TESTS/minimal_init.lua")
  has(f.after, "local MARKERS", "legacy: it becomes the gate")
  has(f.after, "vim.g.legacy_marker = 1", "legacy: what it set up is carried over")
  has(table.concat(f.kept, "\n"), "1 block(s) carried over", "legacy: and the plan says so")

  -- ---------------------------------------------------------------- what must never be hidden or lost without a word
  -- a block of the repository's own with a verb of its own is listed, not counted as an older template line
  local own = project("own.nvim")
  sh = slurp(own .. "/scripts/test.sh")
  local own_block =
    'if [ "${1:-}" = "slow" ]; then\n  shift\n  nvim -n -i NONE --headless -u NONE -l "$DRIVER" run . --tags=slow "$@"\n  exit $?\nfi\n'
  sh = sh:gsub(
    "\n# `scripts/test.sh conformance`",
    "\n" .. own_block .. "# `scripts/test.sh conformance`",
    1
  )
  put(own .. "/scripts/test.sh", sh)
  f = file(update.plan(own, NOFMT), "scripts/test.sh")
  has(table.concat(f.dropped, "\n"), 'if [ "${1:-}" = "slow" ]; then', "own: its verb is listed")
  has(table.concat(f.dropped, "\n"), "run . --tags=slow", "own: its run line is listed")
  eq(f.code_changed, true, "own: a code difference")

  -- a DEPS line in double quotes is read; one this cannot read is a risk and the next source is used
  local dq = project("dq.nvim")
  sh = slurp(dq .. "/scripts/test.sh"):gsub(
    "DEPS=%([^)]*%)",
    'DEPS=("testing.nvim" "lib.nvim" "ui.nvim")',
    1
  )
  put(dq .. "/scripts/test.sh", sh)
  eq(update.plan(dq, NOFMT).deps, { "lib.nvim", "ui.nvim" }, "dq: double-quoted names")
  put(dq .. "/scripts/test.sh", (sh:gsub("DEPS=%([^)]*%)", 'DEPS=("testing.nvim" "$EXTRA")', 1)))
  p = update.plan(dq, NOFMT)
  eq(p.deps, { "lib.nvim" }, "dq: an unreadable word falls back to .testing.lua")
  has(
    table.concat(file(p, "scripts/test.sh").risks, "\n"),
    'cannot read: "$EXTRA"',
    "dq: and says so"
  )

  -- a comment only in the old file is shown, and it is not code drift (`--check` stays green for it)
  local cmt = project("cmt.nvim")
  minit = slurp(cmt .. "/TESTS/minimal_init.lua")
  put(
    cmt .. "/TESTS/minimal_init.lua",
    "-- ui.nvim is not needed here: hard dependencies only\n" .. minit
  )
  f = file(update.plan(cmt, NOFMT), "TESTS/minimal_init.lua")
  eq({ f.changed, f.code_changed }, { true, false }, "cmt: changed, but not in code")
  eq(
    f.dropped_comments,
    { "-- ui.nvim is not needed here: hard dependencies only" },
    "cmt: the comment is listed"
  )
  has(
    table.concat(update.lines(update.plan(cmt, NOFMT)), "\n"),
    "(comments only)",
    "cmt: the report says so"
  )

  -- an export of the file's own (indented, inside an if) counts as setting NVIM_APPNAME
  local cond = project("cond.nvim")
  sh = slurp(cond .. "/scripts/test.sh"):gsub(
    "\nexport NVIM_APPNAME=[^\n]*",
    '\nif [[ -z "${KEEP_APP:-}" ]]; then\n  export NVIM_APPNAME="cond-tests"\nfi',
    1
  )
  put(cond .. "/scripts/test.sh", sh)
  f = file(update.plan(cond, NOFMT), "scripts/test.sh")
  has(f.after, 'export NVIM_APPNAME="cond-tests"', "cond: the template's export stays")
  lacks(
    table.concat(f.kept, "\n"),
    "no NVIM_APPNAME export",
    "cond: no claim that the file did not set one"
  )

  -- the runtimepath loop on one line (a formatter's collapse) still marks where the file's own settings start
  local one = project("one.nvim")
  minit = slurp(one .. "/TESTS/minimal_init.lua")
    :gsub(
      "for _, name in ipairs%(DEPS%) do\n%s*vim%.opt%.rtp:append%(found%[name%]%)\nend",
      "for _, name in ipairs(DEPS) do vim.opt.rtp:append(found[name]) end",
      1
    )
    :gsub(
      vim.pesc("return { root = root, deps = found }"),
      "vim.o.swapfile = false\n\nreturn { root = root, deps = found }",
      1
    )
  has(minit, "do vim.opt.rtp:append(found[name]) end", "one: the fixture has the collapsed loop")
  put(one .. "/TESTS/minimal_init.lua", minit)
  has(
    file(update.plan(one, NOFMT), "TESTS/minimal_init.lua").after,
    "vim.o.swapfile = false",
    "one: its settings are kept"
  )

  -- --write holds back a file with a risk, and one with uncommitted changes; --force writes them
  put(dq .. "/scripts/test.sh", sh:gsub("cond", "dq"))
  local risky = update.plan(dq, NOFMT)
  file(risky, "scripts/test.sh").risks = { "a risk" }
  local w, e, held = update.apply(risky, { git = function() end })
  eq({ w, e, held[1] and held[1].rel }, { {}, {}, "scripts/test.sh" }, "hold: a file with a risk")
  has(
    table.concat(update.lines(risky, { written = w, held = held }), "\n"),
    "@@ ",
    "hold: its diff is shown"
  )
  held = select(
    3,
    update.apply(update.plan(dq, NOFMT), {
      git = function(_, rel)
        return rel == "scripts/test.sh" and " M scripts/test.sh" or nil
      end,
    })
  )
  eq(
    held[1] and held[1].why:match("uncommitted"),
    "uncommitted",
    "hold: a file with uncommitted changes"
  )
  w = update.apply(update.plan(dq, NOFMT), {
    force = true,
    git = function()
      return " M x"
    end,
  })
  eq(w, { "scripts/test.sh" }, "hold: --force writes it")

  -- ---------------------------------------------------------------- .testing.lua is read as text, never executed
  local trap = project("trap.nvim")
  local marker = trap .. "/EXECUTED"
  put(
    trap .. "/.testing.lua",
    ('local fh = io.open(%q, \'w\') if fh then fh:close() end\nreturn {\n  plugin = "trap",\n  deps = { "lib.nvim" },\n}\n'):format(
      marker
    )
  )
  vim.fn.delete(trap .. "/scripts/test.sh")
  p = update.plan(trap, NOFMT)
  eq(vim.uv.fs_stat(marker), nil, "trap: .testing.lua was not executed")
  eq({ p.plugin, p.deps }, { "trap", { "lib.nvim" } }, "trap: plugin and deps read from its text")
  eq(file(p, "scripts/test.sh").before, nil, "trap: a missing scripts/test.sh is planned as new")

  -- ---------------------------------------------------------------- apply, then everything is up to date
  -- the dependencies of the old scripts/test.sh (ui.nvim added above) reach minimal_init as well
  local written, errors = update.apply(update.plan(old, NOFMT))
  eq(
    { written, errors },
    { { "scripts/test.sh", "TESTS/minimal_init.lua" }, {} },
    "apply: writes the changed files"
  )
  has(
    slurp(old .. "/TESTS/minimal_init.lua"),
    '"ui.nvim"',
    "apply: minimal_init looks for ui.nvim too"
  )
  eq(
    update.apply(update.plan(fresh, NOFMT)),
    {},
    "apply: a project that is up to date is not written"
  )
  for _, g in ipairs(update.plan(old, NOFMT).files) do
    eq(g.changed, false, "apply: afterwards up to date: " .. g.rel)
  end

  -- ---------------------------------------------------------------- the CLI
  local cli = require("testing.cli")
  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  put(sh_path, sh:gsub("noapp", "old"))
  local r = run({ "init", old, "--update", "--check" })
  eq(r.code, 1, "cli --check: a file out of date is exit 1\n" .. r.out .. r.err)
  lacks(r.out, "@@ ", "cli --check: no diff")
  r = run({ "init", old, "--update" })
  eq(r.code, 0, "cli preview: exit 0")
  has(r.out, "@@ ", "cli preview: the diff")
  has(r.out, "testing init --update --write", "cli preview: says how to write")
  r = run({ "init", old, "--update", "--write" })
  eq(r.code, 0, "cli --write: exit 0\n" .. r.err)
  has(r.out, "updated", "cli --write: says what it wrote")
  eq(run({ "init", old, "--update", "--check" }).code, 0, "cli --check after --write: exit 0")
  eq(run({ "init", old, "--write" }).code, 2, "cli: --write without --update is bad usage")
  eq(run({ "init", old, "--update", "--force" }).code, 2, "cli: --update with --force is bad usage")
  local made = base .. "/made.nvim"
  vim.fn.mkdir(made .. "/lua/made", "p")
  r = run({ "init", made })
  eq(r.code, 0, "cli init: exit 0\n" .. r.err)
  has(r.out, "created: .testing.lua", "cli init: creates the setup")
  has(run({ "init", made }).out, "skipped: .testing.lua", "cli init again: keeps what exists")

  -- ---------------------------------------------------------------- testing:keep blocks and testing:keep-file
  local keep = project("keep.nvim")
  local keep_sh = keep .. "/scripts/test.sh"
  local keep_text = slurp(keep_sh)
  -- the repository's own lines, below a line the template has (the first `set -euo pipefail`)
  local keep_block = table.concat({
    "# testing:keep begin REPOS_DIR for the ci verb",
    'REPOS_DIR="$ROOT"',
    "# testing:keep end",
  }, "\n")
  local with_block =
    keep_text:gsub("(\nset %-euo pipefail\n)", "%1" .. keep_block:gsub("%%", "%%%%") .. "\n", 1)
  put(keep_sh, with_block)
  p = update.plan(keep, NOFMT)
  f = file(p, "scripts/test.sh")
  eq(f.changed, false, "keep: a block between the markers is not a difference")
  eq(f.code_changed, false, "keep: --check does not count it")
  eq(f.dropped, {}, "keep: nothing is listed as lost")
  has(
    table.concat(f.kept, "\n"),
    "3 line(s) between the testing:keep markers",
    "keep: says what it kept"
  )
  -- an older template: the block survives the re-render
  put(
    keep_sh,
    (with_block:gsub("export NVIM_APPNAME=[^\n]*", 'export NVIM_APPNAME="old-tests"', 1))
  )
  p = update.plan(keep, NOFMT)
  f = file(p, "scripts/test.sh")
  eq(f.changed, true, "keep: an out of date file is still updated")
  has(f.after, keep_block, "keep: the block is put back unchanged")
  eq(f.risks, {}, "keep: and nothing is held back")
  -- the anchor line is gone from the template: the block is not lost silently, the file is held back
  put(
    keep_sh,
    (
      keep_text:gsub(
        "\nset %-euo pipefail\n",
        "\nset -eu\n" .. keep_block:gsub("%%", "%%%%") .. "\n",
        1
      )
    )
  )
  p = update.plan(keep, NOFMT)
  f = file(p, "scripts/test.sh")
  eq(#f.risks, 1, "keep: a block whose anchor line is gone is a risk")
  has(f.risks[1], "copy it by hand", "keep: and says what to do")
  -- a block below a line the template repeats (`fi`): it comes back below THAT `fi`, not the first one
  do
    local lines = vim.split(keep_text, "\n", { plain = true })
    local fis = {}
    for n, l in ipairs(lines) do
      if l == "fi" then
        fis[#fis + 1] = n
      end
    end
    ok(#fis >= 2, "the template has a `fi` more than once")
    local second = fis[2]
    local spliced = vim.list_slice(lines, 1, second)
    vim.list_extend(spliced, vim.split(keep_block, "\n", { plain = true }))
    vim.list_extend(spliced, vim.list_slice(lines, second + 1, #lines))
    put(keep_sh, table.concat(spliced, "\n"))
    p = update.plan(keep, NOFMT)
    f = file(p, "scripts/test.sh")
    eq(f.changed, false, "keep: a block below the second `fi` is back below the second `fi`")
    eq(f.risks, {}, "keep: and nothing is held back")
  end

  -- a block without its end marker
  put(keep_sh, (keep_text:gsub("(\nset %-euo pipefail\n)", "%1# testing:keep begin\nX=1\n", 1)))
  p = update.plan(keep, NOFMT)
  has(
    table.concat(file(p, "scripts/test.sh").risks, "\n"),
    "has no '# testing:keep end'",
    "keep: an open block is a risk"
  )

  -- a file that is the repository's own
  put(
    keep_sh,
    "#!/usr/bin/env bash\n# testing:keep-file the dogfood script runs the checkout itself\necho own\n"
  )
  p = update.plan(keep, NOFMT)
  f = file(p, "scripts/test.sh")
  eq(f.changed, false, "keep-file: the file is left as it is")
  eq(f.code_changed, false, "keep-file: --check does not count it")
  has(
    table.concat(f.kept, "\n"),
    "the dogfood script runs the checkout itself",
    "keep-file: the reason is in the report"
  )
  local keep_init = keep .. "/TESTS/minimal_init.lua"
  put(keep_init, "-- testing:keep-file a hand-written init\nvim.opt.rtp:append('.')\n")
  p = update.plan(keep, NOFMT)
  f = file(p, "TESTS/minimal_init.lua")
  eq(f.changed, false, "keep-file: minimal_init too")
  has(table.concat(f.kept, "\n"), "a hand-written init", "keep-file: its reason is in the report")
  local no_reason = project("noreason.nvim")
  put(no_reason .. "/scripts/test.sh", "#!/usr/bin/env bash\n# testing:keep-file\necho own\n")
  has(
    table.concat(file(update.plan(no_reason, NOFMT), "scripts/test.sh").kept, "\n"),
    "no reason given",
    "keep-file: a missing reason is said"
  )

  -- the repository's own explanatory comment above a code line of the template survives a re-render; a template
  -- comment in an older wording is not brought back next to the new one
  local why = project("why.nvim")
  local why_init = why .. "/TESTS/minimal_init.lua"
  local why_text = slurp(why_init)
  local why_note = "-- Hard dependencies only: ui.nvim is not needed, every require of it is lazy."
  ok(
    select(2, why_text:gsub("\nlocal DEPS = ", "\nlocal DEPS = ")) == 1,
    "the template has one `local DEPS` line"
  )
  put(why_init, (why_text:gsub("\nlocal DEPS = ", "\n" .. why_note .. "\nlocal DEPS = ", 1)))
  p = update.plan(why, NOFMT)
  f = file(p, "TESTS/minimal_init.lua")
  eq(f.changed, false, "own comment: a comment above a template line is not a difference")
  eq(f.dropped_comments, {}, "own comment: nothing is listed as lost")
  has(
    table.concat(f.kept, "\n"),
    "1 comment line(s) above `local DEPS",
    "own comment: says what it kept"
  )
  -- the template's own comment reworded by an older version: the new wording stays, the old one is not duplicated
  put(why_init, (why_text:gsub("%-%- It runs nothing itself%.", "-- Old wording of this line.", 1)))
  p = update.plan(why, NOFMT)
  f = file(p, "TESTS/minimal_init.lua")
  lacks(
    f.after,
    "Old wording of this line.",
    "own comment: a reworded template comment is not brought back"
  )
  has(f.after, "It runs nothing itself.", "own comment: the template's wording is back")

  -- a reason written above a line that differs on purpose has no place in the new render: `--write` holds the file
  -- back (nothing disappears silently); --force-comments writes it anyway
  local function deliberate()
    put(
      why_init,
      (
        why_text:gsub(
          "\nlocal DEPS = [^\n]*",
          "\n" .. why_note .. "\nlocal DEPS = { 'deliberate.nvim' }",
          1
        )
      )
    )
  end
  deliberate()
  p = update.plan(why, NOFMT)
  f = file(p, "TESTS/minimal_init.lua")
  eq(#f.lost_comments, 1, "lost comment: the unplaced run is reported")
  has(f.lost_comments[1], "Hard dependencies only", "lost comment: says which")
  local no_git = function()
    return nil
  end
  local wrote, _, held_lost = update.apply(p, { git = no_git })
  eq(wrote, {}, "lost comment: nothing written")
  eq(#held_lost, 1, "lost comment: the file is held back")
  has(held_lost[1].why, "--force-comments", "lost comment: says how to go on")
  has(
    table.concat(update.lines(p, { held = held_lost }), "\n"),
    "lost comments:",
    "lost comment: shown in the report"
  )
  wrote = update.apply(p, { git = no_git, force_comments = true })
  eq(wrote, { "TESTS/minimal_init.lua" }, "lost comment: --force-comments writes it")
  deliberate()
  eq(
    run({ "init", why, "--update", "--write" }).code,
    1,
    "lost comment: the CLI exits 1 when it holds a file"
  )
  has(slurp(why_init), "deliberate.nvim", "lost comment: the held file is untouched")
  eq(
    run({ "init", why, "--update", "--write", "--force-comments" }).code,
    0,
    "lost comment: --force-comments via the CLI"
  )

  -- this repository's own bootstrap files are the dogfood ones: marked testing:keep-file, so `--update --write` on
  -- the checkout can never replace them with the generated template
  local self_root =
    vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
  local self_plan = update.plan(self_root, NOFMT)
  for _, rel in ipairs({ "scripts/test.sh", "TESTS/minimal_init.lua" }) do
    local sf = file(self_plan, rel)
    eq(sf and sf.changed, false, "dogfood: " .. rel .. " is kept as it is")
    has(
      table.concat(sf and sf.kept or {}, "\n"),
      "testing:keep-file",
      "dogfood: " .. rel .. " says why"
    )
  end

  vim.fn.delete(base, "rf")
end
