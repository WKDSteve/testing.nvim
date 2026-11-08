# CI of @@NAME@@: one pipeline, two kinds of runner.
#
# What is checked lives only in the `ci` section of .testing.lua; every leg runs it with `scripts/ci.sh` (`testing ci`),
# exactly as the pre-push hook and `:Testing ci` do. This file only prepares the machine.
#
# - push to main: the self-hosted runner (the maintainer's local Windows machine), tools on its PATH. Without a running
#   runner a push stays "Queued" (no red mark, discarded after 24 h).
# - pull_request (also from forks): GitHub-hosted runners, a throwaway VM with a read-only token and no secrets (every
#   dependency is a public repository). A pull request never runs on the self-hosted runner: it would run its own
#   workflow code on the maintainer's machine. The hosted legs pin the versions the self-hosted runner has (nvim
#   @@NVIM_VERSION@@, stylua @@STYLUA_VERSION@@, luacheck @@LUACHECK_VERSION@@@@TOOLS_HEADER|raw@@); a difference between the two is a finding.
# - macOS: a GitHub-hosted leg on every event, also on a push: the repository is public, so it costs nothing, and no
#   self-hosted runner has macOS. It runs the steps that depend on the platform: @@PLATFORM_TEXT|raw@@.
@@PUBLISH_HEADER|raw@@#
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
    timeout-minutes: @@TIMEOUT@@
    strategy:
      # One platform failing must not cancel the other.
      fail-fast: false
      matrix:
        # Only a push to main uses the self-hosted runner (the whole `full` profile); every other event, also one
        # added later (workflow_dispatch, pull_request_target, ...), gets hosted runners: the whole profile on ubuntu,
        # and on windows the steps that depend on the platform (@@PORTABLE_TEXT|raw@@ do not).
        include: ${{ fromJSON(github.event_name == 'push' && '[{"name":"windows","runs-on":["self-hosted","windows"],"hosted":false,"steps":""},{"name":"macos","runs-on":"macos-latest","hosted":true,"steps":"--step=@@PLATFORM_STEPS|raw@@"}]' || '[{"name":"ubuntu","runs-on":"ubuntu-latest","hosted":true,"steps":""},{"name":"windows","runs-on":"windows-latest","hosted":true,"steps":"--step=@@PLATFORM_STEPS|raw@@"}]') }}
    defaults:
      run:
        # One shell on every runner: `bash` is the WSL launcher on the self-hosted machine, pwsh is everywhere.
        shell: pwsh
    steps:
      - uses: actions/checkout@@@CHECKOUT_ACTION|raw@@
        with:
          persist-credentials: false
@@CHECKOUTS|raw@@
      # Hosted legs only: the tools the self-hosted runner has on its PATH.
      - uses: rhysd/action-setup-vim@@@SETUP_VIM_ACTION|raw@@
        if: matrix.hosted
        with:
          neovim: true
          version: v@@NVIM_VERSION@@
      # The action installs stylua on PATH; `--version` only proves it is there, the check itself is the pipeline's.
      - uses: JohnnyMorganz/stylua-action@@@STYLUA_ACTION|raw@@
        if: matrix.hosted && matrix.steps == ''
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: v@@STYLUA_VERSION@@
          args: --version
      # PUC Lua, not "luajit-2.1" (that tarball 404s); `std = "luajit"` in .luacheckrc decides what is checked against.
      - uses: leafo/gh-actions-lua@@@LUA_ACTION|raw@@
        if: matrix.hosted && matrix.steps == ''
        with:
          luaVersion: "@@LUA_VERSION@@"
      - uses: leafo/gh-actions-luarocks@@@LUAROCKS_ACTION|raw@@
        if: matrix.hosted && matrix.steps == ''
      - if: matrix.hosted && matrix.steps == ''
        run: luarocks install luacheck @@LUACHECK_VERSION@@
@@NODE_STEP|raw@@      - name: scripts/ci.sh ${{ matrix.steps }}
        env:
@@ENV|raw@@          CI_STEPS: ${{ matrix.steps }}
          CI_REPORT: ${{ runner.temp }}/ci-report.json
          CI_IR: ${{ runner.temp }}/suite-ir.json
        run: |
          nvim --version | Select-Object -First 1
          # Git Bash on Windows (never the WSL launcher), bash elsewhere; scripts/ci.sh is a bash script.
          $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { 'bash' }
          $steps = @($env:CI_STEPS -split ' ' | Where-Object { $_ })
          & $bash scripts/ci.sh @steps --keep-going --no-agent "--json=$env:CI_REPORT" -- "--json=$env:CI_IR"
          exit $LASTEXITCODE
      # The report names every step and, for a red one, its findings or last output lines; the suite IR (everything
      # after `--` goes to the suite step) names the failing case and its assertions.
      - uses: actions/upload-artifact@@@UPLOAD_ACTION|raw@@
        if: failure()
        with:
          name: ci-${{ matrix.name }}
          path: |
            ${{ runner.temp }}/ci-report.json
            ${{ runner.temp }}/suite-ir.json
          if-no-files-found: ignore
          retention-days: 14
@@PUBLISH_JOB|raw@@