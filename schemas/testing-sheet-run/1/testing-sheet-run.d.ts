/**
 * The last line of stdout of `testing sheets run ... --result` (document testing-sheet-run/1). The exit code is 1 for
 * a red sheet and for a task that could not be written alike; `red` and `written` tell the two apart. A reader ignores
 * unknown fields.
 */
export interface TestingSheetRun {
  schema: "testing-sheet-run/1";
  /** 0 green and written, 1 a sheet is red or a task was not written, 3 tasks.nvim could not be reached after the sheets ran. */
  exit: 0 | 1 | 3;
  /** The task of `--task`; null for `--all` and `--sheet`. */
  task: string | null;
  /** The sheets of the run, in the order they ran. */
  sheets: Sheet[];
  /** A sheet failed or does not load; under `--strict` a skipped sheet too. */
  red: boolean;
  /** With `--tasks`: what became of the block of each task. Empty without it. */
  tasks: Task[];
  /** Every task's block stands as the run left it; null: nothing was to be written (no `--tasks`). */
  written: boolean | null;
  /** Why no task could be written at all (exit 3). */
  problem?: string;
}

export interface Sheet {
  /** The id of the sheet; of a sheet that does not load, its file below the root. */
  id: string;
  status: "pass" | "fail" | "skip";
}

export interface Task {
  id: string;
  /** `changed`, `unchanged`, `would_change`: the block stands. Anything else (`failed`, `missing`, `truncated`): it does not. */
  outcome: string;
  /** The reason of an outcome that is not written. */
  message?: string;
}
