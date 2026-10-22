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
load_fn "$ENTRYPOINT" profile_charts >/dev/null
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
