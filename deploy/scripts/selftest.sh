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
# A volume that has logged in before: config/accounts.ini exists, which is what
# makes startup.ini's login a re-login rather than a hope.
mkdir -p "$MT4DIR/config"; : > "$MT4DIR/config/accounts.ini"
load_fn "$ENTRYPOINT" profile_charts >/dev/null
load_fn "$ENTRYPOINT" write_startup_ini >/dev/null
write_startup_ini >/dev/null 2>&1
ini="$TMP/mt4/startup.ini"
if [ -f "$ini" ]; then
  ok "file written"
  check_contains "profile"    "Profile=default"                     "$(cat "$ini")"
  check_contains "login"      "Login=176428789"                     "$(cat "$ini")"
  check_contains "password"   "Password=secret"                     "$(cat "$ini")"
  check_contains "server"     "Server=MetaQuotes-Demo"              "$(cat "$ini")"
  check_contains "symbol"     "Symbol=XAUUSD"                       "$(cat "$ini")"
  check_contains "expert"     "Expert=HEX-FVG-Breaker"              "$(cat "$ini")"
  check_contains "preset"     "ExpertParameters=100usd-demo.set"    "$(cat "$ini")"
  check_contains "autotrade"  "ExpertsTrades=true"                  "$(cat "$ini")"
  check_eq "no unexpanded \${}" "0" "$(grep -c '\${' "$ini")"
else
  bad "file written"
fi

echo "startup.ini on a volume with no account in it"
# Instance 2's first boot deletes config/accounts.ini - the gold account's record -
# and MT4's startup.ini login cannot create a record, it only re-uses one. With
# Login= present and nothing to log in as, the terminal tries, fails and sits at
# "Waiting for update"/"No connection" without ever showing its dialog. Leaving the
# three lines out is the state a fresh install is in, and the one that gets a
# dialog. The expert must still be attached, or the manual login lands on a chart
# with no robot.
MT4DIR="$TMP/mt4n"
write_startup_ini >/dev/null 2>&1
inin="$MT4DIR/startup.ini"
check_eq "no account record -> no Login=" "0" "$(grep -c '^Login=' "$inin")"
check_eq "no account record -> the password is not written either" "0" \
  "$(grep -c '^Password=' "$inin")"
check_eq "no account record -> no Server=" "0" "$(grep -c '^Server=' "$inin")"
check_contains "and the file says why" "left out on purpose" "$(cat "$inin")"
check_contains "the expert is still attached" "Expert=HEX-FVG-Breaker" "$(cat "$inin")"
check_contains "trading is still allowed" "ExpertsTrades=true" "$(cat "$inin")"
# The record appears after the manual login; from then on it is a re-login again.
mkdir -p "$MT4DIR/config"; : > "$MT4DIR/config/accounts.ini"
write_startup_ini >/dev/null 2>&1
check_contains "once it has an account, the login is written again" "Login=176428789" \
  "$(cat "$inin")"


echo "capability reporting"
# SYS_PTRACE is bit 19. Docker's default CapEff (a80425fb) does not have it; with
# `cap_add: SYS_PTRACE` it is a80825fb. The banner used to test CapEff, which is
# empty for the trader process because gosu dropped root - so every healthy
# container warned about a missing capability it actually had.
load_fn "$ENTRYPOINT" cap_has_bit >/dev/null
if cap_has_bit a80425fb 19; then
  bad "Docker's default set has no SYS_PTRACE"
else
  ok "Docker's default set has no SYS_PTRACE"
fi
if cap_has_bit a80825fb 19; then
  ok "cap_add SYS_PTRACE is recognised (the container's own set)"
else
  bad "cap_add SYS_PTRACE is recognised (the container's own set)"
fi
if cap_has_bit "" 19; then bad "an unreadable set is not 'present'"; else ok "an unreadable set is not 'present'"; fi
check_contains "the banner asks the container's set, not the process's" 'CapBnd' \
  "$(sed -n '/^report_isolation() {/,/^}/p' "$ENTRYPOINT")"

echo "banner"
# The banner is the first thing in the log, so anything unbound here kills the
# container before the terminal starts - and only for an instance that happens to
# have the optional variable set. That asymmetry is the point: instance 1 can be
# healthy while instance 2 restart-loops, which is what "$MT4_PERIODm" did (bash
# reads that as the variable MT4_PERIODm, so it only broke when a period was
# given). Rendered for both instances with `set -u` on, like the entrypoint.
banner_text() { # instance symbol period -> what the banner prints
  (
    set -u
    MT4_INSTANCE="$1" MT4_SYMBOL="$2" MT4_PERIOD="$3" MT4_EXPERT=HEX-FVG-Breaker
    MT4_PRESET=100usd-demo; MT4_LOGIN=176472093; MT4_SERVER=MetaQuotes-Demo
    MT4DIR=/data/mt4
    log() { printf '%s\n' "$*"; }
    eval "$(sed -n '/^banner() {/,/^}/p' "$ENTRYPOINT")"
    banner
  ) 2>&1
}
b1="$(banner_text 1 XAUUSD '')"
check_contains "instance 1 renders" "instance 1 | XAUUSD |" "$b1"
check_eq "instance 1 has no unbound variable" "0" \
  "$(printf '%s\n' "$b1" | grep -c 'unbound variable')"
