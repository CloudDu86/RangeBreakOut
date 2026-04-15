//+------------------------------------------------------------------+
//|                                             TimeRangeEA_V1.5.mq5 |
//|                                 Copyright 2023, MetaQuotes Ltd.  |
//|                                          https://www.mql5.com   |
//+------------------------------------------------------------------+
// V1.5 Changes vs V1.4:
//   [1] MA Type input: SMA or EMA selectable via InpMAType
//   [2] Break-even stop: InpBETrigger (Range multiplier, 0=off)
//   [3] Entry window filter: InpEntryWindowStart / InpEntryWindowEnd (minutes from 00:00 server time)
//
// B1 fix retained: CopyBuffer(maHandle, 0, 1, 2, maBuffer)  — shift=1, completed bars only
// B2 fix retained: angle reset to 0 when MA is flat
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.50"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "===== General Inputs ====="
input long   InpMagicNumber  = 1234567;  // magic number

enum LOT_MODE_ENUM {
   LOT_MODE_FIXED,          // fixed lots
   LOT_MODE_MONEY,          // lots based on money
   LOT_MODE_PCT_ACCOUT      // lots based on % of account
};
input LOT_MODE_ENUM InpLotMode    = LOT_MODE_PCT_ACCOUT;  // lot mode
input double        InpLots       = 2;                    // lots / money / risk %
input int           InpStopLoss   = 100;                  // stop loss in % of the range {0=off}
input int           InpTakeProfit = 0;                    // take profit in % of the range {0=off}
input double        InpMaxDD      = 0.0;                  // Trade stop when equity hits DD%

input group "===== Range Inputs ====="
input int  InpRangeStart    = 120;   // range start time in minutes from 00:00
input int  InpRangeDuration = 120;   // range duration in minutes
input int  InpRangeClose    = 1200;  // range close time in minutes from 00:00 (-1=off)

enum BREAKOUT_MODE_ENUM {
   ONE_SIGNAL,    // one breakout per range
   TWO_SIGNALS    // high and low breakout
};
input BREAKOUT_MODE_ENUM InpBreakoutMode = ONE_SIGNAL;  // breakout mode

input group "===== Time Filter ====="
input bool InpMonday         = true;  // range on Monday
input bool InpTuesday        = true;  // range on Tuesday
input bool InpWendsday       = true;  // range on Wednesday
input bool InpThursday       = true;  // range on Thursday
input bool InpFriday         = true;  // range on Friday
input bool InpNenmatsunenshi = true;  // 年末年始スキップ (12/18-1/7)
input bool InpEconomicEvent  = true;  // Economic news filter

//--- [3] Entry window: only allow new entries during this server-time window
input group "===== Entry Window ====="
input int  InpEntryWindowStart = 0;     // entry window start (min from 00:00, 0=disabled)
input int  InpEntryWindowEnd   = 1440;  // entry window end   (min from 00:00, 1440=disabled)

input group "===== MA Filter ====="
input bool            InpMAFilter = false;       // MA filter enable
input ENUM_TIMEFRAMES InpMATime   = PERIOD_M15;  // MA Time Frame

//--- [1] MA Type selection
enum MA_TYPE_ENUM {
   MA_TYPE_SMA,   // SMA
   MA_TYPE_EMA    // EMA
};
input MA_TYPE_ENUM InpMAType   = MA_TYPE_SMA;  // MA Type (SMA / EMA)
input int          InpMAPeriod = 200;           // MA Period

//--- [2] Break-even stop
input group "===== Risk Management ====="
input double InpBETrigger = 0.0;  // Break-even trigger (x Range width, 0=off)

input group "===== Strategy ====="
input bool InpReverse = false;    // Reverse strategy

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
struct RANGE_STRUCT {
   datetime start_time;
   datetime end_time;
   datetime close_time;
   double   high;
   double   low;
   bool     f_entry;
   bool     f_high_breakout;
   bool     f_low_breakout;

   RANGE_STRUCT() : start_time(0), end_time(0), close_time(0),
                    high(0), low(DBL_MAX), f_entry(false),
                    f_high_breakout(false), f_low_breakout(false) {}
};

