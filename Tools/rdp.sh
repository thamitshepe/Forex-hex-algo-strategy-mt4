#!/bin/bash
#
# Open the Windows VPS over RDP from macOS.
#
# There is no web URL for RDP: the rdp:// scheme only hands a preconfigured
# session to an installed client, so `open rdp://...` fails with "Unable to
# interpret ... as a path or URL" on a clean Mac. This script therefore picks
# whatever client actually exists instead of assuming one.
#
# Preference order, first available wins:
#   1. sdl-freerdp  - native SDL3, no X11, installed by `brew install freerdp`
#   2. xfreerdp     - same package, but needs XQuartz running
#   3. Windows App  - GUI client from the App Store, driven via the rdp:// scheme
#
# Usage:
#   Tools/rdp.sh                              # connect with defaults below
#   Tools/rdp.sh --print                      # show the command, do not connect
#   RDP_HOST=1.2.3.4 RDP_USER=admin Tools/rdp.sh
#   RDP_PASS=secret Tools/rdp.sh              # else prompted for, without echo
#
# Exit code 0 = client launched, 2 = environment problem (no client, no host).
#
# The defaults are the Windows VPS (DEPLOY.md §8); override with the RDP_* vars
# above. Passing /p puts the password in the process list, which the FreeRDP
# client warns about; clipboard sync is left on because moving the compiled .ex4
# over beats retyping it in the remote desktop.

set -u

HOST="${RDP_HOST:-147.90.182.131}"
PORT="${RDP_PORT:-3389}"
RDPUSER="${RDP_USER:-Administrator}"
BREW="/opt/homebrew"

print_only=0
case "${1:-}" in
  -n|--print) print_only=1 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --print)"; exit 2 ;;
esac

# Resolution follows the local window; /dynamic-resolution lets the remote
# desktop reflow instead of being pinned to a guessed size.
args=(/v:"${HOST}:${PORT}" /u:"$RDPUSER" /cert:ignore /dynamic-resolution)

# FreeRDP reads a missing password from the terminal, so only add /p when known.
# Otherwise the password lands in `ps` output for no benefit.
if [ -n "${RDP_PASS:-}" ]; then
  args+=(/p:"$RDP_PASS")
fi

find_client() {
  local c
  for c in "${BREW}/opt/freerdp/bin/sdl-freerdp" "${BREW}/opt/freerdp/bin/xfreerdp"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  c="$(command -v sdl-freerdp 2>/dev/null)" && { echo "$c"; return 0; }
  c="$(command -v xfreerdp 2>/dev/null)" && { echo "$c"; return 0; }
  c="${BREW}/bin/sdl-freerdp"
  [ -x "$c" ] && { echo "$c"; return 0; }
  return 1
}

client="$(find_client)"

if [ -z "$client" ]; then
  # No CLI client. The App Store client registers the rdp:// handler, so that
  # path does work once it is installed - it is checked, not assumed.
  if [ -n "$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null | grep -m1 'rdp:' || true)" ]; then
    url="rdp://full%20address=s:${HOST}:${PORT}&username=s:${RDPUSER}"
    [ -n "${RDP_PASS:-}" ] && url="${url}&password=s:${RDP_PASS}"
    if [ "$print_only" = 1 ]; then echo "open \"$url\""; exit 0; fi
    echo "opening via the installed GUI client..."
    exec open "$url"
  fi
  echo "no RDP client installed. Install one of:"
  echo "  brew install freerdp                 # terminal, no sudo, no App Store"
  echo "  brew install --cask windows-app      # Microsoft GUI client (needs sudo)"
  echo "  App Store -> \"Windows App\"           # same app, manual"
  exit 2
fi

case "$client" in
  *xfreerdp*)
    if [ -z "${DISPLAY:-}" ]; then
      echo "xfreerdp needs an X server. Start XQuartz, or:"
      echo "  brew install --cask xquartz"
      exit 2
    fi
    ;;
esac

if [ "$print_only" = 1 ]; then
  printf '%q ' "$client" "${args[@]}"; echo
  exit 0
fi

echo "connecting $RDPUSER@$HOST:$PORT via $(basename "$client")"
exec "$client" "${args[@]}"
