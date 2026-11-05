@echo off
rem bin/testing.cmd -- the `testing` command on Windows (cmd, PowerShell): put this folder on the PATH.
rem
rem   testing [run|ci|status|...] [<root>] [options]   =   nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ...
rem
rem Runs in the caller's working directory (the runner reads it) and hands the exit code through:
rem 0 green, 1 failures, 2 usage/config, 3 infrastructure. Never silent: a missing nvim or an exit code
rem outside 0..3 (a crash) is named on stderr.
setlocal
rem one-line ifs: a path with ")" (Program Files (x86)) would end a parenthesized block early
set "lua=%~dp0..\scripts\testing.lua"
if not exist "%lua%" echo testing: cannot find "%lua%": run bin\testing.cmd of a testing.nvim checkout 1>&2& exit /b 3
where nvim >nul 2>nul
if errorlevel 1 (
  echo testing: nvim is not on the PATH: nothing ran 1>&2
  exit /b 3
)
nvim -n -i NONE --headless -u NONE -l "%lua%" %*
set "rc=%ERRORLEVEL%"
if %rc% GTR 3 echo testing: nvim ended with exit code %rc% and no verdict ^(crash?^) 1>&2
if %rc% LSS 0 echo testing: nvim ended with exit code %rc% and no verdict ^(crash?^) 1>&2
exit /b %rc%