double      maxBalance = 0.0;
RANGE_STRUCT range;
MqlTick     prevTick, lastTick;
CTrade      trade;
int         maHandle;
double      maBuffer[];
double      angle = 90;  // MA slope state (B2 fix: reset to 0 when flat)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   maxBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if (!CheckInputs()) { return INIT_PARAMETERS_INCORRECT; }

   trade.SetExpertMagicNumber(InpMagicNumber);

   if (_UninitReason == REASON_PARAMETERS && CountOpenPosition() == 0)
   {
      CalculateRange();
   }

   DrawObjects();

   // [1] Create MA handle — SMA or EMA based on InpMAType
   ENUM_MA_METHOD maMethod = (InpMAType == MA_TYPE_EMA) ? MODE_EMA : MODE_SMA;
   maHandle = iMA(_Symbol, InpMATime, InpMAPeriod, 0, maMethod, PRICE_CLOSE);
   if (maHandle == INVALID_HANDLE)
   {
      Alert("Failed to create MA handle");
      return INIT_FAILED;
   }

   ArraySetAsSeries(maBuffer, true);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(NULL, "range");
   if (maHandle != INVALID_HANDLE) { IndicatorRelease(maHandle); }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if (!IsNewBar()) { return; }

   // Max drawdown check
   if (InpMaxDD > 0 && AccountInfoDouble(ACCOUNT_BALANCE) < (maxBalance * InpMaxDD * 0.01))
   {
      return;
   }

   prevTick = lastTick;
   SymbolInfoTick(_Symbol, lastTick);

   // [2] Break-even stop management (runs every new bar)
   if (InpBETrigger > 0 && InpStopLoss > 0)
   {
      ManageBreakEven();
   }

   // Range high/low accumulation
   if (lastTick.time >= range.start_time && lastTick.time < range.end_time)
   {
      range.f_entry = true;

      if (lastTick.ask > range.high)
      {
         range.high = lastTick.ask;
         DrawObjects();
      }
      if (lastTick.bid < range.low)
      {
         range.low = lastTick.bid;
         DrawObjects();
      }
   }

   // Close positions at range close time
   if (InpRangeClose >= 0 && lastTick.time >= range.close_time)
   {
      if (!ClosePositions()) { return; }
   }

   // Close positions on important economic event
   if (InpEconomicEvent == true && IsImportantEvent() == true)
   {
      if (!ClosePositions()) { return; }
   }

   // Recalculate range when needed
   if (((InpRangeClose >= 0 && lastTick.time >= range.close_time)
      || (range.f_high_breakout && range.f_low_breakout)
      || (range.end_time == 0)
      || (range.end_time != 0 && lastTick.time > range.end_time && !range.f_entry))
      && CountOpenPosition() == 0)
   {
      CalculateRange();
   }

   CheckBreakouts();
}

