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

input double InpBaselineEquity = 9990.0;   // Blow line: equity at/below this = blown
input double InpRiskPct        = 20.0;     // Risk % of effective bankroll per trade
input double InpMaxRiskPct     = 50.0;     // Never risk more than this % (min-lot guard)
input double InpTakeProfitPct  = 0.15;     // TP: % above entry
input double InpStopLossPct    = 0.40;     // SL: % below entry
input double InpMaxSpreadPct   = 0.03;     // Skip entries when spread wider than this %
input long   InpMagic          = 400400;   // Magic number
input int    InpHeartbeatSec   = 60;       // Heartbeat file write interval
input string InpLogDir         = "HEX-Logs";

CTrade   trade;
bool     blown         = false;
datetime lastHeartbeat = 0;
datetime lastDay       = 0;
string   csvName       = "";
int      tradesToday   = 0;
double   riskToday     = 0.0;

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
      Log("BLOWN", msg);
      Alert(msg);
      SendNotification(msg);   // mobile push when MetaQuotes ID is set
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
   double spreadPct = (ask - bid) / ask * 100.0;
   if(spreadPct > InpMaxSpreadPct)
   {
      Log("SKIP", StringFormat("spread %.4f%% > max %.4f%%", spreadPct, InpMaxSpreadPct));
      return;
   }

   double slDist = ask * InpStopLossPct  / 100.0;
   double tpDist = ask * InpTakeProfitPct / 100.0;
   double sl = NormalizeDouble(ask - slDist, _Digits);
   double tp = NormalizeDouble(ask + tpDist, _Digits);

   double lots = CalcLots(effective, slDist);
   if(lots <= 0.0)
   {
      Log("SKIP", "lot calc returned 0 (risk cap / broker limits)");
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
      Log("ERROR", StringFormat("Buy failed: %d %s", trade.ResultRetcode(),
          trade.ResultRetcodeDescription()));
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
      if(minLotRisk > effective * InpMaxRiskPct / 100.0)
      {
         Log("SKIP", StringFormat("min lot %.2f would risk %.4f > cap %.2f%% of %.2f",
             minLot, minLotRisk, InpMaxRiskPct, effective));
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

