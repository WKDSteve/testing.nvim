# Test sheets (`testing.sheet`)

A live check is a check somebody does by hand: open a dialog, look at it, press a key. A **test sheet**
writes the same check down as data, so that the part a machine can do runs with the suite (through the
RPC klicker, [CHILD.md](CHILD.md)) and only the judgement is left for a person. `testing sheets report`
turns the sheets and their last result into the checklist a person works through.

## A sheet

`TESTS/sheets/<name>.sheet.lua` returns a table:

```lua
return {
  id = "ui.option-float",                -- stable; the spec case is called `sheet:<id>`
  title = ":UI option float",
  task = "ui.nvim/try-the-ui-option-float-in-a-real-session",   -- optional: where the check comes from
  engine = "rpc",                        -- "rpc" (default) or "manual"
  minit = "TESTS/minimal_init.lua",      -- default; relative to the project root
  sizes = { { rows = 24, cols = 80 } },  -- one run per size (default 24x80)
  args = { "+Session load x" },          -- optional (rpc): the child's command line after its own, no shell
  steps = {
    { lua = 'require("ui").setup({ usrcmds = true })' },
    { keys = ":UI<CR>", note = "open the float" },
    { wait = "vim.api.nvim_win_get_config(0).relative ~= ''" },
    { screen = "float", masks = { { row = 24 } } },
    { keys = "q" },
    { expect = "vim.api.nvim_win_get_config(0).relative == ''", note = "the float is gone" },
  },
  judge = { "the rows and texts read well" },        -- criteria for a person (later an AI reviewer)
  manual = { "the cheatsheet key <M-h> of the real config opens it" },  -- steps only a person can do
}
```

