#!/usr/bin/env python3
"""
HEX report - turns the EA's CSV logs into a decision, not just numbers.

The EA (MQL4/Experts/HEX-FVG-Breaker.mq4) writes to
<MT4 Data Folder>/MQL4/Files/Common/HEX-Logs/ (MQL4 FileOpen resolves
relative paths inside the Files sandbox):

    trades.csv      one row per closed position (R multiple, MAE/MFE, session, exit reason)
    signals.csv     one row per signal, taken OR simulated (dry run / blocked)
    rejections.csv  one row per reason a live setup was not traded
    zones.csv       zone lifecycle: OPEN / TOUCH / TRADED / CLOSE
    equity.csv      equity + free-margin snapshots
    partials.csv    TP1 fills
    daily.csv       one row per server day

Usage
    python3 Tools/hex_report.py                      # auto-locate logs, print report
    python3 Tools/hex_report.py --dir /path/to/HEX-Logs
    python3 Tools/hex_report.py --out logs/report.md
    python3 Tools/hex_report.py --json               # machine readable
    python3 Tools/hex_report.py --selftest           # run on synthetic data

Stdlib only. Python 3.8+.
"""
import argparse
import csv
import datetime
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict

TRADES = "trades.csv"
SIGNALS = "signals.csv"
REJECTIONS = "rejections.csv"
ZONES = "zones.csv"
EQUITY = "equity.csv"
PARTIALS = "partials.csv"
DAILY = "daily.csv"
NOTIFY = "notify.csv"

# A demo is only worth reading if there are enough closed trades for the
# numbers to mean anything. Below this, say so instead of pretending.
MIN_TRADES_FOR_STATS = 30


def num(row, key, default=0.0):
    try:
        v = str(row.get(key, "")).strip().replace("%", "")
        if v in ("", "-", "nan", "None"):
            return default
        return float(v)
    except (TypeError, ValueError):
        return default


def txt(row, key, default="?"):
    v = row.get(key)
    if v is None or str(v).strip() == "":
        return default
    return str(v).strip()


# ---------------------------------------------------------------- loading

# Relative path of the log folder inside an MT4 data folder. FileOpen() in
# MQL4 resolves relative names inside <data>/MQL4/Files, so "Common\\HEX-Logs"
# from the EA is <data>/MQL4/Files/Common/HEX-Logs on disk. The bare
# MQL4/Common/HEX-Logs form is kept too: it is what a manual copy of the
# folder looks like, and what a build that resolves outside Files/ would write.
LOG_SUFFIXES = (
    os.path.join("MQL4", "Files", "Common", "HEX-Logs"),
    os.path.join("MQL4", "Files", "HEX-Logs"),  # UseCommonFolder = false
    os.path.join("MQL4", "Common", "HEX-Logs"),
)


def candidate_dirs():
    """Where MT4's Common folder tends to live on macOS/Linux/Windows."""
    home = os.path.expanduser("~")
    user = os.path.basename(home)

    # Every plausible MT4 data folder. The install path differs per installer:
    # MetaQuotes' own Mac wrapper, CrossOver bottles, plain Wine, PlayOnMac and
    # Parallels Tool Download each nest the data folder somewhere else.
    roots = [
        # MetaQuotes official macOS package (MetaTrader 4.app -> wine wrapper)
        os.path.join(home, "Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files/MetaTrader 4"),
        os.path.join(home, "Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/Program Files (x86)/MetaTrader 4"),
        # CrossOver
        os.path.join(home, "Library/Application Support/CrossOver/Bottles/MT4/drive_c/Program Files/MetaTrader 4"),
        os.path.join(home, "Library/Application Support/CrossOver/Bottles/Default/drive_c/Program Files/MetaTrader 4"),
        # plain Wine
        os.path.join(home, ".wine/drive_c/Program Files/MetaTrader 4"),
        # PlayOnMac / PlayOnLinux
        os.path.join(home, "PlayOnMac/Wine/Programs/MetaTrader 4"),
        # Parallels Tool Download (PTD)
        os.path.join(home, "Library/Application Support/PTD/MetaTrader 4/drive_c/users/steamuser/AppData/Roaming/MetaTrader 4"),
        # Windows, when run there
        os.environ.get("PROGRAMFILES", ""),
        os.path.join(os.environ.get("APPDATA", ""), "MetaTrader Ltd") if os.environ.get("APPDATA") else "",
    ]

    out = []
    for root in roots:
        if not root:
            continue
        for suffix in LOG_SUFFIXES:
            out.append(os.path.join(root, suffix))

    # Wine layouts that address the data folder through the fake user profile
    # instead of Program Files.
    wine_users = [
        os.path.join(home, "Library/Application Support/net.metaquotes.wine.metatrader4/drive_c/users"),
        os.path.join(home, "Library/Application Support/CrossOver/Bottles/MT4/drive_c/users"),
        os.path.join(home, ".wine/drive_c/users"),
    ]
    appdata_names = ("Application Data", "AppData/Roaming")
    for wuser in wine_users:
        for who in (user, "crossover", "steamuser", "user"):
            for appdata in appdata_names:
                for suffix in LOG_SUFFIXES:
                    out.append(os.path.join(wuser, who, appdata,
                                            "MetaTrader Ltd", *suffix.split(os.sep)))
                    out.append(os.path.join(wuser, who, appdata,
                                            "MetaTrader 4", *suffix.split(os.sep)))

    env_home = os.environ.get("HOME_MT4", "")
    if env_home:
        out.append(env_home)

    seen, uniq = set(), []
    for d in out:
        if d and d not in seen:
            seen.add(d)
            uniq.append(d)
    return uniq


def locate_logs(cli_dir=None, verbose=True):
    """Find the HEX-Logs folder: explicit arg, known paths, then a bounded search."""
    if cli_dir:
        if os.path.isdir(cli_dir):
            return cli_dir
        raise SystemExit(f"log dir not found: {cli_dir}")

    for d in candidate_dirs():
        if os.path.isdir(d) and os.listdir(d):
            if verbose:
                print(f"[hex_report] using {d}", file=sys.stderr)
            return d

    home = os.path.expanduser("~")
    try:
        res = subprocess.run(
            ["find", home, "-maxdepth", "14", "-type", "d", "-name", "HEX-Logs",
             "-not", "-path", "*/.Trash/*"],
            capture_output=True, text=True, timeout=45,
        )
        for line in res.stdout.splitlines():
            if os.path.isdir(line) and os.listdir(line):
                if verbose:
                    print(f"[hex_report] found {line}", file=sys.stderr)
                return line
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


