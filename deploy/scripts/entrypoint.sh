#!/bin/bash
# HEX-FVG-Breaker on a server: MetaTrader 4 under Wine, headless, in a container.
#
# Every start does the same five things, in this order:
#
#   1. make sure a portable MetaTrader 4 tree exists in $MT4DIR (the volume)
#   2. copy this repo's .mq4 and presets into it and compile them with the real
#      metaeditor.exe, so the EA that runs is the EA that is in git
#   3. write startup.ini (login, server, symbol, expert, automated trading)
#   4. start Xvfb, plus x11vnc and noVNC when VNC_PASSWORD is set
#   5. run `wine terminal.exe /portable startup.ini`, then mirror MT4's journal
#      and the EA's prints into the container log
#
# It deliberately does not restart the terminal after a crash: it exits non-zero
# so Docker's restart policy decides, and the crash stays visible in the logs.
#
# Vocabulary used throughout: "distro" is a portable MT4 directory, "prefix" is
# the Wine C: drive, "data folder" is where MT4 keeps profiles/config/MQL4 -
# in portable mode that is $MT4DIR itself.
set -euo pipefail

log()  { printf '%s [hex] %s\n'  "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '%s [hex] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s [hex] FATAL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Instances. One container is one instance: one account, one chart, one expert.
# More than one instance on a host is more than one Dokploy application, and all
# of them are configured from ONE env file, where instance 2 and up read a
# suffixed copy of every value that makes it a different trader:
#
#   MT4_INSTANCE=1  ->  MT4_LOGIN,  MT4_SYMBOL,  MT4_PRESET,  ...
#   MT4_INSTANCE=2  ->  MT4_LOGIN2, MT4_SYMBOL2, MT4_PRESET2, ...
#
# Shared values (the desktop password, the distro URL, the screen size) keep one
# copy that every instance reads; a NAME<N> copy wins if you need to differ.
# ---------------------------------------------------------------------------
MT4_INSTANCE="${MT4_INSTANCE:-1}"
case "$MT4_INSTANCE" in
  ''|*[!0-9]*) die "MT4_INSTANCE must be a number (1, 2, 3 ...), got '$MT4_INSTANCE'" ;;
  0) die "MT4_INSTANCE starts at 1" ;;
esac

