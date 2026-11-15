//+------------------------------------------------------------------+
//|                                            HEX-FVG-Breaker.mq5   |
//|   Breaker Blocks + Mitigation Blocks + Fair Value Gaps           |
//|   Trend-following execution on FVGs                              |
//|                                                                  |
//|   This is the MT4 EA (MQL4/Experts/HEX-FVG-Breaker.mq4, v3.00)   |
//|   carried to MetaTrader 5. The strategy engine - zone detection, |
//|   trend filter, entry geometry, guards, sizing, exits - is the   |
//|   same code, same rules, same defaults. What changed:            |
//|                                                                  |
//|     * the order layer: MT4's OrderSend/OrderSelect/OrderModify   |
//|       is replaced by CTrade + PositionsTotal/OrdersTotal, because |
//|       MQL5 has no order pool. One record per POSITION, keyed by  |
//|       the position ticket; a pending is keyed by its order       |
//|       ticket and adopted when it fills.                          |
//|     * the bars/indicators: Time[i]/High[i] become iTime/iHigh,   |
//|       and iATR/iMA become handles read with CopyBuffer.          |
//|     * the CSV logs live under MQL5/Files/HEX-Logs so the         |
//|       container can mirror them (MT4 wrote to Common\).           |
//|     * pushes are sent by the CONTAINER from these CSVs (curl),   |
//|       not by WebRequest: MQL5 refuses any URL not whitelisted in  |
//|       the GUI, and a headless box must not depend on a click.    |
//|     * the heartbeat is written from a terminal TIMER, with the    |
//|       age of the last tick inside it, so the container can tell   |
//|       "the EA is gone" from "the feed is dead".                  |
//|                                                                  |
//|   Two things this build does differently ON PURPOSE, because the  |
//|   old exit rules capped every winner short:                      |
//|     1. the runner is given room - TP1 banks a third, not half,    |
//|        and the runner target is 4R instead of 2.5R;               |
//|     2. open profit is protected by a ratcheting lock ladder and   |
//|        a peak-based ATR trail, and once the stop is locked at    |
//|        >= 1R the fixed target is removed so the trail can carry  |
//|        the trade past it (LetWinnersRun).                        |
//+------------------------------------------------------------------+
#property copyright "Forex-hex-algo-strategy-mt4"
#property link      "https://github.com/Manged3/Forex-hex-algo-strategy-mt4"
#property version   "4.01"
#property strict
#property description "Trend trading through Fair Value Gaps, confirmed by Breaker and Mitigation blocks."

#include <Trade/Trade.mqh>

//--- Enums ---------------------------------------------------------
enum ENUM_HEX_ZONE
  {
   HEX_ZONE_FVG       = 1,   // Fair Value Gap (3-candle imbalance)
   HEX_ZONE_BREAKER   = 2,   // Breaker block (level that broke and flipped polarity)
   HEX_ZONE_MITIG     = 3    // Mitigation block (base left behind by displacement)
  };

enum ENUM_TREND_MODE
  {
   TREND_EMA        = 0,     // EMA stack on trend timeframe
   TREND_STRUCTURE  = 1,     // Higher-timeframe market structure (HH/HL vs LH/LL)
   TREND_BOTH       = 2      // Require EMA and structure to agree
  };

enum ENUM_EXIT_MODE
  {
   EXIT_FIXED_RR    = 0,     // TP1 partial + runner at a fixed R multiple
   EXIT_ZONE_RR     = 1,     // TP1 partial + runner at the next opposing zone
   EXIT_TRAIL_ONLY  = 2      // No TPs, trail with ATR (runner)
  };

enum ENUM_ENTRY_MODEL
  {
   ENTRY_LIMIT      = 0,     // Limit order deep in the zone (better R, some never fill)
   ENTRY_TRIGGER    = 1      // Market after a rejection candle inside the zone
  };

// What the price-distance inputs mean. The MT4 file was written for gold and
// every "Dollars" threshold was a $/oz distance. On a 5-digit index those
// numbers are a different country: 1.20 of an index priced at 15000 is inside
// the noise, so nothing qualifies and the EA never trades.
//   SCALE_PRICE - the input is a price distance (the MT4 behaviour, for gold).
//   SCALE_ATR   - the input is a MULTIPLE OF THE M15 ATR ("0.45" = 45% of
//                 ATR), which is symbol-independent and is what the shipped
//                 preset uses on Volatility Boom 400.
// Only the distance gates scale; money amounts (MaxRiskAmount,
// MinFreeMarginUsd) stay in account currency.
enum ENUM_SCALE_MODE
  {
   SCALE_PRICE      = 0,     // Inputs are price distances ($/oz on gold)
   SCALE_ATR        = 1      // Inputs are multiples of the M15 ATR
  };
//--- Zone record ---------------------------------------------------
struct ZoneRec
  {
   int      type;         // ENUM_HEX_ZONE
   int      dir;          // +1 = support (buy zone), -1 = resistance (sell zone)
   datetime t1;           // zone left edge
   datetime t2;           // zone right edge (extended while active)
   double   top;
   double   bottom;
   double   maxPenet;     // deepest penetration ratio seen (0..1)
   bool     mitigated;    // true once penetrated beyond MitigatePct
   int      touches;      // number of times price entered the zone
   bool     touched;      // price has entered the zone since it became valid
   bool     insideNow;    // price is inside the zone on the current bar
   datetime tTouch;       // bar time of the first touch (drives the trigger window)
   datetime tCreate;
   datetime tTrade;       // last time we traded this zone (cooldown)
   bool     traded;
   bool     valid;        // false = pending removal
  };

//--- Open-trade bookkeeping (needed for the report) -----------------
struct TradeRec
  {
   bool     used;
   long     ticket;       // POSITION ticket (0 until a pending fills)
   long     order;        // pending ORDER ticket (0 once filled / for market entries)
   int      dir;
   string   sigType;      // zone type label that produced the signal
   int      confluence;
   double   entry;
   double   sl;
   double   tp;
   double   riskDist;     // stop distance in POINTS (the R unit)
   double   lots;
   double   atr;
   double   spreadPts;
   double   mae;
   double   mfe;
   double   peak;         // best price seen in our favour (drives the trail)
   datetime tOpen;        // position open time; 0 while a limit is still pending
   datetime tPlaced;      // ticket creation time (fills can lag placement)
   datetime tBE;          // 0 until breakeven applied
   int      tp1Done;
   datetime tLastBar;
  };

//--- Globals -------------------------------------------------------
ZoneRec   g_zones[];
TradeRec  g_rec[8];
int       g_zoneMax   = 120;
datetime  g_barTime   = 0;      // time of the last processed bar
int       g_tickCount = 0;
double    g_ddPeak    = 0.0;
double    g_dayStart  = 0.0;
int       g_dayKey    = 0;
int       g_tradesToday = 0;
bool      g_killed    = false;
bool      g_dayKilled = false;   // daily-loss halt: cleared by the day roll (g_killed is not)
string    g_dayReason = "";
string    g_killReason= "";
int       g_sigCount  = 0;
datetime  g_lastSigBar[2];      // last signal bar per direction
double    g_setupDist = 0.0;    // distance from price to the zone being evaluated
double    g_bestEntry = 0.0;    // geometry of the winning zone this evaluation
double    g_bestSl    = 0.0;
double    g_bestTp    = 0.0;
// Point equivalents of the distance inputs, computed from Point (and from ATR
// when ScaleMode = SCALE_ATR) so the EA behaves identically on a 2-digit gold
// feed and on a 3-digit index.
double    g_maxSpreadPts   = 45.0;
double    g_minStopPts     = 120.0;
double    g_maxStopPts     = 1400.0;
double    g_maxEntryPts    = 700.0;
double    g_maxEmaDistPts  = 900.0;
double    g_minTrendSlope  = 15.0;
double    g_minSwingPts    = 120.0;
double    g_beOffsetPts    = 5.0;
// Price units that "1.00" of a distance input is worth: 1.0 in SCALE_PRICE,
// the M15 ATR in SCALE_ATR. Set by ComputePointEquivalents().
double    g_scaleUnit      = 1.0;
string    g_setupMsg  = "scanning...";
double    g_atr       = 0.0;
int       g_trend     = 0;
string    g_trendMsg  = "";
// The point size the thresholds were last derived from. Point is not reliable at
// OnInit on a cold terminal, so this is what says whether they still match the
// symbol in front of us.
double    g_pointUsed = 0.0;
double    g_scaleUsed = 0.0;
double    g_swingHigh = 0.0;    // last confirmed structure level (resistance)
double    g_swingLow  = 0.0;    // last confirmed structure level (support)
int       g_lastBreakDir = 0;   // last structure side that produced a breaker block

// MT5 plumbing ------------------------------------------------------
CTrade    trade;
int       g_atrHandle   = INVALID_HANDLE;
int       g_emaFastH    = INVALID_HANDLE;
int       g_emaSlowH    = INVALID_HANDLE;
string    g_csvName     = "";       // the event CSV the container mirrors
datetime  g_startedAt   = 0;        // TimeLocal of OnInit (a chart that never ticks stalls too)
datetime  g_lastTickLocal = 0;
datetime  g_lastHeartbeat = 0;
int       g_lastStallLog  = 0;
string    g_lastSkipKey   = "";
datetime  lastSkipAt      = 0;
bool      g_tickStalled   = false;
datetime  g_stallSince    = 0;
bool      g_notReady      = false;  // cold terminal: no symbol data yet (not logged in)
string    g_notReadyWhy   = "";
datetime  g_lastNotReadyLog = 0;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
// Section headers are static inputs: they appear in the dialog and in the .set
// file, and they cannot be edited by accident.
sinput string  S0_Gen              = "=== General ===";
input int     MagicNumber          = 20261015;
input string  TradeSymbol          = "";              // "" = chart symbol
input double  MaxSpreadDollars     = 0.45;            // max spread (see ScaleMode)
input double  MaxSlippagePoints    = 30.0;
input int     MaxOpenTrades        = 1;               // 1 position at a time = clean experiment

sinput string  S1_Exec             = "=== Execution mode ===";
input bool    DryRun               = false;           // true = compute+draw+log, never send orders
input int     MaxSignalsPerDay     = 6;               // demo tuning: cap sample noise, protect capital
input bool    RequireNewBar        = true;            // evaluate on closed bars only (non-repainting)
input bool    CloseOnWeekend       = true;            // flat before Friday close (demo brokers gap)
input int     StopTradingHourUTC   = 21;              // no new entries at/after this hour (server time)
input int     StartTradingHourUTC  = 1;               // no new entries before this hour
// 0 = both directions. On a symbol whose spikes are one-sided (Deriv's Boom
// indices only ever spike UP) a short is on the wrong side of the only move
// that matters, so -1/0/+1 is here rather than hard-coded.
input int     TradeDirection       = 0;               // +1 = long only, -1 = short only

sinput string  S2_Trend            = "=== Trend filter ===";
input int     TrendTimeframe       = 60;              // 60 = H1 trend over M15 entries
input ENUM_TREND_MODE TrendMode    = TREND_BOTH;
input int     FastEMAPeriod        = 21;
input int     SlowEMAPeriod        = 50;
input int     TrendSwingLookback   = 5;               // bars each side for H1 swing points
input double  MinTrendSlopeDollars = 0.15;            // slow EMA must move this far over N bars
input int     TrendSlopeBars       = 6;
input double  MaxDistFromEmaDollars= 9.00;            // chase guard: skip entries this far beyond EMA

sinput string  S3_Swing            = "=== Structure / swing detection ===";
input int     SwingLookback        = 3;               // bars each side for an M15 swing
input double  MinSwingRangeDollars = 1.20;            // ignore micro-swings smaller than this
input double  MinDisplacementPct   = 55.0;            // displacement candle: body >= this % of range
input double  MinDisplacementAtr   = 1.10;            // and body >= this x ATR

sinput string  S4_Fvg              = "=== Fair Value Gaps ===";
input bool    UseFVG               = true;
input int     FvgMinSizeAtrPct     = 55;              // gap >= this % of ATR (kills noise gaps)
input int     FvgMaxSizeAtrPct     = 420;             // and <= this % of ATR (skip vacuum gaps)
input double  MitigatePct          = 50.0;            // zone dies after this % penetration
input double  EntryZonePct         = 62.0;            // limit sits this % deep into the gap
input int     MaxZoneAgeBars       = 180;             // drop zones older than this many bars
input bool    RequireFVGConfluence = true;            // entry must also touch breaker/mitigation
input int     ConfluenceLookback   = 60;              // bars of history searched for confluence

sinput string  S5_Breaker          = "=== Breaker blocks ===";
input bool    UseBreaker           = true;
input double  BreakerMinAtr        = 0.70;            // minimum block height in ATR
input double  BreakerMaxAtr        = 6.0;             // maximum block height in ATR

sinput string  S6_Mitig            = "=== Mitigation blocks ===";
input bool    UseMitigation        = true;
input int     MitigConsolBars      = 4;               // low-range consolidation bars before the break
input double  MitigConsolAtrMax    = 0.65;            // that cluster must be tighter than this x ATR
input double  MitigBreakAtr        = 1.20;            // displacement away must be >= this x ATR

sinput string  S7_Trigger          = "=== Entry trigger ===";
input ENUM_ENTRY_MODEL EntryModel  = ENTRY_LIMIT;     // LIMIT = wait at zone, TRIGGER = rejection candle
input double  MaxEntryDistanceDollars = 7.00;         // don't chase a zone further than this
input double  MinRejectionWickPct  = 30.0;            // rejection wick as % of trigger candle range
input double  MinTriggerRangeAtr   = 0.35;            // trigger candle must be meaningful
input double  MinTriggerClosePct   = 45.0;            // close back toward our side this % of range
input int     MaxBarsSinceTouch    = 6;               // bars allowed between touch and trigger
input bool    AllowMarketEntry     = true;            // reserved: see the note in the README
input int     LimitExpiryBars      = 4;               // pending order lifetime (bars)

sinput string  S8_Risk             = "=== Risk / money ===";
input double  RiskPercent          = 0.0;             // 0 = use FixedLot; 1.0 = risk 1% of equity
input double  FixedLot             = 0.01;
input double  MaxLot               = 0.02;            // hard cap, whatever the risk maths says
input double  MaxMarginUsagePct    = 50.0;            // margin for the new position <= this % of equity
input double  StopBufferAtrPct     = 25.0;            // stop beyond the zone by this % of ATR
input double  MinStopDollars       = 1.20;            // floor: never risk less than this stop
input double  MaxStopDollars       = 14.00;           // skip setups whose stop is absurdly wide
input double  MaxRiskAmount        = 0.0;             // 0 = off; e.g. 50.00 = never risk more than $50
input ENUM_SCALE_MODE ScaleMode    = SCALE_PRICE;     // see ENUM_SCALE_MODE

