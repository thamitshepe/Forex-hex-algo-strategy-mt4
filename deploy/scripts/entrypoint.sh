#!/bin/bash
# HEX-BoomRider on a server: MetaTrader 5 under Wine, headless, in a container.
#
# Every start does the same five things, in this order:
#
#   1. make sure a portable MetaTrader 5 tree exists in $MT5DIR (the volume)
#   2. copy this repo's .mq5 and presets into it and compile them with the real
#      metaeditor64.exe, so the EA that runs is the EA that is in git
#   3. write mt5.ini ([Common] login/server, [Experts] autotrading on,
#      [StartUp] expert + preset + symbol + period - MT5 opens the chart and
#      attaches the expert from the config, no profile templates needed)
#   4. start Xvfb, plus x11vnc and noVNC when VNC_PASSWORD is set
#   5. run `wine terminal64.exe /portable /config:mt5.ini`, then mirror MT5's
#      journals and the EA's prints into the container log
#
# It deliberately does not restart the terminal after a crash: it exits non-zero
# so Docker's restart policy decides, and the crash stays visible in the logs.
#
# Vocabulary: "distro" is a portable MT5 directory (tarball with terminal64.exe),
# "prefix" is the Wine C: drive. In portable mode all editable data - config,
# MQL5, logs - lives in $MT5DIR itself, which is what makes it a volume.
#
# Strategy context: Boom 400 on Deriv, long-only spike rider sized against an
# effective bankroll of Equity - BaselineEquity, with a hard blow line that
# alerts and halts. The EA (MQL5/Experts/HEX-BoomRider.mq5) carries the rules;
# this script's only trading opinion is which symbol is on the chart.
set -euo pipefail

# ---------------------------------------------------------------- gosu drop --
# The Wine prefix and the volume belong to uid 1000 (trader), and wine refuses
# to touch a prefix it does not own - "wine: '/home/trader/.wine' is not owned
# by you". The image's ENTRYPOINT starts as root (tini), so the very first
# thing this script does is re-exec itself as trader, once, before anything
# else runs. Everything the container needs (credentials, URLs) is already in
# the environment and survives the exec.
if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
  # Repair volume ownership first: an earlier run that began as root (or a
  # bind mount owned by another uid) leaves /data unwritable for trader, which
  # shows up as "Permission denied" on the heartbeat and on every copy after
  # it. Named volumes inherit the image's ownership when created empty, but
  # boots before bugfixes already wrote root-owned files into them.
  chown -R trader:trader /data 2>/dev/null || true
  exec gosu trader env \
    HOME=/home/trader \
    WINEPREFIX="${WINEPREFIX:-/home/trader/.wine}" \
    DISPLAY="${DISPLAY:-:99}" \
    HEX_BUILD="${HEX_BUILD:-local}" \
    bash "$0" "$@"
fi

log()  { printf '%s [hex] %s\n'  "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '%s [hex] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s [hex] FATAL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Instances. One container is one instance: one account, one chart, one expert.
#   MT5_INSTANCE=1  ->  MT5_LOGIN,  MT5_SYMBOL,  ...
#   MT5_INSTANCE=2  ->  MT5_LOGIN2, MT5_SYMBOL2, ...
# This deployment runs exactly one instance; the machinery stays because the
# volume guard (claim_volume) is what enforces one container per volume.
# ---------------------------------------------------------------------------
MT5_INSTANCE="${MT5_INSTANCE:-1}"
case "$MT5_INSTANCE" in
  ''|*[!0-9]*) die "MT5_INSTANCE must be a number (1, 2, 3 ...), got '$MT5_INSTANCE'" ;;
  0) die "MT5_INSTANCE starts at 1" ;;
esac

