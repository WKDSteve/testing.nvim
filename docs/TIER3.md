# Tier 2.5 and 3 tools

Tier 2.5 (PTY capture of the raw terminal byte stream, in WSL) and tier 3 (a browser, a Tauri window) need tools
that are not part of Neovim. `testing.tier3` finds them without starting a process; `:checkhealth testing` lists
them under "tier 2.5/3 tools".

| Tool | Tier | Override | Used for |
| --- | --- | --- | --- |
| `node` | 3 | `$TESTING_NODE` | Playwright specs (mdview.nvim) |
| `tauri-driver` | 3 | `$TESTING_TAURI_DRIVER` | WebDriver for Tauri windows |
| `msedgedriver` | 3 | `$TESTING_MSEDGEDRIVER` | WebDriver of WebView2; its version must match the installed WebView2 |
| `wsl` | 2.5 | `$TESTING_WSL` | tmux and PTY capture |

A tool is found through its override (an absolute path to a file), then `PATH`. The Playwright browsers are looked
up in `$PLAYWRIGHT_BROWSERS_PATH`, else `%LOCALAPPDATA%\ms-playwright` or `~/.cache/ms-playwright`; chromium is the
engine the mdview specs need.

A missing tool is information, never an error: the cases that need it are **reported skips**, not green runs.

Install on a private machine only (never on the workstation): `cargo install tauri-driver --locked`; download
`msedgedriver` for the exact WebView2 version from `msedgedriver.microsoft.com`, verify its Authenticode signature
and keep it outside the repositories; `npx playwright install chromium` with a pinned Playwright version.

## Tier 2.5: a command in a real terminal (`testing.pty`)

`require("testing.pty").open({ "nvim", "file" }, { cols = 100, rows = 30 })` starts a detached tmux session (in WSL
on Windows with `wsl [-d $TESTING_WSL_DISTRO] --exec tmux`, directly on Linux) and returns a session with

| Call | Result |
| --- | --- |
| `s:send({ "M-n" })`, `s:send({ "text" }, true)` | keys by tmux name, or literal text |
| `s:screen()` | the grid with its escape sequences (`capture-pane -p -e`) |
| `s:raw()` | every byte the program wrote (recorded with `pipe-pane` from the first byte): OSC-1337 images, kitty graphics, titles |
| `s:wait_for(text, ms, "screen"\|"raw")` | polls until the text appears |
| `s:close()` | kills the session and removes the recording |

Every call is an argument vector (`--exec` keeps WSL from re-parsing it through a shell). `pty.available()` answers
whether tmux is usable; a spec that needs it prints `n/a  <reason>` and returns when it is not (a reported skip).
