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
  for name in MT4_LOGIN MT4_PASSWORD MT4_SYMBOL MT4_PRESET; do
    v="$(inst_var "$name")"
    if [ -z "$v" ]; then
      die "MT4_INSTANCE=$MT4_INSTANCE has no ${name}${MT4_INSTANCE}. ${name} alone belongs to instance 1 and is deliberately not reused - that fallback is how a copied application ends up trading the wrong account. Set ${name}${MT4_INSTANCE}=... for this instance."
      return 1
    fi
  done
  # The server is the one value that may legitimately be missing: a terminal only
  # knows the servers it has seen, so on a broker it has never met the exact name
  # cannot be known yet. Empty is not a fallback to instance 1's server - it means
  # no Server= is claimed, MT4 opens its login dialog once, and the name written
  # there is the one to copy into MT4_SERVER$MT4_INSTANCE.
  if [ -z "$(inst_var MT4_SERVER)" ]; then
    warn "instance $MT4_INSTANCE has no MT4_SERVER$MT4_INSTANCE yet. That is allowed: the terminal will use the server saved on this volume, or show its login dialog once - log in there and copy the exact server name into MT4_SERVER$MT4_INSTANCE. It will not use instance 1's server."
  fi
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
WM_PID=""
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
  # config/experts.ini is deliberately *kept*: it holds the WebRequest allow-list
  # (the ntfy URL, UTF-16 in a binary file that nothing in deploy/ can write), and
  # the "disable automated trading when the account/profile/symbol changed" flags.
  # Deleting it would strip the one setting the new instance cannot be given any
  # other way, and in exchange for nothing: the other instrument's expert *inputs*
  # are not here, they are in the profile chart's <expert> block, which
  # ensure_profile_chart already drops.
  for f in config/accounts.ini config/server.ini config/community.ini; do
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
  log "seed: $n file(s) of the previous account's state moved out of the way - the saved login, the last server and the MQL5 session are gone; its CSV log and journals are in $park"
  log "seed: config/experts.ini stays: that is where the WebRequest allow-list (the ntfy URL) lives, and nothing in deploy/ can write it back"
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
  local charts symbol_line login_block accounts
  accounts="$MT4DIR/config/accounts.ini"
  charts="$(profile_charts)"
  if [ -n "$charts" ]; then
    log "profile $MT4_PROFILE carries: $(printf '%s' "$charts" | tr '\t\n' '  ' | sed 's/  *$//')"
  fi
  symbol_line="Symbol=${MT4_SYMBOL}"
  if [ -n "$charts" ] && printf '%s\n' "$charts" | cut -f2 | grep -qx -- "$MT4_SYMBOL"; then
    symbol_line="; Symbol= deliberately left out - the profile above already carries a $MT4_SYMBOL chart, and adding it opens a second one"
    log "chart source: the $MT4_PROFILE profile (Symbol= omitted, so MT4 does not open a second chart)"
  fi
  # Login= in startup.ini is a *re-login*: the terminal re-uses the account
  # record in config/accounts.ini, it does not create one from these three lines.
  # Instance 2 has no record - neutralise_seed deletes the gold one on its first
  # boot, on purpose, so that the second hostname cannot come up as the first
  # account. With Login=/Password=/Server= still in the file MT4 tries, finds
  # nothing to log in as, and sits on the chart at "Waiting for update"/"No
  # connection" without ever showing a dialog: a terminal that looks broken.
  # Leaving the three lines out is what a freshly installed MT4 looks like, and
  # that is the case MT4 answers with its login window. One manual login writes
  # accounts.ini onto the volume, and every later start re-logs in from here.
  if [ -f "$accounts" ]; then
    login_block="Login=${MT4_LOGIN}
Password=${MT4_PASSWORD}
Server=${MT4_SERVER}"
  else
    login_block="; Login= / Password= / Server= are left out on purpose: this volume has no
; config/accounts.ini, so there is no account to re-login as and MT4 answers with
; its login window instead of silently doing nothing. Log in once on the desktop
; (File -> Login); the account is saved here and later starts use these lines."
  fi
  umask 077
  mkdir -p "$MT4DIR" 2>/dev/null || true
  cat > "$f" <<EOF
