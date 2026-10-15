#!/usr/bin/env python3
"""
Reference model of HEX-FVG-Breaker.mq4 in Python.

The EA cannot be unit tested (MQL4 has no test runner), so this file is the
executable specification of its decision logic: same ATR, same detectors, same
zone lifecycle, same lot math. It is used to

  * sanity check the EA's logic against a readable implementation,
  * replay a run and see WHY a signal fired or did not,
  * estimate signal frequency before spending weeks on a demo account.

It is NOT a backtester: fills are idealised, there is no slippage, commission or
swap model, and there is no spread on the exit. Do not use its P&L as evidence
that the strategy works. Use it to find bugs and to size the question.

    python3 Tools/simulate_logic.py --selftest     # unit tests, no data needed
    python3 Tools/simulate_logic.py --demo         # synthetic gold-like series
    python3 Tools/simulate_logic.py --csv bars.csv  # your own OHLC (time,o,h,l,c)

Stdlib only. Python 3.8+.
"""
import argparse
import math
import random
import sys

# ---------------------------------------------------------------- primitives

def body(o, c):
    return abs(c - o)


def rng(h, l):
    return h - l


def wick_down(o, c, l):
    return min(o, c) - l


def wick_up(o, c, h):
    return h - max(o, c)


def is_bull(o, c):
    return c > o


def is_bear(o, c):
    return c < o


class Cfg:
    """Mirrors the extern block of the EA. Defaults are the EA defaults."""

    def __init__(self, **kw):
        # Broker scale. Gold feeds are 2-digit (Point 0.01) or 3-digit (0.001).
        # Everything in this model is compared in points exactly like the EA.
        self.point = 0.01
        # trend filter
        self.trend_mode = "BOTH"              # EMA | STRUCTURE | BOTH
        self.fast_ema_period = 21
        self.slow_ema_period = 50
        self.trend_slope_bars = 6
        self.min_trend_slope_pts = 15.0       # $0.15 per oz over the slope window
        self.max_ema_dist_pts = 900.0
        self.trend_timeframe = 60
        # structure / displacement
        self.swing_lookback = 3
        self.min_swing_pts = 120.0          # $1.20 on a 2-digit feed
        self.min_displacement_pct = 55.0
        self.min_displacement_atr = 1.10
        # FVG
        self.use_fvg = True
        self.fvg_min_size_atr_pct = 55
        self.fvg_max_size_atr_pct = 420
        self.mitigate_pct = 50.0
        self.entry_zone_pct = 62.0
        self.max_zone_age_bars = 180
        self.require_fvg_confluence = True
        self.confluence_lookback = 60
        # breaker
        self.use_breaker = True
        self.breaker_min_atr = 0.70
        self.breaker_max_atr = 6.0
        # mitigation
        self.use_mitigation = True
        self.mitig_consol_bars = 4
        self.mitig_consol_atr_max = 0.65
        self.mitig_break_atr = 1.20
        # entry
        self.entry_model = "LIMIT"           # LIMIT | TRIGGER
        self.max_entry_pts = 700.0
        self.min_rejection_wick_pct = 30.0
        self.min_trigger_range_atr = 0.35
        self.min_trigger_close_pct = 45.0
        self.max_bars_since_touch = 6
        self.limit_expiry_bars = 4
        # risk
        self.fixed_lot = 0.01
        self.max_lot = 0.02
        self.risk_percent = 0.0
        self.max_risk_amount = 2.0
        self.max_margin_usage_pct = 50.0
        self.stop_buffer_atr_pct = 25.0
        self.min_stop_pts = 120.0
        self.max_stop_pts = 1400.0
        self.usd_per_point_per_lot = 0.01   # XAUUSD standard: 0.01/pt at 1 lot
        self.min_lot = 0.01
        self.lot_step = 0.01
        self.margin_per_lot = 2200.0        # placeholder: broker-dependent
        self.equity = 100.0
        # exits
        self.tp1_rr = 1.0
        self.tp1_percent = 50.0
        self.tp2_rr = 2.5
        self.break_even_trigger_rr = 0.80
        self.break_even_offset_pts = 5.0
        self.use_atr_trail = True
        self.trail_atr_mult = 2.20
        self.trail_start_rr = 1.0
        self.min_hold_bars = 2
        for k, v in kw.items():
            if not hasattr(self, k):
                raise KeyError(f"unknown config key: {k}")
            setattr(self, k, v)


# ---------------------------------------------------------------- detectors

def is_swing_high(bars, i, cfg):
    """Bar i is the highest high with cfg.swing_lookback bars on each side.
    Mirrors IsSwingHigh(): note the asymmetry (younger bars may tie, older bars
    may not) and the minimum-range noise filter."""
    k = cfg.swing_lookback
    if i - k < 0 or i + k >= len(bars):
        return False
    h = bars[i]["h"]
    if bars[i]["h"] - bars[i]["l"] < cfg.min_swing_pts * cfg.point:
        return False
    for j in range(1, k + 1):
        if bars[i - j]["h"] > h:
            return False
        if bars[i + j]["h"] >= h:
            return False
    return True


def is_swing_low(bars, i, cfg):
    k = cfg.swing_lookback
    if i - k < 0 or i + k >= len(bars):
        return False
    l = bars[i]["l"]
    if bars[i]["h"] - bars[i]["l"] < cfg.min_swing_pts * cfg.point:
        return False
    for j in range(1, k + 1):
        if bars[i - j]["l"] < l:
            return False
        if bars[i + j]["l"] <= l:
            return False
    return True


def is_displacement(bar, direction, atr, cfg):
    """Strong directional close: body >= pct of range AND body >= mult x ATR."""
    if atr <= 0:
        return False
    r = rng(bar["h"], bar["l"])
    if r <= 0:
        return False
    b = body(bar["o"], bar["c"])
    if b / r * 100.0 < cfg.min_displacement_pct:
        return False
    if b < cfg.min_displacement_atr * atr:
        return False
    if direction > 0:
        return is_bull(bar["o"], bar["c"])
    if direction < 0:
        return is_bear(bar["o"], bar["c"])
    return False
# ---------------------------------------------------------------- detectors

def detect_fvg(bars, i, atr, cfg):
    """Three-candle imbalance. The EA uses newest-first indexing (1=just closed,
    2=middle, 3=oldest); here the list is oldest-first, so bars[i] is the EA's
    shift 1, bars[i-1] shift 2, bars[i-2] shift 3.
    Bullish: low[shift1] > high[shift3]. Returns (dir, top, bottom) or None."""
    if i < 2 or atr <= 0:
        return None
    newest, mid, oldest = bars[i], bars[i - 1], bars[i - 2]
    if newest["l"] > oldest["h"] and is_bull(mid["o"], mid["c"]):
        top, bottom = newest["l"], oldest["h"]
        sz = top - bottom
        if newest["c"] <= oldest["c"]:
            return None
        if sz < cfg.fvg_min_size_atr_pct / 100.0 * atr:
            return None
        if cfg.fvg_max_size_atr_pct and sz > cfg.fvg_max_size_atr_pct / 100.0 * atr:
            return None
        return (+1, top, bottom)
    if newest["h"] < oldest["l"] and is_bear(mid["o"], mid["c"]):
        top, bottom = oldest["l"], newest["h"]
        sz = top - bottom
        if newest["c"] >= oldest["c"]:
            return None
        if sz < cfg.fvg_min_size_atr_pct / 100.0 * atr:
            return None
        if cfg.fvg_max_size_atr_pct and sz > cfg.fvg_max_size_atr_pct / 100.0 * atr:
            return None
        return (-1, top, bottom)
    return None


