#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer uv: it reads the dependency metadata at the top of fetch_cookies.py
# and installs browser_cookie3 into an ephemeral env automatically, so
# there's no separate `pip install` step.
if command -v uv >/dev/null 2>&1; then
  exec uv run "$SCRIPT_DIR/support/fetch_cookies.py" "$@"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: neither uv nor python3 found -- install uv (https://docs.astral.sh/uv/) or Python 3 (https://www.python.org/downloads/)" >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/support/fetch_cookies.py" "$@"