b2="$(banner_text 2 DOGEUSD 5)"
check_contains "instance 2 renders with its timeframe" "instance 2 | DOGEUSD 5m |" "$b2"
check_eq "instance 2 has no unbound variable (the restart loop)" "0" \
  "$(printf '%s\n' "$b2" | grep -c 'unbound variable')"
check_contains "an empty period adds no suffix" "| XAUUSD |" "$b1"
check_contains "instance 2 names the env vars it reads" "MT4_LOGIN2, MT4_SYMBOL2" "$b2"
check_contains "the account line is intact" "account      : 176472093 @ MetaQuotes-Demo" "$b2"
check_eq "the account appears once per banner" "1" \
  "$(printf '%s\n' "$b2" | grep -c 'account      :')"

echo "startup.ini symbol from profile"
# The distro's default profile already carries the XAUUSD M15 chart. Naming the
# symbol in startup.ini as well makes MT4 open a second chart, and a second chart
# loads a second copy of the expert - the double load the MagicNumber lock exists
# to refuse. So when the profile carries the symbol, Symbol= must be gone.
MT4DIR="$TMP/mt4p"; mkdir -p "$MT4DIR/profiles/default"
printf 'symbol=XAUUSD\nperiod=15\n' > "$MT4DIR/profiles/default/chart04.chr"
write_startup_ini >/dev/null 2>&1
inip="$MT4DIR/startup.ini"
check_eq "profile carries symbol -> no Symbol= line" "0" "$(grep -c '^Symbol=' "$inip")"
check_contains "profile carries symbol -> says why" "deliberately left out" "$(cat "$inip")"
check_contains "profile carries symbol -> expert still set" "Expert=HEX-FVG-Breaker" "$(cat "$inip")"
# A profile carrying something else must not suppress Symbol= for our symbol.
printf 'symbol=EURUSD\nperiod=15\n' > "$MT4DIR/profiles/default/chart04.chr"
write_startup_ini >/dev/null 2>&1
check_contains "profile carries another symbol -> Symbol= kept" "Symbol=XAUUSD" "$(cat "$inip")"
# No profile at all (a bare install): Symbol= has to be back, or the chart is empty.
rm -rf "$MT4DIR/profiles"
write_startup_ini >/dev/null 2>&1
check_contains "no profile -> Symbol= kept" "Symbol=XAUUSD" "$(cat "$inip")"

echo "profile chart moves to the instance's symbol"
# A second instance asks for a symbol the archived profile does not carry. Two
# charts would load the expert twice, so the chart must be moved, not joined.
load_fn "$ENTRYPOINT" ensure_profile_chart >/dev/null
MT4DIR="$TMP/mt4c"; MT4_SYMBOL=DOGEUSD; MT4_PERIOD=5
mkdir -p "$MT4DIR/profiles/default"
cat > "$MT4DIR/profiles/default/chart04.chr" <<'CHR'
<chart>
id=134368953844317820
symbol=XAUUSD
period=15
digits=2
scale=2
<window>
height=100
</window>
<expert>
name=HEX-FVG-Breaker
<inputs>
MaxSpreadDollars=0.45
</inputs>
</expert>
</chart>
CHR
ensure_profile_chart >/dev/null 2>&1
chr="$MT4DIR/profiles/default/chart04.chr"
check_contains "symbol moved"  "symbol=DOGEUSD" "$(cat "$chr")"
check_contains "period moved"  "period=5"       "$(cat "$chr")"
check_eq "other instrument's inputs dropped" "0" "$(grep -c 'MaxSpreadDollars' "$chr")"
check_eq "no stale digits/scale" "0" "$(grep -c '^digits=\|^scale=' "$chr")"
check_eq "chart structure survives" "1" "$(grep -c '^</chart>' "$chr")"
check_eq "original kept outside the profile" "1" "$(ls "$MT4DIR/.profile-orig" | wc -l | tr -d ' ')"
# A second chart in the profile is moved out, so exactly one expert can load.
printf '<chart>\nsymbol=EURUSD\nperiod=15\n</chart>\n' > "$MT4DIR/profiles/default/chart07.chr"
ensure_profile_chart >/dev/null 2>&1
check_eq "one chart left in the profile" "1" "$(ls "$MT4DIR/profiles/default"/*.chr | wc -l | tr -d ' ')"
check_eq "extra chart parked, not deleted" "1" "$(ls "$MT4DIR/.profile-extra" | wc -l | tr -d ' ')"
# Running again with the same env must be a no-op, or every restart rewrites the
# file the operator may have tuned in the desktop.
before="$(cat "$chr")"
ensure_profile_chart >/dev/null 2>&1
check_eq "second run is a no-op" "$before" "$(cat "$chr")"
# End to end, and the point of the whole function: once the profile carries this
# instance's symbol, startup.ini must not name it again - that line is what used
# to open a second chart and a second expert on the same magic number.
write_startup_ini >/dev/null 2>&1
check_eq "instance chart -> startup.ini omits Symbol=" "0" "$(grep -c '^Symbol=' "$MT4DIR/startup.ini")"
check_contains "instance chart -> expert still attached" "Expert=HEX-FVG-Breaker" "$(cat "$MT4DIR/startup.ini")"
# No profile at all: nothing to move, and startup.ini's Symbol= is what opens the
# chart. The function must not create anything.
rm -rf "$MT4DIR/profiles"
ensure_profile_chart >/dev/null 2>&1
check_eq "no profile -> no chart invented" "0" "$(ls -d "$MT4DIR/profiles" 2>/dev/null | wc -l | tr -d ' ')"

