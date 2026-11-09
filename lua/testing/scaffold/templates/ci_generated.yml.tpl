# CI of @@NAME@@: one pipeline, @@KINDS|raw@@.
#
@@INTRO|raw@@#
@@LAYOUT_TEXT|raw@@@@PUBLISH_HEADER|raw@@@@FORK_TEXT|raw@@
name: CI

on:
@@TRIGGERS|raw@@
permissions:
  contents: read

concurrency:
@@CONCURRENCY|raw@@  cancel-in-progress: true

jobs:
@@VERIFIED_JOB|raw@@  pipeline:
    name: testing ci (${{ matrix.name }})
@@PIPELINE_GATE|raw@@    runs-on: ${{ matrix.runs-on }}
@@TIMEOUT_TEXT|raw@@    timeout-minutes: @@TIMEOUT@@
    strategy:
      # One platform failing must not cancel the other.
      fail-fast: false
      matrix:
@@MATRIX_TEXT|raw@@        include: @@MATRIX|raw@@
    defaults:
      run:
        # One shell on every runner: `bash` is the WSL launcher on the self-hosted machine, pwsh is everywhere.
        shell: pwsh
    steps:
      - uses: actions/checkout@@@CHECKOUT_ACTION|raw@@
        with:
          persist-credentials: false
@@CHECKOUTS|raw@@
      # @@TOOLS_TEXT|raw@@
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
@@PACKAGE_STEPS|raw@@@@NODE_STEP|raw@@@@CACHE_RESTORE|raw@@      - name: @@SCRIPT|raw@@ ${{ matrix.steps }}
        env:
@@ENV|raw@@          CI_STEPS: ${{ matrix.steps }}
          CI_REPORT: ${{ runner.temp }}/ci-report.json
          CI_IR: ${{ runner.temp }}/suite-ir.json
        run: |
          nvim --version | Select-Object -First 1
          # Git Bash on Windows (never the WSL launcher), bash elsewhere; @@SCRIPT_FILE|raw@@ is a bash script.
          $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { 'bash' }
          $steps = @($env:CI_STEPS -split ' ' | Where-Object { $_ })
          & $bash @@SCRIPT|raw@@ @steps --keep-going --no-agent "--json=$env:CI_REPORT" -- "--json=$env:CI_IR"@@SUITE_EXTRA|raw@@
          exit $LASTEXITCODE
@@CACHE_SAVE|raw@@      # The report names every step and, for a red one, its findings or last output lines; the suite IR (everything
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