#!/usr/bin/env bash
# resolve-tag.sh <owner/image> [moving_tag]
# Prints the immutable tag (sha-xxxxxxx, or a 40-char commit hash if the image was tagged that way) that
# currently points to the same build as the moving tag (default: latest). Prefers sha-xxxxxxx if both exist.
# Needs: curl, jq, GHCR_PAT (read:packages). Read-only, changes nothing.
set -euo pipefail

repo="${1:?missing owner/image, e.g. myorg/myservice}"
moving="${2:-latest}"
owner="${repo%%/*}"
pkg="${repo#*/}"
api="${GH_API:-https://api.github.com}"
: "${GHCR_PAT:?missing GHCR_PAT}"

body="$(mktemp)"; trap 'rm -f "$body"' EXIT

fetch() {  # $1 = orgs|users ; prints the HTTP code
  curl -sS --max-time 20 -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $GHCR_PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$api/$1/$owner/packages/container/$pkg/versions?per_page=100"
}

code="$(fetch orgs || true)"
[ "$code" = 200 ] || code="$(fetch users || true)"
case "$code" in
  200) ;;
  401) echo "resolve-tag: 401 - GHCR_PAT is wrong or expired" >&2; exit 10 ;;
  403) echo "resolve-tag: 403 - the PAT is missing the read:packages scope (or hasn't been granted package access)" >&2; exit 10 ;;
  404) echo "resolve-tag: 404 - package '$repo' not found (wrong name, or the PAT's account has no read access)" >&2; exit 10 ;;
  *)   echo "resolve-tag: error calling the GitHub API (HTTP ${code:-none})" >&2; exit 10 ;;
esac

# The build carrying the moving tag -> get the sha-xxxxxxx tag for that same build
out="$(jq -r --arg t "$moving" '
  [ .[] | select((.metadata.container.tags // []) | index($t)) ][0]
  | if . == null then empty
    else "\(.name)\t\(([.metadata.container.tags[] | select(test("^sha-[0-9a-f]{7}$"))][0]) // ([.metadata.container.tags[] | select(test("^[0-9a-f]{40}$"))][0]) // "")"
    end' "$body")"

if [ -z "$out" ]; then
  echo "resolve-tag: no build carries tag '$moving' among the last 100 builds" >&2
  echo "             (is CI actually pushing tag '$moving'? check the repo's build/publish workflow)" >&2
  exit 11
fi

digest="${out%%$'\t'*}"
tag="${out#*$'\t'}"
if [ -z "$tag" ]; then
  echo "resolve-tag: '$moving' ($digest) has no immutable tag alongside it (sha-xxxxxxx or a 40-char commit hash); CI needs to set that tag in the same build" >&2
  exit 12
fi

echo "resolve-tag: $moving -> $tag ($digest)" >&2
echo "$tag"
