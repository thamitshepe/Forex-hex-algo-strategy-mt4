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
# Deriv's Boom indices carry the Volatility prefix: the account's own symbol
# history folder is "Volatility Boom 400 Index". The name in a [StartUp] Symbol=
# line has to match the broker's symbol exactly - a name that does not exist
# opens a chart that never synchronizes, and the terminal then deletes the
# expert after five minutes without ever calling OnInit. Default M15.
MT5_SYMBOL="$(inst_var MT5_SYMBOL "Volatility Boom 400 Index")"
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
       # fetch-distro.sh retries the release front door and then falls back to
       # GitHub's API asset endpoint: on 2026-11-08 the front door answered 504 to
       # every attempt for over an hour while the asset was fine, and two image
       # builds died on it. The plain curl below is the fallback for a build that
       # does not carry the script (a dev machine).
       if [ -x /opt/hex/fetch-distro.sh ]; then
         /opt/hex/fetch-distro.sh "$url" "$tarball" || die "download failed: $url"
       else
         curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 20 \
           -o "$tarball" "$url" \
           || die "download failed: $url"
       fi ;;
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
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 20 \
    -o "$setup" "$MT5_SETUP_URL" \
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

# ---------------------------------------------------- one chart, always -------
# MT5 restores the desktop it saved on shutdown and THEN applies [StartUp], so
# every start adds a chart to the ones already there. A volume that restarts (a
# feed stall, a deploy, a boot loop) therefore accumulates them: by 2026-11-08
# the noVNC desktop carried several, each restored chart re-attaching its own
# copy of the expert out of the profile - N copies of one robot on one magic
# number, and a Wine desktop painting N charts is why the browser tab felt stuck.
# This volume has exactly one chart: the one [StartUp] opens for $MT5_SYMBOL.
# Everything the terminal saved is cleared before every start, and the profile as
# it first arrived is kept in .profile-orig so the old desktop can be restored by
# hand (copy it back over profiles/).
ensure_single_chart() {
  local root dir n removed=0 detail="" roots=""
  for root in "$MT5DIR/profiles" "$MT5DIR/Profiles"; do
    [ -d "$root" ] && roots="$roots $root"
  done
  if [ -z "$roots" ]; then
    log "no desktop profile on the volume yet - [StartUp] opens the only chart"
    return 0
  fi
  for root in $roots; do
    if [ ! -d "$MT5DIR/.profile-orig" ]; then
      mkdir -p "$MT5DIR/.profile-orig.part" 2>/dev/null || true
      if cp -a "$root/." "$MT5DIR/.profile-orig.part/" 2>/dev/null &&
         mv "$MT5DIR/.profile-orig.part" "$MT5DIR/.profile-orig" 2>/dev/null; then
        log "kept the profile that shipped on this volume in .profile-orig (copy it back over $root to get the old desktop)"
      else
        rm -rf "$MT5DIR/.profile-orig.part" 2>/dev/null || true
        warn "could not keep a copy of $root (read-only or full volume?) - clearing it anyway"
      fi
    fi
    for dir in "$root"/*; do
      [ -d "$dir" ] || continue
      n=$(find "$dir" -maxdepth 1 -type f -name 'chart*.chr' 2>/dev/null | wc -l | tr -d '[:space:]' || true)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      [ "$n" -gt 0 ] || continue
      find "$dir" -maxdepth 1 -type f -name 'chart*.chr' -delete 2>/dev/null || true
      removed=$((removed + n))
      detail="$detail $(basename "$dir"):$n"
    done
    chown -R trader:trader "$root" 2>/dev/null || true
  done
  if [ "$removed" -gt 0 ]; then
    log "cleared $removed saved chart(s) from the desktop profile (${detail# }) - the terminal opens exactly one, the one [StartUp] makes for $MT5_SYMBOL"
  else
    log "the desktop profile carries no saved chart - [StartUp] opens the only one"
  fi
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

# The window manager, started the one way that can fail loudly. openbox exits at
# once if the display is not accepting connections yet, and a desktop with no
# window manager is the noVNC tab that "freezes": the charts are drawn, but no
# window can be focused, moved or closed, so no dialog can be dismissed - and the
# keeper below used to relaunch it into the same race, forever.
start_wm() {
  openbox >>/tmp/openbox.log 2>&1 &
  WM_PID=$!
  sleep 1
  if kill -0 "$WM_PID" 2>/dev/null; then
    return 0
  fi
  WM_PID=""
  warn "openbox did not stay up - this desktop has no window manager (that is the frozen noVNC tab). Its own log:"
  tail -n 8 /tmp/openbox.log 2>/dev/null | sed 's/^/  [openbox] /' || true
  return 1
}

start_desktop() {
  Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  # Xvfb publishes /tmp/.X11-unix/X<n> when it is ready to accept clients. A WM
  # started before that exits immediately - which is how this desktop ended up
  # with none at all. sleep 1 was a guess; the socket is the signal.
  local sock="/tmp/.X11-unix/X${DISPLAY#:}" waited=0
  while [ ! -S "$sock" ] && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if [ ! -S "$sock" ]; then
    warn "Xvfb never published $sock - the desktop will not come up. Its own log:"
    tail -n 8 /tmp/xvfb.log 2>/dev/null | sed 's/^/  [xvfb] /' || true
  fi
  start_wm || true
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
  # WINEDEBUG=+err overrides the image's -all for this one process: the
  # terminal's own crash text must reach the log even when wine is quiet.
  WINEDEBUG=+err wine terminal64.exe /portable /config:mt5.ini >>/tmp/terminal.out 2>&1 &
  TERMINAL_PID=$!
  log "terminal64.exe started (pid $TERMINAL_PID)"
}

wait_for_terminal() {
  # The bracket class matters: 'terminal64\\.exe' means a literal BACKSLASH in
  # the ERE pgrep applies to the command line, and no command line has one - a
  # perfectly healthy terminal was invisible to this check. [.] cannot be
  # misread. 150 x 2s = patient for a first boot after seeding.
  for _ in $(seq 1 150); do
    if pgrep -f 'terminal64[.]exe' >/dev/null; then
      log "terminal64.exe is up"
      return 0
    fi
    sleep 2
  done
  warn "terminal64.exe did not appear within 5 minutes - the evidence follows"
  sed 's/^/  [term] /' /tmp/terminal.out 2>/dev/null | tail -25 || true
  ps -ef 2>/dev/null | grep -i -e wine -e terminal | grep -v grep | head -6 | sed 's/^/  [ps] /' || true
  ls -la "$MT5DIR/logs/" 2>/dev/null | tail -5 | sed 's/^/  [logs] /' || true
  local f
  for f in "$MT5DIR"/logs/*.log; do
    [ -f "$f" ] || continue
    echo "  [journal] $(basename "$f"):"
    tail -15 "$f" 2>/dev/null | sed 's/^/    /'
  done
  log "HINT: a terminal64.exe that dies in seconds under wine is usually a font or a prefix problem - the [term] lines above name it"
}

# MT5 buffers its journals to disk and only flushes them out periodically, so
# `docker logs` would otherwise show nothing for minutes. This polls the two log
# folders and re-prints new lines, surviving a day rollover and a truncated
# file. Anything already in the folder when this starts belongs to a previous
# run and is not replayed (a restart that reprinted it showed a second "loaded
# successfully" that read like a double expert load). Bash 3.2 safe: the
# follow list is one string - no associative arrays, nothing on disk.
mirror_dir() {
  local tag="$1" dir="$2" csv="${3:-yes}" ea_dir="$MT5DIR/MQL5/Files/HEX-Logs"
  set +e
  set +o pipefail
  # Anything already in the folder when this starts belongs to a previous run:
  # report it, never replay it. Then follow the files instead of re-counting them
  # every few seconds. The old per-file .seen counters lived in files: when one
  # could not be written the count stayed at 0 and the whole journal was printed
  # again on every pass - the 3-second echo loop that buried the log on
  # 2026-11-02, reading the volume to do it. tail -F starts at the same offset,
  # never replays, survives a rotated file, and needs no state at all.
  local seen=0 f n ef en sedu="sed"
  # Line-buffered sed, so a sparse journal line shows up in docker logs at once
  # instead of sitting in a 4K block buffer. GNU sed only; macOS sed has no -u
  # and does not need it (nothing there pipes into a log collector).
  sed -u '' /dev/null >/dev/null 2>&1 && sedu="sed -u"
  for f in "$dir"/*.log; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    seen=$((seen + n))
  done
  if [ "$seen" -gt 0 ]; then
    printf '%s %s line(s) from the previous run are already in %s - not replayed, the file is on the volume\n' \
      "$tag" "$seen" "$dir"
  fi
  # Follow, don't re-count. New files - the journal rotates at midnight, the EA
  # writes a fresh CSV - are picked up by the loop below.
  local followed=" "
  while :; do
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      case "$followed" in *" $(basename "$f") "*) continue ;; esac
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      tail -n "+$((n + 1))" -F "$f" 2>/dev/null | $sedu "s/^/[$tag] /" &
      followed="$followed$(basename "$f") "
    done
    if [ "$csv" = "yes" ]; then
    for ef in "$ea_dir"/*.csv "$ea_dir"/*.txt; do
      [ -f "$ef" ] || continue
      case "$followed" in *" $(basename "$ef") "*) continue ;; esac
      en=$(wc -l < "$ef" 2>/dev/null | tr -d '[:space:]'); en=${en:-0}
      case "$en" in ''|*[!0-9]*) en=0 ;; esac
      tail -n "+$((en + 1))" -F "$ef" 2>/dev/null | $sedu "s/^/[EA] /" &
      followed="$followed$(basename "$ef") "
    done
    fi
    sleep 20
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
          # "MQL5.community authorization failed" is MetaQuotes' community login
          # (the MCP server, Tools > Options > Community), not the broker. On
          # 2026-11-06 it fired this hint eight times during a boot loop while the
          # very same MT5_PASSWORD logged in on the ninth start at 03:40:47 - a
          # hint that names the wrong fix is worse than none, it sends the
          # operator to retype a password that was never wrong (and the pushes
          # it spends are the alerts they did not get).
          case "$line" in *MQL5.community*) continue ;; esac
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

# The EA's worst failure mode has no EA-side fix: the terminal attaches the
# expert to the chart before the symbol has any data, waits 5 minutes for the
# symbol to synchronize, gives up, and REMOVES the expert - and never retries.
# Watch for that exact journal line and restart the terminal so it re-attaches;
# boot after seed is fast and each attempt leaves the downloaded symbol data on
# the volume, so attempt 2 or 3 usually sticks. Bounded: after N fails the
# desktop itself is the tool - open Market Watch, find the symbol, make its
# price move, then Ctrl+E the expert back on.
mql_tail() {
  local d="$MT5DIR/MQL5/Logs" f last=""
  for f in "$d"/*.log; do
    [ -f "$f" ] || continue
    last="$f"
  done
  [ -n "$last" ] || { printf '%s' "no MQL5 log yet"; return 0; }
  tail -n 3 "$last" 2>/dev/null | tr -d '\r' | tr '\n' ' '
}

ea_watchdog() { # DIR
  # Two ways the EA leaves the chart, and both are silent in every other signal:
  # the symbol never synchronizes ("symbol synchronization timeout"), or the
  # terminal unloads the program after a critical error - the bare "expert ...
  # removed" line, whose reason is written only to the MQL5 log. Restart the
  # terminal for either. The offset lives in memory, so no counter on disk can
  # go stale and re-fire the same restart every few seconds.
  local dir="$1" cur="" off_file="" off=0 n f line tries=0 last=0 now
  set +e
  set +o pipefail
  while :; do
    # The journal the terminal is WRITING, chosen by mtime. The glob alone is
    # sorted by name, and a name is not a time: a volume that also holds a
    # journal for another day (a distro baked earlier, a clock that was off, a
    # copy someone made) hands back a file nothing appends to any more, and a
    # watchdog reading a quiet file never fires - which is one way the removal
    # line at 2026-11-06 03:53:50 went unanswered for two days.
    cur=""
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      if [ -z "$cur" ] || [ "$(file_mtime "$f")" -ge "$(file_mtime "$cur")" ]; then
        cur="$f"
      fi
    done
    if [ -z "$cur" ]; then
      sleep 5
      continue
    fi
    if [ "$cur" != "$off_file" ]; then
      off_file="$cur"
      off=$(wc -l < "$cur" 2>/dev/null | tr -d '[:space:]'); off=${off:-0}
      case "$off" in ''|*[!0-9]*) off=0 ;; esac
    fi
    n=$(wc -l < "$cur" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -lt "$off" ] && off=0
    if [ "$n" -gt "$off" ]; then
      while IFS= read -r line; do
        case "$line" in
          *'symbol synchronization timeout'*|*'expert '*removed*)
            now=$(date +%s)
            # The restart budget belongs to an incident, not to the container:
            # after ten quiet minutes a fresh removal gets a fresh set of tries
            # instead of going straight to "needs you".
            [ "$last" -gt 0 ] && [ $((now - last)) -gt 600 ] && tries=0
            last="$now"
            tries=$((tries + 1))
            log "WATCHDOG: the EA left the chart (attempt $tries/6): $line"
            if [ "$tries" -le 6 ]; then
              hex_push "EA-RESTART" "The EA was removed on $MT5_SYMBOL (attempt $tries/6 to put it back). Terminal is being restarted. MQL5 log: $(mql_tail)"
              sleep 3
              kill "$TERMINAL_PID" 2>/dev/null || true
            else
              log "WATCHDOG: 6 automatic EA restarts did not stick. Last MQL5 log: $(mql_tail)"
              hex_push "NEEDS-YOU" "6 automatic restarts did not keep the EA on $MT5_SYMBOL. MQL5 log: $(mql_tail) Open the VNC desktop if this keeps happening."
              sleep 900
            fi
            ;;
        esac
      done < <(tail -n "+$((off + 1))" "$cur" 2>/dev/null)
      off="$n"
    fi
    sleep 5
  done
}

# A dead window manager or a dead VNC bridge looks identical to "the EA is
# broken" from a browser - and nobody can click through it. Revive the pieces
# whose death does not mean the terminal should restart.
#
# Liveness is a PID, not a pgrep: `kill -0` cannot miss a process that exists,
# and the fallback ADOPTS an openbox it did not start instead of launching a
# second one. Two window managers on one X display is a desktop nobody can
# click - and the old pgrep-only check could produce exactly that.
wm_alive() {
  if [ -n "$WM_PID" ] && kill -0 "$WM_PID" 2>/dev/null; then
    return 0
  fi
  WM_PID=$(pgrep -x openbox 2>/dev/null | head -1 || true)
  [ -n "$WM_PID" ]
}

desktop_keeper() {
  local want_vnc=0
  if [ -n "${VNC_PASSWORD:-}" ]; then
    want_vnc=1
  fi
  while :; do
    if ! wm_alive; then
      log "WATCHDOG: openbox is gone - relaunching (without a window manager the noVNC desktop cannot be clicked)"
      start_wm || true
    fi
    if [ "$want_vnc" -eq 1 ] && ! pgrep -f 'x11vnc' >/dev/null; then
      log "WATCHDOG: x11vnc died - relaunching (the noVNC tab stays blank until it is back)"
      x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -passwd "$VNC_PASSWORD" \
        -forever -shared -nolookup -o /tmp/x11vnc.log >/dev/null 2>&1 &
      X11VNC_PID=$!
    fi
    if [ "$want_vnc" -eq 1 ] && ! pgrep -f 'websockify' >/dev/null; then
      log "WATCHDOG: websockify died - relaunching (refresh the noVNC tab afterwards)"
      websockify --web=/usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT" \
        >/tmp/novnc.log 2>&1 &
      WEBSOCKIFY_PID=$!
    fi
    sleep 20
  done
}

# ---------------------------------------------------------------- pushes ---
# Notifications are sent from the CONTAINER, not from MQL5. MT5's WebRequest
# refuses any URL that is not whitelisted in Tools > Options > Expert Advisors,
# and that whitelist can only be filled by clicking in the GUI - exactly what a
# headless box must not depend on. curl has no such gate.
hex_push() { # TITLE BODY
  [ -n "${MT5_NOTIFY_URL:-}" ] || return 0
  local title="$1" body="$2" code dir stamp last now
  # One push per title per HEX_PUSH_REPEAT_SEC (default 300). On 2026-11-06 the
  # container booted nine times in two minutes and each boot pushed UP plus the
  # login HINT: sixteen requests, ntfy answered 429 to everything after the
  # first batch, and the pushes that mattered - SKIP at 03:46, DEINIT at 03:53,
  # NOT-RUNNING at 04:15 - were the ones dropped. A container that is crashing
  # is exactly when the phone has to still work.
  #
  # Trade events are never throttled: an ADD or a CLOSE that arrives five
  # minutes late is worse than a duplicate, and the EA itself already throttles
  # the ones that could repeat (SKIP once per reason, FEED on the first tick
  # back). The stamp is written before the curl, so a title also repeats at most
  # once per window when the topic is refusing them - hammering a 429 extends it.
  case " BUY CLOSE ADD BLOWN ERROR FEED DEINIT " in
    *" $title "*) ;;
    *)
      now=$(date +%s)
      dir="$MT5DIR/.hex-pushes"
      mkdir -p "$dir" 2>/dev/null || true
      stamp="$dir/$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '_')"
      last=$(cat "$stamp" 2>/dev/null | tr -d '[:space:]')
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "${HEX_PUSH_REPEAT_SEC:-300}" ]; then
        log "push held ($title): the same title went out $(( now - last ))s ago - not spending the topic's quota on a repeat"
        return 0
      fi
      printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
      ;;
  esac
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Title: HEX-BoomRider $title" \
    -H "Content-Type: text/plain" \
    -H "Tags: chart_with_upwards_trend" \
    --data-binary "$body" "$MT5_NOTIFY_URL" 2>/dev/null) || code=000
  case "$code" in
    2*) log "push sent ($title)" ;;
    *)  warn "push FAILED ($title): HTTP $code from $MT5_NOTIFY_URL" ;;
  esac
}

# Turn the EA's own CSV rows into phone pushes. The EA writes one row per
# event (INIT / BUY / CLOSE / ADD / LOCKIN / TRAIL / EPISODE / BLOWN / SKIP /
# ERROR / FEED / DEINIT): BUY, CLOSE, ADD, BLOWN, ERROR, FEED and DEINIT are
# forwarded every time, and the first SKIP of each distinct reason once per run -
# so a quiet market does not spam the phone, but "nothing is trading" is never
# silent either. ADD is the one to watch for: it is the EA putting a second
# (third, fourth) leg on a trade that is already in profit, i.e. a spike being
# multiplied. FEED is the opposite: ticks stopped arriving. DEINIT says the EA
# left the chart, with the reason the terminal never states on its own.
push_watcher() {
  local ea_dir="$MT5DIR/MQL5/Files/HEX-Logs"
  local followed=" " f n line
  set +e
  set +o pipefail
  [ -n "${MT5_NOTIFY_URL:-}" ] || return 0
  # tail -F starts at the end of the file, so yesterday is not replayed
  # and no .seen counter has to be writable.
  while :; do
    for f in "$ea_dir"/*.csv; do
      [ -f "$f" ] || continue
      case "$followed" in *" $(basename "$f") "*) continue ;; esac
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      followed="$followed$(basename "$f") "
      (
        pushed=" "
        tail -n "+$((n + 1))" -F "$f" 2>/dev/null | while IFS= read -r line; do
          case "$line" in
            *,BUY,*)    hex_push "BUY"   "$line" ;;
            *,CLOSE,*)  hex_push "CLOSE" "$line" ;;
            *,ADD,*)    hex_push "ADD"   "$line (profit leg added - the spike is being multiplied)" ;;
            *,BLOWN,*)  hex_push "BLOWN" "$line" ;;
            *,ERROR,*)  hex_push "ERROR" "$line" ;;
            *,FEED,*)   hex_push "FEED"  "$line (ticks are arriving again)" ;;
            *,DEINIT,*) hex_push "DEINIT" "$line (the EA left the chart - nothing is managing the trade until it is back)" ;;
            *,SKIP,*)
              # A SKIP repeats on every tick with a risk figure that changes each
              # time, so it is deduped by shape and pushed once per reason per
              # run. Silence while nothing trades is exactly how the night of
              # 2026-11-02 went unnoticed: the EA was fine, it just could not
              # size a trade.
              k=$(printf '%s' "$line" | sed 's/[0-9][0-9.]*/#/g')
              case "$pushed" in
                *"|$k|"*) ;;
                *) pushed="$pushed|$k|"
                   hex_push "SKIP" "$line (pushed once per reason - the EA is running, it just cannot size a trade)" ;;
              esac ;;
          esac
        done
      ) &
    done
    sleep 20
  done
}