# NAME<N>, else NAME (instance 1 only), else DEFAULT.
inst_var() { # NAME [DEFAULT]
  local name="$1" def="${2-}" v=""
  eval "v=\"\${${name}${MT5_INSTANCE}-}\""
  if [ -z "$v" ] && [ "$MT5_INSTANCE" = "1" ]; then
    eval "v=\"\${${name}-}\""
  fi
  [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}

shared_var() { # NAME [DEFAULT]
  local name="$1" def="${2-}" v=""
  eval "v=\"\${${name}${MT5_INSTANCE}-}\""
  [ -n "$v" ] || eval "v=\"\${${name}-}\""
  [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}

check_instance_env() {
  local name v
  [ "$MT5_INSTANCE" = "1" ] && return 0
  for name in MT5_LOGIN MT5_PASSWORD MT5_SYMBOL; do
    v="$(inst_var "$name")"
    if [ -z "$v" ]; then
      die "MT5_INSTANCE=$MT5_INSTANCE has no ${name}${MT5_INSTANCE}. ${name} alone belongs to instance 1; instance $MT5_INSTANCE must name its own account rather than borrow it."
    fi
  done
}

MT5DIR="$(shared_var MT5DIR /data/mt5)"
MT5_LOGIN="$(inst_var MT5_LOGIN)"
MT5_PASSWORD="$(inst_var MT5_PASSWORD)"
MT5_SERVER="$(inst_var MT5_SERVER)"
# Deriv's Boom indices are named with spaces: "Boom 400 Index". Default M15.
MT5_SYMBOL="$(inst_var MT5_SYMBOL "Boom 400 Index")"
MT5_PERIOD="$(inst_var MT5_PERIOD "M15")"
MT5_EXPERT="$(inst_var MT5_EXPERT "HEX-BoomRider")"
MT5_PRESET="$(inst_var MT5_PRESET "$MT5_EXPERT")"
# A portable MT5 tarball (see prepare-distro.sh). MetaQuotes' own mt5setup.exe is
# a 64-bit web installer that installs nothing under Wine, so like MT4 the
# terminal has to be supplied; without a distro the volume must already have one.
MT5_DISTRO_URL="$(shared_var MT5_DISTRO_URL)"
# The broker installer fallback: unlike MT4's setup, MT5's full installer
# (mt5setup.exe, ~23MB, https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe)
# DOES run under Wine with /auto and leaves a complete terminal64 tree behind.
# Tried after the distro; the compose file defaults it to MetaQuotes' URL.
MT5_SETUP_URL="$(shared_var MT5_SETUP_URL)"
# Minutes to keep the boot alive for a manual finish over noVNC when the
# silent /auto install does not complete on its own (default 20).
MT5_INSTALL_WAIT_MIN="$(shared_var MT5_INSTALL_WAIT_MIN 20)"
MT5_FORCE_SEED="$(shared_var MT5_FORCE_SEED 0)"
# One-shot account move for an existing volume (see claim_volume below).
MT5_RECLAIM_VOLUME="$(shared_var MT5_RECLAIM_VOLUME)"
ENABLE_VNC="$(shared_var ENABLE_VNC 1)"
VNC_PASSWORD="$(shared_var VNC_PASSWORD)"
VNC_PORT="$(shared_var VNC_PORT 5900)"
NOVNC_PORT="$(shared_var NOVNC_PORT 6080)"
SCREEN="$(shared_var SCREEN 1440x900x24)"
DISPLAY="${DISPLAY:-:99}"
export DISPLAY

export WINEPREFIX="${WINEPREFIX:-/home/trader/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
export WINEDEBUG="${WINEDEBUG:--all}"

EA_SRC="/opt/ea/${MT5_EXPERT}.mq5"
EA_BAKED_EX5="/opt/ea/${MT5_EXPERT}.ex5"

XVFB_PID=""
WM_PID=""
X11VNC_PID=""
WEBSOCKIFY_PID=""
TERMINAL_PID=""


# ------------------------------------------------------- the terminal tree ---

# terminal64.exe is the whole test. In portable mode everything else - config,
# MQL5, logs, history - lives in the same directory, which is why $MT5DIR can be
# a volume and why a distro survives a redeploy untouched.
have_terminal() { [ -f "$MT5DIR/terminal64.exe" ]; }

# --- volume ownership -------------------------------------------------------
# One container per volume, enforced, not assumed. The marker records which
# instance+account the volume belongs to; the heartbeat lease records which
# container is alive on it right now. A second container that points at a
# volume owned by somebody else is a data-corruption bug (two terminals writing
# one tree), so it is refused loudly instead.
claim_volume() {
  local marker="$MT5DIR/.hex-instance" want
  mkdir -p "$MT5DIR"
  want="${MT5_INSTANCE}:${MT5_LOGIN:-no-login}"
  if [ -f "$marker" ]; then
    local have
    have="$(cat "$marker" 2>/dev/null || true)"
    if [ "$have" = "$want" ]; then
      log "volume claimed: $marker says $have (ours)"
      return 0
    fi
    # A one-shot, deliberate account move on the SAME instance number is
    # allowed when MT5_RECLAIM_VOLUME=1. A different instance number is never
    # allowed: that is a second container after somebody else's volume.
    if [ "${MT5_INSTANCE}" = "$(printf '%s' "$have" | cut -d: -f1)" ] \
       && [ "$MT5_RECLAIM_VOLUME" = "1" ]; then
      printf '%s\n' "$want" > "$marker"
      log "re-claiming volume for instance $MT5_INSTANCE: '$have' -> '$want' (MT5_RECLAIM_VOLUME=1; unset it again after this start)"
      return 0
    fi
    die "volume at $MT5DIR is owned by '$have' but this container is '$want'.
Two MetaTrader terminals on one tree corrupt each other. If this is a deliberate
account move on the same instance, set MT5_RECLAIM_VOLUME=1 in the app's
Environment tab for ONE start, then unset it."
  fi
  printf '%s\n' "$want" > "$marker"
  log "volume claimed for instance $MT5_INSTANCE ($want)"
}

# --- the lease --------------------------------------------------------------
# The container's live-ness, on the volume: the EA's heartbeat file and this
# stamp are what healthcheck.sh reads. The entrypoint writes the first beat
# before the terminal starts so an early crash is distinguishable from silence.
write_lease() {
  # rm first: an earlier root-owned run (before the gosu drop existed) may have
  # left this file, and the directory is trader-writable so unlink works.
  rm -f "$MT5DIR/.hex-heartbeat" 2>/dev/null || true
  date -u +%s > "$MT5DIR/.hex-heartbeat" 2>/dev/null || true
}

# --- seeding ----------------------------------------------------------------
seed_distro_from_url() { # URL
  local url="$1" tarball dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/hex-distro.XXXXXX")"
  log "seeding $MT5DIR from $url"
  case "$url" in
    file:///*) tarball="${url#file://}" ;;
    *) tarball="${TMPDIR:-/tmp}/hex-distro.tar"
       curl -fsSL --retry 3 --retry-delay 5 -o "$tarball" "$url" \
         || die "download failed: $url" ;;
  esac
  case "$tarball" in
    *.zst|*.tzst) tar --use-compress-program=unzstd -xf "$tarball" -C "$dir" ;;
    *.gz|*.tgz)   tar -xzf "$tarball" -C "$dir" ;;
    *)            tar -xf  "$tarball" -C "$dir" ;;
  esac
  local src
  src="$(find "$dir" -maxdepth 4 -iname 'terminal64.exe' -print -quit 2>/dev/null)"
  [ -n "$src" ] || die "the distro has no terminal64.exe in it"
  src="${src%/terminal64.exe}"
  # Copy the tree's contents, not the dir: the volume root is $MT5DIR itself.
  cp -a "$src"/. "$MT5DIR"/
  rm -rf "$dir"
  printf '%s\n' "$url" > "$MT5DIR/.seeded-from"
  log "distro seeded (recorded in $MT5DIR/.seeded-from)"
}

