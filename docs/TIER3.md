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

Two more lines of that section: `tmux` on Linux and macOS (looked up on `PATH`; on Windows it lives in WSL and is
found when a case starts), and the container image of `testing.container` (`localhost/testing-linux:1`, or
`$TESTING_CONTAINER_IMAGE`). The image line is the one place that starts a process: it asks the engine
(`podman image exists`, `$TESTING_CONTAINER_ENGINE`) with a deadline of 5 s, so a stopped Podman machine reads as
"not usable" instead of holding up the check.

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

## Linux checks in a container (`testing.container`)

`containers/linux/Containerfile` describes the Linux environment of the container checks: Alpine 3.22 (its release
pins every package version range) with Neovim, `gio`, `trash-cli`, `xdg-utils`, `tmux` and DejaVu fonts, run as the
user `tester`. Build it once with `podman build -t localhost/testing-linux:1 containers/linux`.

`require("testing.container")` runs one command in a fresh container (`--rm --network none`, mounts read-only):

| Call | Result |
| --- | --- |
| `container.available()` | `true, image` or `false, reason` (engine missing, machine stopped, image not built) |
| `container.run({ "nvim", "--headless", ... }, { mounts = { [host] = "/repos" }, env = {} })` | `{ code, stdout, stderr }` |
| `container.argv(command, opts)` | the argument vector of that run (for specs with a fake runner) |

Engine `$TESTING_CONTAINER_ENGINE` (default `podman`), image `$TESTING_CONTAINER_IMAGE`. A spec that needs it prints
`n/a  <reason>` and returns when it is unavailable. The container shares the kernel of the podman machine (WSL2 on
Windows): `is_wsl()` of lib.nvim reads "microsoft" from the kernel release, so container scripts stub the detection
to `false` (the userland is plain Linux). Users: filetree.nvim (`trash_linux_container_spec`: `gio trash`, then
`trash-put`), lib.nvim (`cross_open_default_container_spec`: `xdg-open` gets the target as one untouched argument).
