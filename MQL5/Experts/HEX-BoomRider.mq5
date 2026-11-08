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
input int    InpHeartbeatSec   = 60;       // Heartbeat file write interval (terminal timer, NOT ticks)
input int    InpTickStallSec   = 300;      // Log/push a dead feed after this long with no tick (0 = never)
input int    InpSkipLogSec     = 60;       // Repeat the same SKIP line at most this often (0 = every tick)
input string InpLogDir         = "HEX-Logs";
input string InpNotifyUrl      = "";       // Push target: ntfy URL, empty = MetaQuotes ID push only
input bool   InpNotifyTest     = true;     // Send a hello at init so the pipe is proven early

CTrade   trade;
bool     blown         = false;
// All three clocks are TimeLocal(), deliberately. TimeCurrent() is the server
// time of the LAST TICK, so on a chart that stops being ticked it freezes - and
// a heartbeat, a throttle or a stall detector built on it goes quiet exactly
// when it is needed. Live, 2026-11-02: the terminal stayed up and connected (the
// stop it was holding filled at 22:04 and was journalled), but the chart stopped
// being ticked at 21:54, OnTick was never called again, and the EA wrote nothing
// for six hours while every outward signal said "running".
datetime lastHeartbeat = 0;   // TimeLocal of the last heartbeat write
datetime lastTickLocal = 0;   // TimeLocal of the last tick OnTick was called with
datetime lastStallLog  = 0;   // TimeLocal of the last "no tick" line
datetime stallSince    = 0;   // TimeLocal when the current stall was first logged
datetime startedAt     = 0;   // TimeLocal of OnInit (a chart that never ticks stalls too)
bool     tickStalled   = false;
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
bool     symbolNameReported = false;   // "not in the server's list" was already said once

//+------------------------------------------------------------------+
//| One chart, one robot.                                            |
//|                                                                  |
//| MT5 restores the charts it saved when the terminal last exited   |
//| and THEN applies [StartUp], so every terminal restart adds a     |
//| chart to the ones already there - and a restored chart reloads   |
//| its own copy of this expert out of the profile. By 2026-11-08    |
//| the noVNC desktop carried several charts, which is N copies of   |
//| the robot sizing off one equity and able to trade one account    |
//| twice (plus a Wine desktop painting all of them). The entrypoint |
//| clears the saved charts before every start; this refuses the     |
//| leftovers anyway, because a chart can also be opened by hand.    |
//|                                                                  |
//| The claim is a TEMPORARY global (it dies with the terminal) that |
//| the owner refreshes from the timer, so a copy whose owner was    |
//| removed or crashed can be taken over after two minutes instead   |
//| of locking the volume out for ever.                              |
//+------------------------------------------------------------------+
string ClaimKey() { return "HEXBR-" + IntegerToString(InpMagic); }

bool ClaimChart()
{
   string lease = ClaimKey() + "-seen";
   string owner = ClaimKey() + "-chart";
   long   me    = ChartID();
   long   held  = (long)GlobalVariableGet(owner);
   long   seen  = (long)GlobalVariableGet(lease);
   if(held != 0 && held != me && seen > 0 && (long)TimeLocal() - seen < 120)
   {
      string msg = "another copy of this EA is already running on this terminal (chart " +
                   IntegerToString(held) + ", magic " + IntegerToString(InpMagic) + ") - this "
                   "chart refuses to start, so the two cannot trade the same account twice. The "
                   "container keeps exactly one chart; close the duplicate on the desktop.";
      Log("ERROR", msg);
      Alert("HEX-BoomRider: duplicate chart refused - " + msg);
      return(false);
   }
   GlobalVariableSet(lease, (double)TimeLocal());
   GlobalVariableTemp(lease);
   GlobalVariableSet(owner, (double)me);
   GlobalVariableTemp(owner);
   return(true);
}

void RefreshClaim()
{
   GlobalVariableSet(ClaimKey() + "-seen", (double)TimeLocal());
}