echo "log mirror"
# The mirror has to survive the four things a naive tail does not: a journal that
# already holds a previous run (a restart must not replay it - two "loaded
# successfully" lines read as a double expert load), a file that grows, a file
# that gets truncated under it, and two folders at once.
load_fn "$ENTRYPOINT" mirror_dir >/dev/null
mdir="$TMP/logs"; mkdir -p "$mdir"
printf 'old-one\nold-two\n' > "$mdir/today.log"   # left behind by a previous run
mirror_dir "[mt4]" "$mdir" > "$TMP/mirror.out" 2>&1 &
mirror_pid=$!
sleep 3
check_eq "previous run not replayed" "0" "$(grep -c '^\[mt4\] old-' "$TMP/mirror.out")"
printf 'three\n' >> "$mdir/today.log"          # grew
sleep 3
printf 'reset\n'  > "$mdir/today.log"          # truncated
sleep 3
printf 'after\n' >> "$mdir/today.log"
sleep 3
kill "$mirror_pid" 2>/dev/null
wait "$mirror_pid" 2>/dev/null
out="$(cat "$TMP/mirror.out")"
check_contains "says what it skipped" "previous run"  "$out"
check_contains "appended line"        "[mt4] three"   "$out"
check_contains "after truncate"       "[mt4] reset"   "$out"
check_contains "kept following"       "[mt4] after"   "$out"
# Each line must appear once: a mirror that re-prints the file is noise, and one
# that skips lines is worse.
check_eq "no duplicate lines" "1" "$(printf '%s\n' "$out" | grep -c '^\[mt4\] three$')"
check_eq "mirrored lines are unique" "$(printf '%s\n' "$out" | grep '^\[mt4\] ' | sort -u | wc -l | tr -d ' ')" \
                                     "$(printf '%s\n' "$out" | grep -c '^\[mt4\] ')"

echo "why no trade"
# Reject() in the expert appends a CSV row and returns - it never prints - so a
# session that took no trades looked in the container log exactly like a robot that
# never started. These turn the file into log lines: each *distinct* reason as it
# happens (while a reason holds it is written once per tick, so only a change is
# news) plus a state line, and an explicit warning when the terminal itself is why.
load_fn "$ENTRYPOINT" rej_reasons >/dev/null
load_fn "$ENTRYPOINT" ea_state_line >/dev/null
load_fn "$ENTRYPOINT" mirror_rejections >/dev/null
rdir="$TMP/rej/mt4/MQL4/Files/Common/HEX-Logs"; mkdir -p "$rdir"
printf 'time,bar_time,reason,dir,zone_type,zone_top,zone_bottom,spread_pts,atr,dist_pts,equity,trend,detail\n' > "$rdir/rejections.csv"
printf '2026.10.01 09:00:00,2026.10.01 09:00,GUARD,0,,,,,,,,,an older run\n' >> "$rdir/rejections.csv"
printf 'a,2026.10.22 09:00,GUARD,0,,,,,,,,,x\nb,2026.10.22 09:05,NO_TRIGGER,0,,,,,,,,,x\nc,2026.10.22 09:06,GUARD,0,,,,,,,,,x\n' > "$TMP/r.csv"
check_eq "counts reasons, most frequent first" "GUARD 2, NO_TRIGGER 1" "$(rej_reasons "$TMP/r.csv" 50)"
check_contains "the state line says how many trades closed" "closed trades in trades.csv: 0" \
  "$( ( log() { echo "$*"; }; ea_state_line "$rdir" "$rdir/trades.csv" ) 2>&1 )"
check_contains "and what the last rejection was" "last reason: GUARD" \
  "$( ( log() { echo "$*"; }; ea_state_line "$rdir" "$rdir/trades.csv" ) 2>&1 )"
