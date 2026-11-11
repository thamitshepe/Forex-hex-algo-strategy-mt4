#!/bin/bash
# Self-test for the pure parts of the MT5 deployment scripts.
#
# The container itself is the real test for everything that needs Wine, a
# display or a terminal (deploy/Dockerfile's ea-check stage compiles the EA on
# every build). What CI cannot see is the shell logic between those steps:
# whether the generated mt5.ini says what it claims, whether the volume guard
# claims and refuses as designed, whether the log mirror reports a line exactly
# once, and whether the healthcheck fails when it should. Those are pure
# functions, so they are tested here.
#
# Usage: deploy/scripts/selftest.sh     (exit 0 = all checks passed)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"
HEALTHCHECK="$HERE/healthcheck.sh"
COMPOSE="$HERE/../docker-compose.yml"
TMP="$(mktemp -d)"
PASS=0
FAIL=0
MOCK_PID=""
cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
check_contains() { # name needle haystack
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2])" ;; esac
}
check_not_contains() { # name needle haystack
  case "$3" in *"$2"*) bad "$1 (unexpected [$2])" ;; *) ok "$1" ;; esac
}

# Pull one function out of entrypoint.sh so it can be exercised without running
# the part that starts Wine.
load_fn() { # file name
  local body
  body="$(sed -n "/^$2() {/,/^}/p" "$1")"
  [ -n "$body" ] || { bad "could not extract $2 from $1"; return 1; }
  eval "$body"
}

# entrypoint.sh calls these. The selftest versions still say what happened:
# the tests assert on log's output (e.g. "re-claiming volume"), and die has to
# actually exit so a refusal propagates out of the command-substitution
# subshell the tests run functions in - the entrypoint's real die exits too.
log()  { printf '[log] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { echo "die: $*" >&2; exit 1; }

echo "mt5.ini"
# shellcheck disable=SC2034  # read by the extracted function
MT5DIR="$TMP/mt5"; MT5_LOGIN=41311895; MT5_PASSWORD=secret
MT5_SERVER=Deriv-Demo; MT5_SYMBOL="Volatility Boom 400 Index"; MT5_PERIOD=M15
MT5_EXPERT=HEX-BoomRider; MT5_PRESET=HEX-BoomRider; MT5_INSTANCE=1
mkdir -p "$MT5DIR"   # main() creates this in the real container
load_fn "$ENTRYPOINT" write_mt5_ini >/dev/null
write_mt5_ini >/dev/null 2>&1
ini="$TMP/mt5/mt5.ini"
if [ -f "$ini" ]; then
  ok "file written"
  check_contains "login"     "Login=41311895"          "$(cat "$ini")"
  check_contains "password"  "Password=secret"         "$(cat "$ini")"
  check_contains "server"    "Server=Deriv-Demo"       "$(cat "$ini")"
  check_contains "autotrading on at start"  "Enabled=1"           "$(cat "$ini")"
  check_contains "live trading allowed"     "AllowLiveTrading=1"  "$(cat "$ini")"
  check_contains "expert section"           "[StartUp]"           "$(cat "$ini")"
  check_contains "expert"    "Expert=HEX-BoomRider"                 "$(cat "$ini")"
  check_contains "preset"    "ExpertParameters=HEX-BoomRider.set"   "$(cat "$ini")"
  check_contains "symbol with spaces" "Symbol=Volatility Boom 400 Index" "$(cat "$ini")"
  check_contains "period"    "Period=M15"              "$(cat "$ini")"
  check_eq "no unexpanded \${}" "0" "$(grep -c '\\${' "$ini")"
  check_eq "password is 600" "600" "$(stat -c %a "$ini" 2>/dev/null || stat -f %Lp "$ini")"
else
  bad "file written"
fi

echo "mt5.ini without credentials (VNC-desktop first login path)"
MT5DIR="$TMP/mt5-noauth"; MT5_LOGIN=""; MT5_PASSWORD=""; MT5_SERVER=""
mkdir -p "$MT5DIR"
load_fn "$ENTRYPOINT" write_mt5_ini >/dev/null
out="$(write_mt5_ini 2>&1)"
ini2="$MT5DIR/mt5.ini"
if [ -f "$ini2" ]; then
  check_not_contains "no Login line is claimed" "Login=" "$(cat "$ini2")"
  check_contains "it warns about the login dialog" "MT5_LOGIN is empty" "$out"
  check_contains "and about the password" "MT5_PASSWORD is empty" "$out"
else
  bad "file written without credentials"
fi


echo "claim_volume: one container per volume, enforced"
MT5DIR="$TMP/vol"; MT5_INSTANCE=1; MT5_LOGIN=41311895; MT5_RECLAIM_VOLUME=""
mkdir -p "$MT5DIR"
load_fn "$ENTRYPOINT" claim_volume >/dev/null
claim_volume >/dev/null 2>&1
check_contains "fresh volume claimed with account" "1:41311895" "$(cat "$MT5DIR/.hex-instance")"
out="$(claim_volume 2>&1)"
check_contains "same owner is a no-op" "(ours)" "$out"
MT5_LOGIN=99999999
out="$(claim_volume 2>&1)" && rc=0 || rc=$?
check_eq "wrong account is refused" "1" "$rc"
check_contains "the refusal names both sides" "owned by '1:41311895'" "$out"
check_contains "and names the one-shot fix" "MT5_RECLAIM_VOLUME=1" "$out"
check_eq "and the marker is untouched" "1:41311895" "$(cat "$MT5DIR/.hex-instance")"
MT5_RECLAIM_VOLUME=1
out="$(claim_volume 2>&1)" && rc=0 || rc=$?
check_eq "reclaim flag moves the account on the same instance" "0" "$rc"
check_eq "marker re-owned" "1:99999999" "$(cat "$MT5DIR/.hex-instance")"
check_contains "and it says what it did" "re-claiming volume" "$out"
MT5_INSTANCE=2; MT5_LOGIN=41311895; MT5_RECLAIM_VOLUME=1
out="$(claim_volume 2>&1)" && rc=0 || rc=$?
check_eq "another instance is refused even with the flag" "1" "$rc"
check_eq "marker still names the true owner" "1:99999999" "$(cat "$MT5DIR/.hex-instance")"

echo "ensure_terminal: the distro is the only way a terminal appears"
MT5DIR="$TMP/vol2"; MT5_INSTANCE=1; MT5_LOGIN=41311895; MT5_FORCE_SEED=0; MT5_DISTRO_URL=""; MT5_SETUP_URL=""
mkdir -p "$MT5DIR"
load_fn "$ENTRYPOINT" have_terminal >/dev/null
load_fn "$ENTRYPOINT" seed_distro_from_url >/dev/null
load_fn "$ENTRYPOINT" install_fresh_terminal >/dev/null
load_fn "$ENTRYPOINT" ensure_terminal >/dev/null
out="$(ensure_terminal 2>&1)" && rc=0 || rc=$?
check_eq "no terminal and no source is fatal" "1" "$rc"
check_contains "and the fix is named" "MT5_DISTRO_URL" "$out"
mkdir -p "$TMP/src5/MQL5/Experts" "$TMP/src5/logs"
printf 'fake' > "$TMP/src5/terminal64.exe"
printf 'fake' > "$TMP/src5/metaeditor64.exe"
TAR="$TMP/distro.tar.gz"
tar -czf "$TAR" -C "$TMP/src5" terminal64.exe metaeditor64.exe MQL5 logs
MT5_DISTRO_URL="file://$TAR"
ensure_terminal >/dev/null 2>&1
check_eq "file:// distro seeds terminal64.exe" "1" \
  "$([ -f "$MT5DIR/terminal64.exe" ] && echo 1)"
check_contains "and records where it came from" "file://$TAR" "$(cat "$MT5DIR/.seeded-from")"

echo "ensure_terminal: the installer fallback"
# A fresh volume with only the installer URL: on a dev machine there is no
# wine, so the fallback must refuse with a sentence that names the fix - not
# half-download something. (The happy path runs in the container, where wine
# is installed; the install step itself needs a display and is CI's ea-check
# and the first boot's business.)
MT5DIR="$TMP/vol3"; MT5_INSTANCE=1; MT5_LOGIN=41311895; MT5_FORCE_SEED=0
MT5_DISTRO_URL=""
MT5_SETUP_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
mkdir -p "$MT5DIR"
out="$(ensure_terminal 2>&1)" && rc=0 || rc=$?
check_eq "installer fallback without wine is fatal here" "1" "$rc"
check_contains "and names the distro alternative" "MT5_DISTRO_URL" "$out"
# The URL in the compose default is the one that must be live: pin it.
check_contains "compose defaults the installer URL" \
  "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
  "$(cat "$COMPOSE")"

echo "healthcheck"
MT5DIR="$TMP/hc"
LOGDIR="$MT5DIR/MQL5/Files/HEX-Logs"
mkdir -p "$MT5DIR/logs" "$LOGDIR"
: > "$MT5DIR/mt5.ini"
if pgrep -f 'terminal64[.]exe' >/dev/null 2>&1; then
  date +%s > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
  out="$("$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
  check_eq "a fresh status line is healthy" "0" "$rc"
  check_contains "and says so" "EA status line" "$out"
  touch -t "$(date -v-4H +%Y%m%d%H%M 2>/dev/null || date -d '4 hours ago' +%Y%m%d%H%M)" \
    "$LOGDIR/HEX-BoomRider-heartbeat.txt"
  out="$("$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
  check_eq "a stale status line is unhealthy" "1" "$rc"
  check_contains "with the age in the sentence" "min old" "$out"
else
  printf '  skip process checks (no terminal64.exe process on a dev machine - they run in the container)\n'
fi
# Blown is NOT a failure: the strategy halting by design must not page. This
# path is testable without a live terminal by stubbing the process check.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/pgrep"
chmod +x "$TMP/bin/pgrep"
date +%s > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
: > "$LOGDIR/HEX-BoomRider-BLOWN.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" HEX_HEARTBEAT_MAX_AGE_MIN=180 bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "blown-but-alive reports healthy" "0" "$rc"
check_contains "and explains the halt" "by design" "$out"
rm -f "$LOGDIR/HEX-BoomRider-BLOWN.txt"

# An attached EA on a chart that is not being ticked traded nothing for six
# hours on 2026-11-02 while every other signal said "running". The beat now
# carries the age of the last tick, so the healthcheck can say which half is
# broken instead of calling a live EA detached.
echo "healthcheck: a live EA on a dead feed"
printf '2026.11.02 22:04:19|tick_age=12|equity=9994.29|trades=1\n' > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "a beating EA with live quotes is healthy" "0" "$rc"
check_contains "and reports the age of the last tick" "last tick 0 min ago" "$out"
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1\n' > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "a beating EA with a dead feed is unhealthy" "1" "$rc"
check_contains "and says how long nothing has quoted" "no quotes for 62 min" "$out"
check_contains "not that the EA is gone" "chart is not being ticked" "$out"
printf '2026.11.02 22:04:19|equity=9994.29|trades=1\n' > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "a beat from a build without tick_age is unknown, not a stall" "0" "$rc"
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1\n' > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" HEX_TICK_STALL_MIN=120 bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "the stall limit is a knob, not a constant" "0" "$rc"

# 2026-11-08: a symbol that is not subscribed receives NO quotes at all, so
# tick_age climbs for ever and every restart of the terminal is wasted. That is a
# different fault from "the feed stalled", and the beat now carries it.
echo "healthcheck: an unsubscribed symbol is not a stalled feed"
printf '2026.11.08 09:20:40|tick_age=660|equity=10000.00|trades=0|sel=0|spread=0\n' \
  > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "an unsubscribed symbol is unhealthy" "1" "$rc"
check_contains "and the sentence names the subscription, not the feed" "NOT SUBSCRIBED" "$out"
printf '2026.11.08 09:20:40|tick_age=3720|equity=10000.00|trades=0|sel=1|spread=12\n' \
  > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "a subscribed symbol with old quotes is still unhealthy" "1" "$rc"
check_contains "but then it blames the feed" "chart is not being ticked" "$out"
check_not_contains "and not the subscription" "NOT SUBSCRIBED" "$out"
printf '2026.11.08 09:20:40|tick_age=0|equity=10000.00|trades=0|sel=1|spread=12\n' \
  > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
out="$(PATH="$TMP/bin:$PATH" MT5DIR="$MT5DIR" bash "$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
check_eq "subscribed and ticking is healthy" "0" "$rc"


echo "the heartbeat's tick age, read the way the watchers read it"
HB="$TMP/heartbeat.txt"
load_fn "$ENTRYPOINT" hb_tick_age >/dev/null
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1\n' > "$HB"
check_eq "the age comes out of the beat" "3720" "$(hb_tick_age "$HB")"
printf '2026.11.02 22:04:19|tick_age=0|equity=9994.29|trades=1\n' > "$HB"
check_eq "a tick right now reads as 0, not as unknown" "0" "$(hb_tick_age "$HB")"
printf '2026.11.02 22:04:19|equity=9994.29|trades=1\n' > "$HB"
check_eq "an older beat has no age at all" "" "$(hb_tick_age "$HB")"
check_eq "and a missing file is not an error" "" "$(hb_tick_age "$TMP/nope.txt")"

# The same reader for the fields added later (sel, spread), so a new fact in the
# beat costs one call instead of a parser per fact.
load_fn "$ENTRYPOINT" hb_field >/dev/null
printf '2026.11.08 09:20:40|tick_age=660|equity=10000.00|trades=0|sel=0|spread=7\n' > "$HB"
check_eq "a field at the end of the beat reads out" "0" "$(hb_field "$HB" sel)"
check_eq "so does spread" "7" "$(hb_field "$HB" spread)"
check_eq "and one in the middle, whatever follows it" "660" "$(hb_field "$HB" tick_age)"
check_eq "a field this build does not write is unknown, not 0" "" "$(hb_field "$HB" nope)"
check_eq "a missing file is not an error either" "" "$(hb_field "$TMP/nope.txt" sel)"

# The decision, not just the parsing. ONE thing pushes about the robot stopping
# now, and it pushes when the STATE CHANGES: two watchers on two timers used to
# buzz about the same incident, and a refused order (which the EA logs on every
# tick) buzzed the phone every second. sleep/kill/hex_push are stubbed inside a
# subshell (the second `sleep` ends the loop), so no real process dies.
echo "alert_watcher: one alert per state change, and only one"
MT5DIR="$TMP/aw"
mkdir -p "$MT5DIR/MQL5/Files/HEX-Logs"
AW="$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-heartbeat.txt"
BLOWN="$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-BLOWN.txt"
ACTIONS="$TMP/aw-actions"
MT5_SYMBOL="Volatility Boom 400 Index"; TERMINAL_PID=999999
HEX_TICK_STALL_MIN=15; HEX_SILENCE_GRACE_MIN=0; HEX_ALERT_REPEAT_HOURS=6
for fn in file_mtime hb_tick_age hb_field alert_read_state alert_write_state \
          alert_what alert_facts alert_span alert_watcher; do
  load_fn "$ENTRYPOINT" "$fn" >/dev/null
done
aw_run() { # one or two loop passes, whatever the status line says
  ( i=0
    sleep() { case "${1:-}" in 60) i=$((i + 1)); [ "$i" -ge 2 ] && exit 0 ;; esac; return 0; }
    kill() { printf 'kill %s\n' "$1" >> "$ACTIONS"; }
    hex_push() { printf 'push %s|%s\n' "$1" "$2" >> "$ACTIONS"; }
    alert_watcher )
}
: > "$ACTIONS"
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1|sel=1|spread=7\n' > "$AW"
aw_run
check_eq "a stalled feed raises exactly ONE alert" "1" "$(grep -c '^push ' "$ACTIONS")"
check_contains "and it is titled OFFLINE" "push OFFLINE|" "$(cat "$ACTIONS")"
check_contains "naming the stall in minutes, not the fault it is not" \
  "has not ticked for 62 minutes" "$(cat "$ACTIONS")"
