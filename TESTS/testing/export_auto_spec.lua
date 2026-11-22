-- TESTS/testing/export_auto_spec.lua -- the export after a final check (testing.export.auto): armed only by
-- TESTING_EXPORT_DIR and never under CI, written after `ci commit` without --quick and after `ci land`, never for
-- --quick, --help or --repos-root, and a failing export never changes the run: one line says what became of it.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end

  local auto = require("testing.export.auto")

  -- from_env: what the entry arms
  local function env(t)
    return function(name)
      return t[name]
    end
  end
  eq(auto.from_env(env({})), nil, "from_env: off without TESTING_EXPORT_DIR")
  eq(auto.from_env(env({ TESTING_EXPORT_DIR = "" })), nil, "from_env: an empty value is off")
  eq(
    auto.from_env(env({ TESTING_EXPORT_DIR = "C:/x", CI = "true" })),
    nil,
    "from_env: never under a CI service"
  )
  eq(
    auto.from_env(env({ TESTING_EXPORT_DIR = "C:/x", REPOS_DIR = "E:/repos" })),
    { dir = "C:/x", repos_root = "E:/repos" },
    "from_env: REPOS_DIR is the repositories root"
  )
  eq(
    auto.from_env(env({
      TESTING_EXPORT_DIR = "C:/x",
      REPOS_DIR = "E:/repos",
      TESTING_EXPORT_REPOS_ROOT = "F:/r",
    })),
    { dir = "C:/x", repos_root = "F:/r" },
    "from_env: TESTING_EXPORT_REPOS_ROOT wins"
  )

  -- final_root: which command lines are a final check
  local root = vim.fs.normalize(vim.fn.getcwd())
  eq(auto.final_root("commit", { "HEAD", "--base=@{upstream}" }), root, "final: a full ci commit")
  eq(auto.final_root("commit", { "HEAD", "--quick" }), nil, "final: not --quick")
  eq(auto.final_root("commit", { "--help" }), nil, "final: not --help")
  eq(
    auto.final_root("commit", { "--repos-root=x", "--since=1.day.ago" }),
    nil,
    "final: not --repos-root"
  )
  eq(auto.final_root("land", {}), root, "final: ci land")
  eq(auto.final_root("commit", { "--bogus" }), nil, "final: a command line that does not parse")

  -- after: the export folder's main, stubbed
  local saved = package.loaded["testing.export.folder"]
  local calls = {}
  local result = { code = 0 }
  package.loaded["testing.export.folder"] = {
    main = function(argv, sv)
      calls[#calls + 1] = { argv = argv, state_dir = sv.state_dir }
      if result.raise then
        error("boom")
      end
      if result.code == 0 then
        sv.out("export: 3 repositories to C:/x (1 written, 2 unchanged, 0 removed)")
      else
        sv.err("another export is writing")
      end
      return result.code
    end,
  }
  local lines = {}
  local sv = {
    out = function(l)
      lines[#lines + 1] = l
    end,
    state_dir = "S",
    export_after = { dir = "C:/x", repos_root = "E:/repos" },
  }

  eq(auto.after("commit", { "HEAD", "--base=@{upstream}" }, sv), true, "after: written")
  eq(
    calls[1],
    { argv = { "--out", "C:/x", "--repos-root=E:/repos" }, state_dir = "S" },
    "after: testing export --out <dir> --repos-root=<root>, the run's state"
  )
  has(
    lines[1],
    "export (TESTING_EXPORT_DIR): export: 3 repositories",
    "after: one line, the summary"
  )

  -- `scripts/test.sh` names the real state with --state-dir on the command line: the export reads that one, not the
  -- throwaway stdpath("state") (an export from there is empty and replaces the full one)
  eq(
    auto.after("commit", { "--state-dir=D:/real/state", "HEAD" }, sv),
    true,
    "after: with --state-dir"
  )
  eq(
    calls[2].state_dir,
    "D:/real/state",
    "after: the state of the command line wins over the services'"
  )

  eq(auto.after("commit", { "HEAD", "--quick" }, sv), nil, "after: nothing for --quick")
  eq(#calls, 2, "after: --quick does not export")

  sv.export_after = { dir = "C:/x" }
  auto.after("land", {}, sv)
  eq(
    calls[3].argv[3],
    "--repos-root=" .. vim.fs.dirname(root),
    "after: without a root, the folder above the repository"
  )

  result.code = 2
  lines = {}
  eq(auto.after("land", {}, sv), false, "after: not written")
  has(lines[1], "not written (another export is writing)", "after: ... says why")
  has(lines[1], "the verdict above stands", "after: ... and that the run's verdict stands")

  result.raise = true
  lines = {}
  eq(auto.after("land", {}, sv), false, "after: an error in the export never raises")
  has(lines[1], "boom", "after: ... and is named")

  sv.export_after = nil
  eq(auto.after("land", {}, sv), nil, "after: nothing armed, nothing written (a library call)")
  package.loaded["testing.export.folder"] = saved

  -- the dispatch of `testing ci`: commit and land call it (a red run too)
  local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))
  local f = assert(io.open(repo .. "/lua/testing/ci/init.lua", "rb"))
  local text = f:read("*a")
  f:close()
  has(
    text,
    'require("testing.export.auto").after("commit", rest, sv)',
    "dispatch: ci commit exports after"
  )
  has(
    text,
    'require("testing.export.auto").after("land", rest, sv)',
    "dispatch: ci land exports after"
  )
end
