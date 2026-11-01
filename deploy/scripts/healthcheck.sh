#!/bin/bash
# Docker HEALTHCHECK for the HEX-BoomRider (MT5) container.
#
# Two questions, in order of how often they go wrong:
#   1. is MetaTrader still running?  (a dead terminal is a dead robot)
#   2. has the EA written its heartbeat lately?  (a running terminal with a
#      detached expert looks identical from outside)
#
# This only reports. It does not restart anything: a container that quietly
# restarts itself every time the market is quiet would hide the very failure
# this check exists to expose.
set -uo pipefail

MT5DIR="${MT5DIR:-/data/mt5}"
LOGDIR="$MT5DIR/MQL5/Files/HEX-Logs"
MAX_AGE_MIN="${HEX_HEARTBEAT_MAX_AGE_MIN:-180}"

fail() { echo "unhealthy: $*"; exit 1; }

# `stat -c` is GNU, `stat -f` is BSD: the same check is run by hand on a dev
# machine, where the container's coreutils are not the ones in $PATH.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# 'terminal64[.]exe' - NOT 'terminal64\\.exe': inside single quotes the shell
# keeps both backslashes, the ERE then demands a literal backslash in the
# command line, and a healthy terminal was invisible to the check.
pgrep -f 'terminal64[.]exe' >/dev/null || fail "terminal64.exe is not running"
[ -f "$MT5DIR/mt5.ini" ] || fail "mt5.ini is missing - MT5 was not started by the entrypoint"

# HEX-BoomRider-heartbeat.txt is the EA's heartbeat, refreshed every
# InpHeartbeatSec seconds (60 by default). Weekends and quiet sessions
# legitimately push it past an hour, so the window is generous; what this
# catches is a terminal that is up but not ticking the EA any more. The EA's
# BLOWN marker is not a failure: a blown account is the strategy working as
# designed - it says so, loudly, and halts on purpose.
if [ -f "$LOGDIR/HEX-BoomRider-BLOWN.txt" ]; then
  echo "ok: terminal up, EA is BLOWN (equity <= baseline) - halting by design, reset the demo account to resume"
  exit 0
fi
if [ -f "$LOGDIR/HEX-BoomRider-heartbeat.txt" ]; then
  age=$(( ( $(date +%s) - $(mtime "$LOGDIR/HEX-BoomRider-heartbeat.txt") ) / 60 ))
  [ "$age" -le "$MAX_AGE_MIN" ] || fail "EA heartbeat is ${age} min old (limit ${MAX_AGE_MIN})"
  echo "ok: terminal up, EA heartbeat ${age} min old"
else
  echo "ok: terminal up, no EA heartbeat yet (expected before the first write)"
fi