# The installer is silent even when it fails, so after /auto we cannot tell a
# hidden dialog from a genuine crash. Instead of quit-looping, poll for a
# terminal64.exe under the prefix for a bounded window; whoever is watching
# noVNC can finish the install manually (or read the error dialog's text).
# The lease is refreshed every poll so the healthcheck does not harvest the
# container mid-wait.
wait_for_manual_install() {
  local deadline=$(( $(date +%s) + MT5_INSTALL_WAIT_MIN * 60 )) n=0
  log "no terminal64.exe yet. The setup window may be on the desktop: finish the install over noVNC (set VNC_PASSWORD if it is not up), or leave MT5_DISTRO_URL. Polling for ${MT5_INSTALL_WAIT_MIN} min ..."
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 15
    write_lease
    n=$((n + 1))
    if find "$WINEPREFIX/drive_c" -maxdepth 5 -iname 'terminal64.exe' -print -quit 2>/dev/null | grep -q .; then
      sleep 20 # let the installer finish writing its tree
      TERMINAL_SRC="$(find "$WINEPREFIX/drive_c" -maxdepth 5 -iname 'terminal64.exe' -print -quit 2>/dev/null || true)"
      if [ -n "$TERMINAL_SRC" ]; then
        log "terminal64.exe appeared - continuing the boot"
        return 0
      fi
    fi
    [ $((n % 4)) -eq 0 ] && log "still waiting for terminal64.exe (window: ${MT5_INSTALL_WAIT_MIN} min)"
  done
  return 1
}

