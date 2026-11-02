//+------------------------------------------------------------------+
//| HEX-BoomRider.mq5                                                |
//| Volatility Boom 400 spike-rider for Deriv demo.                  |
//|                                                                  |
//| Strategy (backtested in Tools/boom_backtest.py):                 |
//|   - Long-only: on Boom indices the spike is UP, so we never      |
//|     fight it. Always in the market long with broker-side         |
//|     TP (+TakeProfitPct of entry) and SL (-StopLossPct).          |
//|     Re-enters as soon as flat.                                   |
//|   - Sizing: RiskPct of the EFFECTIVE bankroll, which is          |
//|     Equity - BaselineEquity (default 9990 -> $10 of headroom     |
//|     on a straight 10k demo, no deposit needed).                  |
//|   - Blow guard: Equity <= BaselineEquity  =>  the $10 is gone:   |
//|     Alert + mobile push + blown marker file, close everything,   |
//|     stop trading. Reset the demo account and delete the marker   |
//|     (or bump BaselineEquity) to resume.                          |
//+------------------------------------------------------------------+
#property copyright "HEX"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input double InpBaselineEquity = 9980.0;   // Blow line: equity at/below this = blown ($20 of headroom)
input double InpRiskPct        = 20.0;     // Risk % of effective bankroll per trade
input double InpMaxRiskPct     = 50.0;     // Never risk more than this % of the bankroll (min-lot guard)
// Why this bracket and this cap - measured, not guessed (Tools/boom_backtest.py,
// 200k ticks x 4 model calibrations, 0.10 lots at an ask of ~15122):
//   SL 0.30% -> a loss costs $4.54 = 22.7% of the $20 headroom, so FOUR losses
//   fit before the halt (0.40% cost $6.05: only three fit) and the 50% cap ($10)
//   still admits one minimum lot after the index rises ~2.2x.
//   TP 0.25% -> break-even win rate 54.5%, against 72.7% for the 0.15/0.40
//   bracket the first preset used (which paid $2.27 a win for a $6.05 loss).
input double InpTakeProfitPct  = 0.25;     // TP: % above entry (measured target, base leg only)
input double InpStopLossPct    = 0.30;     // SL: % below entry
// Management. A stop placed BETWEEN the entry and the target is not a stop, it
// is a take-profit: on this symbol the target is only ever reached by a SPIKE
// (a single-tick jump), while any intermediate level is reached by ordinary
// drift - and the drift between spikes pulls DOWN, so it gets there first.
// Live, 2026-11-02, the shipped build proved it: the +0.05% break-even floor
// sat AT the price the moment it armed, so every winner exited at +0.05%,
// no winner ever reached the 0.25% target, not one add fired, and the day read
// 4 wins / 4 losses, -$14.59 in 75 minutes. A 0.05% win against a 0.30% loss
// is zero EV before spread, so it can only bleed. Two rules came out of it:
//   * the break-even floor may only arm AFTER the target has been banked
//     (episodeBanked), so it can never pre-empt the target it guards; and
//   * no submitted stop may ever sit closer than InpMinStopGapPct to the price,
//     enforced in ApplyLadderStop for every caller.
// With those, what pays is the opposite of an early stop: keep the base target,
// and give the spike somewhere to go - add legs while it is happening, funded
// strictly out of profit, all sharing one stop that only ever moves up.
// Harness, 100k ticks x 4 seeds, live-calibrated model, $20 headroom: the base
// engine (bank 0.25% / SL 0.30%) runs $15.93/h, WR 0.776, PF 2.79, median win
// exactly +0.25% (the target), 0/4 blown. The ladder cannot do anything at $20
// of headroom: one add at the 0.10 minimum lot needs ~$4.50 of this episode's
// profit already in hand, which the base lot only generates around $68 of
// headroom. Until then the add is skipped, and it now says so in the log.
input double InpLockInPct      = 0.05;     // Once the target is BANKED, the stop sits this % above entry
input double InpMinStopGapPct  = 0.15;     // Never place the shared stop closer than this % to the price
input double InpBackstopTPPct  = 1.00;     // Distant broker TP, so a position is never target-less
input double InpTrailPct       = 0.30;     // Trail the shared stop this % behind the price
input double InpTrailStartPct  = 0.40;     // ... once the trade is this % in profit
input int    InpMaxAdds        = 3;        // Pyramid: max adds per trade
input double InpAddAtPct       = 0.20;     // Pyramid: first add at this % in profit, then every...
input double InpAddRiskPct     = 100.0;    // ... risking at most this % of the profit already made
input double InpMaxLadderLots  = 0.40;     // Hard cap on ladder exposure
input double InpMaxLadderRiskPct = 30.0;   // ... and its total stop risk, % of headroom (3-loss budget)
input double InpMaxSpreadPct   = 0.03;     // Skip entries when spread wider than this %
input long   InpMagic          = 400400;   // Magic number
input int    InpHeartbeatSec   = 60;       // Heartbeat file write interval
input int    InpSkipLogSec     = 60;       // Repeat the same SKIP line at most this often (0 = every tick)
input string InpLogDir         = "HEX-Logs";
input string InpNotifyUrl      = "";       // Push target: ntfy URL, empty = MetaQuotes ID push only
input bool   InpNotifyTest     = true;     // Send a hello at init so the pipe is proven early

