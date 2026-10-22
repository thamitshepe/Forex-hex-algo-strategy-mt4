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

**One push, then one click.** The push to `main` builds `deploy/Dockerfile` and
publishes `ghcr.io/<owner>/forex-hex-mt4:live` plus the commit SHA, and fails if the
MQL4 does not compile. Then, in Dokploy:

1. **Create Project** `forex-hex-mt4` → **Create Service** → **Compose**.
2. Paste `deploy/docker-compose.yml` into the compose editor.
3. Paste the environment block from §6 into the **Environment** tab, with your demo
   account and the `MT4_DISTRO_URL` from §4.
4. **Deploy**, then watch the log until `terminal.exe is up` (§7).

Everything site-specific lives in Dokploy's environment: that is the one place to
change a password, a symbol or a preset, and no credential is stored in git. The
container pulls the terminal tarball itself on its first start, so there is no file
to copy onto the server and no shell needed.

If you would rather not click at all, §6 also has the CI route — set `DOKPLOY_URL`
and `DOKPLOY_API_TOKEN` as repository variables/secrets and the workflow creates and
deploys the same app. The two routes are alternatives, not stages: the workflow only
touches Dokploy when those two are set.

After the first start the terminal is on its own: a new commit builds a new image,
the redeploy pulls it, the entrypoint recompiles the EA from that commit, and the
chart comes back exactly as it was because the profile is on the volume.

---

## 3. The one look you have to take

Two switches in MetaTrader decide whether the EA may trade, and neither of them
can be set reliably from outside the running terminal. This is not a container
problem — it is the same on any MT4 VPS — and it is the same thing that made this
EA look broken on the laptop.

**If the volume was seeded from a distro (§4) prepared on a machine that already ran
the robot, neither switch needs a click.** `config/experts.ini` comes across with the
WebRequest list in it, and `startup.ini` asks for AutoTrading on every start. Confirm
it from the phone rather than the desktop: an INIT push arriving at all means the
allow-list is in place, and it ends with `AutoTrading ON`. Only a `BLOCKED` line, or
`err 4060` in the dashboard, sends you to the desktop — the rest of this section is
what to do when it does.

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

Then put it somewhere the container can fetch. That is the whole handover: the
entrypoint reads `MT4_DISTRO_URL` and `curl` understands `https://` exactly as
well as `file://`, so if the tarball has a URL there is no step on the server at
all.

```bash
gh release create mt4-distro dist/mt4-portable.tar.gz    # or any https:// host
# then set it as MT4_DISTRO_URL in Dokploy's environment (§6) — or as a repository
# variable (§5) if you are using the CI route:
# MT4_DISTRO_URL=https://github.com/<you>/<repo>/releases/download/mt4-distro/mt4-portable.tar.gz
```

Set that variable once and every deploy after it seeds the volume on first start —
nothing to copy, no shell on the server. A public host makes the tarball public,
and it is MetaQuotes' code; if that matters, keep the bucket private and give the
container a URL that carries its own signature. (A private GitHub release asset
needs a token in the URL, which is more awkward than an object-storage link.)

Two alternatives, for when the tarball has no URL to give it. With a **bind
mount** — change `- hex-mt4-data:/data` to `- /opt/hex-mt4:/data` — it is one
`scp` and `MT4_DISTRO_URL=file:///data/mt4-portable.tar.gz`. With the named volume
the compose file already declares, it is `docker cp mt4-portable.tar.gz
<container>:/data/`. Both work, both are once per install, and neither is needed
on the URL route.

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

### What you have to give it

Everything below is a *value*. Nothing below is an instruction to click something
in Dokploy: `deploy/scripts/dokploy-apply.sh` creates the project, the app, the
environment and the deployment (§6). These are the values it carries.

| kind | name | what it is |
|---|---|---|
| variable | `MT4_DISTRO_URL` | the prepared terminal tarball from §4A as an `https://` URL. At runtime it is how the terminal arrives — no `scp`, no `docker cp`. Passed to the build it also makes `ea-check` download it, compile the EA with the real `metaeditor.exe` and bake the `.ex4` into the image, which is the version of "the build fails if the EA does not compile" that covers *every* commit |
| variable | `DOKPLOY_URL` | the instance, e.g. `https://dokploy.example.com`, no trailing slash |
| secret | `DOKPLOY_API_TOKEN` | a Dokploy API token (Settings → API Keys). **Required for the deploy half** — with `DOKPLOY_URL` it is the only Dokploy input there is |
| secret | `MT4_LOGIN` | the demo account login |
| secret | `MT4_PASSWORD` | its password |
| secret | `VNC_PASSWORD` | the remote desktop's password. Unset ⇒ no desktop at all (§3) |
| variable | `MT4_SERVER` | default `MetaQuotes-Demo` |
| variable | `MT4_SYMBOL` / `MT4_PRESET` | default `XAUUSD` / `100usd-demo` |
| variable | `MT4_PROFILE` | default `default` |
| variable | `ENABLE_VNC` | default `1` |
| variable | `TZ` | leave unset (UTC): the preset's trading hours are UTC |
| variable | `DOKPLOY_PROJECT` / `DOKPLOY_APP` | optional. Rename the project or the Compose app away from `forex-hex-mt4` / `hex-mt4`. `DOKPLOY_APP` is the Compose *project* name, so changing it later is a fresh volume, not a rename |