printf 'ticket,login\n7,222\n' > "$rdir/trades.csv"
check_contains "a closed trade is counted, the header is not" "closed trades in trades.csv: 1" \
  "$( ( log() { echo "$*"; }; ea_state_line "$rdir" "$rdir/trades.csv" ) 2>&1 )"
printf '2026.10.22 09:10:00,2026.10.22 09:10,AUTOTRADE_DISABLED,1,,,,,,,,,terminal AutoTrading button is off\n' >> "$rdir/rejections.csv"
check_contains "AutoTrading off is called out, not just counted" "AutoTrading button is OFF" \
  "$( ( warn() { echo "$*"; }; ea_state_line "$rdir" "$rdir/trades.csv" ) 2>&1 )"
# TMPDIR separates the mirror's position marker from any other run of this test,
# and `log` prints here (the selftest's stub is silent) so the startup line is
# checkable - it is what tells an operator the old rows are on the volume, not lost.
( log() { echo "$*"; }; TMPDIR="$TMP" MT4DIR="$TMP/rej/mt4" mirror_rejections ) \
  > "$TMP/rej.out" 2>&1 &
rej_pid=$!
sleep 6
printf '2026.10.22 10:00:00,2026.10.22 10:00,GUARD,1,,,,,,,,,outside session\n' >> "$rdir/rejections.csv"
printf '2026.10.22 10:00:00,2026.10.22 10:00,GUARD,1,,,,,,,,,outside session\n' >> "$rdir/rejections.csv"
sleep 6
printf '2026.10.22 10:05:00,2026.10.22 10:05,NO_TRIGGER,1,,,,,,,,,no rejection candle in the zone\n' \
  >> "$rdir/rejections.csv"
sleep 6
kill "$rej_pid" 2>/dev/null
wait "$rej_pid" 2>/dev/null
out="$(cat "$TMP/rej.out")"
check_contains "a rejection reaches the container log" \
  "[rej] 2026.10.22 10:00:00  GUARD 1  outside session" "$out"
check_eq "a reason that repeats per tick is printed once" "1" \
  "$(printf '%s\n' "$out" | grep -c 'GUARD')"
check_contains "a new reason is printed" "NO_TRIGGER" "$out"
check_eq "an earlier run's rows are not replayed" "0" \
  "$(printf '%s\n' "$out" | grep -c 'an older run')"
check_contains "and the log says it skipped them" "not replayed" "$out"

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

echo "instance env"
# One env file, several applications. Instance 2 must read its own copies and
# must never fall back to instance 1's account - that fallback is the failure this
# whole scheme exists to prevent, so it is pinned here.
load_fn "$ENTRYPOINT" inst_var >/dev/null
load_fn "$ENTRYPOINT" shared_var >/dev/null
load_fn "$ENTRYPOINT" check_instance_env >/dev/null
load_fn "$ENTRYPOINT" claim_volume >/dev/null
load_fn "$ENTRYPOINT" warn >/dev/null
# shellcheck disable=SC2034  # read by the extracted functions
MT4_INSTANCE=1
MT4_LOGIN=111; MT4_SYMBOL=XAUUSD; MT4_PRESET=100usd-demo; MT4_PERIOD=""
MT4_LOGIN2=222; MT4_SYMBOL2=DOGEUSD; MT4_PRESET2=doge-scalp-shadow; MT4_PERIOD2=5
MT4_PASSWORD2=pw2; MT4_SERVER2=TMGM-Demo
VNC_PASSWORD=shared-pw
check_eq "instance 1 reads the plain name" "XAUUSD" "$(inst_var MT4_SYMBOL)"
check_eq "instance 1 leaves the timeframe to the profile" "" "$(inst_var MT4_PERIOD)"
check_eq "instance 1 login" "111" "$(inst_var MT4_LOGIN)"
MT4_INSTANCE=2
check_eq "instance 2 reads its own symbol" "DOGEUSD" "$(inst_var MT4_SYMBOL)"
check_eq "instance 2 reads its own timeframe" "5" "$(inst_var MT4_PERIOD)"
check_eq "instance 2 reads its own login" "222" "$(inst_var MT4_LOGIN)"
MT4_EXPERT=SomeOtherInstance
check_eq "instance 2 never falls back to instance 1's copy" "HEX-FVG-Breaker" \
  "$(inst_var MT4_EXPERT HEX-FVG-Breaker)"
