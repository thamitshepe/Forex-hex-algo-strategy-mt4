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
MT5_SERVER=Deriv-Demo; MT5_SYMBOL="Boom 400 Index"; MT5_PERIOD=M15
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
  check_contains "symbol with spaces" "Symbol=Boom 400 Index"       "$(cat "$ini")"
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
if pgrep -f 'terminal64\\.exe' >/dev/null 2>&1; then
  date +%s > "$LOGDIR/HEX-BoomRider-heartbeat.txt"
  out="$("$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
  check_eq "fresh heartbeat is healthy" "0" "$rc"
  check_contains "and says so" "EA heartbeat" "$out"
  touch -t "$(date -v-4H +%Y%m%d%H%M 2>/dev/null || date -d '4 hours ago' +%Y%m%d%H%M)" \
    "$LOGDIR/HEX-BoomRider-heartbeat.txt"
  out="$("$HEALTHCHECK" 2>&1)" && rc=0 || rc=$?
  check_eq "stale heartbeat is unhealthy" "1" "$rc"
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
  check_contains "Deriv's Boom 400 is the default symbol" "Boom 400 Index" "$out"
  check_contains "the EA the image ships is attached" "HEX-BoomRider" "$out"
  check_contains "the port a domain proxies to" '6080' "$out"
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

echo "the EA carries the bankroll rule"
EA="$HERE/../../MQL5/Experts/HEX-BoomRider.mq5"
if [ -f "$EA" ]; then
  check_contains "blow line defaults to 9990" "InpBaselineEquity = 9990.0" "$(cat "$EA")"
  check_contains "effective bankroll is equity - baseline" "equity - InpBaselineEquity" "$(cat "$EA")"
  check_contains "the blow alert pushes to the phone" "SendNotification" "$(cat "$EA")"
  check_contains "and writes a marker so the halt survives restarts" "BlownMarkerExists" "$(cat "$EA")"
  check_eq "preset exists beside it" "1" \
    "$([ -f "$HERE/../../MQL5/Presets/HEX-BoomRider.set" ] && echo 1)"
else
  bad "EA exists at MQL5/Experts/HEX-BoomRider.mq5"
fi
check_eq "backtest still compiles" "0" \
  "$(python3 -m py_compile "$HERE/../../Tools/boom_backtest.py" >/dev/null 2>&1 && echo 0 || echo 1)"


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