check_contains "with the figures that make it countable" "Equity 9994.29" "$(cat "$ACTIONS")"
check_contains "and what was done about it" "attempt 1/3" "$(cat "$ACTIONS")"
check_eq "and restarts the terminal once, by pid" "1" "$(grep -c '^kill 999999' "$ACTIONS")"
check_eq "and records the attempt on the volume" "1" \
  "$(grep -c '^1 ' "$MT5DIR/.hex-alert-tries")"
: > "$ACTIONS"
aw_run
check_eq "the next boot is not news: no second buzz" "0" "$(grep -c '^push ' "$ACTIONS")"
check_eq "yet the second attempt is still spent" "2" \
  "$(awk '{print $1}' "$MT5DIR/.hex-alert-tries")"
check_eq "and the terminal is restarted again" "1" "$(grep -c '^kill 999999' "$ACTIONS")"
: > "$ACTIONS"
printf '3 %s offline:no-ticks\n' "$(date +%s)" > "$MT5DIR/.hex-alert-tries"
aw_run
check_eq "after three restarts it stops restarting" "0" \
  "$(grep -c '^kill' "$ACTIONS" || true)"
check_contains "and asks for a human exactly once" "push NEEDS-YOU|" "$(cat "$ACTIONS")"
check_eq "recording that it asked, so it cannot ask again" "4" \
  "$(awk '{print $1}' "$MT5DIR/.hex-alert-tries")"
# The third attempt is still an attempt: it must not also page, or the operator
# gets an OFFLINE and a NEEDS-YOU for one pass.
: > "$ACTIONS"
printf '2 %s offline:no-ticks\n' "$(date +%s)" > "$MT5DIR/.hex-alert-tries"
aw_run
check_eq "the third attempt is spent quietly, with nothing new said" "0" \
  "$(grep -c '^push ' "$ACTIONS")"
check_not_contains "and does not page on top of the alert" "NEEDS-YOU" "$(cat "$ACTIONS")"
check_eq "while still restarting the terminal" "1" "$(grep -c '^kill 999999' "$ACTIONS")"
# ...and having said it, it does not say it again on the next pass or the next
# boot: "4" in the budget means "already told you".
: > "$ACTIONS"
printf '4 %s offline:no-ticks\n' "$(date +%s)" > "$MT5DIR/.hex-alert-tries"
aw_run
check_eq "and it does not repeat the escalation" "0" "$(grep -c '^push ' "$ACTIONS")"
check_eq "nor restart what it has already given up on" "0" \
  "$(grep -c '^kill' "$ACTIONS" || true)"
: > "$ACTIONS"
printf '2026.11.02 22:04:19|tick_age=5|equity=9994.29|trades=1|sel=1|spread=7\n' > "$AW"
aw_run
check_contains "a live feed says it is back, once" "push ONLINE|" "$(cat "$ACTIONS")"
check_contains "in a duration a human can read" "after less than a minute" \
  "$(cat "$ACTIONS")"
check_eq "and kills nothing" "0" "$(grep -c '^kill' "$ACTIONS" || true)"
check_eq "and forgets the incident's budget" "0" \
  "$([ -f "$MT5DIR/.hex-alert-tries" ] && echo 1 || echo 0)"
: > "$ACTIONS"; rm -f "$MT5DIR/.hex-alert" "$MT5DIR/.hex-alert-tries"
printf '2026.11.02 22:04:19|equity=9994.29|trades=1\n' > "$AW"
aw_run
check_eq "a beat from a build with no tick age is online, not a stall" "0" \
  "$(grep -c '^kill' "$ACTIONS" || true)"