; written by deploy/scripts/entrypoint.sh on every start - change the env, not this file
Profile=${MT4_PROFILE}
${login_block}
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
  if [ -f "$accounts" ]; then
    log "login        : $MT4_LOGIN @ ${MT4_SERVER:-<server from this volume>} - re-used from config/accounts.ini"
  else
    warn "login: this volume has no config/accounts.ini, so there is no account for MT4 to log in as - the terminal opens its login window instead (visible on the VNC desktop). Log in once there${MT4_SERVER:+ (server: $MT4_SERVER)}${MT4_LOGIN:+ (login: $MT4_LOGIN)}; it is saved on this volume and every later start logs in from startup.ini. If the server is not in the window's list, this copy of the terminal has never heard of that broker: copy config/servers.ini from a terminal that knows it, or add it once through File -> Open an Account."
  fi
  if [ "$symbol_line" = "Symbol=${MT4_SYMBOL}" ]; then
    log "startup.ini: profile=$MT4_PROFILE server=${MT4_SERVER:-<unset>} symbol=$MT4_SYMBOL expert=$MT4_EXPERT preset=$MT4_PRESET"
  else
    log "startup.ini: profile=$MT4_PROFILE server=${MT4_SERVER:-<unset>} symbol from profile expert=$MT4_EXPERT preset=$MT4_PRESET"
  fi
  [ -n "$MT4_LOGIN" ] || warn "MT4_LOGIN is empty - MT4 will wait at its login dialog (visible on the VNC desktop)"
  [ -n "$MT4_SERVER" ] || warn "MT4_SERVER is empty - no Server= is claimed, so MT4 uses the server saved on this volume or shows the login dialog once (visible on the VNC desktop)"
}

# Whether this volume has an account record, i.e. whether the terminal has ever
# logged in here. That one file is the difference between "MT4 re-logs in from
# startup.ini" and "MT4 sits on an offline chart and looks broken".
login_check() {
  [ -f "$MT4DIR/config/accounts.ini" ]
}

# The first login cannot be automated (see write_startup_ini), so it gets a second
# reminder *after* the terminal had its chance: the startup warning is easy to miss
# in a wall of seeding output, and "the chart says Waiting for update" is what the
# operator actually sees from the outside.
login_watch() {
  sleep "${HEX_LOGIN_WATCH:-90}"
  login_check && return 0
  warn "login: still no config/accounts.ini on this volume ${HEX_LOGIN_WATCH:-90}s after start, so the terminal has not logged in. It cannot do it alone: startup.ini only re-logs an account this volume already knows. Open the desktop and use File -> Login${MT4_LOGIN:+ (login $MT4_LOGIN)}${MT4_SERVER:+ on $MT4_SERVER}; one login is stored on the volume and every later start is automatic."
}

