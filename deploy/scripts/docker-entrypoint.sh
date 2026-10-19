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
if [ "$(stat -c %u /data)" != "$uid" ]; then
  echo "[hex] $(date -u +%H:%M:%S) taking ownership of /data for trader (uid $uid)"
  chown -R trader:trader /data
fi

exec gosu trader /opt/hex/entrypoint.sh