CTrade   trade;
bool     blown         = false;
datetime lastHeartbeat = 0;
datetime lastDay       = 0;
string   csvName       = "";
int      tradesToday   = 0;
double   riskToday     = 0.0;
string   lastSkipKey   = "";
datetime lastSkipAt    = 0;

// --- the current episode: one base trade plus the adds it has earned -------
double   episodeBase    = 0.0;    // base entry: the reference for every % below
double   episodeBaseLots = 0.0;   // volume of the base leg (what the target banks)
double   episodeBooked  = 0.0;    // money this episode has already banked
bool     episodeBanked  = false;  // the base leg has taken its target
int      episodeAdds    = 0;      // adds placed so far this episode
double   ladderStopLast = 0.0;    // last stop we pushed (log a move only once)

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   blown = BlownMarkerExists();
   MqlDateTime dt; TimeCurrent(dt);
   csvName = StringFormat("%s/HEX-BoomRider-%04d%02d%02d.csv",
                          InpLogDir, dt.year, dt.mon, dt.day);
   FolderCreate(InpLogDir);
   Log("INIT", StringFormat("baseline=%.2f risk=%.1f%% tp=%.2f%% sl=%.2f%% blown=%d",
       InpBaselineEquity, InpRiskPct, InpTakeProfitPct, InpStopLossPct, blown));
   Log("INIT", StringFormat("manage: bank %.2f%%; floor %+.2f%% ONLY after the bank; min stop "
       "gap %.2f%% of price; trail=%.2f%% from %.2f%%; adds<=%d every %.2f%% risking %.0f%% "
       "of profit; ladder<=%.2f lots / %.0f%% of headroom",
       InpTakeProfitPct, InpLockInPct, InpMinStopGapPct, InpTrailPct, InpTrailStartPct,
       InpMaxAdds, InpAddAtPct, InpAddRiskPct, InpMaxLadderLots, InpMaxLadderRiskPct));
   // The broker's own floor on this symbol, logged once: a bracket tighter than
   // the stops level is refused with "Invalid stops", and until now this EA had
   // never placed an order, so we had no idea what the floor was.
   Log("INIT", StringFormat("broker: stops=%d freeze=%d points, vol min=%.2f max=%.2f step=%.2f, "
       "tick value=%s size=%s, digits=%d",
       (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
       (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
       SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
       SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
       SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
       DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5),
       DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 5),
       (int)_Digits));
   NotifyAnnounce();
   if(InpNotifyTest)
      Notify("HELLO", StringFormat("HEX-BoomRider online on %s, equity %.2f. "
              "If you read this, notifications work.", _Symbol,
              AccountInfoDouble(ACCOUNT_EQUITY)));
   WriteHeartbeat();
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
void OnTick()
{
   // --- heartbeat (lease/monitor evidence for the deploy side) ---
   if(TimeCurrent() - lastHeartbeat >= InpHeartbeatSec)
      WriteHeartbeat();

   // --- blow guard: the $10 of headroom is gone ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!blown && equity <= InpBaselineEquity)
   {
      blown = true;
      CloseEverything();
      string msg = StringFormat("BOOM RIDER BLOWN: equity %.2f <= baseline %.2f. "
                                "Account is done - RESET THE DEMO ACCOUNT.",
                                equity, InpBaselineEquity);
      Alert(msg);
      Notify("BLOWN", msg);
      WriteBlownMarker(msg);
   }
   if(blown)
      return;

   // --- roll CSV at midnight, reset daily counters ---
   MqlDateTime dt; TimeCurrent(dt);
   if(dt.day != TimeDay(lastDay))
   {
      csvName = StringFormat("%s/HEX-BoomRider-%04d%02d%02d.csv",
                             InpLogDir, dt.year, dt.mon, dt.day);
      tradesToday = 0;
      riskToday   = 0.0;
      lastDay     = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   }

   // --- effective bankroll off the baseline ---
   double effective = equity - InpBaselineEquity;
   if(effective <= 0.0)
      return;

   // --- manage what is open before deciding anything: bank, protect, trail, pyramid
   ManageLadder(effective);

   // --- one episode at a time; enter long only when flat
   if(HasOpenPosition())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // No quotes yet - right after a login, or while the terminal re-scans access
   // points - and an entry priced off a zero ask would send a stop and a target
   // to nowhere. Wait for a real two-sided quote; never divide before checking.
   if(ask <= 0.0 || bid <= 0.0 || !MathIsValidNumber(ask) || !MathIsValidNumber(bid))
      return;
   double spreadPct = (ask - bid) / ask * 100.0;
   if(!MathIsValidNumber(spreadPct) || spreadPct > InpMaxSpreadPct)
   {
      LogSkip("spread", StringFormat("spread %.4f%% > max %.4f%%", spreadPct, InpMaxSpreadPct));
      return;
   }

   double slDist = ask * InpStopLossPct  / 100.0;
   // The base leg's *target* is taken by the EA (BankBaseLeg) so that the legs
   // the ladder adds can keep running past it; the broker TP is only a distant
   // backstop so a position is never target-less if this terminal dies.
   double tpDist = ask * InpBackstopTPPct / 100.0;
   // A bracket tighter than the broker's stops level is refused outright
   // ("Invalid stops"), so widen to the floor instead of failing the entry - and
   // wide the stop means the risk below is sized off the widened distance.
   double stopsDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopsDist > 0.0)
   {
      if(slDist < stopsDist)
         slDist = stopsDist;
      if(tpDist < stopsDist)
         tpDist = stopsDist;
   }
   double sl = NormalizeDouble(ask - slDist, _Digits);
   double tp = NormalizeDouble(ask + tpDist, _Digits);

   double lots = CalcLots(effective, slDist);
   if(lots <= 0.0)
   {
      LogSkip("no-size", "lot calc returned 0 (risk cap / broker limits) - see the line before");
      return;
   }

   if(trade.Buy(lots, _Symbol, 0.0, sl, tp,
                StringFormat("BoomRider risk=%.1f eff=%.2f", InpRiskPct, effective)))
   {
      tradesToday++;
      riskToday += effective * InpRiskPct / 100.0;
      // the fill is the reference for every % the management reasons about
      episodeBase     = trade.ResultPrice() > 0.0 ? trade.ResultPrice() : ask;
      episodeBaseLots = lots;
      episodeBooked   = 0.0;
      episodeBanked   = false;
      episodeAdds     = 0;
      ladderStopLast  = 0.0;
      Log("BUY", StringFormat("lots=%.2f entry~%.2f sl=%.2f backstop-tp=%.2f eff=%.2f",
          lots, ask, sl, tp, effective));
   }
   else
      Notify("ERROR", StringFormat("Buy failed: %d %s",
             trade.ResultRetcode(), trade.ResultRetcodeDescription()));
}

