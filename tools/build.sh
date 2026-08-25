#!/usr/bin/env bash
# Builds a local shelfsync.koplugin.zip, mirroring the packaging step in
# .github/workflows/release.yml (same excludes, same internal folder name),
# but sourced from the current working tree instead of a pushed tag - so it
# includes uncommitted changes, and never picks up gitignored local-only
# tool artifacts (e.g. .serena/, graphify-out/) since it's built from
# `git ls-files` rather than a raw directory copy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="shelfsync.koplugin"
BUILD_DIR="$REPO_ROOT/build"
STAGE_DIR="$BUILD_DIR/$PLUGIN_NAME"
ZIP_PATH="$BUILD_DIR/$PLUGIN_NAME.zip"

# Same exclude set as release.yml's `zip -x` flags (including '*/*.git*',
# which also strips .github/ and .gitignore, not just .git/), plus `build/`
# itself - already gitignored so `git ls-files` wouldn't pick it up anyway,
# excluded explicitly here too as a safeguard.
EXCLUDE_RE='(^|/)[^/]*\.git[^/]*(/|$)|(^|/)(spec|lua_modules|\.luarocks|tools|build)/|(^|/)(lua|luarocks|\.tool-versions|README\.md|CHANGELOG\.md|LICENSE)$|\.rockspec$'

if ! command -v 7z >/dev/null 2>&1; then
  echo "error: 7z not found (install p7zip)" >&2
  exit 1
fi

cd "$REPO_ROOT"

rm -rf "$STAGE_DIR" "$ZIP_PATH"
mkdir -p "$STAGE_DIR"

git ls-files --cached --others --exclude-standard -z |
  grep -zv -E "$EXCLUDE_RE" |
  xargs -0 cp --parents --target-directory="$STAGE_DIR"

(cd "$BUILD_DIR" && 7z a -tzip "$ZIP_PATH" "$PLUGIN_NAME" >/dev/null)
rm -rf "$STAGE_DIR"

echo "Built $ZIP_PATH"
