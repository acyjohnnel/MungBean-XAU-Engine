//+------------------------------------------------------------------+
//|                                                    DojiCrossEA.mq5 |
//|                                              Fixed Version 3.0    |
//+------------------------------------------------------------------+
#property copyright "Fixed Doji Cross EA"
#property version   "3.0"
#property description "Completely fixed with enhanced debugging"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs
input double   RiskPercent      = 1.0;     // Risk per trade (%)
input double   RR_Ratio          = 2.0;     // Risk:Reward ratio
input int      SL_BufferPoints   = 100;     // SL buffer in points (symbol-agnostic)
input bool     EnableTimeFilter  = false;  // Enable time filter
input int      StartHour1        = 0;       // Start hour window 1 (broker time)
input int      EndHour1          = 23;      // End hour window 1 (broker time)
input int      StartHour2        = 0;       // Start hour window 2 (broker time)
input int      EndHour2          = 0;       // End hour window 2 (broker time)
input bool     Monday            = true;    // Trade Monday
input bool     Tuesday           = true;    // Trade Tuesday
input bool     Wednesday         = true;    // Trade Wednesday
input bool     Thursday          = true;    // Trade Thursday
input bool     Friday            = true;    // Trade Friday
input bool     DebugMode         = true;    // Enable debug prints
input double   MaxLotSize        = 0.1;     // Maximum lot size for 1k account
input int      StochKPeriod      = 9;       // Stochastic %K period
input int      StochDPeriod      = 3;       // Stochastic %D period
input int      StochSlowing      = 3;       // Stochastic slowing
input double   StochBuyLevel     = 30.0;    // Buy when Stoch main <= level
input double   StochSellLevel    = 70.0;    // Sell when Stoch main >= level
input bool     EnableStochFilter = true;   // Enable Stochastic gating
input bool     UseStopLoss       = true;   // Enable initial stop loss
input bool     EnableDynamicSL   = true;   // Toggle SL based on PnL sign
input bool     EnablePartialClose = false; // Enable partial close at 1R
input double   PartialClosePercent = 50.0; // Percent to close at 1R
input bool     EnableADXFilter   = true;   // Enable ADX/+DI/-DI filter
input int      ADXPeriod         = 14;     // ADX period
input double   ADXMinStrength    = 20.0;   // Minimum ADX value for trend strength
input bool     EnableBreakEven   = false;  // Move SL to breakeven at 1R
input bool     AllowMultipleTrades = true; // Allow multiple open trades per symbol
input bool     EnableADXVolumeMultiplier = false; // Multiply risk when ADX is high
input double   ADXVolumeThreshold = 40.0;  // ADX threshold to boost risk
input double   ADXVolumeMultiplier = 1.5;  // Risk multiplier when ADX high
input bool     EnableDefenseHedge = false; // Enable hedge defense at loss threshold
input double   DefenseLossPoints = 100.0;  // Loss in points to open hedge
input bool     RemoveSLOnDefenseHedge = false; // Remove SL on original trade when hedge opens
input bool     HedgeByNetExposure = true; // Hedge remaining net exposure

//--- Global handles
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int stochHandle = INVALID_HANDLE;
int adxHandle = INVALID_HANDLE;
CTrade trade;
const long EA_MAGIC = 12345;
double lastAdxValue = 0.0;

string PartialCloseKey(ulong ticket)
{
    return "MBXE_PC_" + (string)ticket;
}

string PlannedSLKey(ulong ticket)
{
    return "MBXE_PL_SL_" + (string)ticket;
}

void StorePlannedSL(ulong ticket, double sl_price)
{
    if(sl_price > 0.0)
        GlobalVariableSet(PlannedSLKey(ticket), sl_price);
}

double GetPlannedSL(ulong ticket)
{
    if(GlobalVariableCheck(PlannedSLKey(ticket)))
        return GlobalVariableGet(PlannedSLKey(ticket));
    return 0.0;
}

string HedgeTicketKey(ulong ticket)
{
    return "MBXE_HD_" + (string)ticket;
}

string HedgeTrendKey(ulong ticket)
{
    return "MBXE_HD_TR_" + (string)ticket;
}

string HedgeDoneKey(ulong ticket)
{
    return "MBXE_HD_DONE_" + (string)ticket;
}

void StoreHedgeTicket(ulong ticket, ulong hedge_ticket)
{
    GlobalVariableSet(HedgeTicketKey(ticket), (double)hedge_ticket);
}

void StoreHedgeTrend(ulong ticket, int trend_dir)
{
    GlobalVariableSet(HedgeTrendKey(ticket), (double)trend_dir);
}

