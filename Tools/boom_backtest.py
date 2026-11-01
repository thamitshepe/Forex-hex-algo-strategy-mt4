#!/usr/bin/env python3
"""Backtest of the HEX-BoomRider strategies on a Volatility Boom 400 model.

Deriv documents Boom 400 as: volatility of 20%, on average one spike every
400 ticks. On Boom indices the inter-spike drift is DOWN and the spike is UP,
which is why shorts against the drift win often and longs live off spikes.
This models exactly that, at one tick per second (a Boom 400 M15 bar holds
roughly 900 ticks, as on the real chart), and runs the EA's two candidate
modes over it:

  mode 0  drift-short : sell after a completed up-spike, stop above the spike
                        high, take profit into the drift.
  mode 1  spike-long  : stay long, take profit at the spike target, stop below
                        the drift budget.

The point is not a pretty equity curve - it is to find which mode survives
the spread, what win rate / profit factor each mode really has, and how often
a $10 bankroll (risked at RiskPct per trade) is still alive after N ticks.

Usage:  python3 Tools/boom_backtest.py
No third-party packages: pure stdlib, so it runs anywhere.
"""
import math
import random
import statistics

# --------------------------------------------------------------------------
# Market model, calibrated to Boom 400's stated behaviour and the live chart.
# --------------------------------------------------------------------------
PRICE0 = 14000.0          # index level, mid-14000s on the live chart
TICKS_PER_SPIKE = 400.0   # "on average 1 spike every 400 ticks"
VOL_ANNUAL = 0.20         # "volatility of 20%"

# One tick per second. Per-tick sigma from the annual vol (24/7 market):
# sigma_tick = price * VOL_ANNUAL / sqrt(365*24*3600) ~ price * 3.4e-6.
# Inter-spike drift: Boom indices bleed down between spikes. Calibrated so the
# drift across one average spike interval (400 ticks) is a fraction of the
# mean spike - the net long-run drift of a Boom index is mildly positive.
DRIFT_PER_CYCLE = 0.0010   # -0.10% per ~400 ticks of down-drift
SPIKE_MEAN = 0.0025        # +0.25% mean spike
SPIKE_STD = 0.0010         # spike size variation
SPREAD_PCT = 0.00012       # ~1.7 points round trip on 14400 (Market Watch ~1-3)
SLIP = 0.0008              # a spike that gaps through the stop fills 0.08% worse
SPIKE_PROB = 1.0 / TICKS_PER_SPIKE

SIGMA_TICK = PRICE0 * VOL_ANNUAL / math.sqrt(365 * 24 * 3600)  # ~0.0032


class Boom400:
    """Tick generator: down-drift with upward spikes, memoryless in time."""

    def __init__(self, price=PRICE0, rng=None):
        self.price = price
        self.rng = rng or random.Random()
        self.last_spike_high = price

    def tick(self):
        p = self.price
        if self.rng.random() < SPIKE_PROB:
            jump = p * max(0.0002, self.rng.gauss(SPIKE_MEAN, SPIKE_STD))
            p += jump
            self.last_spike_high = p
        else:
            p -= DRIFT_PER_CYCLE * p / TICKS_PER_SPIKE  # downward bleed
            p += self.rng.gauss(0.0, SIGMA_TICK)
        self.price = p
        return p