unset MT4_EXPERT
check_eq "shared password is one value for both instances" "shared-pw" "$(shared_var VNC_PASSWORD)"
VNC_PASSWORD2=other
check_eq "a suffixed shared value wins when it exists" "other" "$(shared_var VNC_PASSWORD)"
unset VNC_PASSWORD2
( MT4_INSTANCE=2; MT4_SYMBOL2=""; check_instance_env ) >/dev/null 2>&1
check_eq "instance 2 without its own symbol refuses to boot" "1" "$?"
( MT4_INSTANCE=2; MT4_PRESET2=""; check_instance_env ) >/dev/null 2>&1
check_eq "instance 2 without its own preset refuses to boot" "1" "$?"
( MT4_INSTANCE=2; check_instance_env ) >/dev/null 2>&1
check_eq "instance 2 fully configured boots" "0" "$?"
( MT4_INSTANCE=2; MT4_SERVER2=""; check_instance_env ) >/dev/null 2>&1
check_eq "an unknown server name does not block the boot (log in once instead)" "0" "$?"
( MT4_INSTANCE=1; MT4_LOGIN=""; check_instance_env ) >/dev/null 2>&1
check_eq "instance 1 may still start without a login (login dialog)" "0" "$?"

# The volume remembers who claimed it: a second application pointed at the first
# one's volume is how a DOGE preset would trade a gold account.
vol="$TMP/vol"; mkdir -p "$vol/mt4"
( MT4DIR="$vol/mt4" MT4_INSTANCE=1 MT4_LOGIN=111 MT4_SYMBOL=XAUUSD MT4_PRESET=100usd-demo
  claim_volume ) >/dev/null 2>&1
check_contains "volume records its instance and account" "instance=1 login=111 symbol=XAUUSD" \
  "$(cat "$vol/.hex-instance" 2>/dev/null)"
( MT4DIR="$vol/mt4" MT4_INSTANCE=2 MT4_LOGIN=222 MT4_SYMBOL=DOGEUSD MT4_PRESET=doge-scalp
  claim_volume ) >/dev/null 2>&1
check_eq "another account on the same volume is refused" "1" "$?"
( MT4DIR="$vol/mt4" MT4_INSTANCE=1 MT4_LOGIN=111 MT4_SYMBOL=XAUUSD MT4_PRESET=100usd-demo
  claim_volume ) >/dev/null 2>&1
check_eq "the same account on the same volume is fine" "0" "$?"
( MT4DIR="$vol/mt4" MT4_INSTANCE=1 MT4_LOGIN=111 MT4_SYMBOL=EURUSD MT4_PRESET=100usd-demo
  claim_volume ) >/dev/null 2>&1
check_eq "a symbol change on the same volume is allowed (chart gets moved)" "0" "$?"
check_contains "the marker follows the symbol change" "symbol=EURUSD" \
  "$(cat "$vol/.hex-instance" 2>/dev/null)"

# The instance number is half of a volume's identity: instance 1 reads the plain
# MT4_* names and instance 2 reads the "<n>" copies. An application running at the
# wrong number therefore drives the *other* application's account and symbol while
# its own env looks complete - "it still shows the old account and the old chart",
# with nothing in the log explaining it. Checked even when the login matches.
vol2="$TMP/vol2"; mkdir -p "$vol2/mt4"
( MT4DIR="$vol2/mt4" MT4_INSTANCE=2 MT4_LOGIN=222 MT4_SYMBOL=DOGEUSD MT4_PRESET=doge-scalp
  claim_volume ) >/dev/null 2>&1
check_eq "a fresh volume records the instance that claimed it" "2" \
  "$(sed -n 's/^instance=\([0-9]*\).*/\1/p' "$vol2/.hex-instance" 2>/dev/null)"
( MT4DIR="$vol2/mt4" MT4_INSTANCE=1 MT4_LOGIN=222 MT4_SYMBOL=DOGEUSD MT4_PRESET=doge-scalp
  claim_volume ) >/dev/null 2>&1
check_eq "the same account at the wrong instance number is refused" "1" "$?"
check_contains "and the refusal says which MT4_INSTANCE to set" "MT4_INSTANCE=2" \
  "$( ( MT4DIR="$vol2/mt4" MT4_INSTANCE=1 MT4_LOGIN=222 MT4_SYMBOL=DOGEUSD MT4_PRESET=doge-scalp
        claim_volume ) 2>&1 )"
( MT4DIR="$vol2/mt4" MT4_INSTANCE=2 MT4_LOGIN=222 MT4_SYMBOL=DOGEUSD MT4_PRESET=doge-scalp
  claim_volume ) >/dev/null 2>&1
check_eq "its own instance number is allowed" "0" "$?"