start_display() {
  Xvfb "$DISPLAY" -screen 0 "$SCREEN" +extension GLX +extension RANDR +extension RENDER \
    >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  local n=${DISPLAY#:}; n=${n%%.*}
  for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X${n}" ] && break; sleep 0.2; done
  [ -e "/tmp/.X11-unix/X${n}" ] || die "Xvfb did not start - see /tmp/xvfb.log"
  log "virtual display $DISPLAY ($SCREEN)"
  # A window manager, because MT4 has modal windows and X does not decorate or
  # focus anything by itself. Without one, a dialog is an unmanaged rectangle that
  # can open *behind* the main window, the keyboard focus stays wherever Wine last
  # put it, and there is no title bar - which on MT4 is where the account number and
  # server name are printed. The manual steps (login window, Options, the WebRequest
  # list) all need focus, so this is not cosmetic.
  if command -v openbox >/dev/null 2>&1; then
    openbox --sm-disable >/tmp/openbox.log 2>&1 &
    WM_PID=$!
    log "window manager: openbox (title bars, focus, dialogs raised)"
  else
    warn "no window manager in this image. MT4 windows are then unmanaged: no title bar (the account and server live there), a dialog can open behind the main window, and typing into it may go to the window behind it."
  fi
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
  # A supervisor, not a task: it runs for the life of the container and must never
  # end because one command failed. With `set -e` inherited from the entrypoint that
  # is exactly what happened - `cat` of a `.seen` file that does not exist *yet* (the
  # first time a journal appears) returned 1, the assignment carried it, and this
  # function exited before printing the very line that would have explained why the
  # terminal looked silent. Nothing in here is worth dying for.
  set +e
  set +o pipefail
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
  # Say it out loud even when there is nothing to print. A mirror that stays silent
  # is indistinguishable from a journal that never got written, and that ambiguity
  # is what makes "the terminal shows nothing" so hard to read from `docker logs`.
  printf '%s following %s (%s file(s) there now)\n' "$tag" "$dir" \
    "$(ls -1 "$dir"/*.log 2>/dev/null | wc -l | tr -d '[:space:]')"
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

# The robot's answer to "why did nothing trade" is a CSV row: Reject() appends to
# rejections.csv and returns, it never prints. So the container log - the only
# thing visible on a server - showed a session that took no trades and said
# nothing about why, which is indistinguishable from a robot that did not start.
# These two print instead: each *distinct* rejection as it appears (while a reason
# holds, Reject() writes a row per tick, so only a change is worth a line), and a
# state line every ten minutes with what the files actually contain.
rej_reasons() {  # <file> <max rows> -> "REASON n, REASON n, ..."
  tail -n "${2:-200}" "$1" 2>/dev/null | cut -d, -f3 | grep -v '^reason$' \
    | sort | uniq -c | sort -rn | head -3 \
    | awk '{printf "%s%s %s", sep, $2, $1; sep = ", "}'
}

ea_state_line() {  # <HEX-Logs dir>
  local dir="$1" rej="$1/rejections.csv" trades="$2" n=0 signals last
  [ -f "$rej" ] || { log "state: no rejections.csv yet - the expert has not rejected a setup on this volume"; return 0; }
  if [ -f "$trades" ]; then
    n=$(wc -l < "$trades" 2>/dev/null | tr -d '[:space:]')
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -gt 0 ] && n=$((n - 1))
  fi
  signals="$(tail -n 1 "$dir/daily.csv" 2>/dev/null | cut -d, -f4)"
  last="$(tail -n 1 "$rej" 2>/dev/null | cut -d, -f3)"
  log "state: last 200 rejections -> $(rej_reasons "$rej" 200) | closed trades in trades.csv: $n | signals today: ${signals:-?} | last reason: ${last:-none}"
  if [ "$last" = "AUTOTRADE_DISABLED" ]; then
    warn "the terminal's AutoTrading button is OFF: every setup is being rejected with AUTOTRADE_DISABLED. Nothing outside the terminal can turn it on - open the desktop and click AutoTrading."
  fi
  return 0
}

mirror_rejections() {
  local dir="$MT4DIR/MQL4/Files/Common/HEX-Logs" f="$MT4DIR/MQL4/Files/Common/HEX-Logs/rejections.csv"
  local state="${TMPDIR:-/tmp}/hex-rej" n s i=0
  # Same rule as mirror_dir: a supervisor that must outlive a failed command. The
  # first rejections.csv on a fresh volume arrives *after* this loop started, and
  # reading a `.seen` file that is not there yet must not end the loop.
  set +e
  set +o pipefail
  mkdir -p "$state" 2>/dev/null || true
  # Rows already on the volume are history, not news - the same rule the log
  # mirror follows. (Detail strings can differ per tick, so replaying them all
  # would be a flood rather than a summary.)
  if [ -f "$f" ]; then
    n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$n" > "$state/seen" 2>/dev/null || true
    [ "$n" -gt 1 ] && log "rejections: $((n - 1)) row(s) from earlier runs in $f - not replayed, the file is on the volume"
  fi
  while :; do
    if [ -f "$f" ]; then
      n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
      s=$(cat "$state/seen" 2>/dev/null | tr -d '[:space:]')
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      case "$s" in ''|*[!0-9]*) s=0 ;; esac
      [ "$n" -lt "$s" ] && s=0
      if [ "$n" -gt "$s" ]; then
        tail -n "+$((s + 1))" "$f" 2>/dev/null \
          | awk -F, -v prevf="$state/last" '
              BEGIN { while ((getline l < prevf) > 0) prev = l; close(prevf) }
              { sub(/\r$/, "") }
              $3 == "reason" || NF < 3 { next }
              { key = $3 "|" $13
                if (key == prev) next
                prev = key
                printf "%s  %s %s  %s\n", $1, $3, $4, $13 }
              END { printf "%s", prev > prevf; close(prevf) }' \
          | sed 's/^/[rej] /' || true
      fi
      printf '%s\n' "$n" > "$state/seen" 2>/dev/null || true
    fi
    i=$((i + 1))
    # Two minutes in (the expert needs a bar or two to reject anything) and then
    # every ten, so "no trades" turns into a reason without anyone opening a file.
    if [ "$i" = "24" ] || [ $((i % 120)) -eq 0 ]; then
      ea_state_line "$dir" "$dir/trades.csv" || true
    fi
    sleep 5
  done
}

