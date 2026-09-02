#!/usr/bin/env bash
# Cloud Agent bootstrap for airpods-control.
#
# This repository builds a macOS-native CLI that talks to private Apple audio
# frameworks (CoreAudio/AVFoundation/Security) and needs the Xcode/CLT Swift
# toolchain plus lipo and codesign. That build and the program itself cannot
# run on the Linux Cloud Agent. This script sets up the cross-platform
# developer tooling the repo already pins in mise.toml: rumdl (Markdown lint)
# and pre-commit. See CONTRIBUTING.md for the full macOS workflow.
set -euo pipefail

MISE_BIN="$HOME/.local/bin/mise"

if ! command -v mise >/dev/null 2>&1 && [ ! -x "$MISE_BIN" ]; then
  curl -fsSL https://mise.run | sh
fi

if [ -x "$MISE_BIN" ] && ! command -v mise >/dev/null 2>&1; then
  export PATH="$HOME/.local/bin:$PATH"
fi

ACTIVATE='eval "$(mise activate bash)"'
if ! grep -qF "$ACTIVATE" "$HOME/.bashrc" 2>/dev/null; then
  printf '%s\n' "$ACTIVATE" >>"$HOME/.bashrc"
fi

mise install --yes
mise ls