# Two helpers for reading the EA's heartbeat, used by both watchers below.
#
# `stat -c` is GNU, `stat -f` is BSD: the same file is inspected by hand on a dev
# machine, where the container's coreutils are not the ones in $PATH (healthcheck
# learned this the hard way - see the note there).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# The EA's beat is "<local time>|tick_age=<s>|equity=..|trades=..". tick_age is
# the one fact mtime cannot carry: how long the chart has gone without a tick.
# Empty output = the field is not there (an older build) and must read as
# "unknown", never as a stall - printing 0 for "I cannot tell" is how a healthy
# container becomes a restart loop.
hb_tick_age() {
  sed -n 's/.*|tick_age=\([0-9][0-9]*\)|.*/\1/p' "$1" 2>/dev/null | tail -1
}

# Any numeric field out of the same beat, so a new field costs one call instead of
# a parser per field. Empty output = the field is not in this build's beat, which
# must read as "unknown" - never as 0, and never as the failing value.
hb_field() { # FILE KEY
  sed -n "s/.*|$2=\([0-9][0-9]*\).*/\1/p" "$1" 2>/dev/null | tail -1
}

# "Trader enabled" and "robot running" are not the same thing - last night
# proved it: the EA had been removed hours earlier and the only outward sign
# was an Experts tab with nothing in it. The EA rewrites its heartbeat file
# every InpHeartbeatSec; if that file stops moving, the EA is not on the chart
# no matter what the AutoTrading button says. Buzz once, then every 6h - and
# restart the terminal, because a push is not a fix and on 2026-11-06 this
# watcher was the only thing left awake while nothing traded for two days.
#
# What "silent" can mean changed on 2026-11-02, and the two are different
# incidents this watcher may not confuse:
#   * the heartbeat stops moving   -> the EA is not being called at all: removed
#     from the chart, or its terminal thread is stuck;
#   * the beat moves, tick_age climbs -> the EA is attached and alive but the
#     CHART is not being fed (feed_watchdog below owns that one).
# The EA beats from a terminal timer now, so a stale beat can be trusted to mean
# the first case. Before that, a dead feed looked identical, and on that night
# this line blamed the chart attachment for six hours.
silence_watcher() {
  local hb="$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-heartbeat.txt"
  local state="$MT5DIR/.hex-silence"
  local limit="${HEX_SILENCE_MIN:-20}" grace="${HEX_SILENCE_GRACE_MIN:-10}"
  local age now mt warned=0 last=0 started tries=0 ts=0
  started=$(date +%s)
  set +e
  while :; do
    sleep 300
    now=$(date +%s)
    mt=0
    if [ -f "$hb" ]; then
      mt=$(file_mtime "$hb")
      case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    fi
    if [ "$mt" -gt 0 ]; then
      age=$(( (now - mt) / 60 ))
    elif [ $(( now - started )) -lt 1800 ]; then
      # No beat has ever been written on this volume. A first boot seeds the
      # terminal, synchronizes the symbol and only then loads the EA, which is
      # minutes; alarming inside that window would be a false NOT-RUNNING on
      # every fresh volume (the healthcheck says "no heartbeat yet" here too).
      continue
    else
      age=9999
    fi
    if [ "$age" -lt "$limit" ]; then
      if [ "$warned" -eq 1 ]; then
        warned=0
        log "SILENCE: heartbeat is back (${age}m old) - the EA is running again"
        hex_push "RUNNING" "EA heartbeat is back on ${MT5_SYMBOL} - the robot is trading again."
      fi
      # A beat that moves again ends the incident, so the next silence gets its
      # own three restarts (feed_watchdog's rule, for the same reason).
      rm -f "$state" 2>/dev/null || true
      continue
    fi
    if [ "$warned" -eq 0 ] || [ $(( now - last )) -ge 21600 ]; then
      warned=1; last=$now
      log "SILENCE: the EA has not written a heartbeat for ${age}m - the EA is not being called at all (off the chart, or its terminal thread is stuck). An enabled AutoTrading button does not mean the robot is attached"
      hex_push "NOT-RUNNING" "No EA heartbeat for ${age} minutes on ${MT5_SYMBOL}. The robot is not being called - nothing is trading. Check the container logs / VNC desktop. (A moving heartbeat with no ticks is a different fault: that one says FEED-STALL.)"
    fi
    # Then PUT IT BACK. Until 2026-11-06 this watcher only ever pushed, and that
    # cost two days of trading: the feed died at 03:41, MT5 unloaded the
    # expert at 03:53 ("chart closed"), and after that nothing in the container
    # restarted the terminal. The two watchdogs each deferred to the other -
    # feed_watchdog stops judging once the beat goes stale ("that is the silence
    # incident"), and this watcher, which owns that incident, had no restart in
    # it at all. Restarting the terminal is the only lever there is: mt5.ini's
    # [StartUp] opens the chart and attaches the expert on every PROCESS start,
    # and a terminal that is already up never re-reads it.
    #
    # Grace first: a container that restarted a moment ago still has the dead
    # run's heartbeat on the volume, so on the first pass the beat already looks
    # hours old. A terminal that is still booting has not had its chance
    # (login + symbol sync + expert load was 28s on 2026-11-06, minutes after a
    # bad night), and restarting it there is a restart loop with extra steps.
    if [ $(( now - started )) -lt $(( grace * 60 )) ]; then
      log "SILENCE: ${age}m without a beat, but this container is only $(( (now - started) / 60 ))m old - letting it finish booting before restarting anything"
      continue
    fi
    tries=0; ts=0
    if [ -f "$state" ]; then
      read -r tries ts < "$state" 2>/dev/null
    fi
    case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
    case "$ts"    in ''|*[!0-9]*) ts=0    ;; esac
    # The budget belongs to an incident, not to the container: thirty quiet
    # minutes after the last attempt starts a new set, the same rule ea_watchdog
    # and feed_watchdog use.
    [ "$ts" -gt 0 ] && [ $(( now - ts )) -gt 1800 ] && tries=0
    tries=$(( tries + 1 ))
    printf '%s %s\n' "$tries" "$now" > "$state" 2>/dev/null || true
    if [ "$tries" -le 3 ]; then
      log "WATCHDOG: the EA has been off the chart for ${age}m (attempt $tries/3) - restarting the terminal so [StartUp] attaches it again"
      hex_push "EA-RESTART" "No EA heartbeat for ${age} minutes on ${MT5_SYMBOL}: the expert is not on a chart, so nothing is trading. Restarting the terminal to attach it again (attempt $tries/3)."
      sleep 3
      kill "$TERMINAL_PID" 2>/dev/null || true
      return 0   # main() waits on that pid; the container is coming down
    fi
    log "WATCHDOG: 3 terminal restarts did not get the EA back on the chart (no beat for ${age}m) - this is not a restart problem"
    hex_push "NEEDS-YOU" "The EA is still not on $MT5_SYMBOL after 3 automatic terminal restarts (no heartbeat for ${age}m). Open the VNC desktop: is the chart open, is the expert on it, what does the Experts tab say?"
    sleep 900
  done
}