sinput string  S9_Exits            = "=== Exits (winners are given room) ===";
input ENUM_EXIT_MODE ExitMode      = EXIT_FIXED_RR;
input double  Tp1RR                = 1.0;             // first target, in R
input double  Tp1Percent           = 30.0;            // ... closing this % (was 50: it capped every win)
input double  Tp2RR                = 4.0;             // runner target, in R (was 2.5)
// Once the stop is locked at Tp1RR or better, the fixed target has done its job:
// the trail can now carry the runner past Tp2RR, which is the only way one trade
// turns into 6R-10R instead of 1.75R. Off = the old "close at Tp2RR" behaviour.
input bool    LetWinnersRun        = true;
// Lock ladder: a step function of R-multiples that ratchets the stop toward
// profit and never back. This is the "protect the win" half of trailing - the
// ATR trail below only starts once the trade is in profit, so without this a
// spike can round-trip a 3R winner back to break-even.
input bool    UseProfitLock        = true;
input double  LockTrigger1         = 1.0;             // once the trade has seen this many R...
input double  LockFloor1           = 0.30;            // ...the stop is at least this many R in profit
input double  LockTrigger2         = 2.0;
input double  LockFloor2           = 1.00;
input double  LockTrigger3         = 3.0;
input double  LockFloor3           = 2.00;
input double  LockTrigger4         = 4.0;
input double  LockFloor4           = 3.00;
input double  BreakEvenTriggerRR   = 0.80;            // move stop to entry after this R
input double  BreakEvenOffsetDollars = 0.05;          // lock-in above entry when BE triggers
input bool    UseAtrTrail          = true;
input double  TrailAtrMult         = 2.20;
input double  TrailStartRR         = 1.0;             // trail activates after this R
input bool    TrailFromPeak        = true;            // trail the best price seen, not the last bar
input double  TrailMinStepAtr      = 0.25;            // ignore trail moves smaller than this x ATR
input int     MinHoldBars          = 2;               // avoid getting shaken out instantly

sinput string  S10_Guard           = "=== Demo safety guards ===";
input double  MaxDailyLossPct      = 5.0;             // stop trading for the day after this drawdown
input double  MaxTotalDrawdownPct  = 15.0;            // stop trading entirely (kill switch)
input double  MinFreeMarginUsd     = 40.0;            // margin guard - accounts are margin-bound
input bool    FlattenOnKill        = true;

sinput string  S11_Report          = "=== Reporting / visual ===";
input bool    WriteCsvLogs         = true;
input int     LogEveryNTicks       = 300;             // equity snapshot cadence
input bool    ShowDashboard        = true;
input bool    DrawZones            = true;
input int     ZoneMaxDraw          = 12;              // zones drawn on chart (perf)
input string  Prefix               = "HEX";
input color   ClrBuyZone           = clrDodgerBlue;
input color   ClrSellZone          = clrTomato;
input color   ClrBreaker           = clrMediumOrchid;
input color   ClrMitigation        = clrDarkGoldenrod;

sinput string  S12_Deploy          = "=== Container plumbing ===";
// The status line is written from a terminal TIMER, so it keeps moving when the
// chart stops being ticked. The container reads it (deploy/scripts/healthcheck.sh)
// and turns a stale one into ONE alert and a terminal restart.
input int     InpHeartbeatSec      = 60;
input int     InpTickStallSec      = 300;             // log a dead feed after this long (0 = never)
input int     InpSkipLogSec        = 60;              // repeat the same SKIP at most this often
input string  InpLogDir            = "HEX-Logs";

// ------------------------------------------------------------------
// DISABLED LEGACY - filters/features that do NOT serve a breaker +
// mitigation + FVG trend strategy. Kept commented so the reasoning is
// auditable, not deleted. Re-enable only if a logged report proves it.
// ------------------------------------------------------------------
// RsiPeriod / RsiBuyMax / RsiSellMin   OFF: a mean-reversion oscillator fights
//                                      trend entries; a gap in an uptrend is
//                                      not "overbought", it is intent.
// StochasticPeriod                     OFF: redundant with the rejection
//                                      candle trigger, and laggier.
// MacdPeriod / BollingerPeriod / AdxMin OFF: MACD confirms AFTER the move,
//                                      band-walking makes false "no-trade".
// UseNewsFilter                        OFF: no free calendar; the session gate
//                                      is honest instead.
// UseMartingale / UseGridAveraging     OFF: doubles down on losers / converts
//                                      a 1R loss into a 5R loss.
// RecoveryMode / CounterTrendFVG / TradeAsianSession / CloseOnTrendFlip
// TrailingStopPoints (fixed)           OFF: ignore regime; the ATR trail with
//                                      the profit-lock ladder replaces it.
// ProfitLockPercent (bank-at-amount)   OFF: discretionary; R-multiples are
//                                      measurable and are what the report uses.

//+------------------------------------------------------------------+
//| Broker / identity helpers                                        |
//+------------------------------------------------------------------+
// USD value of 1 lot x 1 point. Gold (contract 100, 2 digits): $1 / lot / pt.
double UsdPerPointPerLot()
  {
   double v  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0) ts = _Point;
   if(v <= 0.0 || ts <= 0.0) return(0.0);
   return(v * _Point / ts);
  }

double ContractSize()
  {
   return(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE));
  }

double SpreadPoints()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return(0.0);
   return((ask - bid) / _Point);
  }

int DayKey(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(s.year * 10000 + s.mon * 100 + s.day);
  }

int HourUtc(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(s.hour);
  }

int DayOfWeekUtc(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(s.day_of_week);
  }

string ZoneName(int t)
  {
   if(t == HEX_ZONE_FVG)     return("FVG");
   if(t == HEX_ZONE_BREAKER) return("BREAKER");
   if(t == HEX_ZONE_MITIG)   return("MITIGATION");
   return("?");
  }

string DirName(int d)
  {
   if(d > 0) return("BUY");
   if(d < 0) return("SELL");
   return("FLAT");
  }

//+------------------------------------------------------------------+
//| Log paths + CSV                                                     |
//|                                                                     |
//| MQL5 sandboxes file access to MQL5/Files, so "HEX-Logs/x.csv" is    |
//| <data>/MQL5/Files/HEX-Logs/x.csv - which is exactly the folder the  |
//| entrypoint mirrors and the push watcher tails. There is no Common   |
//| folder on this side (MT4 had one; nothing in the container reads it).|
//|                                                                     |
//| Two kinds of file, on purpose:                                     |
//|   HEX-Logs/HEX-FVG-Breaker-YYYYMMDD.csv   events (BUY/CLOSE/ERROR/  |
//|                                           SKIP/BLOWN/FEED/DEINIT)   |
//|   HEX-Logs/analysis/*.csv                 the research tables      |
//| The push watcher globs "$dir"/*.csv and matches ,BUY, etc. anywhere  |
//| in the row, so the research tables live one level down: otherwise   |
//| every trades.csv row would buzz a second time, and a zones.csv row   |
//| carrying "BUY" would buzz for a zone that was only drawn.           |
//+------------------------------------------------------------------+
string LogDir()
  {
   return(InpLogDir);
  }

string AnalysisDir()
  {
   return(InpLogDir + "/analysis");
  }

void EnsureFolders()
  {
   FolderCreate(InpLogDir);
   FolderCreate(AnalysisDir());
  }

// Append semantics, the MT5 way: FILE_READ|FILE_WRITE opens an existing file
// without truncating it, then seek to the end. A file that does not exist yet is
// created, and the header is written when the size is zero.
void CsvAppend(const string file, const string header, const string line)
  {
   if(!WriteCsvLogs) return;
   string path = AnalysisDir() + "/" + file;
   int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print(Prefix, " LOG ERROR append ", path, " err=", GetLastError());
      return;
     }
   bool fresh = (FileSize(h) == 0);
   FileSeek(h, 0, SEEK_END);
   if(fresh) FileWriteString(h, header + "\r\n");
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

string CsvTime(datetime t)
  {
   return(TimeToString(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS));
  }

//+------------------------------------------------------------------+
//| Event log, heartbeat, blown marker                                 |
//+------------------------------------------------------------------+
// <time>,<EVENT>,<symbol>,<equity>,<detail>
//
// The EVENT field is what deploy/scripts/entrypoint.sh matches (",BUY,", ",CLOSE,",
// ",BLOWN,", ",ERROR,", ",FEED,", ",DEINIT,", ",SKIP,") to send a phone push, so
// it is a separate field and never a word inside a sentence.
void LogEvent(string ev, string detail)
  {
   if(WriteCsvLogs)
     {
      if(StringLen(g_csvName) == 0)
        {
         MqlDateTime d;
         TimeToStruct(TimeCurrent(), d);
         g_csvName = StringFormat("%s/HEX-FVG-Breaker-%04d%02d%02d.csv",
                                  InpLogDir, d.year, d.mon, d.day);
        }
      int h = FileOpen(g_csvName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h != INVALID_HANDLE)
        {
         FileSeek(h, 0, SEEK_END);
         FileWriteString(h, StringFormat("%s,%s,%s,%.2f,%s\n",
                        TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                        ev, _Symbol, AccountInfoDouble(ACCOUNT_EQUITY), detail));
         FileClose(h);
        }
     }
   // The Experts tab: the entrypoint mirrors MQL5/Logs into docker logs, so this
   // line is what a human reads when something went wrong at 03:00.
   Print("[", Prefix, "] ", ev, ": ", detail);
  }

// SKIP is throttled: a guard that refuses on every tick writes the same sentence
// a few thousand times an hour and buries the BUY/ERROR rows it exists to
// explain. One line per reason per InpSkipLogSec; a NEW reason is logged at once.
// The key is the category, never the text - the figures inside it change on every
// tick.
void LogSkip(string key, string detail)
  {
   // TimeLocal, not TimeCurrent: the server clock is the last tick's, so it
   // freezes when the feed does - and "no tick for Nm" would then be logged once
   // and throttled for ever, which is the silence it exists to break.
   if(key == g_lastSkipKey && InpSkipLogSec > 0 && TimeLocal() - lastSkipAt < InpSkipLogSec)
      return;
   g_lastSkipKey = key;
   lastSkipAt    = TimeLocal();
   LogEvent("SKIP", detail);
  }

int SecondsSinceTick()
  {
   datetime since = (g_lastTickLocal > 0) ? g_lastTickLocal : g_startedAt;
   if(since <= 0) return(0);
   int age = (int)(TimeLocal() - since);
   return(age < 0 ? 0 : age);
  }

void WriteHeartbeat()
  {
   g_lastHeartbeat = TimeLocal();
   string name = InpLogDir + "/HEX-FVG-Breaker-heartbeat.txt";
   int h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   // "<local time>|tick_age=<s>|equity=..|trades=..|sel=..|spread=..".
   // mtime answers "is the EA loaded"; tick_age answers "is the chart being
   // fed" - the two silences of 2026-11-02 that looked identical from outside;
   // sel=0 means the symbol is not subscribed at all, which no restart can fix.
   FileWriteString(h, StringFormat("%s|tick_age=%d|equity=%.2f|trades=%d|sel=%d|spread=%d|open=%d|zones=%d|trend=%d\n",
                   TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
                   SecondsSinceTick(), AccountInfoDouble(ACCOUNT_EQUITY), g_tradesToday,
                   (int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT),
                   (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                   CountPositions(), ArraySize(g_zones), g_trend));
   FileClose(h);
  }

string BlownMarkerName() { return(InpLogDir + "/HEX-FVG-Breaker-BLOWN.txt"); }

bool BlownMarkerExists()
  {
   int h = FileOpen(BlownMarkerName(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return(false);
   FileClose(h);
   return(true);
  }

void WriteBlownMarker(string msg)
  {
   int h = FileOpen(BlownMarkerName(), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, msg + "\n");
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| One terminal, one robot                                            |
//+------------------------------------------------------------------+
// [StartUp] attaches the expert to the chart the terminal opens, and a restored
// chart reloads its own copy out of the profile. A terminal that ends up with two
// charts therefore runs two copies of this EA on one magic number: two signal
// engines, two ideas of "the" position, both modifying the same stop. MaxOpenTrades
// caps the exposure, but the statistics, the CSVs and the notifications all stop
// meaning anything.
//
// The claim is a TEMPORARY global (it dies with the terminal) that the owner
// refreshes from the timer, so a copy whose owner was removed or crashed can be
// taken over after two minutes instead of locking the volume out for ever.
// The chart id does NOT fit in a global without losing digits (ChartID() is a
// long above 2^53 and GlobalVariableSet stores a double), so it is kept as two
// exact halves: a shift and a subtraction, no rounding, no big literal.
#define HEX_CLAIM_STALE_SECS 120

string ClaimKey() { return("HEXFVG-" + IntegerToString(MagicNumber)); }

void SetClaimOwner(const long id)
  {
   long hi = (id >> 32);
   GlobalVariableSet(ClaimKey() + "-hi", (double)hi);
   GlobalVariableSet(ClaimKey() + "-lo", (double)(id - (hi << 32)));
  }

bool ClaimOwnerIs(const long id)
  {
   long hi = (id >> 32);
   return((long)GlobalVariableGet(ClaimKey() + "-hi") == hi &&
          (long)GlobalVariableGet(ClaimKey() + "-lo") == (id - (hi << 32)));
  }

bool ClaimChart()
  {
   string lease = ClaimKey() + "-seen";
   long   me    = ChartID();
   long   seen  = (long)GlobalVariableGet(lease);
   if(GlobalVariableCheck(ClaimKey() + "-hi") && !ClaimOwnerIs(me) &&
      seen > 0 && (long)TimeLocal() - seen < HEX_CLAIM_STALE_SECS)
     {
      string msg = "another copy of this EA is already running on this terminal - this chart "
                   "refuses to start, so the two cannot trade the same account twice. The "
                   "container keeps exactly one chart; close the duplicate on the desktop.";
      LogEvent("ERROR", msg);
      Print(Prefix, ": ERROR - duplicate chart refused - ", msg);
      Alert("HEX-FVG-Breaker: duplicate chart refused - " + msg);
      return(false);
     }
   GlobalVariableSet(lease, (double)TimeLocal());
   GlobalVariableTemp(lease);
   SetClaimOwner(me);
   GlobalVariableTemp(ClaimKey() + "-hi");
   GlobalVariableTemp(ClaimKey() + "-lo");
   return(true);
  }

void RefreshClaim()
  {
   // Only the owner refreshes: a superseded copy that somehow still runs must not
   // keep a stale claim alive.
   if(ClaimOwnerIs(ChartID()))
     {
      GlobalVariableSet(ClaimKey() + "-seen", (double)TimeLocal());
      SetClaimOwner(ChartID());
     }
  }

//+------------------------------------------------------------------+
//| Is this chart even able to trade?                                  |
//|                                                                     |
//| Every field the EA logs about the symbol reads back out of the       |
//| terminal's cached description even when the broker no longer carries |
//| the name, so a chart that can never be ticked has looked perfectly    |
//| healthy: expert loaded, beat moving, tick age climbing to 900, not    |
//| one trade. 2026-11-06 and 2026-11-08 were exactly that. The three     |
//| questions are now asked out loud, in the CSV the container mirrors,  |
//| which is what makes them answerable from a phone.                    |
//+------------------------------------------------------------------+
bool symbolNameReported = false;   // "not in the server's list" was already said

bool SymbolOnServer(const string sym)
  {
   int total = SymbolsTotal(false);            // everything the server carries
   for(int i = 0; i < total; i++)
      if(SymbolName(i, false) == sym) return(true);
   return(false);
  }

// The names the server does carry that look like the one on the chart: the
// operator needs a choice, not a diagnosis ("Volatility Boom 300 Index, ..."),
// because the fix is to set MT5_SYMBOL to one of them.
string SimilarSymbols(const string needle, const int cap)
  {
   string out = "";
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string n = SymbolName(i, false);
      if(StringFind(n, needle) < 0) continue;
      if(out != "") out += ", ";
      out += n;
      if(StringLen(out) > cap)
        {
         out += ", ...";
         break;
        }
     }
   return(out == "" ? "none" : out);
  }

// First word of the chart symbol: "Volatility" for "Volatility Boom 400 Index",
// "XAU" for "XAUUSD". It is what the "these names do exist" hint searches for, so
// it comes from the chart and not from a constant.
string SymbolFamily()
  {
   int sp = StringFind(_Symbol, " ");
   if(sp > 0) return(StringSubstr(_Symbol, 0, sp));
   return(_Symbol);
  }

// When the last quote the terminal knows about arrived: on a dead chart this is
// the one number that says how long "nothing is trading" has been true.
string LastQuoteTime()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.time == 0) return("never");
   return(TimeToString(t.time, TIME_DATE | TIME_SECONDS));
  }

void EnsureSubscribed()
  {
   int total = SymbolsTotal(false);
   if(total > 0 && !SymbolOnServer(_Symbol))
     {
      symbolNameReported = true;
      LogEvent("ERROR", StringFormat("%s is NOT in the server's symbol list (%d symbols on %s). "
               "A chart opened on a name the broker does not offer still draws out of the terminal's "
               "cache and this expert still loads - but no quote can ever arrive, so there is no "
               "entry, no exit and nothing trading. Names on this server containing \"%s\": %s. "
               "Set MT5_SYMBOL to the exact one and the container re-opens the chart.",
               _Symbol, total, AccountInfoString(ACCOUNT_SERVER), SymbolFamily(),
               SimilarSymbols(SymbolFamily(), 400)));
      return;
     }
   int sel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT);
   int vis  = (int)SymbolInfoInteger(_Symbol, SYMBOL_VISIBLE);
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   LogEvent("INIT", StringFormat("symbol: select=%d visible=%d spread=%d points, trade mode=%d, "
            "symbols on server=%d, last quote=%s (server time)",
            sel, vis, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), mode, total, LastQuoteTime()));
   if(sel == 0 || vis == 0)
     {
      bool ok = SymbolSelect(_Symbol, true);
      LogEvent(ok ? "INIT" : "ERROR", StringFormat("%s was not subscribed (select=%d visible=%d) - "
               "SymbolSelect(%s, true) -> %s. A symbol that is not selected receives no quotes at "
               "all, which looks exactly like a dead feed and trades nothing.",
               _Symbol, sel, vis, _Symbol, ok ? "ok" : "FAILED"));
     }
   if(mode == (int)SYMBOL_TRADE_MODE_DISABLED)
      LogEvent("ERROR", StringFormat("%s is on the server but DISABLED for trading on this account - "
               "the chart can be ticked, but every order will be refused", _Symbol));
  }

