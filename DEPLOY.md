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
2. Paste `deploy/docker-compose.yml` into the compose editor (provider: raw).
   It defines one service — `mt4-doge` (DOGEUSD) — from
   `ghcr.io/thamitshepe/forex-hex-mt4:live`, attached to `dokploy-network`
   because that is the only network Traefik can reach it on.
3. Paste **all of** `dist/dokploy.env` into the **Environment** tab: one place,
   nothing per service. Fill `MT4_LOGIN2`/`MT4_PASSWORD2` and the
   `MT4_DISTRO_URL` from §4.
4. **Deploy**, then watch the log until `terminal.exe is up` (§7) — the log has a
   service selector, so `mt4-doge` is read directly.
5. **Domains** tab: `trade2.thami.dev` → service `mt4-doge` → port `6080`
   → HTTPS.
6. **Deploy again.** A domain becomes a Traefik label on the *container*, and labels
   are written when the container is created — so a domain added to a running app
   routes nowhere (`app not found`) until the next deploy. Add the domain first,
   then deploy once; from then on the domain survives every later deploy.


Everything site-specific lives in that one Environment tab: that is the one place to
change a password, a symbol or a preset, and no credential is stored in git. The
container pulls the terminal tarball itself on its first start, so there is no file to
copy onto the server and no shell needed.

If you would rather not click at all, §6 also has the CI route — set `DOKPLOY_URL`
and `DOKPLOY_API_TOKEN` as repository variables/secrets and the workflow creates and
deploys the same app. The two routes are alternatives, not stages: the workflow only
touches Dokploy when those two are set.

After the first start the terminal is on its own: a new commit builds a new image,
the redeploy pulls it, the entrypoint recompiles the EA from that commit, and the
chart comes back exactly as it was because the profile is on the volume.

**What a redeploy keeps, and what it resets.** Everything that matters lives on the
named volume `hex-mt4-doge-data` (compose: `hex-mt4-doge-data:/data`), and a
redeploy — `up -d` against a new image — replaces the *container*, never the
volume. Kept across every deploy: the account login, the balance and open
positions (they live at the broker anyway), the chart profile, the CSV logs
(`trades.csv`, `equity.csv`, …), and the WebRequest allow-list. Reset on every
deploy, on purpose: the EA is recompiled from the commit being deployed, the
presets are re-copied from the image (`sync_ea`), and `startup.ini` is rewritten —
which is why hand-edits inside the container do not survive. The preset the EA
*runs* comes from the env (`MT4_PRESET2`) each boot, so that too survives — as
long as it is set in the Environment tab or the repo, never inside the container.

One thing that looks like data loss but is not: right after a (re)start the
terminal can push `Account 0 | balance 0.00` before it has finished dialling the
broker — a minute later the next banner shows the real account and balance.
Positions and history were never gone; the terminal just woke up before the
connection did.

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

**0. The login, on a volume that has never logged in.** MT4's `startup.ini`
`Login=`/`Password=`/`Server=` are a *re-login*: the terminal re-uses the account
record in `config/accounts.ini`, it cannot create one. A volume seeded from a
distro carries that record, so instance 1 starts logged in. A volume with no
record — every `mt4-doge` volume on its first start, because the seeded record is
the *gold* account and is deliberately deleted (§6) — has nothing to re-login as,
and a terminal in that state looks broken rather than empty: the chart from the
profile is there, the title says `DOGEUSD,M5`, and underneath it says `Waiting for
update`, `No connection` in the bottom-right corner, an empty Market Watch, and no
dialog. The entrypoint now detects it and leaves the three lines out instead, which
is the state a freshly installed MT4 is in and the one that brings up its login
window. Log in once in noVNC (`File → Login`), the account is written to the volume,
and every later start re-logs in from `startup.ini` — visible in the log as
`login : <login> @ <server> - re-used from config/accounts.ini`.

If the login window does not list your broker's server, this copy of the terminal
has never heard of it, and MT4 cannot dial a server it has no address for: copy
`config/servers.ini` from a terminal that is logged into that account into
`/data/mt4/config/`, or add the broker once through `File → Open an Account` and
then log in. Both are one-time, and both are on the volume afterwards.

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
work, everything downstream (compile, `startup.ini`, volume) is identical — and
`deploy/scripts/prepare-broker-distro.sh` (§4C) is that same run plus the archive it
produces, so you only pay for the install once.

**C. A second broker needs its own terminal.** A terminal copy only knows the
servers of the broker it was installed from: `config/servers.ini` is an encrypted
cache of server addresses, and MT4 cannot dial a server name it has no address for.
The generic MetaQuotes build therefore knows `MetaQuotes-Demo` and nothing else, and
an account from another broker sits at `'<login>': connect failed [No connection]`
in the journal no matter how right the password is. Three ways to give this instance
its broker's servers, cheapest first:

