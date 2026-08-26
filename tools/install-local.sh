#!/usr/bin/env bash
# Builds the plugin (via build.sh) and installs it into a local KOReader
# plugins/ folder for testing without a device, fully replacing the existing
# shelfsync.koplugin folder except for shelfsync_config.lua -- it's
# gitignored (user-specific, holds session cookies/tokens) so it's never
# part of the build output and would otherwise just get deleted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="shelfsync.koplugin"
KOREADER_DIR="${KOREADER_DIR:-$HOME/.config/koreader}"
DEST_DIR="$KOREADER_DIR/plugins/$PLUGIN_NAME"

if ! command -v 7z >/dev/null 2>&1; then
  echo "error: 7z not found (install p7zip)" >&2
  exit 1
fi
if [ ! -d "$KOREADER_DIR/plugins" ]; then
  echo "error: $KOREADER_DIR/plugins not found (set KOREADER_DIR to override)" >&2
  exit 1
fi

"$REPO_ROOT/tools/build.sh"

ZIP_PATH="$REPO_ROOT/build/$PLUGIN_NAME.zip"
EXTRACT_DIR="$REPO_ROOT/build/_install_extract"

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
7z x -y -o"$EXTRACT_DIR" "$ZIP_PATH" >/dev/null

CONFIG_BACKUP=""
if [ -f "$DEST_DIR/shelfsync_config.lua" ]; then
  CONFIG_BACKUP="$(mktemp)"
  cp "$DEST_DIR/shelfsync_config.lua" "$CONFIG_BACKUP"
fi

rm -rf "$DEST_DIR"
mv "$EXTRACT_DIR/$PLUGIN_NAME" "$DEST_DIR"
rm -rf "$EXTRACT_DIR"

if [ -n "$CONFIG_BACKUP" ]; then
  cp "$CONFIG_BACKUP" "$DEST_DIR/shelfsync_config.lua"
  rm -f "$CONFIG_BACKUP"
fi

echo "Installed $PLUGIN_NAME to $DEST_DIR"