# The other half of silence - the half nothing watched. On 2026-11-02 at 21:54
# the chart stopped being ticked while the terminal stayed UP and connected: the
# stop it was holding filled at 22:04 and was journalled normally, but OnTick was
# never called again. The EA wrote nothing for six hours, the container sat there
# "running" with nothing trading, and the only signal said the EA was off the
# chart (it was not). MT5 does not reliably come back from that by itself;
# restarting the terminal re-synchronizes the symbol and re-subscribes the chart,
# which is the only lever a container has.
#
# The restart budget lives on the volume (/data/.hex-feed) because the restart
# takes the container down with it - in memory every boot would start at attempt
# 1 and a genuinely dead feed would be restarted for ever. A stall that survives
# three restarts is not a restart problem, and then it says so and stops.
feed_watchdog() {
  local hb="$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-heartbeat.txt"
  local state="$MT5DIR/.hex-feed"
  local limit="${HEX_TICK_STALL_MIN:-15}"
  local tick_age beat_age tries last now mt sel sub
  set +e
  while :; do
    sleep 60
    [ -f "$hb" ] || continue
    # A blown account has halted on purpose and the healthcheck says so; a dead
    # feed in that state is not costing anything, and restarting the terminal
    # every 15 minutes would be noise about a robot that is not supposed to trade.
    [ -f "$MT5DIR/MQL5/Files/HEX-Logs/HEX-BoomRider-BLOWN.txt" ] && continue
    tick_age=$(hb_tick_age "$hb")
    [ -n "$tick_age" ] || continue          # older EA build: no tick age to judge
    if [ "$tick_age" -lt $(( limit * 60 )) ]; then
      if [ -f "$state" ]; then
        rm -f "$state" 2>/dev/null
        log "WATCHDOG: the feed is back (last tick ${tick_age}s ago) - feed restart budget cleared"
      fi
      continue
    fi
    # A stale beat is silence_watcher's incident; restarting here as well would
    # have two watchdogs killing the same terminal for two different reasons.
    now=$(date +%s); mt=$(file_mtime "$hb")
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    beat_age=9999
    [ "$mt" -gt 0 ] && beat_age=$(( (now - mt) / 60 ))
    [ "$beat_age" -le 5 ] || continue
    tries=0; last=0
    if [ -f "$state" ]; then
      read -r tries last < "$state" 2>/dev/null
    fi
    case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
    case "$last"  in ''|*[!0-9]*) last=0  ;; esac
    # The budget belongs to an incident: thirty quiet minutes after the last
    # attempt is a new one, the same rule ea_watchdog uses.
    [ "$last" -gt 0 ] && [ $(( now - last )) -gt 1800 ] && tries=0
    tries=$(( tries + 1 ))
    printf '%s %s\n' "$tries" "$now" > "$state" 2>/dev/null || true
    if [ "$tries" -le 3 ]; then
      # The beat now also says whether the symbol is subscribed at all. An
      # unselected symbol gets no quotes, ever - a restart cannot fix that, and
      # "feed stalled" would send the operator looking at the wrong thing.
      sel=$(hb_field "$hb" sel)
      sub=""
      [ "$sel" = "0" ] && sub=" and the EA reports the symbol is NOT SUBSCRIBED (SYMBOL_SELECT=0)"
      log "WATCHDOG: the EA is on the chart and beating, but nothing has ticked $MT5_SYMBOL for $(( tick_age / 60 ))m$sub (attempt $tries/3) - restarting the terminal to re-subscribe the symbol"
      hex_push "FEED-STALL" "No tick for $(( tick_age / 60 )) minutes on $MT5_SYMBOL. The EA is attached and its heartbeat is moving, but the chart is not being fed$sub - no entry, no exit, nothing trading. Restarting the terminal (attempt $tries/3)."
      sleep 3
      kill "$TERMINAL_PID" 2>/dev/null || true
      return 0   # main() waits on that pid; the container is coming down
    fi
    log "WATCHDOG: 3 terminal restarts did not restore the feed (last tick ${tick_age}s ago) - this is not a restart problem, it is the terminal, the symbol or the broker"
    hex_push "NEEDS-YOU" "The feed is still dead after 3 terminal restarts on $MT5_SYMBOL (no tick for $(( tick_age / 60 ))m, EA attached and beating). Open the VNC desktop: Market Watch, the symbol, the broker's status page. An ERROR row in the log saying the symbol is not in the server's list means MT5_SYMBOL is the wrong name - the row lists the names the server does carry."
    sleep 900
  done
}

