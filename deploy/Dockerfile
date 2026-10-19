# syntax=docker/dockerfile:1
#
# HEX-FVG-Breaker on a server: MetaTrader 4 under Wine, headless, in a container.
#
# The point of this file is that the robot runs on the server, not on your laptop,
# and that it keeps running when your laptop is closed or asleep.
#
# Two stages.
#
#   ea-check  compiles MQL4/Experts/HEX-FVG-Breaker.mq4 with a real
#             metaeditor.exe, so a commit whose MQL4 does not compile cannot
#             produce an image - the same verdict Tools/mt4_compile.sh gives
#             locally, now enforceable on every build.
#
#             It needs a terminal to compile with, and MetaTrader has to be
#             supplied: MetaQuotes' own installer does not work under Wine.
#             Probed on Wine 8 (Debian bookworm): mt4setup.exe is a 64-bit web
#             installer (PE32+, machine 8664) that exits silently, installs
#             nothing, and does not even open a window, in both a win32 and a
#             win64 prefix. So the terminal comes from MT4_DISTRO_URL, the
#             tarball deploy/scripts/prepare-distro.sh produces. Without that
#             variable this stage skips the compile and says so, and the
#             container compiles from source at start instead.
#
#   runtime   what the container runs: Wine, a virtual display, a remote desktop
#             for the one-time look, and deploy/scripts/entrypoint.sh. The image
#             does not ship MetaTrader: the terminal arrives as a prepared distro
#             in the volume (MT4_DISTRO_URL, see deploy/scripts/prepare-distro.sh,
#             or a tarball dropped at /data). That keeps MetaQuotes' binaries out
#             of the registry and lets the same image point at another broker's
#             terminal without a rebuild.
#
# Build:  docker build -f deploy/Dockerfile -t hex-mt4 .
# Run:    see deploy/docker-compose.yml

