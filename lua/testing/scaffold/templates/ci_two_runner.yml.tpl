# CI of a public repository: one pipeline, two kinds of runner (`testing init --workflow=two-runner`, see
# docs/WORKFLOW-CI.md of testing.nvim).
#
# What is checked lives only in .testing.lua; every leg runs it with `scripts/test.sh ci` (`testing ci`), exactly as the
# pre-push hook and `:Testing ci` do. This file only prepares the machine.
#
# - push to main: the self-hosted runner (the maintainer's local Windows machine), tools on its PATH, the whole profile.
#   Without a running runner its job stays "Queued" (no red mark, discarded after 24 h).
# - push to main, macOS: a GitHub-hosted leg, because there is no local Mac. It is the one exception to "CI stays local":
#   a throwaway VM with a read-only token, free in a public repository, never the local machine. The runner guard is a
#   hook of the local runner (docs/RUNNER-GUARD.md), so it never sees this leg.
# - pull_request (also from forks): GitHub-hosted runners only. A pull request never runs on the self-hosted runner: it
#   would run its own workflow code on the maintainer's machine. The hosted legs pin the versions the self-hosted runner
#   has (nvim 0.12.2, stylua 2.5.2, luacheck 1.2.0); a difference between the two is a finding.
#
# A fork can edit this file in its pull request (e.g. `runs-on: self-hosted`). The repository therefore requires
# approval before a workflow of an outside contributor runs; never approve a pull request that touches `.github/`.

name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pipeline:
    name: testing ci (${{ matrix.name }})
    runs-on: ${{ matrix.runs-on }}
    timeout-minutes: 30
    strategy:
      # One platform failing must not cancel the others.
      fail-fast: false
      matrix:
        # Only a push to main uses the self-hosted runner; every other event, also one added later, gets hosted runners.
        # `steps` picks what depends on the platform (stylua and luacheck do not). When .testing.lua makes `conformance`
        # a gate, add it (`--step=suite,conformance`); a step the pipeline does not have is a usage error, never a pass.
        include: ${{ fromJSON(github.event_name == 'push' && '[{"name":"windows","runs-on":["self-hosted","windows"],"hosted":false,"steps":""},{"name":"macos","runs-on":"macos-latest","hosted":true,"steps":"--step=suite"}]' || '[{"name":"ubuntu","runs-on":"ubuntu-latest","hosted":true,"steps":""},{"name":"windows","runs-on":"windows-latest","hosted":true,"steps":"--step=suite"},{"name":"macos","runs-on":"macos-latest","hosted":true,"steps":"--step=suite"}]') }}
    defaults:
      run:
        # One shell on every runner: `bash` is the WSL launcher on the self-hosted machine, pwsh is everywhere.
        shell: pwsh
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false
@@DEP_STEPS_PINNED|raw@@
      # Hosted legs only: the tools the self-hosted runner has on its PATH.
      - uses: rhysd/action-setup-vim@febef33995d6649302e9d88dda81e071b68f16a7 # v1
        if: matrix.hosted
        with:
          neovim: true
          version: v0.12.2
      # The action installs stylua on PATH; `--version` only proves it is there, the check itself is the pipeline's.
      - uses: JohnnyMorganz/stylua-action@76fd70c03e6340ceaf673366712db9b20560b402 # v5
        if: matrix.hosted && matrix.steps == ''
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: v2.5.2
          args: --version
      # PUC Lua, not "luajit-2.1" (that tarball 404s); `std = "luajit"` in .luacheckrc decides what is checked against.
      - uses: leafo/gh-actions-lua@6919171ccf181b826f44b9bca76307b577217377 # v13
        if: matrix.hosted && matrix.steps == ''
        with:
          luaVersion: "5.4"
      - uses: leafo/gh-actions-luarocks@35d062def313a7699a0d513e996bcf4352f05389 # v6
        if: matrix.hosted && matrix.steps == ''
      - if: matrix.hosted && matrix.steps == ''
        run: luarocks install luacheck 1.2.0
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
