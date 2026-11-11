#!/bin/bash
set -euo pipefail

response=$(mktemp)
trap 'rm -f "$response"' EXIT
status=$(curl -sS -o "$response" -w '%{http_code}' \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/tags/$VERSION")
if [[ "$status" == 404 ]]; then
    exit 0
fi
if [[ "$status" != 200 ]]; then
    echo "::error::Could not check release $VERSION (HTTP $status)."
    exit 1
fi
jq -e '(.draft | type == "boolean") and (.assets | type == "array")' "$response" > /dev/null
if jq -e '(.draft | not) and
    ([.assets[] | select(.state == "uploaded") | .name] as $names |
     ($names | index("shelfsync.koplugin.zip")) != null and
     ($names | index("shelfsync-fetch-cookies.zip")) != null)' "$response" > /dev/null; then
    echo "::error::Release $VERSION is already complete."
    exit 1
fi
