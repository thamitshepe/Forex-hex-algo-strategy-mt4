# First Run — MT4 Checklist

From an empty machine to "the EA is live on demo and talking to me".
Run this top to bottom, once. `DEMO-PLAN.md` takes over afterwards.

Nothing here is optional except the parts marked *(optional)*. Every step has a
thing you can **see** that proves it worked — do not move past a step until you
have seen its proof.

---

## 0. MT4, not MT5 (this is where most attempts die)

`HEX-FVG-Breaker.mq4` is **MQL4**. MetaTrader 5 cannot compile it — MetaEditor 5
has no `OrderSend`/`OrderSelect`/`OrdersTotal` with MQL4 semantics. A clean
MT4 install is a hard prerequisite.

- [ ] Confirm what you actually have installed. On macOS, MT4 and MT5 keep
      separate wine prefixes:

      ```bash
      ls -d ~/Library/Application\ Support/net.metaquotes.wine.* 2>/dev/null
      ```

      `metatrader4` = good. Only `metatrader5` = you need MT4 before anything
      else in this file applies.

- [ ] Install MT4. On **macOS**, MetaQuotes ships a native MT4 package
      (https://www.metatrader4.com/en/terminal — the `.pkg` download). It bundles
      its own Wine, drops `MetaTrader 4.app` in `/Applications`, and creates the
      `net.metaquotes.wine.metatrader4` prefix the first time you launch it — no
      CrossOver, Parallels or Whisky needed. That native layout is what
      `Tools/mt4_compile.sh` in this repo expects, so prefer it here. A broker's
      own MT4 build is fine too if it is MQL4, but via the broker's installer it
      runs through CrossOver/Parallels and its data folder lives elsewhere.
      On Windows it is a plain `setup.exe`.

      > The macOS `.pkg` extracts a payload rather than a signed installer, so if
      > double-clicking it is blocked, the app can be placed by hand: mount the
      > `.pkg`'s `Payload`, then `ditto` `MetaTrader 4.app` into `/Applications`
      > (no `sudo` needed when `/Applications` is admin-writable), and launch it
      > once to build the Wine prefix.

- [ ] Open MT4 once, log into a **demo** account on the broker, and let it
      finish downloading its server list.

> Why the account matters now and not later: the data folder you copy files
> into belongs to the MT4 install, but the $100 demo account and its leverage
> are what `MinFreeMarginUsd` is tuned against. Gold at $100 with 1:100
> leverage is margin-bound — the margin guard, not `MaxLot`, is what keeps a
> second position from opening.

---

## 1. Copy the source into the data folder

- [ ] In MT4: **File → Open Data Folder**. A Finder/Explorer window opens at
      `<data>`. Leave it open.
- [ ] Copy `MQL4/Experts/HEX-FVG-Breaker.mq4` into `<data>/MQL4/Experts/`.
- [ ] Copy the six files from `MQL4/Presets/` into `<data>/MQL4/Presets/`
      (create `Presets` if it is not there).
- [ ] In MT4's Navigator (Ctrl+N): right-click **Expert Advisors → Refresh**.

**Proof:** `HEX-FVG-Breaker` is listed under Expert Advisors in the Navigator.

---

## 2. Compile in MetaEditor

There is a real MetaEditor on this machine, so the compile is verifiable from the
command line without opening the GUI. Pick one path; both produce the same
`.ex4`.

**Headless (preferred):** from the repo root,

```bash
Tools/mt4_compile.sh
```

It runs the `metaeditor.exe` bundled inside `MetaTrader 4.app` against
`MQL4/Experts/HEX-FVG-Breaker.mq4`, prints the compiler log, copies the `.ex4`
next to the source and into the MT4 data folder, and exits non-zero if there are
errors. Requires MT4 to have been launched once (that creates the Wine prefix it
uses).

**In the GUI:** right-click `HEX-FVG-Breaker` in MT4 → **Modify**, or press **F4**
with the file selected, then press **F7** (Compile) in MetaEditor.

Expected either way: `0 errors, 0 warnings`, and `HEX-FVG-Breaker.ex4` appears
next to the `.mq4`.

### The `WebRequest` line (already fixed — do not "fix" it back)

`PushHttp()` in `MQL4/Experts/HEX-FVG-Breaker.mq4` ends with:

```mql4
int rc = WebRequest(verb, url, hdrs, "", timeout, post, postDataSize, result, resHeaders);
```

That is the **nine-argument MQL4 form**: `data_size` (here `postDataSize`) sits
between the payload and the result buffer, and `result_headers` is a plain
`string`, not MQL5's string array. It compiles clean on build 1491.

The earlier version of this file used MQL5's eight arguments (no `data_size`),
which is a hard compile error in MQL4 — `"no one of the overloads can be
applied"`. This whole class of bug (MQL5 API that MQL4 lacks) is now caught
offline: `Tools/mt4_compile.sh` is authoritative, and `Tools/lint_mql4.py` blocks
the MQL5-only names and checks the arity of calls like `WebRequest` and `iATR`.

If your MetaEditor ever *does* reject this line, the signature in its error
message is the authority — but build 1491 accepts the form above, so treat any
regression here as an environment difference, not something to pre-emptively
rewrite. Do not accept an "auto-fix" that converts the file to MQL5.

**Proof:** `0 errors, 0 warnings` in the compiler output, `.ex4` file exists.

---

## 3. Whitelist the notification endpoint

`WebRequest` refuses every URL that is not explicitly allowed. This is a
per-terminal setting and it is not remembered between installs.

- [ ] Get a topic first: install **ntfy** on the phone (iOS/Android, or
      https://ntfy.sh in a browser) and pick a topic name nobody else will
      guess, e.g. `hex-xauusd-7f3`.
- [ ] MT4: **Tools → Options → Expert Advisors** tab (the last one).
- [ ] Tick **Allow Algo Trading**. DLL imports are *not* needed — leave them off.
- [ ] In "Allow WebRequest for listed URL" (the list at the bottom), add exactly:

      ```
      https://ntfy.sh
      ```

      Include the scheme and no trailing slash. `https://ntfy.sh/` or a bare
      `ntfy.sh` will not match.
- [ ] Press OK, then **restart MT4**. This setting is read at startup.

**Proof:** after the restart the address is still in the list.

---

## 4. Attach, load the preset

- [ ] Open an **XAUUSD M15** chart. One chart only — two charts run two
      independent instances that do not know about each other.
- [ ] Drag `HEX-FVG-Breaker` from the Navigator onto the chart.
- [ ] **Common** tab: tick **Allow Algo Trading**.
- [ ] **Inputs** tab → **Load** → `100usd-demo.set`.
- [ ] Still on Inputs, set `NotifyUrl` to `https://ntfy.sh/<your-topic>`. The
      preset leaves it empty, and an empty URL means silence.
- [ ] Tick **AutoTrading** in the toolbar (must be green) and click OK.

The settings that matter for a first run, all already in the preset:

| Setting | Value | What it does |
|---|---|---|
| `FixedLot` | `0.01` | ~$1 per $1/oz of gold movement |
| `MaxRiskAmount` | `2.0` | hard $2 cap per trade |
| `MaxSpreadDollars` | `0.45` | stands aside when gold rolls over and the spread blows out |
| `MinFreeMarginUsd` | `40.0` | the real constraint at $100 — no second position |
| `DryRun` | `false` | real (demo) orders. Set `true` for a first day of signals-only logging |
| `StopTradingHourUTC` | `21` | flat and idle overnight |

**Proof:** the EA's name appears in the top-right of the chart with a hat/smiley,
and a dashboard panel is drawn on the chart.

---

## 5. The five-minute verification

Do not walk away before all four of these are true.

- [ ] **The phone buzzes.** `NotifyTestOnInit = true` sends a hello at startup
      ending "If you read this, notifications work." If it does not arrive, §7.
- [ ] **MT4's Experts log** (Ctrl+T → Experts tab) contains:

      ```
      HEX v3.0 on XAUUSD 15m | digits=2 | $1.0000 per point per lot | contract=100
      HEX : logs -> Common\HEX-Logs
      HEX : push -> https://ntfy.sh/<topic> (must be listed in Tools > Options > Expert Advisors)
      ```

      The `$... per point per lot` figure is the EA telling you how it converted
      dollars into points on *this* broker's gold. If it reads `$0.01` or `$100`
      instead of about `$1`, that broker quotes gold in cents or with different
      digits — stop and re-check `MaxSpreadDollars` before trading.
- [ ] **`notify.csv` exists** in the log folder (§6) with at least the init row.
      The other CSVs are created on their first event rather than at startup, so
      a folder holding only `notify.csv` is normal on day one.
- [ ] **The dashboard's Push line** reads `Push : 0 sent, 0 failed  ()`, or
      `1 sent` once the init ping lands. `0 sent, 1 failed (...)` → §7.

---

## 6. Where the logs actually are

MQL4's `FileOpen` resolves every relative path inside the terminal's **Files
sandbox**, so `Common\HEX-Logs` from the EA is on disk at:

    <data>/MQL4/Files/Common/HEX-Logs/

`UseCommonFolder = false` drops one level: `<data>/MQL4/Files/HEX-Logs/`.
Despite the name, this is a plain subfolder of `Files`, not MT4's own
`Terminal\Common` shared folder — so these logs belong to this one terminal
install. That is fine here: one chart, one terminal.

Fastest way to see them: **File → Open Data Folder**, then navigate
`MQL4 → Files → Common → HEX-Logs`.

From the macOS shell, `Tools/hex_report.py` knows the MetaQuotes-wrapper,
CrossOver, Wine, PlayOnMac and Parallels layouts and finds the folder on its own:

```bash
python3 Tools/hex_report.py                     # auto-locate, print the report
python3 Tools/hex_report.py --out logs/report.md
```

If auto-detection ever misses it, the EA prints its own log folder at startup —
`HEX : logs -> Common\HEX-Logs`, relative to `<data>/MQL4/Files` — so pass it
explicitly with `--dir <path>`. An empty set of logs renders as `INCONCLUSIVE`
rather than crashing, which is the expected output on day one.

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Phone silent, dashboard `0 sent, 1 failed` | `https://ntfy.sh` not whitelisted, or MT4 not restarted after adding it | §3 |
| `webrequest failed, err 4060` (or 5200–5203) | the URL is not on the allow list, or the request itself was refused | §3 |
| `unknown function, or function not allowed` at compile/run | old build, or the file was compiled as MQL5 | §2 |
| `push is ON but NotifyUrl is empty` in the Experts tab | preset loaded with the URL blank | set `NotifyUrl`, re-attach |
| `LOG ERROR append ...` | folder could not be created — usually a read-only data folder | run MT4 with write access to its data folder |
| Smiley but no trades for days | expected. `NO_CONFLUENCE` and `NO_TREND` reject most setups — roughly 1.5 trades/day at the default filters. That is the strategy, not a fault | run the report and read the rejection table |
| Risk per trade far off the ~$2 the preset implies | this broker's gold quote convention differs from the assumed one | read the `$ per point per lot` line, §5 |
| Every `notify.csv` row says `TESTMODE` | you are in the Strategy Tester, where HTTP cannot run | expected; the CSV still records everything |

---

## 8. Done — hand off to the plan

The first run is complete when MT4 compiles the EA with 0 errors, the init ping
reached the phone, and `notify.csv` exists in the log folder. The remaining six
CSVs fill in as their events happen; `trades.csv` may stay empty for days.

- [ ] Run one day with **`DryRun = true`** if you want to watch the filters
      reject before anything is sent. Signals and rejections are logged
      identically; only `OrderSend` is skipped.
- [ ] Then `DryRun = false` and switch to **`DEMO-PLAN.md`**: 10 trading days or
      20 closed trades per window, report daily, no parameter changes until a
      window closes.
- [ ] *(optional)* Leave `NotifyOnTp1 = false` unless you want a ping on every
      partial close.