def run_backtest(mode, ticks=400_000, bankroll=10.0, risk_pct=0.15,
                 tp_pct=0.0022, sl_pct=0.0040, min_lot=0.2,
                 point_value=0.01, seed=1):
    """One path. Returns summary stats.

    Position sizing mirrors the EA: lots are chosen so that hitting the stop
    loses risk_pct of the bankroll, then clamped to the broker's minimum lot.
    point_value is the account value of one 0.01 price step at 1.0 lot
    (contract size 1 on Deriv synthetics).
    """
    rng = random.Random(seed)
    mkt = Boom400(rng=rng)
    equity = bankroll
    peak = bankroll
    max_dd = 0.0
    wins = losses = 0
    gross_win = gross_loss = 0.0
    blown_at = None

    pos = None  # (dir, entry, sl, tp, lots)
    spike_high = mkt.price
    spread = SPREAD_PCT * mkt.price
    slip = SLIP * mkt.price

    for i in range(ticks):
        price = mkt.tick()
        if mkt.last_spike_high > spike_high:
            spike_high = mkt.last_spike_high

        if pos is not None:
            d, entry, sl, tp, lots = pos
            if d < 0 and price >= sl:
                # a spike gaps THROUGH the stop: fill is worse than the level
                fill = sl + slip if price > sl else sl
                equity -= (fill - entry) * lots * point_value
                gross_loss += (fill - entry) * lots * point_value
                losses += 1
                pos = None
            elif d < 0 and price <= tp:
                equity += (entry - tp) * lots * point_value
                gross_win += (entry - tp) * lots * point_value
                wins += 1
                pos = None
            elif d > 0 and price <= sl:
                fill = sl - slip if price < sl else sl
                equity -= (entry - fill) * lots * point_value
                gross_loss += (entry - fill) * lots * point_value
                losses += 1
                pos = None
            elif d > 0 and price >= tp:
                equity += (tp - entry) * lots * point_value
                gross_win += (tp - entry) * lots * point_value
                wins += 1
                pos = None

        if equity <= 0:
            blown_at = i
            break

        if pos is None:
            d = -1 if mode == 0 else 1
            if d < 0:
                entry = price - spread / 2.0
                sl = spike_high + 0.0008 * price      # above the recent spike
                tp = entry - (sl - entry) * 0.6       # 0.6R into the drift
            else:
                entry = price + spread / 2.0
                sl = entry - sl_pct * price
                tp = entry + tp_pct * price
            stop_dist = abs(entry - sl)
            risk_amount = equity * risk_pct
            lots = risk_amount / max(stop_dist * point_value, 1e-9)
            lots = max(min_lot, math.floor(lots / min_lot) * min_lot)
            pos = (d, entry, sl, tp, lots)
            spike_high = price

        peak = max(peak, equity)
        max_dd = max(max_dd, peak - equity)

    trades = wins + losses
    return {
        "mode": mode, "seed": seed,
        "final": round(equity, 2),
        "multiple": round(equity / bankroll, 2),
        "trades": trades,
        "win_rate": round(wins / max(trades, 1), 3),
        "pf": round(gross_win / gross_loss, 3) if gross_loss > 0 else 99.0,
        "max_dd": round(max_dd, 2),
        "blown_at_tick": blown_at,
    }


def sweep():
    print(f"Boom 400 model: price~{PRICE0:.0f}, spike {SPIKE_MEAN*100:.2f}% avg "
          f"every ~{TICKS_PER_SPIKE:.0f} ticks, drift -{DRIFT_PER_CYCLE*100:.2f}%/cycle, "
          f"spread {SPREAD_PCT*100:.4f}% round trip")
    print()
    for mode, name in ((0, "drift-short"), (1, "spike-long")):
        for risk in (0.10, 0.20, 0.30):
            res = [run_backtest(mode, ticks=200_000, risk_pct=risk, seed=s)
                   for s in range(8)]
            alive = sum(1 for r in res if r["blown_at_tick"] is None)
            mult = [r["multiple"] for r in res]
            wr = statistics.mean(r["win_rate"] for r in res)
            pf = statistics.mean(r["pf"] for r in res)
            blow = [r["blown_at_tick"] for r in res if r["blown_at_tick"] is not None]
            print(f"mode={name:11s} risk={risk*100:4.0f}%  "
                  f"median x{statistics.median(mult):6.2f}  alive {alive}/8  "
                  f"blown@{blow or '-'}  WR~{wr:.2f}  PF~{pf:.2f}")


def grid():
    """Spike-long across weaker/stronger market assumptions: the strategy must
    be judged on whether it survives when the market is less generous, not on
    the happy-path calibration."""
    global SPIKE_MEAN, DRIFT_PER_CYCLE
    print()
    print("spike-long sensitivity (risk 20%, 8 paths x 150k ticks each):")
    print(f"{'spike':>7} {'drift':>7} {'tp':>7} {'sl':>7}   {'median x':>10} {'alive':>6} {'WR':>5} {'PF':>7}")
    for spike in (0.0015, 0.0025):
        for drift in (0.0005, 0.0010):
            SPIKE_MEAN, DRIFT_PER_CYCLE = spike, drift
            for tp, sl in ((0.0010, 0.0030), (0.0015, 0.0040), (0.0020, 0.0050)):
                res = [run_backtest(1, ticks=150_000, risk_pct=0.20,
                                    tp_pct=tp, sl_pct=sl, seed=s)
                       for s in range(8)]
                alive = sum(1 for r in res if r["blown_at_tick"] is None)
                mult = statistics.median(r["multiple"] for r in res)
                wr = statistics.mean(r["win_rate"] for r in res)
                pf = statistics.mean(min(r["pf"], 999.0) for r in res)
                print(f"{spike*100:6.2f}% {drift*100:6.2f}% {tp*100:6.2f}% {sl*100:6.2f}%   "
                      f"{mult:10.2f} {alive:5d}/8 {wr:5.2f} {pf:7.2f}")


if __name__ == "__main__":
    sweep()
    grid()


