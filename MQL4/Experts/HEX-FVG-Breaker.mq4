//+------------------------------------------------------------------+
//|                                            HEX-FVG-Breaker.mq4   |
//|   Breaker Blocks + Mitigation Blocks + Fair Value Gaps           |
//|   Trend-following execution on FVGs - built for $100 demo        |
//|                                                                  |
//|   Target : XAUUSD M15 (entries), H1 (trend)                      |
//|   Modes  : DRY RUN (signal only) | LIVE DEMO | BACKTEST          |
//|   Output : trades.csv / equity.csv / rejections.csv / zones.csv  |
//|            + live on-chart dashboard                             |
//+------------------------------------------------------------------+
#property copyright "Forex-hex-algo-strategy-mt4"
#property link      "https://github.com/Manged3/Forex-hex-algo-strategy-mt4"
#property version   "3.00"
#property strict
#property description "Trend trading through Fair Value Gaps, confirmed by Breaker and Mitigation blocks."

//--- Enums ---------------------------------------------------------
enum ENUM_HEX_ZONE
  {
   HEX_ZONE_FVG       = 1,   // Fair Value Gap (3-candle imbalance)
   HEX_ZONE_BREAKER   = 2,   // Breaker block (swung level that broke and flipped polarity)
   HEX_ZONE_MITIG     = 3    // Mitigation block (base/consolidation left behind by displacement)
  };

enum ENUM_TREND_MODE
  {
   TREND_EMA        = 0,     // EMA stack on trend timeframe
   TREND_STRUCTURE  = 1,     // Higher-timeframe market structure (HH/HL vs LH/LL)
   TREND_BOTH       = 2      // Require EMA and structure to agree
  };

enum ENUM_EXIT_MODE
  {
   EXIT_FIXED_RR    = 0,     // TP1 partial + TP2 fixed R multiple
   EXIT_ZONE_RR     = 1,     // TP1 partial + TP2 at next opposing zone
   EXIT_TRAIL_ONLY  = 2      // No TPs, trail with ATR (runner)
  };

 enum ENUM_ENTRY_MODEL
  {
   ENTRY_LIMIT      = 0,     // Limit order deep in the zone (better R, some trades never fill)
   ENTRY_TRIGGER    = 1      // Market after a rejection candle inside the zone (fills, worse R)
  };

// How the push message is put on the wire. MT4 has no WhatsApp API, so this
// talks to whatever HTTP endpoint you are willing to put text into a chat with.
enum ENUM_NOTIFY_FORMAT
  {
   NOTIFY_FORM      = 0,     // POST x-www-form-urlencoded: title=..&message=..
   NOTIFY_PLAIN     = 1,     // POST plain text body (ntfy.sh and similar)
   NOTIFY_JSON      = 2,     // POST {"title":"..","message":".."}
   NOTIFY_GET       = 3      // GET, body url-encoded into {TEXT} inside the URL
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
   int      ticket;
   bool     used;
   int      dir;
   string   sigType;      // zone type label that produced the signal
   int      confluence;
   double   entry;
   double   sl;
   double   tp;
   double   riskDist;
   double   lots;
   double   atr;
   double   spreadPts;
   double   mae;
   double   mfe;
   datetime tOpen;          // position open time; 0 while a limit is still pending
   datetime tPlaced;        // ticket creation time (fills can lag placement)
   datetime tBE;            // 0 until breakeven applied
   int      tp1Done;
   datetime tLastBar;
  };

//--- Globals -------------------------------------------------------
ZoneRec   g_zones[];
TradeRec  g_rec[8];
int       g_zoneMax   = 120;
datetime  g_barTime   = 0;      // Time[0] of last processed bar
int       g_tickCount = 0;
double    g_ddPeak    = 0.0;
double    g_dayStart  = 0.0;
int       g_dayKey    = 0;
int       g_tradesToday = 0;
bool      g_killed    = false;
string    g_killReason= "";
int       g_sigCount  = 0;      // signals taken
int       g_rejCount  = 0;      // signals rejected by guards
datetime  g_lastSigBar[2];      // last signal bar per direction
double    g_setupDist = 0.0;    // distance from price to the zone being evaluated
double    g_bestEntry = 0.0;    // geometry of the winning zone this evaluation
double    g_bestSl    = 0.0;
double    g_bestTp    = 0.0;

// Point equivalents of the $/oz inputs, computed once in OnInit so the EA
// behaves identically on a 2-digit and a 3-digit gold feed.
double    g_maxSpreadPts   = 45.0;
double    g_minStopPts     = 120.0;
double    g_maxStopPts     = 1400.0;
double    g_maxEntryPts    = 700.0;
double    g_maxEmaDistPts  = 900.0;
double    g_minTrendSlope  = 15.0;
double    g_minSwingPts    = 120.0;
double    g_beOffsetPts    = 5.0;
string    g_setupMsg  = "scanning...";
double    g_atr       = 0.0;
int       g_trend     = 0;
string    g_trendMsg  = "";
double    g_swingHigh = 0.0;    // last confirmed structure level (resistance)
double    g_swingLow  = 0.0;    // last confirmed structure level (support)
int       g_lastBreakDir = 0;     // last structure side that produced a breaker block

// Push-notification state (see SendPush)
int       g_pushSent   = 0;       // messages accepted since OnInit
int       g_pushFail   = 0;       // transport failures since OnInit
int       g_pushHour   = -1;      // hour the hourly cap is counting
int       g_pushHourN  = 0;       // messages sent inside g_pushHour
int       g_pushLastAt = 0;       // TimeCurrent() of the last accepted message
string    g_pushLastMsg= "";      // last accepted body, for repeat suppression
string    g_pushLastErr= "off";   // surfaced on the dashboard

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
extern string  S0_Gen              = "=== General ===";
extern int     MagicNumber         = 20261015;
extern string  TradeSymbol         = "";              // "" = chart symbol. XAUUSD recommended
extern double  MaxSpreadDollars    = 0.45;            // max spread in $ per ounce (broker-independent)
extern double  MaxSlippagePoints   = 30.0;
extern int     MaxOpenTrades       = 1;               // 1 position at a time = clean experiment

extern string  S1_Exec             = "=== Execution mode ===";
extern bool    DryRun              = false;           // true = compute+draw+log signals, never send orders
extern int     MaxSignalsPerDay    = 6;               // demo tuning: cap sample noise, protect capital
extern bool    RequireNewBar       = true;            // evaluate on closed bars only (non-repainting)
extern bool    CloseOnWeekend      = true;            // flat before Friday close (demo brokers gap)
extern int     StopTradingHourUTC  = 21;              // no new entries after this hour (server time)
extern int     StartTradingHourUTC = 1;               // no new entries before this hour

extern string  S2_Trend            = "=== Trend filter ===";
extern int     TrendTimeframe      = 60;              // 60 = H1 trend over M15 entries
extern ENUM_TREND_MODE TrendMode   = TREND_BOTH;
extern int     FastEMAPeriod       = 21;
extern int     SlowEMAPeriod       = 50;
extern int     TrendSwingLookback  = 5;               // bars each side for H1 swing points
extern double  MinTrendSlopeDollars= 0.15;            // slow EMA must move this $/oz over N bars
extern int     TrendSlopeBars      = 6;
extern double  MaxDistFromEmaDollars = 9.00;          // chase guard: skip entries this $/oz beyond fast EMA

extern string  S3_Swing            = "=== Structure / swing detection ===";
extern int     SwingLookback       = 3;               // bars each side for an M15 swing high/low
extern double  MinSwingRangeDollars= 1.20;            // ignore micro-swings smaller than this $/oz
extern double  MinDisplacementPct  = 55.0;            // displacement candle: body >= this % of range
extern double  MinDisplacementAtr  = 1.10;            // and body >= this x ATR

extern string  S4_Fvg              = "=== Fair Value Gaps ===";
extern bool    UseFVG              = true;
extern int     FvgMinSizeAtrPct    = 55;              // gap >= this % of ATR (kills noise gaps)
extern int     FvgMaxSizeAtrPct    = 420;             // and <= this % of ATR (skip vacuum gaps)
extern double  MitigatePct         = 50.0;            // zone dies after this % penetration
extern double  EntryZonePct        = 62.0;            // limit sits this % deep into the gap
extern int     MaxZoneAgeBars      = 180;             // drop zones older than this many M15 bars
extern bool    RequireFVGConfluence= true;            // entry must also touch breaker/mitigation
extern int     ConfluenceLookback  = 60;              // bars of history searched for confluence

extern string  S5_Breaker          = "=== Breaker blocks ===";
extern bool    UseBreaker          = true;
extern double  BreakerMinAtr       = 0.70;            // minimum block height in ATR
extern double  BreakerMaxAtr       = 6.0;             // maximum block height in ATR

extern string  S6_Mitig            = "=== Mitigation blocks ===";
extern bool    UseMitigation       = true;
extern int     MitigConsolBars     = 4;               // low-range consolidation bars before the break
extern double  MitigConsolAtrMax   = 0.65;            // that cluster must be tighter than this x ATR
extern double  MitigBreakAtr       = 1.20;            // displacement away must be >= this x ATR

extern string  S7_Trigger          = "=== Entry trigger ===";
extern ENUM_ENTRY_MODEL EntryModel = ENTRY_LIMIT;     // LIMIT = wait at zone, TRIGGER = candle rejection
extern double  MaxEntryDistanceDollars = 7.00;        // don't chase a zone further than this $/oz
extern double  MinRejectionWickPct = 30.0;            // rejection wick as % of trigger candle range
extern double  MinTriggerRangeAtr  = 0.35;            // trigger candle must be meaningful
extern double  MinTriggerClosePct  = 45.0;            // close back toward our side this % of range
extern int     MaxBarsSinceTouch   = 6;               // bars allowed between touch and trigger
extern bool    AllowMarketEntry    = true;            // if limit expires, market-enter on trigger close
extern int     LimitExpiryBars     = 4;               // pending order lifetime (bars)

extern string  S8_Risk             = "=== Risk / money ===";
extern double  RiskPercent         = 0.0;             // 0 = use FixedLot; 1.0 = risk 1% of balance
extern double  FixedLot            = 0.01;
extern double  MaxLot              = 0.02;            // $100 gold reality: keep this tiny
extern double  MaxMarginUsagePct   = 50.0;            // margin for the new position <= this % of equity
extern double  StopBufferAtrPct    = 25.0;            // stop beyond the zone by this % of ATR
extern double  MinStopDollars      = 1.20;            // floor: never risk less than this $/oz of stop
extern double  MaxStopDollars      = 14.00;           // skip setups whose stop is absurdly wide
extern double  MaxRiskAmount       = 0.0;             // 0 = off; e.g. 3.00 = never risk more than $3

