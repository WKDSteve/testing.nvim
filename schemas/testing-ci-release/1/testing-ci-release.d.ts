/** One step of `testing ci release --json` (document testing-ci-release/1). A reader ignores unknown fields. */
export interface TestingCiRelease {
  schema: "testing-ci-release/1";
  /** `usage`: the arguments were refused (exit 2). */
  step: "usage" | "repos" | "commits" | "show" | "release";
  /** 0 done, 1 not released, 2 usage, 3 GitHub or the list failed. */
  exit: 0 | 1 | 2 | 3;
  /** Why the step failed (exit 2 or 3). */
  problem?: string | null;
  /** owner/name, as given. */
  repo?: string | null;
  /** The full commit id (steps show and release). */
  sha?: string;
  /** Step repos: the repository of the current folder first, then those on the list. */
  repos?: Repo[];
  /** Step commits: the last --count commits of the default branch, newest first. */
  commits?: Commit[];
  /** Step show: what changed since the last reviewed commit. */
  show?: Show;
  /** Step release (--yes): the release and the re-run of the failed runs. */
  release?: Release;
}

export interface Repo {
  name: string;
  here: boolean;
  /** The guard mode on the list; absent: not on it. */
  mode?: "auto" | "always" | "off" | null;
  reviewed: number;
}

export interface Commit {
  sha: string;
  title: string;
  author: string;
  date: string;
  released: boolean;
}

export interface Show {
  sha: string;
  /** On the list already: nothing compared. */
  already: boolean;
  /** The last reviewed commit; absent: none, review the whole tree. */
  prev?: string | null;
  compared: boolean;
  problem?: string | null;
  /** Anything but "ahead": history rewritten or another branch. */
  status?: string | null;
  total_commits?: number | null;
  commits: { sha: string; author: string; title: string }[];
  /** `flag`: why the file deserves a close look (.github, scripts, lockfile, ...). */
  files: { path: string; previous?: string | null; status: string; flag?: string | null }[];
  files_total: number;
  /** GitHub lists at most 300 files. */
  truncated: boolean;
}

export interface Release {
  already: boolean;
  recorded: boolean;
  reruns: {
    id: number;
    name: string;
    was: "failure" | "cancelled" | "startup_failure" | "timed_out";
    ok: boolean;
    problem?: string | null;
  }[];
}
