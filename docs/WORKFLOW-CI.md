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
the suite (and `conformance` when it is a gate, `surface` when there is a `surface.baseline.json`) are derived from
those files, `fast` and `full` with them
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
| `workflow_dispatch` | as a pull request (by hand, see below) | **hosted macOS**, platform steps | no such trigger |
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
    playwright = { version = "1.64.1", used_by = "the browser sheets" },  -- optional: Chromium on the full leg
    luals = { version = "3.18.2", used_by = "scripts/luals-check.sh" },  -- optional: lua-language-server, full leg
    go = { version_file = "go.mod", used_by = "the relay build" },   -- optional: Go on the hosted legs
    artifacts = { { name = "sheet-shots", path = "TESTS/sheets/out/**/*.png", why = "<what they show>" } },  -- optional
    checkouts = {                                  -- optional: more checkouts below .deps/, not on the specs' rtp
      { repo = "folke/snacks.nvim", ref = "<40 hex>", why = "<one line: why the specs need it>" },
      { repo = "WKDSteve/hover.nvim", ref = "ci-verified", why = "<only the test sheets load it>" },
    },
    env = { TASKS_REQUIRE_SNACKS = "1" },          -- optional: environment of the pipeline step
    packages = { { name = "ripgrep", why = "<one line: what the runs need it for>" } },   -- optional: programs of the hosted legs
    setup = { { run = { "bash", "scripts/ci-setup.sh" }, why = "<what it prepares>" } },   -- optional: before the pipeline
    publish = { why = "<who checks out ci-verified>" },   -- optional (or `true`): the job that moves `ci-verified`
    land = true,                                   -- optional: `testing ci land` (layouts public and hosted);
                                                   -- { also = { "native" } }: land waits for that workflow too
    min_nvim = { version = "0.11.4", why = "<what promises it>" },   -- optional (hosted): a leg on the minimum
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
- **Tools.** The hosted legs install the versions of the self-hosted runner: nvim through `rhysd/action-setup-vim`, stylua
  through its action, and luacheck as the release binary of `lunarmodules/luacheck` whose sha256 is pinned in
  `testing.ci.workflow.SHA256` (checked against the maintainer's signature, the same file `scripts/wsl-tools.sh`
  installs): no Lua and no luarocks from www.lua.org, whose download timed out. A new luacheck is a new pin there.
- **TMPDIR on macOS.** Every macOS leg sets `TMPDIR=/tmp` (one step before the pipeline, in every layout). The runner's
  own TMPDIR lies under `/var/folders/.../T/`, and a Unix socket below the sandbox of a child editor (its RPC server, a
  pipe of fzf-lua) is then longer than `sun_path` (104 bytes) and fails with `ENOTSOCK`. An `env.TMPDIR` of
  `ci.workflow` still decides, since it is the environment of the pipeline step itself; a repository no longer needs
  one for this.
- **Playwright.** `playwright = { version, used_by }` installs that release of `playwright-core` and its Chromium on the
  full leg, outside the checkout, and names them in `TESTING_PLAYWRIGHT_DIR` and `PLAYWRIGHT_BROWSERS_PATH`: the
  browser sheets (and an unpacked extension, which needs the full Chromium) run there instead of being a reported
  skip. Without the key nothing of it is in the workflow.
- **LuaLS.** `luals = { version, used_by }` installs lua-language-server on the hosted leg with the whole profile
  (ubuntu), so a step of the profile (`scripts/luals-check.sh`, the preset `luals`) runs there: the release tarball
  `lua-language-server-<version>-linux-x64.tar.gz` of LuaLS, checked against the sha256 that
  `testing.ci.workflow.SHA256.luals` pins for that version before it is unpacked, its `bin/` on the `PATH`. A version
  without a pinned sum is refused (a bump adds the sum there first); apt has no package, brew and choco only unpinned
  ones, and windows and macOS run only the `platform` steps. A step that needs it gives `skip_exit` for a machine
  without the tool (the self-hosted runner, a local run). Without the key nothing of it is in the workflow.
- **Go.** `go = { version_file = "go.mod", used_by, legs }` runs `actions/setup-go` (pinned) with the version of that
  file of the repository, on every hosted leg (`legs = "hosted"`, default) or only the full one (`"full"`); the hosted
  macOS image has Go only in its tool cache, not on the PATH, so a step that builds Go there needs it. No module cache.
  `version_file` is a path relative to the checkout (no `..`, no glob). Without the key nothing of it is in the
  workflow.
