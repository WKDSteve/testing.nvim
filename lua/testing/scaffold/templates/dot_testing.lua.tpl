-- .testing.lua -- configuration of testing.nvim for this project.
-- Loading this file executes it (same trust as running the specs). Every key is optional;
-- run `nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua doctor .` to
-- see the effective configuration.
return {
  -- Lua module root of the project.
  plugin = @@PLUGIN|lua@@,
  -- Dependencies (directory names) that are put on the runtimepath for the run.
  -- Each is looked up in: $<NAME>_DIR, .deps/<name>, ../<name>, stdpath('data')/lazy/<name>.
  deps = @@DEPS|lua@@,
  -- A new project starts strict, as the fleet runs: a leak (a file written outside the temp dir,
  -- state a spec leaves behind, an error in a scheduled callback, a prompt, a deprecation) fails
  -- the case. Lower one to "warn" only with a comment that says why.
  -- Spawned processes and network connections are only reported (warn); list the expected ones in
  -- guard_allow and set process_net = "error" to fail on anything else.
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "warn",
  },
  -- Legitimate writers, spawns and network hosts, one line each with a sentence why (docs/GUARDS.md of testing.nvim).
  guard_allow = { fs = {}, spawn = {}, network = {} },
  -- The pipeline of `testing ci` is derived from the repository (fast = stylua, luacheck; full = fast + the suite).
  -- To add the LuaLS diagnostics as a third profile, uncomment this: a `ci` section replaces the derived pipeline, so
  -- it names all three. luals takes about a minute, so it stays out of `full` (the pre-push hook runs that). Before
  -- it can be held at zero: `.luarc.json` must not set `workspace.library` (it replaces the library the editor
  -- gives LuaLS: rule LLS-01), every plugin the code requires belongs in `deps` above, and
  -- `testing lint luals --all` reports nothing twice in a row (docs/CI.md of testing.nvim, "The luals preset").
  -- ci = {
  --   default = "full",
  --   profiles = {
  --     fast = { "stylua", "luacheck" },
  --     full = { "fast", "suite" },
  --     strict = { "full", "luals" },
  --   },
  -- },
}