FROM debian:bookworm-slim AS ea-check

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/tmp/wine \
    WINEARCH=win64 \
    WINEDLLOVERRIDES=mscoree,mshtml= \
    WINEDEBUG=-all

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xvfb xauth tar gzip zstd \
      wine wine32 wine64 \
 && rm -rf /var/lib/apt/lists/*

COPY MQL4/Experts/HEX-FVG-Breaker.mq4 /opt/ea/HEX-FVG-Breaker.mq4

ARG MT4_DISTRO_URL=""
RUN set -eux; \
    mkdir -p /opt/ea-built; \
    if [ -z "$MT4_DISTRO_URL" ]; then \
      echo "[ea-check] MT4_DISTRO_URL is not set, so there is no terminal to compile with."; \
      echo "[ea-check] Skipping the CI compile check; the container compiles the EA from source at start."; \
      echo "no distro in this build: the container compiles the EA from source at start" \
        > /opt/ea-built/compile.log; \
      exit 0; \
    fi; \
    curl -fsSL --retry 3 -o /tmp/distro.tar "$MT4_DISTRO_URL"; \
    mkdir -p /tmp/distro; \
    case "$MT4_DISTRO_URL" in \
      *.zst|*.tzst) tar --use-compress-program=unzstd -xf /tmp/distro.tar -C /tmp/distro ;; \
      *.gz|*.tgz)   tar -xzf /tmp/distro.tar -C /tmp/distro ;; \
      *)            tar -xf  /tmp/distro.tar -C /tmp/distro ;; \
    esac; \
    md="$(find /tmp/distro -maxdepth 4 -iname terminal.exe -printf '%h\n' -quit)"; \
    echo "[ea-check] compiling with the terminal at: ${md:-<none>}"; \
    test -n "$md"; \
    cp /opt/ea/HEX-FVG-Breaker.mq4 "$md/MQL4/Experts/"; \
    rm -f "$md/MQL4/Experts/HEX-FVG-Breaker.ex4"; \
    # xvfb-run because Wine is a Windows GUI runtime even when the program it runs
    # is silent, and a build has no display.
    ( cd "$md" && xvfb-run -a wine metaeditor.exe \
        '/compile:MQL4\Experts\HEX-FVG-Breaker.mq4' '/log:C:\ea-check.log' ) || true; \
    xvfb-run -a wineserver -w || true; \
    if [ -f "$WINEPREFIX/drive_c/ea-check.log" ]; then \
      iconv -f UTF-16LE -t UTF-8 "$WINEPREFIX/drive_c/ea-check.log" \
        | sed -e 's/\r$$//' -e '/^$$/d'; \
      cp "$WINEPREFIX/drive_c/ea-check.log" /opt/ea-built/compile.log; \
    fi; \
    # The .ex4, not the exit code, is the verdict: MetaEditor returns 0 either way.
    test -f "$md/MQL4/Experts/HEX-FVG-Breaker.ex4"; \
    cp "$md/MQL4/Experts/HEX-FVG-Breaker.ex4" /opt/ea-built/; \
    echo "[ea-check] OK: compiled $(stat -c %s /opt/ea-built/HEX-FVG-Breaker.ex4) bytes"


FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    TZ=UTC \
    DISPLAY=:99 \
    SCREEN=1440x900x24 \
    WINEARCH=win64 \
    WINEPREFIX=/home/trader/.wine \
    HOME=/home/trader \
    WINEDLLOVERRIDES=mscoree,mshtml= \
    WINEDEBUG=-all \
    MT4DIR=/data/mt4

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip zstd unzip \
      procps psmisc gosu tini tzdata fonts-liberation \
      wine wine32 wine64 \
      xvfb xauth x11vnc xdotool \
      novnc websockify \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# A fixed uid, not root: the Wine prefix and the volume belong to uid 1000, which
# is also the owner docker gives a fresh named volume.
RUN useradd --create-home --uid 1000 trader \
 && mkdir -p /data /opt/ea/presets \
 && chown -R trader:trader /home/trader /data

COPY MQL4/Experts/HEX-FVG-Breaker.mq4 /opt/ea/HEX-FVG-Breaker.mq4
COPY MQL4/Presets/ /opt/ea/presets/
# The CI-checked .ex4 and its compiler log, when the build had a terminal to
# compile with: the entrypoint falls back to this binary when a runtime compile
# cannot run, and the log is the audit trail. The whole directory is copied so a
# build without a distro (no .ex4) still works.
COPY --from=ea-check /opt/ea-built/ /opt/ea-built/
RUN set -eux; \
    if [ -f /opt/ea-built/HEX-FVG-Breaker.ex4 ]; then \
      cp -f /opt/ea-built/HEX-FVG-Breaker.ex4 /opt/ea/HEX-FVG-Breaker.ex4; \
      echo "[build] shipped the .ex4 compiled during the build"; \
    else \
      echo "[build] no .ex4 in this build: the container compiles the EA from source at start"; \
    fi; \
    cp -f /opt/ea-built/compile.log /opt/ea/compile.log; \
    ls -l /opt/ea/
COPY deploy/scripts/ /opt/hex/
RUN chmod 0755 /opt/hex/*.sh

# Bake a prepared terminal into the image instead of seeding it from the volume.
# Empty by default: an image without MetaQuotes' binaries in it is the cleaner
# default, and MT4_DISTRO_URL still works at runtime.
ARG MT4_DISTRO_URL=""
RUN set -eux; \
    if [ -n "$MT4_DISTRO_URL" ]; then \
      curl -fsSL --retry 3 -o /tmp/distro.tar "$MT4_DISTRO_URL"; \
      mkdir -p /opt/mt4-distro; \
      case "$MT4_DISTRO_URL" in \
        *.zst|*.tzst) tar --use-compress-program=unzstd -xf /tmp/distro.tar -C /opt/mt4-distro ;; \
        *.gz|*.tgz)   tar -xzf /tmp/distro.tar -C /opt/mt4-distro ;; \
        *)            tar -xf  /tmp/distro.tar -C /opt/mt4-distro ;; \
      esac; \
      rm -f /tmp/distro.tar; \
      test -f /opt/mt4-distro/terminal.exe; \
      echo "[build] baked an MT4 distro from $MT4_DISTRO_URL"; \
    fi

# Create the Wine prefix at build time so the first start does not spend a minute
# on wineboot while the market is running.
RUN gosu trader env HOME=/home/trader xvfb-run -a wine wineboot --init \
 && gosu trader env HOME=/home/trader xvfb-run -a wineserver -w || true

VOLUME /data
EXPOSE 5900 6080
STOPSIGNAL SIGTERM
# Reports only - see deploy/scripts/healthcheck.sh for why it never restarts.
HEALTHCHECK --interval=5m --timeout=30s --start-period=10m --retries=3 CMD ["/opt/hex/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/hex/docker-entrypoint.sh"]

