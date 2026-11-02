-- TESTS/testing/screen_dir_env_spec.lua -- the folder of the snapshot files: `opts.dir`, else the project's
-- `snapshots.dir` (the runner hands it down in TESTING_SNAPSHOTS_DIR, to this host and to every child), else
-- `TESTS/__snapshots__`.

-- @cache-allow env
-- @cache-env TESTING_SNAPSHOTS_DIR
-- (the spec sets the variable the runner sets for a project that configures `snapshots.dir`)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local screen = require("testing.screen")
  local root = vim.fs.normalize(vim.fn.tempname())
  local file = root .. "/TESTS/x_spec.lua"
  local saved = os.getenv("TESTING_SNAPSHOTS_DIR")

  vim.env.TESTING_SNAPSHOTS_DIR = nil
  local _, rel = screen.path("a", { root = root, file = file })
  eq(rel, "TESTS/__snapshots__/x_spec/a.snap", "no project value: the default folder")

  vim.env.TESTING_SNAPSHOTS_DIR = "TESTS/shots/"
  _, rel = screen.path("a", { root = root, file = file })
  eq(
    rel,
    "TESTS/shots/x_spec/a.snap",
    "the project's snapshots.dir is the default of testing.screen"
  )

  _, rel = screen.path("a", { root = root, file = file, dir = "other" })
  eq(rel, "other/x_spec/a.snap", "opts.dir still wins")

  vim.env.TESTING_SNAPSHOTS_DIR = ""
  _, rel = screen.path("a", { root = root, file = file })
  eq(rel, "TESTS/__snapshots__/x_spec/a.snap", "an empty value is no value")

  vim.env.TESTING_SNAPSHOTS_DIR = saved
end