# The image bakes the terminal (and, since the symbol-name bug, that account's
# Bases/Deriv-Demo: the symbol history plus the Market Watch selection). An
# existing volume predates that, and MT5_FORCE_SEED would wipe the volume - the
# account, the presets, the logs - to get it. Copying the missing base in is
# the same result without the amnesia. No-clobber, so a base the terminal has
# already refreshed on this volume wins.
repair_symbol_bases() {
  local seed="${HEX_DISTRO_SEED:-/opt/mt5-distro}/Bases"
  [ -d "$seed/Deriv-Demo" ] || return 0
  mkdir -p "$MT5DIR/Bases" 2>/dev/null || true
  if [ -d "$MT5DIR/Bases/Deriv-Demo/history/$MT5_SYMBOL" ]; then
    return 0
  fi
  log "the volume has no symbol history - copying Bases/Deriv-Demo out of the image so $MT5_SYMBOL synchronizes at once"
  cp -an "$seed/Deriv-Demo" "$MT5DIR/Bases/" 2>/dev/null || true
  cp -an "$seed"/*.dat "$MT5DIR/Bases/" 2>/dev/null || true
  chown -R trader:trader "$MT5DIR/Bases" 2>/dev/null || true
  log "copied $(du -sh "$MT5DIR/Bases/Deriv-Demo" 2>/dev/null | cut -f1) of symbol history into the volume"
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
  repair_symbol_bases
  sync_ea
  compile_ea
  ensure_single_chart
  write_mt5_ini
  launch_terminal
  wait_for_terminal
  report_isolation
  lease_keeper &
  mirror_dir "MT5" "$MT5DIR/logs" &
  # The Experts tab: this is where the terminal writes WHY it unloaded the EA
  # ("array out of range in ...", "zero divide in ..."), and it was the one log
  # nothing showed.
  mirror_dir "MQL5" "$MT5DIR/MQL5/Logs" nocsv &
  journal_hints "$MT5DIR/logs" &
  ea_watchdog "$MT5DIR/logs" &
  desktop_keeper &
  push_watcher &
  silence_watcher &
  # Silences are two different faults with two different fixes: no heartbeat at
  # all (silence_watcher, the EA is gone) and a heartbeat on a chart nothing is
  # ticking (feed_watchdog, the terminal is up but the feed is dead).
  feed_watchdog &
  hex_push "UP" "HEX-BoomRider container is up: ${MT5_SYMBOL} ${MT5_PERIOD}, account ${MT5_LOGIN:-<unset>} @ ${MT5_SERVER:-<volume>}, build ${HEX_BUILD:-unknown}. You will get a buzz on every BUY, CLOSE, ADD, ERROR and BLOWN - ADD means the EA just put another leg on a trade that is already in profit - plus the first SKIP of each reason if the EA cannot size a trade."
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