extern string  S9_Exits            = "=== Exits ===";
extern ENUM_EXIT_MODE ExitMode     = EXIT_FIXED_RR;
extern double  Tp1RR               = 1.0;             // first target: closes Tp1Percent
extern double  Tp1Percent          = 50.0;
extern double  Tp2RR               = 2.5;             // runner target
extern double  BreakEvenTriggerRR  = 0.80;            // move stop to entry after this R
extern double  BreakEvenOffsetDollars = 0.05;         // lock-in above entry when BE triggers ($/oz)
extern bool    UseAtrTrail         = true;
extern double  TrailAtrMult        = 2.20;
extern double  TrailStartRR        = 1.0;             // trail activates after this R
extern int     MinHoldBars         = 2;               // avoid getting shaken out instantly

extern string  S10_Guard           = "=== Demo safety guards ===";
extern double  MaxDailyLossPct     = 5.0;             // stop trading for the day after this drawdown
extern double  MaxTotalDrawdownPct = 15.0;            // stop trading entirely (kill switch)
extern double  MinFreeMarginUsd    = 40.0;            // margin guard - gold at $100 is margin-bound
extern bool    FlattenOnKill       = true;

extern string  S11_Report          = "=== Reporting / visual ===";
extern bool    WriteCsvLogs        = true;
extern bool    UseCommonFolder     = true;             // true = <data>/MQL4/Files/Common/HEX-Logs, false = <data>/MQL4/Files/HEX-Logs
extern string  LogFolderName       = "HEX-Logs";
extern int     LogEveryNTicks      = 300;             // equity snapshot cadence
extern bool    ShowDashboard       = true;
extern bool    DrawZones           = true;
extern int     ZoneMaxDraw         = 12;              // zones drawn on chart (perf)
extern string  Prefix              = "HEX";
extern color   ClrBuyZone          = clrDodgerBlue;
extern color   ClrSellZone         = clrTomato;
extern color   ClrBreaker          = clrMediumOrchid;
extern color   ClrMitigation       = clrDarkGoldenrod;

extern string  S12_Push            = "=== Push notification (WhatsApp / chat) ===";
// MT4 cannot talk to WhatsApp directly. Point NotifyUrl at a bridge that turns
// an HTTP POST into a chat message: ntfy.sh (free app, no signup), Pushover,
// Telegram via a small bot wrapper, or your own server. Leave NotifyUrl empty
// to switch the whole thing off.
extern bool    NotifyEnabled       = true;
extern string  NotifyUrl           = "";              // e.g. https://ntfy.sh/hex-xauusd
extern ENUM_NOTIFY_FORMAT NotifyFormat = NOTIFY_FORM; // how the body is shaped
extern string  NotifyTitle         = "HEX XAUUSD";    // chat notification title
extern string  NotifyToken         = "";              // optional bearer token (Pushover/others)
extern int     NotifyTimeoutMs     = 3000;            // never block the tick loop for long
extern bool    NotifyOnSignal      = true;            // entry signalled / sent
extern bool    NotifyOnClose       = true;            // position closed, with the R multiple
extern bool    NotifyOnTp1         = false;           // TP1 partial fills (noisy with Tp1Percent>0)
extern bool    NotifyOnKill        = true;            // kill switch tripped
extern int     NotifyMinMinutes    = 2;               // dedupe window for identical text
extern int     NotifyMaxPerHour    = 30;              // flood guard
extern bool    NotifyTestOnInit    = true;            // send a hello so you know it works

// ------------------------------------------------------------------
// DISABLED LEGACY - filters/features that do NOT serve a breaker +
// mitigation + FVG trend strategy. Kept commented so the reasoning is
// auditable, not deleted. Re-enable only if a logged report proves it.
// ------------------------------------------------------------------
// extern int     RsiPeriod           = 14;      // OFF: mean-reversion oscillator fights trend entries.
//                                              //       A gap in an uptrend is not "overbought", it is intent.
// extern double  RsiBuyMax           = 70.0;    // OFF: same reason as RsiPeriod.
// extern double  RsiSellMin          = 30.0;    // OFF: blocks the strongest trends (exactly what we want).
// extern int     StochasticPeriod    = 14;      // OFF: redundant with the rejection-candle trigger, and laggier.
// extern int     MacdPeriod          = 12;      // OFF: MACD confirms AFTER the move; FVG already prices intent.
// extern int     BollingerPeriod     = 20;      // OFF: band-walking during trends causes false "no-trade".
// extern double  AdxMin              = 20.0;    // OFF (candidate): if reports show chop losses, re-enable
//                                              //       AdxMin=18 on the trend TF as a regime gate.
// extern bool    UseNewsFilter       = false;   // OFF: MT4 has no free calendar; a hard time gate
//                                              //       (StartTradingHourUTC/StopTradingHourUTC) is honest instead.
// extern int     NewsMinutesBefore   = 30;      // OFF: depends on UseNewsFilter.
// extern bool    UseMartingale       = false;   // OFF: doubles down on losers. Death on a $100 account.
// extern double  MartingaleFactor    = 2.0;     // OFF: see UseMartingale.
// extern bool    UseGridAveraging    = false;   // OFF: averaging into a broken zone converts 1R loss into 5R.
// extern int     MaxGridOrders       = 4;       // OFF: see UseGridAveraging.
// extern double  GridStepAtr         = 1.0;     // OFF: see UseGridAveraging.
// extern bool    RecoveryMode        = false;   // OFF: "win it back" logic = martingale in disguise.
// extern bool    CounterTrendFVG     = false;   // OFF: trades against TrendTimeframe. Report it first (LogSignals
//                                              //       still records counter-trend setups when LogRejectedAll=true).
// extern bool    TradeAsianSession   = false;   // OFF: gold ranges in Asia; zones there get wicked through.
// extern bool    CloseOnTrendFlip    = false;   // OFF: exits on a 1-candle H1 wiggle; use the ATR trail instead.
// extern bool    UseBreakEvenPct     = false;   // OFF: % based BE confuses price % with risk distance; use RR.
// extern int     TrailingStopPoints  = 300;     // OFF: fixed-point trail ignores regime; ATR trail replaces it.
// extern int     MaxSpreadPointsFri  = 25.0;    // OFF: use the single MaxSpreadPoints gate; widening it on
//                                              //       Friday only invites worse fills when we least want them.
// extern double  ProfitLockPercent   = 0.0;     // OFF: bank-at-amount is discretionary; R-multiples are measurable.

// @@INPUTS@@

//+------------------------------------------------------------------+
//| Broker / identity helpers                                          |
//+------------------------------------------------------------------+
// USD value of 1 lot x 1 point. Gold (contract 100, 2 digits): $1 / lot / pt.
double UsdPerPointPerLot()
  {
   double v  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(ts <= 0.0) ts = Point;
   if(v <= 0.0 || ts <= 0.0) return(0.0);
   return(v * Point / ts);
  }

// Size of one lot in the symbol's base units. MQL4 exposes this as MODE_LOTSIZE;
// MODE_CONTRACTSIZE is the MQL5 name and does not compile here (verified against
// MetaEditor build 1491).
double ContractSize()
  {
   return(MarketInfo(Symbol(), MODE_LOTSIZE));
  }