// Called from the timer while the chart is stalled: the one thing the EA can do
// about a lost subscription from inside. A name the server does not carry cannot
// be fixed in this loop - but if the list was still empty when OnInit ran (a
// terminal that had not synchronized yet), the fault is named here instead, once.
void RetrySubscribe()
  {
   int total = SymbolsTotal(false);
   if(total > 0 && !SymbolOnServer(_Symbol))
     {
      if(!symbolNameReported) EnsureSubscribed();
      return;
     }
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SELECT) != 0) return;
   bool ok = SymbolSelect(_Symbol, true);
   LogEvent(ok ? "INIT" : "ERROR", StringFormat("the stall is a lost subscription - re-selecting %s "
            "in Market Watch -> %s", _Symbol, ok ? "ok" : "FAILED"));
  }

//+------------------------------------------------------------------+
//| Init                                                               |
//+------------------------------------------------------------------+
// What the terminal can see right now. This one line is the difference
// between "the EA is broken" and "the account never signed in" - and on a
// fresh Wine volume that is exactly what a bootloop hides.
string TerminalState()
  {
   return(StringFormat("connected=%d trade_allowed=%d algo=%d account=%d server=%s symbols=%d",
          (int)TerminalInfoInteger(TERMINAL_CONNECTED),
          (int)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
          (int)MQLInfoInteger(MQL_TRADE_ALLOWED),
          (int)AccountInfoInteger(ACCOUNT_LOGIN),
          AccountInfoString(ACCOUNT_SERVER),
          SymbolsTotal(false)));
  }

// Handles, retried instead of fatal.
// A terminal that has not logged in yet has no data for the symbol, so
// iATR/iMA answer INVALID_HANDLE. Returning INIT_FAILED for that makes MT5
// REMOVE the expert - and a removed expert never trades again until someone
// re-attaches it by hand. The watchdog then sees an empty chart, restarts the
// terminal, the container restarts, and a login that would have sorted itself
// out in half a minute becomes a loop that trades nothing. So: create what is
// missing, report what cannot be created, and stay attached.
bool EnsureHandles()
  {
   if(g_atrHandle == INVALID_HANDLE)
      g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(g_emaFastH == INVALID_HANDLE)
      g_emaFastH = iMA(_Symbol, (ENUM_TIMEFRAMES)TrendTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaSlowH == INVALID_HANDLE)
      g_emaSlowH = iMA(_Symbol, (ENUM_TIMEFRAMES)TrendTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_atrHandle != INVALID_HANDLE && g_emaFastH != INVALID_HANDLE && g_emaSlowH != INVALID_HANDLE);
  }

