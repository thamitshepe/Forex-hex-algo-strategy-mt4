#!/bin/sh
# Download the prepared MT5 distro: GitHub's release front door first, its API
# asset endpoint as the fallback.
#
# 2026-11-08: https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>
# answered HTTP 504 to every attempt - from a laptop in one region and from the
# CI runner in another, for over an hour - while the asset itself was fine: the
# release API reported it uploaded (129 MB) and
# https://api.github.com/repos/<owner>/<repo>/releases/assets/<id>, which
# redirects to release-assets.githubusercontent.com, served the same bytes. Two
# image builds died on that 504 and no fix reached the server, so retrying longer
# is not enough: the download has a second route.
#
# Usage: fetch-distro.sh URL DEST
#   0 = DEST holds the file. Anything else = it does not, and why is on stderr.
#   A file:// URL is copied, not downloaded (local tarball, no network).
#
# Neither jq nor python is assumed: the release JSON is parsed by awk, and only
# when the front door has already failed.
set -u

url="${1:-}"
dest="${2:-}"
if [ -z "$url" ] || [ -z "$dest" ]; then
  echo "usage: fetch-distro.sh URL DEST" >&2
  exit 2
fi

case "$url" in
  file://*)
    # A local tarball (tests, a distro baked into the image): nothing to fetch.
    if cp -f "${url#file://}" "$dest" 2>/dev/null; then
      exit 0
    fi
    echo "cannot copy ${url#file://} to $dest" >&2
    exit 1
    ;;
esac

# --retry-all-errors also retries 5xx and dropped connections. A permanent 504
# arrives instantly, so the retries cost nothing when the front door is healthy.
if curl -fsSL --retry 6 --retry-delay 5 --retry-max-time 300 --retry-all-errors \
        --connect-timeout 20 -o "$dest" "$url"; then
  exit 0
fi

# Only GitHub's release URLs have a second route.
case "$url" in
  https://github.com/*/releases/download/*/*) ;;
  *)
    echo "download failed (no API fallback for this URL): $url" >&2
    exit 1
    ;;
esac

# .../<owner>/<repo>/releases/download/<tag>/<asset>, split with shell only.
rest="${url#https://github.com/}"
owner="${rest%%/*}"
rest="${rest#*/}"
repo="${rest%%/*}"
rest="${rest#*/}"
tag_path="${rest#releases/download/}"
tag="${tag_path%%/*}"
asset="${tag_path#*/}"

api="https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
json="$(curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors --max-time 60 "$api" 2>/dev/null)" || json=""
if [ -z "$json" ]; then
  echo "download failed and the release API is unreachable: $api" >&2
  exit 1
fi

# The asset's id: the nearest "id" BEFORE the object that carries our "name" (the
# release has its own id, and the uploader inside the asset carries another, so
# neither "the first id" nor "the last" is right). Whitespace is stripped first,
# because GitHub pretty-prints and `[ \t\r\n]` in an awk regex is not portable.
flat="$(printf '%s' "$json" | tr -d '\n\r\t')"
id="$(printf '%s' "$flat" | awk -v want="$asset" '
  { s = $0
    nid = 0; nnm = 0
    rest = s; base = 0
    while (match(rest, /"id": *[0-9]+/)) {
      t = substr(rest, RSTART, RLENGTH); gsub(/[^0-9]/, "", t)
      ids[++nid] = t; ipos[nid] = base + RSTART
      base += RSTART + RLENGTH - 1
      rest = substr(rest, RSTART + RLENGTH)
    }
    rest = s; base = 0
    while (match(rest, /"name": *"[^"]*"/)) {
      t = substr(rest, RSTART, RLENGTH)
      sub(/.*"name": *"/, "", t); sub(/"$/, "", t)
      nms[++nnm] = t; npos[nnm] = base + RSTART
      base += RSTART + RLENGTH - 1
      rest = substr(rest, RSTART + RLENGTH)
    }
    for (i = 1; i <= nnm; i++) {
      if (nms[i] != want) continue
      best = ""
      for (j = 1; j <= nid; j++) if (ipos[j] < npos[i]) best = ids[j]
      if (best != "") { print best; exit 0 }
    }
    exit 1
  }')" || id=""
if [ -z "$id" ]; then
  echo "download failed and the release API lists no asset named '$asset'" >&2
  exit 1
fi
echo "the release front door refused the download; fetching asset $id through the API instead" >&2
curl -fsSL --retry 6 --retry-delay 5 --retry-max-time 600 --retry-all-errors \
     --connect-timeout 20 -H 'Accept: application/octet-stream' -L -o "$dest" \
     "https://api.github.com/repos/$owner/$repo/releases/assets/$id"
