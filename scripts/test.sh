#!/usr/bin/env bash
# testing:keep-file the dogfood script: it runs this checkout through its own scripts/testing.lua, no generated bootstrap
#
# Runs this repository's specs through its own runner (dogfood):
#
#   nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . [options]
#
#   scripts/test.sh                    every spec under TESTS/
#   scripts/test.sh --file config      only spec files whose name contains "config"
#   scripts/test.sh --json out.json    additionally write the Result-IR
#   scripts/test.sh --junit out.xml    additionally write a JUnit report
#
# Every option of `scripts/testing.lua --help` is passed through unchanged.
#
#   A plain run (no subcommand) defaults to `--cached --order slowest-first`: unchanged spec files come from the result
#   cache (a folder of your real cache directory, or $TESTING_CACHE_HOME), the longest files start first, and the run is
#   recorded in your real state directory (last.json, runs.jsonl: `testing ci verify`, the editor's explorer). Not
#   under CI. `--no-cache` or TESTING_PLAIN=1 gives the plain uncached run.
#
#   scripts/test.sh --cached           reuse the results of unchanged spec files (docs/CACHE.md); the cache
#                                      lives in $TESTING_CACHE_HOME (default: a throwaway directory, so a
#                                      second invocation starts cold unless you point it somewhere)
#   TESTING_CACHE_HOME=~/.cache/tn scripts/test.sh --cached
#   scripts/test.sh --changed          only the specs the working tree can reach (a partial run)
#
#   scripts/test.sh fast [options]     `testing fast`: --cached --order priority, the likely specs first with an
#                                      interim finding after them; the verdict of the whole run comes last
#                                      (docs/CLI.md); `--time-budget 2m` stops starting files after that long.
#                                      This script's throwaway state holds no failure history, so the
#                                      "failed last time" stage is empty here (changes still count); with
#                                      history, run `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua
#                                      fast .` directly
#   scripts/test.sh conformance        the conformance suite K1..K16 (docs/CONFORMANCE.md) in the same isolated
#                                      environment; extra options go to `testing conformance .`; exit 1 when the
#                                      repo is gated (`conformance.gate = true`, or `--gate`) and a check failed
#   scripts/test.sh ci [options]       the whole pipeline of `.testing.lua` (`ci` section: stylua, luacheck, the
#                                      suite, conformance; docs/CI.md) in the same isolated environment;
#                                      `scripts/test.sh ci --profile=fast` is the quick check before a push
#
# Exit code: 0 all green, 1 a spec failed, 2 usage or configuration error, 3 infrastructure error
# (nvim is not on PATH, or lib.nvim was not found: the runner then names all four places it looked
# in: $LIB_NVIM_DIR, <repo>/.deps/lib.nvim, <repo>/../lib.nvim, stdpath('data')/lazy/lib.nvim).

set -uo pipefail

cd "$(dirname "$0")/.."

if ! command -v nvim >/dev/null 2>&1; then
  printf '\033[31m%s\033[0m\n' "error: nvim is not on PATH." >&2
  exit 3
fi

# `ci` and the plain run: the pipeline's document (ci.json), the suite's stamp and the run history (last.json,
# runs.jsonl) must outlive the scratch directory below, where `testing ci verify`, the pre-push hook and the editor's
# test explorer read them. The developer's real state directory is asked for BEFORE the isolation and handed to
# `--state-dir` (an argument, not the environment: the specs must not inherit it).
real_state=""
real_cache=""
if [ "${1:-}" != "conformance" ]; then
  real_state="$(nvim -n -i NONE --headless -u NONE --cmd 'lua io.stdout:write(vim.fn.stdpath("state"))' --cmd 'qa!' 2>/dev/null)"
  real_cache="$(nvim -n -i NONE --headless -u NONE --cmd 'lua io.stdout:write(vim.fn.stdpath("cache"))' --cmd 'qa!' 2>/dev/null)"
  if [ -z "$real_state" ] && [ "${1:-}" = "ci" ]; then
    # without it the document and the stamp would go into the scratch directory and be deleted on exit
    printf '\033[31m%s\033[0m\n' 'error: cannot ask nvim for stdpath("state"); the ci document would be lost.' >&2
    exit 3
  fi
fi

# Throwaway app name, state and cache: the run never reads or writes the developer's real stdpath("state") and
# stdpath("cache"). stdpath("config") and stdpath("data") are not redirected, they only carry the app name below
# (always this name: an exported NVIM_APPNAME would make them that app's real ones).
export NVIM_APPNAME="testing-nvim-tests"
# Without a scratch directory the exports below would point at /state and /cache: stop instead
scratch="$(mktemp -d)" || {
  printf '\033[31m%s\033[0m\n' "error: cannot create a scratch directory (mktemp -d failed; is TMPDIR writable?)." >&2
  exit 3
}
# A second full suite in the same checkout only warns (scripts/suite-lock.sh): both runs end up in timeouts. A partial
# run (--file, --list, --changed), `ci verify` and the other subcommands take no lock.
# shellcheck source=scripts/suite-lock.sh
. "$(dirname "$0")/suite-lock.sh"
full_suite=0
case "${1:-}" in
  conformance | surface | fast) ;;
  ci)
    case "${2:-}" in
      "" | -*) full_suite=1 ;;
    esac
    ;;
  *) full_suite=1 ;;
