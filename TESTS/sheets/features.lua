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
    id = "testing.tree",
    title = "The view tests of a tree shows the last result and the pipeline of the project, and follows a run while it goes",
    surface = { "config:tree" },
    docs = "docs/STATE.md",
  },
  {
    id = "testing.cache",
    title = "--cached skips the specs whose inputs did not change; --changed runs the ones a change touches",
    docs = "docs/CACHE.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing run), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.guards",
    title = "Guards fail a run that writes files, starts processes, prompts or leaves state behind",
    docs = "docs/GUARDS.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing run), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.init",
    title = "testing init writes .testing.lua, scripts/test.sh, the hooks and the CI workflow of a project",
    docs = "docs/CLI.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing init), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
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
    perf = "manual:pushes a check branch to GitHub and waits for the hosted CI (account, network)",
  },
  {
    id = "testing.ci-remote",
    title = "testing ci remote shows the hosted CI per repository and system",
    docs = "docs/CI.md",
    perf = "manual:asks GitHub for the hosted CI (gh or a token, network)",
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
    perf = "manual:gh against the repository and ssh-keygen signatures of real commits (account, network)",
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
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing conformance), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.surface",
    title = "testing surface says which commands, keymaps and autocommands the specs exercise",
    surface = { "command:Testing surface" },
    docs = "docs/SURFACE.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing surface), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.budget",
    title = "testing budget measures the performance budgets of a project against their baseline",
    surface = { "command:Testing budget" },
    docs = "docs/PERFORMANCE.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI, also behind :Testing budget), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.sheets",
    title = "Test sheets run a scripted session in a child editor; testing sheets report says what each feature has",
    docs = "docs/SHEETS.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (testing sheets run, the suite's sheet cases), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
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
    perf = "manual:writes a task or a rule into the vaults through the tasks.nvim and rules.nvim command lines",
  },
  {
    id = "testing.history",
    title = "testing history and stats show the results of a project and what the heavy runs cost",
    docs = "docs/CLI.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (testing history, testing stats), which the trace of testing perf does not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.lint",
    title = "testing lint and :Testing lint run the lint presets of the pipeline, the findings in the quickfix",
    surface = { "command:Testing lint" },
    docs = "docs/CI.md",
  },
  {
    id = "testing.migrate",
    title = "testing migrate and :Testing migrate move a repository from its old runner to testing.nvim",
    surface = { "command:Testing migrate" },
    docs = "docs/MIGRATING.md",
    perf = "manual:asks GitHub (git ls-remote) for the ci-verified branch of every dependency; a one-off fleet move",
  },
  {
    id = "testing.callers",
    title = "testing callers finds the callers of a removed or renamed export in every checkout before a push",
    docs = "docs/CLI.md",
    perf = "skip:runs in the child nvim -l scripts/testing.lua (the CLI only), which the trace of testing perf does "
      .. "not follow (testing.nvim/testing-perf-trace-folgt-nicht-in-die-kind-nvim-des-plugins)",
  },
  {
    id = "testing.perf",
    title = "testing perf runs the sheets with a spawn trace and says which processes a plugin starts and what they cost",
    docs = "docs/PERF.md",
    perf = "skip:the measuring tool itself: its trace wraps the primitives and its sampler runs beside the child",
  },
}