# Two Dokploy applications can be pointed at the SAME volume: a volume name is
# server-wide, so the string that is right for one application is also accepted by
# the second and means the same directory. Then every check above agrees - one
# instance, one login, one marker - while two terminals write one MT4 tree and both
# read the same config/accounts.ini. That is "both hostnames show the same account",
# and the lease is the thing that says it out loud.
#
# Liveness is the whole point: a crashed predecessor also leaves a fresh lease, so
# the warning is printed only when the other container overwrites our own beat while
# we watch. A real second container is simulated by one that keeps writing.
load_fn "$ENTRYPOINT" lease_holder >/dev/null
load_fn "$ENTRYPOINT" lease_write >/dev/null
load_fn "$ENTRYPOINT" lease_shared_warning >/dev/null
load_fn "$ENTRYPOINT" lease_volume >/dev/null
leasevol="$TMP/leasevol"; mkdir -p "$leasevol/mt4"
lease_now="$(date +%s)"
printf 'host=other-container instance=1 login=111 beat=%s\n' "$lease_now" > "$leasevol/.hex-lease"
( for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    printf 'host=other-container instance=1 login=111 beat=%s\n' "$(date +%s)" \
      > "$leasevol/.hex-lease"
    sleep 0.1
  done ) &
writer=$!
out="$( ( HEX_HOST_ID=mine HEX_LEASE_PROBE=2 MT4DIR="$leasevol/mt4" MT4_INSTANCE=1 \
      MT4_LOGIN=111 lease_volume ) 2>&1 )"
wait "$writer" 2>/dev/null || true
check_contains "a container that keeps beating on our volume is a shared volume" \
  "in use right now by another container" "$out"
check_contains "and it names the volume to give this application instead" \
  "hex-mt4-doge" "$out"
# A predecessor that died a moment ago leaves the same fresh lease, and is not one.
printf 'host=dead-container instance=1 login=111 beat=%s\n' "$lease_now" > "$leasevol/.hex-lease"
out="$( ( HEX_HOST_ID=mine HEX_LEASE_PROBE=1 MT4DIR="$leasevol/mt4" MT4_INSTANCE=1 \
      MT4_LOGIN=111 lease_volume ) 2>&1 )"
check_eq "a crashed predecessor with a fresh lease is not a shared volume" "" "$out"
check_contains "and this container takes the volume over" "host=mine" \
  "$(cat "$leasevol/.hex-lease" 2>/dev/null)"
printf 'host=other-container instance=1 login=111 beat=%s\n' "$((lease_now - 3600))" > "$leasevol/.hex-lease"
out="$( ( HEX_HOST_ID=mine HEX_LEASE_PROBE=0 MT4DIR="$leasevol/mt4" MT4_INSTANCE=1 \
      MT4_LOGIN=111 lease_volume ) 2>&1 )"
check_eq "an hour-old heartbeat is a dead container, not a shared volume" "" "$out"
printf 'host=other-container instance=1 login=111 beat=0\n' > "$leasevol/.hex-lease"
out="$( ( HEX_HOST_ID=mine HEX_LEASE_PROBE=0 MT4DIR="$leasevol/mt4" MT4_INSTANCE=1 \
      MT4_LOGIN=111 lease_volume ) 2>&1 )"
check_eq "a container that stopped cleanly releases the volume" "" "$out"
printf 'host=mine instance=1 login=111 beat=%s\n' "$lease_now" > "$leasevol/.hex-lease"
out="$( ( HEX_HOST_ID=mine HEX_LEASE_PROBE=0 MT4DIR="$leasevol/mt4" MT4_INSTANCE=1 \
      MT4_LOGIN=111 lease_volume ) 2>&1 )"
check_eq "our own heartbeat (a redeploy) is not a shared volume" "" "$out"

echo "instance seed: the other account's state"
# The distro is a copy of a working terminal, so it carries the saved login, the
# last server and the EA's CSV log. Instance 1 may have them; instance 2 must not,
# or it starts as the gold account with a trade log it never wrote.
load_fn "$ENTRYPOINT" neutralise_seed >/dev/null
load_fn "$ENTRYPOINT" swap_in_new_tree >/dev/null
seedvol="$TMP/seedvol"
mkdir -p "$seedvol/mt4/config" "$seedvol/mt4/MQL4/Files/Common/HEX-Logs" \
  "$seedvol/mt4/MQL4/Logs" "$seedvol/mt4/logs" "$seedvol/mt4/MQL4/Presets"
for f in config/accounts.ini config/server.ini config/community.ini config/experts.ini; do
  printf 'binary\n' > "$seedvol/mt4/$f"
done
printf 'date,equity\n' > "$seedvol/mt4/MQL4/Files/Common/HEX-Logs/daily.csv"
printf 'journal\n' > "$seedvol/mt4/MQL4/Logs/20260101.log"
printf 'journal\n' > "$seedvol/mt4/logs/20260101.log"
printf 'keep\n' > "$seedvol/mt4/MQL4/Presets/100usd-demo.set"
( MT4DIR="$seedvol/mt4" MT4_INSTANCE=1; neutralise_seed ) >/dev/null 2>&1
check_eq "instance 1 keeps the terminal's own account" "yes" \
  "$([ -f "$seedvol/mt4/config/accounts.ini" ] && echo yes)"