def read_csv(d, name):
    path = os.path.join(d, name)
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            if row and any((v or "").strip() for v in row.values()):
                rows.append(row)
    return rows


# ---------------------------------------------------------------- analytics

def summarize(rows):
    """Core stats over closed trades. Everything is R-based so lot size and
    stop distance never distort the comparison between slices."""
    rs = [num(r, "r_multiple") for r in rows]
    n = len(rs)
    if n == 0:
        return {"n": 0, "win_rate": 0.0, "avg_r": 0.0, "profit_factor": 0.0,
                "expectancy_r": 0.0, "total_r": 0.0, "max_dd_r": 0.0,
                "avg_win_r": 0.0, "avg_loss_r": 0.0, "best_r": 0.0, "worst_r": 0.0,
                "streak_loss": 0, "streak_win": 0, "pnl_net": 0.0, "avg_hold_bars": 0.0,
                "avg_mfe_r": 0.0, "avg_mae_pts": 0.0, "avg_mae_pts_winners": 0.0,
                "avg_mfe_pts": 0.0, "be_rate": 0.0}
    wins = [r for r in rs if r > 0]
    losses = [r for r in rs if r < 0]
    gross_w = sum(wins)
    gross_l = -sum(losses)
    pf = (gross_w / gross_l) if gross_l > 0 else float("inf") if gross_w > 0 else 0.0

    # equity curve in R units + max drawdown in R units
    run = peak = 0.0
    max_dd = 0.0
    for r in rs:
        run += r
        peak = max(peak, run)
        max_dd = max(max_dd, peak - run)

    def streak(sign):
        best = cur = 0
        for r in rs:
            if (sign > 0 and r > 0) or (sign < 0 and r < 0):
                cur += 1
                best = max(best, cur)
            else:
                cur = 0
        return best

    holds = [num(r, "hold_bars") for r in rows]
    mfe_r = [num(r, "mfe_r") for r in rows]
    # mae_pts is written by the EA as a NEGATIVE number: the deepest adverse
    # excursion in points. Magnitude is what matters for stop analysis.
    mae = [num(r, "mae_pts") for r in rows]
    mae_loss = [num(r, "mae_pts") for r in rows if num(r, "r_multiple") < 0]
    mae_win = [num(r, "mae_pts") for r in rows if num(r, "r_multiple") > 0]
    mfe_pts = [num(r, "mfe_pts") for r in rows]
    be = sum(1 for r in rows if txt(r, "exit_reason").upper() in ("BE_OR_TRAIL", "BREAKEVEN"))
    mean = lambda xs: round(sum(xs) / len(xs), 1) if xs else 0.0
    return {
        "n": n,
        "total_r": round(sum(rs), 2),
        "avg_r": round(sum(rs) / n, 3),
        "win_rate": round(100.0 * len(wins) / n, 1),
        "profit_factor": round(pf, 2) if pf != float("inf") else float("inf"),
        "expectancy_r": round(sum(rs) / n, 3),
        "avg_win_r": round(sum(wins) / len(wins), 2) if wins else 0.0,
        "avg_loss_r": round(sum(losses) / len(losses), 2) if losses else 0.0,
        "best_r": round(max(rs), 2),
        "worst_r": round(min(rs), 2),
        "max_dd_r": round(max_dd, 2),
        "streak_win": streak(1),
        "streak_loss": streak(-1),
        "pnl_net": round(sum(num(r, "pnl_net") for r in rows), 2),
        "avg_hold_bars": round(sum(holds) / n, 1),
        "avg_mfe_r": round(sum(mfe_r) / n, 2),
        "avg_mae_pts": mean(mae_loss),
        "avg_mae_pts_winners": mean(mae_win),
        "avg_mfe_pts": mean(mfe_pts),
        "be_rate": round(100.0 * be / n, 1),
    }


def is_phantom(row):
    """True for a trades.csv row that was never a real trade.

    A deleted limit order leaves a history row with no position, so older EA
    builds wrote it up as a 0.00R trade with an empty exit reason. Counted as
    neither win nor loss, it drags expectancy toward zero and inflates the
    trade count. The EA no longer writes these; logs from before the fix have
    them.
    """
    return (abs(num(row, "r_multiple")) < 1e-9
            and abs(num(row, "pnl_net")) < 1e-9
            and txt(row, "exit_reason", "").upper() in ("", "UNKNOWN", "NONE", "?"))


def phantom_rows(rows):
    """How much of a trades.csv is phantom, for the honesty note in the report."""
    ph = [r for r in rows if is_phantom(r)]
    n = len(rows)
    return {
        "count": len(ph),
        "pct": round(100.0 * len(ph) / n, 1) if n else 0.0,
        "first": txt(ph[0], "close_time", "?") if ph else None,
        "last": txt(ph[-1], "close_time", "?") if ph else None,
    }


def group_stats(rows, key):
    out = {}
    for r in rows:
        out.setdefault(txt(r, key), []).append(r)
    return {k: summarize(v) for k, v in sorted(out.items())}


def max_drawdown_pct(equity_rows):
    """Peak-to-trough drawdown from the equity snapshots, in %."""
    peak = -float("inf")
    max_dd = 0.0
    first = last = None
    for r in equity_rows:
        eq = num(r, "equity")
        if eq <= 0:
            continue
        if first is None:
            first = eq
        last = eq
        peak = max(peak, eq)
        if peak > 0:
            max_dd = max(max_dd, (peak - eq) / peak * 100.0)
    return {"max_dd_pct": round(max_dd, 2), "start_equity": first, "end_equity": last,
            "snapshots": len(equity_rows)}


def zone_funnel(zones_rows, signals_rows):
    """How the zone population dies. This is where tuning actually happens:
    if 90% of zones die 'closed through' the detectors are too loose."""
    ev = Counter(txt(r, "event").upper() for r in zones_rows)
    close_notes = Counter()
    for r in zones_rows:
        if txt(r, "event").upper() == "CLOSE":
            note = txt(r, "note", "")
            tag = note.split()[0].rstrip("%").upper() if note else "?"
            close_notes[tag] += 1
    by_type = Counter(txt(r, "zone_type").upper() for r in zones_rows if txt(r, "event").upper() == "OPEN")
    traded = sum(1 for r in signals_rows if txt(r, "mode").upper() in ("MARKET", "PENDING"))
    return {"events": dict(ev), "created_by_type": dict(by_type),
            "death_causes": dict(close_notes), "zones_traded": traded}