ulong GetHedgeTicket(ulong ticket)
{
    if(GlobalVariableCheck(HedgeTicketKey(ticket)))
        return (ulong)GlobalVariableGet(HedgeTicketKey(ticket));
    return 0;
}

int GetHedgeTrend(ulong ticket)
{
    if(GlobalVariableCheck(HedgeTrendKey(ticket)))
        return (int)GlobalVariableGet(HedgeTrendKey(ticket));
    return 0;
}

void ClearHedgeTicket(ulong ticket)
{
    GlobalVariableDel(HedgeTicketKey(ticket));
    GlobalVariableDel(HedgeTrendKey(ticket));
}

bool IsHedgeDone(ulong ticket)
{
    return GlobalVariableCheck(HedgeDoneKey(ticket));
}

void MarkHedgeDone(ulong ticket)
{
    GlobalVariableSet(HedgeDoneKey(ticket), 1.0);
}

bool IsPartialClosed(ulong ticket)
{
    return GlobalVariableCheck(PartialCloseKey(ticket));
}

bool HasOpenPosition()
{
    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
            continue;

        return true;
    }

    return false;
}

double GetOppositeVolume(long type)
{
    double total = 0.0;
    int count = PositionsTotal();
    for(int i = count - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
            continue;

        long pos_type = PositionGetInteger(POSITION_TYPE);
        if(pos_type == type)
            continue;

        total += PositionGetDouble(POSITION_VOLUME);
    }

    return total;
}

double GetAdxRiskMultiplier()
{
    if(!EnableADXVolumeMultiplier)
        return 1.0;

    if(ADXVolumeMultiplier <= 0.0)
        return 1.0;

    return (lastAdxValue >= ADXVolumeThreshold) ? ADXVolumeMultiplier : 1.0;
}

void MarkPartialClosed(ulong ticket)
{
    GlobalVariableSet(PartialCloseKey(ticket), 1.0);
}

void HandlePartialClose()
{
    if(!EnablePartialClose)
        return;

    if(PartialClosePercent <= 0.0 || PartialClosePercent >= 100.0)
        return;

    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic != EA_MAGIC)
            continue;

        if(IsPartialClosed(ticket))
            continue;

        double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        if(sl <= 0.0 || open_price <= 0.0)
            continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double r_distance = MathAbs(open_price - sl);
        if(r_distance <= 0.0)
            continue;

        double trigger_price = (type == POSITION_TYPE_BUY) ? (open_price + r_distance) : (open_price - r_distance);
        double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        bool reached = (type == POSITION_TYPE_BUY) ? (current_price >= trigger_price) : (current_price <= trigger_price);
        if(!reached)
            continue;

        double volume = PositionGetDouble(POSITION_VOLUME);
        double close_volume = volume * (PartialClosePercent / 100.0);

        double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        if(step > 0.0)
            close_volume = MathFloor(close_volume / step) * step;

        double max_partial = volume - min_lot;
        if(close_volume > max_partial)
            close_volume = max_partial;

        if(close_volume < min_lot || close_volume <= 0.0)
            continue;

        if(trade.PositionClosePartial(ticket, close_volume))
        {
            MarkPartialClosed(ticket);
            if(DebugMode)
                Print("Partial close executed for ticket ", ticket, " volume ", close_volume, " of ", volume);
        }
        else if(DebugMode)
        {
            Print("Partial close failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(),
                  " | volume=", volume, " close_volume=", close_volume);
        }
    }
}

void HandleBreakEven()
{
    if(!EnableBreakEven)
        return;

    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic != EA_MAGIC)
            continue;

        double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        if(sl <= 0.0 || open_price <= 0.0)
            continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double r_distance = MathAbs(open_price - sl);
        if(r_distance <= 0.0)
            continue;

        double trigger_price = (type == POSITION_TYPE_BUY) ? (open_price + r_distance) : (open_price - r_distance);
        double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        bool reached = (type == POSITION_TYPE_BUY) ? (current_price >= trigger_price) : (current_price <= trigger_price);
        if(!reached)
            continue;

        double current_sl = sl;
        bool needs_move = (type == POSITION_TYPE_BUY) ? (current_sl < open_price) : (current_sl > open_price);
        if(!needs_move)
            continue;

        double tp = PositionGetDouble(POSITION_TP);
        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        double be_sl = NormalizeDouble(open_price, digits);
        tp = (tp > 0.0) ? NormalizeDouble(tp, digits) : 0.0;

        if(trade.PositionModify(_Symbol, be_sl, tp))
        {
            if(DebugMode)
                Print("Break-even SL set for ticket ", ticket, " at ", be_sl);
        }
        else if(DebugMode)
        {
            Print("Break-even modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        }
    }
}

