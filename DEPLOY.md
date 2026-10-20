# Deploy — the robot runs on a server, not on your laptop

The point of this file: `HEX-FVG-Breaker` trading on XAUUSD M15 with **your**
machine off, asleep, or in a bag. Everything here is a container that builds and
publishes through the same GHCR pattern as the other repos (`skyf`, `agentlinks`,
`text-stream`): GitHub Actions builds an image, GHCR stores it, Dokploy runs it.

What you get that a laptop does not:

| | laptop | server |
|---|---|---|
| survives F5, sleep, closing the lid | no | yes |
| the terminal keeps ticking over the weekend gap | no | yes |
| logs, CSVs and the chart survive a redeploy | n/a | yes, they are on the volume |
| you can look at the desktop from a phone | no | yes, noVNC |

This is the **A** path in the deployment choices: Linux VPS + Docker. Two other
paths exist and are worth knowing about (§8) — MetaQuotes' own MetaTrader VPS,
which is a few clicks inside the terminal, and a Windows VPS, which is MT4-native
but does not fit the GHCR/Dokploy stack.

---

## 1. What actually runs

```
GitHub push ─► Actions: build deploy/Dockerfile ─► ghcr.io/<you>/forex-hex-mt4:live
                                                          │
                                          Dokploy pulls the image
                                                          │
                     ┌────────────────────────────────────┴───────────────┐
                     │ container (linux/amd64)                            │
                     │   tini ─► docker-entrypoint.sh (root → trader)     │
                     │            └─ entrypoint.sh                        │
                     │                 Xvfb :99  + x11vnc + noVNC :6080   │
                     │                 wine terminal.exe /portable         │
                     │                                      startup.ini    │
                     │   volume /data ◄── the whole MT4 data folder:       │
                     │                    profiles/, config/, MQL4/         │
                     │                    Files/Common/HEX-Logs/*.csv      │
                     └────────────────────────────────────────────────────┘
```

Two facts drive the whole design:

- **MT4 in portable mode keeps everything next to `terminal.exe`.** So the data
  folder *is* the install folder, and mounting it as a volume is all that is
  needed for the 30-day demo in `DEMO-PLAN.md` to survive redeploys. The CSVs the
  plan reads live at `/data/mt4/MQL4/Files/Common/HEX-Logs/`.
- **The image does not contain MetaTrader.** The terminal is *supplied* — a
  portable MT4 directory you prepare once with `deploy/scripts/prepare-distro.sh`
  and hand to the container (§4). MetaQuotes' own installer cannot be used: it is
  a 64-bit web installer that exits silently under Wine and installs nothing
  (probed, in both prefix types). That has a good side — the same image runs any
  broker's terminal without a rebuild, and MetaQuotes' binaries stay out of the
  registry.

The image *does* contain the EA source and the presets, from this repo. On every
start the entrypoint copies `HEX-FVG-Breaker.mq4` into the terminal and compiles
it with the real `metaeditor.exe`, so the robot that runs is the robot in git.
If that compile fails, it says so and falls back to the `.ex4` that the build
compiled and checked in CI — see `deploy/scripts/entrypoint.sh`.

---

## 2. The 30-second version

Once, on the server (Dokploy → Compose → new app, paste `deploy/docker-compose.yml`):

```bash
MT4_LOGIN=<demo login>
MT4_PASSWORD=<demo password>
MT4_SERVER=MetaQuotes-Demo      # or your broker's server
VNC_PASSWORD=<something>        # required, or there is no desktop at all
MT4_SYMBOL=XAUUSD
MT4_PRESET=100usd-demo
TZ=UTC
```

Then open `http://<server>:6080/vnc.html`, log in with `VNC_PASSWORD`, and check
the two things a headless start cannot check for you (§3). After that, the
terminal is on its own: a new commit builds a new image, Dokploy restarts the
container, the entrypoint recompiles the EA from that commit, and the chart comes
back exactly as it was because the profile is on the volume.

---

## 3. The one look you have to take