int OnInit()
  {
   EnsureFolders();

   // First line out, before anything can fail: if the journal shows this and
   // nothing after it, the fault is below; if the journal shows "loaded
   // successfully" and never this, the terminal never called OnInit at all.
   Print(Prefix, ": OnInit on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)Period()),
         " | ", TerminalState());

   if(StringLen(TradeSymbol) > 0 && TradeSymbol != _Symbol)
     {
      Alert(Prefix, ": attach this EA to a ", TradeSymbol, " chart (current chart is ", _Symbol, ").");
      LogEvent("ERROR", "wrong chart: wants " + TradeSymbol + ", got " + _Symbol);
      return(INIT_SUCCEEDED);
     }

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print(Prefix, ": NOTE - the defaults were sized for XAUUSD. Current symbol ", _Symbol,
            " needs MaxSpreadDollars / lot inputs re-checked (or ScaleMode = SCALE_ATR).");

   if(FastEMAPeriod >= SlowEMAPeriod)
     {
      Print(Prefix, ": INPUT ERROR - FastEMAPeriod (", FastEMAPeriod, ") must be < SlowEMAPeriod (",
            SlowEMAPeriod, ")");
      Alert(Prefix, ": FastEMAPeriod must be < SlowEMAPeriod");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(!UseFVG && !UseBreaker && !UseMitigation)
     {
      Print(Prefix, ": INPUT ERROR - all three detectors are off, nothing to trade");
      Alert(Prefix, ": all three detectors are off - nothing to trade.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Indicators as HANDLES: MQL5 has no iATR(shift) call, and a handle created in
   // OnInit is what the tester can precompute (one made inside OnTick would
   // rebuild history on every tick). See EnsureHandles() for why a missing
   // handle is NOT a reason to return INIT_FAILED.
   if(!EnsureHandles())
     {
      g_notReady        = true;
      g_notReadyWhy     = "no " + _Symbol + " data yet (" + TerminalState() + ")";
      g_lastNotReadyLog = TimeLocal();
      Print(Prefix, ": NOT READY - ", g_notReadyWhy,
            " - the chart is attached but the terminal cannot see this symbol yet");
      Print(Prefix, ": NOT READY - staying attached and retrying every minute. MT5 REMOVES an");
      Print(Prefix, ": NOT READY - expert whose OnInit fails, so failing here is what turns a");
      Print(Prefix, ": NOT READY - login that is still in progress into a restart loop.");
      LogEvent("ERROR", "NOT READY - " + g_notReadyWhy +
               " - check MT5_LOGIN/MT5_PASSWORD/MT5_SERVER and that the account is authorized");
     }
   else
      Print(Prefix, ": handles ok (atr=", g_atrHandle, " ema", FastEMAPeriod, "=", g_emaFastH,
            " ema", SlowEMAPeriod, "=", g_emaSlowH, ")");

   if(!ClaimChart())
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((int)MaxSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ArrayResize(g_zones, 0);
   ComputePointEquivalents(0.0);
   for(int i = 0; i < 8; i++) g_rec[i].used = false;
   g_ddPeak    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStart  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayKey    = DayKey(TimeCurrent());
   g_lastSigBar[0] = 0;
   g_lastSigBar[1] = 0;
   g_barTime   = 0;

   // The heartbeat is a lease on ATTACHMENT, never on ticks: a terminal timer
   // fires whether or not the chart is being fed.
   g_startedAt = TimeLocal();
   EventSetTimer(1);

   if(DryRun) Print(Prefix, ": DRY RUN - signals are logged and drawn, no orders are sent.");
   Print(Prefix, " v4.01 on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)Period()), " | digits=", _Digits,
         " | $", DoubleToString(UsdPerPointPerLot(), 4), " per point per lot | contract=",
         DoubleToString(ContractSize(), 0));
   Print(Prefix, ": logs -> ", LogDir(), " (events) and ", AnalysisDir(), " (tables)");
   // What this chart can actually SEE - before anything claims it is healthy.
   EnsureSubscribed();

   LogEvent("INIT", StringFormat("v4.01 %s %s | fvg=%d breaker=%d mit=%d | trend=%s | entries=%s | "
            "tp1 %.0f%% @%.2fR, runner %.2fR%s | lock ladder %s | trail %.2fxATR from %.2fR",
            _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
            (int)UseFVG, (int)UseBreaker, (int)UseMitigation,
            EnumToString(TrendMode), EnumToString(EntryModel),
            Tp1Percent, Tp1RR, Tp2RR, (LetWinnersRun ? " (target removed once locked)" : ""),
            (UseProfitLock ? "on" : "off"), TrailAtrMult, TrailStartRR));
   LogEvent("INIT", StringFormat("broker: stops=%d freeze=%d points, vol min=%.2f max=%.2f step=%.2f, "
            "digits=%d, spread gate=%.1fpt, scale=%s",
            (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
            (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
            SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
            SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
            SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
            (int)_Digits, g_maxSpreadPts, EnumToString(ScaleMode)));

   // A blown / killed account stays that way across restarts: the marker is on
   // the volume, which is the only thing a restart cannot take away.
   if(BlownMarkerExists())
     {
      g_killed = true;
      g_killReason = "BLOWN marker on the volume - reset the demo (or delete HEX-FVG-Breaker-BLOWN.txt) to resume";
      Print(Prefix, ": ", g_killReason);
     }
   WriteHeartbeat();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| $/point thresholds, from Point (and from ATR in SCALE_ATR mode)    |
//+------------------------------------------------------------------+
// Gold quotes differ between brokers (2 or 3 digits) and a Deriv index is a
// different price entirely, so every distance gate is derived from Point - and,
// when ScaleMode = SCALE_ATR, from the M15 ATR - instead of being a literal.
// The ATR is not available at OnInit on a cold terminal, so atrPrice = 0 keeps
// the previous (price-unit) scale until the first closed bar arrives.
void ComputePointEquivalents(double atrPrice)
  {
   double p = _Point;
   if(p <= 0.0) p = 0.01;
   double unit = 1.0;
   if(ScaleMode == SCALE_ATR && atrPrice > 0.0) unit = atrPrice;

   g_pointUsed      = p;
   g_scaleUnit      = unit;
   g_scaleUsed      = unit;
   g_maxSpreadPts   = MathMax(1.0, MaxSpreadDollars     * unit / p);
   g_minStopPts     = MathMax(1.0, MinStopDollars       * unit / p);
   g_maxStopPts     = MathMax(g_minStopPts, MaxStopDollars * unit / p);
   g_maxEntryPts    = MathMax(1.0, MaxEntryDistanceDollars * unit / p);
   g_maxEmaDistPts  = MaxDistFromEmaDollars * unit / p;
   g_minTrendSlope  = MinTrendSlopeDollars  * unit / p;
   g_minSwingPts    = MathMax(1.0, MinSwingRangeDollars * unit / p);
   // The break-even offset has to clear the broker's tick, or "lock in $0.05"
   // becomes "do not move the stop": floor it at ten points.
   g_beOffsetPts    = MathMax(10.0, BreakEvenOffsetDollars * unit / p);

   Print(Prefix, ": scale ", (ScaleMode == SCALE_ATR ? "ATR" : "price"), " | unit=",
         DoubleToString(unit, _Digits), " point=", DoubleToString(p, _Digits),
         " -> maxSpread=", DoubleToString(g_maxSpreadPts, 0), "pt",
         " stopRange=", DoubleToString(g_minStopPts, 0), "-", DoubleToString(g_maxStopPts, 0), "pt",
         " maxEntry=", DoubleToString(g_maxEntryPts, 0), "pt");
  }

//+------------------------------------------------------------------+
//| Main tick                                                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_tickCount++;
   g_lastTickLocal = TimeLocal();
   if(g_tickStalled)
     {
      g_tickStalled = false;
      LogEvent("FEED", StringFormat("ticks are back after %dm - it was the feed, not the EA",
               (int)((TimeLocal() - g_stallSince) / 60)));
      g_stallSince = 0;
     }
   if(g_lastHeartbeat == 0 || TimeLocal() - g_lastHeartbeat >= InpHeartbeatSec)
      WriteHeartbeat();

   // Point is not trustworthy at OnInit on a cold terminal: two starts of the
   // same demo account reported digits=4/point=0.0001 and digits=2/point=0.01,
   // and every distance gate is derived once. Re-derive whenever the symbol's
   // point (or the ATR scale) moves, and say so in the log.
   if(_Point != g_pointUsed || (ScaleMode == SCALE_ATR && g_scaleUnit != g_scaleUsed))
      ComputePointEquivalents(g_atr);

   datetime barNow = Bt(0);
   bool newBar = (barNow != 0 && barNow != g_barTime);

   // --- 1. housekeeping: day roll, kill switches, equity snapshot ---
   Housekeeping(newBar);
   // Flattening on a kill switch must not stop the zone engine: the report keeps
   // logging zones/signals while flat, so you can study what it missed.
   if((g_killed || g_dayKilled) && FlattenOnKill && TradingAllowed()) FlattenAll("kill switch");

   // --- 2. register closed bars (zones are only built from closed candles) ---
   if(newBar)
     {
      g_barTime = barNow;
      ScanClosedBar();
      UpdateZones();
      PruneZones();
      if(DrawZones) RenderZones();
      ExpirePendings();
     }

   // --- 3. manage anything open (BE, lock ladder, trail, TP1, expiry) ---
   AdoptFilledPendings();
   ManageOpenPositions();

   // --- 4. evaluate a setup. On bar close for non-repainting behaviour,
   //         or every tick if RequireNewBar = false.
   bool evaluate = newBar || (!RequireNewBar && g_tickCount % 4 == 0);
   if(evaluate && !g_killed) EvaluateSetup();

   // --- 5. reporting / dashboard ---
   if(ShowDashboard) RenderDashboard();
   // Snapshot cadence: an explicit int, because "%" on a double is not an MQL5
   // operator (MathMax returns one) and LogEveryNTicks can be set to 0.
   int everyNTicks = (int)MathMax(50.0, (double)LogEveryNTicks);
   if(WriteCsvLogs && everyNTicks > 0 && g_tickCount % everyNTicks == 0) SnapshotEquity();
  }

//+------------------------------------------------------------------+
//| Timer: the heartbeat, the claim lease, and the dead-feed line.    |
//| This is the only writer of the status line, so its age means "the  |
//| EA is not being called" - not "the market is quiet".              |
//+------------------------------------------------------------------+
void OnTimer()
  {
   RefreshClaim();
   if(g_lastHeartbeat == 0 || TimeLocal() - g_lastHeartbeat >= InpHeartbeatSec)
      WriteHeartbeat();

   // A terminal that was still logging in when this chart opened: retry the
   // handles once a minute, and say so when they arrive - that is the moment
   // the EA starts trading, so it belongs in the CSV, not only in the journal.
   if(g_notReady)
     {
      if(EnsureHandles())
        {
         g_notReady = false;
         Print(Prefix, ": READY - ", _Symbol, " has data now (", TerminalState(), ")");
         LogEvent("INIT", StringFormat("READY - recovered after %dm: %s",
                  (int)((TimeLocal() - g_startedAt) / 60), TerminalState()));
         ComputePointEquivalents(g_atr);
        }
      else if(g_lastNotReadyLog == 0 || TimeLocal() - g_lastNotReadyLog >= 300)
        {
         g_lastNotReadyLog = TimeLocal();
         Print(Prefix, ": still NOT READY - ", g_notReadyWhy);
        }
     }

   if(InpTickStallSec <= 0) return;
   int idle = SecondsSinceTick();
   if(idle < InpTickStallSec) return;
   // One line at the threshold, then one every five minutes: a stalled feed can
   // last hours, and a line a second would bury the fact that there is only one
   // thing wrong. push_watcher turns the first one into a buzz.
   if(g_lastStallLog > 0 && (int)TimeLocal() - g_lastStallLog < 300) return;
   g_lastStallLog = (int)TimeLocal();
   if(!g_tickStalled)
     {
      g_tickStalled = true;
      g_stallSince  = TimeLocal();
     }
   LogSkip("no-ticks", StringFormat("%dm without a tick on %s - the EA is attached and beating, "
           "the chart is not being fed (no entry, no exit, nothing trading)",
           idle / 60, _Symbol));
   // ...and the one repair the EA can attempt itself: a chart that lost its Market
   // Watch selection receives nothing, and re-selecting it starts the quotes again
   // without anyone touching the desktop.
   RetrySubscribe();
  }

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
   if(ClaimOwnerIs(ChartID()))
      GlobalVariableSet(ClaimKey() + "-seen", 0);
   // The row's own timestamp is TimeCurrent() like every other row, so the local
   // clock goes in the text: on a dead feed the server clock is frozen and the
   // one thing that matters is when this actually happened.
   LogEvent("DEINIT", StringFormat("unloaded at %s local: %s; last tick %dm ago",
            TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
            DeinitReason(reason), SecondsSinceTick() / 60));
   if(g_atrHandle != INVALID_HANDLE)     IndicatorRelease(g_atrHandle);
   if(g_emaFastH != INVALID_HANDLE)      IndicatorRelease(g_emaFastH);
   if(g_emaSlowH != INVALID_HANDLE)      IndicatorRelease(g_emaSlowH);
   ObjectsDeleteAll(0, Prefix);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Equity / day guards                                                |
//+------------------------------------------------------------------+
double Equity()
  {
   return(AccountInfoDouble(ACCOUNT_EQUITY));
  }

void Housekeeping(bool newBar)
  {
   double eq = Equity();
   if(eq > g_ddPeak) g_ddPeak = eq;

   int dk = DayKey(TimeCurrent());
   if(dk != g_dayKey)
     {
      g_dayKey      = dk;
      g_dayStart    = eq;
      g_tradesToday = 0;
      g_dayKilled   = false;
      g_dayReason   = "";
      g_csvName     = "";        // roll the event CSV at midnight
      CsvAppend("daily.csv",
                "date,open_equity,close_equity,trades,signals,peak,notes",
                IntegerToString(dk) + "," + DoubleToString(g_dayStart, 2) + "," +
                DoubleToString(eq, 2) + "," + IntegerToString(CountPositions()) + "," +
                IntegerToString(g_sigCount) + "," + DoubleToString(g_ddPeak, 2) + ",roll");
      LogEvent("INIT", "new trading day: " + IntegerToString(dk) + ", daily counters reset");
     }

   // --- week-end flatten (demo brokers gap over the weekend) ---
   if(CloseOnWeekend && DayOfWeekUtc(TimeCurrent()) == 5 && HourUtc(TimeCurrent()) >= 19 &&
      CountPositions() > 0 && TradingAllowed())
      FlattenAll("friday close");

   // --- total drawdown kill switch ---
   if(!g_killed && MaxTotalDrawdownPct > 0.0 && g_ddPeak > 0.0)
     {
      double dd = (g_ddPeak - eq) / g_ddPeak * 100.0;
      if(dd >= MaxTotalDrawdownPct)
        {
         g_killed = true;
         g_killReason = "total drawdown " + DoubleToString(dd, 1) + "% >= " +
                        DoubleToString(MaxTotalDrawdownPct, 1) + "%";
         LogEvent("BLOWN", "KILL SWITCH: " + g_killReason + " | equity " +
                  DoubleToString(eq, 2) + " peak " + DoubleToString(g_ddPeak, 2) +
                  (FlattenOnKill ? " | everything closed, EA halted" : " | no new trades, open trades left"));
         WriteBlownMarker("KILL SWITCH " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) +
                          ": " + g_killReason + " (equity " + DoubleToString(eq, 2) + ")");
         Alert(Prefix, " KILL: ", g_killReason);
        }
     }

   // --- daily loss limit: flat for the rest of the day, not for ever ---
   // MT4 v3 set the same g_killed flag here, so ONE bad day halted the robot
   // until somebody restarted the terminal - the daily limit silently became a
   // permanent kill switch. It has its own flag now, cleared by the day roll,
   // and the row is written once at the trip (the container dedupes the shape).
   if(!g_killed && !g_dayKilled && MaxDailyLossPct > 0.0 && g_dayStart > 0.0)
     {
      double dl = (g_dayStart - eq) / g_dayStart * 100.0;
      if(dl >= MaxDailyLossPct)
        {
         g_dayKilled = true;
         g_dayReason = "daily loss " + DoubleToString(dl, 1) + "% of " +
                       DoubleToString(g_dayStart, 2) + " >= " + DoubleToString(MaxDailyLossPct, 1) + "%";
         LogEvent("SKIP", "daily loss limit hit (" + g_dayReason + "): flat until the next day");
         Print(Prefix, " daily loss limit hit, flat for today");
        }
     }
  }

void SnapshotEquity()
  {
   CsvAppend("equity.csv",
             "time,server_time,balance,equity,open_positions,floating_pnl,free_margin,dd_from_peak_pct",
             CsvTime(TimeCurrent()) + "," + IntegerToString((int)TimeLocal()) + "," +
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," + DoubleToString(Equity(), 2) + "," +
             IntegerToString(CountPositions()) + "," +
             DoubleToString(Equity() - AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
             DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + "," +
             DoubleToString(g_ddPeak > 0 ? (g_ddPeak - Equity()) / g_ddPeak * 100.0 : 0.0, 2));
  }

//+------------------------------------------------------------------+
//| Candle / indicator helpers                                         |
//+------------------------------------------------------------------+
// MT5 has no predefined series. These are the MT4 Open[]/High[]/Low[]/Close[]/
// Time[] reads, one for one, so the strategy code below did not have to be
// rewritten around a rates array (and cannot silently read the wrong shift).
double   Op(int shift) { return(iOpen(_Symbol, PERIOD_CURRENT, shift));  }
double   Hi(int shift) { return(iHigh(_Symbol, PERIOD_CURRENT, shift));  }
double   Lo(int shift) { return(iLow(_Symbol, PERIOD_CURRENT, shift));   }
double   Cl(int shift) { return(iClose(_Symbol, PERIOD_CURRENT, shift)); }
datetime Bt(int shift) { return(iTime(_Symbol, PERIOD_CURRENT, shift));  }
int      BarsAvail()   { return(Bars(_Symbol, PERIOD_CURRENT));          }

// ATR of the chart timeframe, by shift, from the handle made in OnInit.
double AtrVal(int shift)
  {
   if(g_atrHandle == INVALID_HANDLE || shift < 0) return(0.0);
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_atrHandle, 0, 0, shift + 2, b) < shift + 1) return(0.0);
   return(b[shift]);
  }

double Ema(int handle, int shift)
  {
   if(handle == INVALID_HANDLE || shift < 0) return(0.0);
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, 0, shift + 1, b) < shift + 1) return(0.0);
   return(b[shift]);
  }

double BodySize(int shift)   { return(MathAbs(Cl(shift) - Op(shift))); }
double RangeSize(int shift)  { return(Hi(shift) - Lo(shift)); }
double WickDown(int shift)   { return(MathMin(Op(shift), Cl(shift)) - Lo(shift)); }
double WickUp(int shift)     { return(Hi(shift) - MathMax(Op(shift), Cl(shift))); }
bool   IsBull(int shift)     { return(Cl(shift) > Op(shift)); }
bool   IsBear(int shift)     { return(Cl(shift) < Op(shift)); }

// A displacement candle is a strong directional close. It is what leaves an
// imbalance behind and what invalidates an old level with intent.
bool IsDisplacement(int shift, int dir, double atr)
  {
   if(atr <= 0.0) return(false);
   double rng = RangeSize(shift);
   if(rng <= 0.0) return(false);
   double bod = BodySize(shift);
   if(bod / rng * 100.0 < MinDisplacementPct) return(false);
   if(bod < MinDisplacementAtr * atr)          return(false);
   if(dir > 0 && !IsBull(shift)) return(false);
   if(dir < 0 && !IsBear(shift)) return(false);
   return(true);
  }

// Confirmed swing high: highest high with SwingLookback bars on each side.
// Swings below MinSwingRangeDollars are noise and get skipped - a breaker built
// from a micro-swing is a breaker that gets run over.
bool IsSwingHigh(int shift)
  {
   if(shift < SwingLookback + 1) return(false);
   if(shift + SwingLookback > BarsAvail() - 1) return(false);
   double h = Hi(shift);
   if(Hi(shift) - Lo(shift) < g_minSwingPts * _Point) return(false);
   for(int i = 1; i <= SwingLookback; i++)
     {
      if(Hi(shift - i) > h)  return(false);
      if(Hi(shift + i) >= h) return(false);
     }
   return(true);
  }

bool IsSwingLow(int shift)
  {
   if(shift < SwingLookback + 1) return(false);
   if(shift + SwingLookback > BarsAvail() - 1) return(false);
   double l = Lo(shift);
   if(Hi(shift) - Lo(shift) < g_minSwingPts * _Point) return(false);
   for(int i = 1; i <= SwingLookback; i++)
     {
      if(Lo(shift - i) < l)  return(false);
      if(Lo(shift + i) <= l) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Zone storage                                                       |
//+------------------------------------------------------------------+
void ZoneLog(int i, string ev, string note)
  {
   if(!WriteCsvLogs || i < 0 || i >= ArraySize(g_zones)) return;
   CsvAppend("zones.csv",
             "time,event,zone_type,dir,t1,t2,top,bottom,height,max_penet_pct,touches,note",
             CsvTime(TimeCurrent()) + "," + ev + "," + ZoneName(g_zones[i].type) + "," +
             DirName(g_zones[i].dir) + "," + CsvTime(g_zones[i].t1) + "," + CsvTime(g_zones[i].t2) + "," +
             DoubleToString(g_zones[i].top, _Digits) + "," + DoubleToString(g_zones[i].bottom, _Digits) +
             "," + DoubleToString(g_zones[i].top - g_zones[i].bottom, _Digits) + "," +
             DoubleToString(g_zones[i].maxPenet * 100.0, 1) + "," +
             IntegerToString(g_zones[i].touches) + "," + note);
  }

int ZoneAdd(int type, int dir, datetime t1, datetime t2, double top, double bottom, double atr)
  {
   if(atr <= 0.0 || top <= bottom) return(-1);

   // Breaker blocks are anchored to the displacing body. If that body is thinner
   // than the floor, grow it outward in the correct direction: a bullish block
   // hangs below its top, a bearish block rests on its bottom.
   if(type == HEX_ZONE_BREAKER)
     {
      if(top - bottom < BreakerMinAtr * atr)
        {
         if(dir > 0) bottom = top - BreakerMinAtr * atr;
         else        top    = bottom + BreakerMinAtr * atr;
        }
      if(top - bottom > BreakerMaxAtr * atr) return(-1);
     }
   if(type == HEX_ZONE_MITIG && top - bottom < 0.08 * atr) return(-1);
   if(top - bottom > BreakerMaxAtr * atr) return(-1);

   // merge with an overlapping live zone instead of stacking duplicates
   for(int m = 0; m < ArraySize(g_zones); m++)
     {
      if(!g_zones[m].valid) continue;
      if(g_zones[m].type == type && g_zones[m].dir == dir &&
         MathAbs(g_zones[m].top - top) < 0.15 * atr &&
         MathAbs(g_zones[m].bottom - bottom) < 0.15 * atr)
         return(-1);
     }

   int n = ArraySize(g_zones);
   if(n >= g_zoneMax)
     {
      for(int s = 0; s < n - 1; s++) g_zones[s] = g_zones[s + 1];   // drop oldest
      ArrayResize(g_zones, n - 1);
      n--;
     }
   ArrayResize(g_zones, n + 1);
   int i = n;
   g_zones[i].type      = type;
   g_zones[i].dir       = dir;
   g_zones[i].t1        = t1;
   g_zones[i].t2        = t2;
   g_zones[i].top       = top;
   g_zones[i].bottom    = bottom;
   g_zones[i].maxPenet  = 0.0;
   g_zones[i].mitigated = false;
   g_zones[i].touches   = 0;
   g_zones[i].touched   = false;
   g_zones[i].insideNow = false;
   g_zones[i].tTouch    = 0;
   g_zones[i].tCreate   = t2;
   g_zones[i].tTrade    = 0;
   g_zones[i].traded    = false;
   g_zones[i].valid     = true;
   ZoneLog(i, "OPEN", "created");
   return(i);
  }

void ZoneKill(int i, string why)
  {
   if(i < 0 || i >= ArraySize(g_zones)) return;
   if(!g_zones[i].valid) return;
   g_zones[i].valid = false;
   ZoneLog(i, "CLOSE", why);
  }

//+------------------------------------------------------------------+
//| 1. FAIR VALUE GAP - 3-candle imbalance left by displacement      |
//|    shift 1 = just closed, 2 = middle, 3 = oldest of the pattern   |
//+------------------------------------------------------------------+
void DetectFvg(double atr)
  {
   if(!UseFVG || BarsAvail() < 6) return;

   if(Lo(1) > Hi(3) && IsBull(2))                       // bullish imbalance
     {
      double top = Lo(1), bottom = Hi(3), sz = top - bottom;
      if(Cl(1) <= Cl(3)) return;
      if(sz < FvgMinSizeAtrPct / 100.0 * atr) return;
      if(FvgMaxSizeAtrPct > 0 && sz > FvgMaxSizeAtrPct / 100.0 * atr) return;
      ZoneAdd(HEX_ZONE_FVG, +1, Bt(3), Bt(1), top, bottom, atr);
     }
   else if(Hi(1) < Lo(3) && IsBear(2))                  // bearish imbalance
     {
      double top = Lo(3), bottom = Hi(1), sz = top - bottom;
      if(Cl(1) >= Cl(3)) return;
      if(sz < FvgMinSizeAtrPct / 100.0 * atr) return;
      if(FvgMaxSizeAtrPct > 0 && sz > FvgMaxSizeAtrPct / 100.0 * atr) return;
      ZoneAdd(HEX_ZONE_FVG, -1, Bt(3), Bt(1), top, bottom, atr);
     }
  }

//+------------------------------------------------------------------+
//| 2. BREAKER BLOCK - a swing high/low that was broken with          |
//|    displacement. Old resistance becomes support (and vice versa). |
//|    The block body = the displacement candle that broke the level. |
//+------------------------------------------------------------------+
void DetectBreaker(double atr)
  {
   if(!UseBreaker || BarsAvail() < 8) return;

   // g_lastBreakDir remembers which side has already fired against the current
   // structure level. Without it, every bar that closes beyond the broken level
   // spawns another block and the zone list fills with duplicates of one move.
   // UpdateStructure() resets it when a fresh swing level is confirmed.

   // Did the just-closed candle break a prior swing high with intent?
   if(g_lastBreakDir != +1 && Cl(1) > g_swingHigh && g_swingHigh > 0.0 && IsBull(1))
     {
      if(IsDisplacement(1, +1, atr))
        {
         double top    = MathMax(Op(1), Cl(1));
         double bottom = MathMin(Op(1), Cl(1));
         if(top - g_swingHigh > 0.10 * atr)
           {
            if(ZoneAdd(HEX_ZONE_BREAKER, +1, Bt(1), Bt(1), top, bottom, atr) >= 0)
               g_lastBreakDir = +1;
           }
        }
     }
   // Did the just-closed candle break a prior swing low with intent?
   if(g_lastBreakDir != -1 && Cl(1) < g_swingLow && g_swingLow > 0.0 && IsBear(1))
     {
      if(IsDisplacement(1, -1, atr))
        {
         double top    = MathMax(Op(1), Cl(1));
         double bottom = MathMin(Op(1), Cl(1));
         if(g_swingLow - bottom > 0.10 * atr)
           {
            if(ZoneAdd(HEX_ZONE_BREAKER, -1, Bt(1), Bt(1), top, bottom, atr) >= 0)
               g_lastBreakDir = -1;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| 3. MITIGATION BLOCK - a tight consolidation (orders resting there)|
//|    that a displacement candle leaves behind. Price tends to be    |
//|    drawn back into it, then continues with the trend.             |
//+------------------------------------------------------------------+
void DetectMitigation(double atr)
  {
   if(!UseMitigation || BarsAvail() < MitigConsolBars + 6) return;

   // cluster = bars 2 .. MitigConsolBars+1 (older candles), displacement = bar 1
   double hi = -1e10, lo = 1e10;
   for(int k = 2; k <= MitigConsolBars + 1; k++)
     {
      if(Hi(k) > hi) hi = Hi(k);
      if(Lo(k) < lo) lo = Lo(k);
     }
   double cluster = hi - lo;
   if(cluster <= 0.0 || cluster > MitigConsolAtrMax * atr) return;

   if(IsDisplacement(1, +1, atr) && Cl(1) > hi)
      ZoneAdd(HEX_ZONE_MITIG, +1, Bt(MitigConsolBars + 1), Bt(2), hi, lo, atr);
   else if(IsDisplacement(1, -1, atr) && Cl(1) < lo)
      ZoneAdd(HEX_ZONE_MITIG, -1, Bt(MitigConsolBars + 1), Bt(2), hi, lo, atr);
  }

//+------------------------------------------------------------------+
//| Structure memory: track the most recent confirmed swing levels    |
//+------------------------------------------------------------------+
void UpdateStructure()
  {
   if(IsSwingLow(1 + SwingLookback))
     {
      g_swingLow = Lo(1 + SwingLookback);
      g_lastBreakDir = 0;
     }
   if(IsSwingHigh(1 + SwingLookback))
     {
      g_swingHigh = Hi(1 + SwingLookback);
      g_lastBreakDir = 0;
     }
  }

// Called once per closed bar: build the zone set.
void ScanClosedBar()
  {
   double atr = AtrVal(1);
   if(atr <= 0.0) return;
   g_atr = atr;
   // The distance gates are ATR multiples in SCALE_ATR mode, so they are
   // re-derived here, where the ATR is real (it is 0 at OnInit on a cold start).
   if(ScaleMode == SCALE_ATR && MathAbs(atr - g_scaleUsed) > atr * 0.02)
      ComputePointEquivalents(atr);
   UpdateStructure();
   DetectBreaker(atr);
   DetectMitigation(atr);
   DetectFvg(atr);
  }

//+------------------------------------------------------------------+
//| Zone lifecycle: penetration, mitigation, invalidation, pruning    |
//+------------------------------------------------------------------+
void UpdateZones()
  {
   double atr = g_atr;
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid) continue;

      double h = g_zones[i].top - g_zones[i].bottom;
      if(h <= 0.0) { ZoneKill(i, "degenerate"); continue; }

      // extend the right edge while the zone is alive
      if(Bt(0) > g_zones[i].t2) g_zones[i].t2 = Bt(0);

      bool inside = false;
      if(g_zones[i].dir > 0)
        {
         // support zone: penetration measured downward from the top
         if(Lo(1) < g_zones[i].top)
           {
            inside = true;
            double pen = (g_zones[i].top - Lo(1)) / h;
            if(pen > g_zones[i].maxPenet) g_zones[i].maxPenet = pen;
            // closed decisively through the far edge = structure broken, zone dead
            if(Cl(1) < g_zones[i].bottom - 0.15 * atr)
              { ZoneKill(i, "closed through"); continue; }
           }
        }
      else
        {
         if(Hi(1) > g_zones[i].bottom)
           {
            inside = true;
            double pen = (Hi(1) - g_zones[i].bottom) / h;
            if(pen > g_zones[i].maxPenet) g_zones[i].maxPenet = pen;
            if(Cl(1) > g_zones[i].top + 0.15 * atr)
              { ZoneKill(i, "closed through"); continue; }
           }
        }

      if(inside && !g_zones[i].insideNow)
        {
         g_zones[i].touches++;               // discrete visit, not per-bar
         g_zones[i].insideNow = true;
         if(!g_zones[i].touched)
           {
            g_zones[i].touched = true;
            g_zones[i].tTouch  = Bt(1);
            ZoneLog(i, "TOUCH", "first touch");
           }
         // The first visit is the trade we are looking for, so it is never killed
         // on depth alone. A second visit that digs past MitigatePct means the
         // orders sitting there have been consumed - done with it.
         if(g_zones[i].touches > 1 && g_zones[i].maxPenet * 100.0 >= MitigatePct)
           {
            g_zones[i].mitigated = true;
            ZoneKill(i, "mitigated " + DoubleToString(g_zones[i].maxPenet * 100.0, 0) + "% on visit " +
                     IntegerToString(g_zones[i].touches));
            continue;
           }
        }
      else if(!inside)
        {
         g_zones[i].insideNow = false;       // price left: next entry is a new visit
        }
     }
  }

void PruneZones()
  {
   int maxAgeSec = MaxZoneAgeBars * PeriodSeconds();
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid) continue;
      if(TimeCurrent() - g_zones[i].t2 > maxAgeSec) ZoneKill(i, "aged out");
     }
   // compact
   int n = 0;
   for(int i = 0; i < ArraySize(g_zones); i++)
      if(g_zones[i].valid) { g_zones[n] = g_zones[i]; n++; }
   ArrayResize(g_zones, n);
  }

// Count live zones of a given type/direction that overlap the price area of a
// zone index (used for the confluence requirement).
int CountConfluence(int excludeIdx, int dir, double ztop, double zbot)
  {
   int cnt = 0;
   int maxBars = ConfluenceLookback * PeriodSeconds();
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(i == excludeIdx) continue;
      if(!g_zones[i].valid) continue;
      if(g_zones[i].dir != dir) continue;
      if(TimeCurrent() - g_zones[i].t2 > maxBars) continue;
      // must overlap vertically with the FVG we want to trade into
      if(g_zones[i].bottom <= ztop && g_zones[i].top >= zbot) cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
//| Trend determination                                              |
//+------------------------------------------------------------------+
// Swing scan on the trend timeframe: fills the last two confirmed swing highs
// and lows. Returns true when at least two of each were found.
bool ScanTrendSwings(double &h1, double &h2, double &l1, double &l2)
  {
   int fh = 0, fl = 0;
   int need = TrendSwingLookback;
   ENUM_TIMEFRAMES ttf = (ENUM_TIMEFRAMES)TrendTimeframe;
   int maxS = (int)MathMin(240.0, (double)(iBars(_Symbol, ttf) - 2 * need - 2));
   for(int s = 1 + need; s <= maxS; s++)
     {
      bool isH = true, isL = true;
      double hh = iHigh(_Symbol, ttf, s);
      double ll = iLow(_Symbol, ttf, s);
      for(int k = 1; k <= need; k++)
        {
         if(iHigh(_Symbol, ttf, s - k) > hh) isH = false;
         if(iHigh(_Symbol, ttf, s + k) >= hh) isH = false;
         if(iLow(_Symbol, ttf, s - k) < ll)  isL = false;
         if(iLow(_Symbol, ttf, s + k) <= ll) isL = false;
        }
      if(isH)
        {
         if(fh == 0) { h1 = hh; fh = 1; }
         else if(fh == 1) { h2 = hh; fh = 2; }
        }
      if(isL)
        {
         if(fl == 0) { l1 = ll; fl = 1; }
         else if(fl == 1) { l2 = ll; fl = 2; }
        }
      if(fh >= 2 && fl >= 2) return(true);
     }
   return(fh >= 2 && fl >= 2);
  }

int DetermineTrend()
  {
   double fastNow = Ema(g_emaFastH, 1);
   double slowNow = Ema(g_emaSlowH, 1);
   double fastOld = Ema(g_emaFastH, 1 + TrendSlopeBars);
   double slowOld = Ema(g_emaSlowH, 1 + TrendSlopeBars);

   // EMA direction requires the fast line above the slow AND both rising/falling:
   // a flat stack is a range, and ranges are where gap strategies bleed.
   int emaDir = 0;
   double slopeUp   = (slowNow - slowOld) / _Point;
   double slopeDown = (slowOld - slowNow) / _Point;
   if(fastNow > slowNow && fastNow > fastOld && slopeUp   >= g_minTrendSlope) emaDir = +1;
   if(fastNow < slowNow && fastNow < fastOld && slopeDown >= g_minTrendSlope) emaDir = -1;

   // Structure direction: higher highs + higher lows = uptrend.
   int strDir = 0;
   double h1 = 0, h2 = 0, l1 = 0, l2 = 0;
   if(ScanTrendSwings(h1, h2, l1, l2))
     {
      if(h1 > h2 && l1 > l2) strDir = +1;
      if(h1 < h2 && l1 < l2) strDir = -1;
     }

   g_trendMsg = "ema=" + DirName(emaDir) + " struct=" + DirName(strDir) +
                " slope=" + DoubleToString(slopeUp > 0 ? slopeUp : -slopeDown, 0) + "pt";
   if(TrendMode == TREND_EMA)       return(emaDir);
   if(TrendMode == TREND_STRUCTURE) return(strDir);
   if(emaDir != 0 && emaDir == strDir) return(emaDir);
   return(0);
  }

//+------------------------------------------------------------------+
//| Rejection log - the "why no trade" file is what makes this        |
//| testable. Without it you cannot tell a bad filter from no filter. |
//+------------------------------------------------------------------+
void Reject(string reason, int dir, string detail, int zi = -1)
  {
   string zt = "", ztop = "", zbot = "";
   if(zi >= 0 && zi < ArraySize(g_zones))
     {
      zt   = ZoneName(g_zones[zi].type);
      ztop = DoubleToString(g_zones[zi].top, _Digits);
      zbot = DoubleToString(g_zones[zi].bottom, _Digits);
     }
   CsvAppend("rejections.csv",
             "time,bar_time,reason,dir,zone_type,zone_top,zone_bottom,spread_pts,atr,dist_pts,equity,trend,detail",
             CsvTime(TimeCurrent()) + "," + TimeToString(Bt(0), TIME_DATE | TIME_MINUTES) + "," + reason + "," +
             DirName(dir) + "," + zt + "," + ztop + "," + zbot + "," +
             DoubleToString(SpreadPoints(), 1) + "," + DoubleToString(g_atr, _Digits) + "," +
             DoubleToString(g_setupDist, 0) + "," + DoubleToString(Equity(), 2) + "," +
             DirName(g_trend) + "," + detail);
   g_setupMsg = reason;
  }

//+------------------------------------------------------------------+
//| Trade bookkeeping (one record per live position, keyed by ticket) |
//+------------------------------------------------------------------+
int RecSlot(long ticket)
  {
   for(int i = 0; i < 8; i++)
      if(g_rec[i].used && g_rec[i].ticket == ticket && ticket != 0) return(i);
   return(-1);
  }

// A pending is tracked by its ORDER ticket until it fills; this finds that row.
int RecOrderSlot(long orderTicket)
  {
   for(int i = 0; i < 8; i++)
      if(g_rec[i].used && g_rec[i].order == orderTicket && orderTicket != 0) return(i);
   return(-1);
  }

int RecFree()
  {
   for(int i = 0; i < 8; i++) if(!g_rec[i].used) return(i);
   return(-1);
  }

string SessionName(datetime t)
  {
   int h = HourUtc(t);
   if(h >= 1 && h < 8)  return("ASIA");
   if(h >= 8 && h < 13) return("LONDON");
   if(h >= 13 && h < 18) return("NEWYORK");
   if(h >= 18 && h < 22) return("POST_NY");
   return("LATE");
  }

// One CSV line per closed position. R-multiple = realised $ / planned $ risk,
// which is the only number comparable across lot sizes and stop distances.
//
// closeTime / closePrice are what the broker actually did; they fall back to
// "now" and the current bid only when the history could not be read.
void RecWrite(int i, string exitReason, double profit,
              datetime closeTime = 0, double closePrice = 0.0)
  {
   datetime tEnd = (closeTime > 0) ? closeTime : TimeCurrent();
   double   pEnd = (closePrice > 0.0) ? closePrice : NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits);
   double riskUsd = g_rec[i].lots * g_rec[i].riskDist * UsdPerPointPerLot();
   double rMult   = (riskUsd > 0.0) ? profit / riskUsd : 0.0;
   int holdBars   = (int)((tEnd - g_rec[i].tOpen) / PeriodSeconds());
   if(holdBars < 0) holdBars = 0;
   CsvAppend("trades.csv",
             "ticket,login,symbol,tf,type,signal_type,confluence,open_time,close_time,entry,sl,tp,exit_price,"
             "lots,stop_pts,spread_pts_at_entry,pnl_net,r_multiple,risk_usd,mae_pts,mfe_pts,mfe_r,hold_bars,"
             "session,exit_reason,balance_after,atr_at_entry",
             IntegerToString((long)g_rec[i].ticket) + "," +
             IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "," + _Symbol + "," +
             IntegerToString(PeriodSeconds() / 60) + "," + DirName(g_rec[i].dir) + "," +
             g_rec[i].sigType + "," + IntegerToString(g_rec[i].confluence) + "," +
             CsvTime(g_rec[i].tOpen) + "," + CsvTime(tEnd) + "," +
             DoubleToString(g_rec[i].entry, _Digits) + "," + DoubleToString(g_rec[i].sl, _Digits) + "," +
             DoubleToString(g_rec[i].tp, _Digits) + "," + DoubleToString(pEnd, _Digits) + "," +
             DoubleToString(g_rec[i].lots, 2) + "," + DoubleToString(g_rec[i].riskDist, 0) + "," +
             DoubleToString(g_rec[i].spreadPts, 1) + "," +
             DoubleToString(profit, 2) + "," +
             DoubleToString(rMult, 2) + "," +
             DoubleToString(riskUsd, 2) + "," +
             DoubleToString(g_rec[i].mae, 0) + "," + DoubleToString(g_rec[i].mfe, 0) + "," +
             DoubleToString(g_rec[i].riskDist > 0 ? g_rec[i].mfe / g_rec[i].riskDist : 0.0, 2) + "," +
             IntegerToString(holdBars) + "," +
             SessionName(g_rec[i].tOpen) + "," + exitReason + "," +
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
             DoubleToString(g_rec[i].atr, _Digits));
  }

void RecClose(long ticket, string exitReason, double profit,
              datetime closeTime = 0, double closePrice = 0.0)
  {
   int i = RecSlot(ticket);
   if(i < 0) return;
   RecWrite(i, exitReason, profit, closeTime, closePrice);
   g_rec[i].used = false;
  }

//+------------------------------------------------------------------+
//| Guards                                                             |
//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   return(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED));
  }

bool GuardsAllow(int dir, string &why)
  {
   why = "";
   if(g_killed)                          { why = g_killReason; return(false); }
   if(g_dayKilled)                       { why = g_dayReason; return(false); }
   if(CountOpen() >= MaxOpenTrades)      { why = "max open trades reached"; return(false); }
   if(CountPendings() >= 2)              { why = "pending queue full"; return(false); }
   if(g_tradesToday >= MaxSignalsPerDay) { why = "daily signal cap (" + IntegerToString(MaxSignalsPerDay) + ")"; return(false); }
   if(SpreadPoints() > g_maxSpreadPts)
      { why = "spread " + DoubleToString(SpreadPoints(), 1) + " > " + DoubleToString(g_maxSpreadPts, 1); return(false); }

   int h = HourUtc(TimeCurrent());
   if(h < StartTradingHourUTC || h >= StopTradingHourUTC)
      { why = "outside session window (" + IntegerToString(StartTradingHourUTC) + "-" +
              IntegerToString(StopTradingHourUTC) + ")"; return(false); }

   if(CloseOnWeekend && DayOfWeekUtc(TimeCurrent()) == 5 && h >= 19)
      { why = "friday close, staying flat"; return(false); }

   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < MinFreeMarginUsd + 20.0)
      { why = "free margin " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + " below floor"; return(false); }

   if(TradeDirection > 0 && dir < 0) { why = "TradeDirection = long only"; return(false); }
   if(TradeDirection < 0 && dir > 0) { why = "TradeDirection = short only"; return(false); }

   // one signal per direction per bar
   int slot = (dir > 0 ? 0 : 1);
   if(g_lastSigBar[slot] == Bt(0)) { why = "already traded this bar"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Position / pending helpers                                         |
//+------------------------------------------------------------------+
int CountOpen()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      n++;
     }
   return(n);
  }

bool IsPendingType(long type)
  {
   return(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
          type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP);
  }

int CountPendings()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(IsPendingType(OrderGetInteger(ORDER_TYPE))) n++;
     }
   return(n);
  }

