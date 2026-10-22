#!/bin/bash
# Freeze the MetaTrader 4 on this machine into a portable distro the container can
# seed from. Run it on macOS, from the repo root:
#
#   deploy/scripts/prepare-distro.sh              # refuses if MT4 is running
#   deploy/scripts/prepare-distro.sh --force      # copies anyway (not advised)
#
# Why you would want this rather than letting the container install its own copy:
# the distro carries the parts of a MetaTrader setup that no installer and no
# command line can reproduce - the WebRequest allow-list for ntfy, the Options
# "expert advisors" flags, the seeded XAUUSD M15 chart with the EA on it, and the
# account you already logged in with. Those live in config/ and profiles/ inside
# the data folder, and in portable mode the data folder is the install folder, so
# copying the folder copies all of it.
#
# What it costs: MetaTrader must be closed, and once the server is trading you
# must not also run the Mac copy - two terminals on one account is two robots.
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="${MT4_PREFIX:-$HOME/Library/Application Support/net.metaquotes.wine.metatrader4}"
OUTDIR="${REPO}/dist"
OUT="${OUTDIR}/mt4-portable.tar.gz"

# Data folder == install folder only in portable mode. Both layouts are checked so
# the failure says which one is missing rather than "not found".
find_mt4() {
  local c
  for c in "$PREFIX/drive_c/Program Files/MetaTrader 4" \
           "$PREFIX/drive_c/Program Files (x86)/MetaTrader 4"; do
    [ -f "$c/terminal.exe" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

MD="$(find_mt4)" || {
  echo "no terminal.exe under: $PREFIX/drive_c"
  echo "If MT4 lives elsewhere, set MT4_PREFIX (the net.metaquotes.wine.metatrader4 dir)."
  exit 2
}

if [ "$FORCE" = "0" ] && pgrep -fl 'MetaTrader 4.app|terminal\.exe' >/dev/null 2>&1; then
  echo "MetaTrader looks like it is running:"
  pgrep -fl 'MetaTrader 4.app|terminal\.exe' | sed 's/^/  /'
  echo
  echo "Close it first. A live tree copies as a half-written tree: profiles,"
  echo "config/accounts.ini and the .ex4 are all rewritten on the way out."
  echo "Re-run with --force only if you know the copy does not matter."
  exit 1
fi

echo "data folder : $MD"
echo "terminal    : $(ls -l "$MD/terminal.exe" | awk '{print $5" bytes"}')"
echo "ea present  : $(ls "$MD/MQL4/Experts/HEX-FVG-Breaker.ex4" 2>/dev/null || echo 'no - the container compiles it from source')"
# config/experts.ini is a binary MetaQuotes file: its strings are UTF-16LE, so
# `strings | grep` reports a false "not found" for a WebRequest list that is right
# there. Decode it the way the entrypoint decodes MT4's own logs, blank the
# non-printable bytes, and the URL becomes a plain ASCII token again.
ntfy_url="$(iconv -f UTF-16LE -t UTF-8 "$MD/config/experts.ini" 2>/dev/null \
  | tr -c '[:print:]\n' ' ' | grep -o 'https://ntfy[^ ]*' | head -1 || true)"
echo "ntfy allow  : ${ntfy_url:-not in config/experts.ini - add it once in the terminal (DEPLOY.md section 3)}"
echo "charts      : $(ls "$MD/profiles/default/"*.chr 2>/dev/null | wc -l | tr -d ' ') in profiles/default"
if [ -f "$MD/profiles/default/chart04.chr" ] && ! strings -a "$MD/profiles/default/chart04.chr" | grep -qi xauusd; then
  echo "  note: the default profile's charts do not mention XAUUSD - check the symbol"
fi

mkdir -p "$OUTDIR"
echo
echo "archiving (history, logs, tester, sounds and backups are left out) ..."
# Both flags, and they are not the same flag:
#   --no-mac-metadata  stops the AppleDouble "._name" entries that land in MQL4 and
#                      get batch-compiled by MetaEditor on the server.
#   --no-xattrs        stops the per-file "LIBARCHIVE.xattr.com.apple.provenance"
#                      header. Measured on bsdtar 3.5.3: --no-mac-metadata alone
#                      leaves those headers in, and GNU tar on the server warns
#                      once for each of them - 272 lines for this archive.
# history/ is excluded on purpose: it is per-server and re-downloads on first
# connect, and it is the one folder that grows without limit.
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$OUT" -C "$MD" \
  --exclude='history' \
  --exclude='logs' \
  --exclude='tester' \
  --exclude='Sounds' \
  --exclude='_autobackup_*' \
  --exclude='*.log' \
  --exclude='DDE-Sample.xls' \
  .

echo "wrote       : $OUT ($(du -h "$OUT" | cut -f1))"
echo "sha256      : $(shasum -a 256 "$OUT" | cut -d' ' -f1)"

# The archive is checked, not assumed, and with a reader that shows everything:
# macOS `tar -t` HIDES AppleDouble entries - it treats "._name" as metadata for
# "name" rather than as a member - so it reports 0 for an archive that a Linux
# tar extracts as 544 files. Python's tarfile lists members as stored, which is
# what the container's GNU tar will do.
member_count="$(python3 - "$OUT" <<'PY' 2>/dev/null || echo "?"
import sys, tarfile
names = [m.name for m in tarfile.open(sys.argv[1])]
double = [n for n in names if n.rsplit("/", 1)[-1].startswith("._")]
print("%d %d" % (len(names), len(double)))
PY
)"
set -- $member_count
members="${1:-?}"; apple_double="${2:-?}"
xattr_headers="$(gunzip -c "$OUT" | grep -ac 'LIBARCHIVE.xattr' || true)"
echo "members     : ${members}   AppleDouble: ${apple_double}   xattr hdrs: ${xattr_headers:-0}"
# 272 real files is the expected size of this distro; twice that means every one
# of them arrived with an AppleDouble twin and Linux will see 544 files.
if [ "${apple_double:-?}" != "0" ] || [ "${xattr_headers:-0}" != "0" ]; then
  echo
  echo "REFUSING TO SHIP: the archive still carries macOS metadata."
  echo "  AppleDouble ._name -> Linux tar extracts them, MetaEditor batch-compiles"
  echo "                        every one, and they land in MQL4 (~15 s of boot)"
  echo "  xattr headers      -> GNU tar on the server warns once per file"
  echo "Rebuild with --no-mac-metadata --no-xattrs (both are in this script)."
  exit 1
fi
cat <<EOF

Next, on the server:
  1. copy it into the volume that ./deploy/docker-compose.yml mounts at /data
       scp "$OUT" user@server:/opt/hex-mt4/mt4-portable.tar.gz
  2. point the container at it
       MT4_DISTRO_URL=file:///data/mt4-portable.tar.gz
  3. start the container and watch it seed, compile and launch
       docker compose logs -f

Re-run this script after changing anything in MT4 by hand (an option, a chart, the
WebRequest list) and the next container start picks the change up.
EOF