double SpreadPoints()
  {
   return((Ask - Bid) / Point);
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
//| Log paths                                                          |
//+------------------------------------------------------------------+
string LogDir()
  {
   string d = "";
   if(UseCommonFolder) d = "Common\\" + LogFolderName;
   else                d = LogFolderName;
   StringReplace(d, "/", "\\");
   return(d);
  }

void EnsureFolders()
  {
   // MQL4 has no FolderExist(). FolderCreate() fails harmlessly when the
   // folder is already there, so call it and ignore the result.
   if(!IsTesting())
     {
      FolderCreate(LogFolderName);
      if(UseCommonFolder) FolderCreate("Common\\" + LogFolderName);
     }
  }

void CsvAppend(string file, string header, string line)
  {
   if(!WriteCsvLogs) return;
   string path = LogDir() + "\\" + file;
   int h = FileOpen(path, FILE_READ | FILE_TXT | FILE_SHARE_READ | FILE_SHARE_WRITE);
   bool fresh = (h < 0);
   if(h >= 0) FileClose(h);
   h = FileOpen(path, FILE_WRITE | FILE_READ | FILE_TXT | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h < 0) { Print("LOG ERROR append ", path, " err=", GetLastError()); return; }
   FileSeek(h, 0, SEEK_END);
   if(fresh) FileWriteString(h, header + "\r\n");
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

string CsvTime(datetime t)
  {
   return(TimeToStr(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS));
  }

//+------------------------------------------------------------------+
//| Init                                                               |
//+------------------------------------------------------------------+
int OnInit()
  {
   EnsureFolders();

   if(StringLen(TradeSymbol) > 0 && TradeSymbol != Symbol())
     {
      Alert(Prefix, ": attach this EA to a ", TradeSymbol, " chart (current chart is ", Symbol(), ").");
      return(INIT_SUCCEEDED);
     }

   if(StringFind(Symbol(), "XAU") < 0 && StringFind(Symbol(), "GOLD") < 0)
      Print(Prefix, ": NOTE - designed and sized for XAUUSD. Current symbol ", Symbol(),
            " needs MaxSpreadDollars / MaxLot re-checked.");

   if(FastEMAPeriod >= SlowEMAPeriod)
     {
      Alert(Prefix, ": FastEMAPeriod must be < SlowEMAPeriod");
      return(INIT_FAILED);
     }
   if(EntryZonePct < 20.0 || EntryZonePct > 95.0)
     {
      Alert(Prefix, ": EntryZonePct must sit between 20 and 95");
      return(INIT_FAILED);
     }
   if(!UseFVG && !UseBreaker && !UseMitigation)
     {
      Alert(Prefix, ": all three detectors are off - nothing to trade.");
      return(INIT_FAILED);
     }

   ArrayResize(g_zones, 0);
   ComputePointEquivalents();
   for(int i = 0; i < 8; i++) g_rec[i].used = false;
   g_ddPeak    = Equity();
   g_dayStart  = Equity();
   g_dayKey    = DayKey(TimeCurrent());
   g_lastSigBar[0] = 0;
   g_lastSigBar[1] = 0;
   g_barTime   = 0;

   if(DryRun) Print(Prefix, ": DRY RUN - signals are logged and drawn, no orders are sent.");
   Print(Prefix, " v3.0 on ", Symbol(), " ", Period(), "m | digits=", Digits,
         " | $", DoubleToString(UsdPerPointPerLot(), 4), " per point per lot | contract=",
         DoubleToString(ContractSize(), 0));
   Print(Prefix, ": logs -> ", LogDir());

   g_pushSent = 0;
   g_pushFail = 0;
   g_pushHour = -1;
   g_pushHourN = 0;
   g_pushLastAt = 0;
   g_pushLastMsg = "";
   if(NotifyEnabled && StringLen(NotifyUrl) == 0)
     {
      g_pushLastErr = "no NotifyUrl set";
      Print(Prefix, ": push is ON but NotifyUrl is empty - no messages will be sent.");
     }
   else if(NotifyEnabled)
     {
      // Sent at startup so a silent phone is noticed on day one rather than on
      // the first losing trade. If this one fails, the URL is wrong or the
      // address is not on Tools > Options > Expert Advisors > WebRequest list.
      if(NotifyTestOnInit)
         SendPush("INIT", "HEX FVG-Breaker v3.0 started\n" + Symbol() + " " +
                  IntegerToString(Period()) + "m | " +
                  (DryRun ? "DRY RUN" : "live trading") +
                  "\nAccount " + IntegerToString((int)AccountNumber()) +
                  " | balance " + DoubleToString(AccountBalance(), 2) +
                  // On a server nobody can see the chart, so the one line that
                  // says whether the robot may actually trade travels with the
                  // hello. "not connected" is the usual cause of a startup
                  // BLOCKED on a freshly launched terminal, not AutoTrading.
                  "\nAutoTrading " + (IsTradeAllowed() ? "ON" : "BLOCKED") +
                  (IsConnected() ? "" : " (terminal not connected yet)") +
                  "\nIf you read this, notifications work.");
      Print(Prefix, ": push -> ", NotifyUrl,
            " (must be listed in Tools > Options > Expert Advisors)");
     }
   return(INIT_SUCCEEDED);
  }

// $/oz inputs -> points. Gold quotes differ between brokers (2 or 3 digits)
// and some brokers price gold in cents; deriving from Point keeps the intent
// ("stop 1.20 dollars behind the zone") true everywhere.
void ComputePointEquivalents()
  {
   double p = Point;
   if(p <= 0.0) p = 0.01;
   g_maxSpreadPts   = MaxSpreadDollars / p;
   g_minStopPts     = MinStopDollars / p;
   g_maxStopPts     = MaxStopDollars / p;
   g_maxEntryPts    = MaxEntryDistanceDollars / p;
   g_maxEmaDistPts  = MaxDistFromEmaDollars / p;
   g_minTrendSlope  = MinTrendSlopeDollars / p;
   g_minSwingPts    = MinSwingRangeDollars / p;
   g_beOffsetPts    = BreakEvenOffsetDollars / p;
   Print(Prefix, ": scale ok | point=", DoubleToString(p, Digits),
         " -> maxSpread=", DoubleToString(g_maxSpreadPts, 0), "pt",
         " stopRange=", DoubleToString(g_minStopPts, 0), "-", DoubleToString(g_maxStopPts, 0), "pt");
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, Prefix);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main tick                                                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_tickCount++;
   bool newBar = (Time[0] != g_barTime);

   // --- 1. housekeeping: day roll, kill switches, equity snapshot ---
   Housekeeping(newBar);
   // Flattening on a kill switch must not stop the zone engine: the demo keeps
   // logging zones/signals while flat, so you can still study what it missed.
   if(g_killed && FlattenOnKill && IsTradeAllowed()) FlattenAll("kill switch");

   // --- 2. register closed bars (zones are only built from closed candles) ---
   if(newBar)
     {
      g_barTime = Time[0];
      ScanClosedBar();
      UpdateZones();
      PruneZones();
      if(DrawZones) RenderZones();
      ExpirePendings();
     }

   // --- 3. manage anything open (BE, trail, TP1, expiry) ---
   ManageOpenPositions();

   // --- 4. evaluate a setup. On bar close for non-repainting behaviour,
   //         or every tick if RequireNewBar = false.
   bool evaluate = newBar || (!RequireNewBar && g_tickCount % 4 == 0);
   if(evaluate && !g_killed) EvaluateSetup();

   // --- 5. reporting / dashboard ---
   if(ShowDashboard) RenderDashboard();
   if(WriteCsvLogs && g_tickCount % MathMax(50, LogEveryNTicks) == 0) SnapshotEquity();
  }

//+------------------------------------------------------------------+
//| Equity / day guards                                                |
//+------------------------------------------------------------------+
double Equity()
  {
   return(AccountEquity());
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
      CsvAppend("daily.csv",
        "date,day_start_equity,peak_equity,signals,kill_reason",
        TimeToStr(TimeCurrent(), TIME_DATE) + "," + DoubleToString(eq, 2) + "," +
        DoubleToString(g_ddPeak, 2) + ",0,");
      if(g_killed && MaxTotalDrawdownPct <= 0.0) g_killed = false;
     }

   if(!g_killed && MaxTotalDrawdownPct > 0.0 && g_ddPeak > 0.0)
     {
      double dd = (g_ddPeak - eq) / g_ddPeak * 100.0;
      if(dd >= MaxTotalDrawdownPct)
        {
         g_killed = true;
         g_killReason = "total drawdown " + DoubleToString(dd, 1) + "% >= " +
                        DoubleToString(MaxTotalDrawdownPct, 1) + "%";
         Print(Prefix, " KILL: ", g_killReason);
         Reject("KILL", 0, g_killReason);
         if(NotifyOnKill)
            SendPush("KILL", "KILL SWITCH TRIPPED\nTotal drawdown " +
                     DoubleToString(dd, 1) + "% >= " +
                     DoubleToString(MaxTotalDrawdownPct, 1) + "%\n" +
                     "Equity " + DoubleToString(eq, 2) + " / peak " +
                     DoubleToString(g_ddPeak, 2) + "\n" +
                     (FlattenOnKill ? "All positions closed, EA halted."
                                    : "No new trades; open trades left running."));
        }
     }

   if(!g_killed && MaxDailyLossPct > 0.0 && g_dayStart > 0.0)
     {
      double dl = (g_dayStart - eq) / g_dayStart * 100.0;
      if(dl >= MaxDailyLossPct)
        {
         g_killed = true;
         g_killReason = "daily loss " + DoubleToString(dl, 1) + "%";
         Print(Prefix, " daily loss limit hit, flat for today");
         Reject("DAILY_LOSS", 0, g_killReason);
         if(NotifyOnKill)
            SendPush("KILL", "DAILY LOSS LIMIT HIT\n" + DoubleToString(dl, 1) + "% of " +
                     DoubleToString(g_dayStart, 2) + " >= " +
                     DoubleToString(MaxDailyLossPct, 1) + "%\nFlat until the next day.");
        }
     }
  }

void SnapshotEquity()
  {
   CsvAppend("equity.csv",
     "time,server_time,balance,equity,open_positions,floating_pnl,free_margin,dd_from_peak_pct",
     CsvTime(TimeCurrent()) + "," + IntegerToString((int)TimeLocal()) + "," +
     DoubleToString(AccountBalance(), 2) + "," + DoubleToString(Equity(), 2) + "," +
     IntegerToString(CountPositions()) + "," + DoubleToString(Equity() - AccountBalance(), 2) + "," +
     DoubleToString(AccountFreeMargin(), 2) + "," +
     DoubleToString(g_ddPeak > 0 ? (g_ddPeak - Equity()) / g_ddPeak * 100.0 : 0.0, 2));
  }

//+------------------------------------------------------------------+
//| Candle / indicator helpers                                         |
//+------------------------------------------------------------------+
double AtrVal(int tf, int shift)
  {
   // MQL4's iATR takes (symbol, period, ma_period, shift). The applied-price
   // argument that MQL5 has in slot 4 does not exist here; ATR is close-based.
   return(iATR(Symbol(), tf, 14, shift));
  }

double BodySize(int shift)   { return(MathAbs(Close[shift] - Open[shift])); }
double RangeSize(int shift)  { return(High[shift] - Low[shift]); }
double WickDown(int shift)   { return(MathMin(Open[shift], Close[shift]) - Low[shift]); }
double WickUp(int shift)     { return(High[shift] - MathMax(Open[shift], Close[shift])); }
bool   IsBull(int shift)     { return(Close[shift] > Open[shift]); }
bool   IsBear(int shift)     { return(Close[shift] < Open[shift]); }

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
// Swings below MinSwingRangeDollars are noise on gold and get skipped -
// a breaker built from a micro-swing is a breaker that gets run over.
bool IsSwingHigh(int shift)
  {
   if(shift < SwingLookback + 1) return(false);
   double h = High[shift];
   if(High[shift] - Low[shift] < g_minSwingPts * Point) return(false);
   for(int i = 1; i <= SwingLookback; i++)
     {
      if(shift - i < 0 || shift + i > Bars - 1) return(false);
      if(High[shift - i] > h)  return(false);
      if(High[shift + i] >= h) return(false);
     }
   return(true);
  }

bool IsSwingLow(int shift)
  {
   if(shift < SwingLookback + 1) return(false);
   double l = Low[shift];
   if(High[shift] - Low[shift] < g_minSwingPts * Point) return(false);
   for(int i = 1; i <= SwingLookback; i++)
     {
      if(shift - i < 0 || shift + i > Bars - 1) return(false);
      if(Low[shift - i] < l)  return(false);
      if(Low[shift + i] <= l) return(false);
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
     DoubleToString(g_zones[i].top, Digits) + "," + DoubleToString(g_zones[i].bottom, Digits) +
     "," + DoubleToString(g_zones[i].top - g_zones[i].bottom, Digits) + "," +
     DoubleToString(g_zones[i].maxPenet * 100.0, 1) + "," +
     IntegerToString(g_zones[i].touches) + "," + note);
  }

int ZoneAdd(int type, int dir, datetime t1, datetime t2, double top, double bottom, double atr)
  {
   if(atr <= 0.0 || top <= bottom) return(-1);

   // Breaker blocks are anchored to the displacing body. If that body is
   // thinner than the floor, grow it outward in the correct direction: a
   // bullish block hangs below its top, a bearish block rests on its bottom.
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
   double h = top - bottom;

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
   if(!UseFVG || Bars < 6) return;

   if(Low[1] > High[3] && IsBull(2))                       // bullish imbalance
     {
      double top = Low[1], bottom = High[3], sz = top - bottom;
      if(Close[1] <= Close[3]) return;
      if(sz < FvgMinSizeAtrPct / 100.0 * atr) return;
      if(FvgMaxSizeAtrPct > 0 && sz > FvgMaxSizeAtrPct / 100.0 * atr) return;
      ZoneAdd(HEX_ZONE_FVG, +1, Time[3], Time[1], top, bottom, atr);
     }
   else if(High[1] < Low[3] && IsBear(2))                  // bearish imbalance
     {
      double top = Low[3], bottom = High[1], sz = top - bottom;
      if(Close[1] >= Close[3]) return;
      if(sz < FvgMinSizeAtrPct / 100.0 * atr) return;
      if(FvgMaxSizeAtrPct > 0 && sz > FvgMaxSizeAtrPct / 100.0 * atr) return;
      ZoneAdd(HEX_ZONE_FVG, -1, Time[3], Time[1], top, bottom, atr);
     }
  }