int CountPositions()
  {
   return(CountOpen() + CountPendings());
  }

bool PositionAlive(long tk)
  {
   return(tk != 0 && PositionSelectByTicket((ulong)tk));
  }

bool OrderAlive(long tk)
  {
   return(tk != 0 && OrderSelect((ulong)tk));
  }

// The newest position this EA owns on this chart. Used to adopt a fill: MQL5
// does not promise that a filled limit keeps its order ticket as the position
// ticket (and a netting account reuses one position for everything), so the
// position is found by magic + symbol instead of assumed.
long NewestOwnedPosition()
  {
   long best     = 0;
   long bestTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long t = (long)PositionGetInteger(POSITION_TIME);
      if(t >= bestTime) { bestTime = t; best = (long)tk; }
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| Sizing                                                             |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minl = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxl = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   if(minl <= 0.0) minl = 0.01;
   if(maxl <= 0.0) maxl = 100.0;
   lots = MathFloor(lots / step + 0.000000001) * step;
   if(lots < minl) lots = minl;
   if(lots > maxl) lots = maxl;
   return(NormalizeDouble(lots, 2));
  }

// Margin the position would consume, in account currency. MQL5 has
// OrderCalcMargin (MT4 did not) - and it is the only honest way to ask.
double MarginNeeded(double lots, ENUM_ORDER_TYPE type, double price)
  {
   double m = 0.0;
   if(lots <= 0.0 || price <= 0.0) return(1e10);
   if(OrderCalcMargin(type, _Symbol, lots, price, m)) return(m);
   return(1e10);
  }

