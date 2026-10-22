#!/bin/bash
# Turn a *broker's own* MetaTrader 4 installer into a portable distro, on this
# machine, with no Wine installed and no Windows machine in the loop.
#
#   deploy/scripts/prepare-broker-distro.sh tmgm ~/Downloads/tmgm4setup.exe
#   deploy/scripts/prepare-broker-distro.sh --dry-run tmgm ~/Downloads/tmgm4setup.exe
#
# Why this exists rather than prepare-distro.sh: that one archives the MetaTrader
# already installed on this machine, and that terminal knows exactly one broker.
# MT4 dials only the servers whose address is in its own config/servers.ini
# (encrypted, per terminal, per broker) and it has no drop-in file for a server
# list - checked: a terminal that never met a broker writes no *.srv. So a second
# account at a second broker gets "'<login>': connect failed [No connection]" for
# ever, however right the password is. The broker's installer is the one artefact
# that carries both the server list and a terminal that will use it.
#
# The installer runs inside the deployment image (Wine + Xvfb + openbox + noVNC are
# already in it), against a throwaway named volume, and the archive is written by
# tar *inside* a Linux container - which is also why no macOS AppleDouble junk
# ends up in it, the thing prepare-distro.sh has to check for afterwards.
#
# What you get: dist/mt4-portable-<slug>.tar.gz plus the three variables to set.
set -euo pipefail

SLUG=""; SETUP=""; DRY=0; KEEP=0; WAIT_SECS="${PREP_WAIT:-0}"

usage() {
  cat <<'EOF'
usage: prepare-broker-distro.sh [--dry-run] [--login] [--wait SECONDS] [--clean] <slug> <installer.exe>

  <slug>            short name for the broker, used in the output file name (tmgm)
  <installer.exe>   the broker's MetaTrader 4 setup file, as downloaded from them
  --login           hold the container open until you say so, so you can log in
                    through the desktop first (File -> Login). The saved account
                    then travels inside the archive
  --wait SECONDS    the same, without a keyboard: wait this long instead
  --dry-run         print the docker commands and touch nothing
  --clean           remove the throwaway volume at the end, so the next run starts
                    from a clean install instead of reusing this one

The image is ghcr.io/thamitshepe/forex-hex-mt4:live unless HEX_IMAGE says otherwise.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --login)   WAIT_SECS=-1 ;;
    --wait)    WAIT_SECS="${2:-}"; [ -n "$WAIT_SECS" ] || die "--wait needs a number"; shift ;;
    --clean)   KEEP=1 ;;
    -h|--help) usage; exit 0 ;;
    --*)       die "unknown option: $1" ;;
    *)         if [ -z "$SLUG" ]; then SLUG="$1"; elif [ -z "$SETUP" ]; then SETUP="$1"; else die "unexpected argument: $1"; fi ;;
  esac
  shift
done

[ -n "$SLUG" ] && [ -n "$SETUP" ] || { usage >&2; exit 2; }
case "$SLUG" in *[!a-z0-9-]*) die "slug must be lowercase letters, digits and dashes (got '$SLUG')" ;; esac
[ -f "$SETUP" ] || die "no such installer: $SETUP"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${HEX_IMAGE:-ghcr.io/thamitshepe/forex-hex-mt4:live}"
OUT="${REPO}/dist/mt4-portable-${SLUG}.tar.gz"
NAME="hex-prep-${SLUG}"
VOL="hex-prep-${SLUG}-data"
SETUP_ABS="$(cd "$(dirname "$SETUP")" && pwd)/$(basename "$SETUP")"
VNC_PORT="${VNC_PORT:-16080}"
VNC_PASSWORD="${VNC_PASSWORD:-hexprep}"

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = "1" ]; then printf '  + %s\n' "$*"; else "$@"; fi; }
# Same, for the commands whose own output is noise (a volume name, a container id).
runq() { if [ "$DRY" = "1" ]; then printf '  + %s\n' "$*"; else "$@" >/dev/null 2>&1; fi; }

say "image      : $IMAGE"
say "installer  : $SETUP_ABS ($(wc -c < "$SETUP_ABS" | tr -d ' ') bytes)"
say "archive    : $OUT"
say "volume     : $VOL (throwaway)"
say "desktop    : http://localhost:${VNC_PORT}/vnc.html  password ${VNC_PASSWORD}"
say

if ! command -v docker >/dev/null 2>&1; then
  [ "$DRY" = "1" ] || die "docker is not on PATH"
fi

if [ "$DRY" = "1" ]; then
  say "(dry run: nothing below is executed)"
  say
fi

say "running the installer (this takes a few minutes; a 64-bit web stub installs nothing)"
runq docker volume create "$VOL"
runq docker rm -f "$NAME" || true

# A named volume, not a bind mount: the entrypoint refuses to work in a folder its
# uid does not own, and Docker Desktop presents a macOS bind mount with the host
# owner. The volume takes /data's owner from the image, which is the uid the
# entrypoint runs as.
runq docker run -d --name "$NAME" \
  -e MT4_SETUP_URL=file:///in/setup.exe \
  -e MT4_ALLOW_FRESH_INSTALL=1 \
  -e MT4_INSTANCE=1 \
  -e MT4_SYMBOL="${MT4_SYMBOL:-DOGEUSD}" \
  -e MT4_PERIOD="${MT4_PERIOD:-5}" \
  -e MT4_PRESET="${MT4_PRESET:-doge-scalp-shadow}" \
  -e ENABLE_VNC=1 -e VNC_PASSWORD="$VNC_PASSWORD" \
  -e SCREEN=1440x900x24 \
  -p "${VNC_PORT}:6080" \
  -v "${VOL}:/data" \
  -v "${SETUP_ABS}:/in/setup.exe:ro" \
  "$IMAGE"