//+------------------------------------------------------------------+
//| OPEN/CLOSE notifications from actual deals - catches TP/SL       |
//| closes the EA did not issue itself.                              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
      Notify("OPEN", StringFormat("opened %.2f lots at %.2f on %s (eff %.2f)",
             HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
             HistoryDealGetDouble(trans.deal, DEAL_PRICE),
             _Symbol,
             AccountInfoDouble(ACCOUNT_EQUITY) - InpBaselineEquity));
   else if(entry == DEAL_ENTRY_OUT)
   {
      long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string how = (reason == DEAL_REASON_TP) ? "TP hit"
                 : (reason == DEAL_REASON_SL) ? "SL hit"
                 : "closed";
      double closed = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                    + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      // money this episode has actually booked: it is what funds the next add
      episodeBooked += closed;
      Notify("CLOSE", StringFormat("%s - %.2f lots, P/L %.2f, equity %.2f",
             how,
             HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
             closed,
             AccountInfoDouble(ACCOUNT_EQUITY)));
   }
}

//+------------------------------------------------------------------+
//| Position sizing: RiskPct of the effective bankroll against the   |
//| stop distance, clamped to broker limits and the hard risk cap.   |
//+------------------------------------------------------------------+
double CalcLots(double effective, double slDist)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || slDist <= 0.0)
      return 0.0;

   double moneyPerLot = slDist / tickSize * tickValue;   // loss at SL for 1.0 lot
   if(moneyPerLot <= 0.0)
      return 0.0;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = effective * InpRiskPct / 100.0 / moneyPerLot;

   // min lot must not risk more than the hard cap of the effective bankroll
   if(lots < minLot)
   {
      double minLotRisk = minLot * moneyPerLot;
      double capMoney   = effective * InpMaxRiskPct / 100.0;
      if(minLotRisk > capMoney)
      {
         // Say what would fix it: the bankroll whose cap covers one minimum lot.
         // A trading log that only repeats "no" is what cost a whole night here.
         LogSkip("minlot-cap", StringFormat("min lot %.2f would risk %.4f > cap %.2f%% of %.2f "
             "(needs a bankroll of >= %.2f, i.e. equity >= %.2f)",
             minLot, minLotRisk, InpMaxRiskPct, effective,
             minLotRisk / (InpMaxRiskPct / 100.0),
             InpBaselineEquity + minLotRisk / (InpMaxRiskPct / 100.0)));
         return 0.0;
      }
      lots = minLot;
   }
   if(lots > maxLot)
      lots = maxLot;
   if(step > 0.0)
      lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| The ladder. Every position this EA owns on this symbol: a netting  |
