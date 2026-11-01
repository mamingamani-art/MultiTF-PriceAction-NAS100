#ifndef __MT4_COMPAT_MQH__
#define __MT4_COMPAT_MQH__

#define OP_BUY 0
#define OP_SELL 1
#define SELECT_BY_POS 0
#define SELECT_BY_TICKET 1
#define MODE_TRADES 0
#define MODE_HISTORY 1
#define MODE_LOW 1
#define MODE_HIGH 2
#define MODE_TICKVALUE 16
#define MODE_TICKSIZE 17
#define MODE_TRADEALLOWED 22
#define MODE_MINLOT 23
#define MODE_LOTSTEP 24
#define MODE_MAXLOT 25
#define MODE_STOPLEVEL 14
#define Ask SymbolInfoDouble(_Symbol,SYMBOL_ASK)
#define Bid SymbolInfoDouble(_Symbol,SYMBOL_BID)
#define Digits _Digits
#define Point _Point

ulong __mt4_ticket=0;
bool __mt4_history=false;

bool IsTesting(){ return (bool)MQLInfoInteger(MQL_TESTER); }
bool IsConnected(){ return (bool)TerminalInfoInteger(TERMINAL_CONNECTED); }
bool IsTradeAllowed(){ return IsTesting() || (bool)MQLInfoInteger(MQL_TRADE_ALLOWED); }
bool IsTradeContextBusy(){ return false; }
bool RefreshRates(){ MqlTick t; return SymbolInfoTick(_Symbol,t); }
int TimeHour(datetime t){ MqlDateTime d; TimeToStruct(t,d); return d.hour; }
double AccountEquity(){ return AccountInfoDouble(ACCOUNT_EQUITY); }
double AccountFreeMarginCheck(string symbol,int cmd,double volume)
{
   double price=(cmd==OP_BUY?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID));
   double margin=0; ENUM_ORDER_TYPE type=(cmd==OP_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(!OrderCalcMargin(type,symbol,volume,price,margin)) return -1;
   return AccountInfoDouble(ACCOUNT_MARGIN_FREE)-margin;
}
double MarketInfo(string symbol,int mode)
{
   if(mode==MODE_TICKVALUE) return SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   if(mode==MODE_TICKSIZE) return SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   if(mode==MODE_MINLOT) return SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   if(mode==MODE_LOTSTEP) return SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(mode==MODE_MAXLOT) return SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(mode==MODE_STOPLEVEL) return (double)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(mode==MODE_TRADEALLOWED) return SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE)!=SYMBOL_TRADE_MODE_DISABLED;
   if(mode==MODE_HIGH){ double v[1]; return CopyHigh(symbol,PERIOD_D1,0,1,v)==1?v[0]:0; }
   if(mode==MODE_LOW){ double v[1]; return CopyLow(symbol,PERIOD_D1,0,1,v)==1?v[0]:0; }
   return 0;
}

datetime MT4_iTime(string s,int tf,int shift){ MqlRates r[1]; return CopyRates(s,(ENUM_TIMEFRAMES)tf,shift,1,r)==1?r[0].time:0; }
int MT4_iBars(string s,int tf){ return Bars(s,(ENUM_TIMEFRAMES)tf); }
double MT4_iHigh(string s,int tf,int shift){ double v[1]; return CopyHigh(s,(ENUM_TIMEFRAMES)tf,shift,1,v)==1?v[0]:0; }
double MT4_iLow(string s,int tf,int shift){ double v[1]; return CopyLow(s,(ENUM_TIMEFRAMES)tf,shift,1,v)==1?v[0]:0; }
double MT4_iOpen(string s,int tf,int shift){ double v[1]; return CopyOpen(s,(ENUM_TIMEFRAMES)tf,shift,1,v)==1?v[0]:0; }
double MT4_iClose(string s,int tf,int shift){ double v[1]; return CopyClose(s,(ENUM_TIMEFRAMES)tf,shift,1,v)==1?v[0]:0; }
double MT4_iATR(string s,int tf,int period,int shift)
{
   int h=iATR(s,(ENUM_TIMEFRAMES)tf,period); if(h==INVALID_HANDLE) return 0;
   double v[1]; double out=(CopyBuffer(h,0,shift,1,v)==1?v[0]:0); IndicatorRelease(h); return out;
}
int MT4_iHighest(string s,int tf,int mode,int count,int start)
{
   double v[]; ArrayResize(v,count); int n=(mode==MODE_HIGH?CopyHigh(s,(ENUM_TIMEFRAMES)tf,start,count,v):CopyLow(s,(ENUM_TIMEFRAMES)tf,start,count,v));
   if(n<=0) return -1; int best=0; for(int i=1;i<n;i++) if((mode==MODE_HIGH&&v[i]>v[best])||(mode==MODE_LOW&&v[i]<v[best])) best=i; return start+(n-1-best);
}
int MT4_iLowest(string s,int tf,int mode,int count,int start){ return MT4_iHighest(s,tf,MODE_LOW,count,start); }
#define iTime MT4_iTime
#define iBars MT4_iBars
#define iHigh MT4_iHigh
#define iLow MT4_iLow
#define iOpen MT4_iOpen
#define iClose MT4_iClose
#define iATR MT4_iATR
#define iHighest MT4_iHighest
#define iLowest MT4_iLowest

