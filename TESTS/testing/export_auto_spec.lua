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

  eq(
    auto.from_env(env({ TESTING_EXPORT_DIR = "C:/x", TESTING_QUEUE = "off" })),
    nil,
    "from_env: never for what a suite starts (its children carry TESTING_QUEUE=off)"
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

  -- after_run: a plain suite run (`scripts/test.sh`, `testing fast`) leaves the hubs on an old state unless it writes too
  result.code, result.raise, lines = 0, nil, {}
  eq(auto.after_run(root, nil, sv), nil, "after_run: nothing armed, nothing written")
  sv.export_after = { dir = "C:/x", repos_root = "E:/repos" }
  eq(auto.after_run(root, nil, sv), true, "after_run: written")
  eq(
    calls[#calls],
    { argv = { "--out", "C:/x", "--repos-root=E:/repos" }, state_dir = "S" },
    "after_run: the same export, the run's state"
  )

  -- the real path: a plain run of a project through `testing.cli` ends with the export, and a red run too
  local proj = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(proj .. "/TESTS", "p")
  local spec = assert(io.open(proj .. "/TESTS/x_spec.lua", "wb"))
  spec:write("return function(H)\n  H.ok(true, 'x')\nend\n")
  spec:close()
  local function run(extra)
    local n = #calls
    local out = {}
    local code = require("testing.cli").main(vim.list_extend({ proj, "--no-cache" }, extra or {}), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function() end,
      state_dir = proj .. "/state",
      color = false,
      export_after = { dir = "C:/y", repos_root = "E:/repos" },
    })
    return code, #calls - n, table.concat(out, "\n")
  end
  local code, written, said = run()
  eq(code, 0, "cli: the plain run is green")
  eq(written, 1, "cli: a plain run writes the export once")
  has(said, "export (TESTING_EXPORT_DIR)", "cli: ... and says so")
  eq(calls[#calls].state_dir, proj .. "/state", "cli: from the state the run was given")
  vim.fn.delete(proj, "rf")
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
  -- the suite step of `testing ci` runs in a throwaway state: it must not write the export of the hubs, nor must the
  -- processes a suite starts (their environment names TESTING_EXPORT_DIR otherwise)
  has(text, "export_after = false", "dispatch: the suite step of ci never exports")
  local q = assert(io.open(repo .. "/lua/testing/queue.lua", "rb"))
  local qtext = q:read("*a")
  q:close()
  has(qtext, 'M.OFF_ENV = "TESTING_QUEUE"', "dispatch: the marker a suite hands its children")
end