# A container must be given its own volume. Two terminals writing one MT4 tree
# corrupt each other, and the likelier version of that is quieter: the second
# application is created without its own volume, inherits the first one's
# /data - which holds config/accounts.ini, so it logs in as the first account no
# matter what its env says - and trades the second preset against the first
# account's money. So the volume records which instance claimed it.
claim_volume() {
  local meta marker cur was_inst was_login was_sym
  meta="$(dirname "$MT4DIR")"
  marker="$meta/.hex-instance"
  cur="instance=${MT4_INSTANCE} login=${MT4_LOGIN:-?} symbol=${MT4_SYMBOL} preset=${MT4_PRESET}"
  was_inst=""; was_login=""; was_sym=""
  if [ -f "$marker" ]; then
    was_inst="$(sed -n 's/^instance=\([0-9][0-9]*\).*$/\1/p' "$marker" 2>/dev/null | head -1)"
    was_login="$(sed -n 's/^.* login=\([^ ]*\).*$/\1/p' "$marker" 2>/dev/null | head -1)"
    was_sym="$(sed -n 's/^.* symbol=\([^ ]*\).*$/\1/p' "$marker" 2>/dev/null | head -1)"
  fi
  # Checked before the account, because it explains the account: instance 1 reads
  # the plain MT4_* names and instance 2+ reads the "<n>" copies, so an app that
  # runs at the wrong instance number is exactly how the second volume ends up
  # driving the first account - the symptom is "it still shows the old account
  # and the old chart", with nothing in the log saying why.
  if [ -n "$was_inst" ] && [ "$was_inst" != "$MT4_INSTANCE" ]; then
    die "this volume was claimed by instance $was_inst (account ${was_login:-?}, ${was_sym:-?}), but this container runs as instance $MT4_INSTANCE and so reads the other instance's names. Set MT4_INSTANCE=$was_inst on this application - or, if this volume really is instance $MT4_INSTANCE now, delete $marker and restart, which re-claims it."
    return 1
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

# A volume name is server-wide in Dokploy, not application-wide: typing the same
# name into a second application's "Add volume" means the SAME directory, not a
# second one. Two terminals then share one MT4 tree, and the quieter half of that
# is the report this exists for - both applications read the same
# config/accounts.ini, so both log in as whichever account wrote it last, and the
# second hostname shows the first account no matter what its own env says.
# claim_volume cannot catch that (it is literally the same instance, same volume,
# same login), so the volume carries a lease: who is using it, and when they last
# said so, refreshed every 20s. A heartbeat from another container means exactly
# one thing, so it is said out loud, instead of being left to look like an account
# that will not change.
#
# A predecessor that crashed a second ago leaves a fresh lease too, and a restart
# is not a shared volume. The difference is liveness, and it is observable: the
# other container has to overwrite our lease while we watch. A dead one cannot, so
# the warning is only printed when our own beat comes back as somebody else's.
HEX_LEASE_BEAT="${HEX_LEASE_BEAT:-20}"
HEX_LEASE_PROBE="${HEX_LEASE_PROBE:-30}"

lease_holder() { # <lease> <host> <now> -> "<host> <age seconds>" when it is live
  local lease="$1" host="$2" now="$3" was_host beat age
  local window=$(( ${HEX_LEASE_BEAT:-20} * 3 ))
  [ -f "$lease" ] || return 0
  was_host="$(sed -n 's/^host=\([^ ]*\).*$/\1/p' "$lease" 2>/dev/null | head -1)"
  beat="$(sed -n 's/^.* beat=\([0-9][0-9]*\).*$/\1/p' "$lease" 2>/dev/null | head -1)"
  case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
  [ -n "$was_host" ] || return 0
  [ "$was_host" = "$host" ] && return 0
  # beat=0 is a clean shutdown, not a live container.
  [ "$beat" -gt 0 ] || return 0
  age=$((now - beat))
  [ "$age" -lt "$window" ] || return 0
  printf '%s %s' "$was_host" "$age"
}

lease_write() { # <lease> <host> <now>
  printf 'host=%s instance=%s login=%s beat=%s\n' \
    "$2" "$MT4_INSTANCE" "${MT4_LOGIN:-?}" "$3" > "$1" 2>/dev/null || true
}

lease_shared_warning() { # <meta> <holder>
  warn "shared volume: $1 is in use right now by another container ($2 seconds since its last heartbeat). Both applications are pointed at the same volume name - and in Dokploy a volume name is server-wide, so the same name IS the same directory. Two terminals on one MT4 tree both read config/accounts.ini, so both log in as whichever account wrote it last: that is why a second hostname can show the first application's account. Give each application its own volume name (hex-mt4-data for the first, hex-mt4-doge for the second) and redeploy both."
}

lease_volume() {
  local meta lease host now holder
  meta="$(dirname "$MT4DIR")"
  lease="$meta/.hex-lease"
  host="${HEX_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}"
  now="$(date +%s)"
  mkdir -p "$meta" 2>/dev/null || true
  holder="$(lease_holder "$lease" "$host" "$now")"
  lease_write "$lease" "$host" "$now"
  [ -n "$holder" ] || return 0
  # Someone else's heartbeat was here. Wait one beat: if it overwrites ours, it is
  # running now; if ours survives, that lease was left by a container that is gone.
  sleep "${HEX_LEASE_PROBE:-30}"
  now="$(date +%s)"
  holder="$(lease_holder "$lease" "$host" "$now")"
  [ -n "$holder" ] || return 0
  lease_shared_warning "$meta" "$holder"
}

# Keeps the lease fresh, and looks again: a second container that comes up ten
# minutes later shares the volume silently as far as this boot was concerned.
lease_beat() {
  local meta lease host now holder last=""
  # A supervisor too: a failed write must not stop the beat, or a live container
  # starts looking dead and the shared-volume warning fires on a healthy pair.
  set +e
  set +o pipefail
  meta="$(dirname "$MT4DIR")"
  lease="$meta/.hex-lease"
  host="${HEX_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}"
  while :; do
    sleep "${HEX_LEASE_BEAT:-20}"
    now="$(date +%s)"
    holder="$(lease_holder "$lease" "$host" "$now")"
    if [ -n "$holder" ]; then
      if [ "${holder%% *}" = "$last" ]; then
        # The same container overwrote our beat twice: it is alive. Once per ten
        # beats is enough to be seen in `docker logs` without burying the
        # terminal's journal under it.
        lease_shared_warning "$meta" "$holder"
        last=""
        sleep $(( ${HEX_LEASE_BEAT:-20} * 19 ))
        continue
      fi
      last="${holder%% *}"
    else
      last=""
    fi
    lease_write "$lease" "$host" "$now"
  done
}

lease_release() { # a clean stop is not a container that is still using the volume
  local meta lease host
  meta="$(dirname "$MT4DIR")"
  lease="$meta/.hex-lease"
  host="${HEX_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}"
  lease_write "$lease" "$host" 0
}

banner() {
  log "----------------------------------------------------------------"
  log " HEX-FVG-Breaker on MT4 | instance $MT4_INSTANCE | ${MT4_SYMBOL}${MT4_PERIOD:+ ${MT4_PERIOD}m} | $MT4_EXPERT | preset $MT4_PRESET"
  log " image build  : ${HEX_BUILD:-unknown - a local build, not a CI image}"
  log " account      : ${MT4_LOGIN:-<unset>} @ ${MT4_SERVER:-<unset>}"
  if [ "$MT4_INSTANCE" = "1" ]; then
    log " instance env : the unsuffixed names (MT4_LOGIN, MT4_SYMBOL, ...)"
  else
    log " instance env : the \"$MT4_INSTANCE\" copies (MT4_LOGIN$MT4_INSTANCE, MT4_SYMBOL$MT4_INSTANCE, ...)"
  fi
  log " data folder  : $MT4DIR (portable, on the volume)"
  log " mt4 journal  : $MT4DIR/logs          - mirrored below as [mt4]"
  log " ea prints    : $MT4DIR/MQL4/Logs     - mirrored below as [ea]"
  log " ea csv logs  : $MT4DIR/MQL4/Files/Common/HEX-Logs"
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
cap_has_bit() { # hexset bit -> 0 when the bit is set (a test, not a value)
  local set="$1" bit="$2"
  [ -n "$set" ] || return 1
  (( (16#$set >> bit) & 1 ))
}

report_isolation() {
  local shm_kb cap_bnd cap_eff
  shm_kb="$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
  shm_kb="${shm_kb:-0}"
  if [ "$shm_kb" -gt 0 ] && [ "$shm_kb" -lt 131072 ]; then
    warn "/dev/shm is $((shm_kb / 1024)) MB. Xvfb and Wine share it to draw, so a blank desktop or 'BadAccess (MIT-SHM)' in this log is that. Compose can raise it (shm_size: 512m); a Docker-Image app cannot."
  elif [ "$shm_kb" -gt 0 ]; then
    log " shm          : $((shm_kb / 1024)) MB (enough for Xvfb + Wine)"
  fi
  # Two different questions, and only the first one is the container's setting:
  # CapBnd is what the container was *given* (cap_add), CapEff is what this
  # process may use right now. The entrypoint runs as `trader` after gosu dropped
  # root, and a setuid from root clears the effective set - so CapEff is empty for
  # everyone here even when cap_add worked. Asking CapEff produced a warning on
  # every healthy container; ask CapBnd, and mention CapEff only as the reason.
  cap_bnd="$(awk '/^CapBnd:/ {print $2}' /proc/self/status 2>/dev/null)"
  cap_eff="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null)"
  if cap_has_bit "$cap_bnd" 19; then
    if cap_has_bit "$cap_eff" 19; then
      log " CAP_SYS_PTRACE: present"
    else
      log " CAP_SYS_PTRACE: granted to the container, not to the trader process (gosu dropped root, which clears the effective set). Wine traces its own children, and that needs no capability."
    fi
  elif [ -n "$cap_bnd" ]; then
    warn "CAP_SYS_PTRACE is not in this container. Wine only wants it to attach a debugger, so this is usually harmless - but if no smiley face ever appears next to the expert name, this is one of the two candidates (the other is AutoTrading, which the EA reports itself)."
  fi
}

on_term() {
  trap - TERM INT
  log "SIGTERM - asking MT4 to close so it flushes its journal and the EA's CSVs"
  lease_release || true
  wineserver -k >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f 'terminal\.exe' >/dev/null || break
    sleep 1
  done
  pgrep -f 'terminal\.exe' >/dev/null && warn "terminal.exe still alive after 25s, killing it"
  [ -n "$X11VNC_PID" ] && kill "$X11VNC_PID" 2>/dev/null || true
  [ -n "$WEBSOCKIFY_PID" ] && kill "$WEBSOCKIFY_PID" 2>/dev/null || true
  [ -n "$WM_PID" ] && kill "$WM_PID" 2>/dev/null || true
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
  lease_volume
  lease_beat &
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
  mirror_rejections &
  launch_terminal
  login_watch &
  wait_for_terminal

  # The terminal's exit code decides the container's. No silent restart loop: a
  # crash belongs in `docker logs`, and the restart policy belongs to the operator.
  local rc=0
  wait "$TERMINAL_PID" || rc=$?
  lease_release || true
  log "terminal.exe exited with code $rc"
  exit "$rc"
}

main "$@"



