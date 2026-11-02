#!/usr/bin/env bash
#
# Warns when a second full suite starts in the same checkout (sourced by scripts/test.sh, tested by
# TESTS/testing/suite_lock_spec.lua).
#
# Two full suites at once make the process specs (ci_runner_guard_spec, ci_editor_spec, ...) run into their timeouts
# while each is green alone. The lock is `<state dir>/suite-lock-<checksum of the checkout>`, holding the pid of the
# script that runs the suite and its start time. It only warns: a stuck lock must never stop a run, so the second suite
# goes on, and a lock of a dead pid (or one older than SUITE_LOCK_MAX_AGE seconds, default 6 h) is taken over silently.
#
#   suite_lock_acquire <state dir> <checkout>   sets SUITE_LOCK_FILE and SUITE_LOCK_OWNED (1: this process holds it)
#   suite_lock_release                          removes the lock when this process holds it

suite_lock_acquire() {
  SUITE_LOCK_OWNED=0
  SUITE_LOCK_FILE=""
  local dir="$1" root="$2" key file holder since now max
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  key="$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  file="$dir/suite-lock-$key"
  now="$(date +%s)"
  max="${SUITE_LOCK_MAX_AGE:-21600}"
  if [ -f "$file" ]; then
    read -r holder since <"$file" 2>/dev/null || true
    since="${since:-0}"
    if [ -n "${holder:-}" ] && [ "$holder" != "$$" ] && kill -0 "$holder" 2>/dev/null \
      && [ $((now - since)) -lt "$max" ]; then
      printf '\033[33m%s\033[0m\n' "warning: another full suite is running in this checkout (pid $holder, started $((now - since)) s ago): two at once make ci_runner_guard_spec and ci_editor_spec time out. Wait for it, or run in a worktree of its own." >&2
      return 0
    fi
  fi
  printf '%s %s\n' "$$" "$now" >"$file" 2>/dev/null || return 0
  SUITE_LOCK_FILE="$file"
  SUITE_LOCK_OWNED=1
}

suite_lock_release() {
  if [ "${SUITE_LOCK_OWNED:-0}" = 1 ] && [ -n "${SUITE_LOCK_FILE:-}" ]; then
    local holder
    read -r holder _ <"$SUITE_LOCK_FILE" 2>/dev/null || true
    [ "${holder:-}" != "$$" ] || rm -f "$SUITE_LOCK_FILE"
  fi
  SUITE_LOCK_OWNED=0
}