def rejection_breakdown(rej_rows):
    c = Counter(txt(r, "reason").upper() for r in rej_rows)
    spread_only = sum(1 for r in rej_rows if txt(r, "reason").upper() in ("GUARD", "SPREAD"))
    return {"total": len(rej_rows), "by_reason": dict(c.most_common()), "spread_or_guard": spread_only}


def spread_cost_check(trades_rows):
    """Is the spread eating the edge? Gold accounts die here, not in the logic."""
    if not trades_rows:
        return {}
    costs = [num(r, "spread_pts_at_entry") for r in trades_rows]
    stops = [num(r, "stop_pts") for r in trades_rows]
    n = len(costs)
    avg_cost = sum(costs) / n if n else 0.0
    avg_stop = sum(stops) / n if n else 0.0
    ratio = (avg_cost / avg_stop * 100.0) if avg_stop > 0 else 0.0
    # spread cost expressed in R: the fraction of planned risk handed to the
    # broker the instant the position opens
    spread_r = (avg_cost / avg_stop) if avg_stop > 0 else 0.0
    return {"avg_spread_pts": round(avg_cost, 1), "avg_stop_pts": round(avg_stop, 0),
            "spread_pct_of_stop": round(ratio, 1), "spread_cost_r": round(spread_r, 3),
            "worst_spread_pts": round(max(costs), 1) if costs else 0.0}


