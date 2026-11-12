-- TESTS/sheets/features.lua -- the functionalities of testing.nvim as its user meets them; `testing sheets report`
-- says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns about a sheet that names
-- an id not listed here. Data: read with an empty environment like a sheet (docs/SHEETS.md).
-- The list follows docs/CLI.md and docs/BINDINGS.md, one entry per thing a user does with it.
return {
  {
    id = "testing.run",
    title = "testing run and :Testing run, file and last run a project's specs in any dialect, results in the quickfix",
    surface = { "command:Testing run", "command:Testing file", "command:Testing last" },
    docs = "docs/CLI.md",
  },
  {
    id = "testing.editor",
    title = "The :Testing subcommands answer in the editor: hover on a result, list, config, doctor, health, cache",
    surface = {
      "command:Testing hover",
      "command:Testing list",
      "command:Testing doctor",
      "command:Testing config",
    },
    docs = "docs/BINDINGS.md",
  },
  {
    id = "testing.cache",
    title = "--cached skips the specs whose inputs did not change; --changed runs the ones a change touches",
    docs = "docs/CACHE.md",
  },
  {
    id = "testing.guards",
    title = "Guards fail a run that writes files, starts processes, prompts or leaves state behind",
    docs = "docs/GUARDS.md",
  },
  {
    id = "testing.init",
    title = "testing init writes .testing.lua, scripts/test.sh, the hooks and the CI workflow of a project",
    docs = "docs/CLI.md",
  },
  {
    id = "testing.ci",
    title = "testing ci and :Testing ci run the project's pipeline, live in a buffer, with the quickfix of a red step",
    surface = { "command:Testing ci", "command:Testing ci status" },
    docs = "docs/CI.md",
  },
  {
    id = "testing.ci-commit",
    title = "testing ci commit checks a commit in its own worktree against its parent",
    surface = { "command:Testing ci commit" },
    docs = "docs/CI.md",
  },
  {
    id = "testing.ci-land",
    title = "testing ci land moves main only when the hosted CI of exactly that commit is green",
    docs = "docs/CI.md",
  },
  {
    id = "testing.ci-remote",
    title = "testing ci remote shows the hosted CI per repository and system",
    docs = "docs/CI.md",
  },
  {
    id = "testing.pre-push",
    title = "The pre-push hook lets a push through with the proof of a local run",
    surface = { "command:Testing ci hook install" },
    docs = "docs/HOOKS.md",
  },
  {
    id = "testing.runner-guard",
    title = "The runner guard keeps foreign code off the self-hosted runners; testing ci trust admits a reviewed range",
    docs = "docs/RUNNER-GUARD.md",
  },
  {
    id = "testing.fleet",
    title = "testing ci repos and the overview check every repository below a root",
    surface = { "command:Testing ci repos" },
    docs = "docs/CI.md",
  },
  {
    id = "testing.export",
    title = "testing export writes the state of the fleet for other tools, read-only on the workstation",
    surface = { "command:Testing export" },
    docs = "docs/OUTPUT-FORMATS.md",
  },
  {
    id = "testing.conformance",
    title = "testing conformance checks a repository against the rules and gates",
    surface = { "command:Testing conformance" },
    docs = "docs/CONFORMANCE.md",
  },
  {
    id = "testing.surface",
    title = "testing surface says which commands, keymaps and autocommands the specs exercise",
    surface = { "command:Testing surface" },
    docs = "docs/SURFACE.md",
  },
  {
    id = "testing.budget",
    title = "testing budget measures the performance budgets of a project against their baseline",
    surface = { "command:Testing budget" },
    docs = "docs/PERFORMANCE.md",
  },
  {
    id = "testing.sheets",
    title = "Test sheets run a scripted session in a child editor; testing sheets report says what each feature has",
    docs = "docs/SHEETS.md",
  },
  {
    id = "testing.sheet-step",
    title = ":Testing sheet step walks a sheet step by step in a window beside the code, the child's screen in a tile",
    surface = { "command:Testing sheet step" },
    docs = "docs/SHEETS.md",
  },
  {
    id = "testing.act",
    title = "testing act turns a finding of the last run into a task, a rule or a question to the AI",
    surface = { "command:Testing act" },
    docs = "docs/CLI.md",
  },
  {
    id = "testing.history",
    title = "testing history and stats show the results of a project and what the heavy runs cost",
    docs = "docs/CLI.md",
  },
}
