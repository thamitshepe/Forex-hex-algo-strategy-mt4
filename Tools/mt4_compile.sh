#!/bin/bash
#
# Compile an MQL4 Expert Advisor with the real MetaEditor, headless.
#
# MetaQuotes ships MT4 for macOS as a .pkg containing MetaTrader 4.app, which
# bundles its own Wine. That bundle also contains metaeditor.exe, and MetaEditor
# has a command-line interface, so the EA can be compiled on this machine without
# opening the application or touching MetaEditor's GUI. This matters because
# lint_mql4.py can only approximate a compiler; it cannot tell you that
# OrderCalcMargin does not exist in MQL4 or that WebRequest takes nine arguments
# here and eight in MQL5.
#
# Usage:
#   Tools/mt4_compile.sh                      # compile the EA
#   Tools/mt4_compile.sh OtherFile.mq4        # compile a named file from MQL4/Experts
#
# Exit code 0 = compiled with no errors, 1 = compile errors, 2 = environment
# problem (MT4 not installed where this script expects it).
#
# Requirements: /Applications/MetaTrader 4.app, and a Wine prefix already created
# by running that app once (it does so itself on first launch).

set -u

APP="/Applications/MetaTrader 4.app"
PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader4"
MD="${PREFIX}/drive_c/Program Files (x86)/MetaTrader 4"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

name="${1:-HEX-FVG-Breaker.mq4}"
src="${REPO}/MQL4/Experts/${name}"

[ -d "$APP" ] || { echo "MT4 not found at $APP"; exit 2; }
[ -d "$MD" ] || { echo "MT4 data folder not found. Launch MetaTrader 4 once to create it:"; echo "  open -a '$APP'"; exit 2; }
[ -f "$src" ] || { echo "no such source: $src"; exit 2; }

winebin="${APP}/Contents/SharedSupport/wine/bin/wine64"
[ -x "$winebin" ] || { echo "bundled wine64 missing at $winebin"; exit 2; }

base="${name%.mq4}"

# MetaEditor compiles the copy inside its own data folder, so the repo file is
# copied in first. The stale .ex4 is removed either way: its presence is how a
# previous run's success could be mistaken for this run's.
cp "$src" "${MD}/MQL4/Experts/${name}" || { echo "copy into data folder failed"; exit 2; }
rm -f "${MD}/MQL4/Experts/${base}.ex4" "${PREFIX}/drive_c/mt4compile.log"

# C:\ in the Wine prefix is drive_c. A log path is required because MetaEditor
# returns 0 whether or not the compile succeeded; the log is the only verdict.
( cd "$MD" && WINEPREFIX="$PREFIX" "$winebin" metaeditor.exe \
    "/compile:MQL4\\Experts\\${name}" '/log:C:\mt4compile.log' >/dev/null 2>&1 )

log="${PREFIX}/drive_c/mt4compile.log"
[ -f "$log" ] || { echo "MetaEditor produced no log"; exit 2; }

# The log is UTF-16LE. Errors name the source as a path relative to the data
# folder; strip that prefix so line numbers line up with the repo file.
iconv -f UTF-16LE -t UTF-8 "$log" 2>/dev/null \
  | sed -e "s|MQL4\\\\Experts\\\\||" -e '/^$/d' -e 's/\r$//' | sed -n '2,300p'

out="${MD}/MQL4/Experts/${base}.ex4"
if [ -f "$out" ]; then
  cp "$out" "${REPO}/MQL4/Experts/${base}.ex4" 2>/dev/null
  echo "OK: ${base}.ex4 built ($(wc -c < "$out" | tr -d ' ') bytes)"
  exit 0
fi
echo "FAILED: no .ex4 produced"
exit 1