def normalize_zone(direction, top, bottom, atr, cfg, ztype):
    """ZoneAdd() geometry, applied before a zone is stored:
      * breakers below minimum height grow DOWN for bullish, UP for bearish;
      * anything over breaker_max_atr is rejected;
      * degenerate zones are rejected.
    Keeping stored geometry clean means the entry and mitigation code never has
    to re-derive what a zone's edges mean."""
    if atr <= 0 or top <= bottom:
        return None
    if ztype == "BREAKER":
        min_h = cfg.breaker_min_atr * atr
        if top - bottom < min_h:
            if direction > 0:
                bottom = top - min_h          # support hangs below its top
            else:
                top = bottom + min_h          # resistance rests on its bottom
        if top - bottom > cfg.breaker_max_atr * atr:
            return None
    elif ztype == "MITIGATION":
        if top - bottom < 0.08 * atr:
            return None
        if top - bottom > cfg.breaker_max_atr * atr:
            return None
    if top - bottom <= 0:
        return None
    return (top, bottom)


def detect_breaker(bar, swing_high, swing_low, fired_dir, atr, cfg):
    """A swing level broken with displacement flips polarity; the block body is
    the displacing candle. fired_dir (0/+1/-1) stops one move being re-added on
    every bar that closes beyond the broken level."""
    if atr <= 0:
        return None
    if swing_high is not None and fired_dir != +1:
        if bar["c"] > swing_high and is_bull(bar["o"], bar["c"]) and \
           is_displacement(bar, +1, atr, cfg):
            top, bottom = max(bar["o"], bar["c"]), min(bar["o"], bar["c"])
            if top - swing_high > 0.10 * atr:
                g = normalize_zone(+1, top, bottom, atr, cfg, "BREAKER")
                if g:
                    return (+1, g[0], g[1])
    if swing_low is not None and fired_dir != -1:
        if bar["c"] < swing_low and is_bear(bar["o"], bar["c"]) and \
           is_displacement(bar, -1, atr, cfg):
            top, bottom = max(bar["o"], bar["c"]), min(bar["o"], bar["c"])
            if swing_low - bottom > 0.10 * atr:
                g = normalize_zone(-1, top, bottom, atr, cfg, "BREAKER")
                if g:
                    return (-1, g[0], g[1])
    return None


def detect_mitigation(bars, i, atr, cfg):
    """A tight cluster of consolidation bars left behind by a displacement
    candle. Cluster = the cfg.mitig_consol_bars bars before bar i."""
    n = cfg.mitig_consol_bars
    if i - n < 0 or atr <= 0:
        return None
    cluster = bars[i - n:i]
    hi = max(b["h"] for b in cluster)
    lo = min(b["l"] for b in cluster)
    if hi - lo <= 0 or hi - lo > cfg.mitig_consol_atr_max * atr:
        return None
    bar = bars[i]
    if is_displacement(bar, +1, atr, cfg) and bar["c"] > hi:
        return (+1, hi, lo)
    if is_displacement(bar, -1, atr, cfg) and bar["c"] < lo:
        return (-1, hi, lo)
    return None


# ---------------------------------------------------------------- zone store

class Zone:
    """One detected area of interest. Fields mirror ZoneRec in the EA."""

    _next = 0

    def __init__(self, ztype, direction, top, bottom, born_bar, atr):
        Zone._next += 1
        self.id = Zone._next
        self.type = ztype                     # FVG | BREAKER | MITIGATION
        self.dir = direction
        self.top = top
        self.bottom = bottom
        self.born_bar = born_bar
        self.touched = False                  # has price ever traded back into it
        self.first_touch_bar = None           # EA's tTouch: staleness measured here
        self.touches = 0
        self.max_penet = 0.0
        self.inside_now = False               # discrete-visit state machine
        self.traded = False
        self.valid = True
        self.height = top - bottom
        self.atr = atr

    def __repr__(self):
        return (f"<Zone {self.id} {self.type} {'BUY' if self.dir > 0 else 'SELL'} "
                f"{self.bottom:.2f}-{self.top:.2f} touches={self.touches}>")


def update_zones(zones, bar, bar_index, cfg, atr):
    """UpdateZones(): directional penetration, structure-break kills, and
    DISCRETE touch counting.

    Three behaviours here are load-bearing and easy to get wrong:
      * penetration is directional. A bullish zone is support, so it is only
        penetrated from the top downward; a bearish zone is resistance and is
        penetrated from the bottom upward.
      * a close decisively through the far edge kills the zone on its own
        (structure broken), independent of any depth threshold.
      * the FIRST visit is never killed on depth, because that first visit is
        the trade we are looking for. Only a second visit that digs past
        MitigatePct means the resting orders have been consumed.
    Touch counting is per visit, not per bar, or volatility alone would
    mitigate every zone in a choppy market."""
    events = []
    for z in zones:
        if not z.valid:
            continue
        h = z.top - z.bottom
        if h <= 0:
            z.valid = False
            events.append(("DEGENERATE", z))
            continue

        inside = False
        if z.dir > 0:
            if bar["l"] < z.top:
                inside = True
                z.max_penet = max(z.max_penet, (z.top - bar["l"]) / h)
                if bar["c"] < z.bottom - 0.15 * atr:
                    z.valid = False
                    events.append(("CLOSED_THROUGH", z))
                    continue
        else:
            if bar["h"] > z.bottom:
                inside = True
                z.max_penet = max(z.max_penet, (bar["h"] - z.bottom) / h)
                if bar["c"] > z.top + 0.15 * atr:
                    z.valid = False
                    events.append(("CLOSED_THROUGH", z))
                    continue

        if inside and not z.inside_now:
            z.touches += 1
            z.inside_now = True
            if not z.touched:
                z.touched = True
                z.first_touch_bar = bar_index     # staleness measured from here
            events.append(("TOUCH", z))
            if z.touches > 1 and z.max_penet * 100.0 >= cfg.mitigate_pct:
                z.valid = False
                events.append(("MITIGATED", z))
                continue
        elif not inside:
            z.inside_now = False                  # next entry is a new visit
    return events


def prune_zones(zones, bar_index, cfg):
    """PruneZones(): drop zones that have outlived their usefulness."""
    for z in zones:
        if z.valid and bar_index - z.born_bar > cfg.max_zone_age_bars:
            z.valid = False
    return [z for z in zones if z.valid]


def count_confluence(zones, exclude, direction, top, bottom, bar_index, cfg):
    """Live zones of the same direction overlapping the candidate, created within
    ConfluenceLookback bars. This is what separates a lone FVG from a real
    order-flow area."""
    cnt = 0
    for z in zones:
        if z is exclude or not z.valid or z.dir != direction:
            continue
        if bar_index - z.born_bar > cfg.confluence_lookback:
            continue
        if z.bottom <= top and z.top >= bottom:
            cnt += 1
    return cnt


# ---------------------------------------------------------------- trend

def ema(closes, period, i):
    """EMA value at index i, seeded with an SMA like MT4 does."""
    if i + 1 < period:
        return None
    seed = sum(closes[i - period + 1:i + 1]) / period
    k = 2.0 / (period + 1)
    for j in range(i - period + 2, i + 1):
        seed = closes[j] * k + seed * (1 - k)
    return seed


