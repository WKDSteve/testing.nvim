# CI of a private repository: one pipeline, two kinds of runner (`testing init --workflow=two-runner-private`, see
# docs/WORKFLOW-CI.md of testing.nvim).
#
# What is checked lives only in .testing.lua; every leg runs it with `scripts/test.sh ci` (`testing ci`), exactly as the
# pre-push hook and `:Testing ci` do. This file only prepares the machine.
#
# - push to main: the self-hosted runner (the maintainer's local Windows machine), tools on its PATH, the whole profile.
#   Without a running runner its job stays "Queued" (no red mark, discarded after 24 h).
# - workflow_dispatch: a GitHub-hosted macOS leg, started by hand with `gh workflow run ci.yml`. There is no local Mac,
#   so this is the one exception to "CI stays local"; a throwaway VM, never the local machine.
#
# Why macOS only by hand here: hosted minutes of a private repository are paid. GitHub Free includes 12 USD a month and
# macOS costs 0.062 USD per minute (GitHub docs, 2026-11-04), about 190 minutes a month. A leg on every push would use
# that up within days, and an empty budget ends a job without a single step. Hence no pull_request trigger either.
# `testing ci remote` counts push runs only: a macOS run by hand is no verdict there and the MACOS cell stays `-`.

name: CI

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  # The event is part of the group: a push must not cancel the paid macOS run, and that run must not cancel a push.
  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pipeline:
    name: testing ci (${{ matrix.name }})
    runs-on: ${{ matrix.runs-on }}
    # On the macOS leg this is also the price limit of one run (30 minutes: 1.86 USD).
    timeout-minutes: 30
    strategy:
      fail-fast: false
      matrix:
        # Only a push to main uses the self-hosted runner; every other event, also one added later, gets the hosted leg.
        # `steps` picks what depends on the platform (stylua and luacheck do not). When .testing.lua makes `conformance`
        # a gate, add it (`--step=suite,conformance`); a step the pipeline does not have is a usage error, never a pass.
        include: ${{ fromJSON(github.event_name == 'push' && '[{"name":"windows","runs-on":["self-hosted","windows"],"hosted":false,"steps":""}]' || '[{"name":"macos","runs-on":"macos-latest","hosted":true,"steps":"--step=suite"}]') }}
    defaults:
      run:
        # One shell on every runner: `bash` is the WSL launcher on the self-hosted machine, pwsh is everywhere.
        shell: pwsh
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false
@@DEP_STEPS_PINNED|raw@@
      # Hosted leg only: the self-hosted runner has nvim on its PATH.
      - uses: rhysd/action-setup-vim@febef33995d6649302e9d88dda81e071b68f16a7 # v1
        if: matrix.hosted
        with:
          neovim: true
          version: v0.12.2
      - name: scripts/test.sh ci ${{ matrix.steps }}
        env:
          CI_STEPS: ${{ matrix.steps }}
          CI_REPORT: ${{ runner.temp }}/ci-report.json
          CI_IR: ${{ runner.temp }}/suite-ir.json
        run: |
          nvim --version | Select-Object -First 1
          # Git Bash on Windows (never the WSL launcher), bash elsewhere; scripts/test.sh is a bash script.
          $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { 'bash' }
          $steps = @($env:CI_STEPS -split ' ' | Where-Object { $_ })
          & $bash scripts/test.sh ci @steps --keep-going --no-agent "--json=$env:CI_REPORT" -- "--json=$env:CI_IR"
          exit $LASTEXITCODE
      # The report names every step and, for a red one, its findings or last output lines; the suite IR (everything
      # after `--` goes to the suite step) names the failing case and its assertions.
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7
        if: failure()
        with:
          name: ci-${{ matrix.name }}
          path: |
            ${{ runner.temp }}/ci-report.json
            ${{ runner.temp }}/suite-ir.json
          if-no-files-found: ignore
          retention-days: 14