Two switches in MetaTrader decide whether the EA may trade, and neither of them
can be set reliably from outside the running terminal. This is not a container
problem — it is the same on any MT4 VPS — and it is the same thing that made this
EA look broken on the laptop.

**1. AutoTrading (the button in the toolbar).** Its state is not on disk. Not in
`terminal.ini`, not in `experts.ini`, not anywhere that survived a diff of the
whole data folder across a start/click/quit cycle. So the entrypoint asks for it
the only way MT4 allows — `ExpertsTrades=true` in `startup.ini` — and does not
pretend to know whether it worked. Instead the EA now *says*:

- on the chart: `Trading   : ON  (AutoTrading)` or `Trading   : BLOCKED - enable AutoTrading`
- on your phone, on every start: the INIT push ends with `AutoTrading ON` or
  `AutoTrading BLOCKED`

The `Status : armed` line means only "the kill switch has not tripped". A robot
with `Status : armed` and `Trading : BLOCKED` places no trades, which is exactly
the silent week this pair of lines exists to prevent. If a start reports BLOCKED,
click the button once in noVNC. It stays on for the life of that terminal.

**2. The WebRequest allow-list** (`Tools > Options > Expert Advisors > Allow
WebRequest for listed URL`). The ntfy URL must be listed or every push fails with
`err 4060`. That list lives in `config/experts.ini`, which is a *binary* file —
the URL is in there as UTF-16 among flag words — so nothing in `deploy/` writes
it. Two supported ways to have it set:

- **carry it from a machine where it is already set**: `deploy/scripts/prepare-distro.sh`
  (§4) copies a prepared terminal, and this file comes with it;
- **set it once in the noVNC desktop**: Options → Expert Advisors → tick the box,
  paste `https://ntfy.sh`, OK. It persists in the volume from then on.

You can tell it worked from the phone alone: the INIT push arrives. If it does
not, the dashboard's `Push : 0 sent, 1 failed (webrequest failed, err 4060)` and
`FIRST-RUN.md §7` name the cause.

**While you are in that dialog anyway**, look at the three checkboxes above the
list: *Disable automated trading when the account has been changed*, *…when the
profile has been changed*, *…when the charts symbol or period has been changed*.
Any of them ticked lets MT4 switch AutoTrading off by itself — which is the most
likely explanation for a terminal that comes back from a restart unable to trade.
Untick all three.

Do this once, on the first start. Then the state lives in the volume and the
desktop is for emergencies only.

---

## 4. Getting a terminal into the volume (required)

**A. Prepare it on the machine that already works (the supported path).** On the
Mac, with MetaTrader closed:

```bash
deploy/scripts/prepare-distro.sh
# writes dist/mt4-portable.tar.gz, prints its size, its sha256 and what it found
```

It archives the data folder — in portable mode that *is* the install folder —
leaving out `history/`, `logs/`, `tester/`, `Sounds/` and `_autobackup_*`. The
result is 36 MB for the current install and carries the things no installer
reproduces: the WebRequest allow-list for ntfy, the Options flags from §3, the
seeded XAUUSD M15 chart with the EA on it, and the account you are already logged
into. They live in `config/` and `profiles/`, which is why the archive is the
deliverable rather than a checklist.

Then get it onto the server. With a bind mount in the compose file — change
`- hex-mt4-data:/data` to `- /opt/hex-mt4:/data` — the whole thing is `scp`:

```bash
scp dist/mt4-portable.tar.gz user@server:/opt/hex-mt4/
# compose env: MT4_DISTRO_URL=file:///data/mt4-portable.tar.gz
```

`file://` works because the entrypoint uses `curl`, so the tarball only has to be
inside the mounted directory. No hosting, no URL to publish. (With a named volume
instead of a bind mount, use `docker cp mt4-portable.tar.gz <container>:/data/`.)

Restart the container and it seeds, compiles and launches — §7 shows what that
looks like in the log.