//| account holds one aggregate position, a hedging account holds one  |
//| per add, and looping tickets is correct for both.                  |
//+------------------------------------------------------------------+
bool LadderSelect(const int i)
{
   ulong t = PositionGetTicket(i);
   if(t == 0 || !PositionSelectByTicket(t))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   return (PositionGetInteger(POSITION_MAGIC) == InpMagic);
}

int LadderCount()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(LadderSelect(i))
         n++;
   return n;
}

double LadderLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(LadderSelect(i))
         lots += PositionGetDouble(POSITION_VOLUME);
   return lots;
}

double LadderFloat()          // unrealised P/L of the whole ladder
{
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(LadderSelect(i))
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return pl;
}

double LadderStop()           // the highest stop on the ladder = the shared one
{
   double stop = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(LadderSelect(i))
         stop = MathMax(stop, PositionGetDouble(POSITION_SL));
   return stop;
}

double LadderLowestEntry()
{
   double entry = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!LadderSelect(i))
         continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      entry = (entry <= 0.0) ? p : MathMin(entry, p);
   }
   return entry;
}

// one episode at a time: flat means the base trade is still to be opened
bool HasOpenPosition()
{
   return (LadderCount() > 0);
}

//+------------------------------------------------------------------+
void CloseEverything()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!LadderSelect(i))
         continue;
      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      double lots   = PositionGetDouble(POSITION_VOLUME);
      if(trade.PositionClose(ticket))
         Log("CLOSE", StringFormat("halt: closed #%I64u %.2f lots", ticket, lots));
   }
}

//+------------------------------------------------------------------+
//| Money lost by one lot over a given price distance, from the       |
//| symbol's own tick value (the same arithmetic CalcLots uses).      |
//+------------------------------------------------------------------+
double MoneyPerLot(double dist)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || dist <= 0.0)
      return 0.0;
   return dist / tickSize * tickValue;
}

//+------------------------------------------------------------------+
//| What the ladder loses if every position stops where it is set.    |
//| A position whose stop is above its entry contributes nothing.     |
//+------------------------------------------------------------------+
double LadderStopRisk()
{
   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!LadderSelect(i))
         continue;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double stop  = PositionGetDouble(POSITION_SL);
      double lots  = PositionGetDouble(POSITION_VOLUME);
      if(stop > 0.0 && entry > stop)
         risk += MoneyPerLot(entry - stop) * lots;
   }
   return risk;
}