def trend_dir(closes, i, cfg, swings=None):
    """DetermineTrend(): +1, -1 or 0. EMA-stack mode needs fast above slow, the
    fast rising, and the slow EMA to have moved by a minimum slope - the slope
    test is what keeps the EA out of flat markets. swings is the confirmed
    swing structure, [(index, price), ...], for structure mode."""
    fast_now, slow_now = ema(closes, cfg.fast_ema_period, i), ema(closes, cfg.slow_ema_period, i)
    if fast_now is None or slow_now is None:
        return 0
    ema_d = 0
    if i >= cfg.trend_slope_bars:
        fast_old = ema(closes, cfg.fast_ema_period, i - cfg.trend_slope_bars)
        slow_old = ema(closes, cfg.slow_ema_period, i - cfg.trend_slope_bars)
        if fast_old is not None and slow_old is not None:
            if fast_now > slow_now and fast_now > fast_old and \
               (slow_now - slow_old) / cfg.point >= cfg.min_trend_slope_pts:
                ema_d = +1
            if fast_now < slow_now and fast_now < fast_old and \
               (slow_old - slow_now) / cfg.point >= cfg.min_trend_slope_pts:
                ema_d = -1
    if cfg.trend_mode == "EMA":
        return ema_d

    str_d = 0
    if swings:
        hs = [x for x in swings["high"] if x[0] <= i][-2:]
        ls = [x for x in swings["low"] if x[0] <= i][-2:]
        if len(hs) == 2 and len(ls) == 2:
            if hs[-1][1] > hs[-2][1] and ls[-1][1] > ls[-2][1]:
                str_d = +1
            elif hs[-1][1] < hs[-2][1] and ls[-1][1] < ls[-2][1]:
                str_d = -1
    if cfg.trend_mode == "STRUCTURE":
        return str_d
    return ema_d if ema_d == str_d else 0


def trigger_ok(bar, direction, atr, cfg):
    """TriggerOk(): a rejection candle. Buy = long lower wick, closes up, and
    shuts in at least min_trigger_close_pct of its range."""
    r = rng(bar["h"], bar["l"])
    if r <= 0 or r < cfg.min_trigger_range_atr * atr:
        return False
    if direction > 0:
        if wick_down(bar["o"], bar["c"], bar["l"]) / r * 100.0 < cfg.min_rejection_wick_pct:
            return False
        if bar["c"] <= bar["o"]:
            return False
        return (bar["c"] - bar["l"]) / r * 100.0 >= cfg.min_trigger_close_pct
    if wick_up(bar["o"], bar["c"], bar["h"]) / r * 100.0 < cfg.min_rejection_wick_pct:
        return False
    if bar["c"] >= bar["o"]:
        return False
    return (bar["h"] - bar["c"]) / r * 100.0 >= cfg.min_trigger_close_pct


# ---------------------------------------------------------------- geometry

def entry_geometry(zone, atr, cfg):
    """Entry/stop/TP from a zone. The limit sits entry_zone_pct of the way into
    the zone (deep = better R, more unfilled), the stop sits behind the far edge
    plus an ATR buffer, then the stop distance is floored at min_stop_pts."""
    zh = zone.top - zone.bottom
    buf = atr * cfg.stop_buffer_atr_pct / 100.0
    if zone.dir > 0:
        entry = zone.top - zh * cfg.entry_zone_pct / 100.0
        sl = zone.bottom - buf
    else:
        entry = zone.bottom + zh * cfg.entry_zone_pct / 100.0
        sl = zone.top + buf
    risk_pts = abs(entry - sl) / cfg.point
    if risk_pts < cfg.min_stop_pts:
        sl = entry + (-1 if zone.dir > 0 else 1) * cfg.min_stop_pts * cfg.point
        risk_pts = abs(entry - sl) / cfg.point
    if risk_pts > cfg.max_stop_pts:
        return None
    tp = entry + zone.dir * risk_pts * cfg.tp2_rr * cfg.point
    return {"entry": entry, "sl": sl, "tp": tp, "risk_pts": risk_pts}


def calc_lots(risk_pts, equity, cfg):
    """CalcLots(): fixed lot unless risk_percent is set; capped by max_lot, then
    by the margin cap, then floored at the broker minimum. Returns (lots, why)."""
    lots = cfg.fixed_lot
    if cfg.risk_percent > 0:
        risk_usd = equity * cfg.risk_percent / 100.0
        if cfg.max_risk_amount > 0:
            risk_usd = min(risk_usd, cfg.max_risk_amount)
        lots = risk_usd / (risk_pts * cfg.usd_per_point_per_lot)
    if lots > cfg.max_lot:
        lots = cfg.max_lot
    cap = equity * cfg.max_margin_usage_pct / 100.0
    if cfg.margin_per_lot > 0 and lots * cfg.margin_per_lot > cap:
        lots = cap / cfg.margin_per_lot
    if lots < cfg.min_lot:
        return (0.0, f"only {lots:.3f} lots affordable (broker min {cfg.min_lot})")
    lots = round(math.floor(lots / cfg.lot_step + 1e-9) * cfg.lot_step, 2)
    if lots < cfg.min_lot:
        return (0.0, "rounded below broker minimum")
    return (lots, "")


# ---------------------------------------------------------------- engine

def tick_path(bar, order):
    """The intra-bar price sequence for one bar.

    OHLC records which prices were touched, never the order they were touched
    in, so a bar that prints both a stop and a target has no single outcome.
    These two sequences are the pessimistic and the optimistic reading of the
    same bar; where they disagree, the real result depended on the tick stream.
    """
    if order == "high_first":
        return [bar["o"], bar["h"], bar["l"], bar["c"]]
    if order == "low_first":
        return [bar["o"], bar["l"], bar["h"], bar["c"]]
    return []