void HandleDynamicSL()
{
    if(!EnableDynamicSL)
        return;

    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
            continue;

        string comment = PositionGetString(POSITION_COMMENT);
        if(StringFind(comment, "Defense Hedge") >= 0)
            continue;

        double profit = PositionGetDouble(POSITION_PROFIT);
        double sl = PositionGetDouble(POSITION_SL);
        double tp = PositionGetDouble(POSITION_TP);
        double planned_sl = GetPlannedSL(ticket);

        if(profit > 0.0)
        {
            if(sl <= 0.0 && planned_sl > 0.0)
            {
                if(trade.PositionModify(ticket, planned_sl, tp))
                {
                    if(DebugMode)
                        Print("Dynamic SL set for ticket ", ticket, " to ", planned_sl);
                }
                else if(DebugMode)
                {
                    Print("Dynamic SL set failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
                }
            }
        }
        else
        {
            if(sl > 0.0)
            {
                if(trade.PositionModify(ticket, 0.0, tp))
                {
                    if(DebugMode)
                        Print("Dynamic SL removed for ticket ", ticket);
                }
                else if(DebugMode)
                {
                    Print("Dynamic SL removal failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
                }
            }
        }
    }
}

void HandleDefenseHedge()
{
    if(!EnableDefenseHedge)
        return;

    if(DefenseLossPoints <= 0.0)
        return;

    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0)
            continue;

        if(!PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
            continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double volume = PositionGetDouble(POSITION_VOLUME);
        double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double planned_sl = (sl > 0.0) ? sl : GetPlannedSL(ticket);

        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double loss_points = 0.0;

        if(type == POSITION_TYPE_BUY)
            loss_points = (open_price - bid) / _Point;
        else
            loss_points = (ask - open_price) / _Point;

        if(loss_points < DefenseLossPoints)
        {
            // If hedge exists, check close condition only
        }

        if(IsHedgeDone(ticket))
        {
            if(DebugMode)
                Print("Defense hedge skipped: already done for ticket ", ticket);
            continue;
        }

        double emaFast[1];
        double emaSlow[1];
        int current_trend = 0;
        if(CopyBuffer(emaFastHandle, 0, 1, 1, emaFast) == 1 &&
           CopyBuffer(emaSlowHandle, 0, 1, 1, emaSlow) == 1)
        {
            if(emaFast[0] > emaSlow[0])
                current_trend = 1;
            else if(emaFast[0] < emaSlow[0])
                current_trend = -1;
        }

        ulong hedge_ticket = GetHedgeTicket(ticket);
        if(hedge_ticket == 0 && loss_points >= DefenseLossPoints)
        {
            double hedge_volume = 0.0;
            if(HedgeByNetExposure)
            {
                double opposite_volume = GetOppositeVolume(type);
                hedge_volume = volume - opposite_volume;
            }
            else
            {
                hedge_volume = volume;
            }

            double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            if(step > 0.0)
                hedge_volume = MathFloor(hedge_volume / step) * step;
            if(hedge_volume < min_lot)
                hedge_volume = min_lot;
            if(hedge_volume > volume)
                hedge_volume = volume;
            if(hedge_volume <= 0.0)
            {
                if(DebugMode)
                    Print("Defense hedge skipped: hedge_volume <= 0 for ticket ", ticket);
                continue;
            }

            bool hedge_ok = false;
            if(type == POSITION_TYPE_BUY)
                hedge_ok = trade.Sell(hedge_volume, NULL, 0.0, 0.0, 0.0, "Defense Hedge");
            else
                hedge_ok = trade.Buy(hedge_volume, NULL, 0.0, 0.0, 0.0, "Defense Hedge");

            if(hedge_ok)
            {
                ulong new_ticket = (ulong)trade.ResultOrder();
                if(new_ticket > 0)
                {
                    StoreHedgeTicket(ticket, new_ticket);
                    if(current_trend != 0)
                        StoreHedgeTrend(ticket, current_trend);
                    if(DebugMode)
                        Print("Defense hedge opened for ticket ", ticket, " hedge ", new_ticket,
                              " volume=", hedge_volume);

                    if(RemoveSLOnDefenseHedge && sl > 0.0)
                    {
                        double tp = PositionGetDouble(POSITION_TP);
                        if(trade.PositionModify(_Symbol, 0.0, tp))
                        {
                            if(DebugMode)
                                Print("Original SL removed for ticket ", ticket, " after hedge open");
                        }
                        else if(DebugMode)
                        {
                            Print("Failed to remove SL: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
                        }
                    }
                }
            }
            else if(DebugMode)
            {
                Print("Defense hedge failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            }
        }
        else if(DebugMode && hedge_ticket == 0)
        {
            Print("Defense hedge not triggered: loss_points=", loss_points, " threshold=", DefenseLossPoints,
                  " volume=", volume);
        }

        hedge_ticket = GetHedgeTicket(ticket);
        if(hedge_ticket == 0)
            continue;

        int original_trend = GetHedgeTrend(ticket);
        if(original_trend != 0 && current_trend != original_trend)
            continue;

        if(PositionSelectByTicket(hedge_ticket))
        {
            double hedge_open = PositionGetDouble(POSITION_PRICE_OPEN);
            long hedge_type = PositionGetInteger(POSITION_TYPE);
            bool hedge_be = (hedge_type == POSITION_TYPE_BUY) ? (bid >= hedge_open) : (ask <= hedge_open);
            if(!hedge_be)
                continue;

            if(trade.PositionClose(hedge_ticket))
            {
                ClearHedgeTicket(ticket);
                MarkHedgeDone(ticket);
                if(DebugMode)
                    Print("Defense hedge closed for ticket ", ticket, " hedge ", hedge_ticket);
            }
            else if(DebugMode)
            {
                Print("Defense hedge close failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            }
        }
        else
        {
            ClearHedgeTicket(ticket);
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber((uint)EA_MAGIC);
    //--- Create indicator handles
    emaFastHandle = iMA(_Symbol, _Period, 8, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, _Period, 100, 0, MODE_EMA, PRICE_CLOSE);
    if(EnableStochFilter)
        stochHandle = iStochastic(_Symbol, _Period, StochKPeriod, StochDPeriod, StochSlowing, MODE_SMA, STO_LOWHIGH);
    adxHandle = iADX(_Symbol, _Period, ADXPeriod);
    
    if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE ||
       (EnableStochFilter && stochHandle == INVALID_HANDLE) || adxHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles");
        return INIT_FAILED;
    }
    
    Print("========================================");
    Print("EA INITIALIZED");
    Print("Symbol: ", _Symbol, " | Period: ", _Period);
    Print("Account Balance: $", AccountInfoDouble(ACCOUNT_BALANCE));
    Print("Risk: ", RiskPercent, "% | RR: ", RR_Ratio);
    Print("Max Lot Size: ", MaxLotSize);
    Print("========================================");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(emaFastHandle != INVALID_HANDLE) 
    {
        IndicatorRelease(emaFastHandle);
        emaFastHandle = INVALID_HANDLE;
    }
    
    if(emaSlowHandle != INVALID_HANDLE) 
    {
        IndicatorRelease(emaSlowHandle);
        emaSlowHandle = INVALID_HANDLE;
    }

    if(stochHandle != INVALID_HANDLE) 
    {
        IndicatorRelease(stochHandle);
        stochHandle = INVALID_HANDLE;
    }

    if(adxHandle != INVALID_HANDLE)
    {
        IndicatorRelease(adxHandle);
        adxHandle = INVALID_HANDLE;
    }
    
    Print("EA Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    HandlePartialClose();
    HandleBreakEven();
    HandleDynamicSL();
    HandleDefenseHedge();

    //--- Check for new bar (only process on new candle)
    static datetime lastBarTime = 0;
    datetime currentTime = iTime(_Symbol, _Period, 0);
    
    if(currentTime == lastBarTime) 
        return;
    
    lastBarTime = currentTime;
    
    if(DebugMode)
        Print("\n--- NEW BAR --- Time: ", TimeToString(currentTime, TIME_DATE|TIME_MINUTES));
    
    //--- Check trading conditions
    CheckForEntry();
}

//+------------------------------------------------------------------+
//| Check entry conditions                                           |
//+------------------------------------------------------------------+
void CheckForEntry()
{
    //--- Check if we have enough bars
    int bars = Bars(_Symbol, _Period);
    if(bars < 100)
    {
        if(DebugMode) Print("Not enough bars: ", bars);
        return;
    }
    
    //--- Get indicator values
    double emaFast[3] = {0, 0, 0};
    double emaSlow[3] = {0, 0, 0};
    double stochMain[3] = {0, 0, 0};
    double adxMain[3] = {0, 0, 0};
    double adxPlusDI[3] = {0, 0, 0};
    double adxMinusDI[3] = {0, 0, 0};
    
    if(CopyBuffer(emaFastHandle, 0, 1, 3, emaFast) != 3)
    {
        if(DebugMode) Print("ERROR: Failed to copy EMA Fast buffer");
        return;
    }
    
    if(CopyBuffer(emaSlowHandle, 0, 1, 3, emaSlow) != 3)
    {
        if(DebugMode) Print("ERROR: Failed to copy EMA Slow buffer");
        return;
    }

    if(EnableStochFilter)
    {
        if(CopyBuffer(stochHandle, 0, 1, 3, stochMain) != 3)
        {
            if(DebugMode) Print("ERROR: Failed to copy Stochastic buffer");
            return;
        }
    }

    if(CopyBuffer(adxHandle, 0, 1, 3, adxMain) != 3 ||
       CopyBuffer(adxHandle, 1, 1, 3, adxPlusDI) != 3 ||
       CopyBuffer(adxHandle, 2, 1, 3, adxMinusDI) != 3)
    {
        if(DebugMode) Print("ERROR: Failed to copy ADX buffers");
        return;
    }
    
    //--- Get candle data (shift 1 and 2 only - NEVER shift 0)
    double open1 = iOpen(_Symbol, _Period, 2);   // Candle 1 (Doji)
    double high1 = iHigh(_Symbol, _Period, 2);
    double low1  = iLow(_Symbol, _Period, 2);
    double close1 = iClose(_Symbol, _Period, 2);
    
    double open2 = iOpen(_Symbol, _Period, 1);   // Candle 2 (Execution)
    double high2 = iHigh(_Symbol, _Period, 1);
    double low2  = iLow(_Symbol, _Period, 1);
    double close2 = iClose(_Symbol, _Period, 1);
    
    //--- EMA values at candle closes
    double emaFast1 = emaFast[2];  // EMA8 at Candle 1 close
    double emaFast2 = emaFast[1];  // EMA8 at Candle 2 close
    double emaSlow2 = emaSlow[1];  // EMA100 at Candle 2 close
    double stochValue = stochMain[0]; // Stoch main at Candle 2 close (shift 1)
    double adxValue = adxMain[0];
    double plusDIValue = adxPlusDI[0];
    double minusDIValue = adxMinusDI[0];
    lastAdxValue = adxValue;
    
    if(DebugMode)
    {
        Print("Candle 1 (Doji): O=", open1, " H=", high1, " L=", low1, " C=", close1);
        Print("Candle 2 (Exec): O=", open2, " H=", high2, " L=", low2, " C=", close2);
        Print("EMA8 @C1=", emaFast1, " EMA8 @C2=", emaFast2, " EMA100 @C2=", emaSlow2);
        if(EnableStochFilter)
            Print("Stoch Main @C2=", stochValue);
        Print("ADX @C2=", adxValue, " +DI=", plusDIValue, " -DI=", minusDIValue);
    }
    
    //--- Check time and day filters
    if(!IsTradingAllowed())
    {
        if(DebugMode) Print("Trade blocked by time/day filter");
        return;
    }
    
    //--- Check trend direction (SIMPLE - single candle check)
    bool isUptrend   = emaFast2 > emaSlow2;
    bool isDowntrend = emaFast2 < emaSlow2;
    
    if(DebugMode)
    {
        Print("Trend Check: EMA8=", emaFast2, " EMA100=", emaSlow2);
        Print("Uptrend: ", isUptrend, " | Downtrend: ", isDowntrend);
    }

    bool adxStrengthOk = (!EnableADXFilter) || (adxValue >= ADXMinStrength);
    bool adxBuyOk = (!EnableADXFilter) || (plusDIValue > minusDIValue);
    bool adxSellOk = (!EnableADXFilter) || (minusDIValue > plusDIValue);

    if(DebugMode)
    {
        Print("ADX Filter: StrengthOk (>= ", ADXMinStrength, ")=", adxStrengthOk,
              " | BuyOk (+DI>-DI)=", adxBuyOk, " | SellOk (-DI>+DI)=", adxSellOk);
    }
    
    //--- Candle 1: Doji-type check (relaxed: ≤40% body)
    double candle1Body = MathAbs(close1 - open1);
    double candle1Range = high1 - low1;
    bool isDojiType = (candle1Range > 0) && (candle1Body <= 0.4 * candle1Range);
    
    if(DebugMode)
    {
        Print("Candle 1 Check:");
        Print("  Body: ", candle1Body, " | Range: ", candle1Range);
        Print("  Body/Range: ", (candle1Range > 0 ? candle1Body / candle1Range : 0));
        Print("  Is Doji Type (≤40%): ", isDojiType);
    }
    
    if(!isDojiType && DebugMode)
    {
        Print("FAIL: Candle 1 not doji-type");
    }
    
    //--- Candle 2: Body ratio check (2x, not 3x)
    double candle2Body = MathAbs(close2 - open2);
    bool bodyRatioOK = (candle1Body > 0) && (candle2Body >= 2.0 * candle1Body);
    
    if(DebugMode)
    {
        Print("Candle 2 Check:");
        Print("  Body: ", candle2Body);
        Print("  Body Ratio (C2/C1): ", (candle1Body > 0 ? candle2Body / candle1Body : 0));
        Print("  Body Ratio OK (≥2x): ", bodyRatioOK);
    }
    
    //--- Stochastic gating filter (Candle 2)
    bool stochBuyOk = (!EnableStochFilter) || (stochValue <= StochBuyLevel);
    bool stochSellOk = (!EnableStochFilter) || (stochValue >= StochSellLevel);

    if(DebugMode && EnableStochFilter)
    {
        Print("Stoch Filter: BuyOk (<= ", StochBuyLevel, ")=", stochBuyOk,
              " | SellOk (>= ", StochSellLevel, ")=", stochSellOk);
    }

    bool buySignal = (isUptrend && isDojiType && bodyRatioOK && stochBuyOk && adxStrengthOk && adxBuyOk);
    bool sellSignal = (isDowntrend && isDojiType && bodyRatioOK && stochSellOk && adxStrengthOk && adxSellOk);

    if(DebugMode)
    {
        Print("Signal Summary: BuySignal=", buySignal, " SellSignal=", sellSignal,
              " | Uptrend=", isUptrend, " Downtrend=", isDowntrend,
              " Doji=", isDojiType, " BodyRatio=", bodyRatioOK,
              " StochBuyOk=", stochBuyOk, " StochSellOk=", stochSellOk,
              " ADXStrengthOk=", adxStrengthOk, " ADXBuyOk=", adxBuyOk, " ADXSellOk=", adxSellOk);
    }

    //--- BUY CONDITIONS (EXECUTION-SAFE)
    if(buySignal)
    {
        if(!AllowMultipleTrades && HasOpenPosition())
        {
            if(DebugMode) Print("Trade blocked: existing position and AllowMultipleTrades=false");
            return;
        }
        //--- Candle 1 EMA position (RELAXED: low OR close below EMA8)
        bool candle1BelowEMA = (low1 < emaFast1) || (close1 < emaFast1);
        
        //--- Candle 2 execution conditions
        bool candle2Bullish = close2 > open2;
        bool candle2CrossUp = (close2 > emaFast2) && (low2 < emaFast2);
        
        if(DebugMode)
        {
            Print("BUY Conditions Check:");
            Print("  Candle1 Below EMA8: ", candle1BelowEMA);
            Print("  Candle2 Bullish: ", candle2Bullish);
            Print("  Candle2 Cross Up (C>EMA & L<EMA): ", candle2CrossUp);
        }
        
        if(candle1BelowEMA && candle2Bullish && candle2CrossUp)
        {
            Print(">>> BUY SIGNAL CONFIRMED!");
            ExecuteBuy(close2, low1, high1);
        }
        else if(DebugMode)
        {
            Print("BUY Conditions NOT Met:");
            Print("  C1BelowEMA: ", candle1BelowEMA);
            Print("  C2Bullish: ", candle2Bullish);
            Print("  C2CrossUp: ", candle2CrossUp);
        }
    }
    
    //--- SELL CONDITIONS (EXECUTION-SAFE)
    if(sellSignal)
    {
        if(!AllowMultipleTrades && HasOpenPosition())
        {
            if(DebugMode) Print("Trade blocked: existing position and AllowMultipleTrades=false");
            return;
        }
        //--- Candle 1 EMA position (RELAXED: high OR close above EMA8)
        bool candle1AboveEMA = (high1 > emaFast1) || (close1 > emaFast1);
        
        //--- Candle 2 execution conditions
        bool candle2Bearish = close2 < open2;
        bool candle2CrossDown = (close2 < emaFast2) && (high2 > emaFast2);
        
        if(DebugMode)
        {
            Print("SELL Conditions Check:");
            Print("  Candle1 Above EMA8: ", candle1AboveEMA);
            Print("  Candle2 Bearish: ", candle2Bearish);
            Print("  Candle2 Cross Down (C<EMA & H>EMA): ", candle2CrossDown);
        }
        
        if(candle1AboveEMA && candle2Bearish && candle2CrossDown)
        {
            Print(">>> SELL SIGNAL CONFIRMED!");
            ExecuteSell(close2, high1, low1);
        }
        else if(DebugMode)
        {
            Print("SELL Conditions NOT Met:");
            Print("  C1AboveEMA: ", candle1AboveEMA);
            Print("  C2Bearish: ", candle2Bearish);
            Print("  C2CrossDown: ", candle2CrossDown);
        }
    }
}

//+------------------------------------------------------------------+
//| Execute BUY order                                                |
//+------------------------------------------------------------------+
void ExecuteBuy(double entryPrice, double candle1Low, double candle1High)
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    //--- Calculate SL: Below Candle 1 low minus buffer
    double stopLoss = candle1Low - SL_BufferPoints * _Point;
    double takeProfit = ask + (RR_Ratio * (ask - stopLoss));
    
    //--- Calculate lot size
    double slDistance = MathAbs(ask - stopLoss);
    double lotSize = CalculateLotSize(slDistance, GetAdxRiskMultiplier());
    
    if(lotSize <= 0)
    {
        Print("ERROR: Invalid lot size calculated: ", lotSize);
        return;
    }
    
    //--- Display trade details
    Print("\n=== BUY ORDER ===");
    Print("Entry Price: ", NormalizeDouble(ask, digits));
    Print("Stop Loss: ", NormalizeDouble(stopLoss, digits), " (Candle1 Low: ", NormalizeDouble(candle1Low, digits), ")");
    Print("Take Profit: ", NormalizeDouble(takeProfit, digits));
    Print("SL Distance: ", NormalizeDouble(slDistance, digits));
    Print("Lot Size: ", lotSize);
    Print("Risk Amount: $", AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0);
    
    //--- Prepare trade request
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action    = TRADE_ACTION_DEAL;
    request.symbol    = _Symbol;
    request.volume    = NormalizeDouble(lotSize, 2);
    request.type      = ORDER_TYPE_BUY;
    request.price     = NormalizeDouble(ask, digits);
    request.sl        = UseStopLoss ? NormalizeDouble(stopLoss, digits) : 0.0;
    request.tp        = NormalizeDouble(takeProfit, digits);
    request.deviation = 10;
    request.magic     = EA_MAGIC;
    request.comment   = "DojiCross BUY";
    
    //--- Send order
    bool success = OrderSend(request, result);
    
    if(success && result.retcode == TRADE_RETCODE_DONE)
    {
        StorePlannedSL(result.order, stopLoss);
        Print("SUCCESS: Buy order executed. Ticket: ", result.order);
        Print("Volume: ", result.volume, " | Price: ", result.price);
    }
    else
    {
        Print("ERROR: Buy order failed. Code: ", result.retcode);
        Print("Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Execute SELL order                                               |
//+------------------------------------------------------------------+
void ExecuteSell(double entryPrice, double candle1High, double candle1Low)
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    //--- Calculate SL: Above Candle 1 high plus buffer
    double stopLoss = candle1High + SL_BufferPoints * _Point;
    double takeProfit = bid - (RR_Ratio * (stopLoss - bid));
    
    //--- Calculate lot size
    double slDistance = MathAbs(stopLoss - bid);
    double lotSize = CalculateLotSize(slDistance, GetAdxRiskMultiplier());
    
    if(lotSize <= 0)
    {
        Print("ERROR: Invalid lot size calculated: ", lotSize);
        return;
    }
    
    //--- Display trade details
    Print("\n=== SELL ORDER ===");
    Print("Entry Price: ", NormalizeDouble(bid, digits));
    Print("Stop Loss: ", NormalizeDouble(stopLoss, digits), " (Candle1 High: ", NormalizeDouble(candle1High, digits), ")");
    Print("Take Profit: ", NormalizeDouble(takeProfit, digits));
    Print("SL Distance: ", NormalizeDouble(slDistance, digits));
    Print("Lot Size: ", lotSize);
    Print("Risk Amount: $", AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0);
    
    //--- Prepare trade request
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action    = TRADE_ACTION_DEAL;
    request.symbol    = _Symbol;
    request.volume    = NormalizeDouble(lotSize, 2);
    request.type      = ORDER_TYPE_SELL;
    request.price     = NormalizeDouble(bid, digits);
    request.sl        = UseStopLoss ? NormalizeDouble(stopLoss, digits) : 0.0;
    request.tp        = NormalizeDouble(takeProfit, digits);
    request.deviation = 10;
    request.magic     = EA_MAGIC;
    request.comment   = "DojiCross SELL";
    
    //--- Send order
    bool success = OrderSend(request, result);
    
    if(success && result.retcode == TRADE_RETCODE_DONE)
    {
        StorePlannedSL(result.order, stopLoss);
        Print("SUCCESS: Sell order executed. Ticket: ", result.order);
        Print("Volume: ", result.volume, " | Price: ", result.price);
    }
    else
    {
        Print("ERROR: Sell order failed. Code: ", result.retcode);
        Print("Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints, double riskMultiplier)
{
    //--- Get symbol information
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(tickSize <= 0 || tickValue <= 0 || lotStep <= 0)
    {
        Print("ERROR: Invalid symbol info - TickSize: ", tickSize, " TickValue: ", tickValue, " LotStep: ", lotStep);
        return 0;
    }
    
    //--- Calculate risk amount
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * RiskPercent / 100.0;
    if(riskMultiplier > 0.0)
        riskAmount *= riskMultiplier;
    
    //--- Calculate loss per lot
    double lossPerLot = (slPoints / tickSize) * tickValue;
    
    if(lossPerLot <= 0)
    {
        Print("ERROR: Loss per lot calculation failed: ", lossPerLot);
        return 0;
    }
    
    //--- Calculate lot size
    double lots = riskAmount / lossPerLot;
    
    if(DebugMode)
    {
        Print("Lot Calculation:");
        Print("  Account Balance: $", accountBalance);
        Print("  Risk Amount ($", RiskPercent, "%): $", riskAmount);
        Print("  Risk Multiplier: ", riskMultiplier);
        Print("  SL Distance (points): ", slPoints);
        Print("  Tick Size: ", tickSize);
        Print("  Tick Value: ", tickValue);
        Print("  Loss per Lot: $", lossPerLot);
        Print("  Raw Lots: ", lots);
    }
    
    //--- Normalize to lot step
    if(lotStep > 0)
        lots = MathFloor(lots / lotStep) * lotStep;
    
    //--- Apply broker limits
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    
    lots = MathMax(lots, minLot);
    lots = MathMin(lots, maxLot);
    lots = MathMin(lots, MaxLotSize);
    
    //--- Safety for small accounts
    if(accountBalance < 2000 && lots > 0.1)
    {
        Print("WARNING: Capping lot size to 0.1 for small account protection");
        lots = 0.1;
    }
    
    //--- Final validation
    if(lots < minLot)
    {
        Print("WARNING: Calculated lot (", lots, ") below minimum (", minLot, ")");
        lots = minLot;
    }
    
    Print("Final Lot Size: ", lots, " (Min: ", minLot, " Max: ", maxLot, ")");
    
    return lots;
}

//+------------------------------------------------------------------+
//| Check if trading is allowed by time/day filters                  |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
    if(!EnableTimeFilter) 
        return true;
    
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    //--- Check day of week
    bool dayAllowed = false;
    switch(dt.day_of_week)
    {
        case 1: dayAllowed = Monday; break;
        case 2: dayAllowed = Tuesday; break;
        case 3: dayAllowed = Wednesday; break;
        case 4: dayAllowed = Thursday; break;
        case 5: dayAllowed = Friday; break;
        default: dayAllowed = false; break;
    }
    
    if(!dayAllowed) 
        return false;
    
    //--- Check time range
    int currentHour = dt.hour;
    bool in_window1 = false;
    bool in_window2 = false;

    if(StartHour1 <= EndHour1)
        in_window1 = (currentHour >= StartHour1 && currentHour <= EndHour1);
    else
        in_window1 = (currentHour >= StartHour1 || currentHour <= EndHour1);

    if(StartHour2 <= EndHour2)
        in_window2 = (currentHour >= StartHour2 && currentHour <= EndHour2);
    else
        in_window2 = (currentHour >= StartHour2 || currentHour <= EndHour2);

    return (in_window1 || in_window2);
}

//+------------------------------------------------------------------+
//| Trade Error Description                                          |
//+------------------------------------------------------------------+
string TradeErrorDescription(int errorCode)
{
    switch(errorCode)
    {
        case 10004: return "Requote";
        case 10006: return "Request rejected";
        case 10007: return "Request canceled by trader";
        case 10008: return "Order placed";
        case 10009: return "Request completed";
        case 10010: return "Only part of the request completed";
        case 10011: return "Request processing error";
        case 10012: return "Request canceled by timeout";
        case 10013: return "Invalid request";
        case 10014: return "Invalid volume in the request";
        case 10015: return "Invalid price in the request";
        case 10016: return "Invalid stops in the request";
        case 10017: return "Trade is disabled";
        case 10018: return "Market is closed";
        case 10019: return "There is not enough money";
        case 10020: return "Prices changed";
        case 10021: return "There are no quotes";
        case 10022: return "Invalid expiration in the request";
        case 10023: return "Order state changed";
        case 10024: return "Too frequent requests";
        case 10025: return "No changes in request";
        case 10026: return "Autotrading disabled by server";
        case 10027: return "Autotrading disabled by client terminal";
        case 10028: return "Request locked for processing";
        case 10029: return "Order or position frozen";
        default: return "Unknown error: " + IntegerToString(errorCode);
    }
}