( MT4DIR="$seedvol/mt4" MT4_INSTANCE=2; neutralise_seed ) >/dev/null 2>&1
check_eq "instance 2 drops the saved login" "gone" \
  "$([ -f "$seedvol/mt4/config/accounts.ini" ] || echo gone)"
check_eq "instance 2 drops the last server" "gone" \
  "$([ -f "$seedvol/mt4/config/server.ini" ] || echo gone)"
check_eq "instance 2 keeps config/experts.ini (the WebRequest allow-list lives in it)" "binary" \
  "$(cat "$seedvol/mt4/config/experts.ini" 2>/dev/null)"
check_eq "instance 2 drops the other account's CSV log" "gone" \
  "$([ -f "$seedvol/mt4/MQL4/Files/Common/HEX-Logs/daily.csv" ] || echo gone)"
check_eq "that CSV log is parked, not destroyed" "date,equity" \
  "$(head -1 "$seedvol/mt4/.before-instance2/HEX-Logs/daily.csv" 2>/dev/null)"
check_eq "instance 2 drops the journals" "gone" \
  "$([ -f "$seedvol/mt4/logs/20260101.log" ] || echo gone)"
check_eq "that journal is parked too" "journal" \
  "$(cat "$seedvol/mt4/.before-instance2/logs/20260101.log" 2>/dev/null)"
check_eq "the presets are untouched" "keep" "$(cat "$seedvol/mt4/MQL4/Presets/100usd-demo.set")"
check_contains "the volume records that it was neutralised" "instance=2" \
  "$(cat "$seedvol/.hex-neutralised" 2>/dev/null)"
# Once per volume: after this, accounts.ini is *this* instance's login and is what
# makes it start without a prompt, so a second boot must leave it alone.
printf 'this-instance\n' > "$seedvol/mt4/config/accounts.ini"
( MT4DIR="$seedvol/mt4" MT4_INSTANCE=2; neutralise_seed ) >/dev/null 2>&1
check_eq "a later boot keeps this instance's own login" "this-instance" \
  "$(cat "$seedvol/mt4/config/accounts.ini")"
# A re-seed brings the other account's files back, so it must re-arm the step.
mkdir -p "$TMP/newtree" && printf 'MZ\n' > "$TMP/newtree/terminal.exe"
( MT4DIR="$seedvol/mt4" swap_in_new_tree "$TMP/newtree" ) >/dev/null 2>&1
check_eq "a re-seed re-arms neutralisation" "gone" \
  "$([ -f "$seedvol/.hex-neutralised" ] || echo gone)"

echo "compose: one application, two services, one image"
# The deployment shape itself is the fix for "both hostnames show the same
# account": two services from one image, each with its own instance number and its
# own volume, and the second never holding the first account's credentials. Pinned
# here because every one of those is a line in a YAML file, which is exactly the
# kind of thing that gets edited by hand and drifts.
COMPOSE="$HERE/../docker-compose.yml"
gold="$(awk '/^  mt4:$/{f=1} /^  mt4-doge:$/{f=0} f' "$COMPOSE")"
doge="$(awk '/^  mt4-doge:$/{f=1} /^volumes:$/{f=0} f' "$COMPOSE")"
check_eq "the compose file declares both services" "2" "$(grep -cE '^  (mt4|mt4-doge):$' "$COMPOSE")"
check_contains "instance 1 is a property of the mt4 service" 'MT4_INSTANCE: "1"' "$gold"
check_contains "instance 2 is a property of the mt4-doge service" 'MT4_INSTANCE: "2"' "$doge"
check_eq "mt4-doge is not given the gold login" "0" \
  "$(printf '%s\n' "$doge" | grep -c '^      MT4_LOGIN:')"
check_eq "mt4-doge is not given the gold password" "0" \
  "$(printf '%s\n' "$doge" | grep -c '^      MT4_PASSWORD:')"
check_eq "mt4-doge is not given the gold server" "0" \
  "$(printf '%s\n' "$doge" | grep -c '^      MT4_SERVER:')"
check_contains "mt4-doge reads its own login" 'MT4_LOGIN2:' "$doge"
check_contains "mt4-doge has its own volume" 'hex-mt4-doge-data:/data' "$doge"
check_eq "mt4-doge publishes no host port (it has a hostname)" "0" \
  "$(printf '%s\n' "$doge" | grep -c '^    ports:')"
check_contains "the gold volume keeps its old name, so no data moves" 'hex-mt4-data:/data' "$gold"
check_eq "both volumes are declared" "2" "$(grep -cE '^  hex-mt4(-doge)?-data:$' "$COMPOSE")"
check_eq "one image, shared by both" "1" "$(grep -c '^  image:' "$COMPOSE")"
# Traefik only reaches containers on its own network, and Dokploy's is
# dokploy-network. Without this the domain gets as far as the proxy and stops:
# 404 "app not found" if the label is missing too, 502 if only this is.
common="$(awk '/^x-mt4-common:/{f=1} /^services:$/{f=0} f' "$COMPOSE")"
check_contains "the shared block puts services on Dokploy's network" "    - dokploy-network" \
  "$common"