: > "$ACTIONS"; rm -f "$MT5DIR/.hex-alert" "$MT5DIR/.hex-alert-tries"
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1|sel=0|spread=0\n' > "$AW"
aw_run
check_contains "an unsubscribed symbol is named, not blamed on the feed" \
  "not subscribed (SYMBOL_SELECT=0)" "$(cat "$ACTIONS")"
check_contains "and the container still tries the one thing it can" "attempt 1/3" \
  "$(cat "$ACTIONS")"
: > "$ACTIONS"; rm -f "$MT5DIR/.hex-alert" "$MT5DIR/.hex-alert-tries"
printf '2026.11.02 22:04:19|tick_age=3720|equity=9994.29|trades=1|sel=1|spread=7\n' > "$AW"
: > "$BLOWN"
aw_run
check_eq "a blown account is halted, not restarted into noise" "0" \
  "$(grep -c '^kill' "$ACTIONS" || true)"
check_eq "and nothing is pushed (the EA's own BLOWN row already did)" "0" \
  "$(grep -c '^push ' "$ACTIONS")"
rm -f "$BLOWN"

echo "ea_watchdog: it follows the journal the terminal writes, not the name that sorts last"
WLOGS="$TMP/ew-logs"; mkdir -p "$WLOGS"
ACTIONS="$TMP/ew-actions"
MT5_SYMBOL="Volatility Boom 400 Index"
NEWEST="$WLOGS/20261106.log"
printf '0\t03:40:41.000\tExperts\texpert HEX-BoomRider (Volatility Boom 400 Index,M15) loaded successfully\n' > "$NEWEST"
# A journal from another day whose NAME sorts last and which never grows again:
# picking the newest by name makes this the file under watch, and its silence is
# indistinguishable from a healthy evening.
printf '0\t03:30:00.000\tTerminal\tjournal from a distro baked on another day\n' > "$WLOGS/zz-20261105.log"
touch -t 200001010000 "$WLOGS/zz-20261105.log"
load_fn "$ENTRYPOINT" file_mtime >/dev/null
load_fn "$ENTRYPOINT" ea_watchdog >/dev/null
ew_run() {
  ( i=0
    sleep() {
      case "${1:-}" in
        5) i=$((i + 1))
           # the removal lands between two passes, the way a live journal does
           [ "$i" -eq 1 ] && printf '0\t03:53:50.142\tExperts\texpert HEX-BoomRider (Volatility Boom 400 Index,M15) removed\n' >> "$NEWEST"
           [ "$i" -ge 3 ] && exit 0
           ;;
      esac
      return 0
    }
    kill() { printf 'kill %s\n' "$1" >> "$ACTIONS"; }
    hex_push() { printf 'push %s\n' "$1" >> "$ACTIONS"; }
    mql_tail() { printf 'mql'; }
    TERMINAL_PID=4343
    ea_watchdog "$WLOGS" )
}
: > "$ACTIONS"
ew_run
check_eq "a removal in the journal the terminal is writing restarts the terminal" "1" \
  "$(grep -c '^kill 4343' "$ACTIONS")"
check_contains "and the restart is logged with the MQL5 line that caused it" \
  "MQL5 log:" "$(cat "$ENTRYPOINT")"
check_not_contains "the restart itself is not a page (the DEINIT row already was)" \
  'hex_push "EA-RESTART"' "$(cat "$ENTRYPOINT")"

echo "journal_hints: MetaQuotes' community login is not the broker login"
JH="$TMP/jh-logs"; mkdir -p "$JH"
MT5_SERVER=Deriv-Demo; MT5_LOGIN=41311895; MT5_INSTANCE=1
load_fn "$ENTRYPOINT" journal_hints >/dev/null
jh_run() { # DIR STATE
  ( i=0
    sleep() { i=$((i + 1)); [ "$i" -ge 2 ] && exit 0; }
    TMPDIR="$2"
    journal_hints "$1" )
}
printf '2\t03:38:26.115\tMQL5.community\tauthorization failed\n' > "$JH/20261106.log"
out="$(jh_run "$JH" "$TMP/jh-state-a" 2>&1)"
check_not_contains "a failed community login is NOT reported as a refused broker login" \
  "refused login" "$out"
check_eq "and it says nothing at all about it" "0" \
  "$(printf '%s' "$out" | grep -c . || true)"
printf "2\t03:38:30.000\tNetwork\t'41311895': authorization failed\n" >> "$JH/20261106.log"
out="$(jh_run "$JH" "$TMP/jh-state-b" 2>&1)"
check_contains "a broker refusal that names the account still gets the hint" \
  "refused login" "$out"

echo "hex_push: a boot loop cannot burn the topic's quota"
MT5DIR="$TMP/push"; mkdir -p "$MT5DIR"
MT5_NOTIFY_URL="https://ntfy.sh/hex-test"
SENT="$TMP/push-sent"; : > "$SENT"
load_fn "$ENTRYPOINT" hex_push >/dev/null
hp_run() { # TITLE
  ( curl() { printf '%s\n' "$*" >> "$SENT"; echo 200; }
    hex_push "$1" "body" )
}
hp_run UP   >/dev/null
hp_run UP   >/dev/null
check_eq "the same status title twice in one window goes out once" "1" \
  "$(wc -l < "$SENT" | tr -d ' ')"
out="$(hp_run UP 2>&1)"
check_contains "and the hold says why it is not spending the quota" "push held" "$out"
hp_run BUY   >/dev/null
hp_run CLOSE >/dev/null
check_eq "a BUY and a CLOSE are never held" "3" "$(wc -l < "$SENT" | tr -d ' ')"
hp_run DIFFERENT-TITLE >/dev/null
check_eq "a different title has its own window" "4" "$(wc -l < "$SENT" | tr -d ' ')"


echo "push_once_shape: one buzz per fault, not one per tick"
MT5DIR="$TMP/shape"; mkdir -p "$MT5DIR"
SHAPE_SENT="$TMP/shape-sent"; : > "$SHAPE_SENT"
load_fn "$ENTRYPOINT" push_once_shape >/dev/null
hex_push() { printf '%s\n' "$2" >> "$SHAPE_SENT"; }
ps_run() { push_once_shape "ERROR" "$1" >/dev/null; }
ps_run '2026.11.08 09:20:40,ERROR,Volatility Boom 400 Index,9980.15,stop move #1 -> 100.10 refused: 10016 Invalid stops'
ps_run '2026.11.08 09:20:41,ERROR,Volatility Boom 400 Index,9980.16,stop move #2 -> 100.20 refused: 10016 Invalid stops'
check_eq "the same refusal twice (the figures move) buzzes once" "1" \
  "$(wc -l < "$SHAPE_SENT" | tr -d ' ')"
ps_run '2026.11.08 09:20:42,ERROR,Volatility Boom 400 Index,9980.17,buy failed: 10018 Market closed'
check_eq "a different fault is its own buzz" "2" "$(wc -l < "$SHAPE_SENT" | tr -d ' ')"
check_eq "and the stamps live on the volume, so a restart does not replay them" "1" \
  "$([ -d "$MT5DIR/.hex-seen" ] && echo 1 || echo 0)"
echo "boot loop: a container that dies in ten seconds still rings the phone once"
# The one fault alert_watcher cannot see: its first pass is a minute away, and a
# boot is not a state change (so a boot loop is deliberately quiet). The starts
# themselves are the evidence, and they are on the volume, together with the
# terminal's last words - which is why those are copied out of /tmp on the way.
MT5DIR="$TMP/boot"; mkdir -p "$MT5DIR"
BOOT_SENT="$TMP/boot-sent"; : > "$BOOT_SENT"
HEX_CRASHLOOP_BOOTS=3; HEX_CRASHLOOP_WINDOW_MIN=10; HEX_ALERT_REPEAT_HOURS=6
load_fn "$ENTRYPOINT" push_once_shape >/dev/null
load_fn "$ENTRYPOINT" boot_guard >/dev/null
hex_push() { printf '%s|%s\n' "$1" "$2" >> "$BOOT_SENT"; }
bg_run() { boot_guard >/dev/null; }
bg_run
check_eq "one start is a start, not a loop" "0" "$(grep -c '^CRASHLOOP|' "$BOOT_SENT" || true)"
printf 'the container was up 10s and exited rc=1\n  [term] err:module:import_dll Library not found\n' \
  > "$MT5DIR/.hex-last-death"
bg_run
bg_run
check_eq "three starts inside the window are ONE push" "1" \
  "$(grep -c '^CRASHLOOP|' "$BOOT_SENT" || true)"
check_contains "that says how many starts, and why" \
  "3 starts in 10 minutes" "$(cat "$BOOT_SENT")"
check_contains "and quotes the terminal's own last words" \
  "Library not found" "$(cat "$BOOT_SENT")"
bg_run
check_eq "a fourth start does not repeat it inside the window" "1" \
  "$(grep -c '^CRASHLOOP|' "$BOOT_SENT" || true)"
: > "$MT5DIR/.hex-boots"; rm -rf "$MT5DIR/.hex-seen"; : > "$BOOT_SENT"
for _ in 1 2 3; do printf '%s\n' $(( $(date +%s) - 7200 )) >> "$MT5DIR/.hex-boots"; done
bg_run
check_eq "starts from hours ago are not a loop" "0" \
  "$(grep -c '^CRASHLOOP|' "$BOOT_SENT" || true)"
check_eq "and the list of starts stays bounded" "4" \
  "$(wc -l < "$MT5DIR/.hex-boots" | tr -d ' ')"