Leave `DOKPLOY_URL` and `DOKPLOY_API_TOKEN` unset and the workflow still does the
useful half: it publishes `live` and the SHA, and the deploy job prints a notice
instead of failing. That is deliberate — a fork should build without a token.

The values only work in one direction. What is in these secrets is what
`compose.saveEnvironment` writes, on every deploy, replacing what is there. A
variable edited in Dokploy's UI and nowhere else is overwritten by the next push.

---

## 6. Dokploy

**By hand, in the UI — the Docker-Image route.** Everything the container needs is
one of eleven environment variables, and setting them here keeps every credential
out of git. Create **Project** `forex-hex-mt4` → **Create Service** → **Application**,
then:

- **Provider → Docker**: image `ghcr.io/thamitshepe/forex-hex-mt4:live`. The package
  is public, so leave the registry credentials empty.
- **Environment**: paste this, with your own demo account and a VNC password.

```dotenv
MT4_LOGIN=12345678
MT4_PASSWORD=...
MT4_SERVER=MetaQuotes-Demo
MT4_SYMBOL=XAUUSD
MT4_PRESET=100usd-demo
MT4_PROFILE=default
MT4_DISTRO_URL=https://github.com/<you>/<repo>/releases/download/mt4-distro/mt4-portable.tar.gz
ENABLE_VNC=1
VNC_PASSWORD=...
TZ=UTC
# MT4_IMAGE=ghcr.io/<owner>/forex-hex-mt4:<sha>    # pin an older build to roll back
```

- **Advanced → Mounts**: add a **Volume** mount, name `hex-mt4-data`, mount path
  `/data`. Without it every redeploy re-downloads 36 MB and loses the profile — and
  with it the seeded chart.
- **Advanced → Restart Policy**: `Any`.
- **Domains**: host `trade.thami.dev`, path `/`, **port `6080`**, HTTPS on,
  certificate **Let's Encrypt**. Point the DNS A record at the server *before* the
  deploy, or the certificate cannot be issued. Traefik terminates TLS and forwards to
  port 6080 inside the container, so no host port is published and nothing collides.
- **Security** (recommended): basic auth on that domain. It is a trading terminal on a
  public hostname, and the VNC password would otherwise be the only lock.

Then **Deploy**. The first start downloads the tarball (36 MB, once — it lands in the
volume), compiles the EA with the container's own `metaeditor.exe`, logs the account
in from `MT4_LOGIN`/`MT4_PASSWORD`, and prints `terminal.exe is up`. §7 is what to
look at. `uname -m` on the VPS must say `x86_64`: the image is built for
`linux/amd64` only.

**What this route cannot set, and why the compose file still exists.** Dokploy's
Application type has no `cap_add` and no `shm_size`: `CapAdd` appears nowhere in
Dokploy's source, and the compose route works only because it hands raw YAML to
`docker compose`, which is what understands those keys. Neither is usually fatal —
Wine wants `SYS_PTRACE` only to attach a debugger, and 64 MB of `/dev/shm` carries a
1440x900 screen most of the time — but both fail as things that look like a broken
EA, so the entrypoint reports them at boot:

    shm          : 64 MB (enough for Xvfb + Wine)     |  or the WARN that says otherwise
    CAP_SYS_PTRACE: present                           |  or the WARN that says absent

If the desktop is blank, the log says `BadAccess (MIT-SHM)`, or the expert never
attaches, switch this one service to the Compose app in `deploy/docker-compose.yml`:
that is the only reason the file is still here.

**Or let CI do it.** On the first push to `main` with `DOKPLOY_URL` and
`DOKPLOY_API_TOKEN` set, `deploy/scripts/dokploy-apply.sh` makes the same project and
app and deploys it; on every push after that it finds what it made, updates it and
deploys again. It only acts when those two are set, so an app you made by hand is
never touched by a workflow run.

**What the first run does**, in order:

1. `GET /api/project.all` — is there a project called `forex-hex-mt4`?
2. `POST /api/project.create` if not. Dokploy puts a `production` environment in
   it, which is where the service goes.
3. `GET /api/project.one` — that project's environments, and the services already
   in them.
4. `POST /api/compose.create` — the app, named `hex-mt4`, in that environment.
5. `POST /api/compose.update` — `sourceType: raw` plus `composeFile` = the bytes of
   `deploy/docker-compose.yml` from the commit being deployed, so what runs on the
   server is the file in the repo and not a copy pasted once that then drifts.
   `autoDeploy` stays off: the script is the deploy trigger.