# NAME<N>, else NAME (instance 1 only), else DEFAULT. The eval reaches a
# variable *name* assembled from a literal and MT4_INSTANCE - never a value -
# because bash 3.2 has no namerefs and ${!name} cannot carry a default.
inst_var() { # NAME [DEFAULT]
  local name="$1" def="${2-}" v=""
  eval "v=\"\${${name}${MT4_INSTANCE}-}\""
  if [ -z "$v" ] && [ "$MT4_INSTANCE" = "1" ]; then
    eval "v=\"\${${name}-}\""
  fi
  [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}

# NAME<N> wins, otherwise the plain name, otherwise DEFAULT - for everything that
# is the same on every instance of this image.
shared_var() { # NAME [DEFAULT]
  local name="$1" def="${2-}" v=""
  eval "v=\"\${${name}${MT4_INSTANCE}-}\""
  [ -n "$v" ] || eval "v=\"\${${name}-}\""
  [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}

# Identity does not fall back. A duplicated Dokploy application keeps instance 1's
# MT4_LOGIN; falling back to it would trade instance 2's preset against instance
# 1's money with every input looking valid, so 2 and up must name their own.
check_instance_env() {
  local name v
  [ "$MT4_INSTANCE" = "1" ] && return 0
  for name in MT4_LOGIN MT4_PASSWORD MT4_SERVER MT4_SYMBOL MT4_PRESET; do
    v="$(inst_var "$name")"
    if [ -z "$v" ]; then
      die "MT4_INSTANCE=$MT4_INSTANCE has no ${name}${MT4_INSTANCE}. ${name} alone belongs to instance 1 and is deliberately not reused - that fallback is how a copied application ends up trading the wrong account. Set ${name}${MT4_INSTANCE}=... for this instance."
      return 1
    fi
  done
  # Sharing one account between two instances is legal (different symbol, different
  # magic) and occasionally intended - but it is also exactly what a duplicated
  # application looks like when only some of the values were replaced, so it says
  # so rather than assuming.
  if [ -n "${MT4_LOGIN-}" ] && [ "$(inst_var MT4_LOGIN)" = "${MT4_LOGIN}" ]; then
    warn "instance $MT4_INSTANCE logs into the same account as instance 1 (${MT4_LOGIN}). Deliberate only if the symbol and the magic number differ - if you copied the gold application, this is the value you forgot to change."
  fi
  return 0
}

check_instance_env

MT4DIR="${MT4DIR:-/data/mt4}"
MT4_SETUP_URL="${MT4_SETUP_URL:-https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4setup.exe}"
MT4_DISTRO_URL="$(shared_var MT4_DISTRO_URL)"
MT4_ALLOW_FRESH_INSTALL="$(shared_var MT4_ALLOW_FRESH_INSTALL 1)"
MT4_LOGIN="$(inst_var MT4_LOGIN)"
MT4_PASSWORD="$(inst_var MT4_PASSWORD)"
MT4_SERVER="$(inst_var MT4_SERVER)"
MT4_SYMBOL="$(inst_var MT4_SYMBOL XAUUSD)"
# Optional: the chart's timeframe. Empty = whatever the profile's chart already
# is. Set it to move an existing profile onto another timeframe (see
# ensure_profile_chart) instead of editing the desktop by hand.
MT4_PERIOD="$(inst_var MT4_PERIOD)"
MT4_PROFILE="$(inst_var MT4_PROFILE default)"
MT4_EXPERT="$(inst_var MT4_EXPERT HEX-FVG-Breaker)"
MT4_PRESET="$(inst_var MT4_PRESET 100usd-demo)"
MT4_EA_PRESET_SYNC="$(shared_var MT4_EA_PRESET_SYNC 1)"
MT4_EA_COMPILE="$(shared_var MT4_EA_COMPILE 1)"
# Re-seed over a tree that already has a terminal.exe. Off by default: a volume
# that works is not something to overwrite on every restart, and the tree holds
# the live profile and the account login. Needed once after a distro changes (or
# after a tree was seeded from an archive that carried macOS junk).
MT4_FORCE_SEED="$(shared_var MT4_FORCE_SEED 0)"
ENABLE_VNC="$(shared_var ENABLE_VNC 1)"
VNC_PASSWORD="$(shared_var VNC_PASSWORD)"
VNC_PORT="$(shared_var VNC_PORT 5900)"
NOVNC_PORT="$(shared_var NOVNC_PORT 6080)"
SCREEN="$(shared_var SCREEN 1440x900x24)"
DISPLAY="${DISPLAY:-:99}"
export DISPLAY

export WINEPREFIX="${WINEPREFIX:-/home/trader/.wine}"
# win64, not win32. MetaQuotes ships a 64-bit installer (PE32+, machine 8664) and
# a 32-bit terminal; a win64 prefix runs both through WoW64, which is the same
# arrangement a normal Windows install has - and a win32 prefix cannot start the
# installer at all (probed: it exits silently and installs nothing).
export WINEARCH="${WINEARCH:-win64}"
# No mono/gecko dialogs: this container must never wait on a modal window.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
export WINEDEBUG="${WINEDEBUG:--all}"

EA_SRC="/opt/ea/${MT4_EXPERT}.mq4"
EA_BAKED_EX4="/opt/ea/${MT4_EXPERT}.ex4"

XVFB_PID=""
X11VNC_PID=""
WEBSOCKIFY_PID=""
TERMINAL_PID=""

# ------------------------------------------------------- the terminal tree ---

# terminal.exe is the whole test. In portable mode everything else - config,
# MQL4, profiles, history - lives in the same directory, which is why $MT4DIR
# can be a volume and why a distro survives a redeploy untouched.
have_terminal() { [ -f "$MT4DIR/terminal.exe" ]; }

# Where the official installer dropped terminal.exe. /auto installs to a default
# path that differs between a win32 and a win64 prefix, so look rather than guess.
find_installed_terminal() {
  find "$WINEPREFIX/drive_c" -maxdepth 5 -iname 'terminal.exe' -print -quit 2>/dev/null
}

install_fresh_terminal() {
  local setup=/tmp/mt4setup.exe src
  log "no terminal in $MT4DIR - downloading the MetaQuotes installer"
  curl -fsSL --retry 3 --retry-delay 5 -o "$setup" "$MT4_SETUP_URL" \
    || die "download failed: $MT4_SETUP_URL"
  log "running mt4setup.exe /auto - this is the path that is expected to fail"
  # Honest expectation: this does not work. Probed on Wine 8 in the image build
  # and in a container: mt4setup.exe is a 64-bit web installer that exits
  # silently, installs nothing and never opens a window, in both prefix types.
  # It is kept because a future Wine or a broker's own installer may behave, and
  # because failing here with the installer's own output is more useful than not
  # trying at all. The supported path is a prepared distro (DEPLOY.md §4B).
  wine "$setup" /auto >/tmp/mt4setup.out 2>&1 \
    || warn "the installer exited non-zero"
  wineserver -w >/dev/null 2>&1 || true
  src="$(find_installed_terminal)"
  if [ -z "$src" ]; then
    sed 's/^/[setup] /' /tmp/mt4setup.out 2>/dev/null | tail -20 || true
    die "the installer produced no terminal under $WINEPREFIX/drive_c. MetaTrader has to be supplied: run deploy/scripts/prepare-distro.sh and point MT4_DISTRO_URL at the tarball (file:///data/mt4-portable.tar.gz). See DEPLOY.md section 4."
  fi
  log "installed terminal found at $src"
  mkdir -p "$MT4DIR"
  cp -a "$(dirname "$src")/." "$MT4DIR/"
}

# A seeded tree is built beside $MT4DIR and swapped in whole. An extraction that
# dies halfway leaves a folder that has a terminal.exe and half its indicators -
# which looks like a working install and then fails a hundred lines later somewhere
# else. Nothing replaces a working tree until the new one has a terminal.exe.
swap_in_new_tree() {
  local new="$1"
  [ -f "$new/terminal.exe" ] || die "the seeded tree has no terminal.exe at its root - refusing to touch $MT4DIR"
  rm -rf "$MT4DIR.old"
  [ -d "$MT4DIR" ] && mv "$MT4DIR" "$MT4DIR.old"
  mv "$new" "$MT4DIR"
  rm -rf "$MT4DIR.old"
  # The new tree carries the state of whatever terminal it was copied from, so
  # instance 2+ has to neutralise it again (see neutralise_seed).
  rm -f "$(dirname "$MT4DIR")/.hex-neutralised"
}

# The distro is a copy of a *working* terminal, so it carries what made that copy
# work: the saved login (config/accounts.ini), the last server it talked to, the
# MQL5 community session, the per-chart expert inputs, and the EA's CSV log. For
# instance 1 that is its own account and its own history. For instance 2 it is
# somebody else's: the terminal would come up as the gold account, with the gold
# instrument's inputs and a trade log it never wrote - which is exactly what
# "it still shows the old account" looks like. Those files are binary/encrypted,
# so they are removed rather than edited; MT4 writes them back on its first login.
#
# Once per volume, not once per boot: after this instance has logged in, its own
# accounts.ini is the thing that makes it start without a login prompt, and
# deleting that every restart would demand a manual login forever. The marker is
# dropped by swap_in_new_tree, so a re-seed neutralises the fresh tree as well.
#
# Nothing that could later answer a question is destroyed: the binary state files
# go (the next login re-creates them) and the previous account's CSV log and
# journals are *moved* into .before-instance<N>/, because "did that first boot
# trade anything?" is answered from exactly those files.
neutralise_seed() {
  local meta marker park base f n=0
  [ "$MT4_INSTANCE" = "1" ] && return 0
  meta="$(dirname "$MT4DIR")"
  marker="$meta/.hex-neutralised"
  [ -f "$marker" ] && return 0
  park="$MT4DIR/.before-instance$MT4_INSTANCE"
  for f in config/accounts.ini config/server.ini config/community.ini config/experts.ini; do
    if [ -e "$MT4DIR/$f" ]; then
      rm -f "$MT4DIR/$f" 2>/dev/null && n=$((n + 1))
    fi
  done
  mkdir -p "$park" 2>/dev/null || true
  for f in MQL4/Files/Common/HEX-Logs MQL4/Logs logs; do
    if [ -d "$MT4DIR/$f" ]; then
      base="$(basename "$f")"
      rm -rf "$park/$base" 2>/dev/null || true
      mv "$MT4DIR/$f" "$park/$base" 2>/dev/null && n=$((n + 1))
    fi
  done
  rm -rf "$MT4DIR"/history/* 2>/dev/null || true
  printf 'instance=%s\n' "$MT4_INSTANCE" > "$marker" 2>/dev/null || true
  log "seed: $n file(s) of the previous account's state moved out of the way - saved login, last server, MQL5 session and expert inputs are gone, its CSV log and journals are in $park"
  log "seed: this terminal has no account yet - the login comes from startup.ini. If the desktop shows a login dialog on the first start, log in once: the broker's server is unknown to this copy of the terminal, and MT4 saves it on this volume from then on"
}

# Extraction is filtered rather than trusted. An archive built on a Mac can carry
# AppleDouble "._name" files, and MetaEditor batch-compiles every one it finds -
# 200+ files and about 15 seconds of boot for this distro, with their object files
# landing in MQL4. GNU tar also warns once per "LIBARCHIVE.xattr" header, which is
# 272 lines of noise for the same archive. prepare-distro.sh produces clean
# archives now (--no-mac-metadata --no-xattrs); this makes an older or foreign
# archive harmless instead of noisy.
untar_into() {
  local arc="$1" dest="$2" out=/tmp/untar.log
  local -a args=(-xf "$arc" -C "$dest" --exclude='._*' --exclude='.DS_Store')
  case "$arc" in
    *.zst|*.tzst) args=(--use-compress-program=unzstd "${args[@]}") ;;
    *.gz|*.tgz)   args=(-z "${args[@]}") ;;
  esac
  # GNU tar only: bsdtar does not know this option and would refuse to run.
  if tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
    args=(--warning=no-unknown-keyword "${args[@]}")
  fi
  if ! tar "${args[@]}" 2>"$out"; then
    sed 's/^/[tar] /' "$out" | tail -15 >&2
    die "extracting $arc failed - the [tar] lines above name the file or the reason"
  fi
  if [ -s "$out" ]; then
    warn "tar printed $(grep -c . "$out") line(s) while extracting; first few:"
    sed 's/^/[tar] /' "$out" | head -5 >&2
  fi
  rm -f "$out"
}

resolve_distro() {
  local new="$MT4DIR.seeding"
  # One line instead of a wall of tar errors when the volume belongs to someone
  # else. This is the single most common way a fresh server fails, and the message
  # tar prints for it names MQL4 and config rather than the mount.
  if ! ( : > "$MT4DIR/.write-test" ) 2>/dev/null; then
    die "$MT4DIR is not writable by uid $(id -u) ($(id -un)). The volume belongs to another user - docker-entrypoint.sh normally fixes that as root, so check the mount: a bind mount keeps its host ownership, a named volume inherits the image's."
  fi
  rm -f "$MT4DIR/.write-test"
  if have_terminal && [ "$MT4_FORCE_SEED" != "1" ]; then
    log "terminal present: $MT4DIR/terminal.exe ($(stat -c %s "$MT4DIR/terminal.exe") bytes)"
    return 0
  fi
  if [ "$MT4_FORCE_SEED" = "1" ] && have_terminal; then
    warn "MT4_FORCE_SEED=1: replacing the tree in $MT4DIR with a fresh distro - the profile and the account login go with it"
  fi
  if [ -f /opt/mt4-distro/terminal.exe ]; then
    log "seeding $MT4DIR from the MT4 distro baked into this image"
    rm -rf "$new"
    mkdir -p "$new"
    cp -a /opt/mt4-distro/. "$new/"
    swap_in_new_tree "$new"
    return 0
  fi
  if [ -n "$MT4_DISTRO_URL" ]; then
    local arc=/tmp/mt4-distro.tar sha
    log "seeding $MT4DIR from MT4_DISTRO_URL"
    curl -fsSL --retry 3 --retry-delay 5 -o "$arc" "$MT4_DISTRO_URL" \
      || die "distro download failed: $MT4_DISTRO_URL"
    # The URL and the hash are what answer "which distro is this container
    # actually running". A tarball rebuilt on a Mac and a release asset look
    # identical from the inside, and a stale one shows up as odd content rather
    # than as an error - this log line makes the comparison a one-liner.
    sha="$(sha256sum "$arc" | cut -d' ' -f1)"
    log "distro url  : $MT4_DISTRO_URL"
    log "distro sha  : $sha ($(stat -c %s "$arc") bytes)"

    # MT4_FORCE_SEED is one-shot per archive, not "every boot". Replacing the tree
    # also replaces MQL4/Files/Common/HEX-Logs - the EA's own trade history - so a
    # flag left on by accident would erase the CSV record on every restart. The
    # marker is written only after a forced seed; a different archive still gets
    # in, and deleting /data/.seeded-from re-arms the same one.
    if [ "$MT4_FORCE_SEED" = "1" ] && have_terminal && [ -f /data/.seeded-from ] \
       && [ "$(cat /data/.seeded-from)" = "$sha" ]; then
      warn "MT4_FORCE_SEED=1, but /data/mt4 was already re-seeded from this exact archive ($sha)."
      warn "Not replacing it again - that would delete the profile and the EA's CSV trade log."
      warn "Remove MT4_FORCE_SEED from the environment, or delete /data/.seeded-from to force it again."
      rm -f "$arc"
      return 0
    fi

    rm -rf "$new"
    mkdir -p "$new"
    untar_into "$arc" "$new"
    rm -f "$arc"
    log "extracted   : $(find "$new" -type f | wc -l | tr -d ' ') files"
    swap_in_new_tree "$new"
    if [ "$MT4_FORCE_SEED" = "1" ]; then
      printf '%s\n' "$sha" > /data/.seeded-from
      warn "seeded from $sha. MT4_FORCE_SEED stays set but will not re-seed this archive again; set it to 0 when convenient."
    else
      rm -f /data/.seeded-from
    fi
    return 0
  fi
  [ "$MT4_ALLOW_FRESH_INSTALL" = "1" ] \
    || die "no terminal in $MT4DIR and MT4_ALLOW_FRESH_INSTALL=$MT4_ALLOW_FRESH_INSTALL. Put a distro in the volume or allow the install."
  install_fresh_terminal
  have_terminal || die "still no $MT4DIR/terminal.exe after installing"
}

# ------------------------------------------------------------ the EA source ---

sync_ea() {
  [ -f "$EA_SRC" ] || die "EA source is missing from the image: $EA_SRC"
  mkdir -p "$MT4DIR/MQL4/Experts" "$MT4DIR/MQL4/Presets"
  cp -f "$EA_SRC" "$MT4DIR/MQL4/Experts/${MT4_EXPERT}.mq4"
  if [ "$MT4_EA_PRESET_SYNC" = "1" ] && compgen -G "/opt/ea/presets/*.set" >/dev/null; then
    cp -f /opt/ea/presets/*.set "$MT4DIR/MQL4/Presets/"
    log "synced ${MT4_EXPERT}.mq4 and $(ls /opt/ea/presets/*.set | wc -l | tr -d ' ') presets into MQL4/"
  fi
  [ -f "$MT4DIR/MQL4/Presets/${MT4_PRESET}.set" ] || \
    warn "preset ${MT4_PRESET}.set is missing - the expert will open with its own defaults"
}

compile_ea() {
  if [ "$MT4_EA_COMPILE" != "1" ]; then
    log "MT4_EA_COMPILE=0 - keeping whatever .ex4 is already in the volume"
    return 0
  fi
  if [ ! -f "$MT4DIR/metaeditor.exe" ]; then
    warn "metaeditor.exe is not in this distro - cannot compile from source"
    fall_back_to_baked_ex4 "no metaeditor"
    return 0
  fi

  local clog="$WINEPREFIX/drive_c/hexcompile.log"
  local ex4="$MT4DIR/MQL4/Experts/${MT4_EXPERT}.ex4"
  rm -f "$ex4" "$clog"
  # MetaEditor returns 0 whether or not the compile succeeded, so the .ex4 is the
  # verdict and the log is the explanation - the same rule Tools/mt4_compile.sh
  # follows locally. Running this on every start is what keeps "the EA that is
  # running" and "the EA that is in git" the same file.
  ( cd "$MT4DIR" && wine metaeditor.exe "/compile:MQL4\\Experts\\${MT4_EXPERT}.mq4" \
      '/log:C:\hexcompile.log' ) >/dev/null 2>&1 || true
  wineserver -w >/dev/null 2>&1 || true
  if [ -f "$clog" ]; then
    iconv -f UTF-16LE -t UTF-8 "$clog" 2>/dev/null \
      | sed -e 's|\r$||' -e '/^$/d' -e 's|^|[metaeditor] |' | tail -30 || true
    rm -f "$clog"
  fi
  if [ -f "$ex4" ]; then
    log "compiled ${MT4_EXPERT}.ex4 from source ($(stat -c %s "$ex4") bytes)"
    return 0
  fi
  warn "the compile produced no .ex4"
  fall_back_to_baked_ex4 "compile failed"
}

# The image carries an .ex4 built in CI from the same commit, so a runtime compile
# failure (read-only volume, damaged distro, ...) is an environment problem rather
# than a source problem. Trading the CI binary still means trading the code in git
# and beats a container that will not start.
fall_back_to_baked_ex4() {
  [ -f "$EA_BAKED_EX4" ] || die "$1, and this image has no pre-built ${MT4_EXPERT}.ex4 to fall back on"
  cp -f "$EA_BAKED_EX4" "$MT4DIR/MQL4/Experts/${MT4_EXPERT}.ex4"
  warn "$1 - falling back to the .ex4 compiled at image build time"
}

# One chart, one robot. MT4 restores the charts saved in the profile *and* opens a
# chart for startup.ini's Symbol=, so a distro prepared with an XAUUSD M15 chart
# starts with XAUUSD M15 (from the profile) plus XAUUSD H1 (from Symbol=) - two
# copies of the expert on one magic number, each running its own signal engine.
# The profile chart is the one that was verified by hand, so it wins: the symbol
# line is only written when the profile has no chart for it, which is the case the
# line exists for. Newlines and tabs below are the field separators, so the caller
# can grep for a symbol without parsing a binary .chr.
profile_charts() {
  local f sym per
  for f in "$MT4DIR/profiles/$MT4_PROFILE"/chart*.chr; do
    [ -f "$f" ] || continue
    sym="$(grep -a -m1 '^symbol=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '\r')"
    per="$(grep -a -m1 '^period=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '\r')"
    printf '%s\t%s\t%s\n' "$(basename "$f")" "${sym:-?}" "${per:-?}"
  done
  return 0
}

# An instance trades exactly one chart, and it is the chart the env asked for.
# MT4 restores every chart in the profile and *also* opens one for startup.ini's
# Symbol= when it names a symbol the profile does not have - which is how one
# account ends up running the expert twice (once per chart) on one magic number.
# The lock refuses the second copy, but which copy wins is whichever loaded first,
# i.e. a coin toss between two different symbols. So the profile is moved onto the
# requested symbol instead of adding to it.
ensure_profile_chart() {
  local dir="$MT4DIR/profiles/$MT4_PROFILE" f first="" extra
  [ -d "$dir" ] || return 0

  for f in "$dir"/chart*.chr; do
    [ -f "$f" ] || continue
    if [ -z "$first" ]; then
      first="$f"
      continue
    fi
    mkdir -p "$MT4DIR/.profile-extra" 2>/dev/null || true
    extra="$MT4DIR/.profile-extra/$(basename "$f")"
    if [ -e "$extra" ]; then extra="$extra.$(date +%s)"; fi
    if mv -f "$f" "$extra" 2>/dev/null; then
      log "chart: moved an extra chart out of the profile ($(basename "$f")) - one chart, one expert"
    fi
  done
  [ -n "$first" ] || return 0

  local cur_sym cur_per want_per repl
  cur_sym="$(grep -a -m1 '^symbol=' "$first" 2>/dev/null | cut -d= -f2 | tr -d '\r' || true)"
  cur_per="$(grep -a -m1 '^period=' "$first" 2>/dev/null | cut -d= -f2 | tr -d '\r' || true)"
  want_per="${MT4_PERIOD:-$cur_per}"
  repl="$(printf '%s' "$MT4_SYMBOL" | sed 's/[&|\\]/\\&/g')"

  if [ "$cur_sym" = "$MT4_SYMBOL" ] && [ "$cur_per" = "$want_per" ]; then
    log "chart: $(basename "$first") carries ${cur_sym:-?} ${want_per:-?} - no rewrite needed"
    return 0
  fi

  # A <chart> file is plain text, so it can be moved rather than guessed at. The
  # <expert> block goes with the move: those inputs belong to the symbol that was
  # there, and startup.ini's Expert=/ExpertParameters= attach this instance's
  # preset. Leaving both behind puts two sets of inputs in the same chart, and
  # which one wins is decided inside the terminal, not here.
  mkdir -p "$MT4DIR/.profile-orig" 2>/dev/null || true
  cp -f "$first" "$MT4DIR/.profile-orig/$(basename "$first")" 2>/dev/null || true
  local tmp; tmp="$(mktemp)"
  awk '/^<expert>/{skip=1} skip==0{print} /^<\/expert>/{skip=0}' "$first" 2>/dev/null \
    | sed -e "s|^symbol=.*|symbol=${repl}|" \
          -e "s|^period=.*|period=${want_per}|" \
          -e '/^digits=/d' -e '/^scale=/d' > "$tmp" || true
  if grep -qx "symbol=${repl}" "$tmp" 2>/dev/null && grep -qx "period=${want_per}" "$tmp" 2>/dev/null; then
    cat "$tmp" > "$first"
    log "chart: $(basename "$first") moved ${cur_sym:-?} ${cur_per:-?} -> ${MT4_SYMBOL} ${want_per} (the original is in $MT4DIR/.profile-orig)"
  else
    warn "chart: could not rewrite $(basename "$first") - MT4 will open whatever it carries, and Symbol=${MT4_SYMBOL} may add a second chart"
  fi
  rm -f "$tmp"
}


write_startup_ini() {
  local f="$MT4DIR/startup.ini"
  # MetaTrader reads this file when it is named on the command line. Names are the
  # long-standing MT4 set: Expert/ExpertParameters make the terminal attach the
  # robot and load the preset even on a fresh profile, and ExpertsTrades is the
  # "allow automated trading" switch a headless start has no button for.
  #
  # The chart itself (symbol, timeframe, inputs) comes from the profile in the
  # data folder. A distro prepared from a machine that already runs the robot
  # therefore starts with the exact chart that was verified on that machine.
  local charts symbol_line
  charts="$(profile_charts)"
  if [ -n "$charts" ]; then
    log "profile $MT4_PROFILE carries: $(printf '%s' "$charts" | tr '\t\n' '  ' | sed 's/  *$//')"
  fi
  symbol_line="Symbol=${MT4_SYMBOL}"
  if [ -n "$charts" ] && printf '%s\n' "$charts" | cut -f2 | grep -qx -- "$MT4_SYMBOL"; then
    symbol_line="; Symbol= deliberately left out - the profile above already carries a $MT4_SYMBOL chart, and adding it opens a second one"
    log "chart source: the $MT4_PROFILE profile (Symbol= omitted, so MT4 does not open a second chart)"
  fi
  umask 077
  mkdir -p "$MT4DIR" 2>/dev/null || true
  cat > "$f" <<EOF
; written by deploy/scripts/entrypoint.sh on every start - change the env, not this file
Profile=${MT4_PROFILE}
Login=${MT4_LOGIN}
Password=${MT4_PASSWORD}
Server=${MT4_SERVER}
EnableNews=false
ProxyEnable=false
FTPEnable=false
ExpertsEnable=true
ExpertsDllImport=true
ExpertsExpImport=true
ExpertsTrades=true
${symbol_line}
Expert=${MT4_EXPERT}
ExpertParameters=${MT4_PRESET}.set
EOF
  if [ "$symbol_line" = "Symbol=${MT4_SYMBOL}" ]; then
    log "startup.ini: profile=$MT4_PROFILE server=${MT4_SERVER:-<unset>} symbol=$MT4_SYMBOL expert=$MT4_EXPERT preset=$MT4_PRESET"
  else
    log "startup.ini: profile=$MT4_PROFILE server=${MT4_SERVER:-<unset>} symbol from profile expert=$MT4_EXPERT preset=$MT4_PRESET"
  fi
  [ -n "$MT4_LOGIN" ] || warn "MT4_LOGIN is empty - MT4 will wait at its login dialog (visible on the VNC desktop)"
}

start_display() {
  Xvfb "$DISPLAY" -screen 0 "$SCREEN" +extension GLX +extension RANDR +extension RENDER \
    >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  local n=${DISPLAY#:}; n=${n%%.*}
  for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X${n}" ] && break; sleep 0.2; done
  [ -e "/tmp/.X11-unix/X${n}" ] || die "Xvfb did not start - see /tmp/xvfb.log"
  log "virtual display $DISPLAY ($SCREEN)"
}

start_vnc() {
  if [ "$ENABLE_VNC" != "1" ]; then
    log "ENABLE_VNC=0 - no remote desktop"
    return 0
  fi
  if [ -z "$VNC_PASSWORD" ]; then
    # An unauthenticated desktop can place trades. Refuse, loudly, rather than
    # publish one and hope the firewall is doing its job.
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
  cd "$MT4DIR"
  # /portable keeps config, MQL4 and profiles next to terminal.exe instead of the
  # Wine user's AppData, which is what makes $MT4DIR a self-contained volume.
  wine terminal.exe /portable startup.ini >>/tmp/terminal.out 2>&1 &
  TERMINAL_PID=$!
  log "terminal.exe started (pid $TERMINAL_PID)"
}

wait_for_terminal() {
  for _ in $(seq 1 90); do
    if pgrep -f 'terminal\.exe' >/dev/null; then
      log "terminal.exe is up"
      return 0
    fi
    sleep 2
  done
  warn "terminal.exe did not appear within 3 minutes - see /tmp/terminal.out"
}

# MT4 buffers its journal to disk and only flushes on a clean exit, so `docker
# logs` would otherwise show nothing at all until the container stops. This polls
# the two log folders and re-prints new lines, which survives a day rollover and
# a truncated file - the same way `tail -F` would if it could see new files.
#
# Progress is kept in one small file per journal, not an associative array: macOS
# ships bash 3.2, where `declare -A` fails and takes the whole function with it -
# silently, so the journal simply goes quiet. A counter file works on both.
#
# Anything already in the folder when this starts belongs to a previous run of the
# container (the mirrors are started before terminal.exe), so it is not replayed.
# A restart that reprinted it showed a second "loaded successfully" for a chart
# that was loaded once - which reads exactly like a double expert load.
mirror_dir() {
  local tag="$1" dir="$2"
  local state="${TMPDIR:-/tmp}/hex-mirror$(printf '%s' "$dir" | tr -c 'A-Za-z0-9' '_')" f n seen
  mkdir -p "$state" 2>/dev/null || true
  seen=0
  for f in "$dir"/*.log; do
    [ -f "$f" ] || continue
    # BSD `wc -l < file` pads the count with spaces, and a padded number fails the
    # numeric guard below - which would look like "no lines seen yet" on every
    # poll and reprint the whole journal for ever.
    n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]'); n=${n:-0}
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$n" > "$state/$(basename "$f").seen" 2>/dev/null || true
    seen=$((seen + n))
  done
  if [ "$seen" -gt 0 ]; then
    printf '%s %s line(s) from the previous run are already in %s - not replayed, the file is on the volume\n' \
      "$tag" "$seen" "$dir"
  fi
  while :; do
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      local n s sf
      sf="$state/$(basename "$f").seen"
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
      s=$(cat "$sf" 2>/dev/null | tr -d '[:space:]')
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      case "$s" in ''|*[!0-9]*) s=0 ;; esac
      # Shrunk under us (new journal for the day, or MT4 rewriting it): what is in
      # there now is new, so print it from the top instead of going quiet.
      [ "$n" -lt "$s" ] && s=0
      if [ "$n" -gt "$s" ]; then
        tail -n "+$((s + 1))" "$f" 2>/dev/null | sed "s/^/${tag} /" || true
      fi
      printf '%s\n' "$n" > "$sf" 2>/dev/null || true
    done
    sleep 2
  done
}

# A container must be given its own volume. Two terminals writing one MT4 tree
# corrupt each other, and the likelier version of that is quieter: the second
# application is created without its own volume, inherits the first one's
# /data - which holds config/accounts.ini, so it logs in as the first account no
# matter what its env says - and trades the second preset against the first
# account's money. So the volume records which instance claimed it.
claim_volume() {
  local meta marker cur was_login was_sym
  meta="$(dirname "$MT4DIR")"
  marker="$meta/.hex-instance"
  cur="instance=${MT4_INSTANCE} login=${MT4_LOGIN:-?} symbol=${MT4_SYMBOL} preset=${MT4_PRESET}"
  was_login=""; was_sym=""
  if [ -f "$marker" ]; then
    was_login="$(sed -n 's/^.* login=\([^ ]*\).*$/\1/p' "$marker" 2>/dev/null | head -1)"
    was_sym="$(sed -n 's/^.* symbol=\([^ ]*\).*$/\1/p' "$marker" 2>/dev/null | head -1)"
  fi
  # "?" is what an instance with no login yet writes; it proves nothing either way.
  if [ -n "$MT4_LOGIN" ] && [ -n "$was_login" ] && [ "$was_login" != "?" ] && [ "$was_login" != "$MT4_LOGIN" ]; then
    die "this volume belongs to account $was_login and this container is instance $MT4_INSTANCE on account ${MT4_LOGIN}. One volume per instance: give this application its own volume at $meta, or - if you really mean to move this volume to the other account - delete $marker first."
    return 1
  fi
  if [ -n "$was_sym" ] && [ "$was_sym" != "$MT4_SYMBOL" ]; then
    warn "volume: $meta was last used for $was_sym and is now asked for $MT4_SYMBOL - the profile's chart will be moved, the original is kept in $MT4DIR/.profile-orig"
  fi
  if [ ! -f "$marker" ]; then
    log "volume: $meta claimed by instance $MT4_INSTANCE (${MT4_LOGIN:-no login yet}, $MT4_SYMBOL, $MT4_PRESET)"
  fi
  mkdir -p "$meta" 2>/dev/null || true
  printf '%s\n' "$cur" > "$marker" 2>/dev/null || true
}

banner() {
  log "----------------------------------------------------------------"
  log " HEX-FVG-Breaker on MT4 | instance $MT4_INSTANCE | ${MT4_SYMBOL}${MT4_PERIOD:+ $MT4_PERIODm} | $MT4_EXPERT | preset $MT4_PRESET"
  if [ "$MT4_INSTANCE" = "1" ]; then
    log " instance env : the unsuffixed names (MT4_LOGIN, MT4_SYMBOL, ...)"
  else
    log " instance env : the \"$MT4_INSTANCE\" copies (MT4_LOGIN$MT4_INSTANCE, MT4_SYMBOL$MT4_INSTANCE, ...)"
  fi
  log " data folder  : $MT4DIR (portable, on the volume)"
  log " mt4 journal  : $MT4DIR/logs          - mirrored below as [mt4]"
  log " ea prints    : $MT4DIR/MQL4/Logs     - mirrored below as [ea]"
  log " ea csv logs  : $MT4DIR/MQL4/Files/Common/HEX-Logs"
  log " account      : ${MT4_LOGIN:-<unset>} @ ${MT4_SERVER:-<unset>}"
  log " auto trading : requested through startup.ini (ExpertsTrades=true). The"
  log "                button state is not stored on disk, so confirm it once in"
  log "                the desktop - the EA's dashboard and its INIT push both say"
  log "                whether trading is actually allowed."
  log "----------------------------------------------------------------"
}

# Two things this container wants but cannot always be given: a big /dev/shm and
# CAP_SYS_PTRACE. Dokploy's Docker-Image app type can set neither - `CapAdd` does
# not appear anywhere in Dokploy's source, and `shm_size` is a compose key - while
# the Compose route gets both because it hands raw YAML to `docker compose`. Neither
# is fatal on its own, but each fails as something that looks like a broken EA (a
# blank desktop with BadAccess MIT-SHM; an expert that never attaches), so they are
# reported at boot instead of assumed. This logs and carries on: the desktop and the
# EA's own dashboard are the things that know what actually happened.
report_isolation() {
  local shm_kb cap_eff
  shm_kb="$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
  shm_kb="${shm_kb:-0}"
  if [ "$shm_kb" -gt 0 ] && [ "$shm_kb" -lt 131072 ]; then
    warn "/dev/shm is $((shm_kb / 1024)) MB. Xvfb and Wine share it to draw, so a blank desktop or 'BadAccess (MIT-SHM)' in this log is that. Compose can raise it (shm_size: 512m); a Docker-Image app cannot."
  elif [ "$shm_kb" -gt 0 ]; then
    log " shm          : $((shm_kb / 1024)) MB (enough for Xvfb + Wine)"
  fi
  cap_eff="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null)"
  if [ -n "$cap_eff" ] && (( (16#$cap_eff >> 19) & 1 )); then
    log " CAP_SYS_PTRACE: present"
  else
    warn "CAP_SYS_PTRACE is not in this container. Wine only wants it to attach a debugger, so this is usually harmless - but if no smiley face ever appears next to the expert name, this is one of the two candidates (the other is AutoTrading, which the EA reports itself)."
  fi
}

on_term() {
  trap - TERM INT
  log "SIGTERM - asking MT4 to close so it flushes its journal and the EA's CSVs"
  wineserver -k >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f 'terminal\.exe' >/dev/null || break
    sleep 1
  done
  pgrep -f 'terminal\.exe' >/dev/null && warn "terminal.exe still alive after 25s, killing it"
  [ -n "$X11VNC_PID" ] && kill "$X11VNC_PID" 2>/dev/null || true
  [ -n "$WEBSOCKIFY_PID" ] && kill "$WEBSOCKIFY_PID" 2>/dev/null || true
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
  log "stopped"
  exit 0
}

main() {
  trap on_term TERM INT
  banner
  report_isolation
  mkdir -p "$MT4DIR"
  claim_volume
  resolve_distro
  neutralise_seed
  # The display comes up before the compile, not after: metaeditor.exe is a GUI
  # binary and under Wine with no X server it exits without writing the .ex4 -
  # the same reason deploy/Dockerfile's ea-check stage runs it through xvfb-run.
  # An image built without a distro has no baked .ex4 to fall back on, so that
  # failure is fatal, and it looks like a source problem rather than a missing
  # display. A second of Xvfb buys a compile that either works or says why.
  start_display
  sync_ea
  compile_ea
  ensure_profile_chart
  write_startup_ini
  start_vnc
  mirror_dir "[mt4]" "$MT4DIR/logs" &
  mirror_dir "[ea] " "$MT4DIR/MQL4/Logs" &
  launch_terminal
  wait_for_terminal

  # The terminal's exit code decides the container's. No silent restart loop: a
  # crash belongs in `docker logs`, and the restart policy belongs to the operator.
  local rc=0
  wait "$TERMINAL_PID" || rc=$?
  log "terminal.exe exited with code $rc"
  exit "$rc"
}

main "$@"