def mfe_efficiency(trades_rows):
    """How much of the excursion into profit is actually banked. Measured only
    over trades that reached at least +0.5R, because a trade that never went
    0.5R into profit has no capture question to answer. Low efficiency on those
    says the exit is too tight, not that entries are bad."""
    if not trades_rows:
        return {}
    eligible = [r for r in trades_rows if num(r, "mfe_r") >= 0.5]
    eff = sorted(num(r, "r_multiple") / num(r, "mfe_r") for r in eligible)
    if not eff:
        return {"trades_with_mfe": 0, "gave_back_pct": 0.0}
    med = eff[len(eff) // 2]
    gave_back = sum(1 for r in eligible if num(r, "r_multiple") <= 0.25)
    never_any = sum(1 for r in trades_rows if num(r, "mfe_r") < 0.25)
    return {"trades_with_mfe": len(eff), "avg_efficiency": round(sum(eff) / len(eff), 2),
            "median_efficiency": round(med, 2), "gave_back_1R": gave_back,
            "gave_back_pct": round(100.0 * gave_back / len(eff), 1),
            "never_reached_half_r": never_any}


def notify_stats(rows):
    """Summarise notify.csv: what was sent, dropped, failed. The audit trail
    the EA keeps for its own messages, so a silent phone is explained by the
    log rather than by guesswork. DROPPED (throttle/dedupe) is expected
    behaviour; FAIL means the endpoint never accepted the message and is
    almost always the WebRequest URL not being whitelisted."""
    if not rows:
        return None
    by_status = Counter(txt(r, "status", "?").upper() for r in rows)
    by_tag = Counter(txt(r, "tag", "?").upper() for r in rows)
    drop_reasons = Counter()
    last_fail = None
    for r in rows:
        st = txt(r, "status", "?").upper()
        if st == "DROPPED":
            drop_reasons[txt(r, "detail", "?")] += 1
        elif st == "FAIL":
            last_fail = (txt(r, "time", "?"), txt(r, "tag", "?"), txt(r, "detail", "?"))
    total = len(rows)
    ok = by_status.get("OK", 0)
    failed = by_status.get("FAIL", 0)
    dropped = by_status.get("DROPPED", 0)
    testmode = by_status.get("TESTMODE", 0)
    return {"total": total,
            "ok": ok, "failed": failed, "dropped": dropped, "testmode": testmode,
            "by_status": dict(by_status),
            "by_tag": dict(by_tag),
            "drop_reasons": dict(drop_reasons),
            "last_fail": last_fail,
            "fail_pct": round(100.0 * failed / total, 1) if total else 0.0}


def hour_bucket(rows):
    """Group trades by UTC hour of the close, so hour-of-day patterns surface."""
    out = defaultdict(list)
    for r in rows:
        ts = txt(r, "close_time", "")
        hh = ts[11:13].replace("/", "") if len(ts) >= 13 else "?"
        out[hh if hh.isdigit() else "?"].append(r)
    return {k: summarize(v) for k, v in sorted(out.items())}


def tuning_suggestions(overall, by_sig, by_session, by_hour, funnel, rej, spread, mfee, by_dir=None):
    """Rule-based tuning notes. Each one names the exact input to change and the
    evidence from THIS dataset. Hypotheses to test, not truth."""
    out = []
    n = overall["n"]
    if n == 0:
        out.append(("NO DATA", "No closed trades yet. Run the EA on demo; nothing can be concluded.", ""))
        return out

    if n < MIN_TRADES_FOR_STATS:
        out.append(("SMALL SAMPLE",
                    f"Only {n} trades. Every number below has wide error bars - collect "
                    f"{MIN_TRADES_FOR_STATS}+ before changing any parameter.", ""))

    if overall["profit_factor"] != float("inf") and overall["profit_factor"] < 1.0:
        out.append(("EDGE", f"Profit factor {overall['profit_factor']} is below 1.0. Do not raise risk; "
                    "read the per-signal table and disable the losing signal type first.",
                    "signal enable inputs"))
    if overall["win_rate"] < 30 and overall["avg_win_r"] >= 1.8:
        out.append(("EDGE", f"{overall['win_rate']}% win rate with {overall['avg_win_r']}R average win is a "
                    "viable asymmetric profile. Judge on expectancy, not on streaks.", ""))

    if rej.get("spread_or_guard", 0) > max(5, n):
        out.append(("SPREAD", f"{rej['spread_or_guard']} setups were rejected by spread/guard while only {n} "
                    "trades were taken. The strategy is being priced out, not filtered out. Trade only the "
                    "two hours either side of the London/NY open where gold spreads tighten.",
                    "MaxSpreadDollars, session window"))
    if spread and spread.get("spread_pct_of_stop", 0) > 15:
        out.append(("SPREAD", f"Spread is {spread['spread_pct_of_stop']}% of the average stop "
                    f"({spread['spread_cost_r']}R handed over at entry). Above ~10% the edge must come from "
                    "a wider stop. Require more zone height before entry.",
                    "BreakerMinAtr, FvgMinAtr, StopBufferDollars"))

    if n >= 10 and spread:
        stop = spread.get("avg_stop_pts", 0)
        mae_loss = abs(overall["avg_mae_pts"])
        mae_win = abs(overall["avg_mae_pts_winners"])
        # Losers' MAE is ~the stop by construction (they were stopped out), so
        # the informative numbers are how much heat the WINNERS take, and how
        # well winners and losers separate on adverse excursion.
        if stop > 0 and mae_win > 0:
            heat = mae_win / stop * 100.0
            if heat > 60:
                out.append(("ENTRY", f"Winners routinely draw down {heat:.0f}% of the stop "
                            f"({mae_win:.0f} of {stop:.0f} pts) before working. On a slightly worse day "
                            "those same trades are losses - the entry is too late inside the zone.",
                            "EntryZonePct, TriggerLookbackBars, StopBufferDollars"))
            elif heat < 10:
                out.append(("ENTRY", f"Even the winners barely go against you ({heat:.0f}% of stop). "
                            "There is room to enter deeper for a better R:R instead of earlier.",
                            "EntryZonePct"))
        if mae_win > 0 and mae_loss > 0 and mae_loss / mae_win < 1.6:
            out.append(("ENTRY", f"Winners drew down {mae_win:.0f} pts on average, losers {mae_loss:.0f} "
                        "- barely different. When a zone genuinely holds, the losers separate from the "
                        "winners. This says entries are near-random at the moment of execution.",
                        "TriggerLookbackBars, RequireConfluence"))

    if mfee.get("gave_back_pct", 0) > 30:
        out.append(("EXIT", f"{mfee['gave_back_pct']}% of trades reached +1R and closed at <= +0.25R. "
                    "The exits surrender winners. Loosen the breakeven trigger before touching entries.",
                    "BreakEvenTriggerRR, TrailStartRR, Tp1RR/Tp1Percent"))
    eff = mfee.get("avg_efficiency")
    if eff is not None and 0 < eff < 0.35:
        out.append(("EXIT", f"Only {eff} of the average excursion is banked - money is left on the table "
                    "on every winner.", "Tp2RR, TrailStartRR"))

    for name, st in by_sig.items():
        if st["n"] >= 8 and st["expectancy_r"] < -0.15:
            out.append(("SIGNAL", f"{name}: {st['n']} trades at {st['expectancy_r']}R expectancy, "
                        f"win rate {st['win_rate']}%, PF {st['profit_factor']}.",
                        "disable this signal type for the next test window"))
    # The H1 trend filter decides direction, so a one-sided loss pattern is a
    # filter problem, not bad luck.
    for name, st in (by_dir or {}).items():
        if st["n"] >= 8 and st["expectancy_r"] < -0.15:
            other = "BUY" if name.upper() == "SELL" else "SELL"
            out.append(("DIRECTION", f"{name} trades: {st['n']} at {st['expectancy_r']}R expectancy "
                        f"(win rate {st['win_rate']}%). The H1 trend filter is letting through one bad "
                        f"side while {other} works.",
                        "TrendEmaPeriods, structure-lookback inputs, or trade only the profitable side"))
    for name, st in by_session.items():
        if st["n"] >= 8 and st["expectancy_r"] < -0.2:
            out.append(("SESSION", f"{name} session: {st['n']} trades at {st['expectancy_r']}R expectancy.",
                        "narrow StartTradingHourUTC/EndTradingHourUTC to exclude it"))
    for name, st in list(by_hour.items()):
        if st["n"] >= 6 and st["expectancy_r"] < -0.25:
            out.append(("HOUR", f"{name}:00 UTC: {st['n']} trades at {st['expectancy_r']}R expectancy.",
                        "exclude this hour"))

    deaths = funnel.get("death_causes", {})
    total_deaths = sum(deaths.values())
    if total_deaths > 10:
        for cause, cnt in deaths.items():
            share = cnt / total_deaths
            if share > 0.7 and cause not in ("CLOSED", "AGE", "MAXAGE", "TRADED", "MITIGATED"):
                out.append(("ZONES", f"{100.0 * share:.0f}% of zones die as '{cause}'. The detectors are "
                            "producing zones that never get a chance.",
                            "MaxZoneAgeBars, MitigatePct"))

    created = funnel.get("created_by_type", {})
    total_c = sum(created.values())
    if total_c > 20:
        for zt, cnt in created.items():
            if cnt / total_c > 0.8:
                out.append(("ZONES", f"{100.0 * cnt / total_c:.0f}% of all zones are {zt}; the other "
                            "detectors contribute almost nothing. Tighten its minimum height or disable it "
                            "to simplify the dataset.", f"{zt} *Atr inputs"))

    if overall["max_dd_r"] > 6 and overall["total_r"] <= 0:
        out.append(("RISK", f"Drawdown of {overall['max_dd_r']}R against {overall['total_r']}R total gain. "
                    "The account is asked to survive more variance than the edge pays for.",
                    "RiskPercentPerTrade, MaxOpenTrades"))
    if overall["streak_loss"] >= 6:
        out.append(("PSYCHOLOGY", f"Longest losing streak: {overall['streak_loss']}. Over {overall['n']} "
                    "trades that is inside normal variance - do not intervene mid-streak.", ""))
    if not out:
        out.append(("OK", "No rule fired. The dataset looks internally consistent with the configured "
                    "risk. Keep collecting.", ""))
    return out


# ---------------------------------------------------------------- assembly

def build_report(log_dir):
    trades = read_csv(log_dir, TRADES)
    signals = read_csv(log_dir, SIGNALS)
    rejs = read_csv(log_dir, REJECTIONS)
    zones = read_csv(log_dir, ZONES)
    eq = read_csv(log_dir, EQUITY)

    taken = [r for r in signals if txt(r, "mode").upper() in ("MARKET", "PENDING")]
    dry = [r for r in signals if txt(r, "mode").upper() not in ("MARKET", "PENDING")]

    # Phantom rows (a deleted limit written up as a 0.00R trade) are excluded
    # from every statistic below: they are not trades, and leaving them in the
    # denominator understates expectancy and win rate. The count is kept in the
    # report so a log full of them is visible rather than silently smoothed.
    phantom = phantom_rows(trades)
    if phantom["count"]:
        trades = [r for r in trades if not is_phantom(r)]

    overall = summarize(trades)
    by_sig = group_stats(trades, "signal_type")
    by_sess = group_stats(trades, "session")
    by_dir = group_stats(trades, "type")
    by_confl = group_stats(trades, "confluence")
    by_exit = group_stats(trades, "exit_reason")
    by_hour = hour_bucket(trades)
    spread = spread_cost_check(trades)
    mfee = mfe_efficiency(trades)
    funnel = zone_funnel(zones, signals)
    rej = rejection_breakdown(rejs)
    eqd = max_drawdown_pct(eq)
    notify = notify_stats(read_csv(log_dir, NOTIFY))
    sugg = tuning_suggestions(overall, by_sig, by_sess, by_hour, funnel, rej, spread, mfee, by_dir)

    days = sorted({txt(r, "close_time", "")[:10] for r in trades if len(txt(r, "close_time", "")) >= 10})
    return {
        "log_dir": log_dir,
        "generated": now_stamp(),
        "files": {name: len(read_csv(log_dir, name)) for name in
                  (TRADES, SIGNALS, REJECTIONS, ZONES, EQUITY, DAILY, PARTIALS, NOTIFY)},
        "phantom_rows": phantom,
        "overall": overall,
        "by_signal_type": by_sig,
        "by_session": by_sess,
        "by_direction": by_dir,
        "by_confluence": by_confl,
        "by_exit_reason": by_exit,
        "by_hour_utc": by_hour,
        "spread": spread,
        "mfe_efficiency": mfee,
        "zone_funnel": funnel,
        "rejections": rej,
        "notify": notify,
        "equity": eqd,
        "signals": {"total": len(signals), "taken": len(taken), "shadow": len(dry),
                    "by_mode": dict(Counter(txt(r, "mode").upper() for r in signals))},
        "days_with_trades": len(days),
        "first_trade": days[0] if days else None,
        "last_trade": days[-1] if days else None,
        "suggestions": sugg,
    }


def now_stamp():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def go_no_go(rep):
    """A blunt verdict on the 30-day demo test. Rules live in DEMO-PLAN.md."""
    o = rep["overall"]
    fails, warns = [], []
    if o["n"] < 20:
        warns.append(f"only {o['n']} closed trades (need 20+ for a verdict)")
    if o["n"] >= 20:
        if o["expectancy_r"] <= 0:
            fails.append(f"expectancy {o['expectancy_r']}R is not positive")
        if o["profit_factor"] != float("inf") and o["profit_factor"] < 1.15:
            fails.append(f"profit factor {o['profit_factor']} below 1.15")
        if rep["equity"].get("max_dd_pct", 0) >= 12:
            fails.append(f"equity drawdown {rep['equity']['max_dd_pct']}% >= 12%")
        if o["max_dd_r"] >= 10:
            fails.append(f"{o['max_dd_r']}R drawdown in R units")
        if rep["spread"].get("spread_cost_r", 0) > 0.12:
            warns.append(f"spread costs {rep['spread']['spread_cost_r']}R per trade")
    ph = rep.get("phantom_rows") or {}
    if ph.get("count"):
        warns.append(
            f"{ph['count']} row(s) ({ph['pct']}%) excluded as phantom: closed-trade "
            f"lines with no position behind them, written by EA builds before the "
            f"cancelled-limit fix. Stats here ignore them; any report generated from "
            f"this log before now counted them as 0.00R trades.")
    nt = rep.get("notify")
    if nt and nt["failed"]:
        lf = nt["last_fail"]
        detail = f" last: {lf[1]} {lf[2]}" if lf else ""
        warns.append(
            f"notifications: {nt['failed']} send(s) failed ({nt['fail_pct']}% of "
            f"{nt['total']}). Usually the URL is not whitelisted in Tools > Options > "
            f"Expert Advisors.{detail}")
    verdict = "FAIL" if fails else ("INCONCLUSIVE" if warns else "PASS")
    return verdict, fails, warns


# ---------------------------------------------------------------- rendering

def table(rows, headers, keys, floatfmt=None):
    """Fixed-width text table. First column is left-aligned, the rest right."""
    floatfmt = floatfmt or {}

    def cell(row, key):
        return _fmt(row.get(key), floatfmt.get(key))

    grid = [[headers[j] if j < len(headers) else key for j, key in enumerate(keys)]]
    for r in rows:
        grid.append([cell(r, k) for k in keys])
    if len(grid) == 1:
        return "   (no rows)"
    widths = [max(len(row[c]) for row in grid) for c in range(len(keys))]
    lines = []
    for row in grid:
        parts = [row[0].ljust(widths[0])] + [row[c].rjust(widths[c]) for c in range(1, len(keys))]
        lines.append("  ".join(parts).rstrip())
    lines.insert(1, "  ".join("-" * wd for wd in widths).rstrip())
    return "\n".join("   " + ln for ln in lines)


def _fmt(v, spec=None):
    if isinstance(v, float):
        return f"{v:{spec}}" if spec else f"{v:g}"
    if v is None:
        return "-"
    return str(v)


def stat_line(label, value):
    return f"   {label:<26}{value}"


def render(rep):
    o = rep["overall"]
    v, fails, warns = go_no_go(rep)
    out = []
    w = out.append
    w("=" * 78)
    w("HEX-FVG-BREAKER - DEMO REPORT")
    w(f"generated {rep['generated']}   logs: {rep['log_dir']}")
    w("=" * 78)
    w("")
    w(f"VERDICT: {v}")
    for f in fails:
        w(f"   FAIL  {f}")
    for x in warns:
        w(f"   warn  {x}")
    w("")
    span = f"{rep['first_trade']} .. {rep['last_trade']}" if rep["first_trade"] else "no trades"
    w(f"period   : {span}  ({rep['days_with_trades']} trading days)")
    w(f"rows     : " + ", ".join(f"{k}={v}" for k, v in rep["files"].items()))
    w("")
    w("--- OVERALL (closed trades, R-based) " + "-" * 34)
    w(stat_line("closed trades", o["n"]))
    ph = rep.get("phantom_rows") or {}
    if ph.get("count"):
        w(stat_line("  (phantom rows)", f"{ph['count']} excluded, {ph['pct']}% of the log "
                                        f"- never filled, see go/no-go notes"))
    w(stat_line("net R / expectancy", f"{o['total_r']} R   /   {o['expectancy_r']} R per trade"))
    pf = o["profit_factor"]
    w(stat_line("win rate / PF", f"{o['win_rate']}%   /   " + ("inf" if pf == float("inf") else str(pf))))
    w(stat_line("avg win / avg loss", f"{o['avg_win_r']} R  /  {o['avg_loss_r']} R"))
    w(stat_line("best / worst", f"{o['best_r']} R  /  {o['worst_r']} R"))
    w(stat_line("max drawdown", f"{o['max_dd_r']} R (equity: {rep['equity'].get('max_dd_pct', 0)}%)"))
    w(stat_line("streaks (win/loss)", f"{o['streak_win']} / {o['streak_loss']}"))
    w(stat_line("net P&L", f"{o['pnl_net']} USD"))
    w(stat_line("avg hold", f"{o['avg_hold_bars']} bars"))
    w(stat_line("breakeven exits", f"{o['be_rate']}% of trades"))
    w(stat_line("MAE losers / winners", f"{o['avg_mae_pts']} / {o['avg_mae_pts_winners']} pts "
                                        f"(negative = adverse)"))
    w(stat_line("avg MFE", f"{o['avg_mfe_pts']} pts ({o['avg_mfe_r']} R)"))
    if rep["spread"]:
        s = rep["spread"]
        w(stat_line("spread at entry", f"{s['avg_spread_pts']} pts avg ({s['worst_spread_pts']} worst)"))
        w(stat_line("spread vs stop", f"{s['spread_pct_of_stop']}% of stop = {s['spread_cost_r']} R cost"))
    m = rep["mfe_efficiency"]
    if m.get("trades_with_mfe"):
        w(stat_line("MFE capture", f"{m['avg_efficiency']} avg efficiency "
                                   f"(median {m['median_efficiency']})"))
        w(stat_line("gave back >=1R", f"{m['gave_back_1R']} trades ({m['gave_back_pct']}%)"))
    w("")
    sig = rep["signals"]
    w("--- SIGNAL FLOW " + "-" * 59)
    w(f"   logged {sig['total']}   taken {sig['taken']}   shadow/blocked {sig['shadow']}   "
      f"by mode: {sig['by_mode']}")
    rej = rep["rejections"]
    w(f"   rejections: {rej['total']} total")
    for reason, cnt in list(rej["by_reason"].items())[:12]:
        w(f"      {cnt:>6}  {reason}")
    nt = rep.get("notify")
    if nt:
        w("")
        w("--- NOTIFICATIONS " + "-" * 59)
        w(f"   {nt['ok']} sent ok   {nt['failed']} failed   {nt['dropped']} dropped (throttle/dedupe)   "
          f"{nt['testmode']} tester-only")
        w(f"   by tag: " + ", ".join(f"{k}={v}" for k, v in sorted(nt["by_tag"].items())))
        if nt["failed"]:
            lf = nt["last_fail"]
            w(f"   last failure: {lf[0]}  [{lf[1]}]  {lf[2]}")
        if nt["drop_reasons"]:
            w("   drop reasons:")
            for reason, cnt in sorted(nt["drop_reasons"].items(), key=lambda kv: -kv[1])[:8]:
                w(f"      {cnt:>6}  {reason}")
    fn = rep["zone_funnel"]
    w("")
    w("--- ZONE FUNNEL " + "-" * 61)
    w(f"   created by detector: {fn['created_by_type']}")
    w(f"   events: {fn['events']}")
    w(f"   traded zones: {fn['zones_traded']}")
    w("   death causes:")
    for cause, cnt in sorted(fn["death_causes"].items(), key=lambda kv: -kv[1])[:12]:
        w(f"      {cnt:>6}  {cause}")
    w("")

    def slice_table(title, dct, label):
        w(f"--- {title} " + "-" * max(3, 72 - len(title)))
        rows = [dict(k=k, **s) for k, s in dct.items() if s["n"] > 0]
        rows.sort(key=lambda r: -r["total_r"])
        w(table(rows, [label, "n", "win%", "PF", "avgR", "netR", "avgW", "avgL", "DD"],
                ["k", "n", "win_rate", "profit_factor", "avg_r", "total_r",
                 "avg_win_r", "avg_loss_r", "max_dd_r"],
                {"win_rate": ".1f", "profit_factor": ".2f", "avg_r": ".2f", "total_r": ".2f",
                 "avg_win_r": ".2f", "avg_loss_r": ".2f", "max_dd_r": ".2f"}))
        w("")

    slice_table("BY SIGNAL TYPE", rep["by_signal_type"], "signal")
    slice_table("BY SESSION", rep["by_session"], "session")
    slice_table("BY DIRECTION", rep["by_direction"], "dir")
    slice_table("BY CONFLUENCE", rep["by_confluence"], "confl")
    slice_table("BY EXIT REASON", rep["by_exit_reason"], "exit")
    slice_table("BY HOUR (UTC)", rep["by_hour_utc"], "hour")

    w("--- TUNING SUGGESTIONS " + "-" * 54)
    for tag, msg, knob in rep["suggestions"]:
        w(f"   [{tag}]")
        for i, line in enumerate(wrap(msg, 72)):
            w(f"      {line}")
        if knob:
            w(f"      -> {knob}")
    w("")
    w("   Read DEMO-PLAN.md before changing anything. Change ONE knob per test window.")
    return "\n".join(out)


def wrap(text, width):
    words, lines, cur = text.split(), [], ""
    for wd in words:
        if len(cur) + len(wd) + 1 > width and cur:
            lines.append(cur)
            cur = wd
        else:
            cur = f"{cur} {wd}".strip()
    if cur:
        lines.append(cur)
    return lines


def json_safe(obj):
    """Infinity has no JSON spelling; collapse it to a readable string."""
    if isinstance(obj, dict):
        return {k: json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [json_safe(v) for v in obj]
    if isinstance(obj, float) and (obj == float("inf") or obj == float("-inf")):
        return "inf" if obj > 0 else "-inf"
    return obj


# ---------------------------------------------------------------- selftest

def write(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        fh.write(header + "\r\n")
        for r in rows:
            fh.write(",".join(r) + "\r\n")


def selftest(tmp):
    """Synthetic logs that exercise every code path: winners, losers, breakeven,
    a dry-run signal, zone deaths, rejections, equity curve."""
    trades_hdr = ("ticket,login,symbol,tf,type,signal_type,confluence,open_time,close_time,entry,sl,"
                  "tp,exit_price,lots,stop_pts,spread_pts_at_entry,pnl_net,r_multiple,risk_usd,mae_pts,"
                  "mfe_pts,mfe_r,hold_bars,session,exit_reason,balance_after,atr_at_entry")
    rows = []
    # 13 trades: 5 winning buys, 8 losing sells. Deliberately lopsided so the
    # directional rule fires and can be verified.
    # mae is recorded by the EA as a NEGATIVE excursion in points: losers
    # (stopped on a 500 pt stop) bottom near -500, winners give back 70-150.
    plan = [(2.1, "TP2", "BREAKER", 1, "LONDON", "BUY", -90, 1100),
            (1.9, "TP2", "FVG", 2, "NEWYORK", "BUY", -140, 980),
            (2.4, "TP2", "BREAKER", 2, "LONDON", "BUY", -70, 1250),
            (1.2, "BE_OR_TRAIL", "BREAKER", 2, "LONDON", "BUY", -120, 640),
            (3.1, "TP2", "BREAKER", 2, "NEWYORK", "BUY", -150, 1600),
            (-1.0, "STOP_LOSS", "FVG", 1, "ASIA", "SELL", -505, 40),
            (-1.0, "STOP_LOSS", "FVG", 1, "ASIA", "SELL", -502, 25),
            (-1.0, "STOP_LOSS", "BREAKER", 0, "LATE", "SELL", -510, 60),
            (-1.0, "STOP_LOSS", "MITIGATION", 1, "NEWYORK", "SELL", -508, 320),
            (-1.0, "STOP_LOSS", "BREAKER", 1, "LONDON", "SELL", -508, 15),
            (-1.0, "STOP_LOSS", "FVG", 1, "ASIA", "SELL", -500, 35),
            (-1.0, "STOP_LOSS", "MITIGATION", 0, "POST_NY", "SELL", -515, 20),
            (-1.0, "STOP_LOSS", "BREAKER", 1, "LONDON", "SELL", -512, 45)]
    for i, (r, why, sig, confl, sess, dirn, mae, mfe_pts) in enumerate(plan, start=1):
        day = f"2026.09.{(i % 28) + 1:02d}"
        rows.append([str(1000 + i), "555", "XAUUSD", "15", dirn, sig, str(confl),
                     f"{day} 08:15:00", f"{day} 11:45:00", "2650.10", "2645.10", "2662.60", "2655.00",
                     "0.01", "500", "35", f"{r * 5.0:.2f}", f"{r:.2f}", "5.00", str(mae),
                     str(mfe_pts), f"{mfe_pts / 500.0:.2f}", str(max(1, abs(mae) // 100)), sess, why,
                     "100.00", "4.20"])
    write(os.path.join(tmp, TRADES), trades_hdr, rows)

    write(os.path.join(tmp, SIGNALS),
          "time,bar_time,mode,dir,signal_label,confluence,entry,sl,tp,stop_pts,rr_planned,lots,risk_usd,"
          "spread_pts,atr,session,equity,trend,note",
          [["2026.09.01 08:15:00", "2026.09.01 08:15", "MARKET", "BUY", "BREAKER", "2",
            "2650.10", "2645.10", "2662.60", "500", "2.50", "0.01", "5.00", "35", "4.20", "LONDON",
            "100.00", "BUY", "ok"],
           ["2026.09.02 03:15:00", "2026.09.02 03:15", "DRY", "SELL", "FVG", "1",
            "2660.10", "2665.10", "2647.60", "500", "2.50", "0.01", "5.00", "35", "4.20", "ASIA",
            "100.00", "SELL", "dry run"]])

    write(os.path.join(tmp, REJECTIONS),
          "time,bar_time,reason,dir,zone_type,zone_top,zone_bottom,spread_pts,atr,dist_pts,equity,trend,detail",
          [["2026.09.01 02:00:00", "2026.09.01 02:00", "GUARD", "BUY", "FVG", "2650", "2648", "95",
            "4.20", "120", "100.00", "BUY", "spread too wide"],
           ["2026.09.01 02:15:00", "2026.09.01 02:15", "NO_CONFLUENCE", "SELL", "FVG", "2650", "2648",
            "40", "4.20", "90", "100.00", "SELL", "FVG alone"],
           ["2026.09.01 02:30:00", "2026.09.01 02:30", "GUARD", "BUY", "BREAKER", "2650", "2648", "88",
            "4.20", "70", "100.00", "BUY", "spread too wide"]])

    zone_hdr = "time,event,zone_type,dir,t1,t2,top,bottom,height,max_penet_pct,touches,note"
    zrows = []
    for i in range(30):
        zt = "FVG" if i % 4 else "BREAKER"
        zrows.append([f"2026.09.01 0{i % 9}:00:00", "OPEN", zt, "BUY", "2026.09.01 08:00",
                      "2026.09.01 09:00", "2650.00", "2648.00", "2.00", "0.0", "0", "created"])
    for i in range(22):
        zrows.append([f"2026.09.01 0{i % 9}:45:00", "CLOSE", "FVG", "BUY", "2026.09.01 08:00",
                      "2026.09.01 09:45", "2650.00", "2648.00", "2.00", "30.0", "1", "closed through"])
    for i in range(6):
        zrows.append([f"2026.09.01 0{i % 9}:50:00", "CLOSE", "BREAKER", "SELL", "2026.09.01 08:00",
                      "2026.09.01 09:50", "2652.00", "2650.00", "2.00", "10.0", "1", "age limit"])
    zrows.append(["2026.09.01 08:20:00", "TOUCH", "BREAKER", "BUY", "2026.09.01 08:00",
                  "2026.09.01 08:20", "2650.00", "2648.00", "2.00", "10.0", "1", "first touch"])
    zrows.append(["2026.09.01 08:25:00", "TRADED", "BREAKER", "BUY", "2026.09.01 08:00",
                  "2026.09.01 08:25", "2650.00", "2648.00", "2.00", "12.0", "1", "BREAKER"])
    write(os.path.join(tmp, ZONES), zone_hdr, zrows)

    eq_rows = []
    for i, eq in enumerate([100.0, 99.1, 98.0, 101.2, 100.4, 103.9, 103.1, 106.4]):
        eq_rows.append([f"2026.09.{i + 1:02d} 12:00:00", "0", f"{eq - 0.5:.2f}", f"{eq:.2f}",
                        "0", "0.00", f"{eq * 0.9:.2f}", "0.0"])
    write(os.path.join(tmp, EQUITY),
          "time,server_time,balance,equity,open_positions,floating_pnl,free_margin,dd_from_peak_pct",
          eq_rows)

    # notify.csv: what the EA logged about its own push messages. Mix of every
    # status so the parser, the go/no-go warning and the render are exercised.
    # Fields never contain commas (PushCsvSafe strips them), matching the EA.
    write(os.path.join(tmp, NOTIFY),
          "time,tag,status,detail,title,message",
          [["2026.09.01 08:00:00", "INIT", "OK", "-", "HEX FVG", "started"],
           ["2026.09.01 08:15:00", "PENDING", "OK", "200", "HEX FVG", "LIMIT PLACED BUY"],
           ["2026.09.01 08:20:00", "FILL", "OK", "200", "HEX FVG", "FILLED BUY"],
           ["2026.09.01 08:21:00", "TP1", "DROPPED", "duplicate inside 2m", "HEX FVG", "TP1 banked"],
           ["2026.09.01 09:00:00", "CLOSE", "OK", "200", "HEX FVG", "CLOSED BUY TP2"],
           ["2026.09.01 09:05:00", "KILL", "FAIL", "403 forbidden", "HEX FVG", "KILL SWITCH"],
           ["2026.09.01 09:10:00", "PENDING", "FAIL", "webrequest err 4060 not allowed",
            "HEX FVG", "LIMIT PLACED SELL"],
           ["2026.09.01 09:15:00", "ENTRY", "TESTMODE", "-", "HEX FVG", "ENTERED BUY"]])
    return rows


def _path_checks():
    """Where the EA writes and where this tool looks must be the same place.

    Regression cover: the candidate list used to omit the Files/ segment that
    MQL4's FileOpen resolves relative paths against, so only the slow `find`
    fallback could ever locate a real log folder. The fallback is disabled here
    on purpose, otherwise it papers over a wrong candidate list.
    """
    import shutil
    import tempfile

    files_suffix = os.path.join("MQL4", "Files", "Common", "HEX-Logs")
    cds = candidate_dirs()
    out = [
        ("log suffix is Files-relative", files_suffix in LOG_SUFFIXES),
        ("candidates cover the Files layout",
         any(d.endswith(files_suffix) for d in cds)),
        ("candidates contain no duplicates", len(cds) == len(set(cds))),
    ]

    fakehome = tempfile.mkdtemp(prefix="hex_home_")
    leaf = os.path.join(fakehome, "Library/Application Support",
                        "net.metaquotes.wine.metatrader4", "drive_c",
                        "Program Files", "MetaTrader 4",
                        *files_suffix.split(os.sep))
    old_run, old_home = subprocess.run, os.environ.get("HOME")
    try:
        os.makedirs(leaf)
        with open(os.path.join(leaf, "notify.csv"), "w"):
            pass
        os.environ["HOME"] = fakehome

        def no_find(*a, **kw):
            raise FileNotFoundError("find fallback disabled for this check")

        subprocess.run = no_find
        out.append(("locate_logs resolves the macOS wrapper layout",
                    locate_logs(verbose=False) == leaf))
    finally:
        subprocess.run = old_run
        if old_home is not None:
            os.environ["HOME"] = old_home
        shutil.rmtree(fakehome, ignore_errors=True)
    return out


def run_selftest():
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="hex_selftest_")
    try:
        selftest(tmp)
        rep = build_report(tmp)
        o = rep["overall"]
        checks = [
            ("trade rows parsed", o["n"] == 13),
            ("total R correct", abs(o["total_r"] - 2.7) < 0.01),
            ("win rate", abs(o["win_rate"] - 38.5) < 0.1),
            ("losses average to -1R", abs(o["avg_loss_r"] + 1.0) < 0.01),
            ("profit factor ~1.34", abs(o["profit_factor"] - 1.34) < 0.02),
            ("max dd positive", o["max_dd_r"] > 0),
            ("losing streak 8", o["streak_loss"] == 8),
            ("winner MAE separated from loser MAE",
             abs(o["avg_mae_pts"]) / abs(o["avg_mae_pts_winners"]) > 1.6),
            ("signal slices present", "BREAKER" in rep["by_signal_type"]),
            ("session slices present", "ASIA" in rep["by_session"]),
            ("hour slices present", len(rep["by_hour_utc"]) >= 1),
            ("zone deaths counted", sum(rep["zone_funnel"]["death_causes"].values()) == 28),
            ("rejections counted", rep["rejections"]["total"] == 3),
            ("shadow signal counted", rep["signals"]["shadow"] == 1),
            ("equity dd computed", rep["equity"]["max_dd_pct"] > 0),
            ("notify parsed", rep["notify"] is not None and rep["notify"]["total"] == 8),
            ("notify status counts", rep["notify"]["ok"] == 4 and rep["notify"]["failed"] == 2
             and rep["notify"]["dropped"] == 1 and rep["notify"]["testmode"] == 1),
            ("notify last fail captured", rep["notify"]["last_fail"][1] == "PENDING"),
            ("notify failure raises a warning",
             any("notification" in x.lower() for x in go_no_go(rep)[2])),
            ("suggestions produced", len(rep["suggestions"]) >= 1),
            ("directional rule fired",
             any(t == "DIRECTION" for t, _, _ in rep["suggestions"])),
            ("verdict computed", go_no_go(rep)[0] in ("PASS", "FAIL", "INCONCLUSIVE")),
            ("json serialisable", json.dumps(json_safe(rep)) is not None),
        ]
        text = render(rep)
        checks.append(("renders without error", len(text) > 800))
        checks.append(("slice table rendered", "BREAKER" in text and "win%" in text))
        checks.append(("spread cost computed", rep["spread"]["spread_cost_r"] > 0))
        checks.append(("mfe efficiency computed", rep["mfe_efficiency"]["trades_with_mfe"] > 0))
        checks.extend(_path_checks())
        print(text)
        print("=" * 78)
        bad = [name for name, ok in checks if not ok]
        for name, ok in checks:
            print(f"   {'PASS' if ok else 'FAIL'}  {name}")
        if bad:
            print(f"\nSELFTEST FAILED: {bad}")
            return 1
        print(f"\nSELFTEST PASSED ({len(checks)} checks)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description="Report on HEX-FVG-Breaker demo logs.")
    ap.add_argument("--dir", help="folder containing the EA's CSV logs (default: auto-detect)")
    ap.add_argument("--out", help="also write the report to this file")
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    ap.add_argument("--selftest", action="store_true", help="run against synthetic logs and exit")
    args = ap.parse_args(argv)

    if args.selftest:
        return run_selftest()

    log_dir = locate_logs(args.dir)
    if not log_dir:
        print("Could not find a HEX-Logs folder. Point --dir at it, or run the EA once with\n"
              "WriteCsvLogs=true (see the top of this file for typical locations).\n"
              "Try --selftest to see what a filled-out report looks like.")
        return 2

    rep = build_report(log_dir)
    text = json.dumps(json_safe(rep), indent=2) if args.json else render(rep)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"\n[hex_report] wrote {args.out}", file=sys.stderr)
    return 0 if go_no_go(rep)[0] != "FAIL" else 1


if __name__ == "__main__":
    sys.exit(main())