1. **In the desktop** (`File → Open an Account`): the wizard downloads the broker's
   server list into `config/servers.ini`. Search the broker, let it load, close the
   wizard, then `File → Login` with the existing account. One time, on the volume.
   **Whether it worked is not a matter of opinion**: MT4 keeps the whole list in
   `config/servers.ini` and rewrites that file when it learns a broker, so watch it —
   ```bash
   docker exec $(docker ps -qf name=mt4-doge) ls -l /data/mt4/config/servers.ini
   ```
   A timestamp from just now and a different size means the list arrived, the Server
   dropdown in the login window will show the broker, and the login will dial. An
   unchanged timestamp means the wizard found nothing (wrong broker name, or the
   broker is not in MetaQuotes' directory) — go to 2 or 3.
2. **Copy the server data** from a terminal that already logs into that account.
   Two files hold it, and either is worth trying:
   - `config/servers.ini` (the list MT4 dials from) —
     `docker cp servers.ini <container>:/data/mt4/config/`;
   - the per-server files `config/*.srv` — `terminal.exe` contains the paths
     `%\config\*.srv` and `%\config\%s.srv`, so MT4 looks for them there and writes one
     per server it learns. On Windows they sit in
     `%APPDATA%\MetaQuotes\Terminal\<32 hex chars>\config\`, on the Mac inside the
     terminal's portable folder, and a broker's installer carries them too —
     `7z x <broker>setup.exe` unpacks the `.srv` without running anything.
   Then restart, and open the Server dropdown to see whether the name appeared.
   Nothing in either file is account-specific — they are a server list.
3. **Prepare a distro from that broker's own installer**, then give *this* service its
   own copy of it. One command, on the Mac, nothing installed first:
   ```bash
   deploy/scripts/prepare-broker-distro.sh tmgm ~/Downloads/tmgm4setup.exe
   # writes dist/mt4-portable-tmgm.tar.gz, prints size, members and sha256
   # a portal link works in place of the file, and --server names the login's server:
   deploy/scripts/prepare-broker-distro.sh tmgm https://…/tmgm4setup.exe --login \
     --server TradeMaxGlobal-Demo-2
   ```
   It runs the broker's `setup.exe` inside the deployment image itself (Wine, Xvfb,
   openbox and noVNC are already in there, §5) against a throwaway volume, waits for
   `terminal.exe` to appear, and archives the result with `tar` inside a Linux
   container — so the archive cannot pick up the macOS AppleDouble junk that
   `prepare-distro.sh` has to check for. It prints the servers the installer brought
   (one `config/<server>.srv` each), and `--server` makes it warn when the one your
   account logs in on is not among them: the *wrong* broker's installer installs
   perfectly and only fails at login, a deploy later. Add `--login` and it holds the
   container open with the desktop published, so you can `File → Login` once and have
   the saved account travel inside the archive as well as the server list.
   Then, on the `mt4-doge` service:
   ```
   MT4_DISTRO_URL2=https://…/mt4-portable-tmgm.tar.gz
   MT4_FORCE_SEED2=1            # one deploy: replaces this volume's tree
   MT4_KEEP_SEED_LOGIN2=1       # only if you logged in before archiving
   ```
   `MT4_KEEP_SEED_LOGIN2` is what stops the seeding step from doing its normal job:
   `neutralise_seed` deletes `config/accounts.ini` so instance 2 cannot come up as
   instance 1's account, and it cannot read whose account is in there (the file is
   encrypted), so keeping a login has to be an assertion you make about the archive.
   Drop `MT4_FORCE_SEED2` after that deploy; keep the other two.
   If the broker's installer turns out to be a 64-bit web stub too, do the same thing
   by hand: run that broker's terminal anywhere (a Windows machine, a Mac with its
   installer), log in once, close it, and archive the folder the way
   `prepare-distro.sh` does (`--exclude=history --exclude=logs …`, no macOS
   metadata), then continue from `MT4_DISTRO_URL2` above.

   This is the only route that brings the broker's server list *and* its charts *and*
   a saved login in one move, and the only one that works when the broker is not in
   MetaQuotes' directory and no terminal with that account has ever run on a machine
   you control.

The journal tells the three cases apart: `connect failed [No connection]` = no
address / unreachable, `invalid account` = wrong login or expired demo, and
`invalid server` = the name is not in the list at all.

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

**The compose route is §2** — one application, one service (the `mt4-doge`
DOGEUSD instance; the gold `mt4` service was retired 2026-10-30 and its
service block removed from the compose file). What follows describes the same image
run as a **Docker-Image application** instead, which is one container per app; it
is the route to take if you would rather keep a standalone app than a compose
app, or when growing a second account (§“A second instance”).

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

**This route is one instance per application.** A Docker-Image application runs one
container from one image, so it can hold `trade.thami.dev` *or* `trade2.thami.dev`,
not both. Two accounts on two hostnames is a second application from the same image
with its own volume, its own domain and the `MT4_INSTANCE=2` half of the env file —
§“A second instance” below, whose steps are the ones above repeated with the `2`
values. **Give the second application a different volume name.**
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
`environment:` instead of using an `env_file:`. A blank `MT4_LOGIN` is passed
through as blank and the container says so at boot (an empty login means MT4 waits
at its dialog, which is visible on the desktop); the identity of the account is
checked inside the container, because that check is the one that knows this app may
be instance 2 reading `MT4_LOGIN2`.

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
| `MT4_INSTANCE` | which instance a container is: `1` (the default) or `2` in the second application's Environment tab. `1` reads the plain names in this table; `2` reads their `2` copies — `MT4_LOGIN2`, `MT4_SYMBOL2`, `MT4_PRESET2`, … Nothing falls back across instances: a missing `MT4_LOGIN2` stops the container instead of logging into instance 1's account, and a volume claimed by another instance is refused. The compose route sets it per service instead |
| `MT4_LOGIN` / `MT4_PASSWORD` / `MT4_SERVER` | the demo account the terminal logs into |
| `MT4_SYMBOL` / `MT4_PRESET` | what to trade: `XAUUSD` + `100usd-demo.set` |
| `MT4_PERIOD` | optional: move the volume's chart onto this timeframe (`5`, `15`, `60`). Empty = leave the chart alone. An instance whose symbol the profile does not carry gets the chart *moved* onto it — never a second chart, because a second chart loads a second expert |
| `MT4_PROFILE` | which profile in the volume to open (default `default`) |
| `ENABLE_VNC` / `VNC_PASSWORD` | the remote desktop. Empty password ⇒ no desktop, deliberately |
| `TZ` | leave `UTC`: the preset's trading hours are UTC |
| `MT4_DISTRO_URL` | the prepared terminal (§4A), as `https://…`, or `file:///data/mt4-portable.tar.gz` on the copy-by-hand route |
| `MT4_FORCE_SEED` | `1` replaces the tree in `/data/mt4` with a fresh distro *even though* a `terminal.exe` is already there — the profile, the saved login and the EA's CSV trade log under `MQL4/Files/Common/HEX-Logs` are replaced with it. One-shot per archive: after a forced seed the entrypoint records the archive's sha256 in `/data/.seeded-from` and refuses to replace the tree again from that same archive, so leaving the flag on cannot keep erasing trade history. A *different* archive still goes in; delete `/data/.seeded-from` to force the same one again |
| `MT4_DISTRO_URL2` | the same for instance 2, when the second account is at a **different broker** and needs a terminal prepared from that broker's own install (§4C). Only instance 2 reads it, and the compose file passes it to that service alone |
| `MT4_KEEP_SEED_LOGIN` | `1` keeps the seeded tree's `config/accounts.ini`, `server.ini` and `community.ini`, which instance 2's seeding otherwise deletes so it cannot come up as instance 1's account. Set it only when the distro was prepared from *this* broker's terminal with *this* account — it is your assertion, because those files are encrypted and the entrypoint cannot check whose login it is |
| `MT4_SETUP_URL` | the installer to run when a volume has no terminal and no distro is given. Defaults to MetaQuotes' `mt4setup.exe`, which does not work under Wine; a broker's own `setup.exe` might, and `deploy/scripts/prepare-broker-distro.sh` is the way to find out (§4C). `MT4_SETUP_URL2` for instance 2 |
| `MT4_IMAGE` | the full image reference. CI sets it to the tag that run pushed, so no owner is hardcoded in the compose file and a rollback can pin a SHA |
| `HEX_HEARTBEAT_MAX_AGE_MIN` | how stale `equity.csv` may be before the healthcheck says so. CI does not set it; the compose file's `180` applies |

### A second instance (different account, different strategy)

Scaling here means **one service per instance inside one compose application**,
never one container running two terminals and never two hand-configured
applications. The compose file currently defines one service (`mt4-doge`); the
gold (`mt4`) service block it used to carry is in git history and is the template
for adding an instance back:

```yaml
services:
  mt4-doge:   # instance 2  MT4_LOGIN2  DOGEUSD M5  trade2.thami.dev
  # mt4:     # instance 1  MT4_LOGIN   XAUUSD M15  trade.thami.dev  (retired 2026-10-30)
```

One deploy brings up both. **One Environment tab** (`dist/dokploy.env`, pasted
whole) feeds both. One image, one volume per service, one hostname per service.
There is no second application to create, nothing to copy, and no second place for
the two to drift apart.

**What makes them different traders** is three things, and only one of them is in
the env file:

| | `mt4` (instance 1) | `mt4-doge` (instance 2) |
|---|---|---|
| `MT4_INSTANCE` | `1` — hard-coded in the service block | `2` — hard-coded in the service block |
| credentials it *receives* | `MT4_LOGIN`, `MT4_PASSWORD`, `MT4_SERVER` | `MT4_LOGIN2`, `MT4_PASSWORD2`, `MT4_SERVER2` — and **not** the plain names |
| env it reads | `MT4_LOGIN`, `MT4_SYMBOL`, `MT4_PRESET`, … | `MT4_LOGIN2`, `MT4_SYMBOL2`, `MT4_PRESET2`, … |
| account | MetaQuotes demo | **its own** TMGM account |
| volume | `hex-mt4-data` → `/data` | `hex-mt4-doge-data` → `/data` |
| domain | `trade.thami.dev` → service `mt4`, port 6080 | `trade2.thami.dev` → service `mt4-doge`, port 6080 |
| push | `HEX XAUUSD` → ntfy `hex-xauusd-…` | `HEX DOGEUSD` → ntfy `hex-doge-…` |

The instance number is a property of the **service block**, not of the env, so a
pasted env file cannot turn both into instance 1 — which is the mistake that shows up
as "both hostnames have the same account". The DOGE container is not even given the
gold credentials: it does not have `MT4_LOGIN` in its environment, so it cannot log
into that account however it is configured.

**One env file, both services.** `dist/dokploy.env` is the whole of it, pasted into
the application's single Environment tab: the gold values under the plain names, the
DOGE values under the `2` copies. Both services read the same block; each takes what
its own instance number tells it to.

```sh
MT4_LOGIN=…   MT4_PASSWORD=…   MT4_SERVER=MetaQuotes-Demo   MT4_SYMBOL=XAUUSD   MT4_PRESET=100usd-demo
MT4_LOGIN2=…  MT4_PASSWORD2=…  MT4_SERVER2=TMGM-Demo        MT4_SYMBOL2=DOGEUSD MT4_PRESET2=doge-scalp-shadow  MT4_PERIOD2=5
```

Shared values — `VNC_PASSWORD`, `ENABLE_VNC`, `TZ`, `MT4_DISTRO_URL` — are the plain
names, and both services read them; a `VNC_PASSWORD2` wins if you ever want them to
differ. The desktop password being identical is fine: separate containers, separate
hostnames, separate certificates. `HOST_VNC_PORT` only moves the one host port the
`mt4` service publishes (a fallback for when the domain is not up yet); set it only
if something else on the server already listens on 6080.

**Nothing is borrowed across instances**, because that is the failure worth
designing against. With `MT4_INSTANCE=2`:

- an empty `MT4_LOGIN2`/`MT4_PASSWORD2`/`MT4_SYMBOL2`/`MT4_PRESET2` stops the
  container with `FATAL: MT4_INSTANCE=2 has no MT4_LOGIN2 …` — it does **not** fall
  back to `MT4_LOGIN`, which is what a duplicated application would otherwise do:
  trade the DOGE preset on the gold account with every input looking valid.
  `MT4_SERVER2` is the one exception: it may be empty, because a terminal only knows
  the servers it has met and the exact name is read off the login dialog. Empty
  means "claim no server, ask me once", never "use the gold server";
- a volume whose `/data/.hex-instance` names a different account is refused
  (`this volume belongs to account …, and this container is …`). Two terminals
  writing one MT4 tree corrupt each other, and a second application that forgot
  its own volume inherits `config/accounts.ini` — so it would log in as the first
  account no matter what its env says;
- logging into the *same* account as instance 1 still works (two strategies, one
  account, different symbols and magic numbers) but logs a warning, because it is
  also what a half-copied application looks like.

**The terminal it starts from is not neutral either.** The distro is a *copy of a
working terminal*, so it arrives carrying everything that made that copy work: the
saved login (`config/accounts.ini`), the last server it talked to, the MQL5
community session, the chart's expert inputs, and the EA's CSV log. For instance
1 that is its own account. For instance 2 it is somebody else's — the terminal
comes up as the gold account, and the dashboard starts from a trade log it never
wrote. So on its first boot instance 2 moves that state aside, before MT4 starts:

```
seed: 3 file(s) of the previous account's state moved out of the way - the saved
      login, the last server and the MQL5 session are gone; its CSV log and journals
      are in /data/mt4/.before-instance2
seed: config/experts.ini stays: that is where the WebRequest allow-list (the ntfy
      URL) lives, and nothing in deploy/ can write it back
seed: this terminal has no account yet - the login comes from startup.ini. If the
      desktop shows a login dialog on the first start, log in once: the broker's
      server is unknown to this copy of the terminal, and MT4 saves it on this
      volume from then on
```

Those three files are binary and encrypted, so they are removed rather than edited —
the next login re-creates them. `config/experts.ini` is deliberately *kept*: it is
the one file the new instance cannot be given any other way, because the WebRequest
allow-list (the ntfy URL, UTF-16 inside a binary) lives in it and nothing in
`deploy/` can write that back — delete it and every push on instance 2 fails with
`err 4060`. What it does *not* carry is the other instrument's expert inputs: those
are in the profile chart's `<expert>` block, which `ensure_profile_chart` drops
anyway. The previous account's CSV log and journals are *moved*
into `/data/mt4/.before-instance<N>/`, not deleted, because "did that first boot
trade anything?" is answered from exactly those files. It happens once per volume
(`/data/.hex-neutralised`, dropped again by a re-seed), because after that the saved
login is *this* instance's and is what makes it start without a prompt.

**The one manual step.** A trading terminal only knows the servers it has seen, and
this copy has seen MetaQuotes demo and whatever your Mac logged into. If TMGM is not
one of them, the first start cannot resolve `MT4_SERVER2` and shows the login dialog
with an empty account list. Log in once on that instance's desktop (File → Login,
or File → Open an Account and search the broker) — MT4 then writes the server and
the account into *its own* volume, and every later boot logs in from `startup.ini`
without a prompt. That is also where you read the exact server name for
`MT4_SERVER2`.

