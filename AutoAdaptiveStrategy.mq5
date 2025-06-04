#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Auto-Adaptive Multi-Indicator EURUSD M5 Manual 2025 Improved    |
//+------------------------------------------------------------------+
#property copyright "\xC2\xA9 2025 Peter Ekon\xC3\xB3m / ChatGPT"
#property version   "1.10"
#property strict

//-- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+

enum ENUM_MODE
  {
   MODE_TREND = 0,
   MODE_REVERSAL,
   MODE_VOLATILITY
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input ENUM_MODE InitialMode    = MODE_REVERSAL; // Starting mode
input double    RiskPercent    = 2.0;           // Risk per trade (% of equity)
input double    PartialClose   = 50.0;          // % to take profit at R:R = 1
input bool      MoveSLBE       = true;          // Move SL to BE after partial?
input bool      UseTrail       = true;          // Use trailing stop on rest?
input double    TrailATRmult   = 3.0;           // Trailing ATR factor
input int       ATRperiod      = 14;            // ATR period
input int       EmaFastPeriod  = 20;            // Fast EMA
input int       EmaSlowPeriod  = 50;            // Slow EMA
input int       RsiPeriod      = 7;             // RSI period
input double    RsiOversold    = 20.0;          // RSI oversold
input double    RsiOverbought  = 80.0;          // RSI overbought
input int       BBperiod       = 20;            // Bollinger period
input double    BBdev          = 2.0;           // Bollinger deviation
input double    BBatrFactor    = 1.0;           // Squeeze factor
input ulong     MagicNumber    = 20230522;      // Magic number
input string    TradeSymbol    = "EURUSD.fx";   // Symbol
input ENUM_TIMEFRAMES TradeTF  = PERIOD_M5;     // Time frame

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
int      currentMode;
double   lastSwitchEquity;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Helper indicator calculations                                    |
//+------------------------------------------------------------------+
double ManualEMA(int period,int shift)
  {
   double alpha=2.0/(period+1.0);
   double ema=iClose(TradeSymbol,TradeTF,shift+period-1);
   for(int i=shift+period-2;i>=shift;i--)
      ema=alpha*iClose(TradeSymbol,TradeTF,i)+(1.0-alpha)*ema;
   return(ema);
  }

double ManualRSI(int period,int shift)
  {
   double gain=0.0,loss=0.0;
   for(int i=shift+period;i>shift;i--)
     {
      double diff=iClose(TradeSymbol,TradeTF,i-1)-iClose(TradeSymbol,TradeTF,i);
      if(diff>0) gain+=diff; else loss-=diff;
     }
   if(gain+loss==0.0) return(50.0);
   double rs=gain/period/(loss/period+1e-8);
   return(100.0-100.0/(1.0+rs));
  }

double ManualATR(int period,int shift)
  {
   double sum=0.0;
   for(int i=shift+period-1;i>shift-1;i--)
     {
      double high=iHigh(TradeSymbol,TradeTF,i);
      double low=iLow(TradeSymbol,TradeTF,i);
      double closePrev=iClose(TradeSymbol,TradeTF,i+1);
      double tr=MathMax(high-low,MathMax(MathAbs(high-closePrev),MathAbs(low-closePrev)));
      sum+=tr;
     }
   return(sum/period);
  }

void ManualBB(int period,double dev,int shift,double &upper,double &middle,double &lower)
  {
   double sum=0.0,sum2=0.0;
   for(int i=shift;i<shift+period;i++)
     {
      double c=iClose(TradeSymbol,TradeTF,i);
      sum+=c; sum2+=c*c;
     }
   middle=sum/period;
   double std=MathSqrt(sum2/period-middle*middle);
   upper=middle+dev*std;
   lower=middle-dev*std;
  }

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
string ModeName(int mode)
  {
   if(mode==MODE_TREND) return "Trend (EMA)";
   if(mode==MODE_REVERSAL) return "Reverzia (RSI)";
   if(mode==MODE_VOLATILITY) return "Volatilita (BB)";
   return "Unknown";
  }

int CountPositions()
  {
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetInteger(POSITION_MAGIC)==MagicNumber) cnt++;
     }
   return(cnt);
  }

void CloseAll()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetInteger(POSITION_MAGIC)==MagicNumber)
        {
         ulong ticket=PositionGetTicket(i);
         trade.PositionClose(ticket);
        }
     }
  }

// compute lot size using risk per equity and symbol tick value
// stopPrice: proposed stop level, entryPrice: price at entry
// returns normalized lot size