- **Artifacts.** Every leg uploads its report and suite IR when it is red (`ci-<leg>`). `artifacts` names more files a
  hosted leg uploads after the pipeline, e.g. the screenshots of the browser sheets: `{ name = "sheet-shots", path =
  "TESTS/sheets/out/**/*.png", why = <one line>, when = "always" | "failure", legs = "full" | "hosted" }`. `when`
  `always` (default) uploads after a green run too (what the page looked like is the evidence a sheet leaves behind),
  `failure` only from a red leg; `legs` as for `setup` (`full`, the default, is the leg with the whole profile). Each is
  one `actions/upload-artifact` step named `<name>-<leg>`, kept 14 days, no error when nothing matches. `path` is one
  glob relative to the checkout (letters, digits and `._/*-`; no `..`, not absolute, no expression), `name` letters,
  digits, `.`, `_`, `-` and not `ci`; at most 4 entries. Never on the self-hosted leg. Without the key the file is what
  it was.
- **Packages.** `packages` names programs the specs or test sheets need and a runner image lacks (`ripgrep`, for a sheet
  that scans with it): each is installed by one step per system on every hosted leg, with `apt-get` on Linux, `brew` on
  macOS and `choco` on Windows (one name for all three; where the managers name it differently, `apt`, `brew` or `choco` give a name of their own, e.g. `{ name = "poppler", apt = "poppler-utils", why = ... }`), and never on the self-hosted leg, whose machine is not the
  workflow's to change. A name is a package name (letters, digits, `.`, `_`, `+`, `-`; nothing a shell would read as its
  own), `why` is one line above the steps, at most 8 packages. Without `packages` the file is what it was. Before the
  first apt install a Linux leg runs `sudo apt-get update` once: the package index of a runner image can be older than
  its mirrors, and a package the image lacks would then fail with a 404 depending on the image's age.
  `apt`, `brew` or `choco` set to `false` leave that system without the program (`{ name = "tmux", choco = false, why =
  ... }`: choco has no tmux, and the specs that need it are n/a on Windows anyway); false on all three is an error. A
  program that comes from npm is `{ name = "ts-ls", npm = { "typescript@5", "typescript-language-server" }, why = ...
  }`: one step `npm install -g ...` on every hosted leg, instead of the three managers (not together with `apt`, `brew`,
  `choco`; each entry `name`, `@scope/name` or `name@version`, nothing a shell would read as its own).
- **Setup.** `setup` runs commands of the repository that prepare a hosted leg and that no package covers: grammars
  built from source, Lua rocks, a symlink to a checkout. Each entry is `{ run = <argv>, why = <one line>, legs = "full" |
  "hosted" }`: `run` is a list of words, never a shell string (letters, digits and `@%+=:,./_-`; the first word is the
  program, not an option; at most 16 words, at most 4 entries), `why` the comment above the step, `legs` where it runs:
  `full` (default) only on the hosted leg with the whole profile (ubuntu), `hosted` on every hosted leg (windows, macOS
  and `ubuntu-min` too). Each is one bash step (Git Bash on Windows) after the tools, packages, Playwright and Node and
  before the pipeline step, so a script may write `$GITHUB_ENV` (`DOCMAP_TS_PARSERS_DIR=...`) or `$GITHUB_PATH` for it.
  Never on the self-hosted leg. Without `setup` the file is what it was.
- **What is generated.** The checkouts of `deps` and `testing.nvim` from `ci-verified`, the third-party ones pinned with
  their reason, the tool versions and action SHAs of one table in testing.nvim (`testing.ci.workflow`, `TOOLS` and
  `ACTIONS`): a bump there is one regenerated file per repository. Every value of `ci.workflow` is checked first (a
  repository is `owner/name`, a `ref` a full commit id, or `ci-verified` for a repository of the owner of the
  dependencies (third-party code is always pinned), an env name `NAME` and none the step sets itself,
  no text with a line break); a `platform` step that is not in the default profile is an error. A dependency that
  `checkouts` names too (a third-party plugin in `deps`, such as `telescope.nvim`) comes from that line, with its
  repository and pin, not as `<owner>/<name>` at `ci-verified`.
- **`land = true`** (layouts `public` and `hosted`): the workflow also runs on a push to a check branch
  `ci/**`, always on hosted runners (in `public` only a push to main reaches the self-hosted runner), and a first job
  `already-verified` looks for a green run of the same commit on such a branch. When `testing ci land` then moves main
  to that commit, the legs are skipped and only `publish-ci-verified` runs (when there is one): the commit is not tested twice. Without the
  key the file is byte for byte what it was. See docs/CI.md, "Land through the hosted CI". `land = { also = { "native"
  } }` is the same file, and `testing ci land` also waits for the named workflows of the repository (by their `name:`).