//+------------------------------------------------------------------+
//| Can this chart be ticked at all? Two different faults with two   |
//| different fixes, and from outside they were the same silence:    |
//|                                                                  |
//|  * the name is NOT in the SERVER's symbol list - the broker has  |
//|    renamed or retired it. The chart still opens from the         |
//|    terminal's cache, the expert still loads and beats, and no    |
//|    quote can ever arrive. Only a correct MT5_SYMBOL fixes that,  |
//|    so the log names the ones the server does carry.              |
//|  * the name is on the server but not SELECTED - it is not in     |
//|    Market Watch, so nothing subscribes it. SymbolSelect does.    |
//|                                                                  |
//| The terminal's own sync line says the same thing in one number:  |
//| "725 symbols, 0 spreads". No spread data at all means nothing    |
//| is subscribed, whatever the chart is drawing.                    |
//+------------------------------------------------------------------+
bool SymbolOnServer(const string sym)
{
   const int total = SymbolsTotal(false);       // everything the server carries
   for(int i = 0; i < total; i++)
      if(SymbolName(i, false) == sym)
         return(true);
   return(false);
}

// The names the server does carry that look like the one we were asked for: the
// operator needs a choice, not a diagnosis ("Boom 300 Index, Boom 500 Index ..."),
// because the fix is to set MT5_SYMBOL to one of them.
string SimilarSymbols(const string needle, const int cap)
{
   string out = "";
   const int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string n = SymbolName(i, false);
      if(StringFind(n, needle) < 0)
         continue;
      if(out != "")
         out += ", ";
      out += n;
      if(StringLen(out) > cap)
      {
         out += ", ...";
         break;
      }
   }
   return(out == "" ? "none" : out);
}

// When the last quote the terminal knows about arrived: on a dead chart this is
// the one number that says how long "nothing is trading" has been true.
string LastQuoteTime()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.time == 0)
      return("never");
   return(TimeToString(t.time, TIME_DATE | TIME_SECONDS));
}

void EnsureSubscribed()
{
   const int total = SymbolsTotal(false);
   if(total > 0 && !SymbolOnServer(_Symbol))
   {
      symbolNameReported = true;
      Log("ERROR", StringFormat("%s is NOT in the server's symbol list (%d symbols on %s). A chart "
          "opened on a name the broker does not offer still draws out of the terminal's cache and "
          "this expert still loads - but no quote can ever arrive, so there is no entry, no exit and "
          "nothing trading. Names on this server containing \"Boom\": %s. Set MT5_SYMBOL to the exact "
          "one and the container re-opens the chart.",
          _Symbol, total, AccountInfoString(ACCOUNT_SERVER), SimilarSymbols("Boom", 400)));
      return;
   }
   const int sel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT);
   const int vis  = (int)SymbolInfoInteger(_Symbol, SYMBOL_VISIBLE);
   const int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   Log("SUB", StringFormat("symbol: select=%d visible=%d spread=%d points, trade mode=%d, "
       "symbols on server=%d, last quote=%s (server time)",
       sel, vis, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), mode, total, LastQuoteTime()));
   if(sel == 0 || vis == 0)
   {
      const bool ok = SymbolSelect(_Symbol, true);
      Log(ok ? "SUB" : "ERROR", StringFormat("%s was not subscribed (select=%d visible=%d) - "
          "SymbolSelect(%s, true) -> %s. A symbol that is not selected receives no quotes at all, "
          "which looks exactly like a dead feed and trades nothing.",
          _Symbol, sel, vis, _Symbol, ok ? "ok" : "FAILED"));
   }
   if(mode == (int)SYMBOL_TRADE_MODE_DISABLED)
      Log("ERROR", StringFormat("%s is on the server but DISABLED for trading on this account - "
          "the chart can be ticked, but every order will be refused", _Symbol));
}

// Called from the timer while the chart is stalled: the one thing the EA can do
// about a lost subscription from inside. A name the server does not carry cannot
// be fixed in this loop - but if the list was still empty when OnInit ran (a
// terminal that had not synchronized yet), the fault is named here instead, once.
void RetrySubscribe()
{
   const int total = SymbolsTotal(false);
   if(total > 0 && !SymbolOnServer(_Symbol))
   {
      if(!symbolNameReported)
         EnsureSubscribed();
      return;
   }
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT) != 0)
      return;
   const bool ok = SymbolSelect(_Symbol, true);
   Log(ok ? "SUB" : "ERROR", StringFormat("the stall is a lost subscription - re-selecting %s "
       "in Market Watch -> %s", _Symbol, ok ? "ok" : "FAILED"));
}

