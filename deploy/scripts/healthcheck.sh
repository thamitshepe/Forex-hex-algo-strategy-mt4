#!/bin/bash
# Docker HEALTHCHECK for the HEX-FVG-Breaker container.
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

MT4DIR="${MT4DIR:-/data/mt4}"
LOGDIR="$MT4DIR/MQL4/Files/Common/HEX-Logs"
MAX_AGE_MIN="${HEX_HEARTBEAT_MAX_AGE_MIN:-180}"

fail() { echo "unhealthy: $*"; exit 1; }

# `stat -c` is GNU, `stat -f` is BSD: the same check is run by hand on a dev
# machine, where the container's coreutils are not the ones in $PATH.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

pgrep -f 'terminal\.exe' >/dev/null || fail "terminal.exe is not running"
[ -f "$MT4DIR/startup.ini" ] || fail "startup.ini is missing - MT4 was not started by the entrypoint"

# equity.csv is the EA's heartbeat, written every LogEveryNTicks ticks (300 by
# default). Weekends and quiet sessions legitimately push it past an hour, so the
# window is generous; what this catches is a terminal that is up but not ticking
# the EA any more.
if [ -f "$LOGDIR/equity.csv" ]; then
  age=$(( ( $(date +%s) - $(mtime "$LOGDIR/equity.csv") ) / 60 ))
  [ "$age" -le "$MAX_AGE_MIN" ] || fail "equity.csv heartbeat is ${age} min old (limit ${MAX_AGE_MIN})"
  echo "ok: terminal up, heartbeat ${age} min old"
else
  echo "ok: terminal up, no heartbeat file yet (expected before the first write)"
fi