if [ "$DRY" = "1" ]; then
  say
  say "would then poll for /data/mt4/terminal.exe, wait for a login if asked, stop the"
  say "terminal, and archive with:"
  run docker run --rm --entrypoint tar -v "${VOL}:/data:ro" "$IMAGE" -czf - -C /data/mt4 \
    --exclude=history --exclude=logs --exclude=tester --exclude=Sounds \
    --exclude='_autobackup_*' --exclude='*.log' .
  say
  say "and stop $NAME, leaving the volume for --clean."
  exit 0
fi

# Poll for the terminal. The installer either produces one or does not, and the
# difference has to be a sentence, not a timeout.
say "waiting for terminal.exe in the volume ..."
found=0
for _ in $(seq 1 90); do
  if docker exec "$NAME" test -f /data/mt4/terminal.exe 2>/dev/null; then found=1; break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then break; fi
  sleep 4
done

if [ "$found" != "1" ]; then
  say
  say "the installer did not produce a terminal. Its own output, and the container's:"
  docker logs "$NAME" 2>&1 | tail -40 | sed 's/^/  /'
  say
  say "MetaQuotes' own mt4setup.exe is a 64-bit web installer and never works under"
  say "Wine. A broker's setup.exe usually does - if this one does not, install the"
  say "broker's terminal on a Windows machine instead, log in once, and archive that"
  say "folder with tar (DEPLOY.md section 4C, route 3)."
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  exit 1
fi

say "terminal.exe is in the volume - the broker's server list is in it too"
docker logs "$NAME" 2>&1 | grep -E 'installed terminal found|server route|login|startup\.ini' | tail -8 | sed 's/^/  /'

if [ "$WAIT_SECS" = "-1" ]; then
  say
  say "Log in through the desktop now if you want the archive to carry the account:"
  say "  http://localhost:${VNC_PORT}/vnc.html   (password: ${VNC_PASSWORD})"
  say "  File -> Login, then check the title bar shows the account and the corner"
  say "  stops saying 'No connection'. Close that dialog and press Enter here."
  read -r _ || true
elif [ "${WAIT_SECS:-0}" -gt 0 ] 2>/dev/null; then
  say "leaving the desktop open for ${WAIT_SECS}s in case you want to log in"
  sleep "$WAIT_SECS"
fi

say
say "stopping the terminal before archiving - a tree copied while MT4 is running is"
say "a half-written tree (the same reason prepare-distro.sh refuses to run)"
runq docker stop -t 25 "$NAME"
say "archiving (history, logs, tester, sounds and backups are left out) ..."
mkdir -p "${REPO}/dist"
# Written beside the real name and moved into place: a tar that dies halfway leaves
# something that looks like a distro and fails a hundred lines later elsewhere.
docker run --rm --entrypoint tar -v "${VOL}:/data:ro" "$IMAGE" -czf - -C /data/mt4 \
  --exclude=history \
  --exclude=logs \
  --exclude=tester \
  --exclude=Sounds \
  --exclude='_autobackup_*' \
  --exclude='*.log' \
  . > "${OUT}.part" || die "tar failed - nothing was written to $OUT"
mv -f "${OUT}.part" "$OUT"

# Checked, not assumed: a terminal at the root and no AppleDouble twins. The reader
# matters - macOS tar -t hides "._name" members, so grep for them explicitly.
members="$(tar -tzf "$OUT" | grep -c . || true)"
double="$(tar -tzf "$OUT" | grep -c '\./\._' || true)"
[ "$(tar -tzf "$OUT" | grep -cx '\./terminal\.exe' || true)" = "1" ] \
  || die "the archive has no ./terminal.exe - not shipping it"
sha="$(shasum -a 256 "$OUT" 2>/dev/null | cut -d' ' -f1 || sha256sum "$OUT" | cut -d' ' -f1)"

say "wrote      : $OUT ($(du -h "$OUT" | cut -f1))"
say "members    : $members   AppleDouble: $double"
say "sha256     : $sha"
say

docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ "$KEEP" = "1" ]; then
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  say "removed the throwaway volume $VOL"
else
  say "the throwaway volume $VOL is still there (docker volume rm $VOL) - it holds"
  say "the installed tree, so the archive can be rebuilt without reinstalling."
fi

cat <<EOF

Next, for the second instance (DEPLOY.md section 4C):

  1. put the archive where the container can fetch it (any https:// host, or a
     release asset):
       gh release create mt4-distro-${SLUG} "$OUT"
  2. in Dokploy, on the mt4-doge service:
       MT4_DISTRO_URL2=https://…/mt4-portable-${SLUG}.tar.gz
       MT4_FORCE_SEED2=1          one deploy, replaces this volume's tree
       MT4_KEEP_SEED_LOGIN2=1     only if you logged in before archiving
  3. deploy, and watch for:
       [hex] seeding /data/mt4 from MT4_DISTRO_URL
       [hex] server route : <the broker's server> …   (not "no config/….srv")
       [mt4] '<login>': login on <server> …
  4. then remove MT4_FORCE_SEED2 so a later restart cannot re-seed over the live
     tree; keep MT4_KEEP_SEED_LOGIN2.

Port ${VNC_PORT} is published on this machine only; give VNC_PASSWORD a real value
if you run this somewhere other than your own laptop.
EOF
