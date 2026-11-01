# syntax=docker/dockerfile:1
#
# HEX-BoomRider on a server: MetaTrader 5 under Wine, headless, in a container.
#
# The robot runs on the server, not on your laptop, and keeps running when your
# laptop is closed. Two stages:
#
#   ea-check  compiles MQL5/Experts/HEX-BoomRider.mq5 with a real
#             metaeditor64.exe, so a commit whose MQL5 does not compile cannot
#             produce an image. It needs a terminal to compile with, and
#             MetaTrader has to be supplied: MetaQuotes' own mt5setup.exe is a
#             64-bit web installer that installs nothing under Wine (probed on
#             Wine 8/Debian bookworm, same as mt4setup.exe). The terminal comes
#             from MT5_DISTRO_URL, the tarball deploy/scripts/prepare-distro.sh
#             produces from a Deriv MT5 install. Without that variable the stage
#             skips the compile and says so; the container then compiles from
#             source at start or uses a baked-in binary.
#
#   runtime   Wine, a virtual display, a remote desktop for the one-time look,
#             and deploy/scripts/entrypoint.sh. The image does not ship
#             MetaTrader: the terminal arrives as a prepared distro (MT5_DISTRO_URL
#             or a tarball dropped at /data).
#
# Build:  docker build -f deploy/Dockerfile -t hex-mt5 .
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

COPY MQL5/Experts/HEX-BoomRider.mq5 /opt/ea/HEX-BoomRider.mq5
COPY MQL5/Presets/ /opt/ea/presets/