- **Beside the generated workflow** (a release on a tag, jobs of other languages): a hand-written file of its own, e.g.
  `.github/workflows/native.yml` with `name: native`, `on: push: branches: [main, "ci/**"]` and `tags: ["v*"]`, its
  actions pinned by commit, `permissions: contents: read` (a release job widens it for itself). The generated `ci.yml`
  stays without tags; with `land = { also = { "native" } }` a red native run holds main as a red CI run does. Rust needs
  no key: rustup is on every hosted image and reads `rust-toolchain.toml` itself, a target is a `setup` step
  (`{ run = { "rustup", "target", "add", "wasm32-unknown-unknown" }, why = ... }`).
- **`min_nvim`** (layout `hosted`): one more hosted ubuntu leg, `ubuntu-min`, runs only the suite on the promised
  minimum Neovim (`version` without a "v"). The setup step and the cache keys then take the version of the leg
  (`matrix.nvim`), and a comment above the matrix names it (`nvim: v0.11.4`, which a spec of the repository can look
  for). `testing ci remote` puts the leg in the ubuntu column. Without the key the file is byte for byte what it was.
- **Kept in sync.** The preset step `workflow-in-sync` runs the `--check`: a repository that names it in a profile is red
  as soon as the file and `.testing.lua` disagree. It is opt-in: a repository without `ci.workflow` is not generated and
  not checked.
- **First users.** rules.nvim and tasks.nvim: their hand-written workflows were the model; tasks.nvim's is generated
  byte for byte, rules.nvim's differs only in the comment above the publish job. testing.nvim's own workflow is
  generated too (layout `hosted`, `land`, Node for its contract step, lib.nvim as a checkout since its `deps` stays
  empty); the check of lib.nvim's suite through this runner, not part of the gate, has a hand-written file of its own
  (`lib-suite.yml`).

### Why there is no `testing ci workflow`

Decided on 2026-11-04: `testing init` already writes the workflow of a repository, so `--workflow` is a second kind of
the same thing, and a `ci` verb would be a second place for it. `testing ci` runs a pipeline; it writes no setup. The
generated workflow is therefore `testing init --workflow=public`, and only its check is a step of the pipeline.

### What `testing ci remote` shows

`testing ci remote` counts push runs only:

- After `testing ci land` the legs ran on the check branch `ci/**`, and main's run of the same commit skipped them: the
  green check run then stands for the commit, so every system still has its cell. A red run of main (a failed publish)
  stays what is shown, and a red check run of an earlier land never hides a later run of main.

- A system without a job is `-`, with no state in `--json`: no verdict, neither `ok` nor red. The summary counts the
  jobs that exist and says how many repositories have no macOS job: `fully green: 3 / 3 (no macos job: 1)`.
- Red only on macOS is red, also for the exit code.
- On a private repository the `MACOS` cell therefore stays `-`, also after a run by hand: that run can neither hide a
  red push run nor turn it green. Its result: `gh run list -R <owner>/<repo> --workflow=ci.yml --event workflow_dispatch`.
- On a public repository a run by hand (`gh workflow run ci.yml -R <owner>/<repo>`) restarts a run GitHub left
  hanging without jobs (status `queued`; cancel, force-cancel and rerun fail there). It gets the hosted legs of a pull
  request and its own concurrency group, so it never cancels a push run. `testing ci remote` still counts push runs
  only: the hanging run stays the shown one until the next push, the run by hand is the proof in between.

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

## Overtaken runs and reused jobs

Two pushes in a row must not mean two full runs. The older run is ended as soon as the run of the newer commit starts,
and the jobs it already had green count for the newer one when nothing they depend on changed since.

- **Overtaking is GitHub's `concurrency`.** Every generated workflow has `cancel-in-progress: true` in a group of
  workflow, event and ref; on `main` the newer push is a descendant of the older one. A hand-written workflow (a native
  app) takes the same lines:

  ```yaml
  concurrency:
    group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}
    cancel-in-progress: true
  ```

- **The generated workflow needs nothing more.** Each leg saves its result cache after a green run, at once, also when
  the run is cancelled later; the leg of the newer commit restores the newest one and runs only the specs whose key
  changed ([CI-CACHE.md](CI-CACHE.md)). A leg cancelled in the middle saves nothing yet (the entries are written when
  the run ends).