# The MT5 full installer, run with /auto: it installs a complete portable tree
# (terminal64.exe, metaeditor64.exe, its own servers.ini) under the Wine prefix
# and we copy that into the volume. This is how Docker MT5 images bootstrap, and
# unlike MT4's thin web stub it actually works under Wine.
install_fresh_terminal() {
  local setup="${TMPDIR:-/tmp}/mt5setup.exe"
  log "no terminal in $MT5DIR - running the installer at $MT5_SETUP_URL"
  command -v wine >/dev/null 2>&1 \
    || die "wine is not installed - cannot run the installer; supply MT5_DISTRO_URL (a prepared portable tarball) instead"
  curl -fsSL --retry 3 --retry-delay 5 -o "$setup" "$MT5_SETUP_URL" \
    || die "download failed: $MT5_SETUP_URL"
  log "running the installer with /auto"
  local rc=0
  wine "$setup" /auto >/tmp/mt5setup.out 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "the installer exited non-zero (rc=$rc) - its own output:"
    sed 's/^/[setup] /' /tmp/mt5setup.out 2>/dev/null | tail -30 || true
  fi
  wineserver -w >/dev/null 2>&1 || true
  TERMINAL_SRC="$(find "$WINEPREFIX/drive_c" -maxdepth 5 -iname 'terminal64.exe' -print -quit 2>/dev/null || true)"

  if [ -z "$TERMINAL_SRC" ] && command -v winetricks >/dev/null 2>&1; then
    # The common silent-fail cause: a fresh prefix has no Windows core fonts,
    # and MetaQuotes' installer draws its UI before it installs anything.
    log "retrying once after winetricks corefonts"
    winetricks -q corefonts >/tmp/winetricks.out 2>&1 || true
    sed 's/^/[setup] /' /tmp/winetricks.out 2>/dev/null | tail -5 || true
    wine "$setup" /auto >>/tmp/mt5setup.out 2>&1 || true
    wineserver -w >/dev/null 2>&1 || true
    TERMINAL_SRC="$(find "$WINEPREFIX/drive_c" -maxdepth 5 -iname 'terminal64.exe' -print -quit 2>/dev/null || true)"
  fi

  if [ -z "$TERMINAL_SRC" ]; then
    # Diagnose before asking for human eyes: what did the installer leave?
    log "wine $(wine --version 2>/dev/null || echo 'unknown'); what the installer left behind:"
    ls -1 "$WINEPREFIX/drive_c" 2>/dev/null | sed 's/^/[setup]   /' || true
    ls -1 "$WINEPREFIX/drive_c/Program Files" 2>/dev/null | sed 's/^/[setup]   /' || true
    wait_for_manual_install \
      || die "the installer left no terminal64.exe and no manual install appeared within ${MT5_INSTALL_WAIT_MIN} min. Supply MT5_DISTRO_URL (a prepared portable tarball, deploy/scripts/prepare-distro.sh) instead."
  fi

  # Copy the whole installed tree: it brings metaeditor64.exe (so the EA
  # compiles at start) and the server list (so the broker's server is known).
  cp -a "$(dirname "$TERMINAL_SRC")"/. "$MT5DIR"/
  log "terminal installed from $MT5_SETUP_URL"
}

ensure_terminal() {
  if [ "$MT5_FORCE_SEED" = "1" ] && [ -n "$MT5_DISTRO_URL" ]; then
    local stamp="$MT5DIR/.seeded-from"
    if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$MT5_DISTRO_URL" ]; then
      log "MT5_FORCE_SEED=1: replacing the tree in $MT5DIR with $MT5_DISTRO_URL"
      find "$MT5DIR" -mindepth 1 -maxdepth 1 ! -name '.hex-instance' -exec rm -rf {} +
      seed_distro_from_url "$MT5_DISTRO_URL"
    else
      log "MT5_FORCE_SEED=1 but $MT5DIR is already this distro - not re-seeding"
    fi
  fi
  if have_terminal; then
    log "terminal64.exe found in $MT5DIR"
  elif [ -n "$MT5_DISTRO_URL" ]; then
    seed_distro_from_url "$MT5_DISTRO_URL"
    have_terminal || die "seeding from $MT5_DISTRO_URL produced no terminal64.exe"
  elif [ -n "$MT5_SETUP_URL" ]; then
    install_fresh_terminal
    have_terminal || die "installing from $MT5_SETUP_URL produced no terminal64.exe in $MT5DIR"
  else
    die "no terminal64.exe in $MT5DIR, and neither MT5_DISTRO_URL nor MT5_SETUP_URL is set.
Supply a portable distro (MT5_DISTRO_URL, deploy/scripts/prepare-distro.sh) or let
the container install MetaTrader 5 itself (MT5_SETUP_URL, e.g.
https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe)."
  fi
}