//+------------------------------------------------------------------+
//| Push the shared stop up. It only ever tightens, a broker refusal  |
//| (stops level, freeze) is logged rather than swallowed, and each   |
//| level is logged once instead of once per tick.                    |
//+------------------------------------------------------------------+
int ApplyLadderStop(double stop, string why)
{
   if(stop <= 0.0 || !MathIsValidNumber(stop))
      return 0;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // Two floors under our feet: the broker's stops level, and our own minimum
   // distance. This symbol reports a stops level of 0, so the broker's floor
   // alone let a stop land ON the price - where the next tick takes it out.
   // That is how the 2026-11-02 run turned every winner into a +0.05% exit.
   double floorDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double gapDist   = bid * InpMinStopGapPct / 100.0;
   if(gapDist > floorDist)
      floorDist = gapDist;
   double newSl = NormalizeDouble(stop, _Digits);
   if(bid > 0.0 && floorDist > 0.0 && bid - newSl < floorDist)
      newSl = NormalizeDouble(bid - floorDist, _Digits);
   int moved = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!LadderSelect(i))
         continue;
      if(newSl <= PositionGetDouble(POSITION_SL) + _Point / 2.0)
         continue;                     // never loosen a stop
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(trade.PositionModify(ticket, newSl, PositionGetDouble(POSITION_TP)))
         moved++;
      else
         Log("ERROR", StringFormat("stop move #%I64u -> %.2f refused: %d %s",
             ticket, newSl, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
   if(moved > 0 && (ladderStopLast <= 0.0 || MathAbs(newSl - ladderStopLast) > _Point / 2.0))
   {
      ladderStopLast = newSl;
      double pct = (episodeBase > 0.0) ? (newSl - episodeBase) / episodeBase * 100.0 : 0.0;
      // The distance to the price is in every line on purpose: a stop sitting on
      // the price (0.000% below it) is the exact failure this log must expose.
      Log(why, StringFormat("%d position(s) stop -> %.2f (%+.3f%% vs entry %.2f, "
          "%.3f%% below the price)",
          moved, newSl, pct, episodeBase, bid > 0.0 ? (bid - newSl) / bid * 100.0 : 0.0));
   }
   return moved;
}

//+------------------------------------------------------------------+
//| Take the measured target on the BASE leg and leave the rest of the |
//| ladder running. Closing exactly the base volume, oldest ticket      |
//| first, does the same thing on a netting account (a partial close of |
//| the aggregate) and on a hedging account (the base ticket), which is |
//| what the backtest models. A broker TP could not: on netting it      |
//| would close the whole ladder at the target and kill the ride.       |
//+------------------------------------------------------------------+
void BankBaseLeg()
{
   if(episodeBanked || InpTakeProfitPct <= 0.0 || episodeBaseLots <= 0.0)
      return;
   episodeBanked = true;                 // one look per episode, whatever happens
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0)
      step = 0.01;
   double want = MathFloor(episodeBaseLots / step) * step;
   double have = LadderLots();
   if(want > have)
      want = MathFloor(have / step) * step;
   if(want < minLot || want <= 0.0)
      return;
   ulong ticket = 0;
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!LadderSelect(i))
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
      {
         oldest = t;
         ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      }
   }
   if(ticket == 0)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(trade.PositionClosePartial(ticket, NormalizeDouble(want, 2)))
      Notify("BANK", StringFormat("banked the base %.2f lots at %.2f (%+.3f%%), "
             "%.2f lots still riding on the shared stop",
             want, bid, (bid - episodeBase) / episodeBase * 100.0, LadderLots()));
   else
      Log("ERROR", StringFormat("bank %.2f lots refused: %d %s", want,
          trade.ResultRetcode(), trade.ResultRetcodeDescription()));
}

