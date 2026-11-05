/** One line on stdout of `testing sheets step`. A reader ignores unknown events and fields and refuses a higher schema. */
export type TestingSheetSessionEvent =
  | Start
  | Size
  | StepBefore
  | StepAfter
  | Paused
  | Ask
  | Task
  | CommandError
  | End;

/** One line on stdin of `testing sheets step`. Closed stdin is `abort`. */
export type TestingSheetSessionCommand =
  | "next"
  | "continue"
  | `until ${number}`
  | `answer ${"yes" | "no"}${string}`
  | "abort";

interface Base {
  schema: "testing-sheet-session/1";
}

export interface Start extends Base {
  event: "start";
  id: string;
  title: string;
  engine: string;
  task?: string;
  /** The program of `sheets.apps` the sheet runs against. */
  app?: string;
  path?: string;
  root: string;
  sizes: { rows: number; cols: number }[];
  steps: { n: number; action: string; value: string | number; note?: string }[];
  /** A visible window: asked for with --headed and the engine has one. */
  headed: boolean;
  delay_ms: number;
  breaks: number[];
  judge?: string[];
  manual?: string[];
}

export interface Size extends Base {
  event: "size";
  /** `80x24`. */
  size: string;
  state: "open" | "failed" | "skip";
  reason?: string;
}

export interface StepBefore extends Base {
  event: "step-before";
  size: string;
  n: number;
  total: number;
  action: string;
  value: string | number;
  note?: string;
}

export interface StepAfter extends Base {
  event: "step-after";
  size: string;
  n: number;
  status: "pass" | "fail";
  ms: number;
  reason?: string;
  /** The failure line as a normal run writes it. */
  failure?: string;
  /** The file of a `shot` step. */
  shot?: string;
  /** rpc engine: the child's screen after the step, one string per row. */
  screen?: string[];
}

export interface Paused extends Base {
  event: "paused";
  size: string;
  /** The step about to run; after `failed` the step that failed. */
  n: number;
  reason: "start" | "step" | "break" | "until" | "failed";
}

/** A question to a person: the run waits for `answer yes|no [text]`. A no fails the step. */
export interface Ask extends Base {
  event: "ask";
  size: string;
  n: number;
  text: string;
}

/** With --tasks: what became of the task's block, after a run that counts as a verdict. */
export interface Task extends Base {
  event: "task";
  id: string;
  outcome: string;
  message?: string;
}

export interface CommandError extends Base {
  event: "error";
  message: string;
}

export interface End extends Base {
  event: "end";
  status: "pass" | "fail" | "skip" | "manual" | "aborted";
  ok: boolean;
  /** Whether this run may count as a verdict: it ran to its end, without an abort. The command itself writes nothing. */
  verdict: boolean;
  failures: string[];
  snapshots: string[];
  skipped?: string;
  ms: number;
  answers?: { size: string; n: number; text: string; answer: "yes" | "no"; note?: string }[];
}