//+------------------------------------------------------------------+
//| 2. BREAKER BLOCK - a swing high/low that was broken with          |
//|    displacement. Old resistance becomes support (and vice versa). |
//|    The block body = the displacement candle that broke the level. |
//+------------------------------------------------------------------+
void DetectBreaker(double atr)
  {
   if(!UseBreaker || Bars < 8) return;

   // g_lastBreakDir remembers which side has already fired against the current
   // structure level. Without it, every bar that closes beyond the broken level
   // spawns another block and the zone list fills with duplicates of one move.
   // UpdateStructure() resets it when a fresh swing level is confirmed.

   // Did the just-closed candle break a prior swing high with intent?
   if(g_lastBreakDir != +1 && Close[1] > g_swingHigh && g_swingHigh > 0.0 && IsBull(1))
     {
      if(IsDisplacement(1, +1, atr))
        {
         double top   = MathMax(Open[1], Close[1]);
         double bottom = MathMin(Open[1], Close[1]);
         if(top - g_swingHigh > 0.10 * atr)
           {
            if(ZoneAdd(HEX_ZONE_BREAKER, +1, Time[1], Time[1], top, bottom, atr) >= 0)
               g_lastBreakDir = +1;
           }
        }
     }
   // Did the just-closed candle break a prior swing low with intent?
   if(g_lastBreakDir != -1 && Close[1] < g_swingLow && g_swingLow > 0.0 && IsBear(1))
     {
      if(IsDisplacement(1, -1, atr))
        {
         double top    = MathMax(Open[1], Close[1]);
         double bottom = MathMin(Open[1], Close[1]);
         if(g_swingLow - bottom > 0.10 * atr)
           {
            if(ZoneAdd(HEX_ZONE_BREAKER, -1, Time[1], Time[1], top, bottom, atr) >= 0)
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
   if(!UseMitigation || Bars < MitigConsolBars + 6) return;

   // cluster = bars 2 .. MitigConsolBars+1 (older candles), displacement = bar 1
   double hi = -1e10, lo = 1e10;
   for(int k = 2; k <= MitigConsolBars + 1; k++)
     {
      if(High[k] > hi) hi = High[k];
      if(Low[k]  < lo) lo = Low[k];
     }
   double cluster = hi - lo;
   if(cluster <= 0.0 || cluster > MitigConsolAtrMax * atr) return;

   if(IsDisplacement(1, +1, atr) && Close[1] > hi)
      ZoneAdd(HEX_ZONE_MITIG, +1, Time[MitigConsolBars + 1], Time[2], hi, lo, atr);
   else if(IsDisplacement(1, -1, atr) && Close[1] < lo)
      ZoneAdd(HEX_ZONE_MITIG, -1, Time[MitigConsolBars + 1], Time[2], hi, lo, atr);
  }

//+------------------------------------------------------------------+
//| Structure memory: track the most recent confirmed swing levels    |
//+------------------------------------------------------------------+
void UpdateStructure()
  {
   if(IsSwingLow(1 + SwingLookback))
     {
      g_swingLow = Low[1 + SwingLookback];
      g_lastBreakDir = 0;
     }
   if(IsSwingHigh(1 + SwingLookback))
     {
      g_swingHigh = High[1 + SwingLookback];
      g_lastBreakDir = 0;
     }
  }

// Called once per closed bar: build the zone set.
void ScanClosedBar()
  {
   double atr = AtrVal(0, 1);
   if(atr <= 0.0) return;
   g_atr = atr;
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

      double h   = g_zones[i].top - g_zones[i].bottom;
      if(h <= 0.0) { ZoneKill(i, "degenerate"); continue; }

      // extend the right edge while the zone is alive
      if(Time[0] > g_zones[i].t2) g_zones[i].t2 = Time[0];

      bool inside = false;
      if(g_zones[i].dir > 0)
        {
         // support zone: penetration measured downward from the top
         if(Low[1] < g_zones[i].top)
           {
            inside = true;
            double pen = (g_zones[i].top - Low[1]) / h;
            if(pen > g_zones[i].maxPenet) g_zones[i].maxPenet = pen;
            // closed decisively through the far edge = structure broken, zone dead
            if(Close[1] < g_zones[i].bottom - 0.15 * atr)
              { ZoneKill(i, "closed through"); continue; }
           }
        }
      else
        {
         if(High[1] > g_zones[i].bottom)
           {
            inside = true;
            double pen = (High[1] - g_zones[i].bottom) / h;
            if(pen > g_zones[i].maxPenet) g_zones[i].maxPenet = pen;
            if(Close[1] > g_zones[i].top + 0.15 * atr)
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
            g_zones[i].tTouch  = Time[1];
            ZoneLog(i, "TOUCH", "first touch");
           }
         // The first visit is the trade we are looking for, so it is never
         // killed on depth alone. A second visit that digs past MitigatePct
         // means the orders sitting there have been consumed - done with it.
         if(g_zones[i].touches > 1 && g_zones[i].maxPenet * 100.0 >= MitigatePct)
           {
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
   int maxAgeSec = MaxZoneAgeBars * Period() * 60;
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

// Count live zones of a given type/direction that overlap the price area
// of a zone index (used for the confluence requirement).
int CountConfluence(int excludeIdx, int dir, double ztop, double zbot)
  {
   int cnt = 0;
   int maxBars = ConfluenceLookback * Period() * 60;
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
// Swing scan on the trend timeframe: fills the last two confirmed swing
// highs and lows. Returns true when at least two of each were found.
bool ScanTrendSwings(double &h1, double &h2, double &l1, double &l2)
  {
   int fh = 0, fl = 0;
   int need = TrendSwingLookback;
   int maxS = MathMin(240, iBars(Symbol(), TrendTimeframe) - 2 * need - 2);
   for(int s = 1 + need; s <= maxS; s++)
     {
      bool isH = true, isL = true;
      double hh = iHigh(Symbol(), TrendTimeframe, s);
      double ll = iLow(Symbol(), TrendTimeframe, s);
      for(int k = 1; k <= need; k++)
        {
         if(iHigh(Symbol(), TrendTimeframe, s - k) > hh) isH = false;
         if(iHigh(Symbol(), TrendTimeframe, s + k) >= hh) isH = false;
         if(iLow(Symbol(), TrendTimeframe, s - k) < ll)  isL = false;
         if(iLow(Symbol(), TrendTimeframe, s + k) <= ll) isL = false;
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
   double fastNow = iMA(Symbol(), TrendTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slowNow = iMA(Symbol(), TrendTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double fastOld = iMA(Symbol(), TrendTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1 + TrendSlopeBars);
   double slowOld = iMA(Symbol(), TrendTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1 + TrendSlopeBars);

   // EMA direction requires the fast line above the slow AND both rising/falling:
   // a flat stack is a range, and ranges are where gap strategies bleed.
   int emaDir = 0;
   double slopeUp   = (slowNow - slowOld) / Point;
   double slopeDown = (slowOld - slowNow) / Point;
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
//| Rejection log - the "why no trade" file is what makes this         |
//| testable. Without it you cannot tell a bad filter from no filter.  |
//+------------------------------------------------------------------+
void Reject(string reason, int dir, string detail, int zi = -1)
  {
   g_rejCount++;
   string zt = "", ztop = "", zbot = "";
   if(zi >= 0 && zi < ArraySize(g_zones))
     {
      zt   = ZoneName(g_zones[zi].type);
      ztop = DoubleToString(g_zones[zi].top, Digits);
      zbot = DoubleToString(g_zones[zi].bottom, Digits);
     }
   CsvAppend("rejections.csv",
     "time,bar_time,reason,dir,zone_type,zone_top,zone_bottom,spread_pts,atr,dist_pts,equity,trend,detail",
     CsvTime(TimeCurrent()) + "," + TimeToStr(Time[0], TIME_DATE | TIME_MINUTES) + "," + reason + "," +
     DirName(dir) + "," + zt + "," + ztop + "," + zbot + "," +
     DoubleToString(SpreadPoints(), 1) + "," + DoubleToString(g_atr, Digits) + "," +
     DoubleToString(g_setupDist, 0) + "," + DoubleToString(Equity(), 2) + "," +
     DirName(g_trend) + "," + detail);
   g_setupMsg = reason;
  }

//+------------------------------------------------------------------+
//| Trade bookkeeping (one record per live position, keyed by ticket)  |
//+------------------------------------------------------------------+
int RecSlot(int ticket)
  {
   for(int i = 0; i < 8; i++) if(g_rec[i].used && g_rec[i].ticket == ticket) return(i);
   return(-1);
  }

int RecFree()
  {
   for(int i = 0; i < 8; i++) if(!g_rec[i].used) return(i);
   return(-1);
  }

// One CSV line per closed position. R-multiple = realised $ / planned $ risk,
// which is the only number comparable across lot sizes and stop distances.
//
// closeTime / closePrice are what the broker actually did; they fall back to
// "now" and Bid only when the history row could not be read. Passing the real
// fill price matters because on the tick a trade closes, Bid has already moved
// past it, so logging Bid records where the market was a moment later rather
// than where the trade ended.
void RecWrite(int i, string exitReason, double profit,
              datetime closeTime = 0, double closePrice = 0.0)
  {
   datetime tEnd = (closeTime > 0) ? closeTime : TimeCurrent();
   double   pEnd = (closePrice > 0.0) ? closePrice : NormalizeDouble(Bid, Digits);
   double riskUsd = g_rec[i].lots * g_rec[i].riskDist * UsdPerPointPerLot();
   double rMult   = (riskUsd > 0.0) ? profit / riskUsd : 0.0;
   int holdBars   = (int)((tEnd - g_rec[i].tOpen) / (Period() * 60));
   CsvAppend("trades.csv",
     "ticket,login,symbol,tf,type,signal_type,confluence,open_time,close_time,entry,sl,tp,exit_price,lots,stop_pts,spread_pts_at_entry,pnl_net,r_multiple,risk_usd,mae_pts,mfe_pts,mfe_r,hold_bars,session,exit_reason,balance_after,atr_at_entry",
     IntegerToString(g_rec[i].ticket) + "," + IntegerToString(AccountNumber()) + "," + Symbol() + "," +
     IntegerToString(Period()) + "," + DirName(g_rec[i].dir) + "," +
     g_rec[i].sigType + "," + IntegerToString(g_rec[i].confluence) + "," +
     CsvTime(g_rec[i].tOpen) + "," + CsvTime(tEnd) + "," +
     DoubleToString(g_rec[i].entry, Digits) + "," + DoubleToString(g_rec[i].sl, Digits) + "," +
     DoubleToString(g_rec[i].tp, Digits) + "," + DoubleToString(pEnd, Digits) + "," +
     DoubleToString(g_rec[i].lots, 2) + "," + DoubleToString(g_rec[i].riskDist, 0) + "," +
     DoubleToString(g_rec[i].spreadPts, 1) + "," +
     DoubleToString(profit, 2) + "," +
     DoubleToString(rMult, 2) + "," +
     DoubleToString(riskUsd, 2) + "," +
     DoubleToString(g_rec[i].mae, 0) + "," + DoubleToString(g_rec[i].mfe, 0) + "," +
     DoubleToString(g_rec[i].riskDist > 0 ? g_rec[i].mfe / g_rec[i].riskDist : 0.0, 2) + "," +
     IntegerToString(holdBars) + "," +
     SessionName(g_rec[i].tOpen) + "," + exitReason + "," +
     DoubleToString(AccountBalance(), 2) + "," + DoubleToString(g_rec[i].atr, Digits));

   if(NotifyOnClose)
      SendPush("CLOSE", PushCloseBody(i, exitReason, profit, rMult, tEnd, pEnd));
  }

void RecClose(int ticket, string exitReason, double profit,
              datetime closeTime = 0, double closePrice = 0.0)
  {
   int i = RecSlot(ticket);
   if(i < 0) return;
   RecWrite(i, exitReason, profit, closeTime, closePrice);
   g_rec[i].used = false;
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

//+------------------------------------------------------------------+
//| PUSH NOTIFICATION                                                  |
//|   MT4 has no WhatsApp API, so this posts to any HTTP endpoint that   |
//|   forwards text into a chat. In practice: ntfy.sh (free app, no       |
//|   account, pick a private topic), Pushover, or your own bridge.       |
//|                                                                      |
//|   Three rules this code exists to obey:                               |
//|     1. WebRequest BLOCKS the caller. On a live M15 chart a slow        |
//|        endpoint stalls the whole EA, so: hard timeout, no retries,      |
//|        per-hour cap.                                                    |
//|     2. A notification failure must never change trading behaviour.      |
//|        Every failure path records a string and returns.                 |
//|     3. Anything accepted or dropped is appended to notify.csv, so       |
//|        "EA had nothing to say" is distinguishable from "message lost".  |
//|                                                                       |
//|   WebRequest is unavailable in the strategy tester, so there messages   |
//|   are logged to notify.csv only.                                      |
//+------------------------------------------------------------------+

// Percent-encoding built on StringFind/StringSubstr only (no per-character
// casts), looking ASCII up by index in a reference table.
string PushUrlEncode(string s)
  {
   const string TAB = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
   const string HEXC = "0123456789ABCDEF";
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      string ch = StringSubstr(s, i, 1);
      if((StringFind("abcdefghijklmnopqrstuvwxyz", ch) >= 0) ||
         (StringFind("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ch) >= 0) ||
         (StringFind("0123456789", ch) >= 0) ||
         (StringFind("-._~", ch) >= 0) || (ch == "/"))
        { out += ch; continue; }
      if(ch == "\n") { out += "%0A"; continue; }
      if(ch == "\r") { out += "%0D"; continue; }
      if(ch == "\t") { out += "%09"; continue; }
      int idx = StringFind(TAB, ch);
      if(idx >= 0)
        {
         int code = 32 + idx;
         out = out + "%" + StringSubstr(HEXC, (code >> 4) & 15, 1) +
               StringSubstr(HEXC, code & 15, 1);
         continue;
        }
      out += ch;                        // non-ASCII passes through; endpoints cope
     }
   return(out);
  }

// Newlines and commas would split a CSV row: the body is multi-line by design.
string PushCsvSafe(string s)
  {
   StringReplace(s, "\r\n", " | ");
   StringReplace(s, "\n", " | ");
   StringReplace(s, "\r", " | ");
   StringReplace(s, ",", ";");
   return(s);
  }

string PushJsonEsc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\t", " ");
   return(s);
  }

// The one line in this EA that cannot be tested without MetaEditor, because
// WebRequest is not available in the strategy tester. If the compiler rejects
// it, the fix is confined to this function: match the argument list MetaEditor
// prints in the error, or copy the call from
//   https://doc.mql4.com/reference/functions/webrequest.html
// and keep the return value. Nothing above this function depends on its shape.
//
// Returns the HTTP status code, or -1 if the call itself failed (err set).
int PushHttp(string url, string contentType, string body, bool isGet, string &err)
  {
   if(StringFind(url, "http") != 0) { err = "url must start with http"; return(-1); }

   string hdrs = "";
   if(StringLen(contentType) > 0)
      hdrs += "Content-Type: " + contentType + "\r\n";
   if(StringLen(NotifyToken) > 0)
      hdrs += "Authorization: Bearer " + NotifyToken + "\r\n";
   hdrs += "User-Agent: " + Prefix + "-FVG-Breaker/3.0\r\n";

   int timeout = NotifyTimeoutMs;
   if(timeout < 500) timeout = 500;          // never let a dead endpoint hang the tick

   uchar post[];
   if(!isGet)
     {
      StringToCharArray(body, post);
      int n = ArraySize(post);
      if(n > 0) ArrayResize(post, n - 1);    // drop the string terminator
      if(ArraySize(post) <= 0) { err = "empty body"; return(-1); }
     }

   uchar  result[];
   // Build 1491 resolves WebRequest by arity, and the arity differs from MQL5.
   // MQL4 takes (verb, url, headers, cookie, timeout, data, data_size,
   // result[], result_headers_string) - nine arguments, with data_size between
   // the payload and the result buffer. Passing MQL5's eight arguments here is a
   // hard compile error ("no one of the overloads can be applied"), which is how
   // this file failed to compile until build 1491 was run over it. result_headers
   // is a plain string, not an array.
   string resHeaders;
   string verb = isGet ? "GET" : "POST";
   int    postDataSize = ArraySize(post);
   int rc = WebRequest(verb, url, hdrs, "", timeout, post, postDataSize, result, resHeaders);
   if(rc < 0)
      err = "webrequest failed, err " + IntegerToString(GetLastError()) +
            " (is the address allowed in Tools > Options > Expert Advisors?)";
   else if(StringLen(resHeaders) > 0 && rc >= 400)
      err = "response rejected by the endpoint";
   return(rc);
  }

// The gate: enabled, deduplicated, throttled, capped. Records the decision
// either way, so the log explains silence as well as speech.
void SendPush(string tag, string body)
  {
   if(!NotifyEnabled || StringLen(NotifyUrl) == 0) return;

   int dedupeMin = (NotifyMinMinutes < 1) ? 1 : NotifyMinMinutes;
   int now       = (int)TimeCurrent();

   if(StringLen(g_pushLastMsg) > 0 && g_pushLastMsg == body &&
      (now - g_pushLastAt) < dedupeMin * 60)
     {
      PushLog(tag, "DROPPED", "duplicate inside " + IntegerToString(dedupeMin) + "m", "", body);
      return;
     }

   int hr = now / 3600;
   if(hr != g_pushHour) { g_pushHour = hr; g_pushHourN = 0; }
   if(NotifyMaxPerHour > 0 && g_pushHourN >= NotifyMaxPerHour)
     {
      g_pushLastErr = "hourly cap reached";
      PushLog(tag, "DROPPED", "hourly cap " + IntegerToString(NotifyMaxPerHour), "", body);
      return;
     }

   string err = "";
   int    rc  = 0;
   bool   attempted = false;

   if(IsTesting() || IsOptimization())
      err = "not sent: WebRequest does not run in the strategy tester";
   else if(NotifyFormat == NOTIFY_GET)
     { attempted = true; rc = PushHttp(NotifyUrl + "?" + PushUrlEncode(body), "", "", true, err); }
   else if(NotifyFormat == NOTIFY_JSON)
     {
      attempted = true;
      rc = PushHttp(NotifyUrl, "application/json",
                    "{\"title\":\"" + PushJsonEsc(NotifyTitle) + "\",\"message\":\"" +
                    PushJsonEsc(body) + "\"}", false, err);
     }
   else if(NotifyFormat == NOTIFY_PLAIN)
     { attempted = true; rc = PushHttp(NotifyUrl, "text/plain; charset=utf-8", body, false, err); }
   else if(StringFind(NotifyUrl, "ntfy.sh/") >= 0)
     {
      // ntfy takes the message as the raw body and the title as a header, so a
      // form-encoded "title=..&message=.." body would arrive URL-garbled.
      attempted = true;
      rc = PushHttp(NotifyUrl, "text/plain; charset=utf-8", body, false, err);
     }
   else
     {
      attempted = true;
      string form = "title=" + PushUrlEncode(NotifyTitle) + "&message=" + PushUrlEncode(body);
      rc = PushHttp(NotifyUrl, "application/x-www-form-urlencoded", form, false, err);
     }

   string status;
   if(!attempted)                  status = "TESTMODE";   // logged, transport unavailable
   else if(rc >= 200 && rc < 300)  status = "OK";
   else                            status = "FAIL";

   if(status == "FAIL")
     {
      g_pushFail++;
      if(StringLen(err) == 0) err = "http " + IntegerToString(rc);
      g_pushLastErr = "send failed: " + err;
     }
   else
     {
      g_pushSent++;
      g_pushHourN++;
      g_pushLastAt  = now;
      g_pushLastMsg = body;
      if(status == "OK") g_pushLastErr = "ok";
     }
   PushLog(tag, status, attempted ? IntegerToString(rc) : "-", err, body);
  }

void PushLog(string tag, string status, string detail, string err, string body)
  {
   // The notify.csv header stays the stable six columns the report parses; the
   // error text is folded into the detail column rather than adding a seventh,
   // so a row always reads the same way.
   string why = (StringLen(err) > 0) ? (detail + " " + err) : detail;
   CsvAppend("notify.csv", "time,tag,status,detail,title,message",
     CsvTime(TimeCurrent()) + "," + tag + "," + status + "," +
     PushCsvSafe(why) + "," + PushCsvSafe(NotifyTitle) + "," + PushCsvSafe(body));
   Print(Prefix, " push[", tag, "] ", status, " ", why);
  }

// --- Message text -------------------------------------------------
// One line per fact, in the order you read a trade: direction, size, the
// levels, then why. Prices carry Digits decimals so a number copied off the
// phone matches the chart exactly.

string PushEntryBody(int dir, string sigLabel, int confl, double entry, double sl,
                     double tp, double lots, bool pending)
  {
   double riskPts = MathAbs(entry - sl) / Point;
   double rr      = (riskPts > 0.0) ? MathAbs(tp - entry) / riskPts : 0.0;
   string body = (pending ? "LIMIT PLACED  " : "ENTERED  ") +
                 DirName(dir) + " " + Symbol() + " " + DoubleToString(lots, 2) + " lots\n" +
                 "Entry " + DoubleToString(entry, Digits) +
                 "   SL " + DoubleToString(sl, Digits) +
                 "   TP " + DoubleToString(tp, Digits) + "\n" +
                 "Risk " + DoubleToString(riskPts, 0) + " pts   R:R " +
                 DoubleToString(rr, 2) + "\n" +
                 "Signal " + sigLabel + "  confluence " + IntegerToString(confl) + "\n" +
                 "Spread " + DoubleToString(SpreadPoints(), 1) + " pts   " +
                 SessionName(TimeCurrent()) + "   bal " + DoubleToString(AccountBalance(), 2);
   if(pending)
      body += "\nWaits for price; expires after " + IntegerToString(LimitExpiryBars) + " bars";
   return(body);
  }

// Sent the tick a pending limit becomes a position, which is the first moment
// the trade can act. Includes how long the limit waited, because a fill that
// took 4 of 4 bars is a different trade from one that filled instantly.
string PushFillBody(int slot, int dir)
  {
   int waitMin = (g_rec[slot].tPlaced > 0)
                 ? (int)((g_rec[slot].tOpen - g_rec[slot].tPlaced) / 60) : 0;
   return("FILLED  " + DirName(dir) + " " + Symbol() + " " +
          DoubleToString(g_rec[slot].lots, 2) + " lots at " +
          DoubleToString(g_rec[slot].entry, Digits) + "\n" +
          "SL " + DoubleToString(g_rec[slot].sl, Digits) +
          "   TP " + DoubleToString(g_rec[slot].tp, Digits) + "\n" +
          "Limit waited " + IntegerToString(waitMin) + " min\n" +
          "Signal " + g_rec[slot].sigType);
  }

string PushCloseBody(int i, string exitReason, double profit, double rMult,
                     datetime tEnd, double closePrice)
  {
   int holdMin = (g_rec[i].tOpen > 0) ? (int)((tEnd - g_rec[i].tOpen) / 60) : 0;
   return("CLOSED  " + DirName(g_rec[i].dir) + " " + Symbol() + "  " + exitReason + "\n" +
          "P/L " + DoubleToString(profit, 2) + "  (" + DoubleToString(rMult, 2) + "R)\n" +
          "Entry " + DoubleToString(g_rec[i].entry, Digits) +
          "   exit " + DoubleToString(closePrice, Digits) +
          "   SL was " + DoubleToString(g_rec[i].sl, Digits) + "\n" +
          "Signal " + g_rec[i].sigType + "   held " + IntegerToString(holdMin) + " min\n" +
          "Balance " + DoubleToString(AccountBalance(), 2));
  }

// One line on the dashboard. A push that quietly failed for a week is worse
// than no push, so the failure count and reason are always visible.
string PushStatusText()
  {
   if(!NotifyEnabled) return("off");
   if(StringLen(NotifyUrl) == 0) return("on, no URL configured");
   string s = IntegerToString(g_pushSent) + " sent, " +
              IntegerToString(g_pushFail) + " failed  (" + g_pushLastErr + ")";
   if(IsTesting() || IsOptimization()) s += "  [tester: log only]";
   return(s);
  }

//+------------------------------------------------------------------+
//| Guards that every entry must pass                                  |
//+------------------------------------------------------------------+
bool GuardsAllow(int dir, string &why)
  {
   why = "";
   if(g_killed)                 { why = g_killReason; return(false); }
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

   if(AccountFreeMargin() < MinFreeMarginUsd + 20.0)
      { why = "free margin " + DoubleToString(AccountFreeMargin(), 2) + " below floor"; return(false); }

   // one signal per direction per bar
   int slot = (dir > 0 ? 0 : 1);
   if(g_lastSigBar[slot] == Time[0]) { why = "already traded this bar"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Position / pending helpers                                         |
//+------------------------------------------------------------------+
int CountOpen()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) n++;
     }
   return(n);
  }

int CountPendings()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      if(OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT ||
         OrderType() == OP_BUYSTOP  || OrderType() == OP_SELLSTOP) n++;
     }
   return(n);
  }

int CountPositions()
  {
   return(CountOpen() + CountPendings());
  }

bool TicketAlive(int tk)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderTicket() == tk) return(true);
   return(false);
  }

double NormalizeLots(double lots)
  {
   double minl = MarketInfo(Symbol(), MODE_MINLOT);
   double maxl = MarketInfo(Symbol(), MODE_MAXLOT);
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;
   if(minl <= 0.0) minl = 0.01;
   if(maxl <= 0.0) maxl = 100.0;
   lots = MathFloor(lots / step + 0.000000001) * step;
   if(lots < minl) lots = minl;
   if(lots > maxl) lots = maxl;
   return(NormalizeDouble(lots, 2));
  }

// Margin the position would consume, in account currency.
// MQL4 has no OrderCalcMargin - that is an MQL5 function, and calling it here
// was one of the reasons the file did not compile. The MQL4 route is
// AccountFreeMarginCheck: it reports the free margin that would remain if the
// position were opened, so the margin it consumes is simply the difference.
// When funds are insufficient it returns the shortfall as a negative number,
// and the same subtraction still yields the margin required, so no error-state
// sniffing is needed. The figure already reflects the broker's leverage,
// contract size and any positions already open.
double MarginNeeded(double lots, int opType, double price)
  {
   double m = AccountFreeMargin() - AccountFreeMarginCheck(Symbol(), opType, lots);
   if(m <= 0.0)
     {
      double perLot = MarketInfo(Symbol(), MODE_MARGINREQUIRED);
      if(perLot > 0.0) m = perLot * lots;
     }
   if(m <= 0.0) return(1e10);
   return(m);
  }

// Lot sizing. RiskPercent drives it; MaxLot and the margin guard cap it.
// On a $100 gold account the margin guard is what bites first - that is a
// fact of the contract size, not a bug, and it is logged so it is visible.
double CalcLots(double stopDistPts, int opType, double price, string &whyBlock)
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
   double perLot = MarginNeeded(1.0, opType, price);
   if(perLot > 0.0 && perLot < 1e9 && lots * perLot > mMax)
     {
      double allowed = mMax / perLot;
      lots = allowed;
     }

   double minl = MarketInfo(Symbol(), MODE_MINLOT);
   if(minl <= 0.0) minl = 0.01;
   if(lots < minl)
     {
      whyBlock = "margin: only " + DoubleToString(lots, 3) + " lots affordable, broker minimum " +
                 DoubleToString(minl, 2) + " (equity " + DoubleToString(Equity(), 2) + ")";
      return(0.0);
     }
   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| Signal + order dispatch                                            |
//+------------------------------------------------------------------+
void LogSignal(string mode, int dir, string sigLabel, int confl, double entry, double sl,
               double tp, double lots, string note)
  {
   double riskPts = MathAbs(entry - sl) / Point;
   double rr      = riskPts > 0.0 ? MathAbs(tp - entry) / riskPts : 0.0;
   CsvAppend("signals.csv",
     "time,bar_time,mode,dir,signal_label,confluence,entry,sl,tp,stop_pts,rr_planned,lots,risk_usd,spread_pts,atr,session,equity,trend,note",
     CsvTime(TimeCurrent()) + "," + TimeToStr(Time[0], TIME_DATE | TIME_MINUTES) + "," + mode + "," +
     DirName(dir) + "," + sigLabel + "," + IntegerToString(confl) + "," +
     DoubleToString(entry, Digits) + "," + DoubleToString(sl, Digits) + "," + DoubleToString(tp, Digits) +
     "," + DoubleToString(riskPts, 0) + "," + DoubleToString(rr, 2) + "," +
     DoubleToString(lots, 2) + "," + DoubleToString(lots * riskPts * UsdPerPointPerLot(), 2) + "," +
     DoubleToString(SpreadPoints(), 1) + "," + DoubleToString(g_atr, Digits) + "," +
     SessionName(TimeCurrent()) + "," + DoubleToString(Equity(), 2) + "," + DirName(g_trend) + "," + note);
   g_sigCount++;
   g_tradesToday++;
   int slot = (dir > 0 ? 0 : 1);
   g_lastSigBar[slot] = Time[0];
   Print(Prefix, " SIGNAL ", mode, " ", DirName(dir), " ", sigLabel, " conf=", confl,
         " entry=", DoubleToString(entry, Digits), " sl=", DoubleToString(sl, Digits),
         " tp=", DoubleToString(tp, Digits), " lots=", DoubleToString(lots, 2));
  }

double BrokerStopLevelPts()
  {
   double sl = MarketInfo(Symbol(), MODE_STOPLEVEL);
   if(sl <= 0.0) sl = 10.0;
   return(sl);
  }

// Place (or pretend-place) the trade. Every branch is logged so the report
// can tell "no signal" apart from "signal but blocked".
void SendEntry(int dir, string sigLabel, int confl, bool pending, double entryPrice,
               double sl, double tp, double lots, int zi)
  {
   if(DryRun || !IsTradeAllowed())
     {
      LogSignal(DryRun ? "DRY" : "BLOCKED_NO_AUTOTRADE", dir, sigLabel, confl, entryPrice, sl, tp,
                lots, DryRun ? "dry run" : "auto-trading disabled in terminal");
      if(!DryRun) Reject("AUTOTRADE_DISABLED", dir, "terminal AutoTrading button is off", zi);
      return;
     }

   double price = NormalizeDouble(pending ? entryPrice : (dir > 0 ? Ask : Bid), Digits);
   int    cmd   = dir > 0 ? OP_BUY : OP_SELL;
   if(pending) cmd = (dir > 0 ? OP_BUYLIMIT : OP_SELLLIMIT);

   // A limit order must clear the broker stop level or OrderSend rejects it.
   if(pending)
     {
      double minDist = BrokerStopLevelPts() * Point;
      if(dir > 0 && Ask - price < minDist)
        { Reject("LIMIT_TOO_CLOSE", dir, "gap to market " + DoubleToString((Ask - price) / Point, 0) + "pt", zi); return; }
      if(dir < 0 && price - Bid < minDist)
        { Reject("LIMIT_TOO_CLOSE", dir, "gap to market " + DoubleToString((price - Bid) / Point, 0) + "pt", zi); return; }
     }

   datetime expiry = 0;
   if(pending && LimitExpiryBars > 0)
      expiry = TimeCurrent() + LimitExpiryBars * Period() * 60;

   int tk = OrderSend(Symbol(), cmd, lots, price, (int)MaxSlippagePoints,
                      NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                      Prefix + " " + sigLabel, MagicNumber, expiry, clrGray);
   if(tk < 0)
     {
      Reject("ORDERSEND_FAIL", dir,
             "err=" + IntegerToString(GetLastError()) + " cmd=" + IntegerToString(cmd) +
             " lots=" + DoubleToString(lots, 2) + " price=" + DoubleToString(price, Digits) +
             " sl=" + DoubleToString(sl, Digits) + " tp=" + DoubleToString(tp, Digits), zi);
      return;
     }

   if(!OrderSelect(tk, SELECT_BY_TICKET)) return;
   int s = RecFree();
   if(s >= 0)
     {
      g_rec[s].used       = true;
      g_rec[s].ticket     = tk;
      g_rec[s].dir        = dir;
      g_rec[s].sigType    = sigLabel;
      g_rec[s].confluence = confl;
      g_rec[s].entry      = OrderOpenPrice();
      g_rec[s].sl         = OrderStopLoss();
      g_rec[s].tp         = OrderTakeProfit();
      g_rec[s].riskDist   = MathAbs(OrderOpenPrice() - OrderStopLoss()) / Point;
      g_rec[s].lots       = OrderLots();
      g_rec[s].atr        = g_atr;
      g_rec[s].spreadPts  = SpreadPoints();
      g_rec[s].mae        = 0.0;
      g_rec[s].mfe        = 0.0;
      // The clock starts when the trade exists, not when the ticket was placed.
      // A limit that sits unfilled for 6 bars must not arrive with MinHoldBars
      // already satisfied, or the very tick that fills it is allowed to move the
      // stop to breakeven and stop the trade out at the fill price. tOpen is set
      // by ManageOpenPositions when the pending becomes a position.
      g_rec[s].tOpen      = (pending ? 0 : TimeCurrent());
      g_rec[s].tPlaced    = (pending ? TimeCurrent() : 0);
      g_rec[s].tBE        = 0;
      g_rec[s].tp1Done    = 0;
      g_rec[s].tLastBar   = Time[0];
     }

   LogSignal(pending ? "PENDING" : "MARKET", dir, sigLabel, confl, OrderOpenPrice(),
             OrderStopLoss(), OrderTakeProfit(), OrderLots(), "ticket " + IntegerToString(tk));
   if(NotifyOnSignal)
      SendPush(pending ? "PENDING" : "ENTRY",
        PushEntryBody(dir, sigLabel, confl, OrderOpenPrice(), OrderStopLoss(),
                      OrderTakeProfit(), OrderLots(), pending));
   if(zi >= 0 && zi < ArraySize(g_zones))
     {
      g_zones[zi].traded = true;
      g_zones[zi].tTrade = TimeCurrent();
      ZoneLog(zi, "TRADED", sigLabel);
     }
  }

// A stale limit is a trap: cancel it once it has outlived its setup.
//
// Age is read from the order itself. The previous version kept one timestamp
// per direction, so after a limit filled the next same-direction limit was
// measured against the *previous* order's placement time and expired on the
// tick it was created. OrderOpenTime() is when the ticket was placed, which is
// the only clock that matches the question "has this order outlived its setup".
void ExpirePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      if(OrderType() <= OP_SELL) continue;
      if(LimitExpiryBars <= 0) continue;
      int ageBars = (int)((Time[0] - OrderOpenTime()) / (Period() * 60));
      if(ageBars > LimitExpiryBars)
        {
         Reject("LIMIT_EXPIRED", (OrderType() == OP_BUYLIMIT || OrderType() == OP_BUYSTOP) ? 1 : -1,
                "unfilled after " + IntegerToString(ageBars) + " bars at " +
                DoubleToString(OrderOpenPrice(), Digits), -1);
         if(!OrderDelete(OrderTicket(), clrGray))
            Print(Prefix, " delete failed ticket ", OrderTicket(), " err=", GetLastError());
         int s = RecSlot(OrderTicket());
         if(s >= 0) g_rec[s].used = false;      // never traded, so no row is owed
        }
     }
  }

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| THE SETUP                                                        |
//|   trend (H1) + unmitigated FVG (M15) + breaker/mitigation        |
//|   confluence + price already trading back into the zone.         |
//|   Then either a limit deep in the zone, or a rejection candle.   |
//+------------------------------------------------------------------+
void EvaluateSetup()
  {
   g_trend = DetermineTrend();
   if(g_atr <= 0.0) g_atr = AtrVal(0, 1);
   if(g_atr <= 0.0) return;
   if(g_killed) { Reject("KILLED", 0, g_killReason, -1); return; }

   int bestIdx = -1, bestDir = 0, bestConfl = 0;
   double bestScore = -1e10;
   string rejReason = "", rejDetail = ""; int rejZone = -1;   // first reason only (no spam)

   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid || g_zones[i].traded || g_zones[i].mitigated) continue;
      if(!g_zones[i].touched) continue;                 // must already be trading back into us

      int dir = g_zones[i].dir;
      if(dir != g_trend) continue;                      // trend alignment only

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
      double riskPts = MathAbs(entry - sl) / Point;
      if(riskPts < g_minStopPts)
        { sl = entry + (dir > 0 ? -1 : 1) * g_minStopPts * Point; riskPts = MathAbs(entry - sl) / Point; }
      if(riskPts > g_maxStopPts)
        {
         if(rejReason == "") { rejReason = "STOP_TOO_WIDE"; rejDetail = DoubleToString(riskPts, 0) + "pt"; rejZone = i; }
         continue;
        }

      double tp = 0.0;
      if(ExitMode == EXIT_FIXED_RR)  tp = entry + dir * riskPts * Tp2RR * Point;
      if(ExitMode == EXIT_ZONE_RR)
        {
         tp = entry + dir * riskPts * Tp2RR * Point;
         double zt = NextOpposingTarget(dir, entry);
         if(zt > 0.0 && MathAbs(zt - entry) / (riskPts * Point) >= 1.2) tp = zt;
        }

      // --- chase guards
      double dist = (dir > 0) ? (Bid - entry) : (entry - Bid);
      g_setupDist = dist / Point;
      if(dist > g_maxEntryPts * Point)
        {
         if(rejReason == "") { rejReason = "TOO_FAR"; rejDetail = DoubleToString(dist / Point, 0) + "pt from zone"; rejZone = i; }
         continue;
        }
      double emaFast = iMA(Symbol(), TrendTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
      if(g_maxEmaDistPts > 0 && MathAbs(Bid - emaFast) / Point > g_maxEmaDistPts)
        {
         if(rejReason == "") { rejReason = "OVEREXTENDED"; rejDetail = "far from fast EMA"; rejZone = i; }
         continue;
        }

      int barsSinceTouch = (int)((Time[1] - g_zones[i].tTouch) / (Period() * 60));
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
      score -= MathAbs(dist) / (g_maxEntryPts * Point);

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

   double lots = CalcLots(MathAbs(g_bestEntry - g_bestSl) / Point,
                          bestDir > 0 ? OP_BUY : OP_SELL, bestDir > 0 ? Ask : Bid, why);
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
      if(Close[1] <= Open[1]) return(false);
      return((Close[1] - Low[1]) / rng * 100.0 >= MinTriggerClosePct);
     }
   else
     {
      if(WickUp(1) / rng * 100.0 < MinRejectionWickPct) return(false);
      if(Close[1] >= Open[1]) return(false);
      return((High[1] - Close[1]) / rng * 100.0 >= MinTriggerClosePct);
     }
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS                                            |
//|   - track MAE/MFE for the report                                  |
//|   - move to breakeven after BreakEvenTriggerRR                    |
//|   - close Tp1Percent of the position at Tp1RR                     |
//|   - trail behind price with ATR once TrailStartRR is reached      |
//|   - write the closed-trade row when the ticket disappears         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   // --- detect closed tickets first, so the row is written on the tick it closes
   for(int s = 0; s < 8; s++)
     {
      if(!g_rec[s].used) continue;
      if(TicketAlive(g_rec[s].ticket)) continue;

      // A limit that was cancelled instead of filled still leaves a history
      // row, with zero profit. It was never a trade: writing it adds a 0.00R
      // entry that dilutes expectancy and win rate, the two numbers the
      // go/no-go review is made from.
      double   pEnd = 0.0;
      double   pxEnd = 0.0;
      datetime tOpenHist = 0;
      datetime tEnd = 0;
      if(!ClosedOrderInfo(g_rec[s].ticket, pEnd, tOpenHist, tEnd, pxEnd))
        {
         Reject("CANCELLED_UNFILLED", g_rec[s].dir,
                "ticket " + IntegerToString(g_rec[s].ticket) + " removed before fill", -1);
         g_rec[s].used = false;
         continue;
        }
      // A limit that fills and then hits its stop inside the same tick is never
      // seen by the management loop below, so tOpen can still be 0 here. Take it
      // from the history row, or hold_bars and session come out of a 1970 epoch.
      if(g_rec[s].tOpen == 0) g_rec[s].tOpen = tOpenHist;

      string whyExit = ExitReasonGuess(s, pxEnd);
      RecClose(g_rec[s].ticket, whyExit, pEnd, tEnd, pxEnd);
      g_rec[s].used = false;
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int dir    = (OrderType() == OP_BUY) ? 1 : -1;
      int slot   = RecSlot(OrderTicket());
      double entry = OrderOpenPrice();
      double tp    = OrderTakeProfit();
      double riskPts = (slot >= 0) ? g_rec[slot].riskDist : 0.0;
      if(riskPts <= 0.0) continue;              // unknown risk = do not manage blind

      // A limit that has just filled starts its clock here. Until now the
      // record was a pending order and hold time meant nothing, so this is the
      // tick from which MinHoldBars counts. Without it a limit that took six
      // bars to fill arrives already past MinHoldBars and can be moved to
      // breakeven on the tick it was filled, stopping out at its own entry.
      //
      // TimeCurrent() rather than OrderOpenTime(): what a filled ticket reports
      // there is not consistent across builds (some keep the placement time),
      // and this is the first tick on which the EA knows the position exists,
      // so the measured hold time can only be shorter than reality - the safe
      // direction for a rule that delays protection.
      if(slot >= 0 && g_rec[slot].tOpen == 0)
        {
         g_rec[slot].tOpen = TimeCurrent();
         if(NotifyOnSignal) SendPush("FILL", PushFillBody(slot, dir));
        }

      double curPrice = (dir > 0) ? Bid : Ask;
      double rNow     = ((curPrice - entry) / Point * dir) / riskPts;

      // --- MAE / MFE bookkeeping (the "was I early or wrong" dataset)
      double fav = ((dir > 0 ? High[1] : Low[1]) - entry) / Point * dir;
      double adv = ((dir > 0 ? Low[1] : High[1]) - entry) / Point * dir;
      if(fav > g_rec[slot].mfe) g_rec[slot].mfe = fav;
      if(adv < g_rec[slot].mae) g_rec[slot].mae = adv;
      g_rec[slot].tLastBar = Time[0];

      int holdBars = (int)((Time[0] - g_rec[slot].tOpen) / (Period() * 60));
      if(holdBars < MinHoldBars) continue;

      // --- TP1 partial, then hard-lock the runner
      if(!g_rec[slot].tp1Done && Tp1Percent > 0.0 && ExitMode != EXIT_TRAIL_ONLY && rNow >= Tp1RR)
        {
         double minl = MarketInfo(Symbol(), MODE_MINLOT);
         double closeLots = NormalizeLots(OrderLots() * Tp1Percent / 100.0);
         double remain = OrderLots() - closeLots;
         if(closeLots >= minl && remain >= minl)
           {
            if(OrderClose(OrderTicket(), closeLots, NormalizeDouble(curPrice, Digits),
                          (int)MaxSlippagePoints, clrGold))
              {
               g_rec[slot].tp1Done = 1;
               CsvAppend("partials.csv",
                 "time,ticket,dir,lots_closed,price,r_multiple_at_close,remaining_lots,signal_type",
                 CsvTime(TimeCurrent()) + "," + IntegerToString(OrderTicket()) + "," + DirName(dir) +
                 "," + DoubleToString(closeLots, 2) + "," + DoubleToString(curPrice, Digits) + "," +
                 DoubleToString(rNow, 2) + "," + DoubleToString(remain, 2) + "," + g_rec[slot].sigType);
               Print(Prefix, " TP1 closed ", DoubleToString(closeLots, 2), " lots at R ",
                     DoubleToString(rNow, 2));
               if(NotifyOnTp1)
                  SendPush("TP1", DirName(dir) + " " + Symbol() + " TP1 banked " +
                           DoubleToString(closeLots, 2) + " of " +
                           DoubleToString(closeLots + remain, 2) + " lots at " +
                           DoubleToString(curPrice, Digits) + " (+" +
                           DoubleToString(rNow, 2) + "R), " +
                           DoubleToString(remain, 2) + " lots running, stop moved to breakeven");
               double be = entry + dir * (g_beOffsetPts + 5.0) * Point;
               ModifyStop(OrderTicket(), dir, be, tp);
              }
            else
               Print(Prefix, " TP1 close failed err=", GetLastError());
           }
        }

      // --- breakeven
      if(rNow >= BreakEvenTriggerRR)
        {
         double be = entry + dir * g_beOffsetPts * Point;
         bool better = (dir > 0) ? (OrderStopLoss() < be - 0.5 * Point)
                                 : (OrderStopLoss() == 0.0 || OrderStopLoss() > be + 0.5 * Point);
         if(better && g_rec[slot].tBE == 0)
            if(ModifyStop(OrderTicket(), dir, be, tp)) g_rec[slot].tBE = TimeCurrent();
        }

      // --- ATR trail (activates only in profit, so it never cuts a healthy entry)
      if(UseAtrTrail && rNow >= TrailStartRR)
        {
         double trail = (dir > 0)
                        ? NormalizeDouble(High[1] - TrailAtrMult * g_atr, Digits)
                        : NormalizeDouble(Low[1] + TrailAtrMult * g_atr, Digits);
         if(dir > 0 && OrderStopLoss() > 0.0 && trail > OrderStopLoss() + Point)
            ModifyStop(OrderTicket(), dir, trail, tp);
         if(dir < 0 && (OrderStopLoss() == 0.0 ||
             (trail < OrderStopLoss() - Point && trail < Bid)))
            ModifyStop(OrderTicket(), dir, trail, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Order / bookkeeping helpers used by ManageOpenPositions            |
//+------------------------------------------------------------------+
bool ModifyStop(int ticket, int dir, double newSl, double tp)
  {
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return(false);
   if(OrderCloseTime() != 0) return(false);
   double minDist = BrokerStopLevelPts() * Point;
   RefreshRates();
   if(dir > 0 && (Bid - newSl) < minDist) return(false);
   if(dir < 0 && (newSl - Ask) < minDist) return(false);
   newSl = NormalizeDouble(newSl, Digits);
   if(MathAbs(OrderStopLoss() - newSl) < Point * 0.5) return(true);
   bool ok = OrderModify(ticket, OrderOpenPrice(), newSl, NormalizeDouble(tp, Digits), 0, clrYellow);
   if(!ok) Print(Prefix, " modify failed ticket ", ticket, " err=", GetLastError());
   return(ok);
  }

// Everything the report needs about a ticket that has left the terminal.
//
// Two bugs this replaces:
//
//   1. It used to return the FIRST history row found. A partial close leaves
//      one row per leg under the same ticket, so after TP1 the trade reported
//      only the runner's P/L while still charging the full original lot as the
//      risk - every TP1 winner was recorded with its profit understated.
//      Summing the legs is the only reading that matches "what did this trade
//      make me".
//
//   2. A limit that was cancelled rather than filled also has a history row,
//      with zero profit. Returning 0.0 for it produced a 0.00R trade row out of
//      a trade that never happened. Returning false lets the caller drop it.
//
// closePrice / closeTime come from the last leg, which is where the trade
// genuinely ended. Returns false when no position row exists for the ticket.
bool ClosedOrderInfo(int ticket, double &profit, datetime &openTime,
                     datetime &closeTime, double &closePrice)
  {
   profit = 0.0;
   openTime = 0;
   closeTime = 0;
   closePrice = 0.0;
   bool found = false;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderTicket() != ticket) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      profit += OrderProfit() + OrderSwap() + OrderCommission();
      if(openTime == 0 || OrderOpenTime() < openTime) openTime = OrderOpenTime();
      if(OrderCloseTime() >= closeTime)
        {
         closeTime  = OrderCloseTime();
         closePrice = OrderClosePrice();
        }
      found = true;
     }
   return(found);
  }

// Best-effort exit attribution from the path the trade actually took.
// MT4 does not tell us why a position vanished, so we infer it and the
// report shows it as INFERRED - never pretend it is exact.
//
// exitPrice is the actual fill. Comparing it against TP decides whether the
// trade ran to the target: relying on recorded MFE alone mislabels these,
// because MFE is sampled once per bar and the tick that hits TP is not a bar
// close. A trade closed at TP is a TP2 exit even when the bar never printed
// beyond it, and a trade that banked TP1 and then died at the locked stop must
// not be called TP2 just because TP1 was reached first.
string ExitReasonGuess(int slot, double exitPrice)
  {
   if(slot < 0 || slot > 7) return("UNKNOWN");
   double tpPts = 0.0;
   if(g_rec[slot].tp > 0.0 && g_rec[slot].riskDist > 0.0)
      tpPts = MathAbs(g_rec[slot].tp - g_rec[slot].entry) / Point;

   // Closed at (or within a whisker of) the target. The tolerance is 2 points:
   // on a 3-digit gold feed a TP fill can print a point or two on either side,
   // and the only question here is "did it reach TP2".
   if(g_rec[slot].tp > 0.0 && exitPrice > 0.0)
     {
      if(MathAbs(g_rec[slot].tp - exitPrice) <= 2.0 * Point) return("TP2");
     }
   else if(tpPts > 0.0 && g_rec[slot].mfe >= tpPts - 2.0) return("TP2");

   if(g_rec[slot].tp1Done > 0) return("TP1_RUNNER");   // banked TP1, runner then exited
   if(g_rec[slot].tBE > 0) return("BE_OR_TRAIL");
   return("STOP_LOSS");
  }

void FlattenAll(string why)
  {
   static string lastWhy = "";
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      RefreshRates();
      bool ok = false;
      if(OrderType() == OP_BUY)
         ok = OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(Bid, Digits),
                         (int)MaxSlippagePoints, clrRed);
      else if(OrderType() == OP_SELL)
         ok = OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(Ask, Digits),
                         (int)MaxSlippagePoints, clrRed);
      else
         ok = OrderDelete(OrderTicket(), clrRed);
      if(!ok) Print(Prefix, " flatten failed ticket ", OrderTicket(), " err=", GetLastError());
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
   ObjectsDeleteAll(0, Prefix + "_Z");
   ObjectsDeleteAll(0, Prefix + "_L");
   if(!DrawZones) return;
   int n = ArraySize(g_zones);
   int drawn = 0;
   for(int i = n - 1; i >= 0 && drawn < ZoneMaxDraw; i--)
     {
      if(!g_zones[i].valid) continue;
      drawn++;
      color c = ClrBuyZone;
      if(g_zones[i].dir < 0) c = ClrSellZone;
      if(g_zones[i].type == HEX_ZONE_BREAKER) c = ClrBreaker;
      if(g_zones[i].type == HEX_ZONE_MITIG)   c = ClrMitigation;

      string nm = Prefix + "_Z" + IntegerToString(i);
      if(ObjectCreate(0, nm, OBJ_RECTANGLE, 0, g_zones[i].t1, g_zones[i].top,
                      g_zones[i].t2 + Period() * 60, g_zones[i].bottom))
        {
         ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
         ObjectSetInteger(0, nm, OBJPROP_STYLE, g_zones[i].touched ? STYLE_SOLID : STYLE_DOT);
         ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, nm, OBJPROP_FILL, false);
         ObjectSetInteger(0, nm, OBJPROP_BACK, true);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
        }
      string lb = Prefix + "_L" + IntegerToString(i);
      if(ObjectCreate(0, lb, OBJ_TEXT, 0, g_zones[i].t2 + Period() * 120, g_zones[i].top))
        {
         ObjectSetString(0, lb, OBJPROP_TEXT, ZoneName(g_zones[i].type) + " " +
                         IntegerToString((int)(g_zones[i].maxPenet * 100)) + "%");
         ObjectSetInteger(0, lb, OBJPROP_COLOR, c);
         ObjectSetInteger(0, lb, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, lb, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
         ObjectSetInteger(0, lb, OBJPROP_SELECTABLE, false);
        }
     }
  }

//+------------------------------------------------------------------+
//| DASHBOARD - live state, so you always know why it is not trading  |
//+------------------------------------------------------------------+
void RenderDashboard()
  {
   if(!ShowDashboard) return;
   static datetime lastDraw = 0;
   if(TimeCurrent() == lastDraw && g_tickCount > 1) return;
   lastDraw = TimeCurrent();

   string txt = "\n────────────── HEX FVG / BREAKER ──────────────\n";
   string modeTxt = DryRun ? "DRY RUN (no orders)" : "LIVE";
   string entryTxt = (EntryModel == ENTRY_LIMIT) ? "LIMIT (wait in zone)" : "TRIGGER (rejection candle)";
   txt += "Mode      : " + modeTxt + "   entry: " + entryTxt + "\n";
   txt += "Symbol    : " + Symbol() + "  " + IntegerToString(Period()) + "m  digits=" +
          IntegerToString(Digits) + "\n";
   txt += "Trend " + IntegerToString(TrendTimeframe) + "m : " + DirName(g_trend) + "   [" + g_trendMsg + "]\n";
   txt += "ATR(M15)  : " + DoubleToString(g_atr, Digits) +
          "   spread: " + DoubleToString(SpreadPoints(), 1) + " / max " +
          DoubleToString(g_maxSpreadPts, 0) + (SpreadPoints() > g_maxSpreadPts ? "  << WIDE" : "") + "\n";
   txt += "Live zones: " + ZoneSummary() + "\n";
   txt += "Best setup: " + g_setupMsg + "  dist=" + DoubleToString(g_setupDist, 0) + "pt\n";
   txt += "Positions : " + IntegerToString(CountOpen()) + " open, " +
          IntegerToString(CountPendings()) + " pending   today: " +
          IntegerToString(g_tradesToday) + "/" + IntegerToString(MaxSignalsPerDay) + "\n";
   txt += "Equity    : " + DoubleToString(Equity(), 2) +
          "   free margin: " + DoubleToString(AccountFreeMargin(), 2) + "\n";
   txt += "Peak/DD   : " + DoubleToString(g_ddPeak, 2) + "  " +
          DoubleToString(g_ddPeak > 0 ? (g_ddPeak - Equity()) / g_ddPeak * 100.0 : 0.0, 2) + "%\n";
   txt += "Signals   : " + IntegerToString(g_sigCount) + " taken, " + IntegerToString(g_rejCount) +
          " rejected   logs: " + LogDir() + "\n";
   txt += "Push      : " + PushStatusText() + "\n";
   // AutoTrading is a terminal-wide toggle and nothing in MQL4 can turn it on.
   // The Status line below only reports the kill switch, so "armed" and a dead
   // button can both be true - which is exactly how a silent week starts.
   // IsTradeAllowed() is the only view of that button the EA has, so print it.
   txt += "Trading   : " + (IsTradeAllowed() ? "ON  (AutoTrading)" :
                            "BLOCKED - enable AutoTrading") + "\n";
   if(g_killed) txt += "STATUS    : *** STOPPED - " + g_killReason + " ***\n";
   else         txt += "Status    : armed\n";
   Comment(txt);
  }

string ZoneSummary()
  {
   int f = 0, b = 0, m = 0;
   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if(!g_zones[i].valid) continue;
      if(g_zones[i].type == HEX_ZONE_FVG) f++;
      else if(g_zones[i].type == HEX_ZONE_BREAKER) b++;
      else m++;
     }
   return("FVG " + IntegerToString(f) + "  Breaker " + IntegerToString(b) +
          "  Mitigation " + IntegerToString(m));
  }