Steps, in order:

1. **DNS first.** Add an `A` record for the new hostname (the one you used for
   `trade.thami.dev`) pointing at the same server. Let's Encrypt will not issue a
   certificate for a name that does not resolve yet.
2. **Environment**: in the compose application's Environment tab, fill the `…2` values
   in `dist/dokploy.env` and paste the **whole file**. That is the only place either
   instance is configured — there is no `MT4_INSTANCE` to change, because the compose
   file sets it per service.
3. **Deploy**: both services start. `mt4` comes back exactly as it was, on its own
   volume; `mt4-doge` seeds a fresh terminal (~36 MB on its own volume) and logs
   `chart: chart04.chr moved XAUUSD 15 -> DOGEUSD 5`.
4. **Log `mt4-doge` in once.** Its volume deliberately has no `config/accounts.ini`
   (the seeded one is the gold account), and MT4 cannot create an account from
   `startup.ini` — so on this first start it opens its **login window** instead of
   logging in. Open `https://trade2.thami.dev/vnc.html`, `File → Login`, log in with
   `MT4_LOGIN2`/`MT4_PASSWORD2` on `MT4_SERVER2`. One time: the account lands on the
   volume, and every later start re-logs in from `startup.ini` (the log then says
   `login : 990158154 @ TradeMaxGlobal-Demo-2 - re-used from config/accounts.ini`).
   The chart and the expert are already attached, so nothing else needs a click
   except AutoTrading (§3). If the login window does not offer that server, see §3 —
   this terminal has never heard of the broker.