echo "the terminal, not the wine launcher, decides when the container stops"
# `wait $TERMINAL_PID` waits on what the shell started - `wine terminal64.exe` -
# and wine can hand the work to wine64/terminal64 and exit while the terminal is
# still painting. Tearing the desktop down there kills a live terminal: a
# container that restarts every ten seconds and never trades.
load_fn "$ENTRYPOINT" wait_terminal_gone >/dev/null
FOLLOW_N="$TMP/follow"; printf '0' > "$FOLLOW_N"
WAITLOG="$TMP/wait.log"
TERMINAL_PID=999999        # not a child, so `wait` returns at once, like a launcher
sleep() { :; }             # the follow loop's tick, without the ten real seconds
terminal_up() {            # "still up" twice, then gone
  local n
  n=$(( $(cat "$FOLLOW_N") + 1 ))
  printf '%s' "$n" > "$FOLLOW_N"
  [ "$n" -le 2 ] && { printf '1234'; return 0; }
  return 1
}
wait_terminal_gone > "$WAITLOG" 2>&1
unset -f sleep terminal_up
check_contains "a launcher that exits under a live terminal is not the terminal dying" \
  "following the terminal, not the launcher" "$(cat "$WAITLOG")"
check_contains "and the container only stops once terminal64.exe is gone" \
  "terminal64.exe is gone" "$(cat "$WAITLOG")"
check_eq "with the launcher's own status recorded" "127" "$TERMINAL_RC"
check_contains "the check is a live pid, and a zombie tini has not reaped is not one" \
  "Z*) continue" "$(cat "$ENTRYPOINT")"

echo "the terminal's last words survive the restart"
MT5DIR="$TMP/death"; mkdir -p "$MT5DIR/logs" "$MT5DIR/MQL5/Logs"
TERM_LOG="$TMP/death-term.out"
printf 'wine: cannot find L"terminal64.exe"\n' > "$TERM_LOG"
printf '0  09:00:00  Experts  terminal64.exe: 0 bytes\n' > "$MT5DIR/logs/20261108.log"
load_fn "$ENTRYPOINT" terminal_evidence >/dev/null
load_fn "$ENTRYPOINT" openbox_log_tail >/dev/null
load_fn "$ENTRYPOINT" write_death_note >/dev/null
write_death_note 1 10 >/dev/null 2>&1
check_contains "the death note is on the volume, where the next boot reads it" \
  "cannot find" "$(cat "$MT5DIR/.hex-last-death")"
check_contains "with the exit code and how long it lived" "up 10s and exited rc=1" \
  "$(cat "$MT5DIR/.hex-last-death")"
check_contains "and the terminal's own journal is quoted with it" "0 bytes" \
  "$(cat "$MT5DIR/.hex-last-death")"
check_contains "the loop threshold is configurable, and the compose file sets it" \
  "HEX_CRASHLOOP_BOOTS" "$(cat "$COMPOSE")"


echo "main: the way out says why, and cannot die before saying it"
# The tail of main is the one place a `set -e` landmine is fatal: `[ -n "$X" ] &&
# kill "$X"` returns 1 when VNC is off, and the shell then exits BEFORE `exit $rc`
# - a container that stops without a line saying why. Everything main touches is
# stubbed inside a subshell, so this is the SEQUENCE, not Wine.
MT5DIR="$TMP/main"; mkdir -p "$MT5DIR"
TERM_LOG="$TMP/main-term.out"; printf 'wine: crashed in style\n' > "$TERM_LOG"
BOOT_EPOCH=$(( $(date +%s) - 42 ))
MAINLOG="$TMP/main.log"
load_fn "$ENTRYPOINT" terminal_evidence >/dev/null
load_fn "$ENTRYPOINT" write_death_note >/dev/null
load_fn "$ENTRYPOINT" main >/dev/null
(
  X11VNC_PID=""; WEBSOCKIFY_PID=""; WM_PID=""; XVFB_PID=""; TERMINAL_PID=4242
  check_instance_env() { :; }; banner() { :; }; claim_volume() { :; }; write_lease() { :; }
  boot_guard() { :; }; start_desktop() { :; }; ensure_terminal() { :; }
  repair_symbol_bases() { :; }; sync_ea() { :; }; compile_ea() { :; }
  ensure_single_chart() { :; }; write_mt5_ini() { :; }; launch_terminal() { :; }
  wait_for_terminal() { :; }; report_isolation() { :; }; lease_keeper() { :; }
  mirror_dir() { :; }; journal_hints() { :; }; ea_watchdog() { :; }
  desktop_keeper() { :; }; push_watcher() { :; }; alert_watcher() { :; }
  hex_push() { :; }
  wait_terminal_gone() { TERMINAL_RC=7; }   # the terminal died, rc 7
  main
) > "$MAINLOG" 2>&1
main_rc=$?
check_eq "the container leaves with the terminal's own status" "7" "$main_rc"
check_contains "and says so, with how long it lived" \
  "terminal64.exe exited (rc=7) after 4" "$(cat "$MAINLOG")"
check_contains "with the evidence printed before it goes" "[term]" "$(cat "$MAINLOG")"
check_contains "and left on the volume for the boot after it" \
  "crashed in style" "$(cat "$MT5DIR/.hex-last-death")"

echo "alert_watcher: a container that has only just booted is not an incident"
MT5DIR="$TMP/aw2"
mkdir -p "$MT5DIR/MQL5/Files/HEX-Logs"
SW="$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-heartbeat.txt"
ACTIONS="$TMP/aw2-actions"
MT5_SYMBOL="Volatility Boom 400 Index"; TERMINAL_PID=4242
HEX_SILENCE_MIN=20; HEX_SILENCE_GRACE_MIN=10; HEX_ALERT_REPEAT_HOURS=6
: > "$ACTIONS"
aw_run
check_eq "a volume that has never had a status line gets a grace period" "0" \
  "$(wc -l < "$ACTIONS" | tr -d ' ')"
# The container this watcher killed leaves the previous run's status line behind:
# four hours old, and it is not this run's news.
printf '2026.11.02 21:54:49|tick_age=0|equity=9998.25|trades=0|sel=1|spread=9\n' > "$SW"
touch -t "$(date -v-4H +%Y%m%d%H%M 2>/dev/null || date -d '4 hours ago' +%Y%m%d%H%M)" "$SW"
: > "$ACTIONS"
aw_run
check_eq "an old status line inside the grace window restarts nothing" "0" \
  "$(grep -c '^kill' "$ACTIONS" || true)"
HEX_SILENCE_GRACE_MIN=0
aw_run
check_contains "past the grace period the silence is ONE alert" "push OFFLINE|" \
  "$(cat "$ACTIONS")"
check_contains "and it blames the expert, not the feed" "the expert is not on the chart" \
  "$(cat "$ACTIONS")"
check_eq "with the restart that puts it back" "1" "$(grep -c '^kill 4242' "$ACTIONS")"
check_eq "and the budget on the volume, not in memory" "1" \
  "$(grep -c '^1 ' "$MT5DIR/.hex-alert-tries")"

echo "one alert: the state is one value, so the phone hears about it once"
check_contains "the state lives on the volume as <state>|<epoch>" \
  'statef="$MT5DIR/.hex-alert"' "$(cat "$ENTRYPOINT")"
check_contains "and reading it back is its own function" "alert_read_state()" \
  "$(cat "$ENTRYPOINT")"
check_contains "an unchanged state pushes nothing until the reminder window" \
  'STILL-OFFLINE' "$(cat "$ENTRYPOINT")"
check_contains "the reminder window is configurable, and 0 means never" \
  'HEX_ALERT_REPEAT_HOURS' "$(cat "$ENTRYPOINT")"
check_contains "a repeated EA message is deduped by shape before it is pushed" \
  'push_once_shape "ERROR"' "$(cat "$ENTRYPOINT")"
check_contains "and the same is true of the SKIPs a stalled entry produces" \
  'push_once_shape "SKIP"' "$(cat "$ENTRYPOINT")"
check_not_contains "the two watchers that buzzed on their own timers are gone" \
  "feed_watchdog() {" "$(cat "$ENTRYPOINT")"
check_not_contains "and so is the second one" "silence_watcher() {" "$(cat "$ENTRYPOINT")"


echo "one chart: the desktop MT5 saved is cleared before every start"
# MT5 restores the charts it saved on exit and THEN applies [StartUp], so every
# restart adds one. 2026-11-08: the noVNC desktop carried several charts, each one
# reloading its own copy of the expert on the same magic number, and the tab froze.
EA="$HERE/../../MQL5/Experts/HEX-BoomRider.mq5"
CH="$TMP/chart-vol"
mkdir -p "$CH/profiles/default" "$CH/profiles/Charts"
: > "$CH/profiles/default/chart01.chr"
: > "$CH/profiles/default/chart02.chr"
: > "$CH/profiles/default/chart03.chr"
: > "$CH/profiles/default/window.ini"
: > "$CH/profiles/Charts/chart01.chr"
MT5DIR="$CH"; MT5_SYMBOL="Volatility Boom 400 Index"
load_fn "$ENTRYPOINT" ensure_single_chart >/dev/null
out="$(ensure_single_chart 2>&1)"
check_eq "every saved chart is gone" "0" \
  "$(find "$CH/profiles" -type f -name 'chart*.chr' 2>/dev/null | wc -l | tr -d ' ')"
check_contains "and the log says how many" "cleared 4 saved chart(s)" "$out"
check_contains "and where they were" "default:3" "$out"
check_eq "the window layout, which has no expert in it, is left alone" "1" \
  "$(find "$CH/profiles" -type f -name 'window.ini' 2>/dev/null | wc -l | tr -d ' ')"
check_eq "the profile as it arrived is kept once" "4" \
  "$(find "$CH/.profile-orig" -type f -name 'chart*.chr' 2>/dev/null | wc -l | tr -d ' ')"