//+------------------------------------------------------------------+
int OnInit()
{
   // Order matters: name the CSV before anything can log into it, refuse a second
   // copy before it can trade, and only then announce what the chart can see.
   MqlDateTime dt; TimeCurrent(dt);
   csvName = StringFormat("%s/HEX-BoomRider-%04d%02d%02d.csv",
                          InpLogDir, dt.year, dt.mon, dt.day);
   FolderCreate(InpLogDir);
   if(!ClaimChart())
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   // The heartbeat is a lease on ATTACHMENT, never on ticks. A terminal timer
   // fires whether or not the chart is being fed, so the file now moves for as
   // long as the EA is loaded, and the AGE OF THE LAST TICK goes inside it - that
   // is what separates "the EA is gone" from "the EA is here and the feed is
   // dead", which on 2026-11-02 were the same silence from the outside.
   startedAt = TimeLocal();
   EventSetTimer(1);

   blown = BlownMarkerExists();
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
   // What this chart can actually SEE. Every field logged above reads back out of
   // the terminal's cached symbol description even when the broker no longer
   // offers the name, so a chart that can never be ticked has looked perfectly
   // healthy until now (2026-11-06 and 2026-11-08: expert loaded, heartbeat
   // moving, tick_age climbing to 900, not one trade).
   EnsureSubscribed();
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
   // --- heartbeat + the other half of it: ticks ARE arriving ---
   lastTickLocal = TimeLocal();
   if(tickStalled)
   {
      tickStalled = false;
      Log("FEED", StringFormat("ticks are back after %dm - it was the feed, not the EA",
          (int)((TimeLocal() - stallSince) / 60)));
      stallSince = 0;
   }
   if(TimeLocal() - lastHeartbeat >= InpHeartbeatSec)
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
//| The heartbeat, on a terminal timer instead of on ticks.          |
//|                                                                  |
//| Ticks are not a lease on the EA: on 2026-11-02 the chart stopped |
//| being fed at 21:54 while the terminal stayed up and connected,   |
//| so OnTick was never called again. A heartbeat written from       |
//| OnTick therefore stopped too - and "the feed died" and "the EA   |
//| was removed" became the same silence in the container log, which |
//| announced the wrong one for six hours.                           |
//|                                                                  |
//| This timer is independent of the quote flow: if the file stops   |
//| moving, the EA really is gone. The age of the last tick is       |
//| written INSIDE the beat, so the deploy side can tell the feed is |
//| dead while the EA is alive - and restart the terminal to re-      |
//| subscribe the chart.                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // The chart claim is a lease: refreshing it here is what lets another copy take
   // over when this one is gone (and what stops one from starting while it is not).
   RefreshClaim();
   if(lastHeartbeat == 0 || TimeLocal() - lastHeartbeat >= InpHeartbeatSec)
      WriteHeartbeat();

   if(InpTickStallSec <= 0)
      return;
   int idle = SecondsSinceTick();
   if(idle < InpTickStallSec)
      return;
   // One line at the threshold, then one every five minutes: a stalled feed can
   // last hours (that night: six), and a line a second would bury the fact that
   // there is only one thing wrong. push_watcher turns the first one into a buzz.
   if(lastStallLog > 0 && TimeLocal() - lastStallLog < 300)
      return;
   lastStallLog = TimeLocal();
   if(!tickStalled)
   {
      tickStalled = true;
      stallSince  = TimeLocal();
   }
   LogSkip("no-ticks", StringFormat("%dm without a tick on %s - the EA is attached and "
           "beating, the chart is not being fed (no entry, no exit, nothing trading)",
           idle / 60, _Symbol));
   // ...and the one repair the EA can attempt itself: a chart that lost its Market
   // Watch selection receives nothing, and re-selecting it starts the quotes again
   // without anyone touching the desktop.
   RetrySubscribe();
}