check_contains "as an external network Dokploy created" "dokploy-network:" \
  "$(printf '%s\n' "$(awk '/^networks:$/{f=1} f' "$COMPOSE")")"
check_contains "and marks it external" "external: true" \
  "$(printf '%s\n' "$(awk '/^networks:$/{f=1} f' "$COMPOSE")")"
check_contains "the shared block names the port a domain proxies to" '- "6080"' "$common"
if docker compose version >/dev/null 2>&1; then
  out="$(docker compose -f "$COMPOSE" config 2>/dev/null)"
  rc=$?
  check_eq "docker compose accepts the file" "0" "$rc"
  check_eq "and resolves it into two services" "2" \
    "$(printf '%s\n' "$out" | grep -cE '^  (mt4|mt4-doge):$')"
  check_contains "with the second on its own volume" "hex-mt4-doge-data" "$out"
else
  printf '  skip docker compose (not installed)\n'
fi

echo "dokploy-apply"
# The provisioner is what makes the server side clickless, so it is worth knowing
# it still speaks the API the way Dokploy expects. mock-dokploy.py stands in for
# the instance. It is run twice: the second run has to find what the first made
# rather than create a second app, and that is what makes it safe on every push.
DOKPLOY="$HERE/dokploy-apply.sh"
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -x "$DOKPLOY" ]; then
  PORT=$((18000 + RANDOM % 2000))
  LOG="$TMP/requests.jsonl"
  MOCK_LOG="$LOG" python3 "$HERE/mock-dokploy.py" "$PORT" >"$TMP/mock.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 40); do
    curl -sf -H 'x-api-key: k' "http://127.0.0.1:$PORT/api/project.all" >/dev/null 2>&1 && break
    sleep 0.25
  done

  # Eleven values, including a password with a $, a quote and a backslash in it.
  cat > "$TMP/dokploy.env" <<'EOF'
MT4_LOGIN=5023456789
MT4_PASSWORD=pa$$w"or\d
MT4_SERVER=MetaQuotes-Demo
MT4_SYMBOL=XAUUSD
MT4_PRESET=100usd-demo
MT4_PROFILE=default
ENABLE_VNC=1
VNC_PASSWORD=vncpass
TZ=UTC
MT4_DISTRO_URL=
MT4_IMAGE=ghcr.io/owner/forex-hex-mt4:live
EOF

  for run in 1 2; do
    DOKPLOY_URL="http://127.0.0.1:$PORT" DOKPLOY_API_TOKEN=k \
      DOKPLOY_ENV_FILE="$TMP/dokploy.env" "$DOKPLOY" >"$TMP/run$run.out" 2>&1 || \
      bad "run $run exited non-zero: $(tail -1 "$TMP/run$run.out")"
  done

  count() { jq -r --arg p "$1" 'select(.path == $p) | .path' "$LOG" 2>/dev/null | wc -l | tr -d ' '; }
  check_eq "project created once, then found"   "1" "$(count /api/project.create)"
  check_eq "app created once, then found"       "1" "$(count /api/compose.create)"
  check_eq "compose file pushed on both runs"   "2" "$(count /api/compose.update)"
  check_eq "environment saved on both runs"     "2" "$(count /api/compose.saveEnvironment)"
  check_eq "deployed on both runs"              "2" "$(count /api/compose.deploy)"
  # A real instance answers 401 to a call without the key.
  check_eq "x-api-key on every call" "0" \
    "$(jq -r 'select(.api_key != "k") | .path' "$LOG" 2>/dev/null | grep -c . || true)"

  # -s (slurp) so there is one input to index into; without it jq evaluates the
  # filter once per line and a multi-line value comes back glued together.
  update="$(jq -s -c 'map(select(.path == "/api/compose.update"))[0].body' "$LOG")"
  check_eq "sourceType is raw" "raw" "$(printf '%s' "$update" | jq -r '.sourceType')"
  check_eq "composeFile carries pull_policy" "1" \
    "$(printf '%s' "$update" | jq -r '.composeFile | contains("pull_policy: always") | if . then 1 else 0 end')"
  check_eq "autoDeploy off (CI is the trigger)" "false" \
    "$(printf '%s' "$update" | jq -r '.autoDeploy // "false"')"

  saved="$(jq -s -r 'map(select(.path == "/api/compose.saveEnvironment"))[0].body.env' "$LOG")"
  check_contains "awkward password survives JSON" 'pa$$w"or\d' "$saved"
  check_eq "all eleven values sent" "11" "$(printf '%s\n' "$saved" | grep -c '=')"
else
  bad "dokploy-apply.sh not testable here (needs jq, python3, and the script)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