| Step | Does | Fails when |
|---|---|---|
| `keys = s` | typed through `child.feed` (mappings apply, returns when the typeahead is empty) | the keys left an error message (`v:errmsg`, e.g. `E492`); `ignore_errmsg = true` for keys that run `silent! cmd` on purpose (it still sets `v:errmsg`) |
| `input = s` | queued through `child.input` (returns at once); the way into insert mode (`input = "A"`, then a `wait` for the mode): `keys` feeds with `x`, which ends insert mode again | never |
| `lua = s` | runs in the child | it raises |
| `settle = ms` | waits until the child is idle | it is not idle in time |
| `wait = expr` (`timeout` ms, default 2000) | polls a Lua expression in the child | it is not truthy in time |
| `expect = expr` | evaluates a Lua expression in the child now | it is not truthy |
| `screen = name` (`masks`, `cursor`, `mode`, `groups`) | compares the screen with a snapshot ([CHILD.md](CHILD.md#screen-snapshots-testingscreen)); the name gets the size: `float.80x24`; `groups = true` keeps the highlight group of every attribute letter in it | the snapshot differs (or is missing on CI) |
| `hl = { ... }` | how a place is drawn: `text = "..."` (its first appearance on the screen, every cell of it) or `row`, `col` (`cols` wide), and what must hold: `group` (by its name, or the group a link ends in: `group = "FileopsConflict"` holds for a cell drawn with `DiffText` when it links there), `fg`, `bg`, `sp` (`#rrggbb` as drawn), `bold`, `italic`, `underline`, `undercurl`, `strikethrough`, `reverse` (`false` = must not be) | a cell is drawn otherwise (the line names it, what it has and what was expected), the text is not on the screen, or the group is not defined |
| `restart = true` (`args`) | quits the child as a person does (`:qall!`: `VimLeavePre` and `VimLeave` run, a session plugin writes its files) and starts it again **in the same sandbox** (its `stdpath` and temp directories stay), the UI attached again at the sheet's size; `args = { ... }` on the step is the command line of this start, without it the sheet's `args` | the editor does not quit within 10 s (it is killed), or the new one does not start |

Milliseconds are whole numbers up to 600000 (10 minutes), sizes up to 1000 rows or columns (4000 pixels for a browser or desktop sheet): an endless wait
is a mistake, not a check. Every step may carry a `note`; a failure names the size, the step number and the
note, and all failures of a sheet are one line. The first failed
step ends that size (the steps after it depend on it). The UI is attached before the first step, so windows
and floats are laid out for the sheet's size.

`args = { ... }` (rpc sheets) is the child's command line after its own, a list without a shell: `+cmd` and `-c cmd`
(at most 10, as the editor takes them), `--cmd cmd` (at most 9) and file names, relative to the project root, the
child's working directory. Every other option is refused when the sheet loads (`args[1]: "--listen" is refused`): the
harness owns the rest of the command line (`--embed`, `-u`, `--clean`, `-i NONE`). The commands run at startup, before
the UI is attached; so that what they lay out fits the sheet's size, as in a terminal, the harness puts
`--cmd "set lines=<rows> columns=<cols>"` first whenever there are `args` (the tenth `--cmd`). With `restart` a sheet
checks what survives an exit, for example a session written on `VimLeavePre` and loaded by `+LastSession`:

```lua
steps = {
  { lua = "vim.cmd.vsplit('b.txt')" },
  { restart = true, args = { "+LastSession" } },
  { expect = "#vim.api.nvim_list_wins() == 2", note = "the split is back" },
},
```

`requires = { { lua = "<expr>", reason = "<n/a text>" } }` (rpc sheets) lists what the child editor must have, for example
an optional plugin: each expression is evaluated in the child before the first step, and the first one that is not
truthy makes the sheet a **reported skip** (`status = "skip"`, the case prints `n/a  <reason>`), never a green run. An
expression that raises fails the sheet.

The file is read as **data**: `load` with an empty environment, so a sheet cannot call anything while it is
read (a sheet that touches `os` does not load). What runs is the Lua of its steps, inside the child editor.
`load` checks the shape and names the field of a mistake (`steps[3] has two actions (keys and lua)`).

## A sheet from a task (`testing sheets new`)

```
testing sheets new --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--tasks-cli <tasks.lua>] [--name <file>]
```

reads the live-check task through tasks.nvim (`call task`) and writes a **draft** `TESTS/sheets/<slug>.sheet.lua`
into the repository (default the current directory):

* `id` is the task's slug (or `--name`), with what an id does not allow (`/`, spaces, non-ASCII) made `-`; the
  file is named like the id, so a second sheet of the same task (`--name`) is a case of its own. `title` is the
  task's title (the id when it is empty), `task` the id given (letters, digits, `_`, `-`, `.` and one `/`).
  Strings are quoted as Lua strings and cut to 300 characters, so any title loads.
* `steps` is a skeleton that runs as it is: the intro screen off (it names the Neovim version), a setup step to
  fill in, `settle`, one `screen`. It checks nothing yet: write what a person would do.
* `judge` has one entry per checkbox (`-`, `*`, `+` or `1.` list items) under a level 1 or 2 heading `Akzeptanz` /
  `Acceptance`, up to the next such heading (ticked or not, at most 30). Boxes in a fenced code block or another
  section do not count; fences and headings are read as CommonMark does. A task without boxes gets one entry
  from its title.
* `notes` and the header comment say `DRAFT`: drop them once the steps are real and the snapshot is reviewed.

An existing sheet is **never overwritten** (exit 2; `--name` writes another file): the file is created
exclusively, so one that appears meanwhile is not written over either. The written file is loaded right away; a
draft that does not load is removed again. The vault is `--vault`, else `$TASKS_VAULT`, else
`<repo>/../tasks-vault`; the engine is found as for `--tasks` below. Exit codes: 0 written, 2 bad usage or the
sheet exists, 3 no vault or engine, the task could not be read, the file not written or the draft does not load.

## Running sheets

Each sheet is one case of an ordinary spec, named `sheet:<id>`; the report finds its last result by that
name in `testing.state`. A busted style spec:

```lua
-- @cache-inputs TESTS/sheets/ TESTS/__snapshots__/
local sheet = require("testing.sheet")
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

describe("test sheets", function()
  for _, path in ipairs(sheet.files(root .. "/TESTS/sheets")) do
    local s, err = sheet.load(path)
    it(s and sheet.spec_name(s) or path, function()
      assert(s, err)
      sheet.check(s, { root = root })
    end)
  end
end)
```

`sheet.expect(H.ok, s, opts)` hands the verdict to a collecting harness instead of raising; `sheet.run(s, opts)`
returns `{ ok, status, failures, snapshots }`. A project whose process guard is strict lists `nvim` in
`guard_allow.spawn` (the sheet starts a child editor). A `manual` sheet runs nothing (status `manual`).

## The report

```
testing sheets report [<root>...] [--from <ir.json>]... [--out <file>]
```

reads the sheets of every root (default the current directory) and the last results, and writes one
Markdown list (stdout without `--out`). The last results come from the editor's state (`testing.state`,
written by `testing run` and `:Testing`) or, with `--from`, from the Result-IR of a run
(`testing run --json <file>`). `scripts/test.sh` runs with a throwaway app name and stdpath, so its
results never reach the state: run it with `--json <file>` and pass that file. An IR says nothing about
staleness (it is one run); several `--from` files are merged by case name.

| Section | What is in it |
|---|---|
| Red, stale or not run | the case failed, its spec file, the sheet or one of its snapshots changed since it ran, it never ran, or the sheet does not load |
| Review inbox | the automated part is green and the sheet has `judge` criteria: the criteria as checkboxes and the snapshot files to look at |
| Manual | the `manual` steps (of a manual sheet, or of a green sheet without `judge`) |
| Automated | green, nothing left for a person |

Under a sheet whose last stepped run (`testing sheets step`) took notes, the list adds them: `notes of the stepped
run on <date> (<status>):` and one item per note (`step <n> (<size>): <text>`), also for a run that was aborted.

Text from a sheet or a result is written on one line (a newline in a title cannot start a heading or a
checkbox), and a backtick cannot end an inline code span. Nothing is run by the report: run the suite first. Exit codes: 0 written or printed, 2 bad usage, 3 the
file could not be written.

## Into the tasks (`--tasks <vault>`)

A sheet names its live-check task (`task = "ui.nvim/..."`). With `--tasks <vault>` the report also writes the state
of every sheet into that task, as a generated block in front of `## Notizen` / `## Notes` (or at the end):

```
<!-- testing:sheets:begin -->
## Test sheets

_Generated by `testing sheets report --tasks`; edit the sheet, not this block (ticked boxes are kept)._

- **:UI option float** (`ui.option-float`, `ui.nvim/TESTS/sheets/ui-option-float.sheet.lua`): automated part green, waiting for your judgement
  - Judge:
    - [ ] The rows and texts of the float read well
  - By hand:
    - [ ] In the real config the cheatsheet key <M-h> opens the same float
  - Look at: `ui.nvim/TESTS/__snapshots__/sheets/ui-option-float.sheet/float.80x24.snap`
<!-- testing:sheets:states ui.option-float=inbox -->
<!-- testing:sheets:end -->
```

* A second run replaces the block; a box ticked in the task (by hand, or by an app) stays ticked. The block has no
  date, so a task only changes when the state of its sheets does, and its paths always name the project, whatever
  roots the report was given.
* The notes of a stepped run (`testing sheets step --tasks`, `note <text>`) go into the block as a paragraph of their
  own, after the sheets and in front of the `states` line:

  ```
  ### Notizen aus dem Durchgang 2026-11-10 (`ui.option-float`)

  - Schritt 2 (80x24): the border flickers once
  ```

  Every later report keeps these paragraphs as they stand (from the first such heading to the `states` line, also what
  a person added to them); the next stepped run with notes adds its paragraph after them. A block without notes is
  unchanged (the golden block has none). A note is one line; `<!--` in it is written `<!-`, so it can neither end the
  block nor hide text. tasks-desktop does not read these lines.
* The last line inside the block is for programs: `<!-- testing:sheets:states <id>=<state> ... -->`, one entry
  per sheet (its id, or the file name of a sheet that does not load) with `red` (failed or does not load),
  `stale`, `never`, `inbox` (green, waiting for your judgement), `manual` or `green`. tasks.nvim reads this line
  (`show`, the dashboard, `list --sheet=`). **The text above it is a contract too**: tasks-desktop parses the sheet line
  (`- **<title>** (`<id>`, `<project>/<path>`): <state>`), `Judge:`, `By hand:`, `Look at:` and the checkboxes
  (`- [ ]` / `- [x]`) and writes ticks back. Their wording and layout are frozen; only additions at the end of a line
  are allowed. The golden block `TESTS/golden/sheet-block/sheet-block.golden.md` (input `entries.lua`, regenerated by
  `TESTS/golden/regenerate_sheet_block.lua`) is compared byte for byte (`sheet_block_golden_spec`); tasks-desktop keeps
  a copy checked against `SHA256` in the same folder. The prose lines (title, "Generated by ...") are not read. A sheet
  that does not load still reaches its task as `red` when its file has a `task = "<area/slug>"` line of its own
  (read as text, nothing runs), so a broken sheet never leaves the rest of the task looking green.
* Only a marker on a line of its own and outside a fenced code block counts (one quoted in prose or code is text),
  and so does only a notes heading outside a fence. Fences are read as CommonMark does (the same rule as
  tasks.nvim): up to 3 spaces, closed only by the same character, at least as long, with nothing after it. A task whose markers are broken (a begin without its end, an end
  in front of the begin, two of them) is **not written**: it is reported (exit 1) and fixed by hand, so no text
  between stray markers is ever replaced. A task file with CRLF line endings is sent back with line feeds (the
  engine keeps the file's own ending).
* Reading and writing go through the engine of tasks.nvim, never into the files: `call bodies` for every task named
  (asked again for the ids a 2 MiB page did not reach), `call ops` with a `set_body` per changed task and `if_match` =
  the version read, in requests of at most 100 operations and about 200 KiB. A task edited in between is a
  `conflict` (reported, exit 1), not overwritten.
* A task that is not open (finished or unknown) is reported (`task <id> missing`) and the list says so under the
  sheet. A sheet without `task` is left out.
* The conformance check **K16** (`testing conformance`, [CONFORMANCE.md](CONFORMANCE.md)) turns the other half of
  this into a gate: a sheet whose task is neither open nor finished, a sheet that does not load, is a finding
  (`--gate`: exit 1). A sheet without `task` is a warning there.
* The engine is found like a dependency: `$TASKS_NVIM_DIR`, `<vault>/.deps/tasks.nvim`, `<vault>/../tasks.nvim`,
  `stdpath('data')/lazy/tasks.nvim`; `--tasks-cli <path/to/scripts/tasks.lua>` names it. `--dry-run` says what would
  change and writes nothing.

```
testing sheets report <root>... --from <ir.json>... --tasks <vault> [--dry-run]
```

Exit codes: 0 done, 1 a task could not be written (conflict, refused, a body too long to send back), 2 bad usage, 3
the engine could not be reached or the file not written.

## One task, now (`testing sheets run`)

```
testing sheets run --task <area/slug> [--root <dir>]... [--tasks <vault> [--tasks-cli <tasks.lua>] [--dry-run]]
```

runs the sheets that name the task (a sheet that does not load too) and, with `--tasks`, writes their state into
the task's block: no suite, no second command. tasks.nvim's `:Tasks sheet-run` calls it.

* The roots are `--root` (repeatable), else the task's area as a repository: `$REPOS_DIR/<area>`, else
  `<vault>/../<area>`. With `--tasks` the projects the task's block already names join them (found the same way):
  the block is written whole, so a sheet of the task in another project runs too instead of dropping out. A project
  that is not found is refused (pass `--root`). The engine is found before a sheet runs.
* Each root passes the workspace trust gate first (a sheet runs the project's minimal init).
* A missing snapshot is a failure, as on CI: a run from a task never writes a reference image (run the spec once).
* On the workstation (`NVIM_MACHINE_ROLE=workstation`, trimmed, any case) only **manual sheets** run
  (`engine = "manual"`: questions and steps for a person, nothing is started for them). The decision waits until every
  sheet of the run is loaded as data: one rpc, browser or desktop sheet among them, or one that does not load, refuses
  the whole run (exit 2, nothing ran), unless `TESTING_ALLOW_WORKSTATION=1`. With `--tasks` the result is written
  through the engine of tasks.nvim (`nvim -l`, as `:Tasks` does there). A value that is neither `workstation` nor
  `default` is refused as a typo.
* A red sheet carries its first failure line into the block (`red: 80x24 step 3, keys ...`).

Exit codes: 0 green (or waiting for a person) and written, 1 a sheet is red or the task could not be written, 2 bad
usage, refused (trust, workstation) or no sheet names the task, 3 the engine of tasks.nvim could not be reached.

## Hand over to an AI (`testing sheets prompt`, `testing sheets accept`)

Stage 0 of the AI link: no model is called here (ai.nvim's headless entry comes later). The commands write a Markdown
document a person pastes into the AI of their choice, and take the answer back only through a check.

```
testing sheets prompt draft --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--out <file>]
testing sheets prompt explain --task <area/slug> [--root <dir>]... [--tasks <vault>] [--out <file>]
testing sheets accept --task <area/slug> --from <file> [--repo <dir>] [--name <file>]
```

* `prompt draft`: asks for a sheet for the live check. The document holds the task (title and body, without the
  generated block of the last report, cut at 32 KiB), the rules of the sheet format and the skeleton
  `testing sheets new` would write; the answer asked for is one ```lua block that returns the sheet.
* `prompt explain`: runs the task's sheets as `testing sheets run` does (trust gate, workstation rule, as on CI) and
  writes nothing into the task. For each red sheet the document holds every failure line (a snapshot failure shows
  the first differing rows), its snapshot files and its source; the answer asked for is the cause and, for a bug of
  the plugin, one ```task block (`title:`, `summary:`) that tasks.nvim turns into a bug task after confirmation. No
  red sheet: nothing is written (exit 0, a note on stderr).
* `accept`: takes the answer's last ```lua block (at the start of a line, any case; the whole text when it has
  none) and writes `TESTS/sheets/<id>.sheet.lua` of the area's repository (`--repo`, else `$REPOS_DIR/<area>`, else
  beside `--vault`) only when it loads (`sheet.load`, as data; reading stops after a million instructions, so a loop
  in a draft ends), names the task and no sheet of that name exists (created exclusively).

What the model sees is exactly the document: the task's title and body, the sheet format, the skeleton, and for
`explain` the failure lines, snapshot file names and the sheet's source. A project's path is written as its name
(`ui.nvim/TESTS/...`). The failure lines show what the child editor showed or returned (a snapshot's differing rows,
`got <value>`): what a sheet puts on the screen goes to the model too. A vault or root whose path names `tricentis`,
as written, made absolute or resolved (a link, `--vault .`), is refused (exit 2): its tasks may carry customer data,
and nothing of them is handed to an AI.

## Step by step (`testing sheets step`)

```
testing sheets step <sheet> [--root <dir>] [--headed] [--delay <ms>] [--break <n>]... [--run] [--tasks <vault> [--tasks-cli <tasks.lua>]]
```

runs one sheet the way a debugger runs a program: it stops before a step, says what the step will do, runs it when
told to and says what came of it. `<sheet>` is a file, or an id or file name below `<root>/TESTS/sheets` (the root is
`--root`, else the project of a file below `TESTS/sheets`, else the current directory). The workstation rule and the
trust gate are those of `testing sheets run`.

This is about the declarative steps of a sheet. Debugging the Lua code of a spec is another level: `--debug`
(breakpoints through osv and dap.nvim).

Every surface is a client of the same two streams. **stdout** has one JSON object per line
(`testing-sheet-session/1`, [schema](../schemas/testing-sheet-session/1/testing-sheet-session.schema.json); a reader
ignores unknown events and fields and refuses a higher schema), written as it happens:

| Event | Says |
|---|---|
| `start` | the whole sheet: id, title, engine, sizes, every step with its number, action, value and note |
| `size` | the target of a size is `open`, `failed` to start, or the sheet is a `skip` |
| `step-before` | size, number, action, value, note: what is about to happen |
| `paused` | waiting for a command; `reason` is `start`, `step`, `break`, `until` or `failed` |
| `step-after` | `status`, `ms`, on a failure `reason` and the `failure` line of a normal run; `shot` the file of a `shot` step; `image` the picture of the target after this step (browser and desktop sheets; a folder per sheet under `stdpath("cache")`, emptied by the next stepped run, `sheet.run` makes none); `screen` the child's screen as text, one string per row (rpc sheets) |
| `ask` | a question to a person (`ask` step): `size`, `n`, `text`. The run waits for `answer` |
| `note` | a note was taken: `size`, `n` (the step the run stands before, else the one that ran last), `text`, `time` (UTC) |
| `task` | with `--tasks`: what became of the task's block (`id`, `outcome`, `message`) |
| `error` | a command it could not do; the run stays paused |
| `end` | `status` (`pass`, `fail`, `skip`, `manual`, `aborted`), `ok`, `verdict`, `failures`, `snapshots`, `skipped`, `ms`, `answers`, and `notes` when there are any. The target is gone by then |

**stdin** takes one command per line:

| Command | Does |
|---|---|
| `next` | runs this step, stops before the next one |
| `continue` | runs on, to a `--break`, a failed step or the end |
| `until <n>` | runs on and stops before step `n` of a size |
| `break <n>`, `clear <n>` | sets or removes a breakpoint, as `--break` does, in every size; the run stays paused |
| `answer yes\|no [text]` | answers a question; a no fails the step, with the text as its reason |
| `note <text>` | a note on the step the run stands before (after a failure: the failed one), one line of at most 1000 bytes, at most 200 notes in a run; taken at once, also while a step runs or under `continue`; the run stays where it is |
| `abort` | ends the run at once |

* Closed stdin is `abort`, and so is a client that dies or stops reading stdout: nothing stays behind. An abort reaches a
  running `wait` and a running browser step at once, any other step when it returns.
* A failed step pauses even under `continue`, before the next size or the end takes the target away, so a person can
  look at it. The first failed step still ends its size.
* `--break <n>` stops before step `n` of every size. `--delay <ms>` waits before each step that does not stop, to give
  the eye a chance. `--run` starts as if `continue` had been said and reads no commands at all, not even a closed
  stdin (`--break` is refused with it): for watching, not for a client.
* `--headed` opens a visible window for a browser sheet, with Playwright's Chromium, else an installed Chrome or Edge;
  an rpc sheet has none, its child editor shows up as the `screen` text of each step.
* Notes stay beside the pictures of the run (`notes.json` in its folder under `stdpath("cache")`, emptied by the
  next stepped run of the sheet), also after an abort: `testing sheets report` shows them. With `--tasks` a run that
  counts adds them to the task's block as a paragraph (see above); an aborted one writes nothing into the task.
* It writes no state and no snapshot (a missing snapshot is a failure, as on CI). `verdict` in `end` says whether the run
  counts as one: only a run that went through without an abort. Only such a run writes anything: with `--tasks <vault>`
  its state goes into the task's block and a question answered yes ticks its box (a no leaves it, and the sheet is red).
  The block is written whole, so a task with another sheet is refused before anything runs (`testing sheets run --task`).
* Exit codes: 0 green or a skip, 1 a step failed, 2 bad usage or refused (nothing ran, no event, the reason on stderr),
  3 aborted.

From the editor: `:Testing sheet step [<sheet>]` ([BINDINGS.md](BINDINGS.md)) is a client of this command, with the steps
in a buffer and, under them, what the step under the cursor did and its notes (`N` takes one). Debugging the Lua code of a spec stays `--debug`.

Underneath is `require("testing.sheet.session")`: `open(s, opts)`, `peek()` (the next step, starting the target of a
size when needed), `step()`, `close()` (always), `result()` (the shape of `sheet.run`), `cancel()`. `sheet.run` of an
rpc sheet is the loop over it. A browser sheet runs one step at a time through `browser_runner.mjs --driver`, which
speaks `testing-sheet-driver/1` ([schema](../schemas/testing-sheet-driver/1/testing-sheet-driver.schema.json): one JSON
line per command on stdin, `open`, `step`, `close`, one answer on stdout; the end of stdin means close). `sheet.run` of a
browser sheet still runs the plan in one go, through the same step function: the suite has no use for a channel
that could hang.

## Questions (`ask`)

`ask = "text"` is a step in every engine: what only a person can judge, at the place where it can be judged.

* In a stepped run it stops and asks, under `continue` too. Yes goes on; no fails the step, and the note of the answer is
  the reason.
* In any other run (the suite, `sheets run`, `--run`) nobody can answer: the step passes over and the text is a `judge`
  criterion of the sheet, with the same line in the task and the same inbox.
* A sheet with `engine = "manual"` can hold questions and nothing else: a guided walk through what no machine can do.

## Apps (`sheets.apps`)

A browser sheet can run against a program of the project. The sheet stays data and only names it (`app = "demo-hub"`,
and `open = "${link}"`); how it starts is in `.testing.lua`, which runs under the trust gate anyway:

```lua
return {
  sheets = {
    browser = { playwright_dir = "tools/page-check", channel = "chrome" },
    apps = {
      ["demo-hub"] = {
        build = { "cargo", "build", "-p", "pult-hub", "--example", "demo-hub", "--locked" },
        run = { "target/debug/examples/demo-hub.exe" },
        env = { PULT_PORT = "0", PULT_CONFIG_DIR = "${temp}" },
        ready = { stdout = "^http", as = "link" },
      },
    },
  },
}
```

* `build` and `run` are argv lists, never a shell, and run in the project root. A program named by a path is relative
  to the root; a bare name comes from the PATH, on Windows through PATHEXT too, so `pnpm` finds `pnpm.cmd`. `build` may
  also be a list of such lists, run one after the other (`build = { { "pnpm", "--dir", "ui", "build" }, { "cargo",
  "build" } }`); the first one that fails ends it and the failure names its number. A batch file (`.cmd`, `.bat`) is run by
  `cmd.exe`, which reads its arguments again: one with a quote, `%`, `&`, `|`, `<`, `>`, `^` or a line break is
  refused, not quoted.
* `${temp}` is a folder of this run, removed afterwards: the user's real settings stay untouched. It can be used in `run`
  and `env`.
* `ready` waits (`timeout_ms`, default 30 s) for a line on the app's stdout that matches the Lua pattern `stdout`; `as`
  makes the trimmed line available in the `open` steps of the sheet. Only fixed names are filled in, an unknown one
  fails the step, no Lua runs.
* One app for the whole sheet, all sizes. At the end its stdin is closed, then the whole process tree is ended.
* An app that does not build, does not start or does not get ready fails the sheet, with what it said.
* `sheets.browser`: `playwright_dir` is the folder (relative to the root) whose `node_modules` holds `playwright-core`;
  `channel` runs an installed browser (`chrome`, `msedge`) instead of Playwright's Chromium, and without it the sheet is
  a skip, not a run in another browser.
* `window` is a part of the title of the app's window, for a desktop sheet; `ended_early` see [Desktop sheets](#desktop-sheets-enginedesktop).

A repository without a Lua spec needs no suite for its sheets:

```
testing sheets run --all [--root <dir>]... [--engine <name>] [--json <ir>] [--strict]
```

runs every sheet of the roots, with `--engine` only those of that engine (default the current directory; trust gate and workstation rule as above) and writes
the Result-IR `testing sheets report --from` reads. `--strict` makes a skip red, for a CI job that exists to prove
something: without it a missing browser would leave the job green. Exit codes: 0 green, 1 a sheet is red (or a skip
with `--strict`), 2 bad usage, refused or no sheet, 3 the IR could not be written.

## Desktop sheets (`engine = "desktop"`)

A sheet with `engine = "desktop"` works in the real window of a program, the way a screen reader does: by accessible
name, through `sheet-driver` (appkit; UI Automation on Windows). What it can operate is what a screen reader can
operate. It names its app (see [Apps](#apps-sheetsapps)), and `window` in the app's entry is a part of its title.

```lua
return {
  id = "pult.demo-window",
  title = "pult: the window with the demo desk",
  engine = "desktop",
  app = "demo-window",
  sizes = { { cols = 1300, rows = 800 } },       -- the size of the window in pixels
  steps = {
    { wait = { name = "Spotify.exe mute" }, timeout = 15000, note = "the desk is there" },
    { toggle = "Spotify.exe mute" },
    { expect = { name = "Spotify.exe mute", state = "on" } },
    { set = "Spotify.exe gain dB", value = -12 },
    { expect = { name = "Spotify.exe gain dB", value = -12 } },
    { click = "Matrix" },
    { shot = "matrix" },
  },
}
```

| Step | Does | Fails when |
|---|---|---|
| `wait = name` or `{ name, state, value }` (`timeout` ms, default 2000) | waits until the element is there and holds what is asked; `state` is `on` or `off` | it does not in time |
| `expect = ...` | the same, for 1 s: a window draws a change in a later frame | it does not |
| `toggle = name` | switches a toggle | the element has no toggle |
| `click = name` | invokes a button or selects a tab | it can do neither |
| `set = name`, `value = n` | sets a slider | it has no settable range |
| `shot = name` | a picture of the window, `TESTS/sheets/out/<id>.<name>.<w>x<h>.png` | never |

* A name that is not there fails the step, and so does a name that is there twice: a guess would act on the wrong control.
* The driver is `$TESTING_DESKTOP_DRIVER`, else `sheet-driver` on the PATH (`cargo install --path crates/sheet-driver` in appkit). Without one, the sheet is a reported skip.
* `ended_early` in the app's entry is the text of a skip for a program that ends at once with success, like a second
  instance that hands over to a running one. Without it that is a failure.
* The window does not need the focus and may be covered, but starting the program takes the focus. A minimized window or
  one in the tray does not answer: such a step belongs on the app's control interface or to a person. An action goes around
  the hit test of the mouse, so a covered button "works": whether it looks right is `shot` and `judge`.
* A window on the runner is a question of its own: `testing sheets run --all --engine browser` leaves desktop sheets out of a
  CI job (a sheet that does not load stays in, it is red in every job).

## Limits

* The engines are RPC, browser and desktop; terminal byte streams are a later engine.
* `judge` is for a person; an AI reviewer that pre-sorts the inbox does not exist yet.
* A step's Lua is code: review a sheet like a spec.

## Browser sheets (`engine = "browser"`)

A sheet with `engine = "browser"` opens a page in a real chromium (Playwright) and presses keys there. The steps are
data like the others, but they are a different set; `wait` and `expect` are JavaScript expressions **in the page**:

| Step | Does | Fails when |
|---|---|---|
| `open = target` | loads a URL, or a file (relative to the project root) | the page does not load |
| `press = key` | a key by Playwright name (`Tab`, `Shift+Tab`, `Escape`, `Control+k`) | never |
| `click = selector` | clicks the first element that matches the CSS selector | none matches in 5 s |
| `hover = selector` | moves the pointer over the element and leaves it there: a later `expect` or `shot` sees its `:hover` state (JavaScript cannot trigger `:hover`) | none matches in 5 s |
| `focus = selector` | gives the element the keyboard focus (`:focus`, the focus ring) | none matches in 5 s |
| `blur = true` | takes the keyboard focus from whatever has it (the next key goes to the page): the way back from a `focus`, without an `expect` that does it on the side | something but the page itself holds the focus afterwards (a handler gave it to another element) |
| `scheme = "light"\|"dark"` | the page's `prefers-color-scheme` from now on, without a reload | never |
| `wait = js` (`timeout` ms, default 2000) | waits until the expression is truthy | it is not truthy in time |
| `expect = js` | evaluates the expression now | it is not truthy |
| `shot = name` | a screenshot `TESTS/sheets/out/<id>.<name>.<w>x<h>.png` (the input of the AI judge) | never |

A `shot` name is part of a file name: letters, digits, `_` and `-` only; `open`, `press`, `click`, `hover` and `focus`
must not be empty and `scheme` is `light` or `dark` (all of them are refused when the sheet loads). The looks of a
control in one sheet: `{ scheme = "dark" }`, `{ hover = "#save" }`, `{ shot = "save-hover-dark" }`, `{ focus = "#save" }`,
`{ shot = "save-focus-dark" }`, `{ blur = true }`, and a `judge` line for the person who looks at the shots.

`sizes` are the viewport in pixels (`cols` = width, `rows` = height; default 1000 x 700, at most 4000 each). A step of the other engine
is refused when the sheet loads (`steps[2]: keys is not a step of a browser sheet`). The first failed step ends a
size. The runner is `lua/testing/sheet/browser_runner.mjs` (node + `playwright-core`, found in
`$TESTING_PLAYWRIGHT_DIR`, the project or `../mdview.nvim`). Without node, `playwright-core` or chromium the sheet
is a **reported skip** (`status = "skip"`, the case prints `n/a  <reason>`), never a green run. There is no
`prepare` step on purpose: a sheet is data and must not start programs; a page a sheet needs is a file the project
produces (a fixture, a build output), or a program it names (`app`, see [Apps](#apps-sheetsapps)).