// Lot sizing. RiskPercent drives it; MaxLot and the margin guard cap it.
// On a small account the margin guard is what bites first - that is a fact of
// the contract size, not a bug, and it is logged so it stays visible.
double CalcLots(double stopDistPts, ENUM_ORDER_TYPE type, double price, string &whyBlock)
  {
   whyBlock = "";
   double upl = UsdPerPointPerLot();
   if(upl <= 0.0 || stopDistPts <= 0.0)
     { whyBlock = "tick value unavailable"; return(0.0); }

   double lots = FixedLot;
   if(RiskPercent > 0.0)
     {
      double riskUsd = Equity() * RiskPercent / 100.0;
      if(MaxRiskAmount > 0.0 && riskUsd > MaxRiskAmount) riskUsd = MaxRiskAmount;
      lots = riskUsd / (stopDistPts * upl);
     }
   if(lots > MaxLot) lots = MaxLot;

   double mMax   = Equity() * MaxMarginUsagePct / 100.0;
   double perLot = MarginNeeded(1.0, type, price);
   if(perLot > 0.0 && perLot < 1e9 && lots * perLot > mMax)
      lots = mMax / perLot;

   double minl = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minl <= 0.0) minl = 0.01;
   if(lots < minl)
     {
      // Name what WOULD have been enough: "cannot size" without the number is a
      // dead end at 03:00.
      double need = (perLot > 0.0 && perLot < 1e9)
                    ? minl * perLot * 100.0 / MathMax(1.0, MaxMarginUsagePct)
                    : 0.0;
      whyBlock = "margin: only " + DoubleToString(lots, 3) + " lots affordable, broker minimum " +
                 DoubleToString(minl, 2) + " (equity " + DoubleToString(Equity(), 2) + ")" +
                 (need > 0.0 ? ", needs a bankroll of >= " + DoubleToString(need, 2) : "");
      return(0.0);
     }
   return(NormalizeLots(lots));
  }

double BrokerStopLevelPts()
  {
   double sl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(sl <= 0.0) sl = 10.0;
   return(sl);
  }

//+------------------------------------------------------------------+
//| Signal + order dispatch                                            |
//+------------------------------------------------------------------+
void LogSignal(string mode, int dir, string sigLabel, int confl, double entry, double sl,
               double tp, double lots, string note)
  {
   double riskPts = MathAbs(entry - sl) / _Point;
   // Same unit rule as the entry body: price distance over points, or the
   // rr_planned column is 0.00 on every row and the report cannot use it.
   double rr = riskPts > 0.0 ? MathAbs(tp - entry) / _Point / riskPts : 0.0;
   CsvAppend("signals.csv",
             "time,bar_time,mode,dir,signal_label,confluence,entry,sl,tp,stop_pts,rr_planned,lots,"
             "risk_usd,spread_pts,atr,session,equity,trend,note",
             CsvTime(TimeCurrent()) + "," + TimeToString(Bt(0), TIME_DATE | TIME_MINUTES) + "," + mode + "," +
             DirName(dir) + "," + sigLabel + "," + IntegerToString(confl) + "," +
             DoubleToString(entry, _Digits) + "," + DoubleToString(sl, _Digits) + "," +
             DoubleToString(tp, _Digits) + "," + DoubleToString(riskPts, 0) + "," +
             DoubleToString(rr, 2) + "," + DoubleToString(lots, 2) + "," +
             DoubleToString(lots * riskPts * UsdPerPointPerLot(), 2) + "," +
             DoubleToString(SpreadPoints(), 1) + "," + DoubleToString(g_atr, _Digits) + "," +
             SessionName(TimeCurrent()) + "," + DoubleToString(Equity(), 2) + "," +
             DirName(g_trend) + "," + note);
   g_sigCount++;
   g_tradesToday++;
   int slot = (dir > 0 ? 0 : 1);
   g_lastSigBar[slot] = Bt(0);
  }

// Place (or pretend-place) the trade. Every branch is logged so the report can
// tell "no signal" apart from "signal but blocked".
void SendEntry(int dir, string sigLabel, int confl, bool pending, double entryPrice,
               double sl, double tp, double lots, int zi)
  {
   if(DryRun || !TradingAllowed())
     {
      LogSignal(DryRun ? "DRY" : "BLOCKED_NO_AUTOTRADE", dir, sigLabel, confl, entryPrice, sl, tp,
                lots, DryRun ? "dry run" : "auto-trading disabled in terminal");
      if(!DryRun) Reject("AUTOTRADE_DISABLED", dir, "terminal AutoTrading is off", zi);
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     { Reject("NO_QUOTE", dir, "one-sided or missing quote", zi); return; }

   double price = NormalizeDouble(pending ? entryPrice : (dir > 0 ? ask : bid), _Digits);
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   string comment = Prefix + " " + sigLabel;

   // A limit order must clear the broker stop level or it is refused outright.
   if(pending)
     {
      double minDist = BrokerStopLevelPts() * _Point;
      if(dir > 0 && ask - price < minDist)
        { Reject("LIMIT_TOO_CLOSE", dir, "gap to market " + DoubleToString((ask - price) / _Point, 0) + "pt", zi); return; }
      if(dir < 0 && price - bid < minDist)
        { Reject("LIMIT_TOO_CLOSE", dir, "gap to market " + DoubleToString((price - bid) / _Point, 0) + "pt", zi); return; }
     }

   datetime expiry = 0;
   if(pending && LimitExpiryBars > 0)
      expiry = TimeCurrent() + LimitExpiryBars * PeriodSeconds();
   // ORDER_TIME_SPECIFIED with expiry == 0 is refused by the server ("invalid
   // expiration"), so a preset that turns the expiry off gets a GTC order.
   ENUM_ORDER_TYPE_TIME ttime = (expiry > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   bool ok = false;
   if(pending)
     {
      if(dir > 0) ok = trade.BuyLimit(lots, price, _Symbol, sl, tp, ttime, expiry, comment);
      else        ok = trade.SellLimit(lots, price, _Symbol, sl, tp, ttime, expiry, comment);
     }
   else
     {
      if(dir > 0) ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
      else        ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
     }

   if(!ok)
     {
      Reject("ORDERSEND_FAIL", dir,
             "retcode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription() +
             " lots=" + DoubleToString(lots, 2) + " price=" + DoubleToString(price, _Digits) +
             " sl=" + DoubleToString(sl, _Digits) + " tp=" + DoubleToString(tp, _Digits), zi);
      return;
     }

   long  orderTk = (long)trade.ResultOrder();
   int   s       = RecFree();
   long  posTk   = 0;
   double openPx = price;
   if(!pending)
     {
      // A market order either filled (a position exists now) or it did not.
      Sleep(80);
      posTk = NewestOwnedPosition();
      if(posTk != 0 && PositionSelectByTicket((ulong)posTk))
        {
         openPx = PositionGetDouble(POSITION_PRICE_OPEN);
         sl     = PositionGetDouble(POSITION_SL);
         tp     = PositionGetDouble(POSITION_TP);
        }
     }

   if(s >= 0)
     {
      g_rec[s].used       = true;
      g_rec[s].ticket     = posTk;
      g_rec[s].order      = (pending ? orderTk : 0);
      g_rec[s].dir        = dir;
      g_rec[s].sigType    = sigLabel;
      g_rec[s].confluence = confl;
      g_rec[s].entry      = openPx;
      g_rec[s].sl         = sl;
      g_rec[s].tp         = tp;
      g_rec[s].riskDist   = MathAbs(openPx - sl) / _Point;
      g_rec[s].lots       = lots;
      g_rec[s].atr        = g_atr;
      g_rec[s].spreadPts  = SpreadPoints();
      g_rec[s].mae        = 0.0;
      g_rec[s].mfe        = 0.0;
      g_rec[s].peak       = openPx;
      // The clock starts when the trade exists, not when the ticket was placed.
      // A limit that sits unfilled for 6 bars must not arrive with MinHoldBars
      // already satisfied, or the tick that fills it may move the stop to
      // breakeven and stop the trade out at its own fill price.
      g_rec[s].tOpen      = (pending ? 0 : TimeCurrent());
      g_rec[s].tPlaced    = (pending ? TimeCurrent() : 0);
      g_rec[s].tBE        = 0;
      g_rec[s].tp1Done    = 0;
      g_rec[s].tLastBar   = Bt(0);
     }

   LogSignal(pending ? "PENDING" : "MARKET", dir, sigLabel, confl, openPx, sl, tp, lots,
             "ticket " + IntegerToString(posTk != 0 ? posTk : orderTk));
   // The container turns this row into the phone buzz (",BUY," is the pattern).
   LogEvent("BUY", StringFormat("%s %s %.2f lots @ %s sl %s tp %s conf=%d ticket=%s",
            DirName(dir), sigLabel, lots, DoubleToString(openPx, _Digits),
            DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), confl,
            IntegerToString(posTk != 0 ? posTk : orderTk)));
   if(zi >= 0 && zi < ArraySize(g_zones))
     {
      g_zones[zi].traded = true;
      g_zones[zi].tTrade = TimeCurrent();
      ZoneLog(zi, "TRADED", sigLabel);
     }
  }

// A stale limit is a trap: cancel it once it has outlived its setup. Age is read
// from the ORDER itself - a per-direction timestamp measured the next order
// against the previous one's placement time and expired it on the tick it was
// created.
void ExpirePendings()
  {
   if(LimitExpiryBars <= 0) return;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(!IsPendingType(type)) continue;
      datetime placed = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      int ageBars = (int)((Bt(0) - placed) / PeriodSeconds());
      if(ageBars <= LimitExpiryBars) continue;

      Reject("LIMIT_EXPIRED", (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) ? 1 : -1,
             "unfilled after " + IntegerToString(ageBars) + " bars at " +
             DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits), -1);
      if(!trade.OrderDelete(tk))
         Print(Prefix, " delete failed ticket ", IntegerToString((long)tk), " retcode=",
               IntegerToString((int)trade.ResultRetcode()));
      int s = RecOrderSlot((long)tk);
      if(s >= 0) g_rec[s].used = false;      // never traded, so no row is owed
     }
  }