out="$(ensure_single_chart 2>&1)"
check_contains "a second boot finds nothing to clear" "carries no saved chart" "$out"
check_eq "and does not touch the kept copy" "4" \
  "$(find "$CH/.profile-orig" -type f -name 'chart*.chr' 2>/dev/null | wc -l | tr -d ' ')"
MT5DIR="$TMP/empty-vol"; mkdir -p "$MT5DIR"
out="$(ensure_single_chart 2>&1)"
check_contains "a volume with no profile yet is not an error" "no desktop profile" "$out"

esc_call="$(grep -n '^  ensure_single_chart$' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
launch_call="$(grep -n '^  launch_terminal$' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
check_eq "the profile is cleared before the terminal is launched" "1" \
  "$([ -n "$esc_call" ] && [ -n "$launch_call" ] && [ "$esc_call" -lt "$launch_call" ] && echo 1 || echo 0)"
check_contains "the EA is the second lock: it refuses a duplicate chart" \
  "bool ClaimChart()" "$(cat "$EA")"
check_contains "and a live second copy is a failed init, not a silent twin" \
  'return(INIT_FAILED);' "$(cat "$EA")"
check_contains "the claim is refreshed from the timer" "RefreshClaim();" "$(cat "$EA")"
check_contains "and the owner recognises itself despite the double store" \
  "bool ClaimOwnerIs(const long id)" "$(cat "$EA")"
check_contains "and handed back when the EA leaves" \
  'GlobalVariableSet(ClaimKey() + "-seen", 0)' "$(cat "$EA")"

echo "a desktop with no window manager is why the noVNC tab froze"
# openbox exits at once if Xvfb is not accepting clients yet; a desktop with no WM
# draws the charts and cannot be clicked. And two WMs on one display is the same
# freeze from the other side, so the keeper adopts instead of double-starting.
# (What "Xvfb is accepting clients" means is the next block's question.)
check_contains "a WM that died within a second is reported, with its own log" \
  "openbox did not stay up" "$(cat "$ENTRYPOINT")"
check_contains "and that log is printed" '[openbox]' "$(cat "$ENTRYPOINT")"
check_contains "liveness is a pid, not only a name match" "kill -0 \"\$WM_PID\"" "$(cat "$ENTRYPOINT")"
check_contains "the keeper adopts an openbox it did not start" "wm_alive" "$(cat "$ENTRYPOINT")"
check_not_contains "so it can no longer start a second WM" \
  "if ! pgrep -x openbox" "$(cat "$ENTRYPOINT")"
# A dead X display is the one fault that makes a healthy terminal exit a second
# after it starts: openbox says "Failed to open the display", MT5 cannot draw,
# and it is gone. Restarting Xvfb there would pull the display out from under a
# live terminal, so the keeper names it instead.
check_contains "a dead Xvfb is named as the fault, not silently tolerated" \
  "Xvfb is gone" "$(cat "$ENTRYPOINT")"
check_contains "and it is not relaunched under a terminal that is using it" \
  "not relaunched under a live terminal" "$(cat "$ENTRYPOINT")"

echo "a socket file is not a display"
# 2026-11-11: `[ -S /tmp/.X11-unix/X99 ]` was true on every boot - the socket
# outlives the killed server - so 'virtual desktop: Xvfb on :99' was printed over
# a display nobody served, openbox said "Failed to open the display", and MT5 died
# a second after it started, forever. The display is now judged by a client.
SD="$(sed -n '/^start_desktop() {/,/^}/p' "$ENTRYPOINT")"
check_contains "the desktop waits for a client, not for the socket file" \
  "while ! display_up" "$SD"
check_eq "and starts the WM only after that probe" "1" \
  "$([ "$(printf '%s' "$SD" | grep -n 'while ! display_up' | cut -d: -f1)" \
      -lt "$(printf '%s' "$SD" | grep -n 'start_wm || true' | cut -d: -f1)" ] && echo 1 || echo 0)"
check_contains "when it never comes up, that IS the sentence, with Xvfb's own log" \
  "Xvfb never came up on" "$SD"
check_contains "and the socket path is still what a stale display is recognised by" \
  'X11-unix/X${DISPLAY#:}' "$(cat "$ENTRYPOINT")"
check_contains "the probe uses a client that is actually in the image" \
  "xdotool getdisplaygeometry" "$(cat "$ENTRYPOINT")"
check_contains "the lock a killed container leaves is cleared" \
  'X${DISPLAY#:}-lock' "$(cat "$ENTRYPOINT")"
check_contains "but never under a server that is still serving" \
  'if pgrep -x Xvfb >/dev/null 2>&1 || display_up; then' "$(cat "$ENTRYPOINT")"
check_contains "the keeper will not put a WM back onto a dead display" \
  'if ! display_up; then' "$(cat "$ENTRYPOINT")"

load_fn "$ENTRYPOINT" display_up >/dev/null
load_fn "$ENTRYPOINT" x_clear_stale_display >/dev/null
DISPLAY=":77"; XVFB_PID=""
mkdir -p /tmp/.X11-unix
rm -f /tmp/.X11-unix/X77 /tmp/.X77-lock
# A real unix socket, exactly the kind Xvfb leaves behind when it is killed.
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' /tmp/.X11-unix/X77
printf '4242\n' > /tmp/.X77-lock
if display_up; then
  bad "a socket with no server must not read as a display"
else
  ok "a socket with no server is not a display"
fi
out="$(x_clear_stale_display 2>&1)"
check_contains "a display left behind by a killed container is cleared" \
  "cleared a stale :77" "$out"
check_eq "and both files go with it" "no" \
  "$([ -e /tmp/.X11-unix/X77 ] && echo yes || echo no)"
# ...but adopting a live server is the keeper's rule, so a live Xvfb keeps it.
printf '4242\n' > /tmp/.X77-lock
out="$( ( pgrep() { return 0; }; x_clear_stale_display ) 2>&1)"
check_eq "a live Xvfb keeps its display" "yes" \
  "$([ -e /tmp/.X77-lock ] && echo yes || echo no)"
check_eq "and nothing is said about clearing it" "0" \
  "$(printf '%s' "$out" | grep -c 'cleared a stale' || true)"
rm -f /tmp/.X11-unix/X77 /tmp/.X77-lock

echo "openbox's menu complaint is not the reason it exited"
OPENBOX_LOG="$TMP/openbox.log"
printf '%s\n' \
  'Openbox-Message: Unable to find a valid menu file "/var/lib/openbox/debian-menu.xml"' \
  'Openbox-Message: Failed to open the display from the DISPLAY environment variable.' \
  'Openbox-Message: Unable to find a valid menu file "/var/lib/openbox/debian-menu.xml"' \
  > "$OPENBOX_LOG"
out="$(OPENBOX_LOG="$OPENBOX_LOG"; load_fn "$ENTRYPOINT" openbox_log_tail >/dev/null; openbox_log_tail 8 2>&1)"
check_contains "the reason is printed" \
  "Failed to open the display from the DISPLAY environment variable" "$out"
check_eq "the menu noise is not" "0" \
  "$(printf '%s\n' "$out" | grep -c 'Unable to find a valid menu file')"
check_contains "and it is named, not silently dropped" "harmless" "$out"

echo "the wine launcher is not the terminal"
load_fn "$ENTRYPOINT" terminal_pid >/dev/null
check_eq "the launcher's own pid is skipped" "222" \
  "$( ( TERMINAL_PID=111; pgrep() { printf '111\n222\n'; }; terminal_pid ) )"
check_eq "with only the launcher there is no terminal yet" "1" \
  "$( ( TERMINAL_PID=111; pgrep() { printf '111\n'; }; terminal_pid >/dev/null; echo $? ) )"
check_contains "so the poll says which pid it found, and never calls the launcher 'up'" \
  "not calling that 'up'" "$(cat "$ENTRYPOINT")"

echo "a run that is killed says so"
EP="$(cat "$ENTRYPOINT")"
check_contains "SIGTERM is trapped and named" "trap 'on_signal SIGTERM 143' TERM" "$EP"
check_contains "so a stop from outside reads as a stop from outside" \
  "the container is being stopped from outside" "$EP"
check_contains "an exit main did not write is named too, whatever it was" \
  "trap 'say_bye \$?'  EXIT" "$EP"
check_contains "and it leaves the death note for the boot after it" \
  'write_death_note "$rc" "$up"' "$EP"
check_contains "a deliberate exit is not reported as a kill" 'SAID_BYE=1' "$EP"
check_contains "the FATAL path counts as deliberate" \
  'die()  { printf' "$EP"
# ...and the traps do it, exercised for real rather than grepped: a SIGTERM, a
# `set -e` death (the silent way out), and a deliberate exit that must stay quiet.
TRAPS="$TMP/traps.sh"
sed -n '/^SAID_BYE=""/,/^trap .on_signal SIGHUP 129.  HUP$/p' "$ENTRYPOINT" > "$TRAPS"
check_contains "the trap block is what the entrypoint runs" \
  "trap 'say_bye \$?'  EXIT" "$(cat "$TRAPS")"