class Sim:
    """Bar-by-bar replay of the EA's decision loop.

    Deliberately NOT a backtester. Fills are idealised (no slippage, commission
    or swap; the limit fills if price reaches it), so the P&L is indicative
    only. What this is good for: confirming the detectors and filters behave as
    written, and measuring signal frequency before spending weeks on a demo."""

    def __init__(self, cfg, bars):
        self.cfg = cfg
        self.bars = bars                          # [{t,o,h,l,c}] oldest first
        self.closes = [b["c"] for b in bars]
        self.zones = []
        self.trades = []
        self.events = []
        self.rejections = {}
        self.zone_deaths = {}
        self.swing_high = None
        self.swing_low = None
        self.fired_dir = 0
        self.swings = {"high": [], "low": []}
        self.atr = self._atr_series()

    def reject(self, reason):
        self.rejections[reason] = self.rejections.get(reason, 0) + 1

    def _atr_series(self):
        """Wilder ATR(14) as a forward pass. atr[i] is the value at bar i, which
        is what iATR(...,1) returns for the EA on the next tick."""
        out = [0.0] * len(self.bars)
        n = 14
        if len(self.bars) <= n + 1:
            return out
        tr = [0.0] * len(self.bars)
        for j in range(1, len(self.bars)):
            b, p = self.bars[j], self.bars[j - 1]
            tr[j] = max(b["h"] - b["l"], abs(b["h"] - p["c"]), abs(b["l"] - p["c"]))
        val = sum(tr[1:n + 1]) / n
        out[n] = val
        for j in range(n + 1, len(self.bars)):
            val = (val * (n - 1) + tr[j]) / n
            out[j] = val
        return out

    def update_structure(self, i):
        """UpdateStructure(): swings confirm cfg.swing_lookback bars late and a
        freshly confirmed level re-arms the breaker detector (fired_dir -> 0)."""
        k = self.cfg.swing_lookback
        idx = i - k
        if idx < k:
            return
        if is_swing_high(self.bars, idx, self.cfg):
            self.swing_high = self.bars[idx]["h"]
            self.swings["high"].append((idx, self.swing_high))
            self.fired_dir = 0
        if is_swing_low(self.bars, idx, self.cfg):
            self.swing_low = self.bars[idx]["l"]
            self.swings["low"].append((idx, self.swing_low))
            self.fired_dir = 0

    def add_zone(self, i, ztype, direction, top, bottom, atr):
        geom = normalize_zone(direction, top, bottom, atr, self.cfg, ztype)
        if not geom:
            self.reject(ztype + "_GEOMETRY")
            return None
        z = Zone(ztype, direction, geom[0], geom[1], i, atr)
        self.zones.append(z)
        self.events.append((i, "OPEN", z.type))
        return z

    def scan(self, i, atr):
        cfg = self.cfg
        if cfg.use_fvg:
            f = detect_fvg(self.bars, i, atr, cfg)
            if f:
                self.add_zone(i, "FVG", f[0], f[1], f[2], atr)
        if cfg.use_breaker:
            b = detect_breaker(self.bars[i], self.swing_high, self.swing_low,
                               self.fired_dir, atr, cfg)
            if b:
                if self.add_zone(i, "BREAKER", b[0], b[1], b[2], atr):
                    self.fired_dir = b[0]
        if cfg.use_mitigation:
            m = detect_mitigation(self.bars, i, atr, cfg)
            if m:
                self.add_zone(i, "MITIGATION", m[0], m[1], m[2], atr)

    def score(self, z, confl, dist_pts, since_touch):
        """EvaluateSetup's ranking: confluence dominates, then shallow
        penetration and a fresh touch, then not chasing the zone."""
        return (confl * 2.0 - z.max_penet * 4.0 - since_touch * 0.15
                - dist_pts / max(1.0, self.cfg.max_entry_pts))

    def best_setup(self, i, atr, trend):
        """EvaluateSetup(): rank every live zone and return (zone, geometry,
        confl) for the winner, or None. Rejection reasons are tallied."""
        cfg = self.cfg
        price = self.bars[i]["c"]
        fast = ema(self.closes, cfg.fast_ema_period, i)
        best = None
        for z in self.zones:
            if not z.valid or z.traded or z.touches == 0:
                continue
            if z.dir != trend:
                continue
            confl = count_confluence(self.zones, z, z.dir, z.top, z.bottom, i, cfg)
            if z.type == "FVG" and cfg.require_fvg_confluence and confl == 0:
                self.reject("NO_CONFLUENCE")
                continue
            g = entry_geometry(z, atr, cfg)
            if g is None:
                self.reject("STOP_TOO_WIDE")
                continue
            dist = (price - g["entry"]) if z.dir > 0 else (g["entry"] - price)
            dist_pts = dist / cfg.point
            if dist_pts > cfg.max_entry_pts:
                self.reject("TOO_FAR")
                continue
            if cfg.max_ema_dist_pts > 0 and fast is not None and \
               abs(price - fast) / cfg.point > cfg.max_ema_dist_pts:
                self.reject("OVEREXTENDED")
                continue
            # EA: barsSinceTouch = (Time[1] - tTouch)/Period, and tTouch is set
            # once, at the FIRST touch. So staleness is measured from the first
            # visit, not the most recent one.
            since = i - z.first_touch_bar if z.first_touch_bar is not None else 0
            if since > cfg.max_bars_since_touch:
                self.reject("STALE_TOUCH")
                continue
            s = self.score(z, confl, dist_pts, since)
            if best is None or s > best[0]:
                best = (s, z, g, confl)
        if best is None:
            return None
        return best[1], best[2], best[3]

    def simulate_trade_ticks(self, i, z, g, lots, path="high_first"):
        """Same trade, managed tick by tick instead of bar by bar.

        A bar tells you the four prices it touched, not the order. When one bar
        prints both a low through the stop and a high through TP1, the outcome
        depends entirely on which came first, and only the tick stream knows.
        This walks each bar as open -> high -> low -> close ("high_first") or
        open -> low -> high -> close ("low_first") and evaluates every trigger
        at each step, so the two paths bracket what the live EA could have done.

        Differences between this and simulate_trade() are deliberate and mirror
        the EA more closely:
          * the ATR trail anchors on the previous COMPLETED bar's extreme, like
            High[1] in the EA, rather than the current bar's close;
          * the stop is treated as always live at the broker, so it is checked
            before any of the profit protections on every step;
          * TP1 and the breakeven ratchet can therefore fire mid-bar and the new
            stop is enforced on the very next step of the same bar, which is
            what happens live and is the main source of bar-vs-tick disagreement.

        Returns None when the path is unknown, and tags each trade with the path
        plus an `ambiguous` flag for bars where both extremes were threatened.
        """
        if path not in ("high_first", "low_first"):
            return None
        cfg, d = self.cfg, z.dir
        entry, sl, tp = g["entry"], g["sl"], g["tp"]
        risk = abs(entry - sl)
        if risk <= 0:
            return None
        tp1 = entry + d * risk * cfg.tp1_rr
        remaining = lots
        pnl_r = 0.0
        be_active = False
        exit_price, reason, held = None, "END_OF_DATA", 0
        mae, mfe = 0.0, 0.0
        ambiguous = False
        for j in range(i + 1, len(self.bars)):
            b = self.bars[j]
            held = j - i
            prev_h = self.bars[j - 1]["h"]
            prev_l = self.bars[j - 1]["l"]
            mfe = max(mfe, (b["h"] - entry) * d)
            mae = min(mae, (b["l"] - entry) * d)
            if self._both_sides(b, d, entry, sl, tp, tp1, be_active, held, cfg):
                ambiguous = True
            for p in tick_path(b, path):
                stop_hit = (p <= sl) if d > 0 else (p >= sl)
                if stop_hit:
                    exit_price = sl
                    reason = "BE_OR_TRAIL" if be_active else "STOP_LOSS"
                    break
                if held >= cfg.min_hold_bars and remaining > 0 and \
                   cfg.tp1_percent > 0 and ((p >= tp1) if d > 0 else (p <= tp1)):
                    closed = remaining * cfg.tp1_percent / 100.0
                    pnl_r += (closed / lots) * (tp1 - entry) * d / risk
                    remaining -= closed
                    be = entry + d * cfg.break_even_offset_pts * cfg.point
                    sl = max(sl, be) if d > 0 else min(sl, be)
                    be_active = True
                if cfg.use_atr_trail and self.atr[j] > 0:
                    anchor = prev_h if d > 0 else prev_l
                    if ((anchor - entry) * d) / risk >= cfg.trail_start_rr:
                        t = anchor - d * cfg.trail_atr_mult * self.atr[j]
                        if (d > 0 and t > sl) or (d < 0 and t < sl):
                            sl = t
                            be_active = True
                if (p >= tp) if d > 0 else (p <= tp):
                    exit_price, reason = tp, "TP2"
                    break
            if exit_price is not None:
                break
        if exit_price is None:
            exit_price = self.bars[-1]["c"]
        pnl_r += (remaining / lots) * (exit_price - entry) * d / risk
        self.trades.append({
            "bar": i, "dir": "BUY" if d > 0 else "SELL", "type": z.type,
            "entry": entry, "sl": sl, "tp": tp, "lots": lots,
            "r": round(pnl_r, 2), "mae_pts": round(mae / cfg.point, 1),
            "mfe_pts": round(mfe / cfg.point, 1), "hold_bars": held,
            "exit_price": exit_price, "exit_reason": reason,
            "path": path, "ambiguous": ambiguous})
        return self.trades[-1]

    def _both_sides(self, b, d, entry, sl, tp, tp1, be_active, held, cfg):
        """True when this bar threatens the stop AND a target: the case where the
        intra-bar order decides the outcome, so the two paths must disagree."""
        stop_touched = (b["l"] <= sl) if d > 0 else (b["h"] >= sl)
        target_touched = (b["h"] >= tp) if d > 0 else (b["l"] <= tp)
        if held >= cfg.min_hold_bars and cfg.tp1_percent > 0:
            target_touched = target_touched or \
                ((b["h"] >= tp1) if d > 0 else (b["l"] <= tp1))
        return stop_touched and target_touched

    def simulate_trade(self, i, z, g, lots):
        """Idealised forward management of one entry. From bar i+1: the stop is
        always live (it rests at the broker), while TP1/BE/trail/TP2 only act
        after min_hold_bars, exactly like the EA's early-continue."""
        cfg, d = self.cfg, z.dir
        entry, sl, tp = g["entry"], g["sl"], g["tp"]
        risk = abs(entry - sl)
        if risk <= 0:
            return None
        tp1 = entry + d * risk * cfg.tp1_rr
        remaining = lots
        # P&L is accumulated in R units per initial lot: each realised slice
        # contributes (its share of the position) x (its move / risk). Keeping
        # everything in R avoids mixing lots with price units.
        pnl_r = 0.0
        be_active = False
        exit_price, reason, held = None, "END_OF_DATA", 0
        mae, mfe = 0.0, 0.0
        for j in range(i + 1, len(self.bars)):
            b = self.bars[j]
            held = j - i
            mfe = max(mfe, (b["h"] - entry) * d)
            mae = min(mae, (b["l"] - entry) * d)
            if (b["l"] <= sl) if d > 0 else (b["h"] >= sl):
                exit_price = sl
                reason = "BE_OR_TRAIL" if be_active else "STOP_LOSS"
                break
            if held < cfg.min_hold_bars:
                continue
            if remaining > 0 and cfg.tp1_percent > 0 and \
               ((b["h"] >= tp1) if d > 0 else (b["l"] <= tp1)):
                closed = remaining * cfg.tp1_percent / 100.0
                pnl_r += (closed / lots) * (tp1 - entry) * d / risk
                remaining -= closed
                be = entry + d * cfg.break_even_offset_pts * cfg.point
                sl = max(sl, be) if d > 0 else min(sl, be)
                be_active = True
            if cfg.use_atr_trail and self.atr[j] > 0:
                if ((b["c"] - entry) * d) / risk >= cfg.trail_start_rr:
                    t = b["c"] - d * cfg.trail_atr_mult * self.atr[j]
                    if (d > 0 and t > sl) or (d < 0 and t < sl):
                        sl = t
                        be_active = True
            if (b["h"] >= tp) if d > 0 else (b["l"] <= tp):
                exit_price, reason = tp, "TP2"
                break
        if exit_price is None:
            exit_price = self.bars[-1]["c"]
        pnl_r += (remaining / lots) * (exit_price - entry) * d / risk
        r_mult = pnl_r
        self.trades.append({
            "bar": i, "dir": "BUY" if d > 0 else "SELL", "type": z.type,
            "entry": entry, "sl": sl, "tp": tp, "lots": lots,
            "r": round(r_mult, 2), "mae_pts": round(mae / cfg.point, 1),
            "mfe_pts": round(mfe / cfg.point, 1), "hold_bars": held,
            "exit_price": exit_price, "exit_reason": reason})
        return self.trades[-1]



    def run(self, warmup=80, ticks=None):
        """Replay the whole series the way OnTick does on each new bar.

        ticks=None manages each open trade from bar data only (fast, and the
        traditional optimistic reading). ticks="high_first"/"low_first" replays
        the same entries through simulate_trade_ticks(), which walks intra-bar
        price and can therefore reach a different outcome.
        """
        for i in range(warmup, len(self.bars)):
            atr = self.atr[i]
            if atr <= 0:
                continue
            self.update_structure(i)
            self.scan(i, atr)
            for ev, z in update_zones(self.zones, self.bars[i], i, self.cfg, atr):
                self.events.append((i, ev, z.type))
                if ev == "MITIGATED":
                    self.zone_deaths["MITIGATED"] = self.zone_deaths.get("MITIGATED", 0) + 1
            self.zones = [z for z in self.zones if z.valid]
            kept = prune_zones(self.zones, i, self.cfg)
            aged = len(self.zones) - len(kept)
            if aged:
                self.zone_deaths["AGED_OUT"] = self.zone_deaths.get("AGED_OUT", 0) + aged
            self.zones = kept
            trend = trend_dir(self.closes, i, self.cfg, self.swings)
            if trend == 0:
                self.reject("NO_TREND")
                continue
            best = self.best_setup(i, atr, trend)
            if best is None:
                continue
            z, g, _confl = best
            if self.cfg.entry_model == "TRIGGER" and \
               not trigger_ok(self.bars[i], z.dir, atr, self.cfg):
                self.reject("NO_TRIGGER")
                continue
            lots, _why = calc_lots(g["risk_pts"], self.cfg.equity, self.cfg)
            if lots <= 0:
                self.reject("SIZE")
                continue
            z.traded = True
            if ticks:
                self.simulate_trade_ticks(i, z, g, lots, ticks)
            else:
                self.simulate_trade(i, z, g, lots)
        return self.summary()

    def summary(self):
        rs = [t["r"] for t in self.trades]
        wins = [r for r in rs if r > 0]
        losses = [r for r in rs if r < 0]
        gl = -sum(losses)
        pf = (sum(wins) / gl) if gl > 0 else None
        created, exits = {}, {}
        for _, ev, zt in self.events:
            if ev == "OPEN":
                created[zt] = created.get(zt, 0) + 1
        for t in self.trades:
            exits[t["exit_reason"]] = exits.get(t["exit_reason"], 0) + 1
        return {
            "bars": len(self.bars), "trades": len(rs),
            "win_rate": round(100.0 * len(wins) / len(rs), 1) if rs else 0.0,
            "expectancy_r": round(sum(rs) / len(rs), 3) if rs else 0.0,
            "total_r": round(sum(rs), 2) if rs else 0.0,
            "profit_factor": (round(pf, 2) if pf is not None
                              else ("inf" if wins else 0.0)),
            "zones_created": created, "zone_deaths": self.zone_deaths,
            "exit_reasons": exits,
            "rejections": dict(sorted(self.rejections.items(), key=lambda kv: -kv[1])),
            "trades_detail": self.trades,
        }


# ---------------------------------------------------------------- data

def synth_bars(n=6000, seed=7, start=2650.0, vol=0.35, drift=0.02):
    """Random-walk gold-ish M15 series with drifting regime blocks, so the
    detectors see trends, ranges and displacement."""
    rnd = random.Random(seed)
    bars, price = [], start
    for i in range(n):
        regime = math.sin(i / 220.0) * drift + (0.01 if (i // 400) % 3 == 0 else -0.005)
        o = price
        # occasional displacement candles
        step = rnd.gauss(regime, vol) * (3.0 if rnd.random() < 0.03 else 1.0)
        c = o + step
        hi = max(o, c) + abs(rnd.gauss(0, vol * 0.6))
        lo = min(o, c) - abs(rnd.gauss(0, vol * 0.6))
        bars.append({"t": i, "o": round(o, 2), "h": round(hi, 2),
                     "l": round(lo, 2), "c": round(c, 2)})
        price = c
    return bars


def load_csv_bars(path):
    """Read time,open,high,low,close (header optional)."""
    bars = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = [p.strip() for p in line.strip().split(",")]
            if len(parts) < 5 or parts[0].lower() in ("time", "date", "dt"):
                continue
            try:
                o, h, l, c = (float(parts[-4]), float(parts[-3]),
                              float(parts[-2]), float(parts[-1]))
            except ValueError:
                continue
            bars.append({"t": parts[0], "o": o, "h": h, "l": l, "c": c})
    return bars


def print_summary(s, stream=sys.stdout):
    p = lambda *a: print(*a, file=stream)
    p("=" * 66)
    p("HEX-FVG-Breaker reference model - replay summary")
    p("=" * 66)
    p(f"bars replayed      {s['bars']}")
    p(f"zones created      {s['zones_created']}")
    p(f"zone deaths        {s['zone_deaths']}")
    p(f"trades             {s['trades']}")
    if s["trades"]:
        p(f"win rate           {s['win_rate']}%")
        p(f"expectancy         {s['expectancy_r']} R   total {s['total_r']} R")
        p(f"profit factor      {s['profit_factor']}")
        p(f"exit reasons       {s['exit_reasons']}")
    p("rejections:")
    for k, v in list(s["rejections"].items())[:12]:
        p(f"      {v:>6}  {k}")
    p("")
    p("NOTE: fills are idealised. Treat counts and frequencies as meaningful,")
    p("the P&L as indicative only.")
    return s


# ---------------------------------------------------------------- selftest

def bar(o, h, l, c, t=0):
    return {"t": t, "o": o, "h": h, "l": l, "c": c}


def run_selftest():
    checks = []

    def ck(name, cond, extra=""):
        checks.append((f"{name}{('  ' + extra) if extra else ''}", bool(cond)))

    cfg = Cfg()
    # --- FVG: low[1] > high[3] with a bullish middle candle -> bullish gap
    bars = [bar(100, 101, 99, 100.5), bar(101, 102, 100.5, 101.8),
            bar(102, 104, 101.9, 103.9), bar(104, 106, 103.5, 105.9),
            bar(106, 108, 105.8, 107.9)]
    f = detect_fvg(bars, 4, 2.0, cfg)
    ck("fvg bullish detected", f is not None and f[0] == +1)
    ck("fvg edges are low[newest]/high[oldest]",
       f and abs(f[1] - 105.8) < 1e-9 and abs(f[2] - 104.0) < 1e-9)
    ck("fvg min size filters noise", detect_fvg(bars, 4, 20.0, cfg) is None)

    # --- displacement: big bull body passes, doji does not
    ck("displacement bull", is_displacement(bar(100, 106, 99.8, 105.8), +1, 3.0, cfg))
    ck("displacement rejects doji", not is_displacement(bar(100, 106, 94, 100.2), +1, 3.0, cfg))

    # --- swing detection needs lookback bars on both sides
    sbars = [bar(1, 5, 1, 4) for _ in range(7)]
    sbars[3] = bar(4, 10, 4, 5)                  # range 6.0 clears the noise filter
    ck("swing high at centre", is_swing_high(sbars, 3, Cfg(swing_lookback=3)))
    ck("no swing too close to the edge", not is_swing_high(sbars, 2, Cfg(swing_lookback=3)))
    ck("micro swing filtered out",
       not is_swing_high([bar(1, 5.0, 1.0, 4) for _ in range(7)], 3, Cfg(swing_lookback=3)))

    # --- breaker geometry: thin block grows DOWN when bullish, UP when bearish
    g = normalize_zone(+1, 110.0, 109.9, 10.0, Cfg(breaker_min_atr=0.70), "BREAKER")
    ck("bull breaker grows down from its top",
       g is not None and abs(g[0] - 110.0) < 1e-9 and abs(g[1] - 103.0) < 1e-9)
    g2 = normalize_zone(-1, 110.1, 110.0, 10.0, Cfg(breaker_min_atr=0.70), "BREAKER")
    ck("bear breaker grows up from its bottom",
       g2 is not None and abs(g2[1] - 110.0) < 1e-9 and abs(g2[0] - 117.0) < 1e-9)
    ck("oversized breaker rejected",
       normalize_zone(+1, 200.0, 100.0, 10.0, Cfg(breaker_max_atr=6.0), "BREAKER") is None)

    # --- discrete touch counting: staying inside counts ONE touch
    cfg2 = Cfg(mitigate_pct=99.0)
    z = Zone("FVG", +1, 110.0, 100.0, 0, 5.0)
    inside = bar(105, 106, 104, 105.5)
    for k in range(6):
        update_zones([z], inside, k + 1, cfg2, 5.0)
    ck("one touch while price stays inside", z.touches == 1)
    update_zones([z], bar(120, 121, 119, 120.5), 7, cfg2, 5.0)
    update_zones([z], inside, 8, cfg2, 5.0)
    ck("re-entry counts a second touch", z.touches == 2)

    # --- mitigation: the FIRST visit is never killed on depth; a second visit
    #     that digs past MitigatePct is
    cfg3 = Cfg(mitigate_pct=50.0)
    z3 = Zone("FVG", +1, 110.0, 100.0, 0, 1.0)
    update_zones([z3], bar(104, 106, 103, 105), 1, cfg3, 1.0)   # first visit, 30% deep
    ck("not mitigated at 30% penetration", z3.valid)
    update_zones([z3], bar(104, 105, 99, 98.5), 2, cfg3, 1.0)   # closed through
    ck("closed through the far edge kills", not z3.valid)
    z4 = Zone("FVG", +1, 110.0, 100.0, 0, 1.0)
    update_zones([z4], bar(104, 106, 103, 105), 1, cfg3, 1.0)      # visit 1: survives
    update_zones([z4], bar(115, 116, 112, 115), 2, cfg3, 1.0)      # leaves (not through)
    update_zones([z4], bar(102, 104, 101, 103), 3, cfg3, 1.0)      # visit 2, 90% deep
    ck("second deep visit mitigated", not z4.valid and z4.touches == 2)

    # --- entry geometry: deep entry + buffered stop + R multiples
    cfg4 = Cfg(entry_zone_pct=62.0, stop_buffer_atr_pct=25.0, min_stop_pts=50.0,
               max_stop_pts=5000.0, tp2_rr=2.5)
    z4 = Zone("FVG", +1, 110.0, 100.0, 0, 4.0)
    g4 = entry_geometry(z4, 4.0, cfg4)
    ck("bull entry sits 62% into the zone", g4 and abs(g4["entry"] - 103.8) < 1e-9)
    ck("stop sits 25% ATR behind the zone", g4 and abs(g4["sl"] - 99.0) < 1e-9)
    ck("tp sits at 2.5R", g4 and abs(g4["tp"] - (103.8 + 2.5 * 4.8)) < 1e-6)
    small = Zone("FVG", +1, 100.30, 100.00, 0, 0.1)
    gs = entry_geometry(small, 0.1, Cfg(entry_zone_pct=62.0, stop_buffer_atr_pct=25.0,
                                        min_stop_pts=120.0, max_stop_pts=1400.0))
    ck("minimum stop distance enforced", gs and abs(gs["risk_pts"] - 120.0) < 1e-6)
    ck("too-wide stop rejected", entry_geometry(z4, 4.0, Cfg(max_stop_pts=10.0)) is None)

    # --- lot sizing: fixed lot, MaxLot cap, margin cap, broker minimum
    l1, _ = calc_lots(300, 100.0, Cfg(fixed_lot=0.01, max_lot=0.02, risk_percent=0))
    ck("fixed lot used when risk% is off", l1 == 0.01)
    l2, _ = calc_lots(300, 100.0, Cfg(fixed_lot=0.01, max_lot=0.005, risk_percent=0))
    ck("max lot cap then broker minimum", l2 == 0.0)
    l3, _ = calc_lots(100, 100.0, Cfg(risk_percent=1.0, max_risk_amount=2.0,
                                      max_lot=0.02, usd_per_point_per_lot=0.01,
                                      margin_per_lot=0.0))
    ck("risk% sizing capped by MaxLot", l3 == 0.02)
    l4, _ = calc_lots(500, 100.0, Cfg(risk_percent=1.0, max_risk_amount=50.0,
                                      max_lot=1.0, margin_per_lot=5000.0,
                                      max_margin_usage_pct=50.0,
                                      usd_per_point_per_lot=0.01))
    ck("margin cap applied", l4 <= 0.01 + 1e-9)

    # --- trend filter
    up = [float(100 + i * 0.5) for i in range(120)]
    ck("uptrend reads +1", trend_dir(up, 119, Cfg(trend_mode="EMA")) == +1)
    ck("downtrend reads -1", trend_dir(list(reversed(up)), 119, Cfg(trend_mode="EMA")) == -1)
    flat = [100.0 + (0.02 if i % 2 else -0.02) for i in range(120)]
    ck("flat market reads 0", trend_dir(flat, 119, Cfg(trend_mode="EMA")) == 0)

    # --- trigger candle
    ck("hammer passes the buy trigger",
       trigger_ok(bar(100.5, 101.2, 98.0, 101.0), +1, 1.0, cfg))
    ck("closing down fails the buy trigger",
       not trigger_ok(bar(101.0, 101.2, 98.0, 98.3), +1, 1.0, cfg))
    ck("tiny candle fails the range filter",
       not trigger_ok(bar(100, 100.05, 99.95, 100.02), +1, 5.0, cfg))
    ck("no lower wick fails the buy trigger",
       not trigger_ok(bar(100, 103, 97, 97.5), +1, 1.0, cfg))

    # --- confluence: overlapping same-direction zone counts, opposite does not
    cfg5 = Cfg()
    za = Zone("FVG", +1, 110.0, 100.0, 0, 5.0)
    zb = Zone("BREAKER", +1, 105.0, 95.0, 1, 5.0)
    zc = Zone("BREAKER", -1, 105.0, 95.0, 2, 5.0)
    ck("overlapping same-direction zone counts",
       count_confluence([za, zb], za, +1, 110.0, 100.0, 5, cfg5) == 1)
    ck("opposite-direction zone does not count",
       count_confluence([za, zc], za, +1, 110.0, 100.0, 5, cfg5) == 0)

    # --- R arithmetic, hand-checked: a clean TP2 is exactly +Tp2RR
    cfgR = Cfg(tp1_rr=1.0, tp1_percent=0.0, use_atr_trail=False, min_hold_bars=1)
    simR = Sim(cfgR, [bar(100, 101, 99, 100)] * 3 +
               [bar(103, 111, 103, 110), bar(110, 116.5, 109.5, 116)])
    zg = Zone("FVG", +1, 110.0, 100.0, 0, 4.0)
    gg = {"entry": 103.8, "sl": 99.0, "tp": 103.8 + 2.5 * 4.8, "risk_pts": 480.0}
    tR = simR.simulate_trade(2, zg, gg, 0.01)
    ck("clean TP2 = +2.5R", tR and abs(tR["r"] - 2.5) < 1e-9 and
       tR["exit_reason"] == "TP2")

    # a clean stop-out is exactly -1R
    simS = Sim(cfgR, [bar(100, 101, 99, 100)] * 3 +
               [bar(103, 104, 98, 98.5), bar(98, 99, 97, 98)])
    tS = simS.simulate_trade(2, Zone("FVG", +1, 110.0, 100.0, 0, 4.0), gg, 0.01)
    ck("clean stop-out = -1R", tS and abs(tS["r"] + 1.0) < 1e-9 and
       tS["exit_reason"] == "STOP_LOSS")

    # partial TP1 at 1R books half the position at +1R => +0.5R banked, and the
    # remainder must never give back more than the stop allows
    cfgP = Cfg(tp1_rr=1.0, tp1_percent=50.0, use_atr_trail=False, min_hold_bars=1,
               break_even_offset_pts=5.0)
    simP = Sim(cfgP, [bar(100, 101, 99, 100)] * 3 +
               [bar(103, 109, 103, 108), bar(108, 109, 103, 104),
                bar(104, 105, 102, 103)])
    tP = simP.simulate_trade(2, Zone("FVG", +1, 110.0, 100.0, 0, 4.0), gg, 0.01)
    ck("partial TP1 then stop at breakeven ~ +0.5R", tP and 0.4 < tP["r"] < 0.6)

    # --- full replay
    bars2 = synth_bars(2500, seed=11)
    s = Sim(Cfg(trend_mode="EMA"), bars2).run(warmup=120)
    ck("replay produced trades", s["trades"] > 0)
    ck("at least 2 zone types detected", len(s["zones_created"]) >= 2)
    ck("every trade has an exit reason",
       all(t.get("exit_reason") for t in s["trades_detail"]))
    ck("every trade has a numeric R",
       all(isinstance(t["r"], float) for t in s["trades_detail"]))
    ck("rejections recorded", len(s["rejections"]) > 0)
    # With TP1 banking tp1_percent at tp1_rr, the best trade the manager can
    # produce is the blend of that slice and the remainder running to Tp2RR.
    # For the defaults that is 0.5*1.0 + 0.5*2.5 = 1.75R, not 2.5R - a useful
    # sanity check that the partial-close weighting is right.
    d = Cfg()
    max_r = (d.tp1_percent / 100.0) * d.tp1_rr + (1 - d.tp1_percent / 100.0) * d.tp2_rr
    ck(f"no trade exceeds the blended max ({max_r:.2f}R)",
       all(t["r"] <= max_r + 1e-9 for t in s["trades_detail"]))
    ck("no trade is worse than -1R", all(t["r"] >= -1.0 - 1e-9 for t in s["trades_detail"]))

    # --- tick-path engine -------------------------------------------------
    # One bar prints BOTH the stop and TP1. The bar-level engine above cannot
    # tell these apart; the tick engine must, and the two paths must disagree.
    cfgT = Cfg(tp1_rr=1.0, tp1_percent=50.0, use_atr_trail=False, min_hold_bars=1,
               break_even_offset_pts=5.0)
    tbars = [bar(100, 101, 99, 100)] * 3 + [bar(100, 110, 94, 100)]
    tz = Zone("FVG", +1, 110.0, 100.0, 0, 4.0)
    tg = {"entry": 100.0, "sl": 95.0, "tp": 112.5, "risk_pts": 500.0}
    sH = Sim(cfgT, list(tbars)); sH._atr_series()
    sL = Sim(cfgT, list(tbars)); sL._atr_series()
    tH = sH.simulate_trade_ticks(2, tz, tg, 0.01, "high_first")
    tL = sL.simulate_trade_ticks(2, tz, tg, 0.01, "low_first")
    ck("tick engine separates high-first from low-first",
       tH and tL and abs(tH["r"] - tL["r"]) > 1e-9,
       f"{tH['r']:+.2f} vs {tL['r']:+.2f}")
    ck("high-first banks TP1 then locks the runner at breakeven",
       tH and tH["exit_reason"] == "BE_OR_TRAIL")
    ck("low-first is stopped out for the full -1R",
       tL and tL["exit_reason"] == "STOP_LOSS" and abs(tL["r"] + 1.0) < 1e-9)
    ck("unknown tick path yields no trade",
       sH.simulate_trade_ticks(2, tz, tg, 0.01, "sideways") is None)
    ck("tick_path rejects an unknown order", tick_path(bar(1, 2, 0.5, 1.5), "x") == [])

    # A bar that only threatens one side must give both paths the same answer,
    # otherwise the engine is inventing disagreement out of nothing.
    ubars = [bar(100, 101, 99, 100)] * 3 + [bar(100, 102, 99, 101), bar(101, 103, 100, 102)]
    sA = Sim(cfgT, list(ubars)); sA._atr_series()
    sB = Sim(cfgT, list(ubars)); sB._atr_series()
    tA = sA.simulate_trade_ticks(2, tz, tg, 0.01, "high_first")
    tB = sB.simulate_trade_ticks(2, tz, tg, 0.01, "low_first")
    ck("unambiguous bar -> both paths agree",
       tA["exit_reason"] == tB["exit_reason"] and abs(tA["r"] - tB["r"]) < 1e-9)

    # The tick engine must not contradict the two hard bounds the bar engine
    # respects: never better than the blended target, never worse than -1R.
    sT = Sim(Cfg(trend_mode="EMA"), bars2)
    st = sT.run(warmup=120, ticks="high_first")
    ck("tick replay produced trades", st["trades"] > 0)
    ck("tick replay respects the blended max",
       all(t["r"] <= max_r + 1e-9 for t in st["trades_detail"]))
    ck("tick replay respects -1R", all(t["r"] >= -1.0 - 1e-9 for t in st["trades_detail"]))
    ck("tick trades are tagged with their path",
       all(t.get("path") in ("high_first", "low_first") for t in st["trades_detail"]))

    bad = [n for n, ok in checks if not ok]
    for n, ok in checks:
        print(f"   {'PASS' if ok else 'FAIL'}  {n}")
    if bad:
        print(f"\nSELFTEST FAILED: {bad}")
        return 1
    print(f"\nSELFTEST PASSED ({len(checks)} checks)")
    return 0


# ---------------------------------------------------------------- main

def report_ticks(bars, args, stream=sys.stdout):
    """Run the same entries through both intra-bar paths and compare.

    This is the closest thing to answering "does the EA hold up on real-time
    updates" without a tick feed. OHLC data does not record the order prices
    were touched in, so any bar that threatens the stop and a target at once
    has two defensible outcomes. Walking the pessimistic path and the optimistic
    path brackets what the live EA could have done: the wider the gap, the more
    of the reported edge depends on luck inside a bar rather than the setup.
    """
    p = lambda *a: print(*a, file=stream)
    cfg = lambda: Cfg(trend_mode=args.trend, entry_model=args.entry)
    hi = Sim(cfg(), bars).run(warmup=120, ticks="high_first")
    lo = Sim(cfg(), bars).run(warmup=120, ticks="low_first")
    hmap = {t["bar"]: t for t in hi["trades_detail"]}
    lmap = {t["bar"]: t for t in lo["trades_detail"]}
    common = sorted(set(hmap) & set(lmap))
    flips = [k for k in common
             if hmap[k]["exit_reason"] != lmap[k]["exit_reason"]
             or abs(hmap[k]["r"] - lmap[k]["r"]) > 1e-9]
    amb = [k for k in common if hmap[k]["ambiguous"] or lmap[k]["ambiguous"]]

    p("=" * 66)
    p("Real-time (intra-bar path) sensitivity")
    p("=" * 66)
    p(f"trades replayed      {len(common)}")
    p(f"outcome depends on path  {len(flips)}  "
      f"({round(100.0 * len(flips) / len(common), 1) if common else 0.0}%)")
    p(f"touched an ambiguous bar {len(amb)}  "
      f"({round(100.0 * len(amb) / len(common), 1) if common else 0.0}%)"
      "  [stop and target in one bar]")
    p("")
    for label, s in (("path A: high-first", hi), ("path B: low-first", lo)):
        p(f"{label:<34} expectancy {s['expectancy_r']:+.3f} R   "
          f"total {s['total_r']:+.2f} R   PF {s['profit_factor']}")
    spread = abs(hi["expectancy_r"] - lo["expectancy_r"])
    p("")
    p(f"expectancy spread      {spread:.3f} R per trade")
    p("(neither path is the pessimistic one: hitting TP1 early also ratchets the")
    p(" stop, so which path wins depends on where price goes after that.)")
    if not common:
        p("no trades to compare")
    elif spread <= 0.05:
        p("Reading: the edge barely depends on what happens inside a bar. The "
          "reported expectancy should survive live tick-by-tick execution.")
    elif spread <= 0.15:
        p("Reading: a modest part of the edge depends on intra-bar luck. Expect "
          "live results to sit somewhere between these two lines, not above them.")
    else:
        p("Reading: the edge is fragile. Which side of the bar moves first decides "
          "a large share of the outcome, and no backtest on OHLC data can tell "
          "you which one you will get.")
    if flips:
        p("")
        p("path-dependent trades (worst 10 by |R difference|):")
        worst = sorted(flips, key=lambda k: -abs(hmap[k]["r"] - lmap[k]["r"]))[:10]
        for k in worst:
            a, b = hmap[k], lmap[k]
            p(f"   bar {k:>6}  {a['dir']:<4} {a['type']:<10} "
              f"high-first {a['r']:+.2f}R {a['exit_reason']:<12} "
              f"| low-first {b['r']:+.2f}R {b['exit_reason']}")
    p("")
    p("NOTE: two paths bracket reality; the true tick sequence is one of the many "
      "in between. A low flip rate is reassurance, not proof.")
    return {"trades": len(common), "flips": len(flips), "ambiguous": len(amb),
            "expectancy_spread_r": round(spread, 3)}


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Reference model of HEX-FVG-Breaker.mq4 (not a backtester).")
    ap.add_argument("--selftest", action="store_true", help="run the unit checks")
    ap.add_argument("--demo", action="store_true", help="replay synthetic gold-like data")
    ap.add_argument("--csv", help="replay an OHLC csv: time,open,high,low,close")
    ap.add_argument("--seed", type=int, default=7, help="synthetic data seed")
    ap.add_argument("--bars", type=int, default=6000, help="synthetic bar count")
    ap.add_argument("--trend", default="EMA", choices=["EMA", "STRUCTURE", "BOTH"])
    ap.add_argument("--entry", default="LIMIT", choices=["LIMIT", "TRIGGER"])
    ap.add_argument("--verbose", action="store_true", help="print every simulated trade")
    ap.add_argument("--ticks", action="store_true",
                    help="replay every trade through both intra-bar price paths "
                         "and report how often the outcome depends on tick order")
    args = ap.parse_args(argv)

    if args.selftest:
        return run_selftest()
    if not (args.demo or args.csv or args.ticks):
        ap.print_help()
        return 0

    bars = load_csv_bars(args.csv) if args.csv else synth_bars(args.bars, seed=args.seed)
    if len(bars) < 200:
        print(f"only {len(bars)} bars loaded - need at least 200")
        return 2
    src = args.csv if args.csv else f"synthetic (seed {args.seed})"
    print(f"source: {src}")
    if args.ticks:
        report_ticks(bars, args)
        return 0
    sim = Sim(Cfg(trend_mode=args.trend, entry_model=args.entry), bars)
    s = sim.run(warmup=120)
    print_summary(s)
    if args.verbose:
        for t in s["trades_detail"]:
            print(f"   bar {t['bar']:>6}  {t['dir']:<4} {t['type']:<10} "
                  f"entry={t['entry']:.2f} sl={t['sl']:.2f} lots={t['lots']:.2f} "
                  f"r={t['r']:+.2f}  {t['exit_reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())


