#!/bin/bash
# Docker HEALTHCHECK for the HEX-BoomRider (MT5) container.
#
# Three questions, in order of how often they go wrong:
#   1. is MetaTrader still running?  (a dead terminal is a dead robot)
#   2. has the EA written its heartbeat lately?  (a running terminal with a
#      detached expert looks identical from outside)
#   3. is the chart the EA is on actually being TICKED?  (a running terminal, an
#      attached expert and a dead feed also looks identical - and that is what
#      2026-11-02 was: the chart stopped being ticked at 21:54, the EA was never
#      called again, and the container read "unhealthy, heartbeat 384 min old"
#      which named the wrong fault for six hours)
#
# This only reports. It does not restart anything: a container that quietly
# restarts itself every time the market is quiet would hide the very failure
# this check exists to expose. The entrypoint's feed_watchdog is what restarts
# the terminal, and it does it by killing it, which is visible in the log.
set -uo pipefail

MT5DIR="${MT5DIR:-/data/mt5}"
LOGDIR="$MT5DIR/MQL5/Files/HEX-Logs"
HB="$LOGDIR/HEX-BoomRider-heartbeat.txt"
MAX_AGE_MIN="${HEX_HEARTBEAT_MAX_AGE_MIN:-180}"
TICK_MAX_MIN="${HEX_TICK_STALL_MIN:-15}"

fail() { echo "unhealthy: $*"; exit 1; }

# `stat -c` is GNU, `stat -f` is BSD: the same check is run by hand on a dev
# machine, where the container's coreutils are not the ones in $PATH.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# 'terminal64[.]exe' - NOT 'terminal64\\.exe': inside single quotes the shell
# keeps both backslashes, the ERE then demands a literal backslash in the
# command line, and a healthy terminal was invisible to the check.
pgrep -f 'terminal64[.]exe' >/dev/null || fail "terminal64.exe is not running"
[ -f "$MT5DIR/mt5.ini" ] || fail "mt5.ini is missing - MT5 was not started by the entrypoint"

# HEX-BoomRider-heartbeat.txt is the EA's heartbeat, rewritten every
# InpHeartbeatSec seconds (60 by default) from a terminal TIMER - not from OnTick,
# which is the whole point: the timer fires even when the chart is not being fed,
# so a heartbeat that stops moving means the EA is not being called at all. The
# EA's BLOWN marker is not a failure: a blown account is the strategy working as
# designed - it says so, loudly, and halts on purpose.
if [ -f "$LOGDIR/HEX-BoomRider-BLOWN.txt" ]; then
  echo "ok: terminal up, EA is BLOWN (equity <= baseline) - halting by design, reset the demo account to resume"
  exit 0
fi
if [ -f "$HB" ]; then
  age=$(( ( $(date +%s) - $(mtime "$HB") ) / 60 ))
  [ "$age" -le "$MAX_AGE_MIN" ] || fail "EA heartbeat is ${age} min old (limit ${MAX_AGE_MIN}) - the EA is not being called at all: it is off the chart, or the terminal's timer thread is stuck"
  # The beat also carries the age of the last tick: "<time>|tick_age=<s>|...".
  # A beat that keeps moving while tick_age climbs is a live EA on a chart
  # nothing is ticking - no entry, no exit, nothing trading - and on this symbol
  # (Deriv Boom, 24/7) that is a fault, never a closed market. An older build's
  # beat has no such field, and "unknown" must not read as a failure.
  tick_age=$(sed -n 's/.*|tick_age=\([0-9][0-9]*\)|.*/\1/p' "$HB" 2>/dev/null | tail -1)
  if [ -n "$tick_age" ]; then
    [ "$tick_age" -le $(( TICK_MAX_MIN * 60 )) ] || \
      fail "terminal up, EA beating, but no quotes for $(( tick_age / 60 )) min (limit ${TICK_MAX_MIN}) - the chart is not being ticked, so nothing can trade"
    echo "ok: terminal up, EA heartbeat ${age} min old, last tick $(( tick_age / 60 )) min ago"
  else
    echo "ok: terminal up, EA heartbeat ${age} min old"
  fi
else
  echo "ok: terminal up, no EA heartbeat yet (expected before the first write)"
fi
