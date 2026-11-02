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
input double InpTakeProfitPct  = 0.25;     // TP: % above entry
input double InpStopLossPct    = 0.30;     // SL: % below entry
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

   // --- one position at a time; enter long when flat ---
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
   double tpDist = ask * InpTakeProfitPct / 100.0;
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
      Log("BUY", StringFormat("lots=%.2f entry~%.2f sl=%.2f tp=%.2f eff=%.2f",
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
      Notify("CLOSE", StringFormat("%s - %.2f lots, P/L %.2f, equity %.2f",
             how,
             HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
             HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
               + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
               + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION),
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
bool HasOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return false;
   return (PositionGetInteger(POSITION_MAGIC) == InpMagic);
}

//+------------------------------------------------------------------+
void CloseEverything()
{
   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      trade.PositionClose(_Symbol);
}

//+------------------------------------------------------------------+
//| Notifications: ntfy when InpNotifyUrl is set (plain-text POST),  |
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

