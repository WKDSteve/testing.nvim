-- TESTS/sheets/workstation-export.sheet.lua -- the hand run of `testing export` and `testing ci remote` on the
-- workstation, as questions for the person sitting there. A manual sheet starts nothing, so it runs on the workstation
-- (`testing sheets step workstation-export`, or `testing sheets run --task ...`); its answers go into the task.
return {
  id = "testing.workstation-export",
  title = "testing export and ci remote on the workstation: read-only token, no runs, Falcon quiet",
  task = "testing.nvim/handlaeufe-auf-der-workstation",
  engine = "manual",
  steps = {
    {
      ask = "echo $env:NVIM_MACHINE_ROLE shows workstation (PowerShell; in Bash $NVIM_MACHINE_ROLE)?",
      note = "the machine first",
    },
    {
      ask = "TESTING_GITHUB_TOKEN is set to the fine-grained read-only token (Actions and Metadata read), not GITHUB_TOKEN?",
      note = "the token",
    },
    {
      ask = "testing ci remote prints the table of the repositories and exits 0 or 1, without a token in its output?",
      note = "ci remote",
    },
    {
      ask = "testing export --out <dir> writes testing-export.json, and testing-web reads the folder?",
      note = "export",
    },
    {
      ask = "testing run is refused (exit 2, 'refused on the workstation'), and the Task Manager shows no nvim child?",
      note = "no run",
    },
    {
      ask = "Falcon and the EDR reported nothing during these steps?",
      note = "quiet",
    },
  },
}
