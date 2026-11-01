#!/bin/bash
# Freeze the MetaTrader 5 install on this machine into a portable distro the
# container can seed from. Run it on macOS, from the repo root:
#
#   deploy/scripts/prepare-mt5-distro.sh            # refuses if MT5 is running
#
# Why this rather than the container's own installer: the distro IS a complete,
# known-good terminal64 tree (terminal, metaeditor64, MQL5 skeleton, the server
# list from this machine's installs). No Wine-installer roulette on the server.
# Anything the server version lacks (say, a broker server missing from the
# server list) is fixed here, once, on the desktop, and every future boot
# inherits it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="${MT5_PREFIX:-$HOME/Library/Application Support/net.metaquotes.wine.metatrader5}"
OUTDIR="${REPO}/dist"
OUT="${OUTDIR}/mt5-portable.tar.gz"

# Portable mode puts the data folder in the install folder; both layouts are
# checked so the failure says which one is missing rather than "not found".
find_mt5() {
  local c
  for c in "$PREFIX/drive_c/Program Files/MetaTrader 5" "$PREFIX/drive_c/MetaTrader 5"; do
    [ -f "$c/terminal64.exe" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

find_mt5 >/dev/null || {
  echo "no terminal64.exe under: $PREFIX/drive_c"
  echo "If MT5 lives elsewhere, set MT5_PREFIX (the net.metaquotes.wine.metatrader5 dir)."
  exit 2
}

MD="$(find_mt5)"
if pgrep -fl 'MetaTrader 5|terminal64' >/dev/null 2>&1; then
  echo "MetaTrader 5 looks like it is running:"
  pgrep -fl 'MetaTrader 5|terminal64' | sed 's/^/  /'
  echo
  echo "Close it first. A live tree copies as a half-written tree:"
  echo "config/, the MQL5 tree and the journal are all rewritten on the way out."
  exit 1
fi

echo "tree        : $MD"
echo "terminal    : $(ls -l "$MD/terminal64.exe" | awk '{print $5\" bytes\"}')"
[ -f "$MD/metaeditor64.exe" ] \
  && echo "compiler    : present (the container compiles the EA with it)" \
  || echo "compiler    : MISSING - metaeditor64.exe not found"
echo "config      : $(ls "$MD/config" 2>/dev/null | wc -l | tr -d ' ') files (server list, accounts)"

mkdir -p "$OUTDIR"
echo
echo "archiving (Bases, history, logs, tester, sounds are left out; all re-download) ..."
# --no-mac-metadata / --no-xattrs: without them every file gains an AppleDouble
# twin (._name) or a LIBARCHIVE.xattr header, MetaEditor batch-compiles the
# twins on the server and GNU tar warns per header. macOS tar -t HIDES the
# ._members afterwards, which is why the count below uses python's tarfile -
# what Linux tar will see, not what macOS reports.
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$OUT" -C "$MD" \
  --exclude='Bases' \
  --exclude='history' \
  --exclude='logs' \
  --exclude='Tester' \
  --exclude='_autobackup_*' \
  --exclude='*.log' \
  --exclude='*.tmp' \
  --exclude='DDE-Sample.xls' \
  .

echo "wrote       : $OUT ($(du -h "$OUT" | cut -f1))"
echo "sha256      : $(shasum -a 256 "$OUT" | cut -d' ' -f1)"

# The archive is checked, not assumed, with the reader that sees what Linux sees.
member_count="$(python3 - "$OUT" <<'PY' 2>/dev/null || echo "?"
import sys, tarfile
names = [m.name for m in tarfile.open(sys.argv[1])]
double = [n for n in names if n.rsplit('/', 1)[-1].startswith('._')]
print('%d %d' % (len(names), len(double)))
PY
)"
set -- $member_count
members="${1:-?}"; apple_double="${2:-?}"
xattr_headers="$(gunzip -c "$OUT" | grep -ac 'LIBARCHIVE.xattr' || true)"
echo "members     : ${members}   AppleDouble: ${apple_double}   xattr hdrs: ${xattr_headers:-0}"
if [ "${apple_double:-?}" != 0 ] || [ "${xattr_headers:-0}" != 0 ]; then
  echo
  echo "REFUSING TO SHIP: the archive still carries macOS metadata."
  exit 1
fi
if [ "$members" -lt 100 ] 2>/dev/null; then
  echo "REFUSING TO SHIP: only $members members - that is not a complete MT5 tree."
  exit 1
fi

cat <<EOF

Next, ship it and point the container at it:
  1. gh release create mt5-portable-distro dist/mt5-portable.tar.gz \\
       --title "MT5 portable distro" --notes "Complete MT5 tree, Bases excluded"
  2. in Dokploy (Environment tab), add:
       MT5_DISTRO_URL=https://github.com/thamitshepe/Forex-hex-algo-strategy-mt4/releases/download/mt5-portable-distro/mt5-portable.tar.gz
  3. Redeploy, and watch for "distro seeded (recorded in /data/mt5/.seeded-from)".

Re-run this script whenever MT5 on this machine changes in a way the server
should inherit (a server added, an option, a chart saved).
EOF