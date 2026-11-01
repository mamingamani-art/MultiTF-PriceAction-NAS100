//+------------------------------------------------------------------+
//|                                  MultiTF_PriceAction_EA.mq4      |
//| Multi-Timeframe Price Action EA - V10 Multi-Market Research                             |
//|                                                                  |
//| Engine A: H1 -> M15 -> M1 (frozen V9 logic)                   |
//| Engine B2: H4 -> H1 -> M5 | IFVG context, active-OB excluded     |
//|                                                                  |
//| Includes:                                                        |
//| - Risk-based position sizing                                     |
//| - Broker-safe SL/TP                                               |
//| - Strategy Tester protection                                     |
//| - CSV diagnostics for setups/trades                              |
//| - Closed-trade result logging                                    |
//| - Direction / zone / server-session research filters             |
//| - M15 POI is configurable confluence rather than mandatory      |
//| - Opening-session window + stronger M1 sweep/displacement         |
//| - Tester spread override for realistic spread stress testing      |
//| - Multi-market 24H research mode + symbol-specific CSV logs       |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "MT4Compat.mqh"

//====================================================================
// ZONE FILTER MODE
//====================================================================
enum ZoneFilterModeEnum
{
   ZONE_ANY = 0,              // OB or IFVG interaction
   ZONE_REQUIRE_IFVG = 1,     // IFVG must be touched; OB confluence allowed
   ZONE_REQUIRE_CONFLUENCE = 2,// both OB and IFVG must be touched
   ZONE_OB_ONLY = 3,          // only OB interaction
   ZONE_IFVG_ONLY = 4         // only IFVG interaction
};

//====================================================================
// INPUTS - RISK MANAGEMENT
//====================================================================
input double RiskPercent               = 1.0;
input bool   UseFixedLot               = false;
input double FixedLotSize              = 0.10;

// LIVE/DEMO spread protection.
// For US30 on this broker the Journal value is effectively MT4 points.
// Example: tester Spread=30 will print approximately spread=30.
//
// IMPORTANT:
// IgnoreSpreadFilterInTester=true does NOT remove the tester spread.
// MT4 still executes with the configured Strategy Tester spread.
// It only prevents the EA's own safety guard from rejecting the trade.
input double MaxSpread                 = 10.0;
input bool   IgnoreSpreadFilterInTester = true;

input double MaxLotCap                 = 10.0;   // extra safety cap

//====================================================================
// INPUTS - TRADE SETTINGS
//====================================================================
input int    MagicNumber               = 260922081;
input double Slippage                  = 3.0;    // logical pips
input int    MaxOpenTrades             = 1;

//====================================================================
// INPUTS - RESEARCH / QUALITY FILTERS
//====================================================================
// NQ100 optimization: only the Buy side of Engine B with a confirmed
// recent H1 IFVG touch remained positive in 2024, 2025, and 2026.
input bool   AllowLongTrades           = true;
input bool   AllowShortTrades          = false;

// V2 diagnostics showed OB-only setups were materially weaker.
// Default V3 therefore requires an IFVG interaction while still
// allowing OB+IFVG confluence.
input ZoneFilterModeEnum ZoneFilterMode = ZONE_REQUIRE_IFVG;

// V7: M15 OB/IFVG can be used as confluence without starving the system.
// If true, old hard POI-touch rules are enforced.
// If false (default), H1/M15 structure + session premium/discount +
// strong M1 sweep/MSS can execute even without a recent M15 zone touch.
input bool   RequireM15ZoneTouch       = false;

// Session logic is expressed in BROKER SERVER TIME.
// V8 separates market-structure formation from actual entry timing.
//
// StructureStartHour = earliest time whose M15/M1 structure is trusted.
// EntryStartHour / EntryEndHour = actual market-order window.
// End hour is exclusive.
input bool   UseSessionFilter           = false;
input int    StructureStartHour         = 15;
input int    EntryStartHour             = 17;
input int    EntryEndHour               = 18;  // 17:00..17:59

// Stronger session integrity:
// M15 structure/zones, dealing range and M1 liquidity references must
// themselves be formed after StructureStartHour.
input bool   RequireSessionFormedSetups = false;

// Build premium/discount only from M15 candles formed after session start.
input int    MinSessionM15BarsForRange  = 2;

// Price may tap an M15 POI first and only then form the M1 sweep/MSS.
// Search this many CLOSED M1 candles back from the sweep candle.
input int    RecentZoneTouchLookbackM1   = 12;

//====================================================================
// INPUTS - GENERAL STRATEGY
//====================================================================
input int    ATR_Period                = 14;
input double MinRVRatio                = 2.0;

// H1
input int    H1StructureLookback       = 24;
input int    H1SwingSpan               = 3;
input double H1MinBreakBodyATR         = 0.25;

// M15
input int    M15StructureLookback      = 20;
input int    M15SwingSpan              = 3;
input int    M15DealingRangeBars       = 20;
input int    M15ZoneLookback           = 32;
input int    M15OBBreakLookback        = 3;
input double M15MinDisplacementATR     = 0.50;
input double M15MinFVGSizeATR          = 0.05;
input double ZoneTouchToleranceATR     = 0.15;
input int    MaxPriorZoneTouches       = 1;

// M1 execution
input int    M1LiquidityLookback       = 8;
input double M1MinConfirmBodyATR       = 0.40;
input double M1MinSweepPenetrationATR  = 0.05;
input double M1SLBufferATR             = 0.15;

// Diagnostics
input bool   DebugMode                 = false;
input bool   EnableCSVLog              = true;

// Multi-market research labeling.
// When AutoCSVNameBySymbol=true the EA automatically creates unique CSV
// names using the chart/test symbol and ResearchRunTag.
// Example: MTF_V10_NQ100_BASE_EngineA.csv
input bool   AutoCSVNameBySymbol       = true;
input string ResearchRunTag            = "NQ100_OPT";
input string CSVFileName               = "MTF_V10_EngineA.csv";

//====================================================================
// INPUTS - V9 MULTI-ENGINE CONTROL
//====================================================================
input bool   EnableEngineA              = false;
input bool   EnableEngineB              = true;

// Engine A keeps the proven V9 magic/risk inputs above.
// Engine B is isolated for independent statistics and execution.
input int    EngineBMagicNumber         = 260925102;
input double EngineBRiskPercent         = 1.0;
input int    MaxOpenTradesTotal         = 2;

// Shared portfolio risk cap across Engine A + Engine B.
// Default 1.0% means both engines may generate signals, but only one
// full-risk 1% position can be open at a time. Raise deliberately only
// after combined-engine validation.
input double MaxCombinedOpenRiskPercent = 1.0;

// Engine B entry session (broker server time).
// H4/H1 context may form before this window; M5 execution structure
// must itself form inside this window.
input bool   EngineBUseEntryWindow      = false;
input int    EngineBEntryStartHour      = 15;
input int    EngineBEntryEndHour        = 17;   // 15:00..16:59

// Engine B uses the same methodology one scale higher.
input bool   EngineBRequireH1ZoneTouch  = true;
input ZoneFilterModeEnum EngineBZoneFilterMode = ZONE_REQUIRE_IFVG;
input int    EngineBRecentZoneTouchM5   = 12;

// V9.1 research hypothesis:
// Require a fresh same-direction H1 IFVG and reject contexts where
// a same-direction active H1 order block is also present.
input bool   EngineBRequireActiveIFVG   = true;
input bool   EngineBRejectActiveOB      = true;

// H4 context
input int    B_H4StructureLookback      = 24;
input int    B_H4SwingSpan              = 3;
input double B_H4MinBreakBodyATR        = 0.25;

// H1 setup / dealing range / POI
input int    B_H1StructureLookback      = 20;
input int    B_H1SwingSpan              = 3;
input int    B_H1DealingRangeBars       = 20;
input int    B_H1ZoneLookback           = 32;
input int    B_H1OBBreakLookback        = 3;
input double B_H1MinDisplacementATR     = 0.50;
input double B_H1MinFVGSizeATR          = 0.05;
input double B_ZoneTouchToleranceATR    = 0.15;
input int    B_MaxPriorZoneTouches      = 1;

// M5 execution
input int    B_M5LiquidityLookback      = 8;
input double B_M5MinConfirmBodyATR      = 0.40;
input double B_M5MinSweepPenetrationATR = 0.05;
input double B_M5SLBufferATR            = 0.15;

input string EngineBCSVFileName         = "MTF_V10_EngineB.csv";

//====================================================================
// CONSTANTS
//====================================================================
#define DIR_NONE   0
#define DIR_BULL   1
#define DIR_BEAR  -1

#define MAX_SEND_RETRIES 3

//====================================================================
// STRUCTURES
//====================================================================
struct PriceZone
{
   bool     found;
   double   low;
   double   high;
   int      shift;
   datetime time;
   string   type;
};

//====================================================================
// GLOBALS
//====================================================================
datetime g_lastM1BarTime = 0;
datetime g_lastM5BarTime = 0;

ulong g_loggedClosedTickets[];
int g_loggedClosedCount = 0;
int g_lastHistoryTotal  = 0;

//====================================================================
// FORWARD DECLARATIONS
//====================================================================
void   DebugPrint(string msg);
string DirectionToString(int direction);
string BoolText(bool value);
string SafeFileToken(string text);
string ResolveCSVFileNameA();
string ResolveCSVFileNameB();
string ZoneFilterToString();
bool   IsDirectionEnabled(int direction);
bool   IsEntryWindowAllowed();
datetime GetSessionStartFor(datetime referenceTime);
bool   IsBarAfterSessionStart(int timeframe, int shift);
int    GetSessionAwareStructureDirection(int timeframe,
                                         int lookback,
                                         int swingSpan,
                                         double minBodyATR);

bool   IsNewM1Bar();
bool   EnoughHistory();
bool   IsTradeEnvironmentOK();

double PipSize();
double TickSizePrice();
double NormalizePrice(double price);
double GetSpreadPips();
bool   IsSpreadAcceptable();
int    SlippagePoints();

int    GetStructureDirection(int timeframe,
                             int lookback,
                             int swingSpan,
                             double minBodyATR);
int    GetH1Bias();
int    GetM15Structure();

bool   GetM15DealingRange(double &rangeLow,
                          double &rangeHigh,
                          double &equilibrium);

bool   IsOrderBlockStillActive(int direction,
                               double zoneLow,
                               double zoneHigh,
                               int displacementShift);

int    CountPriorZoneTouches(double zoneLow,
                             double zoneHigh,
                             int newestShift,
                             int oldestShift);

bool   FindFreshM15OrderBlock(int direction,
                              PriceZone &zone);

bool   FindFreshM15IFVG(int direction,
                        PriceZone &zone);

bool   CandleTouchesZone(double candleLow,
                         double candleHigh,
                         PriceZone &zone,
                         double tolerance);

bool   FindRecentM1ZoneTouch(PriceZone &zone,
                             double tolerance,
                             int &touchShift,
                             datetime &touchTime,
                             double &touchLow,
                             double &touchHigh);

bool   GetM1ExecutionTrigger(int direction,
                             double &referenceLiquidity,
                             double &sweepExtreme,
                             double &confirmClose,
                             double &sweepLow,
                             double &sweepHigh,
                             string &triggerReason);

bool   ValidateM15ContextAfterTrigger(int direction,
                                      double sweepLow,
                                      double sweepHigh,
                                      double sweepExtreme,
                                      PriceZone &ob,
                                      PriceZone &ifvg,
                                      double &rangeLow,
                                      double &equilibrium,
                                      double &rangeHigh,
                                      string &zoneUsed,
                                      double &zoneLow,
                                      double &zoneHigh,
                                      int &zoneTouchShift,
                                      datetime &zoneTouchTime,
                                      string &rejectReason);

double CalculateInitialStopLoss(int direction,
                                double sweepExtreme);

int    GetLotDigits(double lotStep);
double NormalizeLot(double lots);
double CalculateMoneyRisk(double lots,
                          double entryPrice,
                          double stopLoss);
double CalculateLotSize(int command,
                        double entryPrice,
                        double stopLoss,
                        double &estimatedRiskMoney);

bool   BuildBrokerSafeStops(int command,
                            double entry,
                            double structuralSL,
                            double &finalSL,
                            double &finalTP);

int    CountOpenTrades();

bool   IsTransientTradeError(int errorCode);
void   ReportTradeError(string source,
                        int errorCode);

bool   EmergencyCloseOrder(int ticket);

int    SendECNFallback(int command,
                       double lots,
                       double structuralSL,
                       string tradeComment,
                       double &fillPriceOut,
                       double &finalSLOut,
                       double &finalTPOut);

bool   ExecuteMarketTrade(int direction,
                          double structuralSL,
                          string tradeComment,
                          int &ticketOut,
                          double &entryOut,
                          double &slOut,
                          double &tpOut,
                          double &lotsOut,
                          double &riskMoneyOut);

void   InitCSV();
void   CSVWriteOpen(int ticket,
                    int direction,
                    int h1Bias,
                    int m15Structure,
                    bool hasOB,
                    bool hasIFVG,
                    string zoneUsed,
                    double zoneLow,
                    double zoneHigh,
                    double rangeLow,
                    double equilibrium,
                    double rangeHigh,
                    double referenceLiquidity,
                    double sweepExtreme,
                    double confirmClose,
                    double entry,
                    double sl,
                    double tp,
                    double lots,
                    double riskMoney,
                    string triggerReason,
                    string commentText);

void   CSVWriteRejected(int direction,
                        int h1Bias,
                        int m15Structure,
                        bool hasOB,
                        bool hasIFVG,
                        double referenceLiquidity,
                        double sweepExtreme,
                        double confirmClose,
                        string reason);

bool   IsClosedTicketLogged(ulong ticket);
void   MarkClosedTicketLogged(ulong ticket);
void   LogClosedTrades();


//====================================================================
// V9 MULTI-ENGINE FORWARD DECLARATIONS
//====================================================================
bool   IsNewM5Bar();
bool   EnoughHistoryB();
bool   IsHourInsideWindow(datetime t, int startHour, int endHour);
bool   IsBarInsideWindow(int timeframe, int shift, int startHour, int endHour);
bool   IsEngineBEntryWindowAllowed();

void   ProcessEngineA();
void   ProcessEngineB();

int    CountOpenTradesByMagic(int magicNumber);
int    CountAllEngineOpenTrades();
double CurrentCombinedOpenRiskMoney();
bool   CanOpenEngineRisk(int magicNumber, double requestedRiskPercent);

bool   GetDealingRangeTF(int timeframe,
                         int lookbackBars,
                         double &rangeLow,
                         double &rangeHigh,
                         double &equilibrium);

bool   IsOrderBlockStillActiveTF(int timeframe,
                                 int direction,
                                 double zoneLow,
                                 double zoneHigh,
                                 int displacementShift);

int    CountPriorZoneTouchesTF(int timeframe,
                               double zoneLow,
                               double zoneHigh,
                               int newestShift,
                               int oldestShift);

bool   FindFreshOrderBlockTF(int timeframe,
                             int direction,
                             int zoneLookback,
                             int obBreakLookback,
                             double minDisplacementATR,
                             int maxPriorTouches,
                             PriceZone &zone);

bool   FindFreshIFVGTF(int timeframe,
                       int direction,
                       int zoneLookback,
                       double minFVGSizeATR,
                       int maxPriorTouches,
                       PriceZone &zone);

bool   FindRecentZoneTouchTF(PriceZone &zone,
                             int executionTF,
                             int recentLookback,
                             double tolerance,
                             bool restrictToWindow,
                             int startHour,
                             int endHour,
                             int &touchShift,
                             datetime &touchTime,
                             double &touchLow,
                             double &touchHigh);

bool   GetExecutionTriggerTF(int executionTF,
                             int direction,
                             int liquidityLookback,
                             double minConfirmBodyATR,
                             double minSweepPenetrationATR,
                             bool restrictToWindow,
                             int startHour,
                             int endHour,
                             double &referenceLiquidity,
                             double &sweepExtreme,
                             double &confirmClose,
                             double &sweepLow,
                             double &sweepHigh,
                             string &triggerReason);

bool   ValidateEngineBContext(int direction,
                              double sweepLow,
                              double sweepHigh,
                              double sweepExtreme,
                              PriceZone &ob,
                              PriceZone &ifvg,
                              double &rangeLow,
                              double &equilibrium,
                              double &rangeHigh,
                              string &zoneUsed,
                              double &zoneLow,
                              double &zoneHigh,
                              int &zoneTouchShift,
                              datetime &zoneTouchTime,
                              string &rejectReason);

double CalculateInitialStopLossTF(int executionTF,
                                  double slBufferATR,
                                  int direction,
                                  double sweepExtreme);

double CalculateLotSizeForRisk(double riskPercent,
                               int command,
                               double entryPrice,
                               double stopLoss,
                               double &estimatedRiskMoney);

int    SendECNFallbackForEngine(int command,
                               double lots,
                               double structuralSL,
                               string tradeComment,
                               int magicNumber,
                               double &fillPriceOut,
                               double &finalSLOut,
                               double &finalTPOut);

bool   ExecuteMarketTradeForEngine(int direction,
                                   double structuralSL,
                                   string tradeComment,
                                   int magicNumber,
                                   double riskPercent,
                                   int maxOpenTradesForEngine,
                                   int &ticketOut,
                                   double &entryOut,
                                   double &slOut,
                                   double &tpOut,
                                   double &lotsOut,
                                   double &riskMoneyOut);

void   InitCSVB();
void   CSVWriteOpenB(int ticket,
                     int direction,
                     int h4Bias,
                     int h1Structure,
                     bool hasOB,
                     bool hasIFVG,
                     string zoneUsed,
                     double zoneLow,
                     double zoneHigh,
                     double rangeLow,
                     double equilibrium,
                     double rangeHigh,
                     double referenceLiquidity,
                     double sweepExtreme,
                     double confirmClose,
                     double entry,
                     double sl,
                     double tp,
                     double lots,
                     double riskMoney,
                     string triggerReason,
                     string commentText);

void   CSVWriteRejectedB(int direction,
                         int h4Bias,
                         int h1Structure,
                         bool hasOB,
                         bool hasIFVG,
                         double referenceLiquidity,
                         double sweepExtreme,
                         double confirmClose,
                         string reason);


//====================================================================
// MULTI-MARKET CSV FILE NAMING
//====================================================================
string SafeFileToken(string text)
{
   string s = text;

   StringReplace(s, ".", "_");
   StringReplace(s, "/", "_");
   StringReplace(s, "\\", "_");
   StringReplace(s, ":", "_");
   StringReplace(s, ";", "_");
   StringReplace(s, " ", "_");

   if(StringLen(s) <= 0)
      s = "NA";

   return(s);
}

//+------------------------------------------------------------------+
string ResolveCSVFileNameA()
{
   if(!AutoCSVNameBySymbol)
      return(CSVFileName);

   return(
      "MTF_V10_" +
      SafeFileToken(Symbol()) +
      "_" +
      SafeFileToken(ResearchRunTag) +
      "_EngineA.csv"
   );
}

//+------------------------------------------------------------------+
string ResolveCSVFileNameB()
{
   if(!AutoCSVNameBySymbol)
      return(EngineBCSVFileName);

   return(
      "MTF_V10_" +
      SafeFileToken(Symbol()) +
      "_" +
      SafeFileToken(ResearchRunTag) +
      "_EngineB.csv"
   );
}

//====================================================================
// INIT
//====================================================================
int OnInit()
{
   if(RiskPercent <= 0.0 && !UseFixedLot)
   {
      Print("ERROR: RiskPercent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(UseFixedLot && FixedLotSize <= 0.0)
   {
      Print("ERROR: FixedLotSize must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MaxSpread <= 0.0)
   {
      Print("ERROR: MaxSpread must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MaxOpenTrades < 1)
   {
      Print("ERROR: MaxOpenTrades must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ATR_Period < 2)
   {
      Print("ERROR: ATR_Period must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MinRVRatio < 2.0)
   {
      Print("ERROR: MinRVRatio must be >= 2.0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(M1LiquidityLookback < 2)
   {
      Print("ERROR: M1LiquidityLookback must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MaxLotCap <= 0.0)
   {
      Print("ERROR: MaxLotCap must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(StructureStartHour < 0 || StructureStartHour > 23 ||
      EntryStartHour < 0 || EntryStartHour > 23 ||
      EntryEndHour < 0 || EntryEndHour > 23)
   {
      Print("ERROR: StructureStartHour/EntryStartHour/EntryEndHour must be 0..23.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(!AllowLongTrades && !AllowShortTrades)
   {
      Print("ERROR: both trade directions are disabled.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MinSessionM15BarsForRange < 1)
   {
      Print("ERROR: MinSessionM15BarsForRange must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(RecentZoneTouchLookbackM1 < 2)
   {
      Print("ERROR: RecentZoneTouchLookbackM1 must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(M1MinSweepPenetrationATR < 0.0)
   {
      Print("ERROR: M1MinSweepPenetrationATR must be >= 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(EngineBRiskPercent <= 0.0 && EnableEngineB && !UseFixedLot)
   {
      Print("ERROR: EngineBRiskPercent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MaxOpenTradesTotal < 1)
   {
      Print("ERROR: MaxOpenTradesTotal must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(MaxCombinedOpenRiskPercent <= 0.0)
   {
      Print("ERROR: MaxCombinedOpenRiskPercent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(EngineBEntryStartHour < 0 || EngineBEntryStartHour > 23 ||
      EngineBEntryEndHour < 0 || EngineBEntryEndHour > 23)
   {
      Print("ERROR: Engine B entry hours must be 0..23.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(B_M5LiquidityLookback < 2 ||
      EngineBRecentZoneTouchM5 < 2)
   {
      Print("ERROR: Engine B M5 lookbacks must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(B_M5MinSweepPenetrationATR < 0.0)
   {
      Print("ERROR: B_M5MinSweepPenetrationATR must be >= 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_lastM1BarTime = iTime(Symbol(), PERIOD_M1, 0);
   g_lastM5BarTime = iTime(Symbol(), PERIOD_M5, 0);
   g_lastHistoryTotal = OrdersHistoryTotal();

   if(EnableCSVLog)
   {
      InitCSV();
      if(EnableEngineB)
         InitCSVB();
   }

   Print("======================================================");
   Print("MultiTF_PriceAction_EA V10 MULTI-MARKET RESEARCH INITIALIZED");
   Print("Symbol             = ", Symbol());
   Print("ResearchRunTag     = ", ResearchRunTag);
   Print("24H A session      = ", BoolText(!UseSessionFilter));
   Print("24H B entry        = ", BoolText(!EngineBUseEntryWindow));
   Print("Testing            = ", IsTesting());
   Print("Digits             = ", Digits);
   Print("Point              = ", DoubleToString(Point, Digits));
   Print("TickSize(points)   = ",
         DoubleToString(MarketInfo(Symbol(), MODE_TICKSIZE), 8));
   Print("TickSize(price)    = ",
         DoubleToString(TickSizePrice(), 8));
   Print("TickValue          = ",
         DoubleToString(MarketInfo(Symbol(), MODE_TICKVALUE), 8));
   Print("MinLot             = ",
         DoubleToString(MarketInfo(Symbol(), MODE_MINLOT), 3));
   Print("LotStep            = ",
         DoubleToString(MarketInfo(Symbol(), MODE_LOTSTEP), 3));
   Print("MaxLot             = ",
         DoubleToString(MarketInfo(Symbol(), MODE_MAXLOT), 3));
   Print("StopLevel(points)  = ",
         DoubleToString(MarketInfo(Symbol(), MODE_STOPLEVEL), 0));
   Print("RiskPercent        = ", DoubleToString(RiskPercent, 2));
   Print("Live MaxSpread     = ", DoubleToString(MaxSpread, 2));
   Print("TesterSpreadBypass = ", BoolText(IgnoreSpreadFilterInTester));
   Print("RR                  = 1:", DoubleToString(MinRVRatio, 2));
   Print("AllowLongTrades     = ", BoolText(AllowLongTrades));
   Print("AllowShortTrades    = ", BoolText(AllowShortTrades));
   Print("ZoneFilter          = ", ZoneFilterToString());
   Print("RequireM15ZoneTouch = ", BoolText(RequireM15ZoneTouch));
   Print("UseSessionFilter    = ", BoolText(UseSessionFilter));
   Print("StructureStart      = ", StructureStartHour, ":00 server time");
   Print("EntryWindow         = ", EntryStartHour, ":00 .. ", EntryEndHour, ":00 (end exclusive)");
   Print("SessionFormedSetup  = ", BoolText(RequireSessionFormedSetups));
   Print("MinSessionM15Bars   = ", MinSessionM15BarsForRange);
   Print("ZoneTouchLookbackM1 = ", RecentZoneTouchLookbackM1);
   Print("M1LiquidityLookback = ", M1LiquidityLookback);
   Print("M1ConfirmBodyATR    = ", DoubleToString(M1MinConfirmBodyATR, 2));
   Print("M1SweepPenATR       = ", DoubleToString(M1MinSweepPenetrationATR, 2));
   Print("EngineA enabled     = ", BoolText(EnableEngineA));
   Print("EngineB enabled     = ", BoolText(EnableEngineB));
   Print("EngineB map         = H4 -> H1 -> M5");
   Print("EngineB risk %      = ", DoubleToString(EngineBRiskPercent, 2));
   Print("Combined risk cap % = ", DoubleToString(MaxCombinedOpenRiskPercent, 2));
   Print("EngineB EntryWindow = ", EngineBEntryStartHour, ":00 .. ", EngineBEntryEndHour, ":00");
   Print("B Require IFVG      = ", BoolText(EngineBRequireActiveIFVG));
   Print("B Reject active OB  = ", BoolText(EngineBRejectActiveOB));
   Print("CSV A               = ", ResolveCSVFileNameA());
   Print("CSV B               = ", ResolveCSVFileNameB());
   Print("======================================================");

   return(INIT_SUCCEEDED);
}

//====================================================================
// DEINIT
//====================================================================
void OnDeinit(const int reason)
{
   if(EnableCSVLog)
      LogClosedTrades();

   Print("MultiTF_PriceAction_EA V9.3.1 CORE COMBO deinitialized. Reason=", reason);
}

//====================================================================
// MAIN LOOP
//====================================================================
void OnTick()
{
   // Capture closed trades for both engine magic numbers.
   if(EnableCSVLog)
      LogClosedTrades();

   bool newM1 = IsNewM1Bar();
   bool newM5 = IsNewM5Bar();

   if(!newM1 && !newM5)
      return;

   if(!IsTradeEnvironmentOK())
      return;

   if(!IsSpreadAcceptable())
   {
      DebugPrint(
         "NO TRADE | spread=" +
         DoubleToString(GetSpreadPips(), 2) +
         " > max=" +
         DoubleToString(MaxSpread, 2)
      );
      return;
   }

   if(IsTesting() &&
      IgnoreSpreadFilterInTester &&
      GetSpreadPips() > MaxSpread)
   {
      DebugPrint(
         "TESTER SPREAD OVERRIDE | actual spread=" +
         DoubleToString(GetSpreadPips(), 2) +
         " | live max=" +
         DoubleToString(MaxSpread, 2)
      );
   }

   // Preserve Engine A priority when both engines signal on the same tick.
   if(EnableEngineA && newM1)
      ProcessEngineA();

   if(EnableEngineB && newM5)
      ProcessEngineB();
}

//====================================================================
// ENGINE A - FROZEN V9: H1 -> M15 -> M1
//====================================================================
void ProcessEngineA()
{
   if(!EnoughHistory())
   {
      DebugPrint("A WAIT | insufficient H1/M15/M1 history.");
      return;
   }

   int h1Bias = GetH1Bias();

   if(h1Bias == DIR_NONE)
      return;

   if(!IsDirectionEnabled(h1Bias))
      return;

   if(!IsEntryWindowAllowed())
      return;

   int m15Structure = GetM15Structure();

   if(m15Structure != h1Bias)
      return;

   PriceZone ob;
   PriceZone ifvg;

   bool hasOB   = FindFreshM15OrderBlock(h1Bias, ob);
   bool hasIFVG = FindFreshM15IFVG(h1Bias, ifvg);

   if(!hasOB && !hasIFVG)
      return;

   double referenceLiquidity = 0.0;
   double sweepExtreme       = 0.0;
   double confirmClose       = 0.0;
   double sweepLow           = 0.0;
   double sweepHigh          = 0.0;
   string triggerReason      = "";

   if(!GetM1ExecutionTrigger(
         h1Bias,
         referenceLiquidity,
         sweepExtreme,
         confirmClose,
         sweepLow,
         sweepHigh,
         triggerReason))
      return;

   double rangeLow      = 0.0;
   double equilibrium   = 0.0;
   double rangeHigh     = 0.0;
   string zoneUsed      = "";
   double zoneLow       = 0.0;
   double zoneHigh      = 0.0;
   int zoneTouchShift   = -1;
   datetime zoneTouchTime = 0;
   string rejectReason  = "";

   if(!ValidateM15ContextAfterTrigger(
         h1Bias,
         sweepLow,
         sweepHigh,
         sweepExtreme,
         ob,
         ifvg,
         rangeLow,
         equilibrium,
         rangeHigh,
         zoneUsed,
         zoneLow,
         zoneHigh,
         zoneTouchShift,
         zoneTouchTime,
         rejectReason))
   {
      CSVWriteRejected(
         h1Bias,
         h1Bias,
         m15Structure,
         hasOB,
         hasIFVG,
         referenceLiquidity,
         sweepExtreme,
         confirmClose,
         rejectReason
      );
      return;
   }

   if(!CanOpenEngineRisk(MagicNumber, RiskPercent))
   {
      DebugPrint("A SKIP | combined/open risk cap.");
      return;
   }

   double structuralSL =
      CalculateInitialStopLoss(
         h1Bias,
         sweepExtreme
      );

   if(structuralSL <= 0.0)
      return;

   string directionText =
      (h1Bias == DIR_BULL ? "BUY" : "SELL");

   string tradeComment =
      "V9A_" +
      directionText +
      "_" +
      zoneUsed;

   int    ticket     = -1;
   double entry      = 0.0;
   double finalSL    = 0.0;
   double finalTP    = 0.0;
   double lots       = 0.0;
   double riskMoney  = 0.0;

   bool executed =
      ExecuteMarketTrade(
         h1Bias,
         structuralSL,
         tradeComment,
         ticket,
         entry,
         finalSL,
         finalTP,
         lots,
         riskMoney
      );

   if(!executed)
      return;

   Print("ENGINE A TRADE | ", directionText,
         " | ticket=", ticket,
         " | zone=", zoneUsed,
         " | risk=", DoubleToString(riskMoney, 2));

   CSVWriteOpen(
      ticket,
      h1Bias,
      h1Bias,
      m15Structure,
      hasOB,
      hasIFVG,
      zoneUsed,
      zoneLow,
      zoneHigh,
      rangeLow,
      equilibrium,
      rangeHigh,
      referenceLiquidity,
      sweepExtreme,
      confirmClose,
      entry,
      finalSL,
      finalTP,
      lots,
      riskMoney,
      triggerReason,
      "Engine=A; H1>M15>M1"
   );
}

//====================================================================
// ENGINE B - HIGHER TF SCALE: H4 -> H1 -> M5
//====================================================================
void ProcessEngineB()
{
   if(!EnoughHistoryB())
   {
      DebugPrint("B WAIT | insufficient H4/H1/M5 history.");
      return;
   }

   if(!IsEngineBEntryWindowAllowed())
      return;

   int h4Bias =
      GetStructureDirection(
         PERIOD_H4,
         B_H4StructureLookback,
         B_H4SwingSpan,
         B_H4MinBreakBodyATR
      );

   if(h4Bias == DIR_NONE)
      return;

   if(!IsDirectionEnabled(h4Bias))
      return;

   int h1Structure =
      GetStructureDirection(
         PERIOD_H1,
         B_H1StructureLookback,
         B_H1SwingSpan,
         B_H1MinDisplacementATR * 0.50
      );

   if(h1Structure != h4Bias)
      return;

   PriceZone ob;
   PriceZone ifvg;

   bool hasOB =
      FindFreshOrderBlockTF(
         PERIOD_H1,
         h4Bias,
         B_H1ZoneLookback,
         B_H1OBBreakLookback,
         B_H1MinDisplacementATR,
         B_MaxPriorZoneTouches,
         ob
      );

   bool hasIFVG =
      FindFreshIFVGTF(
         PERIOD_H1,
         h4Bias,
         B_H1ZoneLookback,
         B_H1MinFVGSizeATR,
         B_MaxPriorZoneTouches,
         ifvg
      );

   // Base safety: some active H1 POI must exist.
   if(!hasOB && !hasIFVG)
      return;

   // V9.1 research context gate.
   // This is explicit/configurable so it can be validated out-of-sample.
   if(EngineBRequireActiveIFVG && !hasIFVG)
   {
      DebugPrint("B SKIP | active H1 IFVG required.");
      return;
   }

   if(EngineBRejectActiveOB && hasOB)
   {
      DebugPrint("B SKIP | active H1 OB present.");
      return;
   }

   double referenceLiquidity = 0.0;
   double sweepExtreme       = 0.0;
   double confirmClose       = 0.0;
   double sweepLow           = 0.0;
   double sweepHigh          = 0.0;
   string triggerReason      = "";

   if(!GetExecutionTriggerTF(
         PERIOD_M5,
         h4Bias,
         B_M5LiquidityLookback,
         B_M5MinConfirmBodyATR,
         B_M5MinSweepPenetrationATR,
         EngineBUseEntryWindow,
         EngineBEntryStartHour,
         EngineBEntryEndHour,
         referenceLiquidity,
         sweepExtreme,
         confirmClose,
         sweepLow,
         sweepHigh,
         triggerReason))
      return;

   double rangeLow        = 0.0;
   double equilibrium     = 0.0;
   double rangeHigh       = 0.0;
   string zoneUsed        = "";
   double zoneLow         = 0.0;
   double zoneHigh        = 0.0;
   int zoneTouchShift     = -1;
   datetime zoneTouchTime = 0;
   string rejectReason    = "";

   if(!ValidateEngineBContext(
         h4Bias,
         sweepLow,
         sweepHigh,
         sweepExtreme,
         ob,
         ifvg,
         rangeLow,
         equilibrium,
         rangeHigh,
         zoneUsed,
         zoneLow,
         zoneHigh,
         zoneTouchShift,
         zoneTouchTime,
         rejectReason))
   {
      CSVWriteRejectedB(
         h4Bias,
         h4Bias,
         h1Structure,
         hasOB,
         hasIFVG,
         referenceLiquidity,
         sweepExtreme,
         confirmClose,
         rejectReason
      );
      return;
   }

   if(!CanOpenEngineRisk(EngineBMagicNumber, EngineBRiskPercent))
   {
      DebugPrint("B SKIP | combined/open risk cap.");
      return;
   }

   double structuralSL =
      CalculateInitialStopLossTF(
         PERIOD_M5,
         B_M5SLBufferATR,
         h4Bias,
         sweepExtreme
      );

   if(structuralSL <= 0.0)
      return;

   string directionText =
      (h4Bias == DIR_BULL ? "BUY" : "SELL");

   string tradeComment =
      "V9_1B_" +
      directionText +
      "_" +
      zoneUsed;

   int    ticket     = -1;
   double entry      = 0.0;
   double finalSL    = 0.0;
   double finalTP    = 0.0;
   double lots       = 0.0;
   double riskMoney  = 0.0;

   bool executed =
      ExecuteMarketTradeForEngine(
         h4Bias,
         structuralSL,
         tradeComment,
         EngineBMagicNumber,
         EngineBRiskPercent,
         MaxOpenTrades,
         ticket,
         entry,
         finalSL,
         finalTP,
         lots,
         riskMoney
      );

   if(!executed)
      return;

   Print("ENGINE B TRADE | ", directionText,
         " | ticket=", ticket,
         " | zone=", zoneUsed,
         " | risk=", DoubleToString(riskMoney, 2));

   CSVWriteOpenB(
      ticket,
      h4Bias,
      h4Bias,
      h1Structure,
      hasOB,
      hasIFVG,
      zoneUsed,
      zoneLow,
      zoneHigh,
      rangeLow,
      equilibrium,
      rangeHigh,
      referenceLiquidity,
      sweepExtreme,
      confirmClose,
      entry,
      finalSL,
      finalTP,
      lots,
      riskMoney,
      triggerReason,
      "Engine=B2; H4>H1>M5; IFVG_NO_OB"
   );
}

//====================================================================
// DEBUG UTILITIES
//====================================================================
void DebugPrint(string msg)
{
   if(DebugMode)
      Print(msg);
}

//+------------------------------------------------------------------+
string DirectionToString(int direction)
{
   if(direction == DIR_BULL)
      return("BULLISH");

   if(direction == DIR_BEAR)
      return("BEARISH");

   return("NONE");
}

//+------------------------------------------------------------------+
string BoolText(bool value)
{
   if(value)
      return("YES");

   return("NO");
}

//+------------------------------------------------------------------+
string ZoneFilterToString()
{
   if(ZoneFilterMode == ZONE_ANY)
      return("ANY");

   if(ZoneFilterMode == ZONE_REQUIRE_IFVG)
      return("REQUIRE_IFVG");

   if(ZoneFilterMode == ZONE_REQUIRE_CONFLUENCE)
      return("REQUIRE_CONFLUENCE");

   if(ZoneFilterMode == ZONE_OB_ONLY)
      return("OB_ONLY");

   if(ZoneFilterMode == ZONE_IFVG_ONLY)
      return("IFVG_ONLY");

   return("UNKNOWN");
}

//+------------------------------------------------------------------+
bool IsDirectionEnabled(int direction)
{
   if(direction == DIR_BULL)
      return(AllowLongTrades);

   if(direction == DIR_BEAR)
      return(AllowShortTrades);

   return(false);
}

//+------------------------------------------------------------------+
bool IsEntryWindowAllowed()
{
   if(!UseSessionFilter)
      return(true);

   // Gate the ACTUAL order time, not only the previous closed M1 bar.
   datetime orderTime = TimeCurrent();

   if(orderTime <= 0)
      return(false);

   int hour = TimeHour(orderTime);

   if(EntryStartHour == EntryEndHour)
      return(true);

   if(EntryStartHour < EntryEndHour)
      return(hour >= EntryStartHour && hour < EntryEndHour);

   return(hour >= EntryStartHour || hour < EntryEndHour);
}

//+------------------------------------------------------------------+
//| Returns the broker-server timestamp corresponding to the trusted |
//| structure-session start for referenceTime.                       |
//+------------------------------------------------------------------+
datetime GetSessionStartFor(datetime referenceTime)
{
   if(referenceTime <= 0)
      return(0);

   MqlDateTime dt;
   TimeToStruct(referenceTime, dt);

   dt.hour = StructureStartHour;
   dt.min  = 0;
   dt.sec  = 0;

   return(StructToTime(dt));
}

//+------------------------------------------------------------------+
bool IsBarAfterSessionStart(int timeframe, int shift)
{
   if(!UseSessionFilter ||
      !RequireSessionFormedSetups)
   {
      return(true);
   }

   datetime barTime =
      iTime(
         Symbol(),
         timeframe,
         shift
      );

   datetime referenceTime =
      iTime(
         Symbol(),
         PERIOD_M1,
         1
      );

   if(barTime <= 0 ||
      referenceTime <= 0)
   {
      return(false);
   }

   datetime sessionStart =
      GetSessionStartFor(referenceTime);

   return(barTime >= sessionStart);
}

//+------------------------------------------------------------------+
//| Structure search that ignores pre-StructureStartHour M15 bars.   |
//| H1 bias intentionally remains broader context.                   |
//+------------------------------------------------------------------+
int GetSessionAwareStructureDirection(
   int timeframe,
   int lookback,
   int swingSpan,
   double minBodyATR
)
{
   int bars =
      iBars(Symbol(), timeframe);

   if(bars < lookback + swingSpan + ATR_Period + 10)
      return(DIR_NONE);

   datetime referenceTime =
      iTime(
         Symbol(),
         PERIOD_M1,
         1
      );

   if(referenceTime <= 0)
      return(DIR_NONE);

   datetime sessionStart =
      GetSessionStartFor(referenceTime);

   for(int shift = 1;
       shift <= lookback;
       shift++)
   {
      datetime breakBarTime =
         iTime(
            Symbol(),
            timeframe,
            shift
         );

      if(breakBarTime < sessionStart)
         break;

      datetime oldestReferenceTime =
         iTime(
            Symbol(),
            timeframe,
            shift + swingSpan
         );

      if(oldestReferenceTime < sessionStart)
         continue;

      double referenceHigh = -1.0;
      double referenceLow  = 1.0e100;

      for(int j = 1;
          j <= swingSpan;
          j++)
      {
         double h =
            iHigh(
               Symbol(),
               timeframe,
               shift + j
            );

         double l =
            iLow(
               Symbol(),
               timeframe,
               shift + j
            );

         if(referenceHigh < 0.0 ||
            h > referenceHigh)
         {
            referenceHigh = h;
         }

         if(l < referenceLow)
            referenceLow = l;
      }

      double openPrice =
         iOpen(
            Symbol(),
            timeframe,
            shift
         );

      double closePrice =
         iClose(
            Symbol(),
            timeframe,
            shift
         );

      double body =
         MathAbs(closePrice - openPrice);

      double atr =
         iATR(
            Symbol(),
            timeframe,
            ATR_Period,
            shift
         );

      if(atr <= 0.0)
         continue;

      if(body < atr * minBodyATR)
         continue;

      if(closePrice > referenceHigh)
         return(DIR_BULL);

      if(closePrice < referenceLow)
         return(DIR_BEAR);
   }

   return(DIR_NONE);
}

//====================================================================
// NEW BAR
//====================================================================
bool IsNewM1Bar()
{
   datetime currentBarTime =
      iTime(Symbol(), PERIOD_M1, 0);

   if(currentBarTime <= 0)
      return(false);

   if(currentBarTime != g_lastM1BarTime)
   {
      g_lastM1BarTime = currentBarTime;
      return(true);
   }

   return(false);
}

//====================================================================
// HISTORY CHECK
//====================================================================
bool EnoughHistory()
{
   if(iBars(Symbol(), PERIOD_H1) <
      H1StructureLookback + H1SwingSpan + ATR_Period + 30)
      return(false);

   if(iBars(Symbol(), PERIOD_M15) <
      M15ZoneLookback + M15DealingRangeBars + ATR_Period + 50)
      return(false);

   if(iBars(Symbol(), PERIOD_M1) <
      M1LiquidityLookback + ATR_Period + 50)
      return(false);

   return(true);
}


//====================================================================
// NEW M5 BAR / ENGINE B HISTORY
//====================================================================
bool IsNewM5Bar()
{
   datetime currentBarTime =
      iTime(Symbol(), PERIOD_M5, 0);

   if(currentBarTime <= 0)
      return(false);

   if(currentBarTime != g_lastM5BarTime)
   {
      g_lastM5BarTime = currentBarTime;
      return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
bool EnoughHistoryB()
{
   if(iBars(Symbol(), PERIOD_H4) <
      B_H4StructureLookback + B_H4SwingSpan + ATR_Period + 30)
      return(false);

   if(iBars(Symbol(), PERIOD_H1) <
      B_H1ZoneLookback + B_H1DealingRangeBars + ATR_Period + 50)
      return(false);

   if(iBars(Symbol(), PERIOD_M5) <
      B_M5LiquidityLookback + ATR_Period + 50)
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
bool IsHourInsideWindow(
   datetime t,
   int startHour,
   int endHour
)
{
   if(t <= 0)
      return(false);

   int hour = TimeHour(t);

   if(startHour == endHour)
      return(true);

   if(startHour < endHour)
      return(hour >= startHour && hour < endHour);

   return(hour >= startHour || hour < endHour);
}

//+------------------------------------------------------------------+
bool IsBarInsideWindow(
   int timeframe,
   int shift,
   int startHour,
   int endHour
)
{
   return(
      IsHourInsideWindow(
         iTime(Symbol(), timeframe, shift),
         startHour,
         endHour
      )
   );
}

//+------------------------------------------------------------------+
bool IsEngineBEntryWindowAllowed()
{
   if(!EngineBUseEntryWindow)
      return(true);

   // Exact broker-server order-time gate.
   // Closed M5 trigger bars are still validated separately.
   return(
      IsHourInsideWindow(
         TimeCurrent(),
         EngineBEntryStartHour,
         EngineBEntryEndHour
      )
   );
}

//====================================================================
// TRADE ENVIRONMENT
//====================================================================
bool IsTradeEnvironmentOK()
{
   // Strategy Tester may report MODE_TRADEALLOWED=0 for CFDs/indices.
   // The tester itself controls simulated execution, so live broker
   // permission checks are intentionally skipped during testing.
   if(IsTesting())
      return(true);

   if(!IsConnected())
   {
      Print("Trade skipped: terminal is not connected.");
      return(false);
   }

   if(!IsTradeAllowed())
   {
      Print("Trade skipped: EA/AutoTrading is not allowed.");
      return(false);
   }

   if(MarketInfo(Symbol(), MODE_TRADEALLOWED) == 0)
   {
      Print("Trade skipped: broker does not currently allow trading on ",
            Symbol());
      return(false);
   }

   if(IsTradeContextBusy())
   {
      Print("Trade skipped: trade context is busy.");
      return(false);
   }

   return(true);
}

//====================================================================
// PRICE UTILITIES
//====================================================================
double PipSize()
{
   if(Digits == 3 || Digits == 5)
      return(Point * 10.0);

   return(Point);
}

//+------------------------------------------------------------------+
//| Returns the minimum PRICE change, not a count of points.         |
//| SYMBOL_TRADE_TICK_SIZE is already expressed as a price size.     |
//| Fallback converts legacy MODE_TICKSIZE points into price units.  |
//+------------------------------------------------------------------+
double TickSizePrice()
{
   double tickSizePrice =
      SymbolInfoDouble(
         Symbol(),
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSizePrice > 0.0)
      return(tickSizePrice);

   double tickSizePoints =
      MarketInfo(
         Symbol(),
         MODE_TICKSIZE
      );

   if(tickSizePoints <= 0.0 ||
      Point <= 0.0)
   {
      return(0.0);
   }

   return(tickSizePoints * Point);
}

//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   return(NormalizeDouble(price, Digits));
}

//+------------------------------------------------------------------+
double GetSpreadPips()
{
   RefreshRates();

   double pip = PipSize();

   if(pip <= 0.0)
      return(999999.0);

   return((Ask - Bid) / pip);
}

//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   // During Strategy Tester stress tests, let MT4's configured spread
   // flow through the execution model instead of blocking the setup.
   // The actual Bid/Ask spread still affects entries, stops, exits and P/L.
   if(IsTesting() && IgnoreSpreadFilterInTester)
      return(true);

   return(GetSpreadPips() <= MaxSpread);
}

//+------------------------------------------------------------------+
int SlippagePoints()
{
   if(Point <= 0.0)
      return(0);

   double pointsPerPip =
      PipSize() / Point;

   int result =
      (int)MathRound(
         Slippage * pointsPerPip
      );

   if(result < 0)
      result = 0;

   return(result);
}

//====================================================================
// GENERIC STRUCTURE ENGINE
//====================================================================
int GetStructureDirection(
   int timeframe,
   int lookback,
   int swingSpan,
   double minBodyATR
)
{
   int bars = iBars(Symbol(), timeframe);

   if(bars < lookback + swingSpan + ATR_Period + 10)
      return(DIR_NONE);

   for(int shift = 1;
       shift <= lookback;
       shift++)
   {
      double referenceHigh = -1.0;
      double referenceLow  = 1.0e100;

      for(int j = 1;
          j <= swingSpan;
          j++)
      {
         double h =
            iHigh(
               Symbol(),
               timeframe,
               shift + j
            );

         double l =
            iLow(
               Symbol(),
               timeframe,
               shift + j
            );

         if(referenceHigh < 0.0 ||
            h > referenceHigh)
         {
            referenceHigh = h;
         }

         if(l < referenceLow)
            referenceLow = l;
      }

      double openPrice =
         iOpen(
            Symbol(),
            timeframe,
            shift
         );

      double closePrice =
         iClose(
            Symbol(),
            timeframe,
            shift
         );

      double body =
         MathAbs(closePrice - openPrice);

      double atr =
         iATR(
            Symbol(),
            timeframe,
            ATR_Period,
            shift
         );

      if(atr <= 0.0)
         continue;

      if(body < atr * minBodyATR)
         continue;

      if(closePrice > referenceHigh)
         return(DIR_BULL);

      if(closePrice < referenceLow)
         return(DIR_BEAR);
   }

   return(DIR_NONE);
}

//====================================================================
// H1 / M15 DIRECTION
//====================================================================
int GetH1Bias()
{
   return(
      GetStructureDirection(
         PERIOD_H1,
         H1StructureLookback,
         H1SwingSpan,
         H1MinBreakBodyATR
      )
   );
}

//+------------------------------------------------------------------+
int GetM15Structure()
{
   if(UseSessionFilter &&
      RequireSessionFormedSetups)
   {
      return(
         GetSessionAwareStructureDirection(
            PERIOD_M15,
            M15StructureLookback,
            M15SwingSpan,
            M15MinDisplacementATR * 0.50
         )
      );
   }

   return(
      GetStructureDirection(
         PERIOD_M15,
         M15StructureLookback,
         M15SwingSpan,
         M15MinDisplacementATR * 0.50
      )
   );
}

//====================================================================
// M15 DEALING RANGE
//====================================================================
bool GetM15DealingRange(
   double &rangeLow,
   double &rangeHigh,
   double &equilibrium
)
{
   rangeLow    = 0.0;
   rangeHigh   = 0.0;
   equilibrium = 0.0;

   //===============================================================
   // SESSION-AWARE RANGE
   //===============================================================
   if(UseSessionFilter &&
      RequireSessionFormedSetups)
   {
      datetime referenceTime =
         iTime(
            Symbol(),
            PERIOD_M1,
            1
         );

      if(referenceTime <= 0)
         return(false);

      datetime sessionStart =
         GetSessionStartFor(referenceTime);

      int countedBars = 0;
      double hi = -1.0;
      double lo = 1.0e100;

      // Only CLOSED M15 bars from the current server-time session.
      for(int shift = 1;
          shift <= M15DealingRangeBars;
          shift++)
      {
         datetime barTime =
            iTime(
               Symbol(),
               PERIOD_M15,
               shift
            );

         if(barTime <= 0)
            break;

         if(barTime < sessionStart)
            break;

         double h =
            iHigh(
               Symbol(),
               PERIOD_M15,
               shift
            );

         double l =
            iLow(
               Symbol(),
               PERIOD_M15,
               shift
            );

         if(hi < 0.0 || h > hi)
            hi = h;

         if(l < lo)
            lo = l;

         countedBars++;
      }

      if(countedBars < MinSessionM15BarsForRange)
         return(false);

      if(hi <= lo)
         return(false);

      rangeHigh   = hi;
      rangeLow    = lo;
      equilibrium = (hi + lo) / 2.0;

      return(true);
   }

   //===============================================================
   // FULL LOOKBACK RANGE WHEN SESSION MODE IS DISABLED
   //===============================================================
   int highShift =
      iHighest(
         Symbol(),
         PERIOD_M15,
         MODE_HIGH,
         M15DealingRangeBars,
         1
      );

   int lowShift =
      iLowest(
         Symbol(),
         PERIOD_M15,
         MODE_LOW,
         M15DealingRangeBars,
         1
      );

   if(highShift < 0 || lowShift < 0)
      return(false);

   rangeHigh =
      iHigh(
         Symbol(),
         PERIOD_M15,
         highShift
      );

   rangeLow =
      iLow(
         Symbol(),
         PERIOD_M15,
         lowShift
      );

   if(rangeHigh <= rangeLow)
      return(false);

   equilibrium =
      (rangeHigh + rangeLow) / 2.0;

   return(true);
}

//====================================================================
// ZONE FRESHNESS
//====================================================================
bool IsOrderBlockStillActive(
   int direction,
   double zoneLow,
   double zoneHigh,
   int displacementShift
)
{
   // Examine all CLOSED M15 candles after displacement.
   for(int shift = displacementShift - 1;
       shift >= 1;
       shift--)
   {
      double closePrice =
         iClose(
            Symbol(),
            PERIOD_M15,
            shift
         );

      if(direction == DIR_BULL &&
         closePrice < zoneLow)
      {
         return(false);
      }

      if(direction == DIR_BEAR &&
         closePrice > zoneHigh)
      {
         return(false);
      }
   }

   return(true);
}

//+------------------------------------------------------------------+
int CountPriorZoneTouches(
   double zoneLow,
   double zoneHigh,
   int newestShift,
   int oldestShift
)
{
   if(oldestShift < newestShift)
      return(0);

   int touches = 0;

   for(int shift = newestShift;
       shift <= oldestShift;
       shift++)
   {
      if(shift < 1)
         continue;

      double h =
         iHigh(
            Symbol(),
            PERIOD_M15,
            shift
         );

      double l =
         iLow(
            Symbol(),
            PERIOD_M15,
            shift
         );

      if(h >= zoneLow &&
         l <= zoneHigh)
      {
         touches++;
      }
   }

   return(touches);
}

//====================================================================
// FRESH M15 ORDER BLOCK
//====================================================================
bool FindFreshM15OrderBlock(
   int direction,
   PriceZone &zone
)
{
   zone.found = false;
   zone.low   = 0.0;
   zone.high  = 0.0;
   zone.shift = -1;
   zone.time  = 0;
   zone.type  = "";

   for(int obShift = 3;
       obShift <= M15ZoneLookback;
       obShift++)
   {
      int displacementShift =
         obShift - 1;

      if(UseSessionFilter &&
         RequireSessionFormedSetups)
      {
         if(!IsBarAfterSessionStart(PERIOD_M15, obShift) ||
            !IsBarAfterSessionStart(PERIOD_M15, displacementShift))
         {
            continue;
         }
      }

      double obOpen =
         iOpen(
            Symbol(),
            PERIOD_M15,
            obShift
         );

      double obClose =
         iClose(
            Symbol(),
            PERIOD_M15,
            obShift
         );

      double obHigh =
         iHigh(
            Symbol(),
            PERIOD_M15,
            obShift
         );

      double obLow =
         iLow(
            Symbol(),
            PERIOD_M15,
            obShift
         );

      double dOpen =
         iOpen(
            Symbol(),
            PERIOD_M15,
            displacementShift
         );

      double dClose =
         iClose(
            Symbol(),
            PERIOD_M15,
            displacementShift
         );

      double atr =
         iATR(
            Symbol(),
            PERIOD_M15,
            ATR_Period,
            displacementShift
         );

      if(atr <= 0.0)
         continue;

      double body =
         MathAbs(dClose - dOpen);

      if(body < atr * M15MinDisplacementATR)
         continue;

      //-------------------------------------------------------------
      // Reference structure BEFORE the candidate OB
      //-------------------------------------------------------------
      double referenceHigh = -1.0;
      double referenceLow  = 1.0e100;

      for(int k = 1;
          k <= M15OBBreakLookback;
          k++)
      {
         int s = obShift + k;

         double h =
            iHigh(
               Symbol(),
               PERIOD_M15,
               s
            );

         double l =
            iLow(
               Symbol(),
               PERIOD_M15,
               s
            );

         if(referenceHigh < 0.0 ||
            h > referenceHigh)
            referenceHigh = h;

         if(l < referenceLow)
            referenceLow = l;
      }

      //-------------------------------------------------------------
      // BULLISH OB
      //-------------------------------------------------------------
      if(direction == DIR_BULL)
      {
         bool bearishOB =
            (obClose < obOpen);

         bool bullDisplacement =
            (dClose > dOpen);

         bool structureBreak =
            (dClose > referenceHigh &&
             dClose > obHigh);

         if(!bearishOB ||
            !bullDisplacement ||
            !structureBreak)
         {
            continue;
         }

         if(!IsOrderBlockStillActive(
               direction,
               obLow,
               obHigh,
               displacementShift))
         {
            continue;
         }

         int touches =
            CountPriorZoneTouches(
               obLow,
               obHigh,
               1,
               displacementShift - 1
            );

         if(touches > MaxPriorZoneTouches)
            continue;

         zone.found = true;
         zone.low   = obLow;
         zone.high  = obHigh;
         zone.shift = obShift;
         zone.time  = iTime(Symbol(), PERIOD_M15, obShift);
         zone.type  = "BullOB";

         return(true);
      }

      //-------------------------------------------------------------
      // BEARISH OB
      //-------------------------------------------------------------
      if(direction == DIR_BEAR)
      {
         bool bullishOB =
            (obClose > obOpen);

         bool bearDisplacement =
            (dClose < dOpen);

         bool structureBreak =
            (dClose < referenceLow &&
             dClose < obLow);

         if(!bullishOB ||
            !bearDisplacement ||
            !structureBreak)
         {
            continue;
         }

         if(!IsOrderBlockStillActive(
               direction,
               obLow,
               obHigh,
               displacementShift))
         {
            continue;
         }

         int touches =
            CountPriorZoneTouches(
               obLow,
               obHigh,
               1,
               displacementShift - 1
            );

         if(touches > MaxPriorZoneTouches)
            continue;

         zone.found = true;
         zone.low   = obLow;
         zone.high  = obHigh;
         zone.shift = obShift;
         zone.time  = iTime(Symbol(), PERIOD_M15, obShift);
         zone.type  = "BearOB";

         return(true);
      }
   }

   return(false);
}

//====================================================================
// FRESH M15 IFVG
//====================================================================
bool FindFreshM15IFVG(
   int direction,
   PriceZone &zone
)
{
   zone.found = false;
   zone.low   = 0.0;
   zone.high  = 0.0;
   zone.shift = -1;
   zone.time  = 0;
   zone.type  = "";

   for(int gapShift = 4;
       gapShift <= M15ZoneLookback;
       gapShift++)
   {
      if(UseSessionFilter &&
         RequireSessionFormedSetups)
      {
         if(!IsBarAfterSessionStart(PERIOD_M15, gapShift) ||
            !IsBarAfterSessionStart(PERIOD_M15, gapShift + 1) ||
            !IsBarAfterSessionStart(PERIOD_M15, gapShift + 2))
         {
            continue;
         }
      }

      // Three-candle imbalance:
      // older = gapShift + 2
      // newer = gapShift

      double oldHigh =
         iHigh(
            Symbol(),
            PERIOD_M15,
            gapShift + 2
         );

      double oldLow =
         iLow(
            Symbol(),
            PERIOD_M15,
            gapShift + 2
         );

      double newHigh =
         iHigh(
            Symbol(),
            PERIOD_M15,
            gapShift
         );

      double newLow =
         iLow(
            Symbol(),
            PERIOD_M15,
            gapShift
         );

      double atr =
         iATR(
            Symbol(),
            PERIOD_M15,
            ATR_Period,
            gapShift
         );

      if(atr <= 0.0)
         continue;

      //-------------------------------------------------------------
      // BULLISH IFVG
      // Original bearish FVG: newer high < older low.
      // Then a later M15 close must invert above gap high.
      //-------------------------------------------------------------
      if(direction == DIR_BULL &&
         newHigh < oldLow)
      {
         double gapLow  = newHigh;
         double gapHigh = oldLow;

         if((gapHigh - gapLow) <
            atr * M15MinFVGSizeATR)
         {
            continue;
         }

         int inversionShift = -1;

         for(int s = gapShift - 1;
             s >= 2;
             s--)
         {
            double c =
               iClose(
                  Symbol(),
                  PERIOD_M15,
                  s
               );

            if(c > gapHigh)
            {
               inversionShift = s;
               break;
            }
         }

         if(inversionShift < 0)
            continue;

         bool invalidated = false;

         for(int a = inversionShift - 1;
             a >= 1;
             a--)
         {
            double c =
               iClose(
                  Symbol(),
                  PERIOD_M15,
                  a
               );

            if(c < gapLow)
            {
               invalidated = true;
               break;
            }
         }

         if(invalidated)
            continue;

         int touches =
            CountPriorZoneTouches(
               gapLow,
               gapHigh,
               1,
               inversionShift - 1
            );

         if(touches > MaxPriorZoneTouches)
            continue;

         zone.found = true;
         zone.low   = gapLow;
         zone.high  = gapHigh;
         zone.shift = gapShift;
         zone.time  = iTime(Symbol(), PERIOD_M15, gapShift);
         zone.type  = "BullIFVG";

         return(true);
      }

      //-------------------------------------------------------------
      // BEARISH IFVG
      //-------------------------------------------------------------
      if(direction == DIR_BEAR &&
         newLow > oldHigh)
      {
         double gapLow  = oldHigh;
         double gapHigh = newLow;

         if((gapHigh - gapLow) <
            atr * M15MinFVGSizeATR)
         {
            continue;
         }

         int inversionShift = -1;

         for(int s = gapShift - 1;
             s >= 2;
             s--)
         {
            double c =
               iClose(
                  Symbol(),
                  PERIOD_M15,
                  s
               );

            if(c < gapLow)
            {
               inversionShift = s;
               break;
            }
         }

         if(inversionShift < 0)
            continue;

         bool invalidated = false;

         for(int a = inversionShift - 1;
             a >= 1;
             a--)
         {
            double c =
               iClose(
                  Symbol(),
                  PERIOD_M15,
                  a
               );

            if(c > gapHigh)
            {
               invalidated = true;
               break;
            }
         }

         if(invalidated)
            continue;

         int touches =
            CountPriorZoneTouches(
               gapLow,
               gapHigh,
               1,
               inversionShift - 1
            );

         if(touches > MaxPriorZoneTouches)
            continue;

         zone.found = true;
         zone.low   = gapLow;
         zone.high  = gapHigh;
         zone.shift = gapShift;
         zone.time  = iTime(Symbol(), PERIOD_M15, gapShift);
         zone.type  = "BearIFVG";

         return(true);
      }
   }

   return(false);
}

//====================================================================
// ZONE INTERACTION
//====================================================================
bool CandleTouchesZone(
   double candleLow,
   double candleHigh,
   PriceZone &zone,
   double tolerance
)
{
   if(!zone.found)
      return(false);

   double expandedLow  =
      zone.low - tolerance;

   double expandedHigh =
      zone.high + tolerance;

   if(candleHigh >= expandedLow &&
      candleLow <= expandedHigh)
   {
      return(true);
   }

   return(false);
}


//+------------------------------------------------------------------+
//| Finds the most recent M1 interaction with a valid M15 zone.      |
//|                                                                  |
//| Shift 2 is the sweep candle. We search from shift 2 backwards    |
//| in time (higher shifts) so the POI touch can happen before or on |
//| the sweep candle, but never after the sweep.                     |
//|                                                                  |
//| All candles must remain inside the trusted structure session.   |
//+------------------------------------------------------------------+
bool FindRecentM1ZoneTouch(
   PriceZone &zone,
   double tolerance,
   int &touchShift,
   datetime &touchTime,
   double &touchLow,
   double &touchHigh
)
{
   touchShift = -1;
   touchTime  = 0;
   touchLow   = 0.0;
   touchHigh  = 0.0;

   if(!zone.found)
      return(false);

   int oldestShift =
      2 + RecentZoneTouchLookbackM1 - 1;

   for(int shift = 2;
       shift <= oldestShift;
       shift++)
   {
      if(UseSessionFilter &&
         RequireSessionFormedSetups &&
         !IsBarAfterSessionStart(PERIOD_M1, shift))
      {
         break;
      }

      double low =
         iLow(
            Symbol(),
            PERIOD_M1,
            shift
         );

      double high =
         iHigh(
            Symbol(),
            PERIOD_M1,
            shift
         );

      if(CandleTouchesZone(
            low,
            high,
            zone,
            tolerance))
      {
         touchShift = shift;
         touchTime  =
            iTime(
               Symbol(),
               PERIOD_M1,
               shift
            );
         touchLow   = low;
         touchHigh  = high;

         // First match is the most recent touch.
         return(true);
      }
   }

   return(false);
}

//====================================================================
// M1 EXECUTION TRIGGER
//====================================================================
bool GetM1ExecutionTrigger(
   int direction,
   double &referenceLiquidity,
   double &sweepExtreme,
   double &confirmClose,
   double &sweepLow,
   double &sweepHigh,
   string &triggerReason
)
{
   referenceLiquidity = 0.0;
   sweepExtreme       = 0.0;
   confirmClose       = 0.0;
   sweepLow           = 0.0;
   sweepHigh          = 0.0;
   triggerReason      = "";

   // Bar 2 = sweep candle
   // Bar 1 = confirmation / MSS candle

   if(UseSessionFilter &&
      RequireSessionFormedSetups)
   {
      // Sweep and confirmation must be in-session.
      if(!IsBarAfterSessionStart(PERIOD_M1, 2) ||
         !IsBarAfterSessionStart(PERIOD_M1, 1))
      {
         return(false);
      }

      // The oldest candle used to define the liquidity pool must also
      // be post-structure-session-start, otherwise pre-session weak structure
      // could still generate a "valid" sweep after StructureStartHour.
      int oldestLiquidityShift =
         3 + M1LiquidityLookback - 1;

      if(!IsBarAfterSessionStart(
            PERIOD_M1,
            oldestLiquidityShift))
      {
         return(false);
      }
   }

   double open2 =
      iOpen(Symbol(), PERIOD_M1, 2);

   double high2 =
      iHigh(Symbol(), PERIOD_M1, 2);

   double low2 =
      iLow(Symbol(), PERIOD_M1, 2);

   double close2 =
      iClose(Symbol(), PERIOD_M1, 2);

   double open1 =
      iOpen(Symbol(), PERIOD_M1, 1);

   double high1 =
      iHigh(Symbol(), PERIOD_M1, 1);

   double low1 =
      iLow(Symbol(), PERIOD_M1, 1);

   double close1 =
      iClose(Symbol(), PERIOD_M1, 1);

   double atr1 =
      iATR(
         Symbol(),
         PERIOD_M1,
         ATR_Period,
         1
      );

   if(atr1 <= 0.0)
      return(false);

   double confirmBody =
      MathAbs(close1 - open1);

   //===============================================================
   // BUY
   //===============================================================
   if(direction == DIR_BULL)
   {
      double priorLow = 1.0e100;

      // Liquidity pool BEFORE sweep candle.
      for(int s = 3;
          s < 3 + M1LiquidityLookback;
          s++)
      {
         double l =
            iLow(
               Symbol(),
               PERIOD_M1,
               s
            );

         if(l < priorLow)
            priorLow = l;
      }

      double minSweepPenetration =
         atr1 * M1MinSweepPenetrationATR;

      bool sweptLiquidity =
         (low2 < priorLow - minSweepPenetration);

      bool reclaimed =
         (close2 > priorLow);

      bool confirmationBull =
         (close1 > open1);

      // Mechanical M1 MSS:
      // confirmation candle closes above sweep candle high.
      bool mss =
         (close1 > high2);

      bool displacement =
         (confirmBody >=
          atr1 * M1MinConfirmBodyATR);

      if(sweptLiquidity &&
         reclaimed &&
         confirmationBull &&
         mss &&
         displacement)
      {
         referenceLiquidity = priorLow;
         sweepExtreme       = low2;
         confirmClose       = close1;
         sweepLow           = MathMin(low2, low1);
         sweepHigh          = MathMax(high2, high1);

         triggerReason =
            "BUY sweep+reclaim+MSS";

         return(true);
      }

      return(false);
   }

   //===============================================================
   // SELL
   //===============================================================
   if(direction == DIR_BEAR)
   {
      double priorHigh = -1.0;

      for(int s = 3;
          s < 3 + M1LiquidityLookback;
          s++)
      {
         double h =
            iHigh(
               Symbol(),
               PERIOD_M1,
               s
            );

         if(priorHigh < 0.0 ||
            h > priorHigh)
         {
            priorHigh = h;
         }
      }

      double minSweepPenetration =
         atr1 * M1MinSweepPenetrationATR;

      bool sweptLiquidity =
         (high2 > priorHigh + minSweepPenetration);

      bool reclaimed =
         (close2 < priorHigh);

      bool confirmationBear =
         (close1 < open1);

      bool mss =
         (close1 < low2);

      bool displacement =
         (confirmBody >=
          atr1 * M1MinConfirmBodyATR);

      if(sweptLiquidity &&
         reclaimed &&
         confirmationBear &&
         mss &&
         displacement)
      {
         referenceLiquidity = priorHigh;
         sweepExtreme       = high2;
         confirmClose       = close1;
         sweepLow           = MathMin(low2, low1);
         sweepHigh          = MathMax(high2, high1);

         triggerReason =
            "SELL sweep+reclaim+MSS";

         return(true);
      }

      return(false);
   }

   return(false);
}

//====================================================================
// VALIDATE M15 CONTEXT AFTER M1 TRIGGER
//====================================================================
bool ValidateM15ContextAfterTrigger(
   int direction,
   double sweepLow,
   double sweepHigh,
   double sweepExtreme,
   PriceZone &ob,
   PriceZone &ifvg,
   double &rangeLow,
   double &equilibrium,
   double &rangeHigh,
   string &zoneUsed,
   double &zoneLow,
   double &zoneHigh,
   int &zoneTouchShift,
   datetime &zoneTouchTime,
   string &rejectReason
)
{
   zoneUsed       = "NO_ZONE";
   zoneLow        = 0.0;
   zoneHigh       = 0.0;
   zoneTouchShift = -1;
   zoneTouchTime  = 0;
   rejectReason   = "";

   //===============================================================
   // 1) SESSION DEALING RANGE IS ALWAYS REQUIRED
   //===============================================================
   if(!GetM15DealingRange(
         rangeLow,
         rangeHigh,
         equilibrium))
   {
      rejectReason = "NO_SESSION_DEALING_RANGE";
      return(false);
   }

   // Actual sweep must occur on the correct side of the current
   // session dealing range.
   if(direction == DIR_BULL &&
      sweepExtreme > equilibrium)
   {
      rejectReason = "BUY_SWEEP_NOT_IN_SESSION_DISCOUNT";
      return(false);
   }

   if(direction == DIR_BEAR &&
      sweepExtreme < equilibrium)
   {
      rejectReason = "SELL_SWEEP_NOT_IN_SESSION_PREMIUM";
      return(false);
   }

   //===============================================================
   // 2) DETECT M15 POI CONFLUENCE
   //===============================================================
   double atr15 =
      iATR(
         Symbol(),
         PERIOD_M15,
         ATR_Period,
         1
      );

   if(atr15 <= 0.0)
   {
      rejectReason = "INVALID_M15_ATR";
      return(false);
   }

   double tolerance =
      atr15 * ZoneTouchToleranceATR;

   int obTouchShift = -1;
   datetime obTouchTime = 0;
   double obTouchLow = 0.0;
   double obTouchHigh = 0.0;

   int ifvgTouchShift = -1;
   datetime ifvgTouchTime = 0;
   double ifvgTouchLow = 0.0;
   double ifvgTouchHigh = 0.0;

   bool recentTouchOB =
      FindRecentM1ZoneTouch(
         ob,
         tolerance,
         obTouchShift,
         obTouchTime,
         obTouchLow,
         obTouchHigh
      );

   bool recentTouchIFVG =
      FindRecentM1ZoneTouch(
         ifvg,
         tolerance,
         ifvgTouchShift,
         ifvgTouchTime,
         ifvgTouchLow,
         ifvgTouchHigh
      );

   // Record confluence metadata even when not mandatory.
   if(recentTouchOB &&
      recentTouchIFVG)
   {
      zoneUsed = "OB+IFVG";
      zoneLow  = MathMin(ob.low, ifvg.low);
      zoneHigh = MathMax(ob.high, ifvg.high);

      if(obTouchShift <= ifvgTouchShift)
      {
         zoneTouchShift = obTouchShift;
         zoneTouchTime  = obTouchTime;
      }
      else
      {
         zoneTouchShift = ifvgTouchShift;
         zoneTouchTime  = ifvgTouchTime;
      }
   }
   else if(recentTouchOB)
   {
      zoneUsed       = "OB";
      zoneLow        = ob.low;
      zoneHigh       = ob.high;
      zoneTouchShift = obTouchShift;
      zoneTouchTime  = obTouchTime;
   }
   else if(recentTouchIFVG)
   {
      zoneUsed       = "IFVG";
      zoneLow        = ifvg.low;
      zoneHigh       = ifvg.high;
      zoneTouchShift = ifvgTouchShift;
      zoneTouchTime  = ifvgTouchTime;
   }

   //===============================================================
   // 3) OPTIONAL HARD POI FILTER
   //===============================================================
   if(RequireM15ZoneTouch)
   {
      if(!recentTouchOB &&
         !recentTouchIFVG)
      {
         rejectReason = "NO_RECENT_M15_ZONE_TOUCH";
         return(false);
      }

      if(ZoneFilterMode == ZONE_REQUIRE_IFVG &&
         !recentTouchIFVG)
      {
         rejectReason = "IFVG_REQUIRED_NO_RECENT_TOUCH";
         return(false);
      }

      if(ZoneFilterMode == ZONE_REQUIRE_CONFLUENCE &&
         !(recentTouchOB && recentTouchIFVG))
      {
         rejectReason = "OB_IFVG_RECENT_CONFLUENCE_REQUIRED";
         return(false);
      }

      if(ZoneFilterMode == ZONE_OB_ONLY &&
         !(recentTouchOB && !recentTouchIFVG))
      {
         rejectReason = "OB_ONLY_FILTER_REJECT";
         return(false);
      }

      if(ZoneFilterMode == ZONE_IFVG_ONLY &&
         !(recentTouchIFVG && !recentTouchOB))
      {
         rejectReason = "IFVG_ONLY_FILTER_REJECT";
         return(false);
      }
   }

   return(true);
}


//====================================================================
// V9 GENERIC HIGHER-TF ENGINE HELPERS
//====================================================================
bool GetDealingRangeTF(
   int timeframe,
   int lookbackBars,
   double &rangeLow,
   double &rangeHigh,
   double &equilibrium
)
{
   rangeLow = 0.0;
   rangeHigh = 0.0;
   equilibrium = 0.0;

   int highShift =
      iHighest(Symbol(), timeframe, MODE_HIGH, lookbackBars, 1);

   int lowShift =
      iLowest(Symbol(), timeframe, MODE_LOW, lookbackBars, 1);

   if(highShift < 0 || lowShift < 0)
      return(false);

   rangeHigh =
      iHigh(Symbol(), timeframe, highShift);

   rangeLow =
      iLow(Symbol(), timeframe, lowShift);

   if(rangeHigh <= rangeLow)
      return(false);

   equilibrium =
      (rangeHigh + rangeLow) / 2.0;

   return(true);
}

//+------------------------------------------------------------------+
bool IsOrderBlockStillActiveTF(
   int timeframe,
   int direction,
   double zoneLow,
   double zoneHigh,
   int displacementShift
)
{
   for(int shift = displacementShift - 1;
       shift >= 1;
       shift--)
   {
      double closePrice =
         iClose(Symbol(), timeframe, shift);

      if(direction == DIR_BULL &&
         closePrice < zoneLow)
         return(false);

      if(direction == DIR_BEAR &&
         closePrice > zoneHigh)
         return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
int CountPriorZoneTouchesTF(
   int timeframe,
   double zoneLow,
   double zoneHigh,
   int newestShift,
   int oldestShift
)
{
   if(oldestShift < newestShift)
      return(0);

   int touches = 0;

   for(int shift = newestShift;
       shift <= oldestShift;
       shift++)
   {
      if(shift < 1)
         continue;

      double h =
         iHigh(Symbol(), timeframe, shift);

      double l =
         iLow(Symbol(), timeframe, shift);

      if(h >= zoneLow &&
         l <= zoneHigh)
         touches++;
   }

   return(touches);
}

//+------------------------------------------------------------------+
bool FindFreshOrderBlockTF(
   int timeframe,
   int direction,
   int zoneLookback,
   int obBreakLookback,
   double minDisplacementATR,
   int maxPriorTouches,
   PriceZone &zone
)
{
   zone.found = false;
   zone.low   = 0.0;
   zone.high  = 0.0;
   zone.shift = -1;
   zone.time  = 0;
   zone.type  = "";

   for(int obShift = 3;
       obShift <= zoneLookback;
       obShift++)
   {
      int displacementShift =
         obShift - 1;

      double obOpen =
         iOpen(Symbol(), timeframe, obShift);
      double obClose =
         iClose(Symbol(), timeframe, obShift);
      double obHigh =
         iHigh(Symbol(), timeframe, obShift);
      double obLow =
         iLow(Symbol(), timeframe, obShift);

      double dOpen =
         iOpen(Symbol(), timeframe, displacementShift);
      double dClose =
         iClose(Symbol(), timeframe, displacementShift);

      double atr =
         iATR(Symbol(), timeframe, ATR_Period, displacementShift);

      if(atr <= 0.0)
         continue;

      double body =
         MathAbs(dClose - dOpen);

      if(body < atr * minDisplacementATR)
         continue;

      double referenceHigh = -1.0;
      double referenceLow  = 1.0e100;

      for(int k = 1;
          k <= obBreakLookback;
          k++)
      {
         int s = obShift + k;

         double h =
            iHigh(Symbol(), timeframe, s);

         double l =
            iLow(Symbol(), timeframe, s);

         if(referenceHigh < 0.0 ||
            h > referenceHigh)
            referenceHigh = h;

         if(l < referenceLow)
            referenceLow = l;
      }

      if(direction == DIR_BULL)
      {
         bool bearishOB =
            (obClose < obOpen);

         bool bullDisplacement =
            (dClose > dOpen);

         bool structureBreak =
            (dClose > referenceHigh &&
             dClose > obHigh);

         if(!bearishOB ||
            !bullDisplacement ||
            !structureBreak)
            continue;

         if(!IsOrderBlockStillActiveTF(
               timeframe,
               direction,
               obLow,
               obHigh,
               displacementShift))
            continue;

         int touches =
            CountPriorZoneTouchesTF(
               timeframe,
               obLow,
               obHigh,
               1,
               displacementShift - 1
            );

         if(touches > maxPriorTouches)
            continue;

         zone.found = true;
         zone.low   = obLow;
         zone.high  = obHigh;
         zone.shift = obShift;
         zone.time  = iTime(Symbol(), timeframe, obShift);
         zone.type  = "BullOB";

         return(true);
      }

      if(direction == DIR_BEAR)
      {
         bool bullishOB =
            (obClose > obOpen);

         bool bearDisplacement =
            (dClose < dOpen);

         bool structureBreak =
            (dClose < referenceLow &&
             dClose < obLow);

         if(!bullishOB ||
            !bearDisplacement ||
            !structureBreak)
            continue;

         if(!IsOrderBlockStillActiveTF(
               timeframe,
               direction,
               obLow,
               obHigh,
               displacementShift))
            continue;

         int touches =
            CountPriorZoneTouchesTF(
               timeframe,
               obLow,
               obHigh,
               1,
               displacementShift - 1
            );

         if(touches > maxPriorTouches)
            continue;

         zone.found = true;
         zone.low   = obLow;
         zone.high  = obHigh;
         zone.shift = obShift;
         zone.time  = iTime(Symbol(), timeframe, obShift);
         zone.type  = "BearOB";

         return(true);
      }
   }

   return(false);
}

//+------------------------------------------------------------------+
bool FindFreshIFVGTF(
   int timeframe,
   int direction,
   int zoneLookback,
   double minFVGSizeATR,
   int maxPriorTouches,
   PriceZone &zone
)
{
   zone.found = false;
   zone.low   = 0.0;
   zone.high  = 0.0;
   zone.shift = -1;
   zone.time  = 0;
   zone.type  = "";

   for(int gapShift = 4;
       gapShift <= zoneLookback;
       gapShift++)
   {
      double oldHigh =
         iHigh(Symbol(), timeframe, gapShift + 2);
      double oldLow =
         iLow(Symbol(), timeframe, gapShift + 2);
      double newHigh =
         iHigh(Symbol(), timeframe, gapShift);
      double newLow =
         iLow(Symbol(), timeframe, gapShift);

      double atr =
         iATR(Symbol(), timeframe, ATR_Period, gapShift);

      if(atr <= 0.0)
         continue;

      if(direction == DIR_BULL &&
         newHigh < oldLow)
      {
         double gapLow  = newHigh;
         double gapHigh = oldLow;

         if((gapHigh - gapLow) <
            atr * minFVGSizeATR)
            continue;

         int inversionShift = -1;

         for(int s = gapShift - 1;
             s >= 2;
             s--)
         {
            if(iClose(Symbol(), timeframe, s) > gapHigh)
            {
               inversionShift = s;
               break;
            }
         }

         if(inversionShift < 0)
            continue;

         bool invalidated = false;

         for(int a = inversionShift - 1;
             a >= 1;
             a--)
         {
            if(iClose(Symbol(), timeframe, a) < gapLow)
            {
               invalidated = true;
               break;
            }
         }

         if(invalidated)
            continue;

         int touches =
            CountPriorZoneTouchesTF(
               timeframe,
               gapLow,
               gapHigh,
               1,
               inversionShift - 1
            );

         if(touches > maxPriorTouches)
            continue;

         zone.found = true;
         zone.low   = gapLow;
         zone.high  = gapHigh;
         zone.shift = gapShift;
         zone.time  = iTime(Symbol(), timeframe, gapShift);
         zone.type  = "BullIFVG";

         return(true);
      }

      if(direction == DIR_BEAR &&
         newLow > oldHigh)
      {
         double gapLow  = oldHigh;
         double gapHigh = newLow;

         if((gapHigh - gapLow) <
            atr * minFVGSizeATR)
            continue;

         int inversionShift = -1;

         for(int s = gapShift - 1;
             s >= 2;
             s--)
         {
            if(iClose(Symbol(), timeframe, s) < gapLow)
            {
               inversionShift = s;
               break;
            }
         }

         if(inversionShift < 0)
            continue;

         bool invalidated = false;

         for(int a = inversionShift - 1;
             a >= 1;
             a--)
         {
            if(iClose(Symbol(), timeframe, a) > gapHigh)
            {
               invalidated = true;
               break;
            }
         }

         if(invalidated)
            continue;

         int touches =
            CountPriorZoneTouchesTF(
               timeframe,
               gapLow,
               gapHigh,
               1,
               inversionShift - 1
            );

         if(touches > maxPriorTouches)
            continue;

         zone.found = true;
         zone.low   = gapLow;
         zone.high  = gapHigh;
         zone.shift = gapShift;
         zone.time  = iTime(Symbol(), timeframe, gapShift);
         zone.type  = "BearIFVG";

         return(true);
      }
   }

   return(false);
}

//+------------------------------------------------------------------+
bool FindRecentZoneTouchTF(
   PriceZone &zone,
   int executionTF,
   int recentLookback,
   double tolerance,
   bool restrictToWindow,
   int startHour,
   int endHour,
   int &touchShift,
   datetime &touchTime,
   double &touchLow,
   double &touchHigh
)
{
   touchShift = -1;
   touchTime  = 0;
   touchLow   = 0.0;
   touchHigh  = 0.0;

   if(!zone.found)
      return(false);

   int oldestShift =
      2 + recentLookback - 1;

   for(int shift = 2;
       shift <= oldestShift;
       shift++)
   {
      if(restrictToWindow &&
         !IsBarInsideWindow(
            executionTF,
            shift,
            startHour,
            endHour))
         break;

      double low =
         iLow(Symbol(), executionTF, shift);

      double high =
         iHigh(Symbol(), executionTF, shift);

      if(CandleTouchesZone(
            low,
            high,
            zone,
            tolerance))
      {
         touchShift = shift;
         touchTime =
            iTime(Symbol(), executionTF, shift);
         touchLow  = low;
         touchHigh = high;

         return(true);
      }
   }

   return(false);
}

//+------------------------------------------------------------------+
bool GetExecutionTriggerTF(
   int executionTF,
   int direction,
   int liquidityLookback,
   double minConfirmBodyATR,
   double minSweepPenetrationATR,
   bool restrictToWindow,
   int startHour,
   int endHour,
   double &referenceLiquidity,
   double &sweepExtreme,
   double &confirmClose,
   double &sweepLow,
   double &sweepHigh,
   string &triggerReason
)
{
   referenceLiquidity = 0.0;
   sweepExtreme       = 0.0;
   confirmClose       = 0.0;
   sweepLow           = 0.0;
   sweepHigh          = 0.0;
   triggerReason      = "";

   if(restrictToWindow)
   {
      if(!IsBarInsideWindow(executionTF, 2, startHour, endHour) ||
         !IsBarInsideWindow(executionTF, 1, startHour, endHour))
         return(false);

      int oldestLiquidityShift =
         3 + liquidityLookback - 1;

      if(!IsBarInsideWindow(
            executionTF,
            oldestLiquidityShift,
            startHour,
            endHour))
         return(false);
   }

   double open2 =
      iOpen(Symbol(), executionTF, 2);
   double high2 =
      iHigh(Symbol(), executionTF, 2);
   double low2 =
      iLow(Symbol(), executionTF, 2);
   double close2 =
      iClose(Symbol(), executionTF, 2);

   double open1 =
      iOpen(Symbol(), executionTF, 1);
   double high1 =
      iHigh(Symbol(), executionTF, 1);
   double low1 =
      iLow(Symbol(), executionTF, 1);
   double close1 =
      iClose(Symbol(), executionTF, 1);

   double atr1 =
      iATR(Symbol(), executionTF, ATR_Period, 1);

   if(atr1 <= 0.0)
      return(false);

   double confirmBody =
      MathAbs(close1 - open1);

   if(direction == DIR_BULL)
   {
      double priorLow = 1.0e100;

      for(int s = 3;
          s < 3 + liquidityLookback;
          s++)
      {
         double l =
            iLow(Symbol(), executionTF, s);

         if(l < priorLow)
            priorLow = l;
      }

      double minSweepPenetration =
         atr1 * minSweepPenetrationATR;

      bool sweptLiquidity =
         (low2 < priorLow - minSweepPenetration);

      bool reclaimed =
         (close2 > priorLow);

      bool confirmationBull =
         (close1 > open1);

      bool mss =
         (close1 > high2);

      bool displacement =
         (confirmBody >= atr1 * minConfirmBodyATR);

      if(sweptLiquidity &&
         reclaimed &&
         confirmationBull &&
         mss &&
         displacement)
      {
         referenceLiquidity = priorLow;
         sweepExtreme       = low2;
         confirmClose       = close1;
         sweepLow           = MathMin(low2, low1);
         sweepHigh          = MathMax(high2, high1);
         triggerReason      = "B BUY M5 sweep+reclaim+MSS";
         return(true);
      }

      return(false);
   }

   if(direction == DIR_BEAR)
   {
      double priorHigh = -1.0;

      for(int s = 3;
          s < 3 + liquidityLookback;
          s++)
      {
         double h =
            iHigh(Symbol(), executionTF, s);

         if(priorHigh < 0.0 ||
            h > priorHigh)
            priorHigh = h;
      }

      double minSweepPenetration =
         atr1 * minSweepPenetrationATR;

      bool sweptLiquidity =
         (high2 > priorHigh + minSweepPenetration);

      bool reclaimed =
         (close2 < priorHigh);

      bool confirmationBear =
         (close1 < open1);

      bool mss =
         (close1 < low2);

      bool displacement =
         (confirmBody >= atr1 * minConfirmBodyATR);

      if(sweptLiquidity &&
         reclaimed &&
         confirmationBear &&
         mss &&
         displacement)
      {
         referenceLiquidity = priorHigh;
         sweepExtreme       = high2;
         confirmClose       = close1;
         sweepLow           = MathMin(low2, low1);
         sweepHigh          = MathMax(high2, high1);
         triggerReason      = "B SELL M5 sweep+reclaim+MSS";
         return(true);
      }

      return(false);
   }

   return(false);
}

//+------------------------------------------------------------------+
bool ValidateEngineBContext(
   int direction,
   double sweepLow,
   double sweepHigh,
   double sweepExtreme,
   PriceZone &ob,
   PriceZone &ifvg,
   double &rangeLow,
   double &equilibrium,
   double &rangeHigh,
   string &zoneUsed,
   double &zoneLow,
   double &zoneHigh,
   int &zoneTouchShift,
   datetime &zoneTouchTime,
   string &rejectReason
)
{
   zoneUsed       = "NO_ZONE";
   zoneLow        = 0.0;
   zoneHigh       = 0.0;
   zoneTouchShift = -1;
   zoneTouchTime  = 0;
   rejectReason   = "";

   if(!GetDealingRangeTF(
         PERIOD_H1,
         B_H1DealingRangeBars,
         rangeLow,
         rangeHigh,
         equilibrium))
   {
      rejectReason = "B_NO_H1_DEALING_RANGE";
      return(false);
   }

   if(direction == DIR_BULL &&
      sweepExtreme > equilibrium)
   {
      rejectReason = "B_BUY_SWEEP_NOT_IN_H1_DISCOUNT";
      return(false);
   }

   if(direction == DIR_BEAR &&
      sweepExtreme < equilibrium)
   {
      rejectReason = "B_SELL_SWEEP_NOT_IN_H1_PREMIUM";
      return(false);
   }

   double atrH1 =
      iATR(Symbol(), PERIOD_H1, ATR_Period, 1);

   if(atrH1 <= 0.0)
   {
      rejectReason = "B_INVALID_H1_ATR";
      return(false);
   }

   double tolerance =
      atrH1 * B_ZoneTouchToleranceATR;

   int obTouchShift = -1;
   datetime obTouchTime = 0;
   double obTouchLow = 0.0;
   double obTouchHigh = 0.0;

   int ifvgTouchShift = -1;
   datetime ifvgTouchTime = 0;
   double ifvgTouchLow = 0.0;
   double ifvgTouchHigh = 0.0;

   bool recentTouchOB =
      FindRecentZoneTouchTF(
         ob,
         PERIOD_M5,
         EngineBRecentZoneTouchM5,
         tolerance,
         EngineBUseEntryWindow,
         EngineBEntryStartHour,
         EngineBEntryEndHour,
         obTouchShift,
         obTouchTime,
         obTouchLow,
         obTouchHigh
      );

   bool recentTouchIFVG =
      FindRecentZoneTouchTF(
         ifvg,
         PERIOD_M5,
         EngineBRecentZoneTouchM5,
         tolerance,
         EngineBUseEntryWindow,
         EngineBEntryStartHour,
         EngineBEntryEndHour,
         ifvgTouchShift,
         ifvgTouchTime,
         ifvgTouchLow,
         ifvgTouchHigh
      );

   if(recentTouchOB &&
      recentTouchIFVG)
   {
      zoneUsed = "OB+IFVG";
      zoneLow  = MathMin(ob.low, ifvg.low);
      zoneHigh = MathMax(ob.high, ifvg.high);

      if(obTouchShift <= ifvgTouchShift)
      {
         zoneTouchShift = obTouchShift;
         zoneTouchTime  = obTouchTime;
      }
      else
      {
         zoneTouchShift = ifvgTouchShift;
         zoneTouchTime  = ifvgTouchTime;
      }
   }
   else if(recentTouchOB)
   {
      zoneUsed       = "OB";
      zoneLow        = ob.low;
      zoneHigh       = ob.high;
      zoneTouchShift = obTouchShift;
      zoneTouchTime  = obTouchTime;
   }
   else if(recentTouchIFVG)
   {
      zoneUsed       = "IFVG";
      zoneLow        = ifvg.low;
      zoneHigh       = ifvg.high;
      zoneTouchShift = ifvgTouchShift;
      zoneTouchTime  = ifvgTouchTime;
   }

   if(EngineBRequireH1ZoneTouch)
   {
      if(!recentTouchOB &&
         !recentTouchIFVG)
      {
         rejectReason = "B_NO_RECENT_H1_ZONE_TOUCH";
         return(false);
      }

      if(EngineBZoneFilterMode == ZONE_REQUIRE_IFVG &&
         !recentTouchIFVG)
      {
         rejectReason = "B_IFVG_REQUIRED";
         return(false);
      }

      if(EngineBZoneFilterMode == ZONE_REQUIRE_CONFLUENCE &&
         !(recentTouchOB && recentTouchIFVG))
      {
         rejectReason = "B_OB_IFVG_CONFLUENCE_REQUIRED";
         return(false);
      }

      if(EngineBZoneFilterMode == ZONE_OB_ONLY &&
         !(recentTouchOB && !recentTouchIFVG))
      {
         rejectReason = "B_OB_ONLY_FILTER_REJECT";
         return(false);
      }

      if(EngineBZoneFilterMode == ZONE_IFVG_ONLY &&
         !(recentTouchIFVG && !recentTouchOB))
      {
         rejectReason = "B_IFVG_ONLY_FILTER_REJECT";
         return(false);
      }
   }

   return(true);
}

//+------------------------------------------------------------------+
double CalculateInitialStopLossTF(
   int executionTF,
   double slBufferATR,
   int direction,
   double sweepExtreme
)
{
   double atr =
      iATR(Symbol(), executionTF, ATR_Period, 1);

   if(atr <= 0.0)
      return(0.0);

   double buffer =
      MathMax(
         PipSize(),
         atr * slBufferATR
      );

   if(direction == DIR_BULL)
      return(NormalizePrice(sweepExtreme - buffer));

   if(direction == DIR_BEAR)
      return(NormalizePrice(sweepExtreme + buffer));

   return(0.0);
}

//====================================================================
// STOP LOSS
//====================================================================
double CalculateInitialStopLoss(
   int direction,
   double sweepExtreme
)
{
   double atr =
      iATR(
         Symbol(),
         PERIOD_M1,
         ATR_Period,
         1
      );

   if(atr <= 0.0)
      return(0.0);

   double buffer =
      MathMax(
         PipSize(),
         atr * M1SLBufferATR
      );

   if(direction == DIR_BULL)
   {
      return(
         NormalizePrice(
            sweepExtreme - buffer
         )
      );
   }

   if(direction == DIR_BEAR)
   {
      return(
         NormalizePrice(
            sweepExtreme + buffer
         )
      );
   }

   return(0.0);
}

//====================================================================
// LOT NORMALIZATION
//====================================================================
int GetLotDigits(double lotStep)
{
   if(lotStep >= 1.0)
      return(0);

   if(lotStep >= 0.1)
      return(1);

   if(lotStep >= 0.01)
      return(2);

   if(lotStep >= 0.001)
      return(3);

   return(4);
}

//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double minLot =
      MarketInfo(Symbol(), MODE_MINLOT);

   double brokerMaxLot =
      MarketInfo(Symbol(), MODE_MAXLOT);

   double step =
      MarketInfo(Symbol(), MODE_LOTSTEP);

   if(step <= 0.0)
      step = 0.01;

   double effectiveMax =
      MathMin(
         brokerMaxLot,
         MaxLotCap
      );

   if(lots > effectiveMax)
      lots = effectiveMax;

   lots =
      MathFloor(
         lots / step
      ) * step;

   if(lots < minLot)
      return(0.0);

   return(
      NormalizeDouble(
         lots,
         GetLotDigits(step)
      )
   );
}

//====================================================================
// MONETARY RISK CALCULATION
//====================================================================
double CalculateMoneyRisk(
   double lots,
   double entryPrice,
   double stopLoss
)
{
   if(lots <= 0.0)
      return(0.0);

   double stopDistance =
      MathAbs(entryPrice - stopLoss);

   if(stopDistance <= 0.0)
      return(0.0);

   double tickValue =
      MarketInfo(
         Symbol(),
         MODE_TICKVALUE
      );

   double tickSizePrice =
      TickSizePrice();

   if(tickValue <= 0.0 ||
      tickSizePrice <= 0.0)
   {
      return(0.0);
   }

   double numberOfTicks =
      stopDistance /
      tickSizePrice;

   return(
      numberOfTicks *
      tickValue *
      lots
   );
}

//+------------------------------------------------------------------+
double CalculateLotSize(
   int command,
   double entryPrice,
   double stopLoss,
   double &estimatedRiskMoney
)
{
   estimatedRiskMoney = 0.0;

   //---------------------------------------------------------------
   // FIXED LOT
   //---------------------------------------------------------------
   if(UseFixedLot)
   {
      double lots =
         NormalizeLot(
            FixedLotSize
         );

      if(lots <= 0.0)
      {
         Print("ERROR: FixedLotSize invalid for this broker.");
         return(0.0);
      }

      estimatedRiskMoney =
         CalculateMoneyRisk(
            lots,
            entryPrice,
            stopLoss
         );

      return(lots);
   }

   //---------------------------------------------------------------
   // RISK-BASED LOT
   //---------------------------------------------------------------
   double stopDistance =
      MathAbs(
         entryPrice -
         stopLoss
      );

   if(stopDistance <= 0.0)
      return(0.0);

   double tickValue =
      MarketInfo(
         Symbol(),
         MODE_TICKVALUE
      );

   double tickSizePrice =
      TickSizePrice();

   if(tickValue <= 0.0 ||
      tickSizePrice <= 0.0)
   {
      Print(
         "ERROR: invalid tick metadata. TickValue=",
         DoubleToString(tickValue, 8),
         " TickSizePrice=",
         DoubleToString(tickSizePrice, 8)
      );
      return(0.0);
   }

   double riskBudget =
      AccountEquity() *
      (RiskPercent / 100.0);

   if(riskBudget <= 0.0)
      return(0.0);

   double oneLotRisk =
      CalculateMoneyRisk(
         1.0,
         entryPrice,
         stopLoss
      );

   if(oneLotRisk <= 0.0)
      return(0.0);

   double rawLots =
      riskBudget / oneLotRisk;

   double lots =
      NormalizeLot(rawLots);

   if(lots <= 0.0)
   {
      DebugPrint(
         "NO TRADE | calculated lot below broker minimum. raw=" +
         DoubleToString(rawLots, 4)
      );
      return(0.0);
   }

   estimatedRiskMoney =
      CalculateMoneyRisk(
         lots,
         entryPrice,
         stopLoss
      );

   // Because lots are rounded DOWN, this should normally be <= budget.
   // Guard against bad CFD metadata or unexpected rounding.
   double maxAllowedRisk =
      riskBudget * 1.02;

   if(estimatedRiskMoney >
      maxAllowedRisk)
   {
      Print(
         "RISK GUARD BLOCKED TRADE | estimated=",
         DoubleToString(estimatedRiskMoney, 2),
         " budget=",
         DoubleToString(riskBudget, 2)
      );

      return(0.0);
   }

   ResetLastError();

   double freeMarginAfter =
      AccountFreeMarginCheck(
         Symbol(),
         command,
         lots
      );

   int marginError =
      GetLastError();

   if(freeMarginAfter <= 0.0 ||
      marginError == 134)
   {
      Print("NO TRADE | insufficient margin.");
      return(0.0);
   }

   return(lots);
}

//====================================================================
// BROKER-SAFE STOPS
//====================================================================
bool BuildBrokerSafeStops(
   int command,
   double entry,
   double structuralSL,
   double &finalSL,
   double &finalTP
)
{
   double minDistance =
      MarketInfo(
         Symbol(),
         MODE_STOPLEVEL
      ) * Point;

   minDistance += Point;

   finalSL = structuralSL;

   if(command == OP_BUY)
   {
      if(finalSL >= entry)
         return(false);

      if((entry - finalSL) <
         minDistance)
      {
         finalSL =
            entry - minDistance;
      }

      double riskDistance =
         entry - finalSL;

      if(riskDistance <= 0.0)
         return(false);

      finalTP =
         entry +
         riskDistance * MinRVRatio;
   }
   else if(command == OP_SELL)
   {
      if(finalSL <= entry)
         return(false);

      if((finalSL - entry) <
         minDistance)
      {
         finalSL =
            entry + minDistance;
      }

      double riskDistance =
         finalSL - entry;

      if(riskDistance <= 0.0)
         return(false);

      finalTP =
         entry -
         riskDistance * MinRVRatio;
   }
   else
   {
      return(false);
   }

   finalSL =
      NormalizePrice(finalSL);

   finalTP =
      NormalizePrice(finalTP);

   return(true);
}

//====================================================================
// OPEN TRADE COUNT
//====================================================================
int CountOpenTrades()
{
   int count = 0;

   for(int pos = OrdersTotal() - 1;
       pos >= 0;
       pos--)
   {
      if(!OrderSelect(
            pos,
            SELECT_BY_POS,
            MODE_TRADES))
      {
         continue;
      }

      if(OrderSymbol() != Symbol())
         continue;

      if(OrderMagicNumber() != MagicNumber)
         continue;

      if(OrderType() == OP_BUY ||
         OrderType() == OP_SELL)
      {
         count++;
      }
   }

   return(count);
}


//====================================================================
// V9 MULTI-ENGINE OPEN TRADE / RISK CONTROL
//====================================================================
int CountOpenTradesByMagic(int magicNumber)
{
   int count = 0;

   for(int pos = OrdersTotal() - 1;
       pos >= 0;
       pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol())
         continue;

      if(OrderMagicNumber() != magicNumber)
         continue;

      if(OrderType() == OP_BUY ||
         OrderType() == OP_SELL)
         count++;
   }

   return(count);
}

//+------------------------------------------------------------------+
int CountAllEngineOpenTrades()
{
   int count = 0;

   for(int pos = OrdersTotal() - 1;
       pos >= 0;
       pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol())
         continue;

      long magic = OrderMagicNumber();

      if(magic != MagicNumber &&
         magic != EngineBMagicNumber)
         continue;

      if(OrderType() == OP_BUY ||
         OrderType() == OP_SELL)
         count++;
   }

   return(count);
}

//+------------------------------------------------------------------+
double CurrentCombinedOpenRiskMoney()
{
   double totalRisk = 0.0;

   for(int pos = OrdersTotal() - 1;
       pos >= 0;
       pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol())
         continue;

      long magic = OrderMagicNumber();

      if(magic != MagicNumber &&
         magic != EngineBMagicNumber)
         continue;

      if(OrderType() != OP_BUY &&
         OrderType() != OP_SELL)
         continue;

      double sl = OrderStopLoss();

      if(sl <= 0.0)
         continue;

      totalRisk +=
         CalculateMoneyRisk(
            OrderLots(),
            OrderOpenPrice(),
            sl
         );
   }

   return(totalRisk);
}

//+------------------------------------------------------------------+
bool CanOpenEngineRisk(
   int magicNumber,
   double requestedRiskPercent
)
{
   if(CountOpenTradesByMagic(magicNumber) >= MaxOpenTrades)
      return(false);

   if(CountAllEngineOpenTrades() >= MaxOpenTradesTotal)
      return(false);

   if(UseFixedLot)
      return(true);

   double equity = AccountEquity();

   if(equity <= 0.0)
      return(false);

   double existingRisk =
      CurrentCombinedOpenRiskMoney();

   double requestedRisk =
      equity * (requestedRiskPercent / 100.0);

   double maxRisk =
      equity * (MaxCombinedOpenRiskPercent / 100.0);

   return(
      existingRisk + requestedRisk <=
      maxRisk * 1.001
   );
}

//====================================================================
// ERROR HANDLING
//====================================================================
bool IsTransientTradeError(int errorCode)
{
   switch(errorCode)
   {
      case 4:    // server busy
      case 128:  // timeout
      case 129:  // invalid price
      case 135:  // price changed
      case 136:  // off quotes
      case 137:  // broker busy
      case 138:  // requote
      case 146:  // trade context busy
         return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
void ReportTradeError(
   string source,
   int errorCode
)
{
   string message =
      "MultiTF_PriceAction_EA V9 Multi-Engine | " +
      source +
      " | Error " +
      IntegerToString(errorCode) +
      " | " +
      ErrorDescription(errorCode);

   Print(message);

   if(!IsTesting())
      Alert(message);
}

//====================================================================
// EMERGENCY CLOSE
//====================================================================
bool EmergencyCloseOrder(int ticket)
{
   if(!OrderSelect(
         ticket,
         SELECT_BY_TICKET))
   {
      ReportTradeError(
         "Emergency OrderSelect",
         GetLastError()
      );
      return(false);
   }

   int type = OrderType();

   if(type != OP_BUY &&
      type != OP_SELL)
   {
      return(false);
   }

   RefreshRates();

   double closePrice =
      (type == OP_BUY ? Bid : Ask);

   ResetLastError();

   bool result =
      OrderClose(
         ticket,
         OrderLots(),
         closePrice,
         SlippagePoints(),
         clrNONE
      );

   if(!result)
   {
      ReportTradeError(
         "Emergency OrderClose",
         GetLastError()
      );
      return(false);
   }

   return(true);
}

//====================================================================
// ECN FALLBACK
//====================================================================
int SendECNFallback(
   int command,
   double lots,
   double structuralSL,
   string tradeComment,
   double &fillPriceOut,
   double &finalSLOut,
   double &finalTPOut
)
{
   fillPriceOut = 0.0;
   finalSLOut   = 0.0;
   finalTPOut   = 0.0;

   RefreshRates();

   if(!IsSpreadAcceptable())
      return(-1);

   double price =
      (command == OP_BUY ? Ask : Bid);

   price =
      NormalizePrice(price);

   ResetLastError();

   int ticket =
      OrderSend(
         Symbol(),
         command,
         lots,
         price,
         SlippagePoints(),
         0,
         0,
         tradeComment,
         MagicNumber,
         0,
         clrNONE
      );

   if(ticket < 0)
   {
      ReportTradeError(
         "ECN OrderSend",
         GetLastError()
      );
      return(-1);
   }

   if(!OrderSelect(
         ticket,
         SELECT_BY_TICKET))
   {
      ReportTradeError(
         "ECN OrderSelect",
         GetLastError()
      );

      EmergencyCloseOrder(ticket);
      return(-1);
   }

   double fillPrice =
      OrderOpenPrice();

   double finalSL = 0.0;
   double finalTP = 0.0;

   if(!BuildBrokerSafeStops(
         command,
         fillPrice,
         structuralSL,
         finalSL,
         finalTP))
   {
      EmergencyCloseOrder(ticket);
      return(-1);
   }

   ResetLastError();

   bool modified =
      OrderModify(
         ticket,
         fillPrice,
         finalSL,
         finalTP,
         0,
         clrNONE
      );

   if(!modified)
   {
      ReportTradeError(
         "ECN OrderModify",
         GetLastError()
      );

      // Never intentionally leave an unprotected trade open.
      EmergencyCloseOrder(ticket);
      return(-1);
   }

   fillPriceOut = fillPrice;
   finalSLOut   = finalSL;
   finalTPOut   = finalTP;

   return(ticket);
}

//====================================================================
// ORDER EXECUTION
//====================================================================
bool ExecuteMarketTrade(
   int direction,
   double structuralSL,
   string tradeComment,
   int &ticketOut,
   double &entryOut,
   double &slOut,
   double &tpOut,
   double &lotsOut,
   double &riskMoneyOut
)
{
   ticketOut    = -1;
   entryOut     = 0.0;
   slOut        = 0.0;
   tpOut        = 0.0;
   lotsOut      = 0.0;
   riskMoneyOut = 0.0;

   int command;

   if(direction == DIR_BULL)
      command = OP_BUY;
   else if(direction == DIR_BEAR)
      command = OP_SELL;
   else
      return(false);

   if(CountOpenTrades() >= MaxOpenTrades)
      return(false);

   for(int attempt = 1;
       attempt <= MAX_SEND_RETRIES;
       attempt++)
   {
      RefreshRates();

      if(!IsSpreadAcceptable())
         return(false);

      double entryPrice =
         (command == OP_BUY ? Ask : Bid);

      entryPrice =
         NormalizePrice(entryPrice);

      double finalSL = 0.0;
      double finalTP = 0.0;

      if(!BuildBrokerSafeStops(
            command,
            entryPrice,
            structuralSL,
            finalSL,
            finalTP))
      {
         return(false);
      }

      double estimatedRiskMoney = 0.0;

      double lots =
         CalculateLotSize(
            command,
            entryPrice,
            finalSL,
            estimatedRiskMoney
         );

      if(lots <= 0.0)
         return(false);

      Print(
         "ORDER PREP | ",
         (command == OP_BUY ? "BUY" : "SELL"),
         " | lot=",
         DoubleToString(lots, 3),
         " | entry=",
         DoubleToString(entryPrice, Digits),
         " | SL=",
         DoubleToString(finalSL, Digits),
         " | TP=",
         DoubleToString(finalTP, Digits),
         " | estRisk=",
         DoubleToString(estimatedRiskMoney, 2)
      );

      ResetLastError();

      int ticket =
         OrderSend(
            Symbol(),
            command,
            lots,
            entryPrice,
            SlippagePoints(),
            finalSL,
            finalTP,
            tradeComment,
            MagicNumber,
            0,
            clrNONE
         );

      if(ticket >= 0)
      {
         double actualEntry = entryPrice;

         if(OrderSelect(
               ticket,
               SELECT_BY_TICKET))
         {
            actualEntry = OrderOpenPrice();
         }

         double actualRisk =
            CalculateMoneyRisk(
               lots,
               actualEntry,
               finalSL
            );

         // Post-fill risk sanity check.
         double riskBudget =
            AccountEquity() *
            (RiskPercent / 100.0);

         if(!UseFixedLot &&
            actualRisk >
            riskBudget * 1.05)
         {
            Print(
               "POST-FILL RISK GUARD | actual=",
               DoubleToString(actualRisk, 2),
               " budget=",
               DoubleToString(riskBudget, 2),
               " | closing ticket ",
               ticket
            );

            EmergencyCloseOrder(ticket);
            return(false);
         }

         ticketOut    = ticket;
         entryOut     = actualEntry;
         slOut        = finalSL;
         tpOut        = finalTP;
         lotsOut      = lots;
         riskMoneyOut = actualRisk;

         return(true);
      }

      int errorCode =
         GetLastError();

      ReportTradeError(
         "OrderSend attempt " +
         IntegerToString(attempt),
         errorCode
      );

      //-------------------------------------------------------------
      // ECN / invalid stops fallback
      //-------------------------------------------------------------
      if(errorCode == 130)
      {
         double ecnEntry = 0.0;
         double ecnSL    = 0.0;
         double ecnTP    = 0.0;

         int ecnTicket =
            SendECNFallback(
               command,
               lots,
               structuralSL,
               tradeComment,
               ecnEntry,
               ecnSL,
               ecnTP
            );

         if(ecnTicket < 0)
            return(false);

         double actualRisk =
            CalculateMoneyRisk(
               lots,
               ecnEntry,
               ecnSL
            );

         double riskBudget =
            AccountEquity() *
            (RiskPercent / 100.0);

         if(!UseFixedLot &&
            actualRisk >
            riskBudget * 1.05)
         {
            Print(
               "ECN POST-FILL RISK GUARD | closing ticket ",
               ecnTicket
            );

            EmergencyCloseOrder(ecnTicket);
            return(false);
         }

         ticketOut    = ecnTicket;
         entryOut     = ecnEntry;
         slOut        = ecnSL;
         tpOut        = ecnTP;
         lotsOut      = lots;
         riskMoneyOut = actualRisk;

         return(true);
      }

      if(IsTransientTradeError(errorCode) &&
         attempt < MAX_SEND_RETRIES)
      {
         Sleep(300);
         RefreshRates();
         continue;
      }

      return(false);
   }

   return(false);
}


//====================================================================
// ENGINE B POSITION SIZING / EXECUTION
//====================================================================
double CalculateLotSizeForRisk(
   double riskPercent,
   int command,
   double entryPrice,
   double stopLoss,
   double &estimatedRiskMoney
)
{
   estimatedRiskMoney = 0.0;

   if(UseFixedLot)
   {
      double fixedLots =
         NormalizeLot(FixedLotSize);

      if(fixedLots <= 0.0)
         return(0.0);

      estimatedRiskMoney =
         CalculateMoneyRisk(
            fixedLots,
            entryPrice,
            stopLoss
         );

      return(fixedLots);
   }

   double stopDistance =
      MathAbs(entryPrice - stopLoss);

   if(stopDistance <= 0.0)
      return(0.0);

   double tickValue =
      MarketInfo(Symbol(), MODE_TICKVALUE);

   double tickSizePrice =
      TickSizePrice();

   if(tickValue <= 0.0 ||
      tickSizePrice <= 0.0)
      return(0.0);

   double riskBudget =
      AccountEquity() *
      (riskPercent / 100.0);

   double lossPerLot =
      (stopDistance / tickSizePrice) *
      tickValue;

   if(lossPerLot <= 0.0)
      return(0.0);

   double rawLots =
      riskBudget / lossPerLot;

   double lots =
      NormalizeLot(rawLots);

   if(lots <= 0.0)
      return(0.0);

   estimatedRiskMoney =
      CalculateMoneyRisk(
         lots,
         entryPrice,
         stopLoss
      );

   return(lots);
}

//+------------------------------------------------------------------+
int SendECNFallbackForEngine(
   int command,
   double lots,
   double structuralSL,
   string tradeComment,
   int magicNumber,
   double &fillPriceOut,
   double &finalSLOut,
   double &finalTPOut
)
{
   fillPriceOut = 0.0;
   finalSLOut   = 0.0;
   finalTPOut   = 0.0;

   RefreshRates();

   if(!IsSpreadAcceptable())
      return(-1);

   double price =
      NormalizePrice(
         command == OP_BUY ? Ask : Bid
      );

   ResetLastError();

   int ticket =
      OrderSend(
         Symbol(),
         command,
         lots,
         price,
         SlippagePoints(),
         0,
         0,
         tradeComment,
         magicNumber,
         0,
         clrNONE
      );

   if(ticket < 0)
   {
      ReportTradeError(
         "Engine B ECN OrderSend",
         GetLastError()
      );
      return(-1);
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      EmergencyCloseOrder(ticket);
      return(-1);
   }

   double fillPrice =
      OrderOpenPrice();

   double finalSL = 0.0;
   double finalTP = 0.0;

   if(!BuildBrokerSafeStops(
         command,
         fillPrice,
         structuralSL,
         finalSL,
         finalTP))
   {
      EmergencyCloseOrder(ticket);
      return(-1);
   }

   ResetLastError();

   if(!OrderModify(
         ticket,
         fillPrice,
         finalSL,
         finalTP,
         0,
         clrNONE))
   {
      ReportTradeError(
         "Engine B ECN OrderModify",
         GetLastError()
      );
      EmergencyCloseOrder(ticket);
      return(-1);
   }

   fillPriceOut = fillPrice;
   finalSLOut   = finalSL;
   finalTPOut   = finalTP;

   return(ticket);
}

//+------------------------------------------------------------------+
bool ExecuteMarketTradeForEngine(
   int direction,
   double structuralSL,
   string tradeComment,
   int magicNumber,
   double riskPercent,
   int maxOpenTradesForEngine,
   int &ticketOut,
   double &entryOut,
   double &slOut,
   double &tpOut,
   double &lotsOut,
   double &riskMoneyOut
)
{
   ticketOut    = -1;
   entryOut     = 0.0;
   slOut        = 0.0;
   tpOut        = 0.0;
   lotsOut      = 0.0;
   riskMoneyOut = 0.0;

   int command;

   if(direction == DIR_BULL)
      command = OP_BUY;
   else if(direction == DIR_BEAR)
      command = OP_SELL;
   else
      return(false);

   if(CountOpenTradesByMagic(magicNumber) >= maxOpenTradesForEngine)
      return(false);

   if(CountAllEngineOpenTrades() >= MaxOpenTradesTotal)
      return(false);

   for(int attempt = 1;
       attempt <= MAX_SEND_RETRIES;
       attempt++)
   {
      RefreshRates();

      if(!IsSpreadAcceptable())
         return(false);

      double entryPrice =
         NormalizePrice(
            command == OP_BUY ? Ask : Bid
         );

      double finalSL = 0.0;
      double finalTP = 0.0;

      if(!BuildBrokerSafeStops(
            command,
            entryPrice,
            structuralSL,
            finalSL,
            finalTP))
         return(false);

      double estimatedRiskMoney = 0.0;

      double lots =
         CalculateLotSizeForRisk(
            riskPercent,
            command,
            entryPrice,
            finalSL,
            estimatedRiskMoney
         );

      if(lots <= 0.0)
         return(false);

      if(!UseFixedLot)
      {
         double maxCombinedMoney =
            AccountEquity() *
            (MaxCombinedOpenRiskPercent / 100.0);

         if(CurrentCombinedOpenRiskMoney() +
            estimatedRiskMoney >
            maxCombinedMoney * 1.01)
         {
            DebugPrint(
               "B SKIP | actual combined risk cap before OrderSend."
            );
            return(false);
         }
      }

      ResetLastError();

      int ticket =
         OrderSend(
            Symbol(),
            command,
            lots,
            entryPrice,
            SlippagePoints(),
            finalSL,
            finalTP,
            tradeComment,
            magicNumber,
            0,
            clrNONE
         );

      if(ticket >= 0)
      {
         double actualEntry = entryPrice;

         if(OrderSelect(ticket, SELECT_BY_TICKET))
            actualEntry = OrderOpenPrice();

         double actualRisk =
            CalculateMoneyRisk(
               lots,
               actualEntry,
               finalSL
            );

         double riskBudget =
            AccountEquity() *
            (riskPercent / 100.0);

         if(!UseFixedLot &&
            actualRisk > riskBudget * 1.05)
         {
            EmergencyCloseOrder(ticket);
            return(false);
         }

         ticketOut    = ticket;
         entryOut     = actualEntry;
         slOut        = finalSL;
         tpOut        = finalTP;
         lotsOut      = lots;
         riskMoneyOut = actualRisk;

         return(true);
      }

      int errorCode =
         GetLastError();

      ReportTradeError(
         "Engine B OrderSend attempt " +
         IntegerToString(attempt),
         errorCode
      );

      if(errorCode == 130)
      {
         double ecnEntry = 0.0;
         double ecnSL    = 0.0;
         double ecnTP    = 0.0;

         int ecnTicket =
            SendECNFallbackForEngine(
               command,
               lots,
               structuralSL,
               tradeComment,
               magicNumber,
               ecnEntry,
               ecnSL,
               ecnTP
            );

         if(ecnTicket < 0)
            return(false);

         double actualRisk =
            CalculateMoneyRisk(
               lots,
               ecnEntry,
               ecnSL
            );

         double riskBudget =
            AccountEquity() *
            (riskPercent / 100.0);

         if(!UseFixedLot &&
            actualRisk > riskBudget * 1.05)
         {
            EmergencyCloseOrder(ecnTicket);
            return(false);
         }

         ticketOut    = ecnTicket;
         entryOut     = ecnEntry;
         slOut        = ecnSL;
         tpOut        = ecnTP;
         lotsOut      = lots;
         riskMoneyOut = actualRisk;

         return(true);
      }

      if(IsTransientTradeError(errorCode) &&
         attempt < MAX_SEND_RETRIES)
      {
         Sleep(300);
         RefreshRates();
         continue;
      }

      return(false);
   }

   return(false);
}

//====================================================================
// CSV INITIALIZATION
//====================================================================
void InitCSV()
{
   int handle = INVALID_HANDLE;

   // In Strategy Tester start with a fresh file for each run.
   if(IsTesting())
   {
      handle =
         FileOpen(
            ResolveCSVFileNameA(),
            FILE_CSV |
            FILE_WRITE,
            ';'
         );
   }
   else
   {
      handle =
         FileOpen(
            ResolveCSVFileNameA(),
            FILE_CSV |
            FILE_READ |
            FILE_WRITE |
            FILE_SHARE_READ |
            FILE_SHARE_WRITE,
            ';'
         );
   }

   if(handle == INVALID_HANDLE)
   {
      Print(
         "CSV ERROR: cannot open ",
         ResolveCSVFileNameA(),
         " | error=",
         GetLastError()
      );
      return;
   }

   bool writeHeader =
      (FileSize(handle) == 0);

   if(writeHeader)
   {
      FileWrite(
         handle,
         "Event",
         "Time",
         "Ticket",
         "Direction",
         "H1Bias",
         "M15Structure",
         "HasOB",
         "HasIFVG",
         "ZoneUsed",
         "ZoneLow",
         "ZoneHigh",
         "RangeLow",
         "Equilibrium",
         "RangeHigh",
         "ReferenceLiquidity",
         "SweepExtreme",
         "ConfirmClose",
         "Entry",
         "SL",
         "TP",
         "RR",
         "RiskPercent",
         "RiskMoney",
         "Lots",
         "SpreadPips",
         "Profit",
         "Swap",
         "Commission",
         "Trigger",
         "Comment"
      );
   }

   FileClose(handle);
}


//====================================================================
// ENGINE B CSV INITIALIZATION
//====================================================================
void InitCSVB()
{
   int handle = INVALID_HANDLE;

   if(IsTesting())
   {
      handle =
         FileOpen(
            ResolveCSVFileNameB(),
            FILE_CSV |
            FILE_WRITE,
            ';'
         );
   }
   else
   {
      handle =
         FileOpen(
            ResolveCSVFileNameB(),
            FILE_CSV |
            FILE_READ |
            FILE_WRITE |
            FILE_SHARE_READ |
            FILE_SHARE_WRITE,
            ';'
         );
   }

   if(handle == INVALID_HANDLE)
   {
      Print(
         "CSV B ERROR: cannot open ",
         ResolveCSVFileNameB(),
         " | error=",
         GetLastError()
      );
      return;
   }

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "Event",
         "Time",
         "Ticket",
         "Direction",
         "H4Bias",
         "H1Structure",
         "HasOB",
         "HasIFVG",
         "ZoneUsed",
         "ZoneLow",
         "ZoneHigh",
         "RangeLow",
         "Equilibrium",
         "RangeHigh",
         "ReferenceLiquidity",
         "SweepExtreme",
         "ConfirmClose",
         "Entry",
         "SL",
         "TP",
         "RR",
         "RiskPercent",
         "RiskMoney",
         "Lots",
         "SpreadPips",
         "Profit",
         "Swap",
         "Commission",
         "Trigger",
         "Comment"
      );
   }

   FileClose(handle);
}

//====================================================================
// CSV OPEN EVENT
//====================================================================
void CSVWriteOpen(
   int ticket,
   int direction,
   int h1Bias,
   int m15Structure,
   bool hasOB,
   bool hasIFVG,
   string zoneUsed,
   double zoneLow,
   double zoneHigh,
   double rangeLow,
   double equilibrium,
   double rangeHigh,
   double referenceLiquidity,
   double sweepExtreme,
   double confirmClose,
   double entry,
   double sl,
   double tp,
   double lots,
   double riskMoney,
   string triggerReason,
   string commentText
)
{
   if(!EnableCSVLog)
      return;

   int handle =
      FileOpen(
         ResolveCSVFileNameA(),
         FILE_CSV |
         FILE_READ |
         FILE_WRITE |
         FILE_SHARE_READ |
         FILE_SHARE_WRITE,
         ';'
      );

   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle, 0, SEEK_END);

   FileWrite(
      handle,
      "OPEN",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      ticket,
      DirectionToString(direction),
      DirectionToString(h1Bias),
      DirectionToString(m15Structure),
      BoolText(hasOB),
      BoolText(hasIFVG),
      zoneUsed,
      DoubleToString(zoneLow, Digits),
      DoubleToString(zoneHigh, Digits),
      DoubleToString(rangeLow, Digits),
      DoubleToString(equilibrium, Digits),
      DoubleToString(rangeHigh, Digits),
      DoubleToString(referenceLiquidity, Digits),
      DoubleToString(sweepExtreme, Digits),
      DoubleToString(confirmClose, Digits),
      DoubleToString(entry, Digits),
      DoubleToString(sl, Digits),
      DoubleToString(tp, Digits),
      DoubleToString(MinRVRatio, 2),
      DoubleToString(RiskPercent, 2),
      DoubleToString(riskMoney, 2),
      DoubleToString(lots, 3),
      DoubleToString(GetSpreadPips(), 2),
      "",
      "",
      "",
      triggerReason,
      commentText
   );

   FileClose(handle);
}

//====================================================================
// CSV REJECT EVENT
//====================================================================
void CSVWriteRejected(
   int direction,
   int h1Bias,
   int m15Structure,
   bool hasOB,
   bool hasIFVG,
   double referenceLiquidity,
   double sweepExtreme,
   double confirmClose,
   string reason
)
{
   if(!EnableCSVLog)
      return;

   int handle =
      FileOpen(
         ResolveCSVFileNameA(),
         FILE_CSV |
         FILE_READ |
         FILE_WRITE |
         FILE_SHARE_READ |
         FILE_SHARE_WRITE,
         ';'
      );

   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle, 0, SEEK_END);

   FileWrite(
      handle,
      "REJECT",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      "",
      DirectionToString(direction),
      DirectionToString(h1Bias),
      DirectionToString(m15Structure),
      BoolText(hasOB),
      BoolText(hasIFVG),
      "",
      "",
      "",
      "",
      "",
      "",
      DoubleToString(referenceLiquidity, Digits),
      DoubleToString(sweepExtreme, Digits),
      DoubleToString(confirmClose, Digits),
      "",
      "",
      "",
      DoubleToString(MinRVRatio, 2),
      DoubleToString(RiskPercent, 2),
      "",
      "",
      DoubleToString(GetSpreadPips(), 2),
      "",
      "",
      "",
      "",
      reason
   );

   FileClose(handle);
}


//====================================================================
// ENGINE B CSV OPEN / REJECT
//====================================================================
void CSVWriteOpenB(
   int ticket,
   int direction,
   int h4Bias,
   int h1Structure,
   bool hasOB,
   bool hasIFVG,
   string zoneUsed,
   double zoneLow,
   double zoneHigh,
   double rangeLow,
   double equilibrium,
   double rangeHigh,
   double referenceLiquidity,
   double sweepExtreme,
   double confirmClose,
   double entry,
   double sl,
   double tp,
   double lots,
   double riskMoney,
   string triggerReason,
   string commentText
)
{
   if(!EnableCSVLog)
      return;

   int handle =
      FileOpen(
         ResolveCSVFileNameB(),
         FILE_CSV |
         FILE_READ |
         FILE_WRITE |
         FILE_SHARE_READ |
         FILE_SHARE_WRITE,
         ';'
      );

   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle, 0, SEEK_END);

   FileWrite(
      handle,
      "OPEN",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      ticket,
      DirectionToString(direction),
      DirectionToString(h4Bias),
      DirectionToString(h1Structure),
      BoolText(hasOB),
      BoolText(hasIFVG),
      zoneUsed,
      DoubleToString(zoneLow, Digits),
      DoubleToString(zoneHigh, Digits),
      DoubleToString(rangeLow, Digits),
      DoubleToString(equilibrium, Digits),
      DoubleToString(rangeHigh, Digits),
      DoubleToString(referenceLiquidity, Digits),
      DoubleToString(sweepExtreme, Digits),
      DoubleToString(confirmClose, Digits),
      DoubleToString(entry, Digits),
      DoubleToString(sl, Digits),
      DoubleToString(tp, Digits),
      DoubleToString(MinRVRatio, 2),
      DoubleToString(EngineBRiskPercent, 2),
      DoubleToString(riskMoney, 2),
      DoubleToString(lots, 3),
      DoubleToString(GetSpreadPips(), 2),
      "",
      "",
      "",
      triggerReason,
      commentText
   );

   FileClose(handle);
}

//+------------------------------------------------------------------+
void CSVWriteRejectedB(
   int direction,
   int h4Bias,
   int h1Structure,
   bool hasOB,
   bool hasIFVG,
   double referenceLiquidity,
   double sweepExtreme,
   double confirmClose,
   string reason
)
{
   if(!EnableCSVLog)
      return;

   int handle =
      FileOpen(
         ResolveCSVFileNameB(),
         FILE_CSV |
         FILE_READ |
         FILE_WRITE |
         FILE_SHARE_READ |
         FILE_SHARE_WRITE,
         ';'
      );

   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle, 0, SEEK_END);

   FileWrite(
      handle,
      "REJECT",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      "",
      DirectionToString(direction),
      DirectionToString(h4Bias),
      DirectionToString(h1Structure),
      BoolText(hasOB),
      BoolText(hasIFVG),
      "",
      "",
      "",
      "",
      "",
      "",
      DoubleToString(referenceLiquidity, Digits),
      DoubleToString(sweepExtreme, Digits),
      DoubleToString(confirmClose, Digits),
      "",
      "",
      "",
      DoubleToString(MinRVRatio, 2),
      DoubleToString(EngineBRiskPercent, 2),
      "",
      "",
      DoubleToString(GetSpreadPips(), 2),
      "",
      "",
      "",
      "",
      reason
   );

   FileClose(handle);
}

//====================================================================
// CLOSED-TICKET MEMORY
//====================================================================
bool IsClosedTicketLogged(ulong ticket)
{
   for(int i = 0;
       i < g_loggedClosedCount;
       i++)
   {
      if(g_loggedClosedTickets[i] == ticket)
         return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
void MarkClosedTicketLogged(ulong ticket)
{
   int newSize =
      g_loggedClosedCount + 1;

   ArrayResize(
      g_loggedClosedTickets,
      newSize
   );

   g_loggedClosedTickets[
      g_loggedClosedCount
   ] = ticket;

   g_loggedClosedCount =
      newSize;
}

//====================================================================
// CLOSED TRADE CSV LOGGING
//====================================================================
void LogClosedTrades()
{
   if(!EnableCSVLog)
      return;

   int total =
      OrdersHistoryTotal();

   if(total <= g_lastHistoryTotal)
      return;

   int startPos =
      g_lastHistoryTotal;

   if(startPos < 0)
      startPos = 0;

   for(int pos = startPos;
       pos < total;
       pos++)
   {
      if(!OrderSelect(
            pos,
            SELECT_BY_POS,
            MODE_HISTORY))
      {
         continue;
      }

      if(OrderSymbol() != Symbol())
         continue;

      string targetCSV = "";

      if(OrderMagicNumber() == MagicNumber)
         targetCSV = ResolveCSVFileNameA();
      else if(OrderMagicNumber() == EngineBMagicNumber)
         targetCSV = ResolveCSVFileNameB();
      else
         continue;

      if(OrderType() != OP_BUY &&
         OrderType() != OP_SELL)
      {
         continue;
      }

      ulong ticket =
         OrderTicket();

      if(IsClosedTicketLogged(ticket))
         continue;

      int handle =
         FileOpen(
            targetCSV,
            FILE_CSV |
            FILE_READ |
            FILE_WRITE |
            FILE_SHARE_READ |
            FILE_SHARE_WRITE,
            ';'
         );

      if(handle == INVALID_HANDLE)
         return;

      FileSeek(handle, 0, SEEK_END);

      double netProfit =
         OrderProfit() +
         OrderSwap() +
         OrderCommission();

      FileWrite(
         handle,
         "CLOSE",
         TimeToString(OrderCloseTime(), TIME_DATE | TIME_SECONDS),
         ticket,
         (OrderType() == OP_BUY ? "BULLISH" : "BEARISH"),
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         "",
         DoubleToString(OrderOpenPrice(), Digits),
         DoubleToString(OrderStopLoss(), Digits),
         DoubleToString(OrderTakeProfit(), Digits),
         "",
         "",
         "",
         DoubleToString(OrderLots(), 3),
         "",
         DoubleToString(netProfit, 2),
         DoubleToString(OrderSwap(), 2),
         DoubleToString(OrderCommission(), 2),
         "",
         OrderComment()
      );

      FileClose(handle);

      MarkClosedTicketLogged(ticket);
   }

   g_lastHistoryTotal = total;
}
//+------------------------------------------------------------------+