// A filled limit is a new position: give the record the position ticket, start
// the hold clock, and claim the position before the manager can see it orphaned.
void AdoptFilledPendings()
  {
   for(int s = 0; s < 8; s++)
     {
      if(!g_rec[s].used) continue;
      if(g_rec[s].tOpen != 0) continue;          // already a live position
      if(g_rec[s].order == 0) continue;
      if(OrderAlive(g_rec[s].order)) continue;   // still waiting

      long pos = NewestOwnedPosition();
      if(pos == 0)
        {
         // The order is gone and no position is open. Two very different things
         // look like this from here:
         //   * the limit was cancelled or expired - it was never a trade, and a
         //     0.00R row for it would dilute expectancy and win rate;
         //   * the limit FILLED and the trade closed inside the same tick (a gap
         //     through the stop), which leaves deals but no position. On a
         //     netting account the position id of those deals is the order
         //     ticket, so the history answers it. MT4's ClosedOrderInfo made the
         //     same distinction; without it a real loss would vanish from the
         //     report - the one number nobody can afford to lose.
         double   pEnd = 0.0, pxEnd = 0.0;
         datetime tOpenHist = 0, tEnd = 0;
         if(ClosedPositionInfo(g_rec[s].order, pEnd, tOpenHist, tEnd, pxEnd))
           {
            g_rec[s].ticket = g_rec[s].order;
            g_rec[s].tOpen  = (tOpenHist > 0) ? tOpenHist : TimeCurrent();
            RecWrite(s, "STOP_LOSS", pEnd, tEnd, pxEnd);
            double riskUsd = g_rec[s].lots * g_rec[s].riskDist * UsdPerPointPerLot();
            LogEvent("CLOSE", StringFormat("%s %s filled and closed in the same tick, P/L %.2f = %+.2fR",
                     DirName(g_rec[s].dir), g_rec[s].sigType, pEnd,
                     riskUsd > 0.0 ? pEnd / riskUsd : 0.0));
            g_rec[s].used = false;
            continue;
           }
         LogEvent("SKIP", "pending " + IntegerToString(g_rec[s].order) + " left without filling (" +
                  DirName(g_rec[s].dir) + " " + g_rec[s].sigType + ") - not a trade, no row written");
         g_rec[s].used = false;
         continue;
        }
      if(!PositionSelectByTicket((ulong)pos)) { g_rec[s].used = false; continue; }
      // Another record may already own that position (the fill of one pending can
      // be the newest position while a different trade is already open). Adopting
      // it twice would write two rows for one trade.
      if(RecSlot(pos) >= 0 && RecSlot(pos) != s) { g_rec[s].used = false; continue; }
      g_rec[s].ticket = pos;
      g_rec[s].entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_rec[s].sl     = PositionGetDouble(POSITION_SL);
      g_rec[s].tp     = PositionGetDouble(POSITION_TP);
      g_rec[s].lots   = PositionGetDouble(POSITION_VOLUME);
      if(g_rec[s].riskDist <= 0.0)
         g_rec[s].riskDist = MathAbs(g_rec[s].entry - g_rec[s].sl) / _Point;
      g_rec[s].tOpen  = TimeCurrent();
      g_rec[s].peak   = g_rec[s].entry;
      Print(Prefix, " limit filled -> position ", IntegerToString(pos));
     }
  }

//+------------------------------------------------------------------+
//| THE SETUP                                                        |
//|   trend (H1) + unmitigated FVG (M15) + breaker/mitigation        |
//|   confluence + price already trading back into the zone.         |
//|   Then either a limit deep in the zone, or a rejection candle.   |
//+------------------------------------------------------------------+
void EvaluateSetup()
  {
   g_trend = DetermineTrend();
   if(g_atr <= 0.0) g_atr = AtrVal(1);
   if(g_atr <= 0.0) return;
   if(g_killed)   { Reject("KILLED", 0, g_killReason, -1); return; }
   if(g_dayKilled){ Reject("DAILY_LOSS", 0, g_dayReason, -1); return; }

   int bestIdx = -1, bestDir = 0, bestConfl = 0;
   double bestScore = -1e10;
   string rejReason = "", rejDetail = ""; int rejZone = -1;   // first reason only (no spam)

   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid || g_zones[i].traded || g_zones[i].mitigated) continue;
      if(!g_zones[i].touched) continue;                 // must already be trading back into us

      int dir = g_zones[i].dir;
      if(dir != g_trend) continue;                      // trend alignment only
      if(TradeDirection > 0 && dir < 0) continue;       // symbol/strategy direction filter
      if(TradeDirection < 0 && dir > 0) continue;

      bool isFvg = (g_zones[i].type == HEX_ZONE_FVG);
      int confl = CountConfluence(i, dir, g_zones[i].top, g_zones[i].bottom);
      if(isFvg && RequireFVGConfluence && confl == 0)
        {
         if(rejReason == "") { rejReason = "NO_CONFLUENCE"; rejDetail = "FVG alone, no overlapping breaker/mitigation"; rejZone = i; }
         continue;
        }

      // --- entry geometry: limit sits deep in the zone, stop behind it
      double zoneH = g_zones[i].top - g_zones[i].bottom;
      double entry, sl;
      if(dir > 0)
        {
         entry = g_zones[i].top    - zoneH * EntryZonePct / 100.0;
         sl    = g_zones[i].bottom - g_atr * StopBufferAtrPct / 100.0;
        }
      else
        {
         entry = g_zones[i].bottom + zoneH * EntryZonePct / 100.0;
         sl    = g_zones[i].top    + g_atr * StopBufferAtrPct / 100.0;
        }
      double riskPts = MathAbs(entry - sl) / _Point;
      if(riskPts < g_minStopPts)
        { sl = entry + (dir > 0 ? -1 : 1) * g_minStopPts * _Point; riskPts = MathAbs(entry - sl) / _Point; }
      if(riskPts > g_maxStopPts)
        {
         if(rejReason == "") { rejReason = "STOP_TOO_WIDE"; rejDetail = DoubleToString(riskPts, 0) + "pt"; rejZone = i; }
         continue;
        }

      double tp = 0.0;
      if(ExitMode == EXIT_FIXED_RR)  tp = entry + dir * riskPts * Tp2RR * _Point;
      if(ExitMode == EXIT_ZONE_RR)
        {
         tp = entry + dir * riskPts * Tp2RR * _Point;
         double zt = NextOpposingTarget(dir, entry);
         if(zt > 0.0 && MathAbs(zt - entry) / (riskPts * _Point) >= 1.2) tp = zt;
        }
      // A target closer than the risk it guards is a guaranteed-loser trade:
      // risking 1R to bank 0.5R wins the tick and loses the month. However the
      // target was chosen, never place one below 1R; fall back to exactly 1R.
      if(tp > 0.0 && MathAbs(tp - entry) < riskPts * _Point)
         tp = entry + dir * riskPts * _Point;

      // --- chase guards
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double dist = (dir > 0) ? (bid - entry) : (entry - bid);
      g_setupDist = dist / _Point;
      if(dist > g_maxEntryPts * _Point)
        {
         if(rejReason == "") { rejReason = "TOO_FAR"; rejDetail = DoubleToString(dist / _Point, 0) + "pt from zone"; rejZone = i; }
         continue;
        }
      double emaFast = Ema(g_emaFastH, 1);
      if(g_maxEmaDistPts > 0 && MathAbs(bid - emaFast) / _Point > g_maxEmaDistPts)
        {
         if(rejReason == "") { rejReason = "OVEREXTENDED"; rejDetail = "far from fast EMA"; rejZone = i; }
         continue;
        }

      int barsSinceTouch = (int)((Bt(1) - g_zones[i].tTouch) / PeriodSeconds());
      if(barsSinceTouch > MaxBarsSinceTouch)
        {
         if(rejReason == "") { rejReason = "STALE_TOUCH"; rejDetail = IntegerToString(barsSinceTouch) + " bars"; rejZone = i; }
         continue;
        }

      // --- scoring: FVG + confluence first, shallow penetration, fresh touch
      double score = 0.0;
      if(isFvg) score += 3.0;
      score += confl * 2.0;
      score -= g_zones[i].maxPenet * 4.0;
      score -= barsSinceTouch * 0.15;
      score -= MathAbs(dist) / (g_maxEntryPts * _Point);

      if(score > bestScore)
        {
         bestScore = score; bestIdx = i; bestDir = dir; bestConfl = confl;
         g_bestEntry = entry; g_bestSl = sl; g_bestTp = tp;
        }
     }

   if(bestIdx < 0)
     {
      if(rejReason != "") Reject(rejReason, bestDir, rejDetail, rejZone);
      else g_setupMsg = "no live zone";
      return;
     }

   string why = "";
   if(!GuardsAllow(bestDir, why)) { Reject("GUARD", bestDir, why, bestIdx); return; }

   ENUM_ORDER_TYPE otype = (bestDir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double px = (bestDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalcLots(MathAbs(g_bestEntry - g_bestSl) / _Point, otype, px, why);
   if(lots <= 0.0) { Reject("SIZE", bestDir, why, bestIdx); return; }

   bool pending = (EntryModel == ENTRY_LIMIT);
   if(!pending && !TriggerOk(bestDir))
     { Reject("NO_TRIGGER", bestDir, "no rejection candle inside zone", bestIdx); return; }

   SendEntry(bestDir, ZoneName(g_zones[bestIdx].type), bestConfl, pending,
             g_bestEntry, g_bestSl, g_bestTp, lots, bestIdx);
  }

// Next live zone on the other side of price = natural runner target.
double NextOpposingTarget(int dir, double fromPrice)
  {
   double best = 0.0;
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid) continue;
      if(dir > 0 && g_zones[i].bottom > fromPrice)
         if(best == 0.0 || g_zones[i].bottom < best) best = g_zones[i].bottom;
      if(dir < 0 && g_zones[i].top < fromPrice)
         if(best == 0.0 || g_zones[i].top > best) best = g_zones[i].top;
     }
   return(best);
  }

// Candle-rejection confirmation for ENTRY_TRIGGER mode.
bool TriggerOk(int dir)
  {
   double rng = RangeSize(1);
   if(rng <= 0.0 || rng < MinTriggerRangeAtr * g_atr) return(false);
   if(dir > 0)
     {
      if(WickDown(1) / rng * 100.0 < MinRejectionWickPct) return(false);
      if(Cl(1) <= Op(1)) return(false);
      return((Cl(1) - Lo(1)) / rng * 100.0 >= MinTriggerClosePct);
     }
   if(WickUp(1) / rng * 100.0 < MinRejectionWickPct) return(false);
   if(Cl(1) >= Op(1)) return(false);
   return((Hi(1) - Cl(1)) / rng * 100.0 >= MinTriggerClosePct);
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS                                            |
//|   - close the record when the position is gone (history row)      |
//|   - track MAE/MFE and the best price seen                         |
//|   - close Tp1Percent at Tp1RR, then hard-lock the runner          |
//|   - move to breakeven after BreakEvenTriggerRR                    |
//|   - ratchet the stop with the profit-lock ladder                  |
//|   - trail behind the peak with ATR once TrailStartRR is reached   |
//|   - remove the fixed target once the stop is locked at >= Tp1RR   |
//|     so the runner can go past Tp2RR (LetWinnersRun)               |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   // --- detect closed positions first, so the row is written on the tick it closes
   for(int s = 0; s < 8; s++)
     {
      if(!g_rec[s].used) continue;
      if(g_rec[s].ticket == 0) continue;            // a pending is not a trade yet
      if(PositionAlive(g_rec[s].ticket)) continue;

      // A limit that was cancelled instead of filled leaves no deal at all. It
      // was never a trade: writing it would add a 0.00R row that dilutes
      // expectancy and win rate, the two numbers the review is made from.
      double   pEnd = 0.0, pxEnd = 0.0;
      datetime tOpenHist = 0, tEnd = 0;
      if(!ClosedPositionInfo(g_rec[s].ticket, pEnd, tOpenHist, tEnd, pxEnd))
        {
         Reject("CANCELLED_UNFILLED", g_rec[s].dir,
                "ticket " + IntegerToString(g_rec[s].ticket) + " removed before fill", -1);
         g_rec[s].used = false;
         continue;
        }
      // A position that fills and then hits its stop inside the same tick is
      // never seen by the management loop below, so tOpen can still be 0 here.
      // Take it from the history, or hold_bars and session come out of 1970.
      if(g_rec[s].tOpen == 0) g_rec[s].tOpen = tOpenHist;

      string whyExit = ExitReasonGuess(s, pxEnd);
      double riskUsd = g_rec[s].lots * g_rec[s].riskDist * UsdPerPointPerLot();
      double rMult   = riskUsd > 0.0 ? pEnd / riskUsd : 0.0;
      RecClose(g_rec[s].ticket, whyExit, pEnd, tEnd, pxEnd);
      // The container turns this row into the phone buzz (",CLOSE,").
      LogEvent("CLOSE", StringFormat("%s %s closed by %s, P/L %.2f = %+.2fR, equity %.2f",
               DirName(g_rec[s].dir), g_rec[s].sigType, whyExit, pEnd, rMult,
               AccountInfoDouble(ACCOUNT_EQUITY)));
      g_rec[s].used = false;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      int slot = RecSlot((long)tk);
      if(slot < 0) continue;                 // not ours to manage (no record = no R)

      double entry   = g_rec[slot].entry;
      double tp      = g_rec[slot].tp;
      double riskPts = g_rec[slot].riskDist;
      if(riskPts <= 0.0) continue;           // unknown risk = do not manage blind

      double curPrice = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(curPrice <= 0.0) continue;
      double rNow = ((curPrice - entry) / _Point * dir) / riskPts;

      // --- MAE / MFE bookkeeping, and the peak the trail rides
      double fav = ((dir > 0 ? Hi(1) : Lo(1)) - entry) / _Point * dir;
      double adv = ((dir > 0 ? Lo(1) : Hi(1)) - entry) / _Point * dir;
      if(fav > g_rec[slot].mfe) g_rec[slot].mfe = fav;
      if(adv < g_rec[slot].mae) g_rec[slot].mae = adv;
      if(dir > 0 && curPrice > g_rec[slot].peak) g_rec[slot].peak = curPrice;
      if(dir < 0 && curPrice < g_rec[slot].peak) g_rec[slot].peak = curPrice;
      g_rec[slot].tLastBar = Bt(0);

      double rPeak = ((g_rec[slot].peak - entry) / _Point * dir) / riskPts;

      int holdBars = (int)((Bt(0) - g_rec[slot].tOpen) / PeriodSeconds());
      if(holdBars < MinHoldBars) continue;

      double slNow = PositionGetDouble(POSITION_SL);

      // --- TP1 partial, then hard-lock the runner
      if(!g_rec[slot].tp1Done && Tp1Percent > 0.0 && ExitMode != EXIT_TRAIL_ONLY && rNow >= Tp1RR)
        {
         double minl      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double volNow    = PositionGetDouble(POSITION_VOLUME);
         double closeLots = NormalizeLots(volNow * Tp1Percent / 100.0);
         double remain    = volNow - closeLots;
         if(closeLots >= minl && remain >= minl)
           {
            if(trade.PositionClosePartial(tk, closeLots))
              {
               g_rec[slot].tp1Done = 1;
               CsvAppend("partials.csv",
                         "time,ticket,dir,lots_closed,price,r_multiple_at_close,remaining_lots,signal_type",
                         CsvTime(TimeCurrent()) + "," + IntegerToString((long)tk) + "," + DirName(dir) +
                         "," + DoubleToString(closeLots, 2) + "," + DoubleToString(curPrice, _Digits) + "," +
                         DoubleToString(rNow, 2) + "," + DoubleToString(remain, 2) + "," + g_rec[slot].sigType);
               Print(Prefix, " TP1 closed ", DoubleToString(closeLots, 2), " lots at R ",
                     DoubleToString(rNow, 2));
               // The banked leg must never be given back: the runner's stop goes
               // to entry (+offset) immediately, whatever else is configured.
               double be = entry + dir * (g_beOffsetPts + 5.0) * _Point;
               if(PositionSelectByTicket(tk) && IsBetterStop(dir, be, PositionGetDouble(POSITION_SL)))
                 {
                  ModifyStop((long)tk, dir, be, tp);
                  g_rec[slot].tBE = TimeCurrent();
                 }
              }
            else
               Print(Prefix, " TP1 close failed retcode=", IntegerToString((int)trade.ResultRetcode()), " ",
                     trade.ResultRetcodeDescription());
           }
        }

      // --- everything that protects open profit is decided here, once, and
      //     submitted as ONE stop move: the break-even floor, the R lock ladder
      //     and the ATR trail all compete for the same stop, and three separate
      //     modifies would fight each other (and the broker's freeze level) on
      //     every tick.
      // Re-select: the partial close above (and CTrade itself) move the terminal's
      // current selection, so POSITION_SL read here would otherwise come from a
      // different position - or from none at all.
      if(!PositionSelectByTicket(tk)) continue;
      slNow = PositionGetDouble(POSITION_SL);
      double targetSl = slNow;

      // 1. break-even: the trade has seen BreakEvenTriggerRR, so it is free.
      if(BreakEvenTriggerRR > 0.0 && rPeak >= BreakEvenTriggerRR)
        {
         double be = entry + dir * g_beOffsetPts * _Point;
         if(IsBetterStop(dir, be, targetSl)) targetSl = be;
        }

      // 2. profit-lock ladder: a step function of the BEST R the trade has seen.
      //    This is what stops a spike carrying a 3R winner back to break-even -
      //    once 3R has printed, the stop is at +2R and cannot move back.
      if(UseProfitLock)
        {
         double floorR = LockFloorR(rPeak);
         if(floorR > 0.0)
           {
            double lockSl = entry + dir * floorR * riskPts * _Point;
            if(IsBetterStop(dir, lockSl, targetSl)) targetSl = lockSl;
           }
        }

      // 3. ATR trail, armed in profit only. From the PEAK by default: the last
      //    bar's high lags a runner by up to a bar, and on a trending symbol that
      //    is exactly the distance a winner needs.
      if(UseAtrTrail && rPeak >= TrailStartRR && g_atr > 0.0)
        {
         double anchor  = TrailFromPeak ? g_rec[slot].peak : (dir > 0 ? Hi(1) : Lo(1));
         double trailSl = (dir > 0) ? anchor - TrailAtrMult * g_atr
                                    : anchor + TrailAtrMult * g_atr;
         // Only move when the improvement is worth a broker round-trip.
         double step = TrailMinStepAtr * g_atr;
         if(dir > 0 && trailSl > targetSl + step) targetSl = trailSl;
         if(dir < 0 && (targetSl == 0.0 || trailSl < targetSl - step)) targetSl = trailSl;
        }

      // --- LetWinnersRun: once the stop is locked at >= Tp1RR the fixed target
      //     has done its job. Removing it hands the runner to the trail, which is
      //     the only way a 4R target becomes an 8R trade - and the stop left
      //     behind is at +1R or better, so nothing that was won can be lost.
      double newTp = tp;
      if(LetWinnersRun && tp > 0.0 && riskPts > 0.0)
        {
         double lockedR = (targetSl == 0.0) ? 0.0 : ((targetSl - entry) / _Point * dir) / riskPts;
         if(lockedR >= Tp1RR) newTp = 0.0;
        }

      if(IsBetterStop(dir, targetSl, slNow) || newTp != tp)
        {
         if(ModifyStop((long)tk, dir, targetSl, newTp))
           {
            if(g_rec[slot].tBE == 0 && targetSl != 0.0 &&
               IsBetterStop(dir, targetSl, entry + dir * 0.5 * _Point))
               g_rec[slot].tBE = TimeCurrent();
            g_rec[slot].tp = newTp;
            if(newTp == 0.0 && tp > 0.0)
               Print(Prefix, " runner released: stop at ", DoubleToString(targetSl, _Digits),
                     " (", DoubleToString(((targetSl - entry) / _Point * dir) / riskPts, 2),
                     "R), fixed target removed so the trail can carry it");
           }
        }
     }
  }