//+------------------------------------------------------------------+
//| [2] Break-even stop: move SL to entry once profit >= BETrigger   |
//|     Uses server-side tick prices; runs on each new bar open.     |
//|     Only moves SL forward (never back toward loss).              |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if (range.high <= range.low || range.low == DBL_MAX) return;

   double rangeWidth    = range.high - range.low;
   double beTriggerDist = rangeWidth * InpBETrigger;

   int total = PositionsTotal();
   for (int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket <= 0) continue;
      if (!PositionSelectByTicket(ticket)) continue;

      long magic;
      if (!PositionGetInteger(POSITION_MAGIC, magic)) continue;
      if (magic != InpMagicNumber) continue;

      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if (posType == POSITION_TYPE_BUY)
      {
         // Trigger level: entry + (range * BETrigger)
         double beLevel = NormalizeDouble(openPrice + beTriggerDist, _Digits);
         // Move SL to entry only if not already at or above entry
         if (lastTick.bid >= beLevel && currentSL < openPrice)
         {
            trade.PositionModify(ticket, NormalizeDouble(openPrice, _Digits), currentTP);
         }
      }
      else if (posType == POSITION_TYPE_SELL)
      {
         // Trigger level: entry - (range * BETrigger)
         double beLevel = NormalizeDouble(openPrice - beTriggerDist, _Digits);
         // Move SL to entry only if not already at or below entry (SL==0 means no SL set)
         if (lastTick.ask <= beLevel && (currentSL > openPrice || currentSL == 0))
         {
            trade.PositionModify(ticket, NormalizeDouble(openPrice, _Digits), currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [3] Entry window check: is current server time within window?   |
//|     Window disabled when Start=0 and End=1440 (default).        |
//+------------------------------------------------------------------+
bool IsInEntryWindow()
{
   if (InpEntryWindowStart == 0 && InpEntryWindowEnd == 1440) return true;

   MqlDateTime tm;
   TimeToStruct(lastTick.time, tm);
   int minutesOfDay = tm.hour * 60 + tm.min;

   return (minutesOfDay >= InpEntryWindowStart && minutesOfDay < InpEntryWindowEnd);
}

//+------------------------------------------------------------------+
//| Check user inputs                                                |
//+------------------------------------------------------------------+
bool CheckInputs()
{
   if (InpMagicNumber <= 0) {
      Alert("Magicnumber <= 0"); return false;
   }
   if (InpLotMode == LOT_MODE_FIXED && InpLots <= 0) {
      Alert("Lots <= 0"); return false;
   }
   if (InpLotMode == LOT_MODE_MONEY && InpLots <= 0) {
      Alert("Lots <= 0"); return false;
   }
   if (InpLotMode == LOT_MODE_PCT_ACCOUT && (InpLots <= 0 || InpLots > 5)) {
      Alert("Lots <= 0 or > 5"); return false;
   }
   if (InpStopLoss < 0 || InpStopLoss > 1000) {
      Alert("stop loss < 0 or > 1000"); return false;
   }
   if (InpTakeProfit < 0) {
      Alert("take profit < 0"); return false;
   }
   if (InpRangeClose < 0 && InpStopLoss == 0) {
      Alert("close time and stop loss is off"); return false;
   }
   if (InpRangeStart < 0 || InpRangeStart >= 1440) {
      Alert("Range start < 0 or >= 1440"); return false;
   }
   if (InpRangeDuration <= 0 || InpRangeDuration >= 1440) {
      Alert("Range duration <= 0 or >= 1440"); return false;
   }
   if (InpRangeClose >= 1440 || (InpRangeStart + InpRangeDuration) % 1440 == InpRangeClose) {
      Alert("Close time >= 1440 or end time == close time"); return false;
   }
   if (InpMonday + InpTuesday + InpWendsday + InpThursday + InpFriday == 0) {
      Alert("Range is prohibited on all days of the week"); return false;
   }
   if (InpEntryWindowStart < 0 || InpEntryWindowStart >= 1440) {
      Alert("Entry window start must be 0-1439"); return false;
   }
   if (InpEntryWindowEnd <= 0 || InpEntryWindowEnd > 1440) {
      Alert("Entry window end must be 1-1440"); return false;
   }
   if (InpEntryWindowStart >= InpEntryWindowEnd) {
      Alert("Entry window start must be < entry window end"); return false;
   }
   if (InpBETrigger < 0) {
      Alert("BE trigger must be >= 0"); return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Calculate a new range                                            |
//+------------------------------------------------------------------+
void CalculateRange()
{
   range.start_time      = 0;
   range.end_time        = 0;
   range.close_time      = 0;
   range.high            = 0.0;
   range.low             = DBL_MAX;
   range.f_entry         = false;
   range.f_high_breakout = false;
   range.f_low_breakout  = false;

   datetime curr_time   = TimeCurrent();
   int      curr_year   = TimeYear(curr_time);

   datetime start_holiday_nenshi   = StringToTime(StringFormat("%d.01.07 23:59", curr_year));
   datetime start_holiday_nenmatsu = StringToTime(StringFormat("%d.12.18 00:00", curr_year));

   int time_cycle = 86400;
   range.start_time = (lastTick.time - (lastTick.time % time_cycle)) + InpRangeStart * 60 + SummerWinterTimeShift() * 3600;

   if (!InpNenmatsunenshi && lastTick.time > start_holiday_nenshi && lastTick.time < start_holiday_nenmatsu)
   {
      return;
   }
   else
   {
      for (int i = 0; i < 8; i++)
      {
         MqlDateTime tmp;
         TimeToStruct(range.start_time, tmp);
         int dow = tmp.day_of_week;

         if (lastTick.time >= range.start_time || dow == 6 || dow == 0
            || (dow == 1 && !InpMonday)    || (dow == 2 && !InpTuesday)
            || (dow == 3 && !InpWendsday)  || (dow == 4 && !InpThursday)
            || (dow == 5 && !InpFriday))
         {
            range.start_time += time_cycle;
         }
      }

      // calculate range end time
      range.end_time = range.start_time + InpRangeDuration * 60;
      for (int i = 0; i < 2; i++)
      {
         MqlDateTime tmp;
         TimeToStruct(range.start_time, tmp);
         int dow = tmp.day_of_week;
         if (dow == 6 || dow == 0) { range.end_time += time_cycle; }
      }

      // calculate range close time
      if (InpRangeClose >= 0)
      {
         range.close_time = (range.end_time - (range.end_time % time_cycle)) + InpRangeClose * 60;
         for (int i = 0; i < 3; i++)
         {
            MqlDateTime tmp;
            TimeToStruct(range.close_time, tmp);
            int dow = tmp.day_of_week;
            if (range.close_time <= range.end_time || dow == 6 || dow == 0)
            {
               range.close_time += time_cycle;
            }
         }
      }
   }

   DrawObjects();
}

//+------------------------------------------------------------------+
//| Count all open positions managed by this EA                     |
//+------------------------------------------------------------------+
int CountOpenPosition()
{
   int counter = 0;
   int total   = PositionsTotal();
   for (int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket <= 0) { Print("Failed to get position ticket"); return -1; }
      if (!PositionSelectByTicket(ticket)) { Print("Failed to select position ticket"); return -1; }
      long magicNumber;
      if (!PositionGetInteger(POSITION_MAGIC, magicNumber)) { Print("Failed to get position magicNumber"); return -1; }
      if (magicNumber == InpMagicNumber) { counter++; }
   }
   return counter;
}

//+------------------------------------------------------------------+
//| Check breakout                                                   |
//+------------------------------------------------------------------+
void CheckBreakouts()
{
   if (lastTick.time >= range.end_time && range.end_time > 0 && range.f_entry)
   {
      if (InpReverse == false)   { rangeBreakOutEntry(); }
      else                       { rangeBreakOutReverseEntry(); }
   }
}

//+------------------------------------------------------------------+
//| Normal breakout entry                                            |
//+------------------------------------------------------------------+
void rangeBreakOutEntry()
{
   // [1] Read MA (B1 fix: shift=1 — only completed M15 bars)
   if (InpMAFilter == true)
   {
      int values = CopyBuffer(maHandle, 0, 1, 2, maBuffer);
      if (values != 2)
      {
         Print("Not enough data for moving average");
         return;
      }
      // [B2 fix] reset angle to 0 when MA is flat (no stale state)
      if (maBuffer[0] != maBuffer[1])
         angle = (MathArctan(maBuffer[0] - maBuffer[1]) * 180 / M_PI) * 100;
      else
         angle = 0;
   }

   //--- BUY: high breakout
   if ((!range.f_high_breakout && lastTick.ask >= range.high && InpMAFilter == false)
      || (!range.f_high_breakout && lastTick.ask >= range.high && InpMAFilter == true && angle > 0))
   {
      range.f_high_breakout = true;
      if (InpBreakoutMode == ONE_SIGNAL) { range.f_low_breakout = true; }

      // [3] Entry window check
      if (!IsInEntryWindow()) { return; }

      double sl = InpStopLoss == 0 ? 0 : NormalizeDouble(lastTick.bid - ((range.high - range.low) * InpStopLoss * 0.01), _Digits);
      double tp = InpTakeProfit == 0 ? 0 : NormalizeDouble(lastTick.bid + ((range.high - range.low) * InpTakeProfit * 0.01), _Digits);

      double lots;
      if (InpStopLoss == 0)
      {
         double tmpSL = NormalizeDouble(lastTick.bid - (range.high - range.low), _Digits);
         if (!CalculateLots(lastTick.bid - tmpSL, lots)) { return; }
      }
      else
      {
         if (!CalculateLots(lastTick.bid - sl, lots)) { return; }
      }

      double maxLotsPerEntry = 50.0;
      double times           = lots / maxLotsPerEntry;
      double remainderLots   = MathMod(lots, maxLotsPerEntry);

      if (lots > maxLotsPerEntry)
      {
         for (int i = 1; i < (int)times; i++)
         {
            trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, maxLotsPerEntry, lastTick.ask, sl, tp,
                               (string)AccountInfoDouble(ACCOUNT_BALANCE));
         }
         trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, remainderLots, lastTick.ask, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
      else
      {
         trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, lots, lastTick.ask, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
   }

   //--- SELL: low breakout
   if ((!range.f_low_breakout && lastTick.bid <= range.low && InpMAFilter == false)
      || (!range.f_low_breakout && lastTick.bid <= range.low && InpMAFilter == true && angle < 0))
   {
      range.f_low_breakout = true;
      if (InpBreakoutMode == ONE_SIGNAL) { range.f_high_breakout = true; }

      // [3] Entry window check
      if (!IsInEntryWindow()) { return; }

      double sl = InpStopLoss == 0 ? 0 : NormalizeDouble(lastTick.ask + ((range.high - range.low) * InpStopLoss * 0.01), _Digits);
      double tp = InpTakeProfit == 0 ? 0 : NormalizeDouble(lastTick.ask - ((range.high - range.low) * InpTakeProfit * 0.01), _Digits);

      double lots;
      if (InpStopLoss == 0)
      {
         double tmpSL = NormalizeDouble(lastTick.ask + (range.high - range.low), _Digits);
         if (!CalculateLots(tmpSL - lastTick.ask, lots)) { return; }
      }
      else
      {
         if (!CalculateLots(sl - lastTick.ask, lots)) { return; }
      }

      double maxLotsPerEntry = 50.0;
      double times           = lots / maxLotsPerEntry;
      double remainderLots   = MathMod(lots, maxLotsPerEntry);

      if (lots > maxLotsPerEntry)
      {
         for (int i = 1; i < (int)times; i++)
         {
            trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, maxLotsPerEntry, lastTick.bid, sl, tp,
                               (string)AccountInfoDouble(ACCOUNT_BALANCE));
         }
         trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, remainderLots, lastTick.bid, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
      else
      {
         trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, lots, lastTick.bid, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
   }
}

//+------------------------------------------------------------------+
//| Reverse breakout entry                                           |
//+------------------------------------------------------------------+
void rangeBreakOutReverseEntry()
{
   //--- High breakout → SELL (reverse)
   if (!range.f_high_breakout && lastTick.ask >= range.high)
   {
      range.f_high_breakout = true;
      if (InpBreakoutMode == ONE_SIGNAL) { range.f_low_breakout = true; }

      // [3] Entry window check
      if (!IsInEntryWindow()) { return; }

      double sl = InpStopLoss == 0 ? 0 : NormalizeDouble(lastTick.bid + ((range.high - range.low) * InpStopLoss * 0.01), _Digits);
      double tp = InpTakeProfit == 0 ? 0 : NormalizeDouble(lastTick.bid - ((range.high - range.low) * InpTakeProfit * 0.01), _Digits);

      double lots;
      if (InpStopLoss == 0)
      {
         double tmpSL = NormalizeDouble(lastTick.bid - (range.high - range.low), _Digits);
         if (!CalculateLots(sl - lastTick.bid, lots)) { return; }
      }
      else
      {
         if (!CalculateLots(sl - lastTick.bid, lots)) { return; }
      }

      double maxLotsPerEntry = 50.0;
      double times           = lots / maxLotsPerEntry;
      double remainderLots   = MathMod(lots, maxLotsPerEntry);

      if (lots > maxLotsPerEntry)
      {
         for (int i = 1; i < (int)times; i++)
         {
            trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, maxLotsPerEntry, lastTick.bid, sl, tp,
                               (string)AccountInfoDouble(ACCOUNT_BALANCE));
         }
         trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, remainderLots, lastTick.bid, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
      else
      {
         trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, lots, lastTick.bid, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
   }

   //--- Low breakout → BUY (reverse)
   if (!range.f_low_breakout && lastTick.bid <= range.low)
   {
      range.f_low_breakout = true;
      if (InpBreakoutMode == ONE_SIGNAL) { range.f_high_breakout = true; }

      // [3] Entry window check
      if (!IsInEntryWindow()) { return; }

      double sl = InpStopLoss == 0 ? 0 : NormalizeDouble(lastTick.ask - ((range.high - range.low) * InpStopLoss * 0.01), _Digits);
      double tp = InpTakeProfit == 0 ? 0 : NormalizeDouble(lastTick.ask + ((range.high - range.low) * InpTakeProfit * 0.01), _Digits);

      double lots;
      if (InpStopLoss == 0)
      {
         double tmpSL = NormalizeDouble(lastTick.ask + (range.high - range.low), _Digits);
         if (!CalculateLots(tmpSL - lastTick.ask, lots)) { return; }
      }
      else
      {
         if (!CalculateLots(lastTick.ask - sl, lots)) { return; }
      }

      double maxLotsPerEntry = 50.0;
      double times           = lots / maxLotsPerEntry;
      double remainderLots   = MathMod(lots, maxLotsPerEntry);

      if (lots > maxLotsPerEntry)
      {
         for (int i = 1; i < (int)times; i++)
         {
            trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, maxLotsPerEntry, lastTick.ask, sl, tp,
                               (string)AccountInfoDouble(ACCOUNT_BALANCE));
         }
         trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, remainderLots, lastTick.ask, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
      else
      {
         trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, lots, lastTick.ask, sl, tp,
                            (string)AccountInfoDouble(ACCOUNT_BALANCE));
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lots                                                   |
//+------------------------------------------------------------------+
bool CalculateLots(double slDistance, double &lots)
{
   lots = 0.0;
   if (InpLotMode == LOT_MODE_FIXED)
   {
      lots = InpLots;
   }
   else
   {
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      double riskMoney = (InpLotMode == LOT_MODE_MONEY)
                         ? InpLots
                         : AccountInfoDouble(ACCOUNT_EQUITY) * InpLots * 0.01;

      double moneyVolumeStep = (slDistance / tickSize) * tickValue * volumeStep;
      lots = MathFloor(riskMoney / moneyVolumeStep) * volumeStep;

      long   leverage     = AccountInfoInteger(ACCOUNT_LEVERAGE);
      double accountMoney = AccountInfoDouble(ACCOUNT_EQUITY);

      while (lots * 100000 > accountMoney * leverage * 0.95)
      {
         lots -= volumeStep;
      }

      Comment("riskMoney: ", riskMoney, "\n",
              "slDistance: ", slDistance, "\n",
              "tickSize: ", tickSize, "\n",
              "tickValue: ", tickValue, "\n",
              "volumeStep: ", volumeStep, "\n",
              "moneyVolumeStep: ", moneyVolumeStep, "\n",
              "lots: ", lots, "\n",
              "SummerWinterShift: ", SummerWinterTimeShift());
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check lots for min, max and step                                 |
//+------------------------------------------------------------------+
bool CheckLots(double &lots)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if (lots < minVol)
   {
      Print("Lot size will be set to the minimum allowable volume");
      lots = minVol;
      return true;
   }
   if (lots > maxVol)
   {
      Print("Lot size will be set to the maximum allowable volume. lots: ", lots, " max", maxVol);
      return false;
   }
   if (!CalculateMarginLots(lots)) { return false; }
   lots = (int)MathFloor(lots / step) * step;
   return true;
}

//+------------------------------------------------------------------+
//| Calculate margin                                                 |
//+------------------------------------------------------------------+
bool CalculateMarginLots(double &lots)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRate = 0.5;
   double lotSize    = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);

   while (true)
   {
      double marginRequired = SymbolInfoDouble(Symbol(), SYMBOL_MARGIN_INITIAL) * lotSize;
      if ((freeMargin - marginRequired) / freeMargin < marginRate)
      {
         lotSize -= SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
         if (lotSize < SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN))
         {
            return false;
         }
      }
      else
      {
         return true;
      }
   }
}

//+------------------------------------------------------------------+
//| Close all open positions managed by this EA                     |
//+------------------------------------------------------------------+
bool ClosePositions()
{
   int total = PositionsTotal();
   for (int i = total - 1; i >= 0; i--)
   {
      if (total != PositionsTotal()) { total = PositionsTotal(); i = total; continue; }
      ulong ticket = PositionGetTicket(i);
      if (ticket <= 0) { Print("Failed to get position ticket"); return false; }
      if (!PositionSelectByTicket(ticket)) { Print("Failed to select position by ticket"); return false; }
      long magicNumber;
      if (!PositionGetInteger(POSITION_MAGIC, magicNumber)) { Print("Failed to get Position magicNumber"); return false; }
      if (magicNumber == InpMagicNumber)
      {
         trade.PositionClose(ticket);
         double accountBalance = AccountInfoDouble(ACCOUNT_EQUITY);
         if (accountBalance > maxBalance) { maxBalance = accountBalance; }
         if (trade.ResultRetcode() != TRADE_RETCODE_DONE)
         {
            Print("Failed to close position. Result: " + (string)trade.ResultRetcode() + ":" + trade.ResultRetcodeDescription());
            return false;
         }
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Draw objects on chart                                            |
//+------------------------------------------------------------------+
void DrawObjects()
{
   // start
   ObjectDelete(NULL, "range start");
   if (range.start_time > 0) {
      ObjectCreate(NULL, "range start", OBJ_VLINE, 0, range.start_time, 0);
      ObjectSetString(NULL, "range start", OBJPROP_TOOLTIP, "start of the range \n" + TimeToString(range.start_time, TIME_DATE|TIME_MINUTES));
      ObjectSetInteger(NULL, "range start", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range start", OBJPROP_WIDTH, 2);
      ObjectSetInteger(NULL, "range start", OBJPROP_BACK, true);
   }

   // end
   ObjectDelete(NULL, "range end");
   if (range.end_time > 0) {
      ObjectCreate(NULL, "range end", OBJ_VLINE, 0, range.end_time, 0);
      ObjectSetString(NULL, "range end", OBJPROP_TOOLTIP, "end of the range \n" + TimeToString(range.end_time, TIME_DATE|TIME_MINUTES));
      ObjectSetInteger(NULL, "range end", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range end", OBJPROP_WIDTH, 2);
      ObjectSetInteger(NULL, "range end", OBJPROP_BACK, true);
   }

   // close
   ObjectDelete(NULL, "range close");
   if (range.close_time > 0) {
      ObjectCreate(NULL, "range close", OBJ_VLINE, 0, range.close_time, 0);
      ObjectSetString(NULL, "range close", OBJPROP_TOOLTIP, "close of the range \n" + TimeToString(range.close_time, TIME_DATE|TIME_MINUTES));
      ObjectSetInteger(NULL, "range close", OBJPROP_COLOR, clrRed);
      ObjectSetInteger(NULL, "range close", OBJPROP_WIDTH, 2);
      ObjectSetInteger(NULL, "range close", OBJPROP_BACK, true);
   }

   // high
   ObjectsDeleteAll(NULL, "range high");
   if (range.high > 0) {
      ObjectCreate(NULL, "range high", OBJ_TREND, 0, range.start_time, range.high, range.end_time, range.high);
      ObjectSetString(NULL, "range high", OBJPROP_TOOLTIP, "high of the range \n" + DoubleToString(range.high, _Digits));
      ObjectSetInteger(NULL, "range high", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range high", OBJPROP_WIDTH, 2);
      ObjectSetInteger(NULL, "range high", OBJPROP_BACK, true);

      ObjectCreate(NULL, "range high ", OBJ_TREND, 0, range.end_time, range.high, InpRangeClose >= 0 ? range.close_time : INT_MAX, range.high);
      ObjectSetString(NULL, "range high ", OBJPROP_TOOLTIP, "high of the range \n" + DoubleToString(range.high, _Digits));
      ObjectSetInteger(NULL, "range high ", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range high ", OBJPROP_BACK, true);
      ObjectSetInteger(NULL, "range high ", OBJPROP_STYLE, STYLE_DOT);
   }

   // low
   ObjectsDeleteAll(NULL, "range low");
   if (range.low < DBL_MAX) {
      ObjectCreate(NULL, "range low", OBJ_TREND, 0, range.start_time, range.low, range.end_time, range.low);
      ObjectSetString(NULL, "range low", OBJPROP_TOOLTIP, "low of the range \n" + DoubleToString(range.low, _Digits));
      ObjectSetInteger(NULL, "range low", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range low", OBJPROP_WIDTH, 2);
      ObjectSetInteger(NULL, "range low", OBJPROP_BACK, true);

      ObjectCreate(NULL, "range low ", OBJ_TREND, 0, range.end_time, range.low, InpRangeClose >= 0 ? range.close_time : INT_MAX, range.low);
      ObjectSetString(NULL, "range low ", OBJPROP_TOOLTIP, "low of the range \n" + DoubleToString(range.low, _Digits));
      ObjectSetInteger(NULL, "range low ", OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(NULL, "range low ", OBJPROP_BACK, true);
      ObjectSetInteger(NULL, "range low ", OBJPROP_STYLE, STYLE_DOT);
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Utility helpers                                                  |
//+------------------------------------------------------------------+
int TimeYear(datetime time)
{
   MqlDateTime mqlTime;
   TimeToStruct(time, mqlTime);
   return mqlTime.year;
}

int DayOfWeek(datetime time)
{
   MqlDateTime mqlTime;
   TimeToStruct(time, mqlTime);
   return mqlTime.day_of_week;
}

datetime getLastSunday(int year, int month)
{
   datetime lastDay = StringToTime(StringFormat("%d.%02d.31 23:59", year, month));
   while (DayOfWeek(lastDay) != 0) { lastDay -= 86400; }
   return lastDay;
}

datetime getNthSunday(int year, int month, int n)
{
   datetime day = StringToTime(StringFormat("%d.%02d.01 00:00", year, month));
   int count = 0;
   while (true)
   {
      if (DayOfWeek(day) == 0)
      {
         count++;
         if (count == n) return day;
      }
      day += 86400;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Check for important economic event (CPI within ±30 min)         |
//+------------------------------------------------------------------+
bool IsImportantEvent()
{
   MqlCalendarValue values[];
   datetime startTime = TimeTradeServer() - PeriodSeconds(PERIOD_H4);
   datetime endTime   = TimeTradeServer() + PeriodSeconds(PERIOD_H4);
   int valuesTotal = CalendarValueHistory(values, startTime, endTime);

   for (int i = 0; i < valuesTotal; i++)
   {
      MqlCalendarEvent event;
      CalendarEventById(values[i].event_id, event);

      MqlCalendarCountry county;
      CalendarCountryById(event.country_id, county);

      datetime timeRange  = PeriodSeconds(PERIOD_M30);
      datetime timeBefore = TimeTradeServer() - timeRange;
      datetime timeAfter  = TimeTradeServer() + timeRange;

      if (StringFind(_Symbol, county.currency) >= 0)
      {
         if (values[i].time >= timeBefore && values[i].time <= timeAfter)
         {
            if (event.name == "CPI")
            {
               Print(event.name, " > ", county.currency, " > ", event.importance, ", TIME = ", values[i].time);
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if we have a bar open tick (new M1 bar)                   |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime previousTime = 0;
   datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if (previousTime != currentTime)
   {
      previousTime = currentTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Summer/Winter time shift for range calculation                  |
//| Returns 1 during DST transition periods, else 0                 |
//+------------------------------------------------------------------+
int SummerWinterTimeShift()
{
   int currentYear = TimeYear(TimeCurrent());

   datetime secondSundayMarch   = getNthSunday(currentYear, 3, 2);
   datetime lastSundayMarch     = getLastSunday(currentYear, 3);
   datetime lastSundayOctober   = getLastSunday(currentYear, 10);
   datetime firstSundayNovember = getNthSunday(currentYear, 11, 1);

   if (TimeCurrent() >= secondSundayMarch && TimeCurrent() < lastSundayMarch)
   {
      return 1;  // GMT+1 (spring forward)
   }
   else if (TimeCurrent() >= lastSundayOctober && TimeCurrent() < firstSundayNovember)
   {
      return 1;  // GMT+1 (fall back transition)
   }
   else
   {
      return 0;
   }
}