# ------------------------------------------------------- the expert and EA ---

# The repo's .mq5 and .set go into the volume, so what runs is what is in git.
# MT5 layout: MQL5/Experts for the EA, MQL5/Presets for its inputs.
sync_ea() {
  local dest_mq5="$MT5DIR/MQL5/Experts" dest_set="$MT5DIR/MQL5/Presets"
  mkdir -p "$dest_mq5" "$dest_set" "$MT5DIR/MQL5/Files/HEX-Logs"
  if [ ! -f "$EA_SRC" ]; then
    die "the image has no $EA_SRC - the Dockerfile must copy it in"
  fi
  cp -f "$EA_SRC" "$dest_mq5/"
  log "synced $(basename "$EA_SRC") into the volume"
  if compgen -G "/opt/ea/presets/${MT5_PRESET}.set" >/dev/null; then
    cp -f "/opt/ea/presets/${MT5_PRESET}.set" "$dest_set/"
    log "synced preset ${MT5_PRESET}.set into the volume"
  else
    warn "preset /opt/ea/presets/${MT5_PRESET}.set does not exist - the EA will run on its input defaults"
  fi
}

# Compile the EA with the real metaeditor64.exe so the .ex5 in the volume is
# built from the .mq5 in git. The CI build ships a .ex5 in /opt/ea-built when it
# had a terminal to compile with; that is the fallback when a runtime compile
# cannot run (e.g. the volume's distro has no metaeditor64.exe).
compile_ea() {
  local exe="$MT5DIR/metaeditor64.exe"
  local target="$MT5DIR/MQL5/Experts/${MT5_EXPERT}.mq5"
  local out="$MT5DIR/MQL5/Experts/${MT5_EXPERT}.ex5"
  rm -f "$out"
  if [ -f "$exe" ]; then
    log "compiling ${MT5_EXPERT}.mq5 with metaeditor64.exe"
    # metaeditor64 /compile:<path> writes <name>.log next to the source unless
    # /log:<path> is given. GUI app, exits when told to compile. /portable makes
    # it resolve #include inside this tree's MQL5/Include; without it the
    # editor looks in the Wine roaming data folder, which is empty. The belt
    # covers the case where /portable alone is not enough for this build:
    # copy the tree's Include into the roaming Terminal folder re-found at
    # runtime and compile again without the switch.
    (cd "$MT5DIR" && wine metaeditor64.exe /portable "/compile:MQL5\\Experts\\${MT5_EXPERT}.mq5" "/log:MQL5\\Experts\\compile.log" >/dev/null 2>&1 || true)
    wineserver -w >/dev/null 2>&1 || true
    if [ ! -f "$out" ]; then
      local td h
      td="$(find "$WINEPREFIX/drive_c/users" -maxdepth 7 -type d -name 'Terminal' -path '*MetaQuotes/Terminal' -print -quit 2>/dev/null || true)"
      if [ -n "$td" ]; then
        log "/portable compile miss - populating the roaming Include folder and retrying"
        for h in "$td"/*/; do
          [ -d "$h" ] || continue
          mkdir -p "$h/MQL5"
          cp -a "$MT5DIR/MQL5/Include" "$h/MQL5/" 2>/dev/null || true
        done
        (cd "$MT5DIR" && wine metaeditor64.exe "/compile:MQL5\\Experts\\${MT5_EXPERT}.mq5" "/log:MQL5\\Experts\\compile.log" >/dev/null 2>&1 || true)
        wineserver -w >/dev/null 2>&1 || true
      fi
    fi
    if [ -f "$out" ]; then
      log "compiled OK: $(basename "$out") (log: MQL5/Experts/compile.log)"
      return 0
    fi
    warn "runtime compile produced no .ex5 - log follows (if any)"
    sed 's/^/  [compile] /' "$MT5DIR/MQL5/Experts/compile.log" 2>/dev/null | tail -15 || true
  else
    warn "no metaeditor64.exe in the volume - cannot compile at start"
  fi
  if [ -f "$EA_BAKED_EX5" ]; then
    cp -f "$EA_BAKED_EX5" "$out"
    log "using the .ex5 compiled during the image build ( $(basename "$EA_BAKED_EX5") )"
    return 0
  fi
  die "no compiled ${MT5_EXPERT}.ex5: the runtime compile failed (see above) and this image has no baked-in copy. Fix the MQL5 or build the image with MT5_DISTRO_URL set so the ea-check stage can compile."
}

# ------------------------------------------------------------- start config --
# MT5 reads a start configuration from /config:<file>. This is what makes the
# first boot unattended, which MT4 could never fully do:
#
#   [Common]   Login/Password/Server  -> logs the account in (autologin)
#   [Experts]  Enabled=1              -> AutoTrading on at start
#   [StartUp]  Expert/ExpertParameters/Symbol/Period
#                                 -> opens ONE chart on the symbol, attaches
#                                    the expert with the preset's inputs
write_mt5_ini() {
  local ini="$MT5DIR/mt5.ini"
  {
    echo "[Common]"
    [ -n "$MT5_LOGIN" ]    && echo "Login=$MT5_LOGIN"
    [ -n "$MT5_PASSWORD" ] && echo "Password=$MT5_PASSWORD"
    [ -n "$MT5_SERVER" ]   && echo "Server=$MT5_SERVER"
    echo ""
    echo "[Experts]"
    echo "Enabled=1"
    echo "AllowLiveTrading=1"
    echo "AllowDllImport=0"
    echo ""
    echo "[StartUp]"
    echo "Expert=${MT5_EXPERT}"
    echo "ExpertParameters=${MT5_PRESET}.set"
    echo "Symbol=${MT5_SYMBOL}"
    echo "Period=${MT5_PERIOD}"
  } > "$ini"
  chmod 600 "$ini"   # it holds the account password
  log "mt5.ini: server=${MT5_SERVER:-<from volume>} symbol=$MT5_SYMBOL period=$MT5_PERIOD expert=$MT5_EXPERT preset=$MT5_PRESET"
  [ -n "$MT5_LOGIN" ]    || warn "MT5_LOGIN is empty - MT5 will wait at its login dialog (visible on the VNC desktop)"
  [ -n "$MT5_PASSWORD" ] || warn "MT5_PASSWORD is empty - the terminal cannot log in by itself"
  [ -n "$MT5_SERVER" ]   || warn "MT5_SERVER is empty - using the server saved on this volume"
}


# ------------------------------------------------------- desktop and launch --

start_desktop() {
  Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  sleep 1
  openbox >/tmp/openbox.log 2>&1 &
  WM_PID=$!
  log "virtual desktop: Xvfb on $DISPLAY ($SCREEN)"
  # An unauthenticated VNC on a public host is a trading terminal anyone can
  # drive. Refuse, loudly, rather than publish one and hope the firewall is
  # doing its job.
  if [ "$ENABLE_VNC" != "1" ]; then
    log "remote desktop: disabled (ENABLE_VNC != 1)"
    return 0
  fi
  if [ -z "$VNC_PASSWORD" ]; then
    warn "ENABLE_VNC=1 but VNC_PASSWORD is empty - refusing to publish an unauthenticated desktop"
    return 0
  fi
  x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -passwd "$VNC_PASSWORD" \
    -forever -shared -nolookup -o /tmp/x11vnc.log >/dev/null 2>&1 &
  X11VNC_PID=$!
  sleep 1
  websockify --web=/usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT" \
    >/tmp/novnc.log 2>&1 &
  WEBSOCKIFY_PID=$!
  log "remote desktop: http://<this-host>:$NOVNC_PORT/vnc.html  (or tunnel it: ssh -L $NOVNC_PORT:localhost:$NOVNC_PORT user@server)"
}

launch_terminal() {
  cd "$MT5DIR"
  # /portable keeps config, MQL5 and logs next to terminal64.exe instead of the
  # Wine user's AppData, which is what makes $MT5DIR a self-contained volume.
  wine terminal64.exe /portable /config:mt5.ini >>/tmp/terminal.out 2>&1 &
  TERMINAL_PID=$!
  log "terminal64.exe started (pid $TERMINAL_PID)"
}

wait_for_terminal() {
  for _ in $(seq 1 90); do
    if pgrep -f 'terminal64\\.exe' >/dev/null; then
      log "terminal64.exe is up"
      return 0
    fi
    sleep 2
  done
  warn "terminal64.exe did not appear within 3 minutes - see /tmp/terminal.out"
}

# MT5 buffers its journals to disk and only flushes them out periodically, so
# `docker logs` would otherwise show nothing for minutes. This polls the two log
# folders and re-prints new lines, surviving a day rollover and a truncated
# file. Anything already in the folder when this starts belongs to a previous
# run and is not replayed (a restart that reprinted it showed a second "loaded
# successfully" that read like a double expert load). Bash 3.2 safe: per-file
# counters on disk, no associative arrays.
mirror_dir() {
  local tag="$1" dir="$2"
  set +e
  set +o pipefail
  local state="${TMPDIR:-/tmp}/hex-mirror$(printf '%s' "$dir" | tr -c 'A-Za-z0-9' '_')" f n seen
  mkdir -p "$state" 2>/dev/null || true
  seen=0
  for f in "$dir"/*.log; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$n" > "$state/$(basename "$f").seen" 2>/dev/null || true
    seen=$((seen + n))
  done
  if [ "$seen" -gt 0 ]; then
    printf '%s %s line(s) from the previous run are already in %s - not replayed, the file is on the volume\\n' \
      "$tag" "$seen" "$dir"
  fi
  # Also mirror the EA's own CSV folder, so trades are visible in docker logs.
  local ea_dir="$MT5DIR/MQL5/Files/HEX-Logs" ef en
  local ea_state="$state/ea"
  mkdir -p "$ea_state" 2>/dev/null || true
  for ef in "$ea_dir"/*.csv "$ea_dir"/*.txt; do
    [ -f "$ef" ] || continue
    en=$(wc -l < "$ef" 2>/dev/null | tr -d '[:space:]'); en=${en:-0}
    case "$en" in ''|*[!0-9]*) en=0 ;; esac
    printf '%s\\n' "$en" > "$ea_state/$(basename "$ef").seen" 2>/dev/null || true
  done
  while :; do
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      p=$(cat "$state/$(basename "$f").seen" 2>/dev/null | tr -d '[:space:]')
      case "$p" in ''|*[!0-9]*) p=0 ;; esac
      [ "$n" -lt "$p" ] && p=0
      if [ "$n" -gt "$p" ]; then
        tail -n "+$((p + 1))" "$f" 2>/dev/null | sed "s/^/[$tag] /"
        printf '%s\\n' "$n" > "$state/$(basename "$f").seen" 2>/dev/null || true
      fi
    done
    for ef in "$ea_dir"/*.csv "$ea_dir"/*.txt; do
      [ -f "$ef" ] || continue
      en=$(wc -l < "$ef" 2>/dev/null | tr -d '[:space:]'); en=${en:-0}
      case "$en" in ''|*[!0-9]*) en=0 ;; esac
      p=$(cat "$ea_state/$(basename "$ef").seen" 2>/dev/null | tr -d '[:space:]')
      case "$p" in ''|*[!0-9]*) p=0 ;; esac
      [ "$en" -lt "$p" ] && p=0
      if [ "$en" -gt "$p" ]; then
        tail -n "+$((p + 1))" "$ef" 2>/dev/null | sed "s/^/[EA] /"
        printf '%s\\n' "$en" > "$ea_state/$(basename "$ef").seen" 2>/dev/null || true
      fi
    done
    sleep 3
  done
}


# The journal explains a failed login in one line and never names the fix.
# MT5 phrases (best-effort watch, one hint per container run):
#   "failed to connect" / "no connection"   -> server unknown or unreachable
#   "wrong login or password"/"auth failed" -> credentials
#   "invalid server data"                   -> server name spelling
journal_hints() { # DIR
  local dir="$1" state="${TMPDIR:-/tmp}/hex-hints" f n s p key lead line
  set +e
  set +o pipefail
  mkdir -p "$state" 2>/dev/null || true
  : > "$state/fired" 2>/dev/null || true
  while :; do
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      s="$state/$(basename "$f").seen"
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
      p=$(cat "$s" 2>/dev/null | tr -d '[:space:]')
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      case "$p" in ''|*[!0-9]*) p=0 ;; esac
      [ "$n" -lt "$p" ] && p=0
      if [ "$n" -gt "$p" ]; then
        tail -n "+$((p + 1))" "$f" 2>/dev/null | while IFS= read -r line; do
          key=""; lead=""
          case "$line" in
            *"no connection"*|*"failed to connect"*)
              key=connect
              lead="the terminal could not reach ${MT5_SERVER:-the server} with login ${MT5_LOGIN:-<none>}. This tree came from one broker's terminal - a server name it has never seen fails exactly like this, right password or not. Open the desktop (VNC) once and add the server through File -> Open an Account, or reseed with a distro prepared from a Deriv MT5 terminal." ;;
            *"wrong login"*|*"authorization failed"*|*"auth failed"*)
              key=account
              lead="the broker answered and refused login ${MT5_LOGIN:-<none>} - wrong number or password, or the demo account has expired. Check MT5_PASSWORD${MT5_INSTANCE} character by character (a trailing space counts) and whether the demo is still open." ;;
            *"invalid server"*)
              key=server
              lead="the broker has no server called ${MT5_SERVER:-<none>} - take the exact spelling from Deriv's MT5 server list (e.g. Deriv-Demo)." ;;
            *"account disabled"*|*"account banned"*)
              key=disabled
              lead="the broker has disabled ${MT5_LOGIN:-<none>}. Nothing in this container can undo that; it has to be re-enabled in the broker's portal." ;;
          esac
          [ -n "$key" ] || continue
          grep -qx "$key" "$state/fired" 2>/dev/null && continue
          printf '%s\n' "$key" >> "$state/fired" 2>/dev/null || true
          log "HINT: $lead"
        done
      fi
      printf '%s\n' "$n" > "$s" 2>/dev/null || true
    done
    sleep 3
  done
}

# Keep the lease fresh so healthcheck's "container alive" evidence is ours too.
lease_keeper() {
  while :; do
    write_lease
    sleep 60
  done
}

banner() {
  local build="${HEX_BUILD:-unknown}"
  echo "=================================================================="
  echo " HEX-BoomRider (MetaTrader 5, Wine, portable)  build: $build"
  echo " account : ${MT5_LOGIN:-<unset>} @ ${MT5_SERVER:-<from volume>}"
  echo " chart   : $MT5_SYMBOL $MT5_PERIOD   expert: $MT5_EXPERT ($MT5_PRESET.set)"
  echo " data dir: $MT5DIR   instance: $MT5_INSTANCE"
  echo " logs    : $MT5DIR/MQL5/Files/HEX-Logs (CSV, heartbeat, BLOWN marker)"
  echo "=================================================================="
}

report_isolation() {
  # What "is this container alone on its volume" looks like from the outside.
  if [ -f "$MT5DIR/.hex-instance" ]; then
    log "volume owner: $(cat "$MT5DIR/.hex-instance")"
  fi
}

main() {
  check_instance_env
  banner
  mkdir -p "$MT5DIR"
  claim_volume
  write_lease
  # The desktop comes up BEFORE the terminal is sourced: the installer and the
  # compiler are Windows GUI programs - Wine needs a display even for /auto.
  start_desktop
  ensure_terminal
  sync_ea
  compile_ea
  write_mt5_ini
  launch_terminal
  wait_for_terminal
  report_isolation
  lease_keeper &
  mirror_dir "MT5" "$MT5DIR/logs" &
  journal_hints "$MT5DIR/logs" &
  # Wait on the terminal: when it dies, tear the desktop down and exit non-zero
  # so Docker's restart policy decides. No silent self-restarts.
  set +e
  wait "$TERMINAL_PID"
  local rc=$?
  set -e
  log "terminal64.exe exited (rc=$rc) - stopping the container"
  [ -n "$X11VNC_PID" ]    && kill "$X11VNC_PID"    2>/dev/null
  [ -n "$WEBSOCKIFY_PID" ] && kill "$WEBSOCKIFY_PID" 2>/dev/null
  [ -n "$WM_PID" ]        && kill "$WM_PID"        2>/dev/null
  [ -n "$XVFB_PID" ]      && kill "$XVFB_PID"      2>/dev/null
  exit "$rc"
}

main "$@"