//+------------------------------------------------------------------+
//| The one stop the whole ladder shares: never below where it already |
//| is, never below the lock-in floor once the target has been BANKED, |
//| and trailing the peak once the trail is armed. Only ever moves up, |
//| and never closer to the price than InpMinStopGapPct (ApplyLadder-   |
//| Stop enforces that: a stop on the price is a stop hit next tick).   |
//+------------------------------------------------------------------+
double SharedStop(double bid, double pct)
{
   double stop = LadderStop();
   // The floor arms only once the base leg has BANKED its target. Armed any
   // earlier it is not a floor, it is an at-the-money take-profit at
   // InpLockInPct - which is exactly what killed the live run of 2026-11-02
   // (every winner left at +0.05%, no winner ever reached the 0.25% target,
   // and not one add fired: 4 wins / 4 losses, -$14.59 in 75 minutes).
   if(InpLockInPct > 0.0 && episodeBase > 0.0 && episodeBanked && pct >= InpLockInPct)
      stop = MathMax(stop, episodeBase * (1.0 + InpLockInPct / 100.0));
   if(InpTrailPct > 0.0 && pct >= InpTrailStartPct)
      stop = MathMax(stop, bid * (1.0 - InpTrailPct / 100.0));
   return stop;
}

//+------------------------------------------------------------------+
//| Pyramid: add only out of money this episode has already made, at  |
//| the shared stop, never past the ladder caps, and never risking     |
//| more than the same headroom the base trade obeys.                  |
//+------------------------------------------------------------------+
void MaybeAdd(double effective, double bid, double pct, double stop)
{
   if(InpMaxAdds <= 0 || episodeAdds >= InpMaxAdds || InpAddRiskPct <= 0.0)
      return;
   if(pct < InpAddAtPct * (episodeAdds + 1))
      return;
   double dist        = bid - stop;
   double moneyPerLot = MoneyPerLot(dist);
   if(stop <= 0.0 || moneyPerLot <= 0.0)
      return;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0)
      step = 0.01;
   double budget = (episodeBooked + LadderFloat()) * InpAddRiskPct / 100.0;
   double lots = MathFloor((budget / moneyPerLot) / step) * step;
   lots = MathMin(lots, InpMaxLadderLots - LadderLots());
   if(lots < minLot)
   {
      // Say it out loud, throttled: on 2026-11-02 the ladder never fired and the
      // log said nothing, so a ladder that was never affordable looked exactly
      // like a ladder that was broken.
      LogSkip("add-small", StringFormat("add at %+.3f%% would be %.2f lots (broker min %.2f): "
              "this episode has %.2f in hand, one min lot with %.0f points to its stop "
              "needs %.2f", pct, lots, minLot, episodeBooked + LadderFloat(), dist / _Point,
              minLot * moneyPerLot));
      return;      // the episode has not made enough to pay for another leg
   }

   double cap = effective * InpMaxLadderRiskPct / 100.0;
   if(LadderStopRisk() + lots * moneyPerLot > cap)
   {
      LogSkip("add", StringFormat("ladder risk %.2f + %.2f > cap %.2f",
              LadderStopRisk(), lots * moneyPerLot, cap));
      return;
   }

   if(!trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(stop, _Digits), 0.0, "BoomRider add"))
   {
      Log("ERROR", StringFormat("add %.2f lots refused: %d %s",
          lots, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return;
   }
   episodeAdds++;
   Notify("ADD", StringFormat("added %.2f lots at %.2f (%+.3f%%), ladder now %.2f lots, "
          "stop %.2f, booked %.2f", lots, bid, pct, LadderLots(), stop, episodeBooked));
}

//+------------------------------------------------------------------+
//| Every tick, before any entry decision: bank at the target, protect |
//| the shared stop, trail it, then pyramid out of profit.             |
//+------------------------------------------------------------------+
void ManageLadder(double effective)
{
   if(LadderCount() == 0)
   {
      if(episodeBase > 0.0)
         Log("EPISODE", StringFormat("flat again: %d add(s), booked %.2f this episode",
             episodeAdds, episodeBooked));
      episodeBase     = 0.0;
      episodeBaseLots = 0.0;
      episodeBooked   = 0.0;
      episodeBanked   = false;
      episodeAdds     = 0;
      ladderStopLast  = 0.0;
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0 || !MathIsValidNumber(bid))
      return;
   if(episodeBase <= 0.0)
      episodeBase = LadderLowestEntry();      // rebuild the reference after a restart
   if(episodeBase <= 0.0)
      return;
   double pct = (bid - episodeBase) / episodeBase * 100.0;

   // 1. the base leg takes the measured target; the added legs keep running
   if(pct >= InpTakeProfitPct)
   {
      BankBaseLeg();
      if(LadderCount() == 0)
         return;
   }

   // 2. the shared stop: lock-in floor once paid, then trail the peak. Every
   //    position in the ladder gets it, so no add can ever give profit back.
   double stop = SharedStop(bid, pct);
   if(stop > LadderStop())
      ApplyLadderStop(stop, pct >= InpTrailStartPct ? "TRAIL" : "LOCKIN");

   // 3. pyramid, funded only by profit this episode has made
   MaybeAdd(effective, bid, pct, stop);
}


//| MetaQuotes ID push otherwise. One log line per attempt outcome;  |
//| a failing push must never disturb trading.                       |
//+------------------------------------------------------------------+
void NotifyAnnounce()
{
   if(StringLen(InpNotifyUrl) > 0)
      Print("[BoomRider] push -> ", InpNotifyUrl,
            " (must be listed in Tools > Options > Expert Advisors > Allow WebRequest)");
   else
      Print("[BoomRider] push -> MetaQuotes ID (set it in Tools > Options > Expert Advisors; ",
            "no InpNotifyUrl given, so ntfy is off)");
}

void Notify(string event, string msg)
{
   Log(event, msg);
   if(StringLen(InpNotifyUrl) == 0)
   {
      SendNotification(msg);   // MetaQuotes ID mobile push (silently no-ops if unset)
      return;
   }
   char post[];                // WebRequest needs non-const arrays
   char result[];
   StringToCharArray(msg, post, 0, StringLen(msg));   // body = the message, no NUL
   string headers = "Content-Type: text/plain\r\n" +
                    "Title: HEX-BoomRider " + event + "\r\n" +
                    "Tags: chart_with_upwards_trend\r\n";
   string url = InpNotifyUrl;
   ResetLastError();
   int status = WebRequest("POST", url, headers, 5000, post, result, headers);
   if(status == -1)
      Print("[BoomRider] NOTIFY-FAIL ", event, ": WebRequest blocked - add the URL's ",
            "origin to Tools > Options > Expert Advisors > Allow WebRequest (err ",
            GetLastError(), ")");
   else if(status < 200 || status >= 300)
      Print("[BoomRider] NOTIFY-FAIL ", event, ": HTTP ", status);
   else
      Print("[BoomRider] NOTIFY-OK ", event, ": sent");
}

//+------------------------------------------------------------------+
//| CSV log + heartbeat + blown marker (portable-file conventions)   |
//+------------------------------------------------------------------+
void Log(string event, string detail)
{
   string line = StringFormat("%s,%s,%s,%.2f,%s",
                 TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                 event, _Symbol, AccountInfoDouble(ACCOUNT_EQUITY), detail);
   int h = FileOpen(csvName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\n");
   FileClose(h);
   Print("[BoomRider] ", event, ": ", detail);   // banner mirror via Experts log
}

//+------------------------------------------------------------------+
//| SKIP logging, throttled. The sizing guard fires on every tick,   |
//| and the same line twice a second for hours buries the BUY/ERROR  |
//| rows it exists to explain (and doubles docker-log volume through |
//| the MQL5 mirror). One line per reason per InpSkipLogSec; a new   |
//| reason is logged at once. key is the category, not the text: the |
//| risk figure inside the text changes on every single tick.        |
//+------------------------------------------------------------------+
void LogSkip(string key, string detail)
{
   if(key == lastSkipKey && InpSkipLogSec > 0 && TimeCurrent() - lastSkipAt < InpSkipLogSec)
      return;
   lastSkipKey = key;
   lastSkipAt  = TimeCurrent();
   Log("SKIP", detail);
}

void WriteHeartbeat()
{
   lastHeartbeat = TimeCurrent();
   string name = InpLogDir + "/HEX-BoomRider-heartbeat.txt";
   int h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, StringFormat("%s|%.2f|%d\n",
                   TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                   AccountInfoDouble(ACCOUNT_EQUITY), tradesToday));
   FileClose(h);
}

string BlownMarkerName() { return InpLogDir + "/HEX-BoomRider-BLOWN.txt"; }

bool BlownMarkerExists()
{
   int h = FileOpen(BlownMarkerName(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return false;
   FileClose(h);
   return true;
}

void WriteBlownMarker(string msg)
{
   int h = FileOpen(BlownMarkerName(), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, msg + "\n");
   FileClose(h);
}

//+------------------------------------------------------------------+
int TimeDay(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.day;
}
//+------------------------------------------------------------------+

