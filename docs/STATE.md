# The last result (`testing.state`)

`runs.jsonl` ([CLI.md](CLI.md), `--lf`) keeps only the ids of the red cases. A UI needs more: the counters,
the duration, which cases are green, the message of a red one, and whether the file changed since the case
ran. `testing.state` is that shared state for an explorer, a hover, a quickfix list, diagnostics and a
statusline. It is a pure data module: no window, no buffer, no keymap.

```
stdpath('state')/testing/<project>/last.json   the last result per case, merged over partial runs
stdpath('state')/testing/<project>/prev.json   the one before it
```

`stdpath('state')` is the editor's real one for `testing run --state-dir <dir>` too: the generated `scripts/test.sh` asks for it
before it gives the specs a throwaway state and hands it down as that argument, so a run through the script updates the
same `last.json` the explorer reads.

Every run writes it after the history (`testing.run.project`). It is a convenience, never part of the verdict:
a failing write is a note (`testing: note: result not stored: ...`) and the run goes on.

## What it holds

Per case: `id`, `file`, `line`, `status`, `duration_ms`, `flaky`, `describe` (the titles, outermost first),
`name`, `fails` (every failing assertion as `{ line, msg }`, at most 20; the hover lists them for a file that is one
case) with `fails_total` (the count of ALL failing assertions, written only when it is above the 20 kept, read back
only as a whole number above `#fails` and up to 1,000,000), and for a red or skipped case `message` (first line of the first failing assertion, the error, or
the skip reason), `expected` and `actual`. Per spec file: `{ mtime_ns, size, run, ts }` from when its result
was recorded. The Result-IR carries `describe` and `name` as additive optional fields of a case
([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md)); a reader that does not find them falls back to the id.

## Merged, not replaced

`testing --file a_spec.lua` must not make the results of `b_spec.lua` disappear. A run replaces the cases it
produced (by id) and keeps the others. A file that ran **completely** forgets the ids it no longer produces
and renews its file record; a run with a case restriction (`--filter`, `--lf`, a stop) only replaces what ran
and is marked `partial`. A file that no longer exists is dropped with its cases.

## Stale

`is_stale(state, file)` compares the recorded `{ mtime_ns, size }` with the file now. A changed file, a
deleted one and a file without a record are stale (`changed`, `gone`, `no result`): the result of a stale file
must never be shown as a current green. `mtime_ns` is a **decimal string**: nanoseconds since the epoch do
not fit a double, and a number that went through JSON would not equal itself. File names are compared with
forward slashes, so a Windows path from a buffer finds its record.

## The API

```lua
local state = require("testing.state")
local st = state.load(root)                   -- always a state; st.notes says what was ignored
state.snapshot(st)                            -- counters: summary, cases, files, failed, stale, partial
state.case(st, id)                            -- one case
state.case_at(st, file, line, { exact = true }) -- the case a line belongs to
state.file_summary(st, file)                  -- counts, red ids, duration, stale + reason
state.is_stale(st, file)                      -- boolean, reason
state.failures(st)                            -- the red cases by file and line
state.newly_failed(st, state.load_prev(root)) -- ids red now and not in prev.json
state.apply(st, res, info)                    -- merge a finished run (in memory)
local off = state.subscribe(st, function(s, event) end)  -- called on apply; a broken subscriber hurts nobody
state.record(root, res, info)                 -- what the driver calls: read again under the lock, apply, write
```

## In a tree view

`testing.integrations.tree` shows the last result in a tree view. It registers two entries at
`lib.nvim.tree.registry`, which filetree.nvim's own tree (`adapter = "native"`) reads: a badge next to spec
files in every view, and a view of its own, `tests`.

### The badge

| On a spec file | Means |
| --- | --- |
| `✗ 2/14` | two of its fourteen cases are red |
| `~` | the file changed since its result was recorded (stale, whatever the result said) |
| `○` | nothing red, but a case did not run (skipped): not green |
| `✓` | every case green |

A folder shows the worst of what lies below it, also while it is closed.

### The view `tests`

`:Filetree source tests` (or the view bar of the tree) shows the last result as a tree: folder, spec file,
describe, case, plus the spec files below `TESTS` that never ran.

```
▾ Tests
  ▾ ✗ TESTS/
    ▸ · fresh_spec.lua                 never ran: opening it lists its describe / it calls
    ▸ ✓ green_spec.lua          2  8ms
    ▾ ✗ red_spec.lua          1/2  8ms red over all, the time
      ▾ ✗ red                 1/2  8ms
          ✓ one                    4ms
          ✗ two                    4ms
```

| Sign | Means |
| --- | --- |
| `✗` | red: `fail`, `error`, `timeout`, `crash`, `xpass` |
| `●` | running: the file is being run right now |
| `◌` | queued: the run will get to it |
| `~` | stale: the file changed since the result was recorded. An old red stays red, an old green is no green |
| `·` | never ran |
| `○` | skipped |
| `✓` | green: `pass`, `xfail` |

