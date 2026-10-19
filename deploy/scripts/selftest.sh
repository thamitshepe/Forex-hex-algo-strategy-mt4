#!/bin/bash
# Self-test for the pure parts of the deployment scripts.
#
# The container itself is the real test for everything that needs Wine, a display
# or a terminal, and CI runs that on every build (deploy/Dockerfile's ea-check
# stage compiles the EA). What CI cannot see is the shell logic between those
# steps: whether the generated startup.ini says what it claims, whether the log
# mirror reports a line exactly once, and whether the healthcheck fails when it
# should. Those are pure functions, so they are tested here instead - the same
# reason Tools/hex_report.py carries its own selftest.
#
# Usage: deploy/scripts/selftest.sh     (exit 0 = all checks passed)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"
HEALTHCHECK="$HERE/healthcheck.sh"
TMP="$(mktemp -d)"
PASS=0
FAIL=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
check_contains() { # name needle haystack
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2])" ;; esac
}

# Pull one function out of entrypoint.sh so it can be exercised without running
# the part that starts Wine.
load_fn() { # file name
  local body
  body="$(sed -n "/^$2() {/,/^}/p" "$1")"
  [ -n "$body" ] || { bad "could not extract $2 from $1"; return 1; }
  eval "$body"
}

# entrypoint.sh calls these; the selftest only needs them to not explode.
log()  { :; }
warn() { :; }
die()  { echo "die: $*" >&2; return 1; }

echo "startup.ini"
# shellcheck disable=SC2034  # read by the extracted function
MT4DIR="$TMP/mt4"; MT4_PROFILE=default; MT4_LOGIN=176428789
MT4_PASSWORD=secret; MT4_SERVER=MetaQuotes-Demo; MT4_SYMBOL=XAUUSD
MT4_EXPERT=HEX-FVG-Breaker; MT4_PRESET=100usd-demo
load_fn "$ENTRYPOINT" write_startup_ini >/dev/null
write_startup_ini >/dev/null 2>&1
ini="$TMP/mt4/startup.ini"
if [ -f "$ini" ]; then
  ok "file written"
  check_contains "profile"    "Profile=default"                     "$(cat "$ini")"
  check_contains "login"      "Login=176428789"                     "$(cat "$ini")"
  check_contains "server"     "Server=MetaQuotes-Demo"              "$(cat "$ini")"
  check_contains "symbol"     "Symbol=XAUUSD"                       "$(cat "$ini")"
  check_contains "expert"     "Expert=HEX-FVG-Breaker"              "$(cat "$ini")"
  check_contains "preset"     "ExpertParameters=100usd-demo.set"    "$(cat "$ini")"
  check_contains "autotrade"  "ExpertsTrades=true"                  "$(cat "$ini")"
  check_eq "no unexpanded \${}" "0" "$(grep -c '\${' "$ini")"
else
  bad "file written"
fi

echo "log mirror"
# The mirror has to survive the three things a naive tail does not: a file that
# grows, a file that gets truncated under it, and two folders at once.
load_fn "$ENTRYPOINT" mirror_dir >/dev/null
mdir="$TMP/logs"; mkdir -p "$mdir"
printf 'one\ntwo\n' > "$mdir/today.log"
mirror_dir "[mt4]" "$mdir" > "$TMP/mirror.out" 2>&1 &
mirror_pid=$!
sleep 3
printf 'three\n' >> "$mdir/today.log"          # grew
sleep 3
printf 'reset\n'  > "$mdir/today.log"          # truncated
sleep 3
printf 'after\n' >> "$mdir/today.log"
sleep 3
kill "$mirror_pid" 2>/dev/null
wait "$mirror_pid" 2>/dev/null
out="$(cat "$TMP/mirror.out")"
check_contains "first lines"  "[mt4] one"   "$out"
check_contains "appended line" "[mt4] three" "$out"
check_contains "after truncate" "[mt4] reset" "$out"
check_contains "kept following" "[mt4] after" "$out"
# Each line must appear once: a mirror that re-prints the file is noise, and one
# that skips lines is worse.
check_eq "no duplicate lines" "1" "$(printf '%s\n' "$out" | grep -c '^\[mt4\] two$')"
check_eq "line count" "5" "$(printf '%s\n' "$out" | grep -c '^\[mt4\] ')"

echo "healthcheck"
# A fake process with terminal.exe in its argv, so the check is exercised without
# MetaTrader. macOS and Linux pgrep both match the full command line.
if [ -x "$HEALTHCHECK" ]; then
  ( exec -a 'terminal.exe' sleep 30 ) &
  liveness_pid=$!
  sleep 1
  hexdir="$TMP/hex"; mkdir -p "$hexdir/MQL4/Files/Common/HEX-Logs"
  MT4DIR="$hexdir" "$HEALTHCHECK" >/dev/null 2>&1
  check_eq "no startup.ini -> unhealthy" "1" "$?"
  printf 'x\n' > "$hexdir/startup.ini"
  printf 'x\n' > "$hexdir/MQL4/Files/Common/HEX-Logs/equity.csv"
  MT4DIR="$hexdir" "$HEALTHCHECK" >/dev/null 2>&1
  check_eq "fresh heartbeat -> ok" "0" "$?"
  # 200 minutes old against a 180 minute limit.
  touch -t "$(date -v-200M +%Y%m%d%H%M 2>/dev/null || date -d '200 min ago' +%Y%m%d%H%M)" \
    "$hexdir/MQL4/Files/Common/HEX-Logs/equity.csv" 2>/dev/null
  MT4DIR="$hexdir" "$HEALTHCHECK" >/dev/null 2>&1
  check_eq "stale heartbeat -> unhealthy" "1" "$?"
  kill "$liveness_pid" 2>/dev/null
else
  bad "healthcheck.sh is not executable"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