// The R multiple whose floor the stop has earned. Monotone by construction: a
// higher trigger can only ever name a higher floor.
double LockFloorR(double rPeak)
  {
   double f = 0.0;
   if(LockTrigger1 > 0.0 && rPeak >= LockTrigger1 && LockFloor1 > f) f = LockFloor1;
   if(LockTrigger2 > 0.0 && rPeak >= LockTrigger2 && LockFloor2 > f) f = LockFloor2;
   if(LockTrigger3 > 0.0 && rPeak >= LockTrigger3 && LockFloor3 > f) f = LockFloor3;
   if(LockTrigger4 > 0.0 && rPeak >= LockTrigger4 && LockFloor4 > f) f = LockFloor4;
   return(f);
  }

// "Better" always means further into profit, and never by less than half a tick.
bool IsBetterStop(int dir, double candidate, double current)
  {
   if(candidate <= 0.0) return(false);
   if(current <= 0.0) return(true);
   if(dir > 0) return(candidate > current + 0.5 * _Point);
   return(candidate < current - 0.5 * _Point);
  }

//+------------------------------------------------------------------+
//| Order / bookkeeping helpers used by ManageOpenPositions            |
//+------------------------------------------------------------------+
bool ModifyStop(long ticket, int dir, double newSl, double tp)
  {
   if(!PositionSelectByTicket((ulong)ticket)) return(false);
   double curSl = PositionGetDouble(POSITION_SL);
   double curTp = PositionGetDouble(POSITION_TP);
   double newTp = (tp <= 0.0) ? 0.0 : NormalizeDouble(tp, _Digits);

   bool slSame = (MathAbs(curSl - newSl) < _Point * 0.5);
   bool tpSame = (MathAbs(curTp - newTp) < _Point * 0.5);
   if(slSame && tpSame) return(true);

   // A stop inside the broker's stops level is refused ("invalid stops"), and a
   // refused modify would be retried on every single tick. Drop it here instead.
   if(!slSame && newSl > 0.0)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double minDist = BrokerStopLevelPts() * _Point;
      if(bid <= 0.0 || ask <= 0.0) return(false);
      if(dir > 0 && (bid - newSl) < minDist) return(false);
      if(dir < 0 && (newSl - ask) < minDist) return(false);
      newSl = NormalizeDouble(newSl, _Digits);
     }
   else
     {
      newSl = curSl;
     }

   if(!trade.PositionModify(ticket, newSl, newTp))
     {
      Print(Prefix, " modify failed ticket ", IntegerToString(ticket), " retcode=",
            IntegerToString((int)trade.ResultRetcode()), " ", trade.ResultRetcodeDescription());
      return(false);
     }
   return(true);
  }

// Everything the report needs about a position that has left the terminal.
//
// Two bugs the MT4 original had to fix, kept fixed here:
//   1. A partial close leaves one DEAL per leg under the same position id, so
//      summing them is the only reading that matches "what did this trade make
//      me" - reading the first leg reports the runner's P/L while charging the
//      full original lot as the risk.
//   2. A limit that was cancelled rather than filled has NO deal at all.
//      Returning false lets the caller drop it instead of writing a 0.00R row
//      out of a trade that never happened.
bool ClosedPositionInfo(long positionId, double &profit, datetime &openTime,
                        datetime &closeTime, double &closePrice)
  {
   profit = 0.0;
   openTime = 0;
   closeTime = 0;
   closePrice = 0.0;
   if(!HistorySelectByPosition((ulong)positionId)) return(false);
   bool found = false;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long entryKind = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entryKind != DEAL_ENTRY_IN && entryKind != DEAL_ENTRY_OUT &&
         entryKind != DEAL_ENTRY_INOUT && entryKind != DEAL_ENTRY_OUT_BY) continue;
      profit += HistoryDealGetDouble(d, DEAL_PROFIT)
              + HistoryDealGetDouble(d, DEAL_SWAP)
              + HistoryDealGetDouble(d, DEAL_COMMISSION);
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(openTime == 0 || t < openTime) openTime = t;
      if(entryKind != DEAL_ENTRY_IN && t >= closeTime)
        {
         closeTime  = t;
         closePrice = HistoryDealGetDouble(d, DEAL_PRICE);
        }
      found = true;
     }
   return(found);
  }

// Best-effort exit attribution from the path the trade actually took. MT5 knows
// why a deal closed (DEAL_REASON) but the record is written from the polling
// loop, so it is inferred from the geometry - and the report shows it as
// INFERRED, never as exact.
string ExitReasonGuess(int slot, double exitPrice)
  {
   if(slot < 0 || slot > 7) return("UNKNOWN");
   double tpPts = 0.0;
   if(g_rec[slot].tp > 0.0 && g_rec[slot].riskDist > 0.0)
      tpPts = MathAbs(g_rec[slot].tp - g_rec[slot].entry) / _Point;

   // Closed at (or within a whisker of) the recorded target. The tolerance is two
   // points: a TP fill can print a point or two either side, and the only
   // question here is "did it reach the runner target".
   if(g_rec[slot].tp > 0.0 && exitPrice > 0.0)
     {
      if(MathAbs(g_rec[slot].tp - exitPrice) <= 2.0 * _Point) return("TP2");
     }
   else if(tpPts > 0.0 && g_rec[slot].mfe >= tpPts - 2.0) return("TP2");

   if(g_rec[slot].tp1Done > 0) return("TP1_RUNNER");   // banked TP1, runner then exited
   if(g_rec[slot].tBE > 0)     return("BE_OR_TRAIL");
   return("STOP_LOSS");
  }

void FlattenAll(string why)
  {
   static string lastWhy = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!trade.PositionClose(tk))
         Print(Prefix, " flatten failed position ", IntegerToString((long)tk), " retcode=",
               IntegerToString((int)trade.ResultRetcode()));
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(!trade.OrderDelete(tk))
         Print(Prefix, " flatten failed order ", IntegerToString((long)tk), " retcode=",
               IntegerToString((int)trade.ResultRetcode()));
     }
   if(CountPositions() == 0 && why != lastWhy)
     {
      Print(Prefix, " FLATTEN complete: ", why);
      lastWhy = why;
     }
  }

//+------------------------------------------------------------------+
//| CHART RENDERING - see the zones, do not trust the log blindly      |
//+------------------------------------------------------------------+
void RenderZones()
  {
   ObjectsDeleteAll(0, Prefix + "_Z_");
   int drawn = 0;
   for(int i = ArraySize(g_zones) - 1; i >= 0 && drawn < ZoneMaxDraw; i--)
     {
      if(!g_zones[i].valid) continue;
      string nm = Prefix + "_Z_" + IntegerToString(i);
      color  c  = ClrBuyZone;
      if(g_zones[i].dir < 0)     c = ClrSellZone;
      if(g_zones[i].type == HEX_ZONE_BREAKER) c = ClrBreaker;
      if(g_zones[i].type == HEX_ZONE_MITIG)   c = ClrMitigation;
      if(ObjectCreate(0, nm, OBJ_RECTANGLE, 0, g_zones[i].t1, g_zones[i].top,
                      g_zones[i].t2, g_zones[i].bottom))
        {
         ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
         ObjectSetInteger(0, nm, OBJPROP_BACK, true);
         ObjectSetInteger(0, nm, OBJPROP_FILL, true);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetString(0, nm, OBJPROP_TOOLTIP,
                         ZoneName(g_zones[i].type) + " " + DirName(g_zones[i].dir) +
                         " pen=" + DoubleToString(g_zones[i].maxPenet * 100.0, 0) + "%");
        }
      drawn++;
     }
   ChartRedraw();
  }

string ZoneSummary()
  {
   int fvg = 0, brk = 0, mit = 0;
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid) continue;
      if(g_zones[i].type == HEX_ZONE_FVG)     fvg++;
      if(g_zones[i].type == HEX_ZONE_BREAKER) brk++;
      if(g_zones[i].type == HEX_ZONE_MITIG)   mit++;
     }
   return("fvg=" + IntegerToString(fvg) + " brk=" + IntegerToString(brk) +
          " mit=" + IntegerToString(mit) + " tot=" + IntegerToString(ArraySize(g_zones)));
  }

void RenderDashboard()
  {
   string lock = UseProfitLock
                 ? StringFormat("%.2fR@%.1fR %.2fR@%.1fR %.2fR@%.1fR %.2fR@%.1fR",
                                LockFloor1, LockTrigger1, LockFloor2, LockTrigger2,
                                LockFloor3, LockTrigger3, LockFloor4, LockTrigger4)
                 : "off";
   string state = g_killed ? ("KILLED: " + g_killReason)
                : g_dayKilled ? ("FLAT TODAY: " + g_dayReason)
                : (DryRun ? "DRY RUN" : "LIVE");
   string s = "";
   s += Prefix + " FVG-Breaker v4.01  " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)Period()) + "\n";
   s += "state      : " + state + "\n";
   s += "trend (H1) : " + DirName(g_trend) + "   " + g_trendMsg + "\n";
   s += "setup      : " + g_setupMsg + "   dist=" + DoubleToString(g_setupDist, 0) + "pt\n";
   s += "zones      : " + ZoneSummary() + "\n";
   s += "atr/spread : " + DoubleToString(g_atr, _Digits) + " / " +
        DoubleToString(SpreadPoints(), 1) + "pt (max " + DoubleToString(g_maxSpreadPts, 0) + ")\n";
   s += "equity     : " + DoubleToString(Equity(), 2) + "  peak " + DoubleToString(g_ddPeak, 2) +
        "  dd " + DoubleToString(g_ddPeak > 0 ? (g_ddPeak - Equity()) / g_ddPeak * 100.0 : 0.0, 2) + "%\n";
   s += "today      : " + IntegerToString(g_tradesToday) + "/" + IntegerToString(MaxSignalsPerDay) +
        " signals   open: " + IntegerToString(CountPositions()) + "\n";
   s += "exits      : tp1 " + DoubleToString(Tp1Percent, 0) + "% @" + DoubleToString(Tp1RR, 2) +
        "R, runner " + DoubleToString(Tp2RR, 2) + "R" + (LetWinnersRun ? " (released once locked)" : "") + "\n";
   s += "protect    : lock " + lock + " | trail " + DoubleToString(TrailAtrMult, 2) + "xATR from " +
        DoubleToString(TrailStartRR, 2) + "R" + (TrailFromPeak ? " (peak)" : " (bar)") + "\n";
   s += "ticks      : " + IntegerToString(g_tickCount) + "   tick age " +
        IntegerToString(SecondsSinceTick()) + "s\n";
   Comment(s);
  }