ARG MT5_DISTRO_URL=""
RUN set -eux; \
    mkdir -p /opt/ea-built; \
    if [ -z "$MT5_DISTRO_URL" ]; then \
      echo "[ea-check] MT5_DISTRO_URL is not set, so there is no terminal to compile with."; \
      echo "[ea-check] Skipping the CI compile check; the container compiles the EA from source at start."; \
      echo "no distro in this build: the container compiles the EA from source at start" \
        > /opt/ea-built/compile.log; \
      exit 0; \
    fi; \
    curl -fsSL --retry 3 -o /tmp/distro.tar "$MT5_DISTRO_URL"; \
    mkdir -p /tmp/distro; \
    case "$MT5_DISTRO_URL" in \
      *.zst|*.tzst) tar --use-compress-program=unzstd -xf /tmp/distro.tar -C /tmp/distro ;; \
      *.gz|*.tgz)   tar -xzf /tmp/distro.tar -C /tmp/distro ;; \
      *)            tar -xf  /tmp/distro.tar -C /tmp/distro ;; \
    esac; \
    md="$(find /tmp/distro -maxdepth 4 -iname terminal64.exe -printf '%h\n' -quit)"; \
    echo "[ea-check] compiling with the terminal at: ${md:-<none>}"; \
    test -n "$md"; \
    cp /opt/ea/HEX-BoomRider.mq5 "$md/MQL5/Experts/"; \
    mkdir -p "$md/MQL5/Presets"; cp /opt/ea/presets/*.set "$md/MQL5/Presets/" 2>/dev/null || true; \
    rm -f "$md/MQL5/Experts/HEX-BoomRider.ex5"; \
    # xvfb-run because Wine is a Windows GUI runtime even when the program it \
    # runs is a command-line compile; /log captures the verdict to a file. \
    cd "$md" \
    && xvfb-run -a wine metaeditor64.exe "/compile:MQL5\\Experts\\HEX-BoomRider.mq5" "/log:MQL5\\Experts\\compile.log" \
    || true; \
    wineserver -w || true; \
    test -f "$md/MQL5/Experts/HEX-BoomRider.ex5" || { cat "$md/MQL5/Experts/compile.log" 2>/dev/null; exit 1; }; \
    cp "$md/MQL5/Experts/HEX-BoomRider.ex5" /opt/ea-built/; \
    cp "$md/MQL5/Experts/compile.log" /opt/ea-built/; \
    echo "[ea-check] HEX-BoomRider.ex5 compiled clean"

# ------------------------------------------------------------------ runtime --

FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/home/trader/.wine \
    WINEARCH=win64 \
    WINEDLLOVERRIDES=mscoree,mshtml= \
    WINEDEBUG=-all \
    MT5DIR=/data/mt5

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip zstd unzip \
      procps psmisc gosu tini tzdata fonts-liberation \
      wine wine32 wine64 \
      xvfb xauth x11vnc xdotool \
      openbox \
      novnc websockify \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# A fixed uid, not root: the Wine prefix and the volume belong to uid 1000, which
# is also the owner docker gives a fresh named volume.
RUN useradd --create-home --uid 1000 trader \
 && mkdir -p /data /opt/ea/presets \
 && chown -R trader:trader /home/trader /data

COPY MQL5/Experts/HEX-BoomRider.mq5 /opt/ea/HEX-BoomRider.mq5
COPY MQL5/Presets/ /opt/ea/presets/
# The CI-checked .ex5 and its compiler log, when the build had a terminal to
# compile with: the entrypoint falls back to this binary when a runtime compile
# cannot run, and the log is the audit trail.
COPY --from=ea-check /opt/ea-built/ /opt/ea-built/
RUN set -eux; \
    if [ -f /opt/ea-built/HEX-BoomRider.ex5 ]; then \
      cp -f /opt/ea-built/HEX-BoomRider.ex5 /opt/ea/HEX-BoomRider.ex5; \
      echo "[build] shipped the .ex5 compiled during the build"; \
    else \
      echo "[build] no .ex5 in this build: the container compiles the EA from source at start"; \
    fi; \
    cp -f /opt/ea-built/compile.log /opt/ea/compile.log; \
    ls -l /opt/ea/
COPY deploy/scripts/entrypoint.sh /opt/hex/entrypoint.sh
COPY deploy/scripts/healthcheck.sh /opt/hex/healthcheck.sh
RUN chmod 0755 /opt/hex/*.sh

# Which commit this image is; printed as the banner's first line.
ARG HEX_BUILD="local"
ENV HEX_BUILD="${HEX_BUILD}"

# Bake a prepared terminal into the image instead of seeding it from the volume.
# Empty by default: an image without MetaQuotes' binaries is the cleaner default.
ARG MT5_DISTRO_URL=""
RUN set -eux; \
    if [ -n "$MT5_DISTRO_URL" ]; then \
      curl -fsSL --retry 3 -o /tmp/distro.tar "$MT5_DISTRO_URL"; \
      mkdir -p /opt/mt5-distro; \
      case "$MT5_DISTRO_URL" in \
        *.zst|*.tzst) tar --use-compress-program=unzstd -xf /tmp/distro.tar -C /opt/mt5-distro ;; \
        *.gz|*.tgz)   tar -xzf /tmp/distro.tar -C /opt/mt5-distro ;; \
        *)            tar -xf  /tmp/distro.tar -C /opt/mt5-distro ;; \
      esac; \
      rm -f /tmp/distro.tar; \
      test -f /opt/mt5-distro/terminal64.exe; \
      echo "[build] baked an MT5 distro from $MT5_DISTRO_URL"; \
    fi

# Create the Wine prefix at build time so the first start does not spend a
# minute on wineboot while the market is running.
RUN gosu trader env HOME=/home/trader xvfb-run -a wine wineboot --init \
 && gosu trader env HOME=/home/trader xvfb-run -a wineserver -w || true

VOLUME /data
EXPOSE 5900 6080
STOPSIGNAL SIGTERM
# Reports only - see deploy/scripts/healthcheck.sh for why it never restarts.
HEALTHCHECK --interval=5m --timeout=30s --start-period=10m --retries=3 CMD ["/opt/hex/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/hex/entrypoint.sh"]

