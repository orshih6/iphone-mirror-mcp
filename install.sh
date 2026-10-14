#!/usr/bin/env bash
# Builds a release binary and installs it as `iphone-mirror` (CLI) plus an
# `iphone-mirror-mcp` link (starts the MCP server when run with no arguments).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iphone-mirror only runs on macOS (iPhone Mirroring needs macOS 15+)." >&2
  exit 1
fi

swift build -c release --product iphone-mirror
mkdir -p "$INSTALL_DIR"
install -m 755 .build/release/iphone-mirror "$INSTALL_DIR/iphone-mirror"
ln -sf "$INSTALL_DIR/iphone-mirror" "$INSTALL_DIR/iphone-mirror-mcp"

echo "Installed $INSTALL_DIR/iphone-mirror ($("$INSTALL_DIR/iphone-mirror" --version))"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "Note: $INSTALL_DIR is not on your PATH." ;;
esac
cat <<MSG

Next:
  1. Grant permissions to the app you run Claude Code in (Terminal, iTerm, Ghostty, VS Code…):
       $INSTALL_DIR/iphone-mirror permissions
     then enable it under System Settings › Privacy & Security › Screen Recording and Accessibility,
     and restart that app.
  2. Register the MCP server with Claude Code:
       claude mcp add --scope user iphone-mirror -- $INSTALL_DIR/iphone-mirror-mcp
  3. Check:
       $INSTALL_DIR/iphone-mirror status
MSG
