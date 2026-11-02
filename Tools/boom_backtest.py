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

def run_backtest(mode, ticks=400_000, bankroll=20.0, risk_pct=0.20,
                 tp_pct=0.0025, sl_pct=0.0030, min_lot=0.1,
                 point_value=0.01, seed=1):
    """One path. Returns summary stats.

    Position sizing mirrors the EA: lots are chosen so that hitting the stop
    loses risk_pct of the bankroll, then clamped to the broker's minimum lot.
    point_value is the account value of one 0.01 price step at 1.0 lot, so one
    whole price unit at 1.0 lot is point_value / 0.01 = $1.00 (cross-checked
    against the EA's own log: 0.40% of an ask of 15122 at 0.10 lots = $6.05).
    Applying point_value directly to a price *difference* was a 100x scale bug:
    the equity curve, the multiple and the "blown" flag were all meaningless.
    """
    money_per_unit = point_value / 0.01
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
                equity -= (fill - entry) * lots * money_per_unit
                gross_loss += (fill - entry) * lots * money_per_unit
                losses += 1
                pos = None
            elif d < 0 and price <= tp:
                equity += (entry - tp) * lots * money_per_unit
                gross_win += (entry - tp) * lots * money_per_unit
                wins += 1
                pos = None
            elif d > 0 and price <= sl:
                fill = sl - slip if price < sl else sl
                equity -= (entry - fill) * lots * money_per_unit
                gross_loss += (entry - fill) * lots * money_per_unit
                losses += 1
                pos = None
            elif d > 0 and price >= tp:
                equity += (tp - entry) * lots * money_per_unit
                gross_win += (tp - entry) * lots * money_per_unit
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
            lots = risk_amount / max(stop_dist * money_per_unit, 1e-9)
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

def run_ladder(seed=1, ticks=100_000, bankroll=20.0, base_lots=0.1,
               tp_pct=0.0025, sl_pct=0.0030,
               be_at=0.0008, be_buf=0.0002,
               bank_at=0.0, bank_frac=0.5,
               add_at=0.0010, max_adds=3, add_gap=0.0010, add_risk=0.5,
               max_lots=0.4, trail=0.0, trail_start=0.0, max_risk=0.0, gate_k=0,
               point_value=0.01):
    """The managed long: break-even, then a pyramided ladder funded by profit.

    Applied on every tick, in this order:
      1. base trade: the tested bracket, the only exposure that can lose at all;
      2. at +be_at the ladder stop moves to entry + be_buf, so from there on the
         episode is flat-to-up minus stop slippage;
      3. every +add_at of further gain, up to max_adds, one more base_lots is
         added and the *shared* ladder stop steps up to bid - add_gap, i.e. each
         add raises the floor for the whole ladder and locks profit in;
      4. the add is sized so its risk is add_risk of what the episode has already
         booked, so adds can only spend money the trade itself made;
      5. max_lots caps total exposure;
      6. a trail (if set) replaces step 3's stop with bid - trail past
         trail_start, letting a big spike run.
    Fills are the model's: entry at ask, stops slipped through on a spike.
    """
    rng = random.Random(seed)
    mkt = Boom400(rng=rng)
    money = point_value / 0.01
    pl = 0.0
    pos = []                      # [entry, stop, target, lots]
    base_entry = base_tick = None
    adds = 0
    total_adds = 0
    be_done = False
    bank_done = False
    wins = losses = 0
    gross_win = gross_loss = 0.0
    episodes, episode = [], 0.0
    blown_at = None

    base_win_dollars = tp_pct * 15122.0 * base_lots

    def book(entry, exit_px, lots):
        nonlocal pl, episode, wins, losses, gross_win, gross_loss
        pnl = (exit_px - entry) * lots * money
        pl += pnl
        episode += pnl
        if pnl >= 0:
            wins += 1
            gross_win += pnl
        else:
            losses += 1
            gross_loss += -pnl

    for i in range(ticks):
        price = mkt.tick()
        slip = SLIP * price
        bid = price - SPREAD_PCT * price / 2.0

        keep = []
        for entry, stop, target, lots in pos:
            if stop > 0 and price <= stop:
                book(entry, stop - slip if price < stop else stop, lots)
            elif target > 0 and price >= target:
                book(entry, target, lots)
            else:
                keep.append([entry, stop, target, lots])
        pos = keep

        if not pos and base_entry is not None:
            episodes.append(episode)
            episode = 0.0
            base_entry = base_tick = None
            adds = 0
            be_done = False
            bank_done = False

        if pl <= -bankroll:
            blown_at = i
            break

        if pos and base_entry is not None:
            pct = (price - base_entry) / base_entry

            # 2. bank part of the trade at the validated target level, and let the
            #    remainder ride: the routine spike pays out, the tail stays open.
            #    (Banking at an arbitrary TP1 below the target is dead code here:
            #    spikes jump, so the price never rests in between.)
            if bank_at > 0.0 and not bank_done and pct >= bank_at:
                left = math.floor((sum(p[3] for p in pos) * bank_frac) / 0.10) * 0.10
                new = []
                for entry, stop, target, lots in pos:
                    take = min(lots, left)
                    if take > 0:
                        book(entry, base_entry * (1 + bank_at), take)
                        left -= take
                        lots -= take
                        if lots <= 0:
                            continue
                    new.append([entry, stop, 0.0, lots])
                pos = new
                bank_done = True
                if pos:
                    for p in pos:
                        p[1] = max(p[1], base_entry * (1 + be_buf))
                    be_done = True
                if not pos:
                    continue

            if be_at > 0.0 and not be_done and pct >= be_at:    # 2. protect
                for p in pos:
                    p[1] = max(p[1], base_entry + base_entry * be_buf)
                be_done = True

            if trail > 0.0 and pct >= trail_start:           # 6. let it run
                for p in pos:
                    p[1] = max(p[1], bid - price * trail)

            if adds < max_adds and pct >= add_at * (adds + 1):   # 3./4./5.
                paying = (gate_k <= 0 or sum(episodes[-gate_k:]) > 0.0)
                stop = max(max(p[1] for p in pos), bid - price * add_gap)
                if paying and stop < bid:
                    float_pl = sum((bid - e) * l * money for e, s, t, l in pos)
                    budget = add_risk * max(episode + float_pl, 0.0)
                    lots = math.floor((budget / ((bid - stop) * money)) / 0.10) * 0.10
                    lots = max(0.0, min(lots, max_lots - sum(p[3] for p in pos)))
                    # what every leg would lose if the shared stop were hit now
                    risk_now = sum((e - s) * l * money for e, s, t, l in pos
                                   if s > 0 and e > s)
                    if max_risk > 0.0 and risk_now + lots * (bid - stop) * money > max_risk:
                        lots = 0.0
                    if lots >= 0.10:
                        for p in pos:                        # one ladder, one stop
                            p[1] = max(p[1], stop)
                        pos.append([bid, stop, 0.0, lots])
                        adds += 1
                        total_adds += 1

        if not pos:
            entry = price + SPREAD_PCT * price / 2.0
            pos = [[entry, entry - entry * sl_pct, entry + entry * tp_pct, base_lots]]
            base_entry, base_tick = entry, i

    return {
        "per_h": round(pl / (ticks / 3600.0), 2),
        "trades": wins + losses,
        "wr": round(wins / max(wins + losses, 1), 3),
        "avg_win": round(gross_win / max(wins, 1), 2),
        "avg_loss": round(gross_loss / max(losses, 1), 2),
        "pf": round(gross_win / gross_loss, 2) if gross_loss > 0 else 99.0,
        "blown": blown_at,
        "eps": len(episodes),
        "adds": total_adds,
        "x2": sum(1 for e in episodes if e >= 2 * base_win_dollars),
        "x3": sum(1 for e in episodes if e >= 3 * base_win_dollars),
        "x4": sum(1 for e in episodes if e >= 4 * base_win_dollars),
        "x10": sum(1 for e in episodes if e >= 10 * base_win_dollars),
        "worst": round(min(episodes), 2) if episodes else 0.0,
        "best": round(max(episodes), 2) if episodes else 0.0,
    }



