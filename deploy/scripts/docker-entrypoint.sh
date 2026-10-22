#!/bin/bash
# Container entrypoint. Starts as root, becomes the trader user, runs the EA.
#
# The only thing root is for is making the volume usable. Wine and MetaTrader must
# run as one user from start to finish because the wineserver socket is per-user:
# an unprivileged terminal talking to a root-owned wineserver cannot be signalled,
# and the clean SIGTERM shutdown (which is what flushes MT4's journal and the EA's
# CSVs) depends on `wineserver -k` reaching it.
set -euo pipefail

MT4DIR="${MT4DIR:-/data/mt4}"

mkdir -p /data "$MT4DIR"
uid="$(id -u trader)"

# The check has to look at $MT4DIR too, not only at /data. The mkdir above runs as
# root, so on a volume Docker populated from the image - /data already owned by
# trader - the freshly made /data/mt4 stays root:root. The old /data-only check saw
# a matching owner, skipped the chown, and every write as trader then failed with a
# wall of "tar: ./MQL4: Cannot mkdir: Permission denied".
reason=""
[ "$(stat -c %u /data)" = "$uid" ] || reason="/data"
if [ -z "$reason" ]; then
  [ "$(stat -c %u "$MT4DIR")" = "$uid" ] || reason="$MT4DIR (created as root just above)"
fi
if [ -z "$reason" ]; then
  found="$(find /data -maxdepth 3 ! -user trader -print -quit 2>/dev/null || true)"
  if [ -n "$found" ]; then
    reason="$found (left behind by a run that owned it as another user)"
  fi
fi
if [ -n "$reason" ]; then
  echo "[hex] $(date -u +%H:%M:%S) taking ownership of /data for trader (uid $uid): $reason"
  chown -R trader:trader /data
fi

exec gosu trader /opt/hex/entrypoint.sh
