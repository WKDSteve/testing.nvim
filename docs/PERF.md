# Processes of a plugin (`testing perf`)

`testing perf` answers: **which processes does a plugin start while it is used, and what do they cost?** It runs
the test sheets of a repository ([SHEETS.md](SHEETS.md)), the feature sheets above all, in real child editors and
records every process start with its step, its caller and its time, and samples the process tree for memory and CPU.
The report lists findings (a freeze of the editor, a burst of starts, a large or long process, one that keeps running,
the same command again) and how much of the plugin's process code the run reached.

It measures, it never gates: the exit code says whether the run could be done. It does not belong in CI either (load
on a shared runner is noise); run it on a quiet machine and compare with the last run.

```
testing perf [<root>...] [--all <dir>] [--sheet <id>]... [--feature <id>]... [--real <prog,...|all>]
             [--interval <ms>] [--json <file>] [--markdown <file>] [--baseline <json>] [--keep-traces]
testing perf scan [<root>]        the spawn sites of a repository, nothing runs
```

| Option | |
|---|---|
| `<root>` | a repository (default the working directory); several may follow |
| `--all <dir>` | every repository below `<dir>` with a `.testing.lua`, one after the other |
| `--sheet <id>`, `--feature <id>` | only these sheets / the sheets of these functionalities |
| `--real <list>` | take these programs out of the sheets' `fakes` (`all`: every one); see below |
| `--interval <ms>` | how often the process tree is sampled (default 500, 100 to 60000) |
| `--json <file>` | the document `testing-perf/1` (the next run's `--baseline`) |
| `--markdown <file>` | the report; without it the report goes to stdout |
| `--baseline <json>` | an earlier `--json`: the report adds a comparison per repository |
| `--keep-traces` | keep the trace files of the children (one JSON line per start) and print where |

Exit codes: `0` done, `2` bad usage or every root refused (workspace trust, [CONFIG.md](CONFIG.md)), `3` no sheet ran.
On the workstation (`NVIM_MACHINE_ROLE=workstation`) the command is refused like every run. It lowers its own CPU
priority like the other heavy runs (`TESTING_PRIORITY=normal` keeps it).

## What is measured

Each rpc sheet runs as `testing sheets run` would run it: one child editor per size, the steps in order. A missing
snapshot is a failure and is never written. On top of that:

* **The spawn trace** (`testing.perf.trace`). The child installs it before the project's minimal init (the job field
  `preload` of the RPC child, `testing.child.rpc_init`), so the starts of a plugin's `setup()` are seen too. It wraps
  `vim.system`, `vim.fn.system`/`systemlist`, `jobstart`, `termopen`, `vim.uv.spawn`, `io.popen` and `os.execute` and
  writes per start: when (monotonic clock), the kind, the redacted argv (temporary folders as `<TMP>`), whether the
  editor waited for it (`sync`, a `wait()`) and how long, how long the process ran, its pid, and the caller:
  * `site`: the first frame outside Neovim's runtime (maybe inside lib.nvim),
  * `origin`: the first frame outside lib.nvim too (the plugin's own line), `plugin`: its repository.
  * A start asked for by a sheet step itself (an RPC chunk, `<nvim>`, before any plugin frame) or by a file below
    `TESTS/` is the sheet's **preparation** (`plugin = "sheet"`): counted apart, never a finding.
* **The steps**: their bounds are taken in the parent; every start falls into a step (`start` before the first:
  the editor and the setup; `after` after the last).
* **The process tree** (`testing.perf.tree`): every descendant of the running editor (the child and what it starts),
  sampled every `--interval` ms. On Windows one long-lived PowerShell (`lua/testing/perf/tree.ps1`, a CIM query per
  sample); on Linux `/proc`. It adds the largest working set and the CPU seconds to the starts it saw, and which
  processes still run when the last step is done. A process shorter than the interval may be missed: the trace still
  has it with its duration.

### Findings

| Kind | When | Default |
|---|---|---|
| `freeze` | a start blocked the editor longer than | 50 ms |
| `memory` | a process's working set peaked above | 300 MB |
| `cpu` | a process used more CPU than | 10 s |
| `left` | a process the plugin started still runs after the last step (language servers are not counted) | |
| `burst` | more starts of the plugin in one step than | 5 |
| `repeat` | the same command line again within | 2000 ms |

The same call in a loop is one line with a count (grouped by kind, program and calling line). The thresholds are
`require("testing.perf.report").THRESHOLDS`.

### Coverage

`testing.perf.scan` lists the **spawn sites** of the repository's `lua/` and `plugin/`: a line that calls a primitive
(the list above, `vim.lsp.start`), or a call into a module of lib.nvim that starts processes. Which modules those are
is computed from lib.nvim itself: a module whose code calls a primitive, or that requires such a module (four
rounds), so `git.run_async(...)` on `local git = require("lib.nvim.git")` is a site. A site is **reached** when a start
of the run has it as its `site` or `origin`. It is a heuristic on purpose: it finds the candidates, the run proves
which were reached; an unreached site is a functionality without a sheet, a sheet that does not go far enough, or a
case for `perf` below.

The report also lists the functionalities of the catalog (`TESTS/sheets/features.lua`) without a sheet.

## Real or a stand-in (`--real`)

By default a sheet's processes run for real (`git`, `rg`, a language server, a child editor): that is what is
measured. What a sheet replaces stays replaced: its `fakes` (a browser, `xdg-open`, the trash) and the network stubs
of its `lua` steps. Those starts are counted, not measured.

* `--real xdg-open,open` takes these programs out of the sheets' `fakes`: the real program runs (a window may open).
  `--real all` takes every fake out. A sheet that reads its fake's log then fails at that step; the starts up to
  there are measured.
* The child gets `TESTING_PERF_REAL` with the list. A step can skip its own stub when the run wants the real thing:
  `if not require("testing.perf.trace").real("network") then package.loaded[...] = stub end`.

## Functionalities that are not measured by their own sheets (`perf`)

A functionality of the catalog may say why ([SHEETS.md](SHEETS.md#feature-sheets-and-the-catalog-feature-testssheetsfeatureslua)):

```lua
{ id = "media.play", title = "Play a video in mpv", perf = "manual:opens an mpv window" },
{ id = "lsp.lensline", title = "lensline over the LSP pack", perf = "user" },
{ id = "sandbox.podman", title = "Run in a container", perf = "skip:podman is not on every machine" },
```

| `perf` | Meaning | In the report |
|---|---|---|
| `"user"` | only the installed config shows it (several plugins together, a real language server on a project): a sheet with `config = "user"` of the config measures it | listed |
| `"manual:<why>"` | a GUI, an account, real network, a container: a hand run with the process tools | listed; the hand run belongs in an acceptance task |
| `"skip:<why>"` | not worth measuring, or not allowed on this machine | listed |

A marked functionality is not counted as "without a sheet".

## Comparing runs

```
testing perf --all E:/repos --json perf-2026-11.json --markdown perf-2026-11.md
testing perf --all E:/repos --baseline perf-2026-11.json --json perf-2027-01.json --markdown perf-2027-01.md
```

The comparison shows per repository the starts of the plugin, the blocked milliseconds, the largest process and the
reached sites, each with its change.

## Limits

* Only rpc sheets are measured; browser, desktop, webview and manual sheets are listed.
* A start from Neovim's own runtime with no plugin frame (a language server started by `vim.lsp.enable`) has
  `plugin = "?"`; its argv names it.
* The sampler sees what lives at least one interval; CPU seconds of a process are read while it lives.
* Values from a loaded machine are orders of magnitude, not budgets: the report names the machine.