5. **Domain**: in the same application's **Domains** tab add `trade2.thami.dev` →
   service **`mt4-doge`** → port **6080** → HTTPS + Let's Encrypt. One domain per
   service, added once; it survives every deploy after that. Check that
   `trade.thami.dev` points at service `mt4` while you are there.
6. **Deploy once more** after adding a domain: Dokploy writes the Traefik label when
   it creates the container, so a domain added to an already running app answers
   `app not found` until the next deploy.
7. **Delete the old second application** if you created one: it still claims
   `trade2.thami.dev` otherwise, and two things answering one hostname is how you end
   up looking at the wrong container.



**Coming from two applications.** The service `mt4-doge` replaces the second
application, whose volume is disposable (it was a copy of the gold account's terminal;
nothing of yours is in it). The *gold* instance is the part to be careful with: a
Docker-Image application's volume is called `hex-mt4-data` on the host, while this
compose application's is `<project>_hex-mt4-data` — different volumes even though the
YAML says the same name. Either accept one re-seed (36 MB, and the gold login comes
from `MT4_LOGIN`, which the distro already knows — no dialog), or carry the files
across with both applications stopped and both names from `docker volume ls`:

```sh
docker run --rm -v hex-mt4-data:/from -v hex-mt4_hex-mt4-data:/to alpine \
  sh -c 'cp -a /from/. /to/ && chown -R 1000:1000 /to'
```

**The two-application alternative.** If you would rather keep two Docker-Image
applications instead of one compose app, the same image runs as two apps — one
container each, `MT4_INSTANCE=2` and only the `2` names in the second app's
Environment tab, different volume names per app (`hex-mt4-data`, `hex-mt4-doge`), one
domain each. Costs: two deploys instead of one, and two env tabs that can drift. What
it does not cost is safety — the credentials and the volume guards are the same.

**§6.1 The compose alternative.** `deploy/docker-compose.yml` defines the same two
instances as services of one application (`mt4`, `mt4-doge`), so one deploy and one
Environment tab cover both — at the price of the Compose application type, and of a
redeploy of one restarting the other. It pulls the same `ghcr.io/…/forex-hex-mt4:live`
image; nothing is built. Use one route or the other for a given hostname, never both.

**Which instance am I looking at?** The first three lines of each application's log
answer it, so that "both hostnames show the same account" is checkable instead of
guessed:

```
[hex] HEX-FVG-Breaker on MT4 | instance 2 | DOGEUSD 5m | HEX-FVG-Breaker | preset doge-scalp-shadow
[hex] image build  : cb0ddcee2fef9772cebeed714610bbbd714f0025
[hex] account      : 12345678 @ TMGM-Demo
```

`image build` is the commit the image was built from: if it is not the commit you
think you deployed, the application is still on a stale tag (`:live` needs a pull, a
pinned `:sha` never moves) and nothing below that line will have changed either. And
a service pointed at a volume that was already claimed by the other instance stops
with `FATAL: this volume was claimed by instance 2 …` before Wine starts.

