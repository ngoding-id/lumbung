#!/usr/bin/env bash
# fetch-previous-release.sh
#
# Downloads every asset of the latest GitHub Release for $GITHUB_REPOSITORY
# into ./previous/. If there is no release yet (HTTP 404), creates an empty
# ./previous/ directory and exits 0.
#
# Required env:
#   GITHUB_TOKEN       - token with `contents: read` on the repo
#   GITHUB_REPOSITORY  - owner/repo (provided automatically by GitHub Actions)
#
# Dependencies: curl, jq

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

PREV_DIR="${1:-previous}"
mkdir -p "$PREV_DIR"

api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/latest"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

http_code=$(curl -sSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -o "$response_file" \
  -w '%{http_code}' \
  "$api_url")

if [ "$http_code" = "404" ]; then
  echo "No previous release found (HTTP 404). Treating previous set as empty."
  exit 0
fi

if [ "$http_code" != "200" ]; then
  echo "Failed to fetch latest release: HTTP $http_code" >&2
  cat "$response_file" >&2 || true
  exit 1
fi

tag=$(jq -r '.tag_name // empty' "$response_file")
echo "Latest release tag: ${tag:-<none>}"

asset_count=$(jq -r '.assets | length' "$response_file")
echo "Found $asset_count assets to download."

if [ "$asset_count" = "0" ]; then
  exit 0
fi

# Iterate assets via NUL-separated records to be safe with filenames.
jq -r '.assets[] | "\(.name)\t\(.url)"' "$response_file" | \
while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  echo "Downloading $name ..."
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "${PREV_DIR}/${name}" \
    "$url"
done

echo "Previous release assets downloaded into ${PREV_DIR}/:"
ls -la "$PREV_DIR"