#define OrdersTotal PositionsTotal
int OrdersHistoryTotal(){ HistorySelect(0,TimeCurrent()); return HistoryDealsTotal(); }
bool OrderSelect(ulong value,int select,int pool=MODE_TRADES)
{
   __mt4_history=(pool==MODE_HISTORY);
   if(select==SELECT_BY_POS)
   {
      if(pool==MODE_TRADES){ __mt4_ticket=PositionGetTicket((int)value); return __mt4_ticket>0; }
      HistorySelect(0,TimeCurrent()); __mt4_ticket=HistoryDealGetTicket((int)value); return __mt4_ticket>0;
   }
   __mt4_ticket=value;
   if(PositionSelectByTicket(value)){ __mt4_history=false; return true; }
   HistorySelect(0,TimeCurrent()); __mt4_history=HistoryDealSelect(value); return __mt4_history;
}
string OrderSymbol(){ return __mt4_history?HistoryDealGetString(__mt4_ticket,DEAL_SYMBOL):PositionGetString(POSITION_SYMBOL); }
long OrderMagicNumber(){ return __mt4_history?HistoryDealGetInteger(__mt4_ticket,DEAL_MAGIC):PositionGetInteger(POSITION_MAGIC); }
int OrderType(){ return (int)(__mt4_history?HistoryDealGetInteger(__mt4_ticket,DEAL_TYPE):PositionGetInteger(POSITION_TYPE)); }
double OrderLots(){ return __mt4_history?HistoryDealGetDouble(__mt4_ticket,DEAL_VOLUME):PositionGetDouble(POSITION_VOLUME); }
double OrderOpenPrice(){ return __mt4_history?HistoryDealGetDouble(__mt4_ticket,DEAL_PRICE):PositionGetDouble(POSITION_PRICE_OPEN); }
double OrderStopLoss(){ return __mt4_history?0:PositionGetDouble(POSITION_SL); }
double OrderTakeProfit(){ return __mt4_history?0:PositionGetDouble(POSITION_TP); }
ulong OrderTicket(){ return __mt4_ticket; }
datetime OrderCloseTime(){ return __mt4_history?(datetime)HistoryDealGetInteger(__mt4_ticket,DEAL_TIME):0; }
double OrderProfit(){ return __mt4_history?HistoryDealGetDouble(__mt4_ticket,DEAL_PROFIT):PositionGetDouble(POSITION_PROFIT); }
double OrderSwap(){ return __mt4_history?HistoryDealGetDouble(__mt4_ticket,DEAL_SWAP):PositionGetDouble(POSITION_SWAP); }
double OrderCommission(){ return __mt4_history?HistoryDealGetDouble(__mt4_ticket,DEAL_COMMISSION):0; }
string OrderComment(){ return __mt4_history?HistoryDealGetString(__mt4_ticket,DEAL_COMMENT):PositionGetString(POSITION_COMMENT); }

ENUM_ORDER_TYPE_FILLING MT5Filling(string s)
{
   long f=SymbolInfoInteger(s,SYMBOL_FILLING_MODE);
   if((f&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if((f&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}
int OrderSend(string symbol,int cmd,double volume,double price,int deviation,double sl,double tp,string comment,long magic,datetime expiration=0,color arrow=clrNONE)
{
   MqlTradeRequest q={}; MqlTradeResult r={};
   q.action=TRADE_ACTION_DEAL; q.symbol=symbol; q.volume=volume; q.magic=magic; q.deviation=deviation;
   q.type=(cmd==OP_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL); q.price=(cmd==OP_BUY?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID));
   q.sl=sl; q.tp=tp; q.comment=comment; q.type_filling=MT5Filling(symbol); q.type_time=ORDER_TIME_GTC;
   if(!::OrderSend(q,r) || (r.retcode!=TRADE_RETCODE_DONE && r.retcode!=TRADE_RETCODE_PLACED)) return -1;
   if(PositionSelect(symbol)) return (int)PositionGetInteger(POSITION_TICKET);
   return (int)(r.order>0?r.order:r.deal);
}
bool OrderModify(ulong ticket,double price,double sl,double tp,datetime expiration=0,color arrow=clrNONE)
{
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest q={}; MqlTradeResult r={}; q.action=TRADE_ACTION_SLTP; q.position=ticket; q.symbol=PositionGetString(POSITION_SYMBOL); q.sl=sl; q.tp=tp;
   return ::OrderSend(q,r) && r.retcode==TRADE_RETCODE_DONE;
}
bool OrderClose(ulong ticket,double lots,double price,int deviation,color arrow=clrNONE)
{
   if(!PositionSelectByTicket(ticket)) return false; string s=PositionGetString(POSITION_SYMBOL); long pt=PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest q={}; MqlTradeResult r={}; q.action=TRADE_ACTION_DEAL; q.position=ticket; q.symbol=s; q.volume=lots; q.deviation=deviation;
   q.type=(pt==POSITION_TYPE_BUY?ORDER_TYPE_SELL:ORDER_TYPE_BUY); q.price=(q.type==ORDER_TYPE_BUY?SymbolInfoDouble(s,SYMBOL_ASK):SymbolInfoDouble(s,SYMBOL_BID)); q.type_filling=MT5Filling(s);
   return ::OrderSend(q,r) && r.retcode==TRADE_RETCODE_DONE;
}
string ErrorDescription(int e){ return IntegerToString(e); }

#endif