**B. Let the container try MetaQuotes' installer.** Leave `MT4_DISTRO_URL` empty
and it downloads `mt4setup.exe` and runs `/auto`. **Expect this to fail**, and the
log will say so with the installer's own output: the installer is 64-bit, exits
silently under Wine, installs nothing and never opens a window. It is left in
place because a future Wine, or a broker's branded installer, may behave
differently — and a container that tries and explains itself beats one that
refuses. If you point `MT4_SETUP_URL` at a broker's own installer and it *does*
work, everything downstream (compile, `startup.ini`, volume) is identical.

**Only one terminal per account.** Once the server is trading, do not also run
the Mac copy: two terminals on one account is two robots, and the preset's
`MaxOpenTrades=1` bounds each of them separately, not the pair.


---

## 5. The image: what builds it, where it lands

`.github/workflows/deploy.yml` follows the same shape as the other repos: build
`deploy/Dockerfile`, push to GHCR, tag `:live` for `main` plus the commit SHA.

```
ghcr.io/thamitshepe/forex-hex-mt4:live      <- what Dokploy runs
ghcr.io/thamitshepe/forex-hex-mt4:<sha>     <- the rollback tag
```

Four things worth knowing, all of them checked rather than assumed:

- **The owner is whoever owns the repo the workflow runs in.** `Manged3/...` is
  read-only for the current token, so the workflow runs from the fork
  (`thamitshepe/Forex-hex-algo-strategy-mt4`, wired up as the `fork` remote) and
  the image lands under that account's namespace. If you publish somewhere else,
  change `image:` in `deploy/docker-compose.yml` to match. The workflow itself
  needs no edit: it uses `${{ github.repository_owner }}`.
- **The package is public, so Dokploy needs no registry credential.**
  `GET https://ghcr.io/v2/thamitshepe/forex-hex-mt4/tags/list` answers `200` to an
  anonymous pull-scoped token and lists `live` and the commit SHA. If you would
  rather have it private, flip it in the repo's Packages tab and add a registry
  credential in Dokploy (registry `ghcr.io`, username = the GitHub account,
  password = a PAT with `read:packages`). The image holds no secrets either way —
  credentials live in the environment and on the volume, never in the image.
- **The build fails if the EA does not compile** — once `MT4_DISTRO_URL` is set
  as a repository variable. That is a feature: green CI and a working robot are
  the same fact here. Without that variable the `ea-check` stage prints
  `MT4_DISTRO_URL is not set` and skips, and the container compiles from source
  at first start instead (slower to boot, same result).
- **It is `linux/amd64` only**, which is what a normal VPS is. The published
  manifest is an OCI index holding one `linux/amd64` image plus buildkit's
  provenance attestation.

### What is left to set on GitHub

Repository variables are not secrets — they are a URL, a UUID and a tarball URL —
so they belong in Settings → Variables, not Settings → Secrets:

| kind | name | what it is |
|---|---|---|
| variable | `MT4_DISTRO_URL` | the prepared terminal tarball from §4A. At runtime it is how the terminal arrives; passed to the build it is also what makes `ea-check` download it, compile the EA with the real `metaeditor.exe`, and bake the `.ex4` into the image — the version of "the build fails if the EA does not compile" that covers *every* commit rather than only the ones where someone remembers to compile locally |
| variable | `DOKPLOY_URL` | the Dokploy instance, e.g. `https://dokploy.example.com`, no trailing slash |
| variable | `DOKPLOY_COMPOSE_ID` | the Compose app's id. `GET <DOKPLOY_URL>/api/project.all` with the `x-api-key` header lists it |
| secret | `DOKPLOY_API_TOKEN` | a Dokploy API token (Settings → API Keys). With the three above, the `deploy` job calls `POST /api/compose.deploy` |
| secret | `DOKPLOY_WEBHOOK` | the alternative trigger: the webhook URL from the app's Deployments tab. Used only when the API triple is incomplete — and read as a git-provider push, so §6 applies |

Leave all five unset and the workflow still does the useful half: it publishes
`live` and the SHA, and the `deploy` job prints a notice instead of failing.

---

## 6. Dokploy