double ComputeLot(double stopPrice,double entryPrice)
  {
   double riskAmt=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;
   double dist=MathAbs(stopPrice-entryPrice);
   double tickVal=SymbolInfoDouble(TradeSymbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(TradeSymbol,SYMBOL_TRADE_TICK_SIZE);
   if(dist<=0.0 || tickVal<=0.0 || tickSize<=0.0) return(0.0);
   double lot=riskAmt/(dist/tickSize*tickVal);
   double step=SymbolInfoDouble(TradeSymbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(TradeSymbol,SYMBOL_VOLUME_MIN);
   lot=MathFloor(lot/step)*step;
   if(lot<minLot) lot=minLot;
   return(lot);
  }

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void ManagePositions(bool newBar)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      ulong  ticket=PositionGetTicket(i);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double stop =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);
      bool   buy  =(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);

      double price=buy?SymbolInfoDouble(TradeSymbol,SYMBOL_BID)
                      :SymbolInfoDouble(TradeSymbol,SYMBOL_ASK);

      if(newBar && UseTrail && tp==0)
        {
         double atr=ManualATR(ATRperiod,0);
         double newSL=buy ? price-TrailATRmult*atr : price+TrailATRmult*atr;
         if(buy && newSL>stop)
            trade.PositionModify(ticket,newSL,0);
         if(!buy && newSL<stop)
            trade.PositionModify(ticket,newSL,0);
        }
      if(MoveSLBE && tp==0 && stop!=0)
        {
         if((buy && price>entry) || (!buy && price<entry))
           {
            double be=entry;
            if((buy && stop<be) || (!buy && stop>be))
               trade.PositionModify(ticket,be,0);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Entry signals                                                    |
//+------------------------------------------------------------------+
void CheckEntry()
  {
   double emaFastCur=ManualEMA(EmaFastPeriod,0);
   double emaFastPrev=ManualEMA(EmaFastPeriod,1);
   double emaSlowCur=ManualEMA(EmaSlowPeriod,0);
   double emaSlowPrev=ManualEMA(EmaSlowPeriod,1);
   double rsiCur=ManualRSI(RsiPeriod,0);
   double rsiPrev=ManualRSI(RsiPeriod,1);
   double bbUpper,bbMiddle,bbLower,bbUpperPrev,bbMiddlePrev,bbLowerPrev;
   ManualBB(BBperiod,BBdev,0,bbUpper,bbMiddle,bbLower);
   ManualBB(BBperiod,BBdev,1,bbUpperPrev,bbMiddlePrev,bbLowerPrev);
   double atrCur=ManualATR(ATRperiod,0);
   double atrPrev=ManualATR(ATRperiod,1);

   double ask=SymbolInfoDouble(TradeSymbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(TradeSymbol,SYMBOL_BID);

   bool buy=false,sell=false;
   double entry=0,stop=0,tp1=0;
   string comment="";

   if(currentMode==MODE_TREND)
     {
      if(emaFastPrev<=emaSlowPrev && emaFastCur>emaSlowCur)
        {
         buy=true; entry=ask; stop=entry-3*atrCur; comment="EMA Trend BUY";
        }
      else if(emaFastPrev>=emaSlowPrev && emaFastCur<emaSlowCur)
        {
         sell=true; entry=bid; stop=entry+3*atrCur; comment="EMA Trend SELL";
        }
     }
   else if(currentMode==MODE_REVERSAL)
     {
      if(rsiPrev<RsiOversold && rsiCur>=RsiOversold)
        {
         buy=true; entry=ask; stop=entry-2*atrCur; comment="RSI Reversal BUY";
        }
      else if(rsiPrev>RsiOverbought && rsiCur<=RsiOverbought)
        {
         sell=true; entry=bid; stop=entry+2*atrCur; comment="RSI Reversal SELL";
        }
     }
   else if(currentMode==MODE_VOLATILITY)
     {
      double prevWidth=bbUpperPrev-bbLowerPrev;
      bool squeeze=(BBatrFactor>0.0 && atrPrev>0) ? prevWidth<BBatrFactor*atrPrev : true;
      if(squeeze)
        {
         if(iClose(TradeSymbol,TradeTF,1)<=bbUpperPrev && iClose(TradeSymbol,TradeTF,0)>bbUpper)
           {
            buy=true; entry=ask; stop=entry-2*atrCur; comment="BB Break BUY";
           }
         else if(iClose(TradeSymbol,TradeTF,1)>=bbLowerPrev && iClose(TradeSymbol,TradeTF,0)<bbLower)
           {
            sell=true; entry=bid; stop=entry+2*atrCur; comment="BB Break SELL";
           }
        }
     }

   if(!buy && !sell) return;

   double lots=ComputeLot(stop,entry);
   if(lots<=0) return;
   double part=lots*PartialClose/100.0;
   double rest=lots-part;
   double step=SymbolInfoDouble(TradeSymbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(TradeSymbol,SYMBOL_VOLUME_MIN);
   part=MathMax(minLot,MathFloor(part/step)*step);
   rest=MathMax(minLot,MathFloor(rest/step)*step);
   if(part+rest>lots+1e-6) rest=lots-part;

   if(buy) tp1=entry+MathAbs(entry-stop);
   if(sell) tp1=entry-MathAbs(entry-stop);

   bool r1=false,r2=false;
   if(buy)
     {
      r1=trade.Buy(part,TradeSymbol,entry,stop,tp1,comment+" TP");
      r2=trade.Buy(rest,TradeSymbol,entry,stop,0,comment+" Trail");
     }
   if(sell)
     {
      r1=trade.Sell(part,TradeSymbol,entry,stop,tp1,comment+" TP");
      r2=trade.Sell(rest,TradeSymbol,entry,stop,0,comment+" Trail");
     }
   if(r1 && r2)
      Print("Opened trade ",(buy?"BUY":"SELL")," ",lots," lot (",part,"+",rest,") Mode:",ModeName(currentMode));
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   currentMode=InitialMode;
   lastSwitchEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   Print("EA init. Mode:",ModeName(currentMode));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(_Symbol!=TradeSymbol || _Period!=TradeTF) return;

   datetime barTime=iTime(TradeSymbol,TradeTF,0);
   bool newBar=false;
   if(barTime!=lastBarTime)
     {
      newBar=true;
      lastBarTime=barTime;
     }

   ManagePositions(newBar);

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0.8*lastSwitchEquity)
     {
      currentMode=(currentMode+1)%3;
      Print("Equity drop ~20% from ",lastSwitchEquity," switching mode:",ModeName(currentMode));
      lastSwitchEquity=equity;
      CloseAll();
     }

   if(CountPositions()==0 && newBar)
      CheckEntry();
  }

//+------------------------------------------------------------------+
