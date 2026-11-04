/** The result of `testing ci commit` (document testing-ci-commit/1). A reader ignores unknown fields. */
export interface TestingCiCommit {
  schema: "testing-ci-commit/1";
  repo: string;
  /** The worst exit code of all commits. */
  exit: 0 | 1 | 2 | 3;
  /** Commits per verdict. */
  tally: Partial<Record<Verdict, number>>;
  /** UTC, ISO 8601. */
  time: string;
  /** In the order they were named (a range: oldest first). */
  commits: CommitResult[];
  /** Only with `--repos-root`: one entry per repository, also one that could not be checked. */
  repos?: RepoResult[];
}

export interface RepoResult {
  name: string;
  root: string;
  commits: number;
  exit: 0 | 1 | 2 | 3;
  /** Why the repository could not be checked (not a repository, not trusted, ...). */
  problem?: string | null;
}

export type Verdict =
  | "clean"
  | "known-red"
  | "flaky"
  | "regression"
  | "unclassified"
  | "docs-only"
  | "empty"
  | "error"
  | "infra";

export interface CommitResult {
  /** The full commit id. */
  sha: string;
  /** The directory name of the repository (only with `--repos-root`). */
  repo?: string;
  /** What red is compared with: `--base` or the first parent; null for a root commit. */
  base?: string | null;
  verdict: Verdict;
  /** clean, known-red, flaky, docs-only, empty 0; regression, unclassified 1; error 2; infra 3. */
  exit: 0 | 1 | 2 | 3;
  profile?: string | null;
  suite_args?: string[];
  /** True when the result was kept from an earlier call (nothing ran). */
  reused?: boolean;
  /** False when a list of findings was cut: the rest counts as new. */
  exact: boolean;
  changed_files?: string[];
  docs_only?: boolean;
  /** Red at the commit, not at the base. */
  new: Item[];
  /** Red at the commit and at the base. */
  known: Item[];
  /** Red at the base, not at the commit (only in the steps red at the commit). */
  fixed: Item[];
  /** New at first, green when their spec files ran once more at the commit (red under load only). */
  flaky?: Item[];
  problems: string[];
  /** The worktrees left in place by `--keep`. */
  snapshots?: string[];
  /** How to check it again, keeping the worktrees. */
  rerun: string;
  /** The steps of the run at the commit and at the base. */
  steps_head?: { name: string; state: string }[];
  steps_base?: { name: string; state: string }[];
  /** The testing-ci/1 documents of both runs (null when there was none). */
  head?: object | null;
  base_run?: object | null;
}

export interface Item {
  step: string;
  file: string | null;
  line: number | null;
  col: number | null;
  text: string;
  /** The step is red without findings: the item is the step itself. */
  whole: boolean;
}
