---@module 'testing.ci.runners'
---@brief The failure lines of common test runners, as error formats: a red process step without an error format of
---its own is read with them, so that `ci commit` compares it test by test instead of as a whole.
---@description
--- A process step that names no `efm` (a repository's own `ui-test`, `rust-test`, ...) used to have no findings when
--- it was red. `testing.ci.baseline` then compared it as a whole: red at the base too meant "known", and a test that
--- turned red in that step went through as "0 new" (tasks-desktop, 2026-11-22: three new red Vitest files behind an
--- already red `ui-test`). With these formats such a step names its red tests, and a new one is a new finding.
---
--- Only the line that names one failed test is read, once per test (the matcher drops repeats):
---   * Vitest (default reporter): ` FAIL  <file> > <suite> > <test>`, and ` FAIL  <file> [ <file> ]` for a file that
---     failed as a whole (it did not load).
---   * cargo test (libtest): `test <path::to::test> ... FAILED`; the test path stands where a file would.
---   * pytest (short summary): `FAILED <file>::<test> - <reason>` and `ERROR ...`, with or without the reason.
---   * Python unittest: `FAIL: <test> (<module.Class.test>)` and `ERROR: ...`; the dotted name stands for the file.
---
--- Not read: Playwright's list reporter (its lines start with a running number, which the error format cannot
--- skip) and TAP. A red step whose output matches none of them stays a whole-step item, and `ci commit` says so.
--- The formats are only used for a red step (`testing.ci`): a green step's output is never searched.

local M = {}

---The error formats, tried in this order on every line (`testing.ci.report.matcher`).
---@type string[]
M.EFM = {
  " FAIL  %F > %m",
  " FAIL  %f [ %m ]",
  "test %f ... FAILED",
  "FAILED %f - %m",
  "FAILED %f",
  "ERROR %f - %m",
  "ERROR %f",
  "FAIL: %m (%f)",
  "ERROR: %m (%f)",
}

---Whether what stands where the file is names a test: a path (`/`, `\`, a file name with a dot), a dotted name or a
---`::` path. A log line such as `ERROR 12:30:01` or `ERROR timeout` names none and is no finding.
---@param f Testing.Ci.Finding
---@return boolean
function M.names_a_test(f)
  local id = f.file or ""
  return id:find("::", 1, true) ~= nil or id:find("[/\\]") ~= nil or id:find("%a%.%a") ~= nil
end

---A matcher of the runners' failure lines.
---@return Testing.Ci.Matcher
function M.matcher()
  return require("testing.ci.report").matcher(M.EFM, M.names_a_test)
end

return M