**Compose app (what `deploy/docker-compose.yml` is for).** New Compose app →
paste the file → set the environment. The file already carries the two settings
that are easy to leave out and hard to debug: `cap_add: [SYS_PTRACE]` (Wine needs
ptrace to attach to the processes it spawns; without it the EA never loads) and
`shm_size: 512m` (Xvfb and Wine share memory to draw; too small shows up as
`BadAccess (MIT-SHM)` and a dead desktop).

| variable | what it is |
|---|---|
| `MT4_LOGIN` / `MT4_PASSWORD` / `MT4_SERVER` | the demo account the terminal logs into |
| `MT4_SYMBOL` / `MT4_PRESET` | what to trade: `XAUUSD` + `100usd-demo.set` |
| `MT4_PROFILE` | which profile in the volume to open (default `default`) |
| `ENABLE_VNC` / `VNC_PASSWORD` | the remote desktop. Empty password ⇒ no desktop, deliberately |
| `TZ` | leave `UTC`: the preset's trading hours are UTC |
| `MT4_DISTRO_URL` | the prepared terminal. Required in practice: `file:///data/mt4-portable.tar.gz` |
| `HEX_HEARTBEAT_MAX_AGE_MIN` | how stale `equity.csv` may be before healthcheck says so |

Volume: `hex-mt4-data` at `/data`. Everything that matters — the terminal, the
profile with the chart, the compiled EA, the HEX-Logs CSVs — is under it, so a
redeploy is not a restart of the demo.

**Registry pull: not needed.** The package is public (§5), so Dokploy pulls
`ghcr.io/thamitshepe/forex-hex-mt4:live` with no credential at all. Only if you
make the package private do you add one here (registry `ghcr.io`, username = the
GitHub account, password = a PAT with `read:packages`).

**Where the environment goes.** Dokploy's environment editor writes what you type
to a `.env` file next to the compose file, and Compose reads that file for
`${VAR}` substitution by itself. That is why `deploy/docker-compose.yml` spells
`${MT4_LOGIN}` inside `environment:` instead of using an `env_file:` — no extra
wiring, and the `:?` guards still work, so a Compose app started without
`MT4_LOGIN` fails loudly rather than coming up with an empty login.

**Triggering a redeploy.** Three ways, ordered by how little they ask of you:

1. **Dokploy's GitHub App.** Point the Compose app at
   `thamitshepe/Forex-hex-algo-strategy-mt4`, branch `main`, compose path
   `deploy/docker-compose.yml`, and switch Auto Deploy on. Dokploy's GitHub
   integration then deploys on push with no webhook and no CI change. The branch
   configured here has to be the branch you push to — Dokploy answers
   `301 Branch Not Match` otherwise.
2. **The API, from CI.** Set `DOKPLOY_URL`, `DOKPLOY_COMPOSE_ID` and
   `DOKPLOY_API_TOKEN` (§5) and the workflow calls `POST /api/compose.deploy`
   once the image is pushed. This is Dokploy's documented CI path, and the only
   one indifferent to source type, branch and Watch Paths.
3. **The webhook URL.** `DOKPLOY_WEBHOOK` = the URL on the app's Deployments tab.
   Dokploy reads that URL as a git-provider push: its handler compares `body.ref`
   with the app's branch, and reads `commits[].{added,modified,removed}` to match
   Watch Paths. The workflow sends the branch and an empty `commits[]`, which
   passes only while **Watch Paths is unset** — so prefer 1 or 2 if you ever set
   one.

**Turn on "Pull latest images on deploy."** It is in the Compose app's Advanced
tab, it adds `--pull always` to the `up -d` Dokploy runs, and it has no effect if
you have set a custom command. Without it a redeploy of a *moving* tag like
`:live` can reuse the image already on the host — Docker matches the tag, not the
new digest. That is the difference between "the server picked up the new EA" and
"the server is still trading last week's build".

**Port 6080 is the remote desktop.** It is the only way to see the button in §3,
and it is also a live trading terminal. Safest option: do not publish it at all,
remove the `ports:` block, and tunnel:

```bash
ssh -L 6080:localhost:6080 user@your-server
# then browse http://localhost:6080/vnc.html
```

If you do publish it, put it behind Dokploy's proxy with TLS and leave
`VNC_PASSWORD` set — the entrypoint refuses to start a desktop without one.

