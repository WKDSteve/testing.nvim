/** What testing.nvim sends an engine's driver process: one JSON line each on stdin. The end of stdin means close. */
export type TestingSheetDriverCommand =
  | {
      cmd: "open";
      sheet: { id: string; root: string; out_dir: string };
      size: { rows: number; cols: number };
      /** `headed`, and what the engine's driver needs to find (`playwright_dir`). */
      options: { headed?: boolean; [key: string]: unknown };
    }
  | { cmd: "step"; n: number; step: Record<string, unknown> }
  | { cmd: "close" };

/** One JSON line on stdout per command. A reader ignores unknown fields. */
export interface TestingSheetDriverAnswer {
  schema: "testing-sheet-driver/1";
  ok: boolean;
  /** Why a step failed. */
  reason?: string;
  /** `open`: a prerequisite is missing, the sheet is a reported skip. */
  skip?: string;
  /** The command itself could not be done. */
  error?: string;
  /** `step`: the file a `shot` wrote. */
  shot?: string;
}