//+------------------------------------------------------------------+
//| Why the EA left the chart, in the log the deploy side already   |
//| mirrors. The terminal writes the reason to the Experts log only  |
//| in some cases ("expert ... removed") and never says when it      |
//| happened; this row is a fact with a time on it, and DEINIT is    |
//| forwarded to the phone.                                          |
//+------------------------------------------------------------------+
string DeinitReason(const int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM:     return "ExpertRemove() was called";
      case REASON_REMOVE:      return "removed from the chart";
      case REASON_RECOMPILE:   return "recompiled";
      case REASON_CHARTCHANGE: return "symbol or timeframe changed";
      case REASON_CHARTCLOSE:  return "chart closed";
      case REASON_PARAMETERS:  return "inputs changed";
      case REASON_ACCOUNT:     return "another account was logged in";
      case REASON_TEMPLATE:    return "template applied";
      case REASON_INITFAILED:  return "OnInit did not succeed";
      case REASON_CLOSE:       return "terminal closed";
   }
   return StringFormat("reason %d", reason);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   // Hand the chart claim back at once, so re-attaching the expert does not have
   // to wait out the two-minute lease (and a duplicate cannot start in between).
   if((long)GlobalVariableGet(ClaimKey() + "-chart") == ChartID())
      GlobalVariableSet(ClaimKey() + "-seen", 0);
   // The row's own timestamp is TimeCurrent() like every other row, so the local
   // clock goes in the text: on a dead feed the server clock is frozen and the
   // one thing that matters is when this actually happened.
   Log("DEINIT", StringFormat("unloaded at %s local: %s; last tick %dm ago",
       TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
       DeinitReason(reason), SecondsSinceTick() / 60));
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
   // TimeLocal, not TimeCurrent: the server clock is the last tick's, so it
   // freezes when the feed does - and "no tick for Nm" would then be logged once
   // and throttled for ever, which is the silence it exists to break.
   if(key == lastSkipKey && InpSkipLogSec > 0 && TimeLocal() - lastSkipAt < InpSkipLogSec)
      return;
   lastSkipKey = key;
   lastSkipAt  = TimeLocal();
   Log("SKIP", detail);
}

//+------------------------------------------------------------------+
//| How long the chart has gone without a tick, in seconds. Before  |
//| the first tick it counts from OnInit, so "the symbol never      |
//| synchronized" is a stall too and not an eternal all-clear.      |
//+------------------------------------------------------------------+
int SecondsSinceTick()
{
   datetime since = (lastTickLocal > 0) ? lastTickLocal : startedAt;
   if(since <= 0)
      return 0;
   int age = (int)(TimeLocal() - since);
   return age < 0 ? 0 : age;
}

void WriteHeartbeat()
{
   lastHeartbeat = TimeLocal();
   string name = InpLogDir + "/HEX-BoomRider-heartbeat.txt";
   int h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   // "<local time>|tick_age=<s>|equity=..|trades=..|sel=..|spread=..". The
   // timestamp is when the EA last ran (mtime says the same thing to the
   // container); tick_age is the fact mtime cannot carry: 0..N seconds since the
   // chart last ticked, so a beat that keeps moving while tick_age climbs is a
   // dead feed with a live EA. sel is whether the symbol is subscribed at all -
   // 0 means no quote can arrive however long we wait, which is a different fix
   // (select it) from a stalled feed (restart the terminal).
   // Parsed by deploy/scripts/healthcheck.sh and the watchers in the entrypoint
   // with `tick_age=\([0-9][0-9]*\)` / `|sel=\([0-9][0-9]*\)` - an older build
   // has no such field and must read as "unknown", never as a stall.
   FileWriteString(h, StringFormat("%s|tick_age=%d|equity=%.2f|trades=%d|sel=%d|spread=%d\n",
                   TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
                   SecondsSinceTick(), AccountInfoDouble(ACCOUNT_EQUITY), tradesToday,
                   (int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT),
                   (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
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