KD="$TMP/killed"; mkdir -p "$KD"
# shellcheck disable=SC2016  # the ${1..} and $(..) belong to the probe script
probe_script() { # NAME BODY
  cat > "$TMP/$1.sh" <<EOF
log() { printf '[log] %s\n' "\$*"; }
MT5DIR='$KD'
BOOT_EPOCH=\$(( \$(date +%s) - 3 ))
write_death_note() { printf 'note rc=%s up=%s\n' "\$1" "\$2" > "\$MT5DIR/.hex-last-death"; }
. '$TRAPS'
$2
EOF
}
probe_script sigterm ': > "'"$KD"'/ready"; while :; do sleep 1; done'
# The signal has to reach THE SHELL THAT SOURCED THE TRAPS, so the background job
# is that shell itself and not a wrapper around it.
"$BASH" "$TMP/sigterm.sh" > "$TMP/sigterm.out" 2>&1 &
sig_pid=$!
n=0
while [ ! -f "$KD/ready" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
kill -TERM "$sig_pid" 2>/dev/null
wait "$sig_pid" 2>/dev/null; sig_rc=$?
kill "$sig_pid" 2>/dev/null || true
check_eq "a SIGTERM leaves with the signal's own status" "143" "$sig_rc"
check_contains "and says it was a stop from outside" \
  "SIGTERM received" "$(cat "$TMP/sigterm.out")"
check_contains "and that this run did not reach its shutdown" \
  "ended without reaching its shutdown (rc=143)" "$(cat "$TMP/sigterm.out")"
check_contains "and the death note the next boot quotes says so too" \
  "note rc=143" "$(cat "$KD/.hex-last-death")"
probe_script seterr 'set -e
false
log unreachable'
"$BASH" "$TMP/seterr.sh" > "$TMP/sete.out" 2>&1; set_rc=$?
check_eq "a set -e death keeps its status" "1" "$set_rc"
check_contains "and is named instead of being silent" \
  "ended without reaching its shutdown (rc=1)" "$(cat "$TMP/sete.out")"
check_eq "the line after the failure never ran" "0" \
  "$(grep -c unreachable "$TMP/sete.out" || true)"
probe_script deliberate 'log "terminal64.exe exited (rc=7) after 7s - stopping the container"
SAID_BYE=1
exit 7'
"$BASH" "$TMP/deliberate.sh" > "$TMP/bye.out" 2>&1; bye_rc=$?
check_eq "a deliberate exit keeps the terminal's status" "7" "$bye_rc"
check_eq "and is not reported as a kill" "0" \
  "$(grep -c 'ended without reaching' "$TMP/bye.out" || true)"

echo "a chart that cannot be ticked says which of the two faults it is"
check_contains "the EA asks the server for its symbol list" 'SymbolsTotal(false)' "$(cat "$EA")"
check_contains "and says so when the name is not on it" \
  "is NOT in the server's symbol list" "$(cat "$EA")"
check_contains "naming the names that do exist" 'SimilarSymbols("Boom", 400)' "$(cat "$EA")"
check_contains "an unselected symbol is selected, not just reported" \
  'SymbolSelect(_Symbol, true)' "$(cat "$EA")"
check_contains "a symbol disabled for trading is named too" \
  "SYMBOL_TRADE_MODE_DISABLED" "$(cat "$EA")"
check_contains "the last quote the terminal knows about is logged" \
  "string LastQuoteTime()" "$(cat "$EA")"
check_contains "the beat carries the subscription state" '|sel=%d' "$(cat "$EA")"
check_contains "and the spread" '|spread=%d' "$(cat "$EA")"
check_contains "a stall retries the subscription" "void RetrySubscribe()" "$(cat "$EA")"
check_contains "and folds a name fault written late, not never" \
  "symbolNameReported" "$(cat "$EA")"
check_contains "the watchdog repeats the subscription state in its push" \
  'hb_field "$hb" sel' "$(cat "$ENTRYPOINT")"
check_contains "and the healthcheck fails on it" "NOT SUBSCRIBED" "$(cat "$HEALTHCHECK")"

echo "compose file"
# The compose file is what Dokploy runs, so what it resolves into is checked,
# not assumed: exactly one service, on its own volume, speaking only MT5.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  out="$(docker compose -f "$COMPOSE" config 2>/dev/null)"
  rc=$?
  check_eq "docker compose accepts the file" "0" "$rc"
  check_eq "and resolves it into exactly one service" "1" \
    "$(printf '%s\n' "$out" | grep -cE '^  (mt5-boom|mt4|mt4-doge):$')"
  check_contains "the service is mt5-boom" "mt5-boom" "$out"
  check_contains "on its own fresh volume" "hex-mt5-boom-data" "$out"
  check_not_contains "no MT4 variable reaches the container" "MT4_" "$out"
  check_contains "the account's Boom symbol is the default" "Volatility Boom 400 Index" "$out"
  check_contains "the EA the image ships is attached" "HEX-BoomRider" "$out"
  check_contains "the port a domain proxies to" '6080' "$out"
  check_contains "the dead-feed limit reaches the container" "HEX_TICK_STALL_MIN" "$out"
  check_contains "and the silence limit, which restarts the terminal" "HEX_SILENCE_MIN" "$out"
  check_contains "and the phone-side push window" "HEX_PUSH_REPEAT_SEC" "$out"
else
  printf '  skip docker compose (not installed)\n'
fi

echo "no MT4 leftovers in what ships"
check_eq "entrypoint speaks no MT4_ variables" "0" \
  "$(grep -c 'MT4_' "$ENTRYPOINT" || true)"
check_eq "compose speaks no MT4_ variables" "0" \
  "$(grep -c 'MT4_' "$COMPOSE" || true)"
check_contains "healthcheck watches terminal64" "terminal64" "$(cat "$HEALTHCHECK")"
wf="$HERE/../../.github/workflows/deploy.yml"
check_contains "workflow builds the MT5 image" "forex-hex-mt5" "$(cat "$wf")"
check_not_contains "workflow assigns no account password" "MT5_PASSWORD=" "$(cat "$wf")"
check_not_contains "workflow references no password secret" "secrets.MT5" "$(cat "$wf")"
check_not_contains "workflow assigns no account login" "MT5_LOGIN=" "$(cat "$wf")"

echo "an EA that vanishes is seen, explained and put back"
# The 2026-11-02 removal left no trace in the journal beyond one bare line - the
# reason lives in the Experts (MQL5) log, which nothing mirrored.
check_contains "the Experts (MQL5) log is mirrored, not just the journal" \
  'mirror_dir "MQL5" "$MT5DIR/MQL5/Logs" nocsv' "$(cat "$ENTRYPOINT")"
check_contains "the watchdog knows a bare removal, not only a sync timeout" \
  "'expert '*removed*" "$(cat "$ENTRYPOINT")"
check_contains "and the push carries the MQL5 line that caused it" \
  "MQL5 log:" "$(cat "$ENTRYPOINT")"
check_contains "a SKIP is pushed once per reason, not on every tick" \
  'push_once_shape "SKIP"' "$(cat "$ENTRYPOINT")"
# 2026-11-06: the journal had the removal line and the container still never
# restarted, so both halves of "put it back" are checked, not just the push.
check_contains "a stale beat spends a restart budget on the volume" \
  ".hex-alert-tries" "$(cat "$ENTRYPOINT")"
check_contains "the journal under watch is chosen by mtime, not by name" \
  'file_mtime "$cur"' "$(cat "$ENTRYPOINT")"


echo "the EA carries the bankroll rule"
EA="$HERE/../../MQL5/Experts/HEX-BoomRider.mq5"
SET="$HERE/../../MQL5/Presets/HEX-BoomRider.set"
if [ -f "$EA" ]; then
  check_contains "blow line defaults to 9980 (\$20 of headroom)" \
    "InpBaselineEquity = 9980.0" "$(cat "$EA")"
  check_contains "effective bankroll is equity - baseline" "equity - InpBaselineEquity" "$(cat "$EA")"
  check_contains "the blow alert pushes to the phone" "SendNotification" "$(cat "$EA")"
  check_contains "and writes a marker so the halt survives restarts" "BlownMarkerExists" "$(cat "$EA")"
  check_contains "no entry is priced off a one-sided or missing quote" \
    "ask <= 0.0 || bid <= 0.0" "$(cat "$EA")"
  # The $20 unit of risk is what the bracket was chosen against: a 0.30% stop on
  # a 0.10 lot costs ~$4.54, so four losses fit the headroom, and the 50% cap
  # ($10) admits that minimum lot with 2.2x of margin. A cap the minimum lot
  # cannot satisfy refuses every entry forever (the loop of 2026-11-02).
  check_contains "the min-lot cap admits the broker's 0.10 minimum with margin" \
    "InpMaxRiskPct     = 50.0" "$(cat "$EA")"
  check_contains "and the bracket breaks even below 60%" \
    "InpTakeProfitPct  = 0.25" "$(cat "$EA")"
  check_contains "with a stop four losses can absorb" \
    "InpStopLossPct    = 0.30" "$(cat "$EA")"
  # A 0.30% stop is ~45 points; the broker can refuse anything tighter than its
  # stops level, and this EA has never placed an order yet, so log the floor and
  # widen rather than fail the first entry.
  check_contains "the broker's own stops level is logged at init" \
    "SYMBOL_TRADE_STOPS_LEVEL" "$(cat "$EA")"
  check_contains "and a bracket tighter than it is widened, not failed" \
    "double stopsDist = (double)SymbolInfoInteger" "$(cat "$EA")"
  check_eq "preset exists beside it" "1" \
    "$([ -f "$SET" ] && echo 1)"
  # EA default and preset have to agree, or the preset silently wins.
  for kv in "InpBaselineEquity=9980.0" "InpRiskPct=20.0" "InpMaxRiskPct=50.0" \
            "InpTakeProfitPct=0.25" "InpStopLossPct=0.30"; do
    check_contains "preset carries $kv" "$kv" "$(cat "$SET")"
  done
  check_contains "and the preset is honest about which lot is traded at \$20" \
    "FOUR losses fit in \$20" "$(cat "$SET")"
  # A SKIP repeated twice a second for hours is how "nothing is trading" stayed
  # invisible for a night; and a refusal has to name what would fix it.
  check_contains "repeated SKIPs are throttled to one per reason per minute" \
    "InpSkipLogSec" "$(cat "$EA")"
  check_contains "the throttle keys on the reason, not the changing risk figure" \
    "void LogSkip(string key, string detail)" "$(cat "$EA")"
  check_contains "and a refused size names the bankroll it would need" \
    "needs a bankroll of >= " "$(cat "$EA")"
  # Position management. On this symbol a spike is a single-tick jump, so an
  # early break-even / mid-target partial measures identical (nothing acts on it)
  # and an early cut loses 32% of the profit rate; what pays is keeping the base
  # target and adding legs out of profit behind a shared stop that only rises.
  # The base leg's target is taken by the EA, not the broker: a broker TP on a
  # netting account would close the whole ladder at the target and kill the ride.
  check_contains "the base leg banks its target in the EA, not at the broker" \
    "void BankBaseLeg()" "$(cat "$EA")"
  check_contains "closing the partial by ticket works on netting and hedging" \
    "trade.PositionClosePartial(ticket" "$(cat "$EA")"
  check_contains "a distant broker TP still exists as a backstop" \
    "InpBackstopTPPct  = 1.00" "$(cat "$EA")"
  check_contains "the ladder stop can only ever tighten" \
    "never loosen a stop" "$(cat "$EA")"
  check_contains "one shared stop for every leg of the ladder" \
    "double SharedStop(double bid, double pct)" "$(cat "$EA")"
  check_contains "a break-even floor sits ABOVE entry, not at it" \
    "episodeBase * (1.0 + InpLockInPct / 100.0)" "$(cat "$EA")"
  # ...but that alone WAS the 2026-11-02 bug: armed before the target is banked,
  # the floor sits on the price and stops the trade out at +0.05% instead of
  # letting the spike reach 0.25%. Every winner left at +0.05%, no winner ever
  # reached the target, no add ever fired. The gate and the minimum gap are the fix.
  check_contains "the floor arms only once the target has been banked" \
    "episodeBanked && pct >= InpLockInPct" "$(cat "$EA")"
  check_contains "no stop is ever placed inside the minimum gap of the price" \
    "bid * InpMinStopGapPct / 100.0" "$(cat "$EA")"
  check_contains "and that gap floors every stop the ladder moves" \
    "if(gapDist > floorDist)" "$(cat "$EA")"
  check_contains "a stop move reports how far below the price it landed" \
    "%% below the price" "$(cat "$EA")"
  check_contains "an add the profit cannot afford is logged, not silenced" \
    "add-small" "$(cat "$EA")"
  check_contains "adds are sized from profit already made" \
    "(episodeBooked + LadderFloat()) * InpAddRiskPct / 100.0" "$(cat "$EA")"
  check_contains "an add that the trade cannot pay for is skipped, not forced" \
    "the episode has not made enough to pay for another leg" "$(cat "$EA")"
  check_contains "the ladder has a hard lot cap" \
    "InpMaxLadderLots - LadderLots()" "$(cat "$EA")"
  check_contains "and a risk cap inside the 3-loss budget" \
    "InpMaxLadderRiskPct" "$(cat "$EA")"
  check_contains "positions are found by magic, so netting and hedging both work" \
    "if(PositionGetString(POSITION_SYMBOL) != _Symbol)" "$(cat "$EA")"
  for kv in "InpLockInPct=0.05" "InpMinStopGapPct=0.15" "InpTrailPct=0.30" \
            "InpTrailStartPct=0.40" "InpMaxAdds=3" "InpAddAtPct=0.20" \
            "InpAddRiskPct=100.0" "InpMaxLadderLots=0.40" \
            "InpMaxLadderRiskPct=30.0"; do
    check_contains "preset carries $kv" "$kv" "$(cat "$SET")"
  done
else
  bad "EA exists at MQL5/Experts/HEX-BoomRider.mq5"
fi

echo "a live EA on a dead feed is a different fault, with its own fix"
# 2026-11-02: the chart stopped being ticked at 21:54, the EA wrote nothing for
# six hours, and the only line said the robot was not on the chart. It was. The
# EA now beats on a terminal timer and puts the tick age inside the beat, so the
# container can name the fault and restart the terminal to re-subscribe the symbol.
check_contains "the EA beats from a terminal timer, not from ticks" \
  "EventSetTimer(1)" "$(cat "$EA")"
check_contains "and writes the beat there" "void OnTimer()" "$(cat "$EA")"
check_contains "the beat carries the age of the last tick" "tick_age=" "$(cat "$EA")"
check_contains "a stalled feed is logged instead of swallowed" \
  'LogSkip("no-ticks"' "$(cat "$EA")"
check_contains "and the throttle runs on the wall clock, not the frozen tick clock" \
  "TimeLocal() - lastSkipAt" "$(cat "$EA")"
check_contains "the EA says why it left the chart" "void OnDeinit(" "$(cat "$EA")"
check_contains "with the reason named, not a number" "REASON_REMOVE" "$(cat "$EA")"
check_contains "the reason the EA left still reaches the phone" \
  '*,DEINIT,*)' "$(cat "$ENTRYPOINT")"
check_contains "and so does the recovery when ticks come back" \
  '*,FEED,*)' "$(cat "$ENTRYPOINT")"
check_contains "the container restarts the terminal when the feed stalls" \
  'title="OFFLINE"' "$(cat "$ENTRYPOINT")"
check_contains "with a budget that survives the restart it causes" \
  'budget="$MT5DIR/.hex-alert-tries"' "$(cat "$ENTRYPOINT")"
check_contains "and it stops restarting after three tries" 'attempt $tries/3' \
  "$(cat "$ENTRYPOINT")"
check_contains "the one watcher is started with the others" "alert_watcher &" \
  "$(cat "$ENTRYPOINT")"
check_contains "and a state change is the only thing that pushes" \
  'if [ "$st" != "$prev" ]' "$(cat "$ENTRYPOINT")"
check_contains "the phone is told once per fault, not once per repetition" \
  'STILL-OFFLINE' "$(cat "$ENTRYPOINT")"
check_contains "preset pins the stall threshold the container uses" \
  "InpTickStallSec=300" "$(cat "$SET")"

check_eq "backtest still compiles" "0" \
  "$(python3 -m py_compile "$HERE/../../Tools/boom_backtest.py" >/dev/null 2>&1 && echo 0 || echo 1)"
# 2026-11-02 again: the harness reported the broken rule as the MOST profitable
# configuration in its table ($56/h) while the live book lost money on it, because
# it only ever reported $/h, WR and PF. Where the wins actually exit is asserted
# now, and the pre-fix rule is kept in the harness to prove it can see the bug.
BK="$HERE/../../Tools/boom_backtest.py"
check_contains "the harness asserts the win payload, not just \$/h" \
  "def payload_checks()" "$(cat "$BK")"
check_contains "and still runs the pre-fix rule it must be able to catch" \
  "floor_after_bank=False" "$(cat "$BK")"
check_contains "the tape's per-tick volatility comes from the live book" \
  "SIGMA_QUIET" "$(cat "$BK")"
# DEPLOY.md once told people the GHCR package was public when it was not, and
# walked the deploy through forex-hex-mt4 after the workflow moved to mt5. Both
# are a deploy that fails at the pull with nothing to explain it, so the doc is
# checked against the image name the workflow actually builds.
DOC="$HERE/../../DEPLOY.md"
WF="$HERE/../../.github/workflows/deploy.yml"
if [ -f "$DOC" ] && [ -f "$WF" ]; then
  IMG="$(sed -n 's/^  IMAGE_NAME: .*\/\([a-z0-9._-]*\)$/\1/p' "$WF" | head -1)"
  [ -n "$IMG" ] || IMG="forex-hex-mt5"
  check_contains "the docs name the image the workflow actually builds" \
    "ghcr.io/thamitshepe/$IMG" "$(cat "$DOC")"
  check_contains "and they do not promise a public package without checking" \
    "verified 2026-11-02" "$(cat "$DOC")"
  check_contains "the docs explain where the cleared profile is kept" \
    ".profile-orig" "$(cat "$DOC")"
  check_contains "and the unsubscribed-symbol fault by its field name" \
    "SYMBOL_SELECT" "$(cat "$DOC")"
fi
# The EA compile check lives in the image build. metaeditor writes its log in
# UTF-16, so reading it with plain cat prints NULs and a real compile error looks
# like a mystery failure; and a distro missing MQL5/Include reports the EA's own
# #include as "not found", which is not the EA's fault either.
DOCKERFILE="$HERE/../Dockerfile"
check_contains "the EA compile log is decoded before it is read" \
  "tr -d '\\000' < " "$(cat "$DOCKERFILE")"
check_contains "a distro without the include tree is named as such" \
  "refusing to blame the EA for a distro problem" "$(cat "$DOCKERFILE")"
# GitHub's release front door answered 504 to every attempt on 2026-11-08 - from a
# laptop and from CI, for over an hour - while the asset itself was fine: the API
# reported it uploaded and the API's own asset endpoint served the same bytes. Two
# image builds died on that 504 and no fix reached the server. So the download has
# two routes now, and the fallback is the one that has to be tested: a stub curl
# plays the broken front door, the release API and the asset endpoint.
echo "the distro download has a second route (the front door 504s)"
FD="$HERE/fetch-distro.sh"
check_eq "the helper ships and is executable" "1" "$([ -x "$FD" ] && echo 1)"
check_contains "the image build downloads through it" \
  'sh /opt/hex/fetch-distro.sh "$MT5_DISTRO_URL" /tmp/distro.tar' "$(cat "$DOCKERFILE")"
check_contains "and so does the container's own seeding" \
  '/opt/hex/fetch-distro.sh "$url" "$tarball"' "$(cat "$ENTRYPOINT")"
FB="$TMP/fd"
mkdir -p "$FB/bin"
cat > "$FB/rel.json" <<'JSON'
{
  "id": 111,
  "name": "MT5 portable distro",
  "uploader": { "login": "owner", "id": 333 },
  "assets": [
    { "id": 222, "name": "mt5-portable.tar.gz", "uploader": { "id": 444 } }
  ]
}
JSON
cat > "$FB/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
case "$*" in
  */releases/tags/*)   cat "$STUB_JSON"; exit 0 ;;
  */releases/assets/*) [ -n "$out" ] && printf 'DISTRO-BYTES\n' > "$out"; exit 0 ;;
  *front-door-ok*)     [ -n "$out" ] && printf 'FRONT-DOOR\n'  > "$out"; exit 0 ;;
esac
exit 22
STUB
chmod +x "$FB/bin/curl"
FDURL="https://github.com/owner/repo/releases/download/tag/mt5-portable.tar.gz"
: > "$FB/log1"
out="$(STUB_LOG="$FB/log1" STUB_JSON="$FB/rel.json" PATH="$FB/bin:$PATH" \
        sh "$FD" "$FDURL" "$FB/out1.tar" 2>&1)" && rc=0 || rc=$?
check_eq "a 504 on the front door does not fail the download" "0" "$rc"
check_eq "the bytes are on disk" "DISTRO-BYTES" "$(cat "$FB/out1.tar" 2>/dev/null)"
check_contains "it takes the ASSET's id, not the release's" "releases/assets/222" "$(cat "$FB/log1")"
check_not_contains "and not the release id" "releases/assets/111" "$(cat "$FB/log1")"
check_not_contains "and not the uploader's id" "releases/assets/444" "$(cat "$FB/log1")"
check_contains "it says which route it used" "through the API instead" "$out"
: > "$FB/log2"
STUB_LOG="$FB/log2" STUB_JSON="$FB/rel.json" PATH="$FB/bin:$PATH" \
  sh "$FD" "https://github.com/owner/repo/releases/download/tag/front-door-ok.tar.gz" "$FB/out2.tar" \
  >/dev/null 2>&1
check_eq "a healthy front door is used as it is" "FRONT-DOOR" "$(cat "$FB/out2.tar" 2>/dev/null)"
check_eq "with no API call at all" "0" "$(grep -c 'releases/tags' "$FB/log2" || true)"
: > "$FB/log3"
out="$(STUB_LOG="$FB/log3" STUB_JSON="$FB/rel.json" PATH="$FB/bin:$PATH" \
        sh "$FD" "https://example.com/somewhere.tar.gz" "$FB/out3.tar" 2>&1)" && rc=0 || rc=$?
check_eq "a URL with no second route fails loudly" "1" "$rc"
check_contains "and says there is no fallback for it" "no API fallback" "$out"
mkdir -p "$FB/local"
printf 'LOCAL\n' > "$FB/local/distro.tar.gz"
sh "$FD" "file://$FB/local/distro.tar.gz" "$FB/out4.tar" >/dev/null 2>&1
check_eq "a file:// distro is copied, not downloaded" "LOCAL" "$(cat "$FB/out4.tar" 2>/dev/null)"


echo "dokploy-apply"
# The provisioner is what makes the server side clickless, so it is worth knowing
# it still speaks the API the way Dokploy expects. mock-dokploy.py stands in for
# the instance. It is run twice: the second run has to find what the first made
# rather than create a second app, and that is what makes it safe on every push.
DOKPLOY="$HERE/dokploy-apply.sh"
# A shell resolves a function when it is called, not when the file is read, so a
# helper used above its own definition prints "die: command not found" exactly in
# the case the message exists for (a mistyped --env file). Compare the line
# numbers rather than trusting the order by eye.
die_line="$(grep -n '^die() {' "$DOKPLOY" 2>/dev/null | head -1 | cut -d: -f1)"
use_line="$(grep -n 'die \"env file not found' "$DOKPLOY" 2>/dev/null | head -1 | cut -d: -f1)"
check_eq "the provisioner defines its failure helper before the first use of it" "1" \
  "$([ -n "$die_line" ] && [ -n "$use_line" ] && [ "$die_line" -lt "$use_line" ] && echo 1 || echo 0)"
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -x "$DOKPLOY" ]; then
  PORT=$((18000 + RANDOM % 2000))
  LOG="$TMP/requests.jsonl"
  MOCK_LOG="$LOG" python3 "$HERE/mock-dokploy.py" "$PORT" >"$TMP/mock.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 40); do
    curl -sf -H 'x-api-key: k' "http://127.0.0.1:$PORT/api/project.all" >/dev/null 2>&1 && break
    sleep 0.25
  done

  # What CI sends: the moving parts only. Deliberately NO MT5_LOGIN /
  # MT5_PASSWORD - those live in the Dokploy Environment tab.
  cat > "$TMP/dokploy.env" <<'EOF'
ENABLE_VNC=1
TZ=UTC
MT5_DISTRO_URL=
MT5_IMAGE=ghcr.io/owner/forex-hex-mt5:live
EOF

  for run in 1 2; do
    DOKPLOY_URL="http://127.0.0.1:$PORT" DOKPLOY_API_TOKEN=k \
      DOKPLOY_ENV_FILE="$TMP/dokploy.env" "$DOKPLOY" >"$TMP/run$run.out" 2>&1 || \
      bad "run $run exited non-zero: $(tail -1 "$TMP/run$run.out")"
  done

  # The credentials are set once in the app's Environment tab, as the operator
  # would; the merge has to carry them into what CI saves on the next push.
  cat > "$TMP/ui.env" <<'EOF'
MT5_LOGIN=41311895
MT5_PASSWORD=pa$$w"or\d
MT5_SERVER=Deriv-Demo
MT5_RECLAIM_VOLUME=1
EOF
  curl -sf -X POST "http://127.0.0.1:$PORT/api/compose.saveEnvironment" \
    -H 'Content-Type: application/json' -H 'x-api-key: k' \
    -d "$(jq -nc --arg composeId comp-1 --rawfile env "$TMP/ui.env" \
          '{composeId: $composeId, env: $env}')" >/dev/null
  DOKPLOY_URL="http://127.0.0.1:$PORT" DOKPLOY_API_TOKEN=k \
    DOKPLOY_ENV_FILE="$TMP/dokploy.env" "$DOKPLOY" >"$TMP/run3.out" 2>&1 || \
    bad "run 3 exited non-zero: $(tail -1 "$TMP/run3.out")"

  count() { jq -r --arg p "$1" 'select(.path == $p) | .path' "$LOG" 2>/dev/null | wc -l | tr -d ' '; }
  check_eq "project created once, then found"   "1" "$(count /api/project.create)"
  check_eq "app created once, then found"       "1" "$(count /api/compose.create)"
  check_eq "compose file pushed on all runs"    "3" "$(count /api/compose.update)"
  check_eq "environment saved on all runs (plus the UI save)" "4" "$(count /api/compose.saveEnvironment)"
  check_eq "deployed on all runs"               "3" "$(count /api/compose.deploy)"
  check_eq "x-api-key on every call" "0" \
    "$(jq -r 'select(.api_key != "k") | .path' "$LOG" 2>/dev/null | grep -c . || true)"

  check_contains "UI-set credentials survive the next CI deploy" "kept 4 variable(s)" \
    "$(<"$TMP/run3.out")"
  saved3="$(jq -s -r 'map(select(.path == "/api/compose.saveEnvironment"))[3].body.env' "$LOG")"
  check_contains "the login is in what CI saved" "MT5_LOGIN=41311895" "$saved3"
  check_contains "the password with shell metacharacters too" 'pa$$w"or\d' "$saved3"
  check_contains "and the hand-set one-shot switch" "MT5_RECLAIM_VOLUME=1" "$saved3"
  check_eq "CI's four are still there after the merge" "8" \
    "$(printf '%s\n' "$saved3" | grep -c '=')"

  # Removal works the other way: the user deletes the switch in the Environment
  # tab (an ordinary UI save), and CI does not resurrect it.
  curl -sf -X POST "http://127.0.0.1:$PORT/api/compose.saveEnvironment" \
    -H 'Content-Type: application/json' -H 'x-api-key: k' \
    -d "$(jq -nc --arg composeId comp-1 --rawfile env "$TMP/dokploy.env" \
          '{composeId: $composeId, env: $env}')" >/dev/null
  DOKPLOY_URL="http://127.0.0.1:$PORT" DOKPLOY_API_TOKEN=k \
    DOKPLOY_ENV_FILE="$TMP/dokploy.env" "$DOKPLOY" >"$TMP/run4.out" 2>&1 || true
  saved5="$(jq -s -r 'map(select(.path == "/api/compose.saveEnvironment"))[5].body.env' "$LOG")"
  check_eq "a switch removed in the UI stays removed" "0" \
    "$(printf '%s\n' "$saved5" | grep -c MT5_RECLAIM_VOLUME || true)"

  update="$(jq -s -c 'map(select(.path == "/api/compose.update"))[0].body' "$LOG")"
  check_eq "sourceType is raw" "raw" "$(printf '%s' "$update" | jq -r '.sourceType')"
  check_eq "composeFile carries pull_policy" "1" \
    "$(printf '%s' "$update" | jq -r '.composeFile | contains("pull_policy: always") | if . then 1 else 0 end')"
  check_eq "autoDeploy off (CI is the trigger)" "false" \
    "$(printf '%s' "$update" | jq -r '.autoDeploy // "false"')"

  saved="$(jq -s -r 'map(select(.path == "/api/compose.saveEnvironment"))[0].body.env' "$LOG")"
  check_eq "CI's four values sent" "4" "$(printf '%s\n' "$saved" | grep -c '=')"
else
  bad "dokploy-apply.sh not testable here (needs jq, python3, and the script)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