- **Any workflow: `testing ci reuse`.** A first job asks, for every job and the paths it depends on, whether a push run
  of this workflow already had it green for an ancestor of this commit, with those paths unchanged since:

  ```yaml
  on:
    push:
      branches: [main]
    workflow_dispatch:
      inputs:
        full: { description: "run every job, take nothing over", type: boolean, default: false }
  jobs:
    plan:
      runs-on: ubuntu-latest
      timeout-minutes: 5
      permissions:
        actions: read      # the job results of earlier runs
        contents: read     # the commits they ran on (fetched when the checkout lacks them)
      outputs:
        rust: ${{ steps.reuse.outputs.rust }}
        ui: ${{ steps.reuse.outputs.ui }}
      steps:
        - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
          with: { repository: WKDSteve/testing.nvim, ref: ci-verified, path: .deps/testing.nvim, persist-credentials: false }
        - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
          with: { repository: WKDSteve/lib.nvim, ref: ci-verified, path: .deps/lib.nvim, persist-credentials: false }
        - uses: rhysd/action-setup-vim@febef33995d6649302e9d88dda81e071b68f16a7 # v1
          with: { neovim: true, version: v0.12.2 }
        - id: reuse
          env:
            GH_TOKEN: ${{ github.token }}
            TESTING_REUSE: ${{ inputs.full && 'off' || '' }}
          run: >-
            nvim -n -i NONE --headless -u NONE -l .deps/testing.nvim/scripts/testing.lua ci reuse
            --job=rust=src-tauri,Cargo.lock,rust-toolchain.toml
            --job=ui=ui,package.json,pnpm-lock.yaml --name="ui:ui (node)"
    rust:
      needs: plan
      if: needs.plan.outputs.rust != 'reuse'
      # ...
    ui:
      name: ui (node)
      needs: plan
      if: needs.plan.outputs.ui != 'reuse'
      # ...
  ```

  - `--job=<key>=<pathspecs>`: `<key>` is the output (`reuse` or `run`, and `<key>_from` the commit taken over) and the
    job's name in the run; `--name=<key>:<name>` when its `name:` differs. The paths are git pathspecs, comma-separated.
    The workflow file always counts too: a change to a job runs it again. Without paths a job depends on the whole tree,
    and only a run of a commit with the same tree counts (a rebase, the push of main after `testing ci land`).
  - **Where the verdict lies:** in the job results of the Actions API, nowhere else. Every run can read them, they are
    bound to the commit, nobody without write access to the repository makes one, and a cancelled run leaves the jobs
    that were green before the cancel. Nothing is written for it.
  - **What counts:** a run of this workflow file in this repository, of the event `push` (no pull request, no fork, no
    run by hand), not this run, on an ancestor of the commit or the commit itself (the compare API). Newest run first,
    the newest completed job of the name decides: green with unchanged paths is `reuse`, green with changed paths or red
    is `run`. A cancelled or skipped one (a job that reused something itself) is passed over, so the search finds the
    run in which it really was green; at most `--runs` (50) runs are looked at.
  - **In doubt it runs:** an error of the API or of git, a commit that cannot be fetched, a job never seen decide `run`,
    with the reason. `--full`, `TESTING_REUSE=off` (above: the `full` input of a run by hand) run every job.
  - **The report:** one line per job (`reuse  rust  green at 1d48a8d, src-tauri, Cargo.lock unchanged since`) and a
    table in the step summary, with a link to the job taken over.
  - **The runner guard is untouched** ([RUNNER-GUARD.md](RUNNER-GUARD.md)): the command never starts anything, it only
    leaves jobs out. A green job of a self-hosted runner became green only after the guard let its commit run, and only
    pushes count as sources. Let the `plan` job run on a hosted runner.
  - A job that `needs` a reused (skipped) job runs only with `if: ${{ !cancelled() && !contains(needs.*.result,
    'failure') }}`; GitHub counts a skipped job as passed for a required check.
  - The paths decide how safe it is: name everything the job reads (sources, lock files, toolchain files, scripts it
    runs). A job whose inputs cannot be named keeps no paths and is reused only for the same tree.
- **Before a rolling build: `testing ci superseded`.** `superseded=true` and `by=<sha>` (to `$GITHUB_OUTPUT`) when the
  tip of `--ref` (default `main`) is a strict descendant of the commit: the newer commit will build, this one need not.
  An error answers `false`, so the build happens rather than silently not.

A commit that was overtaken has no verdict of its own. When the newer one is red, `testing ci commit
--range=@{upstream}..HEAD` checks it along (`CI-04`).

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
