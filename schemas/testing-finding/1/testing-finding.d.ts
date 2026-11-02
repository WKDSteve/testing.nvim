/** One finding of testing.nvim (document testing-finding/1). The engine writes it; a reader ignores unknown fields. */
export interface TestingFinding {
  schema: "testing-finding/1";
  /** 16 hex, stable over commits and moved lines. */
  fp: string;
  kind: "case" | "flaky" | "guard" | "ci-run" | "lint" | "sheet";
  repo: string;
  area: string | null;
  sha: string | null;
  /** Only released classes are ever written. */
  class: "public" | "internal";
  where: null | { file: string; line: number | null };
  run: null | {
    source: "local" | "ci";
    id: string | null;
    os: string | null;
    url: string | null;
  };
  /** At most 120 characters. */
  title: string;
  /** Redacted, at most 4 KiB. */
  excerpt: string;
  repro: string | null;
  rule: string | null;
}
