-- TESTS/testing/scaffold_spec.lua -- `testing init`: the generated files, their invariants (NEW-39/40/45/49),
-- no overwrite, force, hostile names (SEC-42/46) and a real run of what was generated.
---@diagnostic disable: param-type-mismatch, need-check-nil

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local scaffold = require("testing.scaffold")
  local render = require("testing.scaffold.render")
  local read = require("lib.nvim.fs.read")
  local is_windows = vim.fn.has("win32") == 1

  local tmp = vim.fs.normalize(vim.fn.tempname())
  local function mkproj(dirname, lua_dirs)
    local root = tmp .. "/" .. dirname
    vim.fn.mkdir(root, "p")
    for _, d in ipairs(lua_dirs or {}) do
      vim.fn.mkdir(root .. "/" .. d, "p")
    end
    return root
  end
  local function slurp(path)
    local text = read(path)
    ok(text ~= nil, "cannot read " .. path)
    return text
  end
  local function list_files(root)
    local out = {}
    for _, f in
      ipairs(vim.fs.find(function()
        return true
      end, { path = root, type = "file", limit = 1000 }))
    do
      out[#out + 1] = f:sub(#root + 2)
    end
    table.sort(out)
    return out
  end

  -- ---------------------------------------------------------------- sanitize (SEC-42)

  eq(scaffold.sanitize_plugin("myplug"), "myplug", "a plain name is kept")
  eq(scaffold.sanitize_plugin("my plug"), "my_plug", "a space becomes an underscore")
  eq(scaffold.sanitize_plugin("\27[31mred\27[0m"), "red", "color sequences are removed first")
  eq(scaffold.sanitize_plugin("\27]0;title\7name"), "name", "an OSC sequence is removed first")
  eq(scaffold.sanitize_plugin(".."), nil, "dots only: nothing usable")
  eq(scaffold.sanitize_plugin("../../etc"), "etc", "a traversal keeps no separator")
  eq(scaffold.sanitize_plugin(""), nil, "empty: nothing usable")
  eq(scaffold.sanitize_plugin(42), nil, "not a string: nothing usable")
  eq(#scaffold.sanitize_plugin(("a"):rep(500)) <= 64, true, "the length is bounded")
  for _, hostile in ipairs({
    'x"; rm -rf /; "',
    "a\nb\rc",
    "$(touch pwned)",
    "`id`",
    "a'b",
    "a\\",
    "é\0x",
    "x]]; os.execute('boom') --",
  }) do
    local s = scaffold.sanitize_plugin(hostile)
    ok(
      s == nil or (s:match("^[%w_%-]+$") ~= nil and #s <= 64),
      "hostile name " .. vim.inspect(hostile) .. " is reduced to [%w_-], got " .. vim.inspect(s)
    )
  end

  -- ---------------------------------------------------------------- render (SEC-46)

  -- every quoting must read back as the same text in the language it is for
  for _, v in ipairs({
    "plain",
    "a\\",
    'a"b',
    'a\\"b',
    "line\nbreak",
    "cr\r\n",
    "tab\t",
    "\\n",
    "]]",
  }) do
    local chunk = load("return " .. render.lua_quote(v))
    ok(chunk ~= nil, "lua_quote(" .. vim.inspect(v) .. ") is a valid literal")
    eq(chunk(), v, "lua_quote round-trips " .. vim.inspect(v))
  end
  eq(render.sh_quote("a'b"), [['a'\''b']], "sh_quote closes, escapes and reopens the quote")
  eq(render.sh_quote("$(x)"), "'$(x)'", "sh_quote does not expand")
  eq(render.yaml_quote('a"b\\'), '"a\\"b\\\\"', "yaml_quote escapes the backslash and the quote")

  eq(
    render.render("x=@@A|lua@@", { A = "q\\" }),
    'x="q\\\\"',
    "a trailing backslash cannot close the quote"
  )
  eq(render.render("@@L|lua@@", { L = { "a", "b" } }), '{ "a", "b" }', "a list as a Lua table")
  eq(render.render("@@L|lua@@", { L = {} }), "{}", "an empty list as a Lua table")
  eq(render.render("@@L|sh@@", { L = { "a b", "c" } }), "'a b' 'c'", "a list as shell words")
  eq(
    render.render("@@A|raw@@", { A = "@@B@@" }),
    "@@B@@",
    "a value is not scanned for placeholders again"
  )
  eq(render.render("a\r\nb", {}), "a\nb", "CRLF in a template becomes LF")
  eq(render.render("@@A@@", { A = "ok-1_2.3/x" }), "ok-1_2.3/x", "a bare word may hold [%w._/-]")
  for _, bad in ipairs({ 'a"b', "a b", "a;b", "a$b", "a\nb", "a'b", ("x"):rep(500) }) do
    local out, err = render.render("@@A@@", { A = bad })
    eq(out, nil, "a bare placeholder refuses " .. vim.inspect(bad):sub(1, 20))
    has(err, "placeholder A", "the refusal names the placeholder")
  end
  local missing, merr = render.render("@@NOPE@@", {})
  eq(missing, nil, "an unknown placeholder is an error, never shipped")
  has(merr, "NOPE", "the error names it")
  eq((render.render("@@A|bogus@@", { A = "x" })), nil, "an unknown mode is an error")
  eq((render.render("@@A|lua@@", { A = "x\0y" })), nil, "NUL is refused")
  eq((render.render("@@A|yaml@@", { A = { "x" } })), nil, "yaml takes a string only")

  -- ---------------------------------------------------------------- detection

  eq(
    scaffold.detect_plugin(mkproj("one.nvim", { "lua/one" })),
    "one",
    "the only lua/<name> directory"
  )
  eq(
    scaffold.detect_plugin(mkproj("two.nvim", { "lua/zzz", "lua/two" })),
    "two",
    "the one that matches the repository name"
  )
  eq(
    scaffold.detect_plugin(mkproj("three.nvim", { "lua/aaa", "lua/bbb" })),
    "three",
    "ambiguous: the repository name"
  )
  eq(scaffold.detect_plugin(mkproj("bare-repo")), "bare-repo", "no lua/: the directory name")
  eq(
    scaffold.detect_plugin(mkproj("x.nvim", { "lua/.hidden" })),
    "x",
    "a hidden directory is not a module"
  )

  -- the module root decides, the repository name is only a fallback (buffer-ctx.nvim ships lua/buffer_ctx)
  eq(
    scaffold.detect_plugin(mkproj("buffer-ctx.nvim", { "lua/buffer_ctx" })),
    "buffer_ctx",
    "the module directory, not the repository spelling"
  )
  do
    local r = mkproj("wide-cfg.nvim", { "lua/wide_cfg", "lua/helper_a", "lua/helper_b" })
    eq(
      scaffold.detect_plugin(r),
      "wide_cfg",
      "several directories: the one that matches the name loosely"
    )
  end
  do
    local r = mkproj("odd-name.nvim", { "lua/aaa", "lua/real_mod" })
    vim.fn.writefile({ "return {}" }, r .. "/lua/real_mod/init.lua")
    local name, how = scaffold.detect_plugin(r)
    eq(
      { name, how },
      { "real_mod", "lua-dir" },
      "several directories: the only one with an entry module"
    )
  end
  do
    local r = mkproj("single-file.nvim", { "lua" })
    vim.fn.writefile({ "return {}" }, r .. "/lua/sfile.lua")
    eq(scaffold.detect_plugin(r), "sfile", "a single-file module root (lua/sfile.lua)")
  end
  do
    local r = mkproj("both.nvim", { "lua/x1", "lua/x2" })
    vim.fn.writefile({ "return {}" }, r .. "/lua/x1/init.lua")
    vim.fn.writefile({ "return {}" }, r .. "/lua/x2/init.lua")
    local name, how = scaffold.detect_plugin(r)
    eq(
      { name, how },
      { "both", "directory-name" },
      "two entry modules and no name match: the repository name"
    )
  end

  -- ---------------------------------------------------------------- init: files and invariants

  local root = mkproj("myplug.nvim", { "lua/myplug" })
  local result = scaffold.init(root)
  eq(result.errors, {}, "init has no errors")
  eq(result.skipped, {}, "nothing existed yet")
  eq(result.replaced, {}, "nothing was replaced")
  eq(result.plugin, "myplug", "the plugin name was detected")
  local expected = {
    ".github/workflows/ci.yml",
    ".gitattributes",
    ".luacheckrc",
    ".testing.lua",
    "TESTS/minimal_init.lua",
    "TESTS/myplug/load_spec.lua",
    "scripts/test.sh",
    "stylua.toml",
  }
  local created = vim.deepcopy(result.created)
  table.sort(created)
  table.sort(expected)
  eq(created, expected, "the files that were created")
  eq(list_files(root), expected, "and no other file exists")

  local texts = {}
  for _, rel in ipairs(expected) do
    texts[rel] = slurp(root .. "/" .. rel)
    lacks(texts[rel], "@@", rel .. " has no placeholder left")
    lacks(texts[rel], "\r", rel .. " is LF only")
  end

  -- NEW-40: loud, exit 1, all four places, in the runner and in the minimal init
  local sh = texts["scripts/test.sh"]
  has(sh, "#!/usr/bin/env bash", "test.sh has a shebang")
  has(sh, "set -euo pipefail", "test.sh stops at the first error")
  has(sh, "FAIL_CODE=1", "test.sh fails with exit code 1 (3 for the ci verb)")
  has(sh, '"$DRIVER" conformance .', "test.sh has the conformance subcommand")
  has(sh, '"$DRIVER" surface .', "test.sh has the surface subcommand")
  has(sh, '"$DRIVER" ci ${ci_args[@]+', "test.sh has the ci subcommand")
  has(
    sh,
    "ci_args=(verify --state-dir",
    "test.sh: ci verify reads the proof from the real state directory"
  )
  has(sh, "FAIL_CODE=3", "test.sh: a missing runner is exit 3 for ci")
  has(sh, "nvim is not on PATH", "test.sh names a missing nvim")
  for _, place in ipairs({
    "1. \\$$envname",
    "2. .deps/$name",
    "3. ../$name",
    "4. stdpath('data')/lazy/$name",
  }) do
    has(sh, place, "test.sh names the place " .. place)
  end
  has(sh, "DEPS=('testing.nvim' 'lib.nvim')", "test.sh resolves the runner and the dependencies")
  has(sh, 'run . "$@"', "test.sh hands every argument to the driver")
  has(sh, "myplug-tests", "the run gets a throwaway NVIM_APPNAME")
  has(
    sh,
    "export XDG_STATE_HOME=",
    "a run without child editors does not write into the real state dir"
  )
  has(sh, "export XDG_CACHE_HOME=", "nor into the real cache dir")
  has(sh, "trap 'rm -rf \"$scratch\"' EXIT", "and removes the scratch directory afterwards")
  has(sh, "suite_lock_acquire", "a second full suite in the same checkout is warned about")
  has(sh, "scripts/suite-lock.sh", "...through the lock script of the runner checkout")
  has(sh, '-f "$lock_lib"', "...only when that checkout has it (an older runner runs without)")
  ok(
    not sh:find("\nexec nvim", 1, true),
    "so the script does not `exec` (the trap would never run)"
  )
  local minit = texts["TESTS/minimal_init.lua"]
  has(minit, "os.exit(1)", "minimal_init fails with exit code 1")
  has(
    minit,
    'local DEPS = { "testing.nvim", "lib.nvim" }',
    "minimal_init resolves the runner and the dependencies"
  )
  for _, place in ipairs({ '"$" .. env_name(name)', "../%s", ".deps/%s", "stdpath('data')/lazy/%s" }) do
    has(minit, place, "minimal_init names the place " .. place)
  end

  -- NEW-39/45/49
  has(texts["stylua.toml"], 'line_endings = "Unix"', "stylua.toml matches .gitattributes")
  has(texts[".gitattributes"], "eol=lf", ".gitattributes pins LF")
  has(texts[".luacheckrc"], "busted", ".luacheckrc declares the busted std")

  -- CI: 3 OS, timeout, IR artifact on failure, both checkouts from ci-verified
  local ci = texts[".github/workflows/ci.yml"]
  for _, needle in ipairs({
    "timeout-minutes:",
    "ubuntu-latest",
    "windows-latest",
    "macos-latest",
    "fail-fast: false",
    "actions/upload-artifact",
    "if: failure()",
    "testing-ir.json",
    "scripts/test.sh --json",
    'repository: "WKDSteve/testing.nvim"',
    "path: .deps/testing.nvim",
    'repository: "WKDSteve/lib.nvim"',
    "path: .deps/lib.nvim",
    "set -o pipefail",
  }) do
    has(ci, needle, "ci.yml has " .. needle)
  end
  local _, n_verified = ci:gsub("ref: ci%-verified", "")
  eq(n_verified, 2, "both dependencies are checked out from ci-verified")

  -- the generated Lua is Lua
  for _, rel in ipairs({
    ".testing.lua",
    "TESTS/minimal_init.lua",
    "TESTS/myplug/load_spec.lua",
    ".luacheckrc",
  }) do
    local chunk, cerr = loadfile(root .. "/" .. rel)
    ok(chunk ~= nil, rel .. " is valid Lua: " .. tostring(cerr))
  end
  -- ... and the project config validates against the schema of testing.config.project
  local loaded = require("testing.config.project").load(root)
  eq(loaded.error, nil, ".testing.lua loads")
  eq(loaded.problems, {}, ".testing.lua has no warning")
  eq(loaded.config.plugin, "myplug", ".testing.lua names the plugin")
  eq(loaded.config.deps, { "lib.nvim" }, ".testing.lua names the dependency")
  eq(loaded.config.guards, {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "warn",
    clock = false,
  }, ".testing.lua starts strict, the process/network guard only reports (warn)")
  -- the loader fills in an empty guard_allow by default: look at the file itself
  local raw = assert(loadfile(root .. "/.testing.lua"))()
  eq(
    raw.guard_allow,
    { fs = {}, spawn = {}, network = {} },
    ".testing.lua writes an empty allowlist"
  )
  -- the `strict` profile (LuaLS at zero) is offered as a comment: the file has no `ci` section as it is (the derived
  -- pipeline stays), and uncommenting the block gives a section that names all three profiles
  eq(raw.ci, nil, ".testing.lua has no ci section of its own (the pipeline is derived)")
  do
    local file_lines = vim.fn.readfile(root .. "/.testing.lua")
    local NL = string.char(10)
    local text = table.concat(file_lines, NL)
    ok(
      text:find('strict = { "full", "luals" }', 1, true) ~= nil,
      ".testing.lua offers the strict profile"
    )
    local lines = {}
    for _, line in ipairs(file_lines) do
      lines[#lines + 1] = (
        line:gsub("^  %-%- (ci = {)", "  %1"):gsub("^  %-%-   ", "    "):gsub("^  %-%- }", "  }")
      )
    end
    local uncommented = assert(load(table.concat(lines, NL), "=.testing.lua"))()
    eq(uncommented.ci, {
      default = "full",
      profiles = {
        fast = { "stylua", "luacheck" },
        full = { "fast", "suite" },
        strict = { "full", "luals" },
      },
    }, "uncommented, the block is a ci section with fast, full and strict")
  end
  if not is_windows then
    local stat = vim.uv.fs_stat(root .. "/scripts/test.sh")
    ok(bit.band(stat.mode, tonumber("100", 8)) ~= 0, "scripts/test.sh is executable")
  end

  -- ---------------------------------------------------------------- no overwrite, force

  vim.fn.writefile({ "-- mine" }, root .. "/.testing.lua")
  local again = scaffold.init(root)
  eq(again.errors, {}, "a second init has no errors")
  eq(again.created, {}, "a second init creates nothing")
  eq(again.replaced, {}, "a second init replaces nothing")
  local skipped = vim.deepcopy(again.skipped)
  table.sort(skipped)
  eq(skipped, expected, "every existing file is reported as skipped")
  eq(slurp(root .. "/.testing.lua"), "-- mine\n", "the user's file is untouched")

  local forced = scaffold.init(root, { force = true })
  eq(forced.errors, {}, "force has no errors")
  eq(forced.skipped, {}, "force skips nothing")
  eq(#forced.replaced, #expected, "force replaces every file")
  eq(slurp(root .. "/.testing.lua"), texts[".testing.lua"], "force restores the template")

  -- a directory where a file belongs: an error for that file, the others are still written
  local blocked = mkproj("blocked.nvim", { "lua/blocked", ".testing.lua" })
  local b = scaffold.init(blocked, { force = true })
  eq(#b.errors, 1, "one error")
  has(b.errors[1], ".testing.lua", "the error names the path")
  eq(#b.created, #expected - 1, "the other files were created")

  -- ---------------------------------------------------------------- hostile input

  local function assert_confined(proj, res, label)
    for _, rel in ipairs(res.created) do
      ok(
        not rel:find("..", 1, true) and rel:sub(1, 1) ~= "/",
        label .. ": created path stays inside: " .. rel
      )
    end
    for _, f in ipairs(list_files(proj)) do
      ok(not f:find("..", 1, true), label .. ": nothing escaped")
    end
  end

  local evil = 'x"\n]]; os.execute("boom") --'
  local p1 = mkproj("evil1.nvim")
  local r1 = scaffold.init(p1, { plugin = evil })
  eq(r1.errors, {}, "a hostile plugin name is sanitized, not refused")
  ok(r1.plugin:match("^[%w_%-]+$") ~= nil, "the used name is plain: " .. r1.plugin)
  assert_confined(p1, r1, "evil name")
  for _, rel in ipairs(r1.created) do
    if rel:match("%.lua$") then
      local chunk, cerr = loadfile(p1 .. "/" .. rel)
      ok(chunk ~= nil, "evil name: " .. rel .. " is still valid Lua: " .. tostring(cerr))
    end
  end
  local cfg = require("testing.config.project").load(p1)
  eq(cfg.error, nil, "evil name: .testing.lua loads")
  eq(cfg.problems, {}, "evil name: .testing.lua validates")
  lacks(slurp(p1 .. "/.testing.lua"), "os.execute", "the payload is not in the config")
  lacks(slurp(p1 .. "/scripts/test.sh"), "os.execute", "the payload is not in the shell script")

  local p2 = mkproj("evil2.nvim")
  local r2 = scaffold.init(p2, { plugin = "../../escape" })
  eq(r2.errors, {}, "a traversal in the name is sanitized")
  assert_confined(p2, r2, "traversal")
  eq(vim.uv.fs_stat(tmp .. "/escape"), nil, "nothing was written next to the project")

  local p3 = mkproj("evil3.nvim")
  local r3 = scaffold.init(p3, { plugin = "..." })
  eq(#r3.errors, 1, "a name without a usable character is an error")
  eq(list_files(p3), {}, "and nothing was created")

  local p4 = mkproj("evil4.nvim")
  for _, bad in ipairs({ { 'x"; echo' }, { "a/b" }, { ".." }, { "" }, "lib.nvim" }) do
    local r = scaffold.init(p4, { deps = bad })
    eq(#r.errors, 1, "invalid deps " .. vim.inspect(bad) .. " is an error")
    eq(list_files(p4), {}, "invalid deps " .. vim.inspect(bad) .. ": nothing was created")
  end
  local ro = scaffold.init(p4, { owner = 'a"b' })
  eq(#ro.errors, 1, "an invalid owner is an error")
  eq(list_files(p4), {}, "an invalid owner: nothing was created")

  -- a hostile directory name (legal on every platform's file system) as the derived name
  local p5 = mkproj("a b;x$y'z")
  local r5 = scaffold.init(p5)
  eq(r5.errors, {}, "a hostile directory name derives a sanitized name")
  ok(r5.plugin:match("^[%w_%-]+$") ~= nil, "the derived name is plain: " .. tostring(r5.plugin))
  has(
    slurp(p5 .. "/scripts/test.sh"),
    r5.plugin .. "-tests",
    "the name reached the script as a plain word"
  )

  -- more dependencies and another owner
  local p6 = mkproj("deps.nvim", { "lua/deps" })
  local r6 = scaffold.init(p6, {
    deps = { "lib.nvim", "runtime-analysis.nvim", "lib.nvim", "testing.nvim" },
    owner = "someone",
  })
  eq(r6.errors, {}, "several dependencies")
  has(
    slurp(p6 .. "/scripts/test.sh"),
    "DEPS=('testing.nvim' 'lib.nvim' 'runtime-analysis.nvim')",
    "deduplicated, runner first"
  )
  has(
    slurp(p6 .. "/.github/workflows/ci.yml"),
    'repository: "someone/runtime-analysis.nvim"',
    "the owner is used"
  )
  eq(
    require("testing.config.project").load(p6).config.deps,
    { "lib.nvim", "runtime-analysis.nvim" },
    "the config lists the dependencies without the runner"
  )

  -- never raises
  eq(#scaffold.init(nil).errors, 1, "no root: an error, no raise")
  eq(#scaffold.init(tmp .. "/does-not-exist").errors, 1, "a missing root: an error, no raise")
  eq(
    #scaffold.init(tmp .. "/myplug.nvim/.testing.lua").errors,
    1,
    "a file as root: an error, no raise"
  )

  -- ---------------------------------------------------------------- the generated minimal_init, run for real

  local function run(argv, cwd, env)
    local full_env = vim.tbl_extend("force", {
      NVIM_APPNAME = "testing-scaffold-spec", -- its stdpath('data') holds no checkout
      LIB_NVIM_DIR = "",
      TESTING_NVIM_DIR = "",
    }, env or {})
    return vim.system(argv, { cwd = cwd, env = full_env, text = true, timeout = 60000 }):wait()
  end
  local nvim = vim.v.progpath
  local res = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root
  )
  eq(res.code, 1, "minimal_init without dependencies exits 1")
  for _, place in ipairs({
    "$TESTING_NVIM_DIR",
    ".deps/testing.nvim",
    "../testing.nvim",
    "stdpath('data')/lazy/testing.nvim",
    "$LIB_NVIM_DIR",
    ".deps/lib.nvim",
    "../lib.nvim",
    "stdpath('data')/lazy/lib.nvim",
  }) do
    has(res.stderr, place, "minimal_init names " .. place)
  end

  local fake = tmp .. "/fake"
  vim.fn.mkdir(fake .. "/lib/lua/lib/nvim", "p")
  vim.fn.mkdir(fake .. "/tst/lua/testing", "p")
  local res_ok = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root,
    { LIB_NVIM_DIR = fake .. "/lib", TESTING_NVIM_DIR = fake .. "/tst" }
  )
  eq(res_ok.code, 0, "minimal_init with every dependency exits 0: " .. tostring(res_ok.stderr))
  local res_bad = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root,
    { LIB_NVIM_DIR = fake .. "/nope", TESTING_NVIM_DIR = fake .. "/tst" }
  )
  eq(res_bad.code, 1, "an override that is set but wrong is never skipped")
  has(res_bad.stderr, "$LIB_NVIM_DIR", "and it is named")

  -- ---------------------------------------------------------------- the generated test.sh, run for real

  local bash
  if is_windows then
    -- PATH's bash may be WSL's, which cannot run this; the one that ships with git is the one CI uses.
    local git = vim.fn.exepath("git")
    local candidate = git ~= ""
        and vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(git))) .. "/bin/bash.exe"
      or ""
    bash = vim.uv.fs_stat(candidate) and candidate or vim.fn.exepath("bash")
  else
    bash = vim.fn.exepath("bash")
  end
  ok(bash ~= "", "bash is available (scripts/test.sh needs it, here and in CI)")
  local path_sep = is_windows and ";" or ":"
  local env_path =
    { TESTING_AGENT = "0", PATH = vim.fs.dirname(nvim) .. path_sep .. (vim.env.PATH or "") }

  local run_proj = mkproj("runme.nvim", { "lua/runme" })
  vim.fn.writefile({ "return {}" }, run_proj .. "/lua/runme/init.lua")
  eq(scaffold.init(run_proj).errors, {}, "init for the real run")

  local missing_res = run({ bash, "scripts/test.sh" }, run_proj, env_path)
  eq(missing_res.code, 1, "test.sh without the runner exits 1, not 0 and not a hang")
  for _, place in ipairs({
    "$TESTING_NVIM_DIR",
    ".deps/testing.nvim",
    "../testing.nvim",
    "stdpath('data')/lazy/testing.nvim",
  }) do
    has(missing_res.stderr, place, "test.sh names " .. place)
  end

  local self_dir = require("testing.deps").self_dir()
  local lib = require("testing.deps").resolve("lib.nvim", self_dir)
  ok(lib ~= nil, "lib.nvim resolves for the real run")
  local deps_env =
    vim.tbl_extend("force", env_path, { TESTING_NVIM_DIR = self_dir, LIB_NVIM_DIR = lib.dir })
  local green = run({ bash, "scripts/test.sh" }, run_proj, deps_env)
  eq(
    green.code,
    0,
    "the generated setup runs green: " .. tostring(green.stdout) .. tostring(green.stderr)
  )
  has(green.stdout, "load_spec.lua", "and it ran the generated spec")

  -- an NVIM_APPNAME the developer exported (run() sets one) must not become the run's app name: the run would read
  -- and write that app's real stdpath("data")
  vim.fn.writefile({
    "return function(H)",
    '  H.eq(vim.env.NVIM_APPNAME, "runme-tests", "the throwaway app name, not the inherited one")',
    "end",
  }, run_proj .. "/TESTS/appname_spec.lua")
  local appname = run(
    { bash, "scripts/test.sh", "--file", "appname" },
    run_proj,
    vim.tbl_extend("force", deps_env, { NVIM_APPNAME = "developer-config" })
  )
  eq(
    appname.code,
    0,
    "an exported NVIM_APPNAME is replaced by the throwaway one: "
      .. tostring(appname.stdout)
      .. tostring(appname.stderr)
  )
  vim.fn.delete(run_proj .. "/TESTS/appname_spec.lua")

  -- `scripts/test.sh ci`: the generated project needs no ci section, its pipeline is derived; without the runner the
  -- ci verb is exit 3 (infrastructure), the plain run stays exit 1
  local ci_list = run({ bash, "scripts/test.sh", "ci", "list" }, run_proj, deps_env)
  eq(ci_list.code, 0, "test.sh ci list: exit 0: " .. tostring(ci_list.stderr))
  has(
    ci_list.stdout,
    "derived: stylua",
    "test.sh ci list: the derived pipeline of the generated project"
  )
  local ci_missing = run({ bash, "scripts/test.sh", "ci", "list" }, run_proj, env_path)
  eq(ci_missing.code, 3, "test.sh ci without the runner: exit 3")

  -- an nvim that fails when asked for stdpath("state") is infrastructure too: exit 3 and the message, not a silent 1
  local broken_dir = vim.fn.tempname() .. "-broken-nvim"
  vim.fn.mkdir(broken_dir, "p")
  vim.fn.writefile({ "#!/usr/bin/env bash", "exit 1" }, broken_dir .. "/nvim")
  vim.uv.fs_chmod(broken_dir .. "/nvim", tonumber("755", 8))
  local broken_env =
    vim.tbl_extend("force", deps_env, { PATH = broken_dir .. path_sep .. deps_env.PATH })
  local ci_broken = run({ bash, "scripts/test.sh", "ci", "list" }, run_proj, broken_env)
  eq(ci_broken.code, 3, "test.sh ci with an nvim that fails: exit 3 (" .. ci_broken.stderr .. ")")
  has(
    ci_broken.stderr,
    "cannot ask nvim for stdpath",
    "test.sh ci with an nvim that fails: says why"
  )
  vim.fn.delete(broken_dir, "rf")

  -- the pipeline's document lands in the developer's real state directory (not the throwaway one, which is removed)
  local real_state = vim.fn.tempname() .. "-real-state"
  local ci_run = run(
    { bash, "scripts/test.sh", "ci", "--step=suite" },
    run_proj,
    vim.tbl_extend("force", deps_env, { XDG_STATE_HOME = real_state })
  )
  eq(ci_run.code, 0, "test.sh ci --step=suite: green: " .. ci_run.stdout .. ci_run.stderr)
  ok(
    #vim.fn.globpath(real_state, "**/ci.json", true, true) > 0,
    "test.sh ci: the document is below the real state directory"
  )
  local ci_logs = vim.fn.globpath(real_state, "**/runlog.jsonl", true, true)
  eq(#ci_logs, 1, "test.sh ci: the log of the runs is below the real state directory")
  local ci_kinds = {}
  for _, e in ipairs((require("testing.runlog").read(ci_logs[1]))) do
    ci_kinds[e.kind] = true
  end
  ok(ci_kinds.ci, "test.sh ci: the run of the pipeline is in the log")
  vim.fn.delete(real_state, "rf")

  -- the plain run's history lands in the developer's real state directory too: the spec process gets a throwaway one,
  -- the real one goes to the runner as `--state-dir` (the editor's test explorer reads it there)
  local run_state = vim.fn.tempname() .. "-run-state"
  local plain_run = run(
    { bash, "scripts/test.sh" },
    run_proj,
    vim.tbl_extend("force", deps_env, { XDG_STATE_HOME = run_state })
  )
  eq(plain_run.code, 0, "test.sh: green: " .. plain_run.stdout .. plain_run.stderr)
  ok(
    #vim.fn.globpath(run_state, "**/runs.jsonl", true, true) > 0,
    "test.sh: the run history is below the real state directory"
  )
  -- the file the editor reads the last run from: `testing.history.dir` of the project, under the real state directory
  local last_files = vim.fn.globpath(run_state, "**/last.json", true, true)
  eq(#last_files, 1, "test.sh: one last.json below the real state directory")
  local last_ok, last_doc =
    pcall(vim.json.decode, table.concat(vim.fn.readfile(last_files[1]), "\n"))
  ok(last_ok and type(last_doc) == "table", "test.sh: last.json is a document")
  -- and the log of the runs, for `testing history`
  local logs = vim.fn.globpath(run_state, "**/runlog.jsonl", true, true)
  eq(#logs, 1, "test.sh: the log of the runs is below the real state directory")
  local logged = require("testing.runlog").read(logs[1])
  eq(#logged, 1, "test.sh: one line per run")
  eq(
    { logged[1].kind, logged[1].scope, logged[1].verdict },
    { "run", "full", "green" },
    "test.sh: what ran"
  )
  -- a run of a part of the suite says so: the statistics count whole runs only
  local part_state = vim.fn.tempname() .. "-part-state"
  local part_spec = run_proj .. "/TESTS/second_spec.lua"
  vim.fn.writefile({ "return function(H) H.ok(true, 'second') end" }, part_spec)
  local part_run = run(
    { bash, "scripts/test.sh", "--file", "second_spec" },
    run_proj,
    vim.tbl_extend("force", deps_env, { XDG_STATE_HOME = part_state })
  )
  vim.fn.delete(part_spec)
  eq(part_run.code, 0, "test.sh --file: green: " .. part_run.stdout .. part_run.stderr)
  local part_log =
    require("testing.runlog").read(vim.fn.globpath(part_state, "**/runlog.jsonl", true, true)[1])
  eq(part_log[1].scope, "partial", "test.sh --file: the log says it was a part of the suite")
  vim.fn.delete(part_state, "rf")
  vim.fn.delete(run_state, "rf")
  -- an `--state-dir` of the caller wins over the real one
  local own_state = vim.fn.tempname() .. "-own-state"
  local own_run = run(
    { bash, "scripts/test.sh", "--state-dir", own_state },
    run_proj,
    vim.tbl_extend("force", deps_env, { XDG_STATE_HOME = run_state })
  )
  eq(own_run.code, 0, "test.sh --state-dir: green: " .. own_run.stdout .. own_run.stderr)
  ok(
    #vim.fn.globpath(own_state, "**/runs.jsonl", true, true) > 0,
    "test.sh: the caller's --state-dir wins"
  )
  ok(
    #vim.fn.globpath(run_state, "**/runs.jsonl", true, true) == 0,
    "and the real one is left alone"
  )
  vim.fn.delete(own_state, "rf")
  vim.fn.delete(run_state, "rf")

  -- the generated spec can fail: break the module and the verdict changes
  vim.fn.writefile({ 'error("module is broken")' }, run_proj .. "/lua/runme/init.lua")
  local red = run({ bash, "scripts/test.sh" }, run_proj, deps_env)
  eq(red.code, 1, "a broken module makes the generated setup exit 1")
  lacks(red.stdout, "TESTING_OK", "and no green sentinel is printed")

  -- ---------------------------------------------------------------- pieces the migration reuses

  -- the run arguments baked into test.sh: empty for `init` (byte-identical to before), a vetted block otherwise
  local vars = assert(scaffold.build_vars("pl", { "lib.nvim" }, "WKDSteve"))
  eq(vars.RUN_ARGS, "", "build_vars: no extra run arguments by default")
  eq(vars.ALL_DEPS, { "testing.nvim", "lib.nvim" }, "build_vars: the runner comes first")
  eq(vars.PLUGIN, "pl", "build_vars: the plugin")
  local plain_sh = assert(scaffold.render_template("test.sh.tpl", vars))
  has(plain_sh, 'run . "$@"', "render_template: no run arguments leave no gap")
  lacks(plain_sh, "run .  ", "render_template: and no double space")
  local sentinel_vars =
    assert(scaffold.build_vars("pl", {}, "WKDSteve", { RUN_ARGS = " --sentinel 'PL_OK'" }))
  has(
    assert(scaffold.render_template("test.sh.tpl", sentinel_vars)),
    "run . --sentinel 'PL_OK' \"$@\"",
    "render_template: extra run arguments land before the user's arguments"
  )
  local no_tpl, no_tpl_err = scaffold.render_template("nope.tpl", vars)
  eq(no_tpl, nil, "render_template: an unknown template is an error")
  has(no_tpl_err, "cannot read template", "with the reason")
  local lost, lost_err = scaffold.render_template("test.sh.tpl", { PLUGIN = "x" })
  eq(lost, nil, "render_template: a missing placeholder value is an error")
  has(lost_err, "no value for placeholder", "that names the problem")

  -- dep_step: the checkout step of one dependency, in the layout of the job
  local step = assert(scaffold.dep_step("lib.nvim"))
  has(step, "path: .deps/lib.nvim\n", "dep_step: .deps/ by default")
  has(step, 'repository: "WKDSteve/lib.nvim"', "dep_step: from the owner's repository")
  has(step, "ref: ci-verified", "dep_step: from the verified branch")
  has(
    assert(scaffold.dep_step("ui.nvim", "someone", "")),
    "path: ui.nvim\n",
    "dep_step: an empty prefix is a sibling"
  )
  has(
    assert(scaffold.dep_step("ui.nvim", "someone", "")),
    '"someone/ui.nvim"',
    "dep_step: with the owner given"
  )
  for _, bad_prefix in ipairs({ "../", "/abs/", "a b/", "x;y/", "$(id)/", 42 }) do
    local t, e = scaffold.dep_step("lib.nvim", "WKDSteve", bad_prefix)
    eq(t, nil, "dep_step refuses the prefix " .. vim.inspect(bad_prefix))
    eq(e, "invalid path prefix", "with a reason")
  end
  eq((scaffold.dep_step("../evil")), nil, "dep_step refuses a path as a dependency name")
  eq((scaffold.dep_step("lib.nvim", "bad owner")), nil, "dep_step refuses an invalid owner")

  -- the artifact step of the migration is plain data too
  local art =
    assert(scaffold.render_template("ci_artifact_step.yml.tpl", { SUFFIX = "-${{ matrix.os }}" }))
  has(art, "name: testing-ir-${{ matrix.os }}", "the artifact name carries the suffix")
  has(art, "if: failure()", "it is uploaded when the job fails")
  has(art, "path: ${{ runner.temp }}/testing-ir.json", "the IR is what it uploads")

  -- ---------------------------------------------------------------- --workflow: two kinds of runner, a macOS leg
  do
    local CI_FILE = ".github/workflows/ci.yml"

    ---The two lists of the matrix expression: what a push runs, what every other event runs.
    ---@param text string
    ---@return table[] on_push
    ---@return table[] otherwise
    local function legs(text)
      local pushed, other = text:match("github%.event_name == 'push' && '(%[.-%])' || '(%[.-%])'")
      ok(
        pushed ~= nil and other ~= nil,
        "the matrix has a list for a push and one for any other event"
      )
      return vim.json.decode(pushed), vim.json.decode(other)
    end
    ---@param list table[]
    ---@param name string
    ---@return table|nil
    local function leg(list, name)
      for _, l in ipairs(list) do
        if l.name == name then
          return l
        end
      end
    end
    ---@param l table
    ---@return boolean
    local function is_self_hosted(l)
      return type(l["runs-on"]) == "table" and vim.tbl_contains(l["runs-on"], "self-hosted")
    end

    -- an existing repository: its other files stay, and its dependencies are its own
    local wf_root = mkproj("wf.nvim", { "lua/wf" })
    eq(scaffold.init(wf_root).errors, {}, "workflow: the setup exists first")
    local test_sh = slurp(wf_root .. "/scripts/test.sh")
    local patched =
      test_sh:gsub("DEPS=%(([^)\n]*)%)", "DEPS=('testing.nvim' 'lib.nvim' 'ui.nvim')", 1)
    local fh = assert(io.open(wf_root .. "/scripts/test.sh", "wb"))
    fh:write(patched)
    fh:close()
    local old_ci = slurp(wf_root .. "/" .. CI_FILE)
    local kept = scaffold.init(wf_root, { workflow = "two-runner" })
    eq(kept.errors, {}, "workflow: no error when the file exists")
    eq(kept.skipped, { CI_FILE }, "workflow: an existing ci.yml is kept without force")
    eq(slurp(wf_root .. "/" .. CI_FILE), old_ci, "workflow: ... unchanged")
    has(
      table.concat(scaffold.workflow_next_steps("two-runner", kept), "\n"),
      "--force replaces this one file only",
      "workflow: ... and it says how to replace it"
    )

    local dot_before = slurp(wf_root .. "/.testing.lua")
    local wf_forced = scaffold.init(wf_root, { workflow = "two-runner", force = true })
    eq(wf_forced.errors, {}, "workflow: force works")
    eq(wf_forced.replaced, { CI_FILE }, "workflow: force replaces the workflow and nothing else")
    eq(slurp(wf_root .. "/scripts/test.sh"), patched, "workflow: test.sh is untouched")
    eq(slurp(wf_root .. "/.testing.lua"), dot_before, "workflow: .testing.lua is untouched")
    eq(
      wf_forced.workflow_deps_from,
      "scripts/test.sh",
      "workflow: the dependencies were read from test.sh"
    )
    eq(
      wf_forced.workflow_deps,
      { "testing.nvim", "lib.nvim", "ui.nvim" },
      "workflow: the runner and the repository's own dependencies"
    )

    local public = slurp(wf_root .. "/" .. CI_FILE)
    lacks(public, "@@", "two-runner: no placeholder left")
    lacks(public, "\r", "two-runner: LF only")
    has(public, 'repository: "WKDSteve/ui.nvim"', "two-runner: the dependency is checked out")
    has(public, "path: .deps/ui.nvim", "two-runner: ... where scripts/test.sh looks")
    has(public, "scripts/test.sh ci @steps", "two-runner: runs what `testing init` writes")
    lacks(public, "scripts/ci.sh", "two-runner: not a shim that `testing init` does not write")
    has(public, "persist-credentials: false", "two-runner: a checkout keeps no credentials")
    has(public, "fail-fast: false", "two-runner: a red macOS leg does not cancel the local one")
    has(public, "pull_request:", "two-runner: pull requests run")
    lacks(public, "workflow_dispatch", "two-runner: public needs no run by hand")
    -- every action reaches the maintainer's machine: pinned by commit, as in the repositories it comes from
    for line in public:gmatch("uses: ([^\n]+)") do
      ok(line:match("@%x%x%x%x%x%x%x+ # v%d") ~= nil, "two-runner: pinned by commit: " .. line)
    end

    local on_push, otherwise = legs(public)
    local mac = leg(on_push, "macos")
    ok(mac ~= nil, "two-runner: a push has a macOS leg")
    eq(mac["runs-on"], "macos-latest", "two-runner: ... on a GitHub-hosted runner")
    eq(mac.hosted, true, "two-runner: ... which gets its tools from the workflow")
    eq(mac.steps, "--step=suite", "two-runner: ... and runs what depends on the platform")
    ok(is_self_hosted(leg(on_push, "windows")), "two-runner: a push uses the local runner")
    eq(leg(on_push, "windows").hosted, false, "two-runner: ... with the tools on its PATH")
    eq(leg(on_push, "windows").steps, "", "two-runner: ... and the whole profile")
    for _, l in ipairs(otherwise) do
      ok(not is_self_hosted(l), "two-runner: no other event reaches the local runner: " .. l.name)
    end
    ok(leg(otherwise, "macos") ~= nil, "two-runner: a pull request runs on macOS too")
    eq(leg(otherwise, "ubuntu").steps, "", "two-runner: ubuntu carries the whole profile")

    -- the runner guard is a hook in the `.env` of a local runner: nothing in the workflow reaches it, and a hosted leg
    -- names no label of a local runner
    local guard = require("testing.ci.runner_guard")
    lacks(public, guard.HOOK_VAR, "two-runner: the workflow does not touch the guard's hook")
    for _, l in ipairs(on_push) do
      eq(l.hosted, not is_self_hosted(l), "two-runner: hosted means no local runner: " .. l.name)
    end

    -- the steps of the hosted legs exist in what `testing init` set up (an unknown step is a usage error)
    local section = assert(
      require("testing.ci.derive").section(
        wf_root,
        require("testing.config.project").load(wf_root).config
      )
    )
    local derived = table.concat(section.profiles.full, " ")
    has(derived, "suite", "two-runner: --step=suite exists in the derived pipeline")
    lacks(derived, "conformance", "two-runner: ... and conformance does not, without a gate")

    -- private: macOS only by hand, and the file says why
    local priv_root = mkproj("priv.nvim", { "lua/priv" })
    local priv_result = scaffold.init(priv_root, { workflow = "two-runner-private" })
    eq(priv_result.errors, {}, "two-runner-private: no error")
    eq(priv_result.created, { CI_FILE }, "two-runner-private: only the workflow is written")
    eq(priv_result.workflow_deps_from, nil, "two-runner-private: no file names dependencies")
    eq(
      priv_result.workflow_deps,
      { "testing.nvim", "lib.nvim" },
      "two-runner-private: ... so the default"
    )
    local private = slurp(priv_root .. "/" .. CI_FILE)
    lacks(private, "@@", "two-runner-private: no placeholder left")
    has(private, "workflow_dispatch:", "two-runner-private: macOS runs by hand")
    has(private, "gh workflow run ci.yml", "two-runner-private: ... and the file says how")
    has(private, "0.062 USD per minute", "two-runner-private: ... and why not on every push")
    lacks(private, "\n  pull_request:", "two-runner-private: no paid pull-request legs")
    has(
      private,
      "${{ github.event_name }}-${{ github.ref }}",
      "two-runner-private: a push does not cancel the paid run by hand, nor it a push"
    )
    local p_push, p_other = legs(private)
    eq(#p_push, 1, "two-runner-private: a push has one leg")
    ok(is_self_hosted(p_push[1]), "two-runner-private: ... on the local runner")
    eq(#p_other, 1, "two-runner-private: the run by hand has one leg")
    eq(p_other[1].name, "macos", "two-runner-private: ... macOS")
    eq(p_other[1]["runs-on"], "macos-latest", "two-runner-private: ... GitHub-hosted")
    has(
      table.concat(scaffold.workflow_next_steps("two-runner-private", priv_result), "\n"),
      "gh workflow run ci.yml",
      "two-runner-private: the report names the run by hand"
    )

    -- what cannot be right writes nothing
    local bad_root = mkproj("bad.nvim", { "lua/bad" })
    local unknown = scaffold.init(bad_root, { workflow = "nope" })
    has(unknown.errors[1], "unknown workflow", "workflow: an unknown kind is an error")
    has(unknown.errors[1], "two-runner-private", "workflow: ... that names the kinds")
    eq(list_files(bad_root), {}, "workflow: ... and writes nothing")
    has(
      scaffold.init(bad_root, { workflow = "two-runner", hooks = true }).errors[1],
      "exclude each other",
      "workflow: not together with hooks"
    )
    vim.fn.mkdir(bad_root .. "/scripts", "p")
    local bad_sh = assert(io.open(bad_root .. "/scripts/test.sh", "wb"))
    bad_sh:write("#!/bin/sh\nDEPS=('testing.nvim' '$(evil)')\n")
    bad_sh:close()
    local risky = scaffold.init(bad_root, { workflow = "two-runner" })
    has(risky.errors[1], "names a dependency", "workflow: a dependency it cannot read is an error")
    eq(risky.created, {}, "workflow: ... a checkout must not vanish without a word")

    -- the command line
    local cli = require("testing.cli")
    local function init_cli(args)
      local out, err = {}, {}
      local code = cli.main(vim.list_extend({ "init" }, args), {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
      })
      return code, table.concat(out, "\n"), table.concat(err, "\n")
    end
    local cli_root = mkproj("clip.nvim", { "lua/clip" })
    local code, out = init_cli({ cli_root, "--workflow=two-runner" })
    eq(code, 0, "cli: --workflow is exit 0")
    has(out, "created: " .. CI_FILE, "cli: it says what it created")
    has(out, "runner-guard install", "cli: and what is left to do")
    eq(list_files(cli_root), { CI_FILE }, "cli: only the workflow")
    local bad_code, _, bad_err = init_cli({ cli_root, "--workflow=nope" })
    eq(bad_code, 2, "cli: an unknown kind is a usage error")
    has(bad_err, "unknown workflow", "cli: ... and says so")
    eq(init_cli({ cli_root, "--workflow=two-runner", "--hooks" }), 2, "cli: not with --hooks")
    eq(init_cli({ cli_root, "--workflow=two-runner", "--update" }), 2, "cli: not with --update")
    eq(init_cli({ cli_root, "--workflow=two-runner", "--plugin=x" }), 2, "cli: not with --plugin")
  end

  vim.fn.delete(tmp, "rf")
end
