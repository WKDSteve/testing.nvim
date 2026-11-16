-- TESTS/testing/ci_state_dir_before_sub_spec.lua -- `scripts/test.sh ci <sub>` hands its `--state-dir <dir>` in front of
-- the subcommand (copies older than the list in the template do so for everything but `verify`, `list` and `hook`).
-- A subcommand that reads --state-dir (commit, land, remote, overview) gets it after its name; one that has none
-- (release, runner-guard, trust, ...) goes on without it instead of ending in "unknown argument release".
-- The subcommands are stand-ins (package.loaded): nothing is started.
return function(H)
  local eq = H.eq
  local ci = require("testing.ci")
  local sv = { out = function() end, err = function() end }

  local seen = {}
  local saved = {}
  local function stand_in(mod, entry)
    saved[mod] = package.loaded[mod]
    local fake = vim.tbl_extend("force", {}, package.loaded[mod] or {})
    fake[entry] = function(argv)
      seen[mod] = argv
      return 0
    end
    package.loaded[mod] = fake
  end
  stand_in("testing.ci.land", "main")
  stand_in("testing.ci.remote", "main")
  stand_in("testing.ci.overview", "main")
  stand_in("testing.ci.hook", "main")
  stand_in("testing.ci.release", "main")
  stand_in("testing.ci.list", "main")

  local ok_run, problem = pcall(function()
    -- reads --state-dir: it follows the subcommand's name
    for _, sub in ipairs({ "land", "remote", "overview" }) do
      local mod = "testing.ci." .. sub
      eq(
        ci.main({ "--state-dir", "/s", sub, "--x" }, sv),
        0,
        sub .. ": --state-dir <dir> in front is taken"
      )
      eq(seen[mod], { "--state-dir=/s", "--x" }, sub .. ": ... and handed on after the name")
      seen[mod] = nil
      eq(ci.main({ "--state-dir=/s", sub }, sv), 0, sub .. ": --state-dir=<dir> in front is taken")
      eq(seen[mod], { "--state-dir=/s" }, sub .. ": ... the joined form as well")
      seen[mod] = nil
      eq(ci.main({ sub, "--y" }, sv), 0, sub .. ": without --state-dir as before")
      eq(seen[mod], { "--y" }, sub .. ": ... its arguments unchanged")
    end
    -- has no --state-dir: it goes on without it
    for _, sub in ipairs({ "hook", "release", "list" }) do
      local mod = "testing.ci." .. sub
      eq(
        ci.main({ "--state-dir", "/s", sub, "status" }, sv),
        0,
        sub .. ": --state-dir in front is dropped"
      )
      eq(seen[mod], { "status" }, sub .. ": ... the rest is handed on")
    end
  end)

  for mod, value in pairs(saved) do
    package.loaded[mod] = value
  end
  if not ok_run then
    error(problem, 0)
  end
end
