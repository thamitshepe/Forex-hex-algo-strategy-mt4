#!/usr/bin/env python3
"""
Generate MT4 .set presets from the extern block of HEX-FVG-Breaker.mq4.

Hand-writing .set files is how you end up with a preset that silently drops a
parameter, so every preset is derived from the EA's own defaults and then
patched with the values that preset is about.

    python3 Tools/make_presets.py            # write presets to MQL4/Presets/
    python3 Tools/make_presets.py --check    # verify presets still cover real inputs

MT4 .set notes: booleans are 1/0, enums are their integer value, colors are
BGR integers (value = R + G*256 + B*65536), strings are written bare.
"""
import os
import re
import sys

EA = os.path.join("MQL4", "Experts", "HEX-FVG-Breaker.mq4")
OUT = os.path.join("MQL4", "Presets")

# CSS/X11 triples for the color inputs, converted to MT4's BGR integer form.
COLORS = {
    "clrDodgerBlue": (30, 144, 255),
    "clrTomato": (255, 99, 71),
    "clrMediumOrchid": (186, 85, 211),
    "clrDarkGoldenrod": (184, 134, 11),
    "clrRed": (255, 0, 0),
    "clrGreen": (0, 255, 0),
    "clrBlue": (0, 0, 255),
    "clrGold": (255, 215, 0),
    "clrGray": (128, 128, 128),
    "clrSilver": (192, 192, 192),
    "clrWhite": (255, 255, 255),
    "clrBlack": (0, 0, 0),
    "clrYellow": (255, 255, 0),
}

ENUMS = {
    "ENUM_TREND_MODE": {"TREND_EMA": 0, "TREND_STRUCTURE": 1, "TREND_BOTH": 2},
    "ENUM_EXIT_MODE": {"EXIT_FIXED_RR": 0, "EXIT_ZONE_RR": 1, "EXIT_TRAIL_ONLY": 2},
    "ENUM_ENTRY_MODEL": {"ENTRY_LIMIT": 0, "ENTRY_TRIGGER": 1},
    "ENUM_NOTIFY_FORMAT": {"NOTIFY_FORM": 0, "NOTIFY_PLAIN": 1, "NOTIFY_JSON": 2,
                           "NOTIFY_GET": 3},
}

EXTERN_RE = re.compile(r'^extern\s+(?P<type>\w+)\s+(?P<name>\w+)\s*=\s*(?P<val>.*?);', re.M)