6. `POST /api/compose.saveEnvironment` — the values from §5, as the `.env` the
   compose file interpolates.
7. `POST /api/compose.deploy` — pull `ghcr.io/…:live` and recreate.

Nothing is built on the server; the app pulls the image.

**Why a Compose app and not an Application.** Dokploy's Application type takes a
Docker image directly, which looks like the natural fit for a GHCR image, and it
cannot express either of the two settings this container cannot do without:
`cap_add: [SYS_PTRACE]` — Wine needs ptrace to attach to the processes it spawns,
and without it the EA never loads, which looks exactly like a broken EA — and
`shm_size: 512m` — Xvfb and Wine share memory to draw, and too little shows up as
`BadAccess (MIT-SHM)` and a dead desktop. Neither field exists on Dokploy's
application schema or in its UI. Compose hands the YAML to `docker compose`
untouched, so a Compose app is the only service type that can carry them.

**Not a Stack, either.** Stack is Docker Swarm, which handles `cap_add` and
`shm_size` differently and drops `build`.

**The environment.** Dokploy writes what step 6 sends to a `.env` beside the
compose file, and Compose reads that file for `${VAR}` substitution by itself —
which is why `deploy/docker-compose.yml` spells `${MT4_LOGIN}` inside
`environment:` instead of using an `env_file:`. The `:?` guards still work, so an
app started without `MT4_LOGIN` fails loudly instead of coming up with an empty
login.

Volume: `hex-mt4-data`, at `/data` in the container and really
`hex-mt4_hex-mt4-data` on the host, because Compose prefixes named volumes with the
project name. Everything that matters — the terminal, the profile with the chart,
the compiled EA, the HEX-Logs CSVs — is under it, so a redeploy is not a restart of
the demo. This is also the one place `DOKPLOY_APP` matters: it *is* that prefix, so
renaming the app later points the container at an empty volume.

**Registry pull: not needed.** The package is public (§5), so Dokploy pulls
`ghcr.io/thamitshepe/forex-hex-mt4:live` with no credential at all. Only if you make
the package private do you add one here (registry `ghcr.io`, username = the GitHub
account, password = a PAT with `read:packages`) — and that one is a click, because
Dokploy exposes no API field for registry credentials.

**Re-pulling the moving tag.** `deploy/docker-compose.yml` carries
`pull_policy: always` on the service. Without it a redeploy of `:live` can reuse the
image already on the host — Docker matches the tag, not the new digest — and "the
server picked up the new EA" quietly becomes "the server is still trading last
week's build". Dokploy's own version of this is the **"Pull latest images on
deploy"** switch in the app's Advanced tab, which appends `--pull always` to the
same `up -d`. It is not usable from CI: `compose.pullImages` exists on the table
with a default of `false` and is absent from `compose.update`, so setting it would
be the one click left in an otherwise clickless deploy. The YAML says the same
thing, Dokploy passes no contradicting `--pull` flag, and `docker compose config`
shows the setting surviving into the resolved file.

**Port 6080 is the remote desktop.** It is the only way to see the button in §3, and
it is also a live trading terminal. Safest: do not publish it — delete the `ports:`
block — and tunnel:

```bash
ssh -L 6080:localhost:6080 user@server
# then browse http://localhost:6080/vnc.html
```

If you do publish it, put it behind Dokploy's proxy with TLS and leave
`VNC_PASSWORD` set: the entrypoint refuses to start a desktop without one.

**If you would rather click.** Every step above is also something in the UI: Create
Service → Compose, provider raw/paste, paste `deploy/docker-compose.yml`, paste the
§5 values into Environment, Deploy. It is the same app. The difference is that the
script is reproducible and the clicks are not — and that the next CI redeploy
overwrites the environment and the compose file with what is in the repo, so a
UI-made app and a script-made app cannot stay different for long.

**The variables, one line each.**

| variable | what it is |
|---|---|
| `MT4_LOGIN` / `MT4_PASSWORD` / `MT4_SERVER` | the demo account the terminal logs into |
| `MT4_SYMBOL` / `MT4_PRESET` | what to trade: `XAUUSD` + `100usd-demo.set` |
| `MT4_PROFILE` | which profile in the volume to open (default `default`) |
| `ENABLE_VNC` / `VNC_PASSWORD` | the remote desktop. Empty password ⇒ no desktop, deliberately |
| `TZ` | leave `UTC`: the preset's trading hours are UTC |
| `MT4_DISTRO_URL` | the prepared terminal (§4A), as `https://…`, or `file:///data/mt4-portable.tar.gz` on the copy-by-hand route |
| `MT4_IMAGE` | the full image reference. CI sets it to the tag that run pushed, so no owner is hardcoded in the compose file and a rollback can pin a SHA |
| `HEX_HEARTBEAT_MAX_AGE_MIN` | how stale `equity.csv` may be before the healthcheck says so. CI does not set it; the compose file's `180` applies |

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



