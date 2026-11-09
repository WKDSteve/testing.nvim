# The CI workflow: how the pieces fit together

One definition of "this repository is fine", used in four places: in the terminal, before a push, in the editor, and
on the hosted runner. This page is the use case; [CI.md](CI.md) is the reference for every option.

## The idea

- **One definition per repository**: the `ci` section of `.testing.lua` (profiles of steps: `stylua`, `luacheck`,
  `suite`, `conformance`, a repository's own steps).
- **One engine**: `testing ci` runs it. The same pipeline, the same exit codes, everywhere.
- **One entry point per repository**: `scripts/ci.sh`, a shim that finds testing.nvim and calls `testing ci`
  (`--fast` is `--profile=fast`; a gate name such as `luacheck` is `--step=luacheck`). The GitHub workflow, the
  pre-push hook, `:MyPlugins ci` and a person in a terminal all run this one script.
- **A proof of the tested state**: a green run writes `ci-<profile>.json` and the suite's stamp. `testing ci verify`
  answers in a tenth of a second whether the current tree is already proven, so nothing is run twice.
- **A commit, not the working tree**: `testing ci commit <sha>` checks a commit in a git worktree of its own and
  sorts red into new, known and fixed against its parent. A review uses it, never "the suite is red, skipped": another
  session's uncommitted work cannot make it red, and red that was there before is `known-red`, not the commit's fault
  ([CI.md](CI.md#check-a-commit-testing-ci-commit)).

## A repository, set up

A Lua project with a `stylua.toml`, a `.luacheckrc` and specs needs **no `ci` section at all**: `stylua`, `luacheck`,
the suite (and `conformance`, when it is a gate) are derived from those files, `fast` and `full` with them
([CI.md](CI.md#without-writing-a-pipeline-the-derived-one)). `testing ci list` shows what was derived and why. Only
what differs is written down:

```lua
-- .testing.lua
return {
  deps = { "lib.nvim" },
  ci = {
    skip = { "luacheck" },                                   -- leave a derived step out
    steps = {
      docs = { run = { "scripts/gen_docs.sh", "--check" } }, -- a step of the repository: argv, never a shell line
    },
  },
}
```

A section with `profiles` is the whole pipeline, written by hand, for a project whose checks differ more.

```bash
scripts/ci.sh                # the default profile (full)
scripts/ci.sh --fast         # stylua and luacheck, seconds
scripts/ci.sh luacheck       # one gate: a partial run, green for that gate only
scripts/ci.sh --keep-going   # every step, all red ones at once
```

Repositories with a Lua suite run through `scripts/test.sh ci` (it finds the dependencies and isolates state, the same
as a plain suite run). Vaults without a suite carry a `.testing.lua` with only the `ci` section and a shim that looks
for testing.nvim itself (`$TESTING_NVIM_DIR`, `.deps/testing.nvim`, `../testing.nvim`).

A missing tool or dependency is exit `3` before any step runs, never a silent green.

## A day with it

1. **Edit, then check fast.** `scripts/ci.sh --fast` (or `:Testing ci fast` in the editor). Formatting and lint, in
   seconds.
2. **In the editor.** `:Testing ci` runs the pipeline in a headless child, so a hanging step cannot take the session
   down. Output streams into `testing-ci://<repo>`, a progress indicator shows step n of m, the verdict is notified,
   and a red run fills the quickfix list with the findings (a click jumps to the place). `:Testing ci status` shows
   the last result and says `stale` when the tree changed since. The statusline component
   `require("testing.ci.editor").statusline()` shows `ci: ✓ full @abc1234` / `ci: ✗ luacheck` / `stale`.
3. **Before the push.** `testing ci hook install` writes a pre-push hook: it runs `testing ci verify` first. A proven
   state passes at once; otherwise the `fast` profile runs with `--reuse` (an unchanged suite is not run again). A red
   pipeline blocks the push; `git push --no-verify` skips it.
4. **After a change in a library.** `:Testing ci repos` (or `testing ci --repos-root=$REPOS_DIR`) runs the pipelines of
   all repositories that have a `ci` section. Each repository is verified first and **skipped when it is already
   proven**, so only the repositories the change reached run again. A table at the top of the buffer follows the run;
   the quickfix list collects the findings of every red repository, prefixed with its name.

## On the hosted runner

The GitHub workflow of a repository does not spell the commands out again: it checks out the dependencies below
`.deps/` and runs `scripts/ci.sh` (one job per gate where independent red/green marks are wanted, e.g.
`scripts/ci.sh luacheck`).

- **Dependencies come from `ci-verified`.** Every repository publishes the branch `ci-verified` once its own CI is
  green. Other repositories check out `lib.nvim`, `testing.nvim` and so on at that branch, so a half-finished change
  in a library never breaks its dependents.
- **testing.nvim needs lib.nvim.** A job that runs the shim therefore checks out both below `.deps/`.
- **Private repositories** run on a self-hosted runner. Without a running runner a push stays "Queued". Start it with
  `scripts/runners.ps1 ensure <repo>` of the nvim configuration.
- **The same files, a different machine.** What the runner does and what you did locally are the same steps; a
  difference is a finding (a tool version, a missing dependency), not a second pipeline to maintain.

## One pipeline, two kinds of runner

CI stays on the local runner. macOS is the one exception, because there is no local Mac: its leg runs in a throwaway
GitHub-hosted VM, never on the local machine. Every workflow `testing init` writes comes from one generator
(`testing.ci.workflow`) in one of three **layouts**:

| Event | `public` | `private` | `hosted` |
| --- | --- | --- | --- |
| push to `main` | local runner, whole profile; **hosted macOS**, platform steps | local runner, whole profile | hosted ubuntu (whole profile), hosted windows and macOS (platform steps) |
| `workflow_dispatch` | no such trigger | **hosted macOS**, platform steps | no such trigger |
| `pull_request` | hosted ubuntu (whole profile), hosted windows and macOS (platform steps) | no such trigger | as a push |

```bash
testing init                                 # the whole setup; its ci.yml in the layout `hosted`
testing init --workflow=two-runner           # only ci.yml, layout `public`
testing init --workflow=two-runner-private   # only ci.yml, layout `private`
testing init --workflow=hosted               # only ci.yml, layout `hosted`
```

`--workflow=<kind>` writes only `.github/workflows/ci.yml` and touches nothing else. An existing file is kept; `--force`
replaces this one file. The checkouts below `.deps/` come from the `DEPS=(...)` line of `scripts/test.sh`, else from
`deps` in the text of `.testing.lua`, else `lib.nvim`; nothing of the project runs for that, and a name it cannot read
is an error. These kinds take the defaults (the suite as the platform step, no Node, no pinned checkout); a repository
that needs more describes it in `ci.workflow` and uses `--workflow=public` (below), which keeps the file in sync.

- **Why private is by hand.** Standard runners are free for public repositories. A private one has 12 USD a month on
  GitHub Free and macOS costs 0.062 USD per minute (GitHub docs, 2026-11-04), about 190 minutes. Start the leg with
  `gh workflow run ci.yml`. The 30-minute timeout limits one run to 1.86 USD.
- **Hosted only.** The layout `hosted` never reaches the local runner and carries the result cache
  ([CI-CACHE.md](CI-CACHE.md)): the suite runs with `--cached`, a pull request only restores the cache, a push to `main`
  saves it.
- **Steps.** A hosted leg runs what depends on the platform (`platform`, the suite by default); a pipeline without such
  a step answers with a usage error, never a pass.
- **Entry point.** Every leg calls `scripts/ci.sh` where the repository has that wrapper, else `scripts/test.sh ci`,
  which `testing init` writes: the same pipeline.
- **The runner guard does not see the hosted leg.** The guard is a hook in the `.env` of a local runner
  ([RUNNER-GUARD.md](RUNNER-GUARD.md#hosted-legs)). A guard that refuses the local job does not stop the macOS leg
  (`fail-fast: false`).
- **A job with `needs: [pipeline]` waits for every leg.** A `publish-ci-verified` job behind this matrix does not move
  the branch while macOS alone is red, and a push with the local runner off stays open until that job is discarded
  after 24 h.
- **First run.** The layouts are checked against golden files, not on a real macOS VM; the first push of a repository is
  that check.

### Generated from `.testing.lua`: `--workflow=public`

The kinds above write the defaults once. `--workflow=public` takes everything from `ci.workflow` instead (the layout
too, despite the flag's name: it was the first layout) and keeps the file that way:

```lua
ci = {
  profiles = { ... },
  workflow = {
    name = "tasks.nvim",                           -- the repository, for the header (never the directory's name: a
                                                   -- worktree of `testing ci commit` is called `tree`)
    layout = "public",                             -- optional: "public" (default), "private" or "hosted"
    platform = { "suite", "conformance" },        -- the steps the hosted windows and macOS legs run
    node = { version = "22", used_by = "the Node contract check" },   -- optional: Node on the hosted full legs
    checkouts = {                                  -- optional: third-party dependencies, pinned by commit
      { repo = "folke/snacks.nvim", ref = "<40 hex>", why = "<one line: why the specs need it>" },
    },
    env = { TASKS_REQUIRE_SNACKS = "1" },          -- optional: environment of the pipeline step
    publish = { why = "<who checks out ci-verified>" },   -- optional (or `true`): the job that moves `ci-verified`
    timeout = 30,                                  -- optional: minutes of a leg
  },
}
```

```bash
testing init --workflow=public            # write .github/workflows/ci.yml (an existing one is kept)
testing init --workflow=public --force    # replace it
testing init --workflow=public --check    # compare byte for byte, print a diff, exit 1 when it differs
```

- **Layout.** As in the table above. In `public` a pull request never reaches the self-hosted runner; the header says to
  approve no pull request that touches `.github/`. In every layout the job that moves `ci-verified` (`publish`) runs on
  a hosted ubuntu runner: the only job with write access stays off the maintainer's machine, whose global pre-push hook
  would refuse the move from a shallow checkout anyway. The jobs are named `testing ci (<system>)`, so
  `testing ci remote` puts each leg in its column and the publish job in none.
- **What is generated.** The checkouts of `deps` and `testing.nvim` from `ci-verified`, the third-party ones pinned with
  their reason, the tool versions and action SHAs of one table in testing.nvim (`testing.ci.workflow`, `TOOLS` and
  `ACTIONS`): a bump there is one regenerated file per repository. Every value of `ci.workflow` is checked first (a
  repository is `owner/name`, a third-party `ref` a full commit id, an env name `NAME` and none the step sets itself,
  no text with a line break); a `platform` step that is not in the default profile is an error.
- **Kept in sync.** The preset step `workflow-in-sync` runs the `--check`: a repository that names it in a profile is red
  as soon as the file and `.testing.lua` disagree. It is opt-in: a repository without `ci.workflow` is not generated and
  not checked.
- **First users.** rules.nvim and tasks.nvim: their hand-written workflows were the model; tasks.nvim's is generated
  byte for byte, rules.nvim's differs only in the comment above the publish job.

### Why there is no `testing ci workflow`

Decided on 2026-11-04: `testing init` already writes the workflow of a repository, so `--workflow` is a second kind of
the same thing, and a `ci` verb would be a second place for it. `testing ci` runs a pipeline; it writes no setup. The
generated workflow is therefore `testing init --workflow=public`, and only its check is a step of the pipeline.

### What `testing ci remote` shows

`testing ci remote` counts push runs only:

- A system without a job is `-`, with no state in `--json`: no verdict, neither `ok` nor red. The summary counts the
  jobs that exist and says how many repositories have no macOS job: `fully green: 3 / 3 (no macos job: 1)`.
- Red only on macOS is red, also for the exit code.
- On a private repository the `MACOS` cell therefore stays `-`, also after a run by hand: that run can neither hide a
  red push run nor turn it green. Its result: `gh run list -R <owner>/<repo> --workflow=ci.yml --event workflow_dispatch`.

### The log of a red macOS run

No device is needed:

```bash
gh run list -R <owner>/<repo> --workflow=ci.yml --limit 10
```

```bash
gh run view <run-id> -R <owner>/<repo> --log-failed
```

One job: `gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs` (the job ids are in `gh run view <run-id> --json jobs`;
the `url` of the `macos` cell in `testing ci remote --json` links the job). The report and the suite IR stay 14 days as
the artifact `ci-macos` (`testing-ir-macos-latest` with the workflow of plain `testing init`):

```bash
gh run download <run-id> -R <owner>/<repo> -n ci-macos
```

Save what matters at once: GitHub can answer an old run with HTTP 404 well before the usual retention ends.

## What the `conformance` step checks

K1 to K15 of [CONFORMANCE.md](CONFORMANCE.md): layout, documentation, tooling, and static rules read from the text of
the repository. `UI-63` is one of them: no `vim.fn.confirm`, `vim.fn.input`, `vim.fn.inputlist` or literal Yes/No
`vim.ui.select` in `lua/` outside the dialog helper; ask through `lib.nvim.ui.dialog`, or mark an intended exception
with `-- native-prompt: <reason>`. It is a warning, so it never turns the gate red by itself.

## Exit codes and the sentinel

`0` green (or skipped for this system), `1` a step red, `2` usage or configuration error (a typo in the `ci`
section is an error, never a green run), `3` a tool or dependency is missing or a step could not start. The last line
of a complete green run is `TESTING_CI_OK`; a partial run (`--step`, suite options, a green-partial suite) never
prints it. See [EXIT-CODES.md](EXIT-CODES.md).

## Adding a repository

1. `testing init` (or `testing migrate`) for `.testing.lua`, `TESTS/minimal_init.lua` and `scripts/test.sh`.
2. Add the `ci` section; `testing ci list` shows the resolved profiles.
3. Replace `scripts/ci.sh` by the shim (keep the name: workflows, hooks and `:MyPlugins ci` call it).
4. Check it from both sides: a format error and a red case turn it red (exit `1`), a missing tool gives exit `3`.
5. Point the workflow at `scripts/ci.sh` and give the job the dependency checkouts; on the local runner,
   `testing init --workflow=<kind>` writes it ([above](#one-pipeline-two-kinds-of-runner)).

## Not there yet

- **Test explorer node**: the pipeline as a node with its steps, restart from a step (`ci-explorer-knoten`, waits for
  the explorer).
- **Live check in a real editor**: split, progress style and statusline were built against a fake process; the check
  by hand is the task `ci-editor-live-test-von-testing-ci-ci-repos-im-echten-editor`.
- **Terminal view** (terminal.nvim instead of the scratch buffer) is optional and not built.