esac
for a in "$@"; do
  case "$a" in
    --file | --file=* | --list | --changed | --help | -h) full_suite=0 ;;
  esac
done
if [ "$full_suite" = 1 ] && [ -n "$real_state" ]; then
  suite_lock_acquire "$real_state" "$(pwd)"
fi
trap 'suite_lock_release; rm -rf "$scratch"' EXIT
if command -v cygpath >/dev/null 2>&1; then
  scratch="$(cygpath -m "$scratch")"
fi
# Windows: TMP/TEMP often hold the 8.3 short form (C:/Users/RUNNER~1/...). Neovim's glob and :checkhealth cannot
# find files below a path with a "~1" component, so the specs are run with the long form.
if command -v cygpath >/dev/null 2>&1; then
  for var in TMP TEMP; do
    val="${!var:-}"
    if [ -n "$val" ]; then
      export "$var=$(cygpath -w -l "$val")"
    fi
  done
fi
export XDG_STATE_HOME="$scratch/state"
# The specs always get a throwaway cache home (they run the runner themselves and must not write into a shared
# cache); a shared one is handed to the outer run only, through --cache-dir.
cache_args=()
if [ -n "${TESTING_CACHE_HOME:-}" ]; then
  cache_args=(--cache-dir "$TESTING_CACHE_HOME")
  unset TESTING_CACHE_HOME
fi
# A plain run defaults to the result cache (unchanged spec files are not run again; docs/CACHE.md) in a folder of the
# developer's real cache directory, and starts the longest files first (their durations are in the real state). A cache
# hit is keyed on everything the file can reach, so it is the answer a run would give; `--no-cache` or
# TESTING_PLAIN=1 turns both off (CI does not use this script's defaults: it sets CI).
plain_defaults=()
if [ -z "${CI:-}" ] && [ -z "${TESTING_PLAIN:-}" ] && [ "${1:-}" != "ci" ] && [ "${1:-}" != "fast" ] && [ "${1:-}" != "conformance" ]; then
  plain_defaults=(--cached --order slowest-first)
  if [ ${#cache_args[@]} -eq 0 ] && [ -n "$real_cache" ]; then
    cache_args=(--cache-dir "$real_cache/testing-nvim-tests")
  fi
fi
export XDG_CACHE_HOME="$scratch/cache"
# Workspace trust (docs/CONFIG.md): this script IS code of this repository, so running it is the trust decision; and
# the specs run the runner on fixture projects they build in the temp directory. Every root is trusted below.
export TESTING_TRUST=1

# No `exec`: the trap must remove the scratch directory afterwards.
# nvim runs in the background and is waited for: with nvim in the foreground bash handles a TERM/INT/HUP only after
# nvim ended, so a stopped wrapper left the whole suite running (orphans that held the queue and the machine). The
# signal is passed on to nvim; on Windows nvim's own children go with it (libuv puts them in a kill-on-close job).
nvim_pid=""
# shellcheck disable=SC2329 # called from the traps below
forward() {
  if [ -n "$nvim_pid" ]; then
    kill -TERM "$nvim_pid" 2>/dev/null || true
    wait "$nvim_pid" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'forward 130' INT
trap 'forward 143' TERM
trap 'forward 129' HUP
run_nvim() {
  nvim "$@" <&0 &
  nvim_pid=$!
  wait "$nvim_pid"
}
if [ "${1:-}" = "conformance" ]; then
  shift
  run_nvim -n -i NONE --headless -u NONE -l scripts/testing.lua conformance . "$@"
  exit $?
fi
if [ "${1:-}" = "fast" ]; then
  shift
  [ -z "$real_state" ] || set -- --state-dir "$real_state" "$@"
  run_nvim -n -i NONE --headless -u NONE -l scripts/testing.lua fast . ${cache_args[@]+"${cache_args[@]}"} "$@"
  exit $?
fi
if [ "${1:-}" = "ci" ]; then
  shift
  state_args=()
  if [ -n "$real_state" ]; then
    state_args=(--state-dir "$real_state")
  fi
  # a shared cache reaches the suite step only when it asks for one (`--cached` after `--`)
  suite_cache=()
  for a in "$@"; do
    if [ "$a" = "--cached" ] && [ ${#cache_args[@]} -gt 0 ]; then
      suite_cache=("${cache_args[@]}")
    fi
  done
  # a subcommand goes first (`ci verify`, `ci commit`, ...): `testing ci` reads it as its first argument; `list`, `hook`,
  # `runner-guard` and `trust` take no --state-dir
  sub=()
  case "${1:-}" in
    verify | commit | remote | overview)
      sub=("$1")
      shift
      ;;
    list | hook | runner-guard | trust)
      sub=("$1")
      shift
      state_args=()
      ;;
  esac
  run_nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ci ${sub[@]+"${sub[@]}"} ${state_args[@]+"${state_args[@]}"} "$@" ${suite_cache[@]+"${suite_cache[@]}"}
  exit $?
fi
# the real state directory goes first, a `--state-dir` of the caller after it wins
[ -z "$real_state" ] || set -- --state-dir "$real_state" "$@"
run_nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . ${cache_args[@]+"${cache_args[@]}"} ${plain_defaults[@]+"${plain_defaults[@]}"} "$@"
exit $?
