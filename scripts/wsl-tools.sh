#!/usr/bin/env bash
#
# The tools `testing ci commit --wsl` needs inside WSL, as official release builds into ~/.local (no sudo, nothing of
# the distribution changed): stylua and luacheck at the versions of testing.ci.workflow.TOOLS (a spec keeps the two
# equal), and Node 22 for the contract step of testing.nvim. The `--wsl` script puts ~/.local/bin on PATH itself.
#
#   wsl.exe -e bash scripts/wsl-tools.sh        install or update, then print the versions
#
# Every download is checked: stylua and luacheck against the SHA-256 pinned here, Node against the SHASUMS256.txt of
# its own release. Exit 0 done, 1 a download or a check failed.

set -euo pipefail

STYLUA_VERSION="2.5.2"
STYLUA_SHA256="bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab"
LUACHECK_VERSION="1.2.0"
LUACHECK_SHA256="d68da17fca0697d9e2fb04201f3884abd259fa558b3a449bccaed47f1390defc"
NODE_MAJOR="22"

BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$HOME/.local/opt"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

check() { # <sha256> <file>
  echo "$1  $2" | sha256sum -c - >/dev/null || {
    echo "error: checksum of $2 does not match" >&2
    exit 1
  }
}

curl -fsSL -o "$T/stylua.zip" \
  "https://github.com/JohnnyMorganz/StyLua/releases/download/v$STYLUA_VERSION/stylua-linux-x86_64.zip"
check "$STYLUA_SHA256" "$T/stylua.zip"
unzip -q -o "$T/stylua.zip" -d "$T"
install -m 755 "$T/stylua" "$BIN/stylua"

curl -fsSL -o "$T/luacheck" \
  "https://github.com/lunarmodules/luacheck/releases/download/v$LUACHECK_VERSION/luacheck"
check "$LUACHECK_SHA256" "$T/luacheck"
install -m 755 "$T/luacheck" "$BIN/luacheck"

base="https://nodejs.org/dist/latest-v$NODE_MAJOR.x"
curl -fsSL -o "$T/SHASUMS256.txt" "$base/SHASUMS256.txt"
line="$(grep -E " node-v$NODE_MAJOR\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz$" "$T/SHASUMS256.txt")"
file="${line##* }"
curl -fsSL -o "$T/$file" "$base/$file"
check "${line%% *}" "$T/$file"
rm -rf "$HOME/.local/opt/node"
mkdir -p "$HOME/.local/opt/node"
tar -xJf "$T/$file" -C "$HOME/.local/opt/node" --strip-components=1
for b in node npm npx; do ln -sf "$HOME/.local/opt/node/bin/$b" "$BIN/$b"; done

export PATH="$BIN:$PATH"
stylua --version
luacheck --version | head -1
echo "node $(node --version)"