**CI and the second application.** CI publishes the image on every push; it does not
create or reconfigure a Docker-Image application (`deploy/scripts/dokploy-apply.sh`
writes a compose application, so it belongs to the §6.1 route). On the two-application
route, a new build reaches each app the next time that app is deployed — with `:live`
and "Pull latest images" (the YAML's `pull_policy: always` in the compose route), or
by pinning a SHA. Nothing else about the second app changes when the image does.

**Why a subdomain and not `trade.thami.dev/vnc2.html`.** The desktop is
noVNC + websockify, and both build their URLs from the root of the site: the page
is `/vnc.html` and it opens a WebSocket at `/websockify`. Served under a path
prefix, that socket request goes to `/vnc2/websockify`, which the container does
not answer — you get a black page with `404` on the socket. Making it work means a
proxy that rewrites the prefix (`StripPrefix` on every path, including the
WebSocket upgrade) plus the same prefix known to websockify. That is a Compose
application with Traefik labels, not a field in the Docker-Image form, and it is
one more thing to get wrong at 3 a.m. A second hostname is one DNS record and
costs nothing. So: `https://trade2.thami.dev/vnc.html` — same page, same
behaviour, its own cookie and password.

**The chart is moved, not added.** The distro's profile carries an `XAUUSD M15`
chart. An instance asking for `DOGEUSD 5` would, on a naive start, get *that*
chart restored **and** a second one opened for `Symbol=DOGEUSD` — two charts, two
copies of the expert, and the MagicNumber lock refusing one of them at random.
So `ensure_profile_chart` moves the profile's chart onto the requested
symbol/timeframe (keeping the original in `/data/mt4/.profile-orig`) and drops the
`<expert>` block that carried the other instrument's inputs; `startup.ini` then
attaches this instance's expert and preset to the only chart there is. You will
see it in the log as `chart: chart04.chr moved XAUUSD 15 -> DOGEUSD 5`, or
`chart: chart04.chr carries DOGEUSD 5 - no rewrite needed` on every later start.

**A third, a fourth.** Same three steps. Practically, what runs out first is
memory: each instance is a Wine prefix, one terminal, Xvfb and x11vnc — budget
~700 MB–1 GB per instance, so three fit on a 4 GB VPS and two comfortably. Watch
`docker stats` on the host rather than guessing, and remember every instance needs
its own trading account (or at least its own magic number *and* symbol if it
shares one — but separate accounts is the honest way, so one account's drawdown
cannot starve another's margin).

**Per-instance presets.** A new strategy that is a *tuning* of this engine is a
new entry in `Tools/make_presets.py` → `PRESETS`, then
`python3 Tools/make_presets.py` (never hand-edit a `.set`: `--check` fails on
overrides that do not match a real input, and the generator is what keeps the
`differs from the EA default` header honest). A strategy that is a *different
engine* is a new `.mq4` in `MQL4/Experts/`, a Dockerfile that copies it, and
`MT4_EXPERT` naming it — the entrypoint already syncs and compiles whatever
`MT4_EXPERT` points at.

**Before a new instance risks money.** Point it at a `-shadow` preset for one
session (`doge-scalp-shadow.set`, `100usd-shadow.set`): the signals, rejections
and dashboard are identical, `trades.csv` stays empty, and you find out whether
the broker's spread, the symbol name and the lot step are what the preset assumed
*before* the first order. An empty `trades.csv` on a `-shadow` preset is the
expected result, not a fault — `DryRun=1` places no orders at all.

**Turning dry-run off.** Out of shadow mode is a preset change, because `DryRun`
is an input and every preset carries it: `doge-scalp-shadow` → `doge-scalp`
(the gold pair `100usd-shadow` → `100usd-demo` worked the same way while that
instance ran — the point of the pairs is that going live is never just `DryRun`;
the shadow copy carries the uncapped guards and the live copy restores the caps).
Reaching for the shadow preset's values and flipping `DryRun` by hand would leave
the risk cap off.

**Sizing follows the account, and the preset names it.** `RiskPercent` sizes every
trade as a share of equity, but the broker's minimum lot (0.01) sets a floor on how
small a trade can be — and `CalcLots` *blocks* a trade whose risk-sized size falls
below that floor rather than over-risking silently. The practical consequence:

- `doge-scalp` — 1.5% of equity per trade. Comfortable from roughly $100 up
  (measured at 0.5% for six live days: +1.4% total, +0.28R/trade — the strategy
  pays, 0.5% just pays slowly, so it was raised).
- `doge-10` — the $10-account variant: 3.0% per trade with the stop bracket
  tightened to 150–300 pts, so worst-case min-lot risk is ~$0.30 = 3% of the
  starting balance; `MaxDailyLossPct`/`MinFreeMarginUsd` widened from the $100
  defaults, which a $10 account would trip on its first normal loss or first
  boot. Grow the account, then switch the instance to `doge-scalp`
  (`MT4_PRESET2=doge-scalp`, redeploy).

1. Change the env, not the file in the container. `MT4_PRESET2`
   in the application's Environment tab (or the `MT4_PRESET2`
   repository variable the workflow sends), then redeploy. Editing
   `/data/mt4/MQL4/Presets/*.set` over `docker exec` looks like it works and is
   undone at the next start: `sync_ea` re-copies `/opt/ea/presets/*.set` from the
   image whenever `MT4_EA_PRESET_SYNC=1` (the default), and `startup.ini` is
   rewritten with `ExpertParameters=<preset>.set` every boot.
2. Turn AutoTrading on in that instance's desktop and untick the three
   "disable automated trading when …" boxes (§3). A live preset with the button
   off places nothing and logs `BLOCKED_NO_AUTOTRADE` per signal instead of
   `DRY`.
3. Confirm the preset actually moved: the boot banner names it —
   `[hex] … | preset doge-scalp` — and the chart's `Mode` line reads `LIVE`
   instead of `DRY RUN (no orders)`. A shadow preset left on instance 1 while you
   are testing instance 2 is the usual reason "it still does nothing".

**Real money is a second, separate step.** All the presets are tuned against a
$100 *demo* (`FixedLot=0.01`, `MaxRiskAmount=2.0`, `MinFreeMarginUsd=40`,
`MaxSpreadDollars=0.45` on gold / `0.0008` on DOGE). Trading live means a live
account's `MT4_LOGIN`/`MT4_PASSWORD` and a live `MT4_SERVER` (e.g. `TMGM-Live`)
— plus `config/servers.ini` on that volume must already know the server (§4C), or
the login sits at `connect failed [No connection]` however right the password is.

**"No trades" is a question the log can now answer.** The expert writes *why* it
passed to `rejections.csv` and never prints, so the container log used to show a
session that traded nothing and said nothing about it — indistinguishable from a
robot that never started. The entrypoint now reads that file back:

```
[rej] 2026.10.22 10:00:00  GUARD 1  outside session
[rej] 2026.10.22 10:07:00  GUARD 1  spread 19.0 > 12.0
[hex] state: last 200 rejections -> GUARD 50, NO_CONFLUENCE 9, NO_TRIGGER 3 | closed
      trades in trades.csv: 0 | signals today: 53 | last reason: GUARD
```

Only a *change* of reason-and-detail is printed (while a reason holds, `Reject()`
writes a row per tick), and the state line repeats every ten minutes. If the last reason is
`AUTOTRADE_DISABLED`, the terminal's AutoTrading button is off — nothing outside the
terminal can turn it on, and the entrypoint says so in words instead of leaving you
to find it in a CSV.

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
18:03:52 [hex] server route : no config/MetaQuotes-Demo.srv; this terminal keeps its
               servers in config/servers.ini (20052 bytes) - if the login window's
               Server dropdown does not offer MetaQuotes-Demo, that name has no
               address in this tree and the dial will fail whatever you type …
18:03:52 [hex] synced HEX-FVG-Breaker.mq4 and 6 presets into MQL4/
18:03:55 [metaeditor] 0 errors, 0 warnings, 162 msec elapsed
18:03:55 [hex] compiled HEX-FVG-Breaker.ex4 from source (152972 bytes)
18:03:55 [hex] startup.ini: profile=default server=MetaQuotes-Demo symbol=XAUUSD expert=HEX-FVG-Breaker preset=100usd-demo
18:03:55 [hex] virtual display :99 (1440x900x24)
18:03:55 [hex] window manager: openbox (title bars, focus, dialogs raised)
18:03:55 [hex] remote desktop: http://<this-host>:6080/vnc.html  (or tunnel it: ...)
18:03:56 [hex] following /data/mt4/logs (0 file(s) there now)
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

`[mt4] following /data/mt4/logs` is printed once, before `terminal.exe` starts, and
it is the line that makes silence meaningful: the mirrors are background loops, and
one that has quietly died prints nothing — which looks exactly like a terminal with
nothing to say. If that line is missing, the mirror is the problem, not MT4. On a
volume with no account record yet, `login :` (or the `login:` warning) also says
whether the terminal intends to log in by itself or is waiting for you.

When MT4 writes a reason of its own, one `HINT:` line follows it and says what the
reason means and what to do, once per container run:

```
18:04:02 [mt4] 0  15:39:52  '990158154': connect failed [No connection]
18:04:02 [hex] HINT: the terminal could not reach TradeMaxGlobal-Demo-2 with login
               990158154. MT4 dials only servers whose address is in its own
               config/servers.ini, and this tree came from one broker's terminal -
               a server name it has never seen fails exactly like this, right
               password or not. Give this instance that broker's server list: …
```

The four it knows are `connect failed`, `invalid account`, `invalid server` and
`account disabled`/`closed` — the whole vocabulary of a terminal that cannot log in,
and the only lines a person has to act on.

`server route :` is the other half of that, printed before the terminal starts: when
`config/<MT4_SERVER>.srv` exists, it lists that server's access points and probes each
one on TCP 443 from inside the container. `answers on TCP 443 at …` means the route is
fine and any failure left is the account. `none of the N access point(s) … answers`
means this host cannot reach the broker's server at all — MT4 will say
`connect failed [No connection]` for ever and never send the password, so no login
detail, preset or image can help. (On a tree that has never been logged in it says
there is no such `.srv` and that the list lives in `servers.ini`, which is normal.)


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
and notice when it stops. It does not fit GHCR/Dokploy at all. From a Mac,
`open 'rdp://…'` fails with *Unable to interpret … as a path or URL* until an RDP
client exists to receive it, so `Tools/rdp.sh` picks whichever client is installed
(`brew install freerdp` needs no sudo and no App Store account) and connects.

**This** — one Linux VPS, roughly $5–7/month (MT4 is a 32-bit app: 2 vCPU, 2 GB
RAM and 10 GB disk is plenty). It fits the CI you already have, `docker logs`
shows the EA's prints, and a rebuild is a `git push`.

---

## 9. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| both hostnames show the same account and the same chart | the second container is instance 1 too: a Docker-Image app copied from the first (no `MT4_INSTANCE=2`, plain `MT4_LOGIN`), a compose service pointed at the other service's **volume**, or an old application still serving that hostname on a stale `:sha` | the first three log lines answer it: `instance N` must be `1` on `trade.thami.dev` and `2` on `trade2.thami.dev`, and `image build` must be the commit you deployed. `WARN: shared volume: … in use right now by another container` means the volume, and nothing else |
| the second hostname serves nothing, or its certificate is for the wrong app | the DNS record is missing, or the domain was added without a service name (compose apps route per service) | Domains → host, path `/`, **service `mt4-doge`**, port `6080`, HTTPS + Let's Encrypt; its `A` record must point at this server. One hostname, one service — delete any older application still claiming it |
| no `[mt4]` lines at all for a whole session, though the terminal is clearly running | the journal mirror ended at its first poll: under the entrypoint's `set -e`, reading a `.seen` file that did not exist *yet* returned 1 and killed the background loop — so every message that would have explained the terminal (a failed login above all) went only to a file on the volume | fixed — the mirror prints `[mt4] following /data/mt4/logs (N file(s) there now)` at start and survives a failed command. If that line is missing, the mirror is the thing to look at, not the terminal |
| the login window does not appear, or typing into a dialog does nothing | the image had no window manager, so MT4's dialogs are unmanaged: they can open *behind* the main window, and the keyboard focus stays on the window behind them | fixed — `openbox` starts with the display: title bars (that is where MT4 prints the account and server), dialogs raised and focused |
| the desktop shows the chart (`DOGEUSD,M5` in the title) but `Waiting for update`, `No connection` in the corner and an empty Market Watch | not logged in — and not a chart problem: the chart comes from the profile, the terminal is offline. This is the first start of a volume with no `config/accounts.ini`, and `startup.ini`'s login can only re-use an account, never create one | `File → Login` once in the desktop with `MT4_LOGIN2`/`MT4_PASSWORD2`. The log line `login: this volume has no config/accounts.ini …` says the same thing; after the login it becomes `login : … - re-used from config/accounts.ini`. §3 |
| the login window does not list the broker (`TradeMaxGlobal-Demo-2`) at all | MT4 cannot dial a server name it has no address for, and `config/servers.ini` is a per-terminal, per-broker cache: this tree came from the MetaQuotes demo build, so it knows `MetaQuotes-Demo` and nothing else. A typed-in name is accepted by the dialog and then fails at dialling | give the terminal its broker's servers, three routes in **§4C**: `File → Open an Account` in the desktop (downloads the list — check by watching `config/servers.ini`'s timestamp change), `docker cp` of `servers.ini` and/or `config/*.srv` from a terminal that knows the account, or `MT4_DISTRO_URL2` with a distro prepared from that broker's own terminal. Then `File → Login` once |
| the login window lists the broker and the credentials are right, yet every attempt ends in `'<login>': connect failed [No connection]`, Market Watch stays empty and the chart says `Waiting for update` | an empty Market Watch and a blank chart are *consequences* of no login, not separate faults: the symbol list, the ticks and the history all come from the server. And `connect failed` never reaches the password — MT4 gives the same message for a name it has no address for and for an address the host cannot reach | read the `server route :` line at startup. It names the terminal's own access points out of `config/<server>.srv` and probes TCP 443 from inside the container: `answers on TCP 443 at …` means the route is fine and the login is the problem, `none of the N access point(s) … answers` means the host cannot reach that server at all (datacentre/ASN filter, geo, or the server moved), which no setting in this repo can change — run it where it can reach the broker, or ask the broker, or validate the strategy on a reachable server meanwhile |
| `Automated trading disabled because the account has been changed` (and then `Automated trading disabled`) in the journal, expert loaded but idle | MT4's *Options → Expert Advisors* box "Disable automated trading when the account has been changed" is ticked by default, and any account switch — including the first successful login on a fresh volume — turns AutoTrading off. The expert stays attached, prints nothing, and `IsTradeAllowed()` is false | untick all three "disable automated trading when …" boxes once in the desktop (**§3**), restart, and check the EA dashboard (or its INIT push) says trading is allowed |
| `app not found` at both hostnames, containers running | the domain was added *after* the last deploy, so no Traefik label points at the container (labels are written at container creation) | **Deploy** once more after adding the domains. Verify: `docker inspect <container> --format '{{index .Config.Labels "traefik.http.routers.<app>.rule"}}'` must print your `Host(...)` rule, and `docker logs dokploy-traefik 2>&1 \| tail` must not say "no such service" |
| `502 Bad Gateway` instead of `app not found` | the label exists but Traefik cannot reach the container: the service is not on `dokploy-network` | the compose file already puts both services there (`networks: [dokploy-network]`, declared `external: true`); if you edited it, `docker network ls \| grep dokploy` shows the name |
| `line 860: MT4_PERIODm: unbound variable`, restart loop, only on `mt4-doge` | a banner line wrote `$MT4_PERIODm`, which bash reads as the variable `MT4_PERIODm`; with `MT4_PERIOD` set (instance 2 has `MT4_PERIOD2=5`) the word is expanded and the variable does not exist. Instance 1 has an empty period, so it never showed | fixed in the image (and the selftest now renders the banner for both instances under `set -u`). Redeploy to pick up the new `:live` |
| `FATAL: the installer produced no terminal under .../drive_c` | MetaQuotes' installer does not run under Wine — it is a 64-bit web installer that exits silently | expected with `MT4_DISTRO_URL` empty; supply a distro (§4A). The installer's own output is printed just above the error |
| `tar: ./MQL4: Cannot mkdir: Permission denied` on first start | the volume belongs to another uid, so seeding as `trader` cannot write into it | `docker-entrypoint.sh` chowns `/data` as root before dropping privileges; if it persists the mount is a bind mount, which keeps its *host* ownership — `chown -R 1000:1000` that host directory or use a named volume |
| restart loop, `BadAccess (MIT-SHM)` while installing | Xvfb and Wine share memory to draw | `shm_size: 512m` (already set); `ipc: host` if it persists |
| terminal runs, no `[ea]` lines, no push | AutoTrading off, or the container lacks `cap_add: SYS_PTRACE` | `CAP_SYS_PTRACE: granted to the container, not to the trader process` is the **healthy** line (gosu dropped root, which clears the effective set; Wine traces its own children and needs no capability) — so check the smiley/AutoTrading first, then §3. `WARN: CAP_SYS_PTRACE is not in this container` is the one worth fixing: that app type cannot set it, the compose file does |
| the `CAP_SYS_PTRACE` warning on a container that has `cap_add: SYS_PTRACE` | the check read `CapEff`, which is empty for the `trader` process because gosu dropped root | fixed — it reads `CapBnd` (what the container was given) and only warns when the container really lacks it |
| push never arrives, dashboard `err 4060` | ntfy URL missing from the WebRequest list | §3, second switch |
| INIT push: `AutoTrading BLOCKED (terminal not connected yet)` | the hello went out before the login finished | harmless once. If it persists, the server name or password is wrong — check the `[mt4]` login lines |
| `X Error ... BadAccess (MIT-SHM)` and a black desktop | `/dev/shm` too small | `shm_size: 512m` is already set; if it still happens add `ipc: host` |
| `no desktop at all` in the log | by design: `ENABLE_VNC=1` with an empty `VNC_PASSWORD` | set the password |
| two `Expert HEX-FVG-Breaker …: loaded successfully` lines, one per timeframe | MT4 restores the profile's charts **and** opens one for `startup.ini`'s `Symbol=`, so the expert runs twice on one magic number. The entrypoint now omits `Symbol=` when the profile already carries a chart for the symbol (`chart source: the default profile`), and the EA refuses to start a second copy (`FATAL another copy of this EA holds MagicNumber`) | if you still see two charts, the profile itself has two — remove one and redeploy |
| two `loaded successfully` lines with *different* timestamps, the earlier one hours old | not a double load: on a restart the log mirror re-read the journal that was already on the volume, so the previous run's lines came out again | fixed — the mirror now starts at the end of an existing journal and says `N line(s) from the previous run … not replayed`. One run = one `loaded successfully` |
| `Compiling '._HEX-FVG-Breaker'` (and 200 more `._` names) while MT4 starts | the distro was built on macOS without `--no-mac-metadata`: Linux tar extracts the AppleDouble twins that macOS `tar -t` hides, and MetaEditor compiles every one. Costs ~15 s of boot and puts junk in `MQL4` | rebuild the distro with `deploy/scripts/prepare-distro.sh` (it now refuses to write an archive with AppleDouble members) and re-seed with `MT4_FORCE_SEED=1`. The entrypoint also filters `._*` on extraction, so a stale archive is no longer noisy |
| healthcheck `unhealthy` while the market is shut | `equity.csv` is only written on ticks | raise `HEX_HEARTBEAT_MAX_AGE_MIN`, or ignore it over the weekend |
| it re-seeds the distro on every start | the volume is not mounted, so `/data` is empty each time | check the `volumes:` block. Seeding is idempotent once `/data/mt4/terminal.exe` exists |
| it trades the wrong timeframe | the chart comes from the profile, not from the env | prepare a distro with the XAUUSD M15 chart, or set the chart once in the desktop (the profile is then saved on the volume) |
| two robots on one account | the laptop copy is still running | stop one of them, always |
| a second instance opens an XAUUSD chart, or logs `FATAL another copy of this EA holds MagicNumber` | the volume's profile carried a symbol the env did not ask for, and `Symbol=` opened a second chart next to it | `ensure_profile_chart` moves the profile's chart instead of adding one (`chart: chart04.chr moved XAUUSD 15 -> DOGEUSD 5`). If it logs `chart: could not rewrite`, that volume's `.chr` is not the plain-text form it expects — set the symbol once in the desktop (right-click the chart → Symbol) and it is saved on the volume |
| `spread 0.0012 > 0.0008` in `rejections.csv` on the crypto instance | the preset's spread cap is tighter than the broker's normal spread | raise `MaxSpreadDollars` in `Tools/make_presets.py` to just above what Market Watch shows, `python3 Tools/make_presets.py`, redeploy |
| the second instance's chart is empty and the expert never trades | the broker names the pair differently (`DOGEUSD.a`, `DOGEUSD.raw`) | read the exact name off its Market Watch, set `MT4_SYMBOL2` to it, redeploy — the chart is moved onto the new name on the next start |
| instance 2 comes up logged into the gold account | the distro is a copy of the gold terminal, so it carries `config/accounts.ini` and the last server | instance 2 moves that state aside on its first boot (`seed: N file(s) … moved out of the way`, keep is in `/data/mt4/.before-instance2`). If it still happens, check that this app has `MT4_INSTANCE=2` — the step is skipped for instance 1 on purpose. The reverse is deliberate too: a distro prepared from *that broker's own* terminal should keep its login, and that is `MT4_KEEP_SEED_LOGIN2=1` (§4C) |
| `prepare-broker-distro.sh` says the installer produced no terminal | the broker shipped a 64-bit web stub, the same kind MetaQuotes ships; nothing installs and no window opens | its own output is in the container log the script prints. Install that broker's terminal on a Windows machine (or a Mac with its installer), log in once, close it, and archive the folder by hand — `prepare-distro.sh` does the same work for the MetaQuotes install, so copy its `tar` line verbatim — then continue from `MT4_DISTRO_URL2` in §4C |
| the DOGE desktop sits on a login dialog with no accounts listed | that copy of the terminal has never seen TMGM's server, so `MT4_SERVER2` resolves to nothing | log in once on that desktop (File → Login / Open an Account) and read the exact server name off the dialog; MT4 saves it on this volume and later boots log in from `startup.ini` |
| `FATAL: MT4_INSTANCE=2 has no MT4_LOGIN2 …` | the application says it is instance 2 but its env has no `…2` copies — usually a copied application whose values were not replaced | fill `MT4_LOGIN2`/`MT4_PASSWORD2`/`MT4_SERVER2`/`MT4_SYMBOL2`/`MT4_PRESET2` in this app's Environment tab. This refusal is deliberate: the alternative is trading the DOGE preset on the gold account |
| `FATAL: this volume belongs to account … and this container is …` | two applications were given the same volume (the second one has no volume of its own, or was created from the first without changing its mount) | give this application its own volume at `/data`. If you really mean to move *this* volume to the other account, delete `/data/.hex-instance` on it first |
| `FATAL: this volume was claimed by instance 2 … but this container runs as instance 1` | the app's `MT4_INSTANCE` does not match the volume. Instance 1 reads `MT4_LOGIN`, instance 2 reads `MT4_LOGIN2` — so the wrong number means this app is using the *other* app's account and symbol while its env looks perfectly complete | set `MT4_INSTANCE` to the number in the message. If the volume really belongs to this instance now, delete `/data/.hex-instance` and restart |
| the second app still shows the gold account and the gold chart, and its log has no `seed:` line | it is not running a build with the instance rules in it, or it is not instance 2 at all — the neutralise step only runs for instance ≥ 2, and an old image has no such step | compare the log's `image build` line with the commit you deployed, and `instance N` on the first line with what that app is supposed to be. A pinned `:sha` tag never moves, and `:live` needs a pull |
| no trades at all, and nothing in the log about it | three unrelated causes that used to look identical: the preset says `DryRun=1` (`-shadow`), the terminal's AutoTrading is off, or every setup is being rejected by a filter | read the `[rej]` and `[hex] state:` lines — they name the reason. `AUTOTRADE_DISABLED` → click AutoTrading on the desktop; `GUARD … spread` → the preset's cap is tighter than the broker; `NO_CONFLUENCE`/`TOO_FAR`/`OVEREXTENDED` → filters working as designed; an empty `trades.csv` on a `-shadow` preset is correct behaviour, and the banner's `preset …` line names which one is loaded (§6, "Turning dry-run off") |
| `AUTOTRADE_DISABLED` in `rejections.csv`, dashboard `Trading : BLOCKED` | AutoTrading is a terminal-wide button and no MQL4 code can turn it on | click it once on the desktop (§3). It is not stored on the volume, so a re-created Wine prefix starts with it off again |
| instance 2 logs into the wrong account | the login is also stored in the volume's `config/accounts.ini`, so a shared volume logs in as whoever used it last | the same fix as above — one volume per instance. The `FATAL` above catches it before the terminal starts |
| `MT4_INSTANCE must be a number` | `MT4_INSTANCE` holds something other than `1`, `2`, `3` … | it is an instance *number*, not a name |
| no trades on a small account, and `SIZE` in `rejections.csv` ("margin: only … lots affordable, broker minimum 0.01") | `RiskPercent` of a small balance cannot buy the broker's minimum lot — `doge-scalp` needs roughly $100 for that, and `CalcLots` blocks the trade rather than over-risk it | use the `doge-10` preset for a $10 account (§6, "Sizing follows the account"), or fund the account past the minimum-lot threshold |
| every entry push says `R:R 0.00` | a build older than 2026-10-30: the planned-R:R arithmetic divided a price distance by a point count, so every push and every `signals.csv` row showed 0.00 | redeploy; the fixed build prints the real planned R:R (e.g. `R:R 2.00`), and never places a target closer than 1R |

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