A folder, a file and a describe show the worst below them, in this order: `crash`, `error`, `timeout`,
`fail`, `xpass`, `running`, `queued`, `stale`, `never`, `skip`, `xfail`, `pass`. A skipped case keeps
what is above it from being green. What is red is open when the view is shown. The number next to the view
in the bar is the count of red cases.

A spec file that is one case (the `return function(H)` dialects) is that case; when it is red, its failing
assertions stand below it, each with its line.

| Key | Does |
| --- | --- |
| `<CR>` | on a case or an assertion: the spec file at that line; on a file: the file |
| `r` | run what the node stands for: the case, the describe, the file, the folder, or everything on the top line; with several nodes marked, all of them. On the nodes of the pipeline: the step, or the profile |
| `R` | run what failed last time (`--lf`) |

The run is the one of `:Testing run` (a headless child, the summary as a notification, the failures in the
quickfix list), and the view follows it while it goes (see below); every node keeps its place and its open
state. The keys are the view's own, in other views `r` and `R` keep their meaning; move or drop them with
`setup({ tree = { keys = { run = "<lhs>", failed = false } } })`, the actions stay in the tree's menu. To a tree
that asks a source for the preview of a node, a red case answers with what it said (status, message,
expected against actual, the failing assertions).

### The last pipeline run

When the project has a pipeline run on record (`testing ci`, [CI.md](CI.md)), it stands first in the view:

```
▾ Tests
  ▾ ✗ Pipeline fast           1/3  2.2s  red steps over all, the time
      ✓ stylua                     700ms
    ▾ ✗ luacheck                   1.5s
        unused variable x   lua/x.lua:3
      ○ suite                            skipped: the reason stands below it
  ▾ ✗ TESTS/
```

A step shows its state: `✓` green (or proven by an earlier run), `✗` red or the tools were missing, `○`
skipped. Below a red step stand its findings; `<CR>` on one opens the file at its line and column. `r` on a
step runs that step again (`:Testing ci <profile> --step=<name>`), on a finding the step it belongs to, on the
`Pipeline` line the whole profile; with several steps marked, those. A pipeline run that has ended shows by
itself, like a new result.

The document is the one `:Testing ci status` shows (`ci.json` in the state folder, the last run of any
profile). It is read as untrusted input: a size cap, every field checked, a step whose name could not be an
argument of the next run is left out, and a finding that points out of the project keeps its text and loses
its place.

A spec file that never ran is found by name (`*_spec.lua` below `TESTS`); a project with another
`spec_pattern` shows such a file after its first run. The view changes no file.

### While a run goes

A run started from this editor (`:Testing run`, `:Testing file`, `r` and `R` in the view, `require("testing").run`)
is followed case by case, in the view and in the badges of every other view:

1. the files of the run are queued (`◌`), the file that is being run is running (`●`, the badge of a spec file
   shows `●` too, and so do its folders);
2. every case gets its result the moment the run records it: its sign and time, the count and the sign of its
   file, its describe and its folders, and the badge of the file;
3. a case the run did not get to (a run narrowed to other cases) shows again what it showed before;
4. when the run has ended, the stored result is read again. A run that was stopped or crashed leaves the last
   good result: nothing stays `running`.

How: while a tree shows results, the child gets `--events=<file>` ([CLI.md](CLI.md)), a file in a folder `live`
below the state folder of the project, and the editor reads what is added to it ten times a second. The words of
a failure are not in that stream; they show when the run has ended. Without a tree that shows results nothing is
followed: no file, no flag, no timer. A run from elsewhere (a terminal, the CI) shows when it has written its
result.

### When it reads

`setup()` registers both entries (`setup({ tree = false })` registers nothing); nothing is read before a
tree asks. Then the result file of the project of the working directory is read once, and again when it
changes or the directory changes. Without a tree that reads the registry nothing happens, and without
`lib.nvim.tree.registry` (an older lib.nvim) the registration is skipped. `:checkhealth testing` says which
(`tests source: registered`, `not registered`, `no tree registry`).

## An untrusted file

`last.json` is read back like `runs.jsonl`: a size cap (`MAX_BYTES`) before decoding, `pcall` around the
decode, every field validated; a case that fails is dropped and counted in `notes`, a file that is not
usable (not JSON, an array, an unknown version, a directory) is ignored with a note. Titles and messages lose
their control characters and are cut (`MAX_TEXT`), so a terminal sequence in a test title does not reach a
window. Nothing from the file is used as a path. It is written atomically under the lock of
`testing.statelock`, bounded in bytes, cases and string lengths.

## The log of the runs

`runlog.jsonl` next to `last.json` has one line per run: time, `kind` (`run`, `ci`), `scope` (`full`, or `partial` for a
selection), `verdict`, duration, commit, whether the tree was dirty, the counters and up to 20 ids of red cases. `testing
history` reads it, and the export puts the newest 100 runs and the statistics into each `repos/<key>.json` (`history`).

It is appended under a lock, so a run does not get slower as the log grows. A line older than 90 days moves into
`runlog-days.json`, as counts of its day, and so does the oldest part of a file past 4 MiB. Like the other stores it is
a convenience, never part of a verdict, and it is untrusted when read back: a size cap, every line checked, a line that
fails is dropped and counted in a note.