def parse_inputs(path):
    """Return [(type, name, value_literal)] in declaration order."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    out = []
    for m in EXTERN_RE.finditer(src):
        val = re.sub(r'//.*$', '', m.group("val").strip()).strip()
        out.append((m.group("type"), m.group("name"), val))
    return out


def encode(mql_type, value):
    """Turn an MQL4 literal into what MT4 writes into a .set file."""
    value = value.strip()
    if mql_type == "bool":
        return "1" if value.lower().startswith("true") else "0"
    if value.startswith("clr"):
        if value in COLORS:
            r, g, b = COLORS[value]
            return str(r + g * 256 + b * 65536)
        return value
    if re.fullmatch(r'[A-Z_][A-Z0-9_]*', value):        # bare enum constant
        for table in ENUMS.values():
            if value in table:
                return str(table[value])
    if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
        return value[1:-1]                              # MT4 stores strings bare
    return value


def same_value(a, b):
    """Compare two .set literals as MT4 would read them (0.0 and 0 are equal)."""
    if a == b:
        return True
    try:
        return abs(float(a) - float(b)) < 1e-9
    except (TypeError, ValueError):
        return False


def is_section_header(mql_type, name):
    """The EA groups inputs with string inputs named S0_Gen, S1_Exec, ..."""
    return mql_type == "string" and re.fullmatch(r'S\d+_\w+', name) is not None


def preset(inputs, name, title, notes, overrides):
    """Full-input .set text: every parameter, defaults patched by `overrides`.

    MT4's .set reader is unforgiving about trailing content on a value line, so
    the header is pure comments and the body is strictly name=value."""
    seen = {n for _, n, _ in inputs}
    unknown = sorted(k for k in overrides if k not in seen)
    if unknown:
        raise SystemExit(f"{name}: override names not found in the EA: {unknown}")

    lines = [";+" + "-" * 66, f";| {title}", ";+" + "-" * 66]
    lines += ["; " + n if n else ";" for n in notes]
    lines.append(";")
    diffs = [(mt, pn, encode(mt, v), overrides[pn])
             for mt, pn, v in inputs
             if pn in overrides and not same_value(encode(mt, v), overrides[pn])]
    if diffs:
        lines.append("; differs from the EA default:")
        for mt, pn, old, new in diffs:
            lines.append(f";   {pn}: {old}  ->  {new}")
    lines.append(";" + "-" * 67)
    for mtype, pname, val in inputs:
        if is_section_header(mtype, pname):
            continue
        lines.append(f"{pname}={overrides.get(pname, encode(mtype, val))}")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------- presets
# (id, title, notes, overrides)

# The push topic belongs to the deployment, not to the strategy: every XAUUSD
# preset notifies the same chat. It used to be patched into the .set files by
# hand, which meant one regeneration silently dropped it and the phone went
# quiet - so it is applied in main() to every preset that does not name its own.
# A preset for a different instance (see doge-scalp) carries its own topic.
NOTIFY_XAU = "https://ntfy.sh/hex-xauusd-e7b863cd"

PRESETS = [
    ("100usd-demo",
     "HEX-FVG-Breaker - $100 live-size demo (START HERE)",
     ["Attach to XAUUSD M15. Recommended first preset: 0.01 lot, one position at",
      "a time, a $2 hard risk cap, and kill switches that stop the EA before a bad",
      "week can hurt.",
      "",
      "Why the numbers are what they are:",
      "On a standard account 0.01 lot of gold is about $1 per $1/oz of movement.",
      "A typical 2 $/oz stop therefore risks roughly $2 = 2% of a $100 account.",
      "MinFreeMarginUsd 40 is the real binding constraint at 1:100 leverage - the",
      "margin guard, not MaxLot, is what stops a second position opening.",
      "MaxSpreadDollars 0.45 keeps the EA out of the roll-over hours when gold",
      "spreads blow out and eat the entire edge.",
      "RiskPercent 0 means FixedLot wins. Set RiskPercent 1.0 to size by equity."],
     {"DryRun": "0", "FixedLot": "0.01", "MaxLot": "0.02", "RiskPercent": "0",
      "MaxRiskAmount": "2.0", "MaxOpenTrades": "1", "MaxSignalsPerDay": "6",
      "MaxSpreadDollars": "0.45", "MinFreeMarginUsd": "40", "MaxMarginUsagePct": "50",
      "MaxDailyLossPct": "5", "MaxTotalDrawdownPct": "15", "FlattenOnKill": "1"}),

    ("100usd-shadow",
     "HEX-FVG-Breaker - shadow mode (logs everything, trades nothing)",
     ["Run this to see what the EA would do without risking the demo balance.",
      "Every signal, zone and rejection still goes to the CSV logs, so after one",
      "or two weeks you can run Tools/hex_report.py and judge the logic before",
      "any money is exposed.",
      "",
      "DryRun=1 short-circuits SendEntry(): the setup is computed, drawn and",
      "logged, then discarded. Those signals appear with mode=DRY in signals.csv,",
      "which the report counts separately as shadow signals."],
     {"DryRun": "1", "FixedLot": "0.01", "MaxOpenTrades": "1", "MaxSignalsPerDay": "10",
      "MaxSpreadDollars": "0.45", "WriteCsvLogs": "1", "UseCommonFolder": "1"}),

    ("london-ny-window",
     "HEX-FVG-Breaker - tight session window (spread-first variant)",
     ["Same risk settings as 100usd-demo but only trades 07:00-20:00 server time,",
      "which brackets the London and New York sessions on a GMT+2/+3 broker.",
      "",
      "Why: on a $100 account the spread is the biggest opponent. Gold spreads are",
      "tightest during London/NY overlap and widen badly in the Asian session and",
      "at the roll-over. If the report says most of your setups are being rejected",
      "on spread, this is the preset to try.",
      "",
      "Set StartTradingHourUTC/StopTradingHourUTC to YOUR broker's server clock.",
      "Check Tools > Servers time in MT4, or read the server_time column that",
      "equity.csv writes, then adjust both numbers accordingly."],
     {"DryRun": "0", "FixedLot": "0.01", "MaxLot": "0.02", "RiskPercent": "0",
      "MaxRiskAmount": "2.0", "MaxOpenTrades": "1", "MaxSpreadDollars": "0.40",
      "MinFreeMarginUsd": "40", "MaxDailyLossPct": "5", "MaxTotalDrawdownPct": "15",
      "StartTradingHourUTC": "7", "StopTradingHourUTC": "20", "MaxSignalsPerDay": "4"}),

    ("cent-account",
     "HEX-FVG-Breaker - cent account (real money model, tiny stakes)",
     ["For a cent account funded with $100 (displayed as 10,000 US cents). There",
      "0.01 lot is roughly 1 cent per 0.01 move, so the same trade risks a couple",
      "of cents of displayed equity. This is the honest way to test the money model",
      "with real order execution.",
      "",
      "CHECK YOUR BROKER BEFORE TRUSTING THESE NUMBERS:",
      "1. Contract size - a cent-account XAUUSD lot is often 10x or 100x smaller",
      "   than a standard one. Verify what 0.01 lot actually costs you in cents.",
      "2. MaxRiskAmount is in ACCOUNT CURRENCY: on a cent account 300 = $3.00 real.",
      "3. MinFreeMarginUsd is also account currency, hence the larger number.",
      "If any of those three are wrong, fix them before funding anything."],
     {"DryRun": "0", "FixedLot": "0.01", "MaxLot": "1.0", "RiskPercent": "1.0",
      "MaxRiskAmount": "300", "MaxOpenTrades": "1", "MaxSignalsPerDay": "8",
      "MaxSpreadDollars": "0.45", "MinFreeMarginUsd": "500", "MaxMarginUsagePct": "60",
      "MaxDailyLossPct": "5", "MaxTotalDrawdownPct": "15", "FlattenOnKill": "1"}),

    ("structure-only",
     "HEX-FVG-Breaker - trend from structure only (A/B test)",
     ["Identical to 100usd-demo except for the trend filter. TrendMode=1",
      "(TREND_STRUCTURE) drops the EMA stack and reads direction from H1 market",
      "structure (HH/HL versus LH/LL) alone.",
      "",
      "Use it as a later test window in DEMO-PLAN.md: run 100usd-demo for a",
      "stretch, then this, and compare expectancy per trade in the report. One",
      "change at a time, or the comparison means nothing."],
     {"DryRun": "0", "FixedLot": "0.01", "MaxLot": "0.02", "RiskPercent": "0",
      "MaxRiskAmount": "2.0", "MaxOpenTrades": "1", "MaxSpreadDollars": "0.45",
      "MinFreeMarginUsd": "40", "MaxDailyLossPct": "5", "MaxTotalDrawdownPct": "15",
      "TrendMode": "1"}),

    ("trigger-entry",
     "HEX-FVG-Breaker - candle-trigger entry instead of limit (A/B test)",
     ["Same as 100usd-demo except EntryModel=1 (ENTRY_TRIGGER): enter at market on",
      "a rejection candle inside the zone instead of resting a limit order deep",
      "inside it.",
      "",
      "Trade-off to watch in the report: limit entries get a better price but many",
      "never fill (fewer trades, better R:R); trigger entries always fill at a",
      "worse price. Which wins on a $100 account is a data question, not an opinion",
      "question. Compare the taken-vs-shadow signal counts too."],
     {"DryRun": "0", "FixedLot": "0.01", "MaxLot": "0.02", "RiskPercent": "0",
      "MaxRiskAmount": "2.0", "MaxOpenTrades": "1", "MaxSpreadDollars": "0.45",
      "MinFreeMarginUsd": "40", "MaxDailyLossPct": "5", "MaxTotalDrawdownPct": "15",
      "EntryModel": "1", "AllowMarketEntry": "1"}),

    # The second instance: a different instrument on a different account. Every
    # *_Dollars input is a PRICE distance, so these are DOGE-sized, not gold-sized
    # - copying the gold preset here would ask for a stop six times the price of
    # the coin and nothing would ever trade.
    ("doge-scalp",
     "HEX-FVG-Breaker - DOGEUSD M5 scalp (second instance, TMGM)",
     ["Same engine, different job. Volume/scalp tuning for a 24/7 crypto pair,",
      "not the gold swing tuning. Read this before trusting any number:",
      "",
      "* Every *_Dollars input is in PRICE units. DOGE near $0.20 means a stop of",
      "  0.003, not 1.20. If DOGE has moved a long way from there, re-read the",
      "  stop bracket (MinStopDollars/MaxStopDollars) before starting it.",
      "* Trend is EMA-only (TrendMode 0) on M30 over M5 entries: structure",
      "  confirmation on an instrument that just moved 3% is a veto, not a filter.",
      "* Confluence is off - an FVG that also overlaps a breaker is rare on M5,",
      "  and this instance wants many small trades, not six well-fed ones.",
      "* One target at 1R, all of it, breakeven at 0.55R, no trail: small wins",
      "  taken off the table instead of runners given back.",
      "* Session 0-24 and CloseOnWeekend 0, because crypto does not close.",
      "",
      "Sizing is by risk (0.5% of equity), not by lots: a DOGE lot is not a gold",
      "lot, and the margin guard plus MaxLot are what actually bound it.",
      "",
      "Watch rejections.csv on day one: 'spread > 0.0008' means the broker's",
      "normal spread is wider than this assumes, so raise MaxSpreadDollars to",
      "just above what Market Watch shows."],
     {"MagicNumber": "20261016", "DryRun": "0", "MaxSpreadDollars": "0.0008",
      "MaxOpenTrades": "1", "MaxSignalsPerDay": "40", "RequireNewBar": "1",
      "CloseOnWeekend": "0", "StartTradingHourUTC": "0", "StopTradingHourUTC": "24",
      "TrendTimeframe": "30", "TrendMode": "0", "FastEMAPeriod": "9", "SlowEMAPeriod": "21",
      "MinTrendSlopeDollars": "0.0002", "MaxDistFromEmaDollars": "0.004",
      "SwingLookback": "2", "MinSwingRangeDollars": "0.0015",
      "MinDisplacementPct": "50.0", "MinDisplacementAtr": "0.90",
      "FvgMinSizeAtrPct": "30", "FvgMaxSizeAtrPct": "250", "MitigatePct": "45.0",
      "EntryZonePct": "55.0", "MaxZoneAgeBars": "36", "RequireFVGConfluence": "0",
      "ConfluenceLookback": "30", "BreakerMinAtr": "0.50", "BreakerMaxAtr": "4.0",
      "MitigConsolBars": "3", "MitigConsolAtrMax": "0.70", "MitigBreakAtr": "1.10",
      "EntryModel": "1", "AllowMarketEntry": "1", "MaxEntryDistanceDollars": "0.004",
      "MinRejectionWickPct": "25.0", "MinTriggerRangeAtr": "0.30",
      "MinTriggerClosePct": "40.0", "MaxBarsSinceTouch": "3", "LimitExpiryBars": "2",
      "RiskPercent": "0.5", "MaxLot": "0.20", "MaxMarginUsagePct": "20",
      "StopBufferAtrPct": "20.0", "MinStopDollars": "0.0015", "MaxStopDollars": "0.012",
      "Tp1RR": "1.0", "Tp1Percent": "100.0", "Tp2RR": "2.0",
      "BreakEvenTriggerRR": "0.55", "BreakEvenOffsetDollars": "0.0001",
      "UseAtrTrail": "0", "TrailStartRR": "1.2", "MinHoldBars": "0",
      "MaxDailyLossPct": "3.0", "MaxTotalDrawdownPct": "10.0", "MinFreeMarginUsd": "20",
      "NotifyUrl": "https://ntfy.sh/hex-doge-b652c737", "NotifyTitle": "HEX DOGEUSD",
      "NotifyMinMinutes": "1", "NotifyMaxPerHour": "60"}),

    ("doge-scalp-shadow",
     "HEX-FVG-Breaker - DOGEUSD M5 scalp, DRY RUN (no orders sent)",
     ["doge-scalp.set with DryRun=1: the EA computes, draws and logs every",
      "signal, writes the CSVs, and never calls OrderSend.",
      "",
      "Point the second instance at this for its first session. The dashboard",
      "still says SIGNAL, rejections.csv still says why not, and trades.csv stays",
      "empty on purpose - which is how you separate 'the strategy is bad' from",
      "'the plumbing is bad' before either costs anything."],
     {"MagicNumber": "20261016", "DryRun": "1", "MaxSpreadDollars": "0.0008",
      "MaxOpenTrades": "1", "MaxSignalsPerDay": "40", "RequireNewBar": "1",
      "CloseOnWeekend": "0", "StartTradingHourUTC": "0", "StopTradingHourUTC": "24",
      "TrendTimeframe": "30", "TrendMode": "0", "FastEMAPeriod": "9", "SlowEMAPeriod": "21",
      "MinTrendSlopeDollars": "0.0002", "MaxDistFromEmaDollars": "0.004",
      "SwingLookback": "2", "MinSwingRangeDollars": "0.0015",
      "MinDisplacementPct": "50.0", "MinDisplacementAtr": "0.90",
      "FvgMinSizeAtrPct": "30", "FvgMaxSizeAtrPct": "250", "MitigatePct": "45.0",
      "EntryZonePct": "55.0", "MaxZoneAgeBars": "36", "RequireFVGConfluence": "0",
      "ConfluenceLookback": "30", "BreakerMinAtr": "0.50", "BreakerMaxAtr": "4.0",
      "MitigConsolBars": "3", "MitigConsolAtrMax": "0.70", "MitigBreakAtr": "1.10",
      "EntryModel": "1", "AllowMarketEntry": "1", "MaxEntryDistanceDollars": "0.004",
      "MinRejectionWickPct": "25.0", "MinTriggerRangeAtr": "0.30",
      "MinTriggerClosePct": "40.0", "MaxBarsSinceTouch": "3", "LimitExpiryBars": "2",
      "RiskPercent": "0.5", "MaxLot": "0.20", "MaxMarginUsagePct": "20",
      "StopBufferAtrPct": "20.0", "MinStopDollars": "0.0015", "MaxStopDollars": "0.012",
      "Tp1RR": "1.0", "Tp1Percent": "100.0", "Tp2RR": "2.0",
      "BreakEvenTriggerRR": "0.55", "BreakEvenOffsetDollars": "0.0001",
      "UseAtrTrail": "0", "TrailStartRR": "1.2", "MinHoldBars": "0",
      "MaxDailyLossPct": "3.0", "MaxTotalDrawdownPct": "10.0", "MinFreeMarginUsd": "20",
      "NotifyUrl": "https://ntfy.sh/hex-doge-b652c737",
      "NotifyTitle": "HEX DOGEUSD (shadow)",
      "NotifyMinMinutes": "1", "NotifyMaxPerHour": "60"}),
]


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    if not os.path.isfile(EA):
        raise SystemExit(f"EA not found at {EA} (run this from the repo root)")

    inputs = parse_inputs(EA)
    names = [n for _, n, _ in inputs]
    print(f"{EA}: {len(names)} extern inputs parsed")

    # Push topic is deployment, not strategy (see NOTIFY_XAU). Applied to the
    # overrides rather than to the .set files, so regeneration cannot drop it.
    for _name, _title, _notes, _over in PRESETS:
        _over.setdefault("NotifyUrl", NOTIFY_XAU)

    if "--check" in argv:
        bad = [f"{name}: {k}" for name, _, _, over in PRESETS for k in over if k not in names]
        if bad:
            print("STALE PRESET OVERRIDES:\n   " + "\n   ".join(bad))
            return 1
        print(f"OK - {len(PRESETS)} presets, every override matches a real input")
        return 0

    os.makedirs(OUT, exist_ok=True)
    for name, title, notes, over in PRESETS:
        path = os.path.join(OUT, name + ".set")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(preset(inputs, name, title, notes, over))
        body = sum(1 for t, n, _ in inputs if not is_section_header(t, n))
        print(f"  wrote {path}  ({body} inputs, {len(over)} overridden)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