def ladder():
    """Base vs managed ladder, same ticks. The parameters shipped in
    MQL5/Presets/HEX-BoomRider.set come from this table: the ladder that spends
    only booked profit, shares one stop, and stays inside max_lots."""
    print()
    print("management comparison (100k ticks x 4 seeds, $20 bankroll, 0.10 lots):")
    print(f"{'config':>34} {'$/h':>7} {'WR':>5} {'avgW':>6} {'avgL':>6} {'PF':>6} "
          f"{'x2':>4} {'x3':>4} {'x4':>4} {'x10':>4} {'best':>7} {'blown':>6}")
    cases = {
        "base only (TP 0.25 / SL 0.30)": dict(be_at=0.0, max_adds=0),
        "ladder, no risk cap": dict(be_at=0.0005, be_buf=0.0005, trail=0.0030,
                                    trail_start=0.0040, add_at=0.0020, add_gap=0.0060,
                                    add_risk=1.0, max_adds=3, max_lots=0.4),
        "ladder + 30% risk cap (SHIPPED)": dict(be_at=0.0005, be_buf=0.0005, trail=0.0030,
                                                trail_start=0.0040, add_at=0.0020,
                                                add_gap=0.0060, add_risk=1.0, max_adds=3,
                                                max_lots=0.4, max_risk=6.0),
        "ladder + 20% risk cap": dict(be_at=0.0005, be_buf=0.0005, trail=0.0030,
                                      trail_start=0.0040, add_at=0.0020, add_gap=0.0060,
                                      add_risk=1.0, max_adds=3, max_lots=0.4, max_risk=4.0),
        "half the add risk (never fires)": dict(be_at=0.0005, be_buf=0.0005, trail=0.0030,
                                                trail_start=0.0040, add_at=0.0020,
                                                add_gap=0.0060, add_risk=0.5, max_adds=3,
                                                max_lots=0.4, max_risk=6.0),
        "shipped + regime gate on 3 eps": dict(be_at=0.0005, be_buf=0.0005, trail=0.0030,
                                               trail_start=0.0040, add_at=0.0020,
                                               add_gap=0.0060, add_risk=1.0, max_adds=3,
                                               max_lots=0.4, max_risk=6.0, gate_k=3),
    }
    for name, kw in cases.items():
        res = [run_ladder(seed=s, **kw) for s in range(4)]
        mean = lambda k: sum(r[k] for r in res) / len(res)
        blown = sum(1 for r in res if r["blown"] is not None)
        print(f"{name:>34} {mean('per_h'):7.2f} {mean('wr'):5.3f} {mean('avg_win'):6.2f} "
              f"{mean('avg_loss'):6.2f} {mean('pf'):6.2f} {mean('x2'):4.0f} {mean('x3'):4.0f} "
              f"{mean('x4'):4.0f} {mean('x10'):4.0f} {mean('best'):7.2f} {blown:4d}/4")


if __name__ == "__main__":
    sweep()
    grid()
    ladder()