---

## 7. Verifying it, and living with it

**Watch it boot** (`docker compose logs -f`, or Dokploy's log view). A healthy
first start prints, in order (`[hex]` is the entrypoint, `[mt4]` is MetaTrader's
own journal, `[ea]` is the EA's `Print` output; `[mt4]` and `[ea]` lines keep
MT4's level and timestamp columns, tab-separated):

```
18:02:38 [hex] ----------------------------------------------------------------
18:02:38 [hex]  HEX-FVG-Breaker on MT4 | XAUUSD | HEX-FVG-Breaker | preset 100usd-demo
18:02:38 [hex] no terminal in /data/mt4 - downloading the MetaQuotes installer
18:03:52 [hex] terminal present: /data/mt4/terminal.exe (45725928 bytes)
18:03:52 [hex] synced HEX-FVG-Breaker.mq4 and 6 presets into MQL4/
18:03:55 [metaeditor] 0 errors, 0 warnings, 162 msec elapsed
18:03:55 [hex] compiled HEX-FVG-Breaker.ex4 from source (152972 bytes)
18:03:55 [hex] startup.ini: profile=default server=MetaQuotes-Demo symbol=XAUUSD expert=HEX-FVG-Breaker preset=100usd-demo
18:03:55 [hex] virtual display :99 (1440x900x24)
18:03:55 [hex] remote desktop: http://<this-host>:6080/vnc.html  (or tunnel it: ...)
18:03:56 [hex] terminal.exe started (pid 42)
18:03:58 [hex] terminal.exe is up
18:04:02 [mt4] 0   18:04:02.101   MetaTrader 4 build 1492 started (MetaQuotes Software Corp.)
18:04:09 [mt4] 0   18:04:09.284   '176428789': login on MetaQuotes-Demo through Access Point 5 (ping: 156.15 ms)
18:04:11 [ea]  0   18:04:11.612   HEX-FVG-Breaker XAUUSD,M15: v3.0 on XAUUSD 15m | digits=2 | $1.0000 per point per lot | contract=100
18:04:11 [ea]  0   18:04:11.613   HEX-FVG-Breaker XAUUSD,M15: logs -> Common\HEX-Logs
```

The two `[ea]` lines are the same first-run proof `FIRST-RUN.md` §5 asks for, now
readable from a phone. Then the phone gets the INIT push, which now also says
whether trading is allowed.


**Day to day:**

```bash
docker inspect --format '{{.State.Health.Status}}' <container>   # ok / unhealthy
ls -l /data/mt4/MQL4/Files/Common/HEX-Logs/                      # heartbeat + history
docker compose stop                                              # SIGTERM -> wineserver -k -> clean flush
```

**Input changes belong in git.** Every start re-copies `MQL4/Presets/*.set` and
recompiles the EA, so a setting changed on the server is overwritten by the next
restart, never mind the next deploy. To change a parameter: edit the preset in
this repo, commit, and let the pipeline carry it — which is also what makes
`DEMO-PLAN.md`'s "one setting per window" rule checkable in `git log`.


`docker compose stop` gets MT4 to write its journal and CSVs on the way out. This
is the thing a force-quit on the laptop destroyed: MT4 buffers, and only a clean
exit flushes. The entrypoint's SIGTERM handler waits up to 25 s for exactly that,
which is why `stop_grace_period: 30s` is in the compose file.

**Reading the demo back:** pull the CSVs off and point the existing report tool at
them, or run it inside the container's volume copy:

```bash
scp -r user@server:/opt/hex-mt4/hex-logs ./logs/server
python3 Tools/hex_report.py --dir ./logs/server
```

---

## 8. The other two ways to get off your laptop

Worth reading before you rent anything, because one of them is genuinely less
work than this one.

**MetaTrader's own VPS** — inside the terminal: Navigator → *Virtual Hosting*, or
the VPS icon in the toolbar. MetaQuotes migrates your terminal, chart and EA to
their server and keeps it running; roughly $10–15/month, bought from the MQL5
account. No Docker, no Wine, and it is the vendor's own product, so AutoTrading is
their problem, not yours. It wins when the goal is "just keep trading" and you do
not care which machine it is. It loses on cost, on not being in your CI, on being
per-account rather than per-repo, and on the logs living somewhere you do not
control.

**A Windows VPS** — MT4 native, no Wine layer, nothing in §3 to check. Around
$10–20/month, and you maintain a Windows desktop by hand: install, update, log in,
and notice when it stops. It does not fit GHCR/Dokploy at all.

**This** — one Linux VPS, roughly $5–7/month (MT4 is a 32-bit app: 2 vCPU, 2 GB
RAM and 10 GB disk is plenty). It fits the CI you already have, `docker logs`
shows the EA's prints, and a rebuild is a `git push`.

---

## 9. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `FATAL: the installer produced no terminal under .../drive_c` | MetaQuotes' installer does not run under Wine — it is a 64-bit web installer that exits silently | expected with `MT4_DISTRO_URL` empty; supply a distro (§4A). The installer's own output is printed just above the error |
| restart loop, `BadAccess (MIT-SHM)` while installing | Xvfb and Wine share memory to draw | `shm_size: 512m` (already set); `ipc: host` if it persists |
| terminal runs, no `[ea]` lines, no push | AutoTrading off, or the container lacks `cap_add: SYS_PTRACE` | check the cap first, then §3 |
| push never arrives, dashboard `err 4060` | ntfy URL missing from the WebRequest list | §3, second switch |
| INIT push: `AutoTrading BLOCKED (terminal not connected yet)` | the hello went out before the login finished | harmless once. If it persists, the server name or password is wrong — check the `[mt4]` login lines |
| `X Error ... BadAccess (MIT-SHM)` and a black desktop | `/dev/shm` too small | `shm_size: 512m` is already set; if it still happens add `ipc: host` |
| `no desktop at all` in the log | by design: `ENABLE_VNC=1` with an empty `VNC_PASSWORD` | set the password |
| healthcheck `unhealthy` while the market is shut | `equity.csv` is only written on ticks | raise `HEX_HEARTBEAT_MAX_AGE_MIN`, or ignore it over the weekend |
| it re-seeds the distro on every start | the volume is not mounted, so `/data` is empty each time | check the `volumes:` block. Seeding is idempotent once `/data/mt4/terminal.exe` exists |
| it trades the wrong timeframe | the chart comes from the profile, not from the env | prepare a distro with the XAUUSD M15 chart, or set the chart once in the desktop (the profile is then saved on the volume) |
| two robots on one account | the laptop copy is still running | stop one of them, always |

---

## 10. What this deliberately does not do

- **It does not turn AutoTrading on for you.** Nothing outside the terminal can,
  so it reports the state in two places instead of pretending (§3).
- **It does not change the strategy.** The only code change that came with this
  deployment is two reporting lines: the dashboard's `Trading :` line and the
  AutoTrading line in the INIT push. `DEMO-PLAN.md`'s rules still hold, including
  "change one setting per window".
- **It does not ship an account or a terminal.** Credentials live in the
  environment; the terminal lives on the volume. That means the volume is
  sensitive — `config/accounts.ini` is in there — and also that the image is safe
  to publish.
- **It cannot install MetaTrader from scratch.** MetaQuotes' installer does not
  work under Wine (probed: 64-bit web installer, exits silently, installs
  nothing), so the terminal has to be supplied as a distro (§4A). That is why the
  image is publishable at all: it ships no MetaQuotes binaries.
- **It is amd64 only.** The image uses a `win64` Wine prefix — MetaQuotes'
  installer is 64-bit and their terminal is 32-bit, and a win64 prefix runs both
  through WoW64, exactly as a normal Windows install does. That needs an amd64
  host with 32-bit userland (`i386` arch), so it runs on any normal VPS; on ARM it
  only runs under emulation, slowly, and is not worth it.
- **It does not auto-restart a crashed terminal.** The entrypoint exits with the
  terminal's code and lets the restart policy decide, so a crash is a line in the
  logs rather than a silence.



