//+------------------------------------------------------------------+
//|                                        GoldBTC_HedgeGrid_EA.mq5   |
//|                    黄金(XAUUSD)/比特币(BTCUSD) 双向对冲阶梯加仓 EA |
//|                    https://github.com/jliushi/mt5-gold-btc-ea     |
//+------------------------------------------------------------------+
#property copyright "jliushi"
#property link      "https://github.com/jliushi/mt5-gold-btc-ea"
#property version   "1.00"
#property description "黄金/比特币 双向对冲·逆势阶梯加仓·总盈利达标全平·秒进秒出保护 EA"

#include <Trade\Trade.mqh>

//====================== 输入参数 ======================
input group           "=== 基础 ==="
input long            InpMagic          = 20260928;      // 魔术号(不同图表设不同值)
input double          InpTargetProfit   = 50.0;          // 总盈利目标(账户货币)达标全平

input group           "=== 手数与加仓 ==="
input double          InpFirstLot       = 0.01;          // 首单固定手数
input double          InpAddLot         = 0.01;          // 逆势加仓固定手数
input double          InpMaxLotPerOrder = 1.00;          // 单次最大手数(封顶)
input int             InpMaxAddCount    = 10;            // 最大加仓次数(每方向)
input double          InpGridStepPoints = 300;           // 逆势阶梯间距(点)

input group           "=== 均线(仅展示;首单不看金叉死叉) ==="
input int             InpFastMA         = 20;            // 快速均线周期
input int             InpSlowMA         = 60;            // 慢速均线周期
input ENUM_MA_METHOD  InpMAMethod       = MODE_SMA;      // 均线方法
input ENUM_TIMEFRAMES InpMATF           = PERIOD_CURRENT;// 均线时间周期

input group           "=== 风控 ==="
input double          InpMaxSpreadPoints= 50;            // 最大点差(点)超限禁止开仓
input bool            InpOpenBuyFirst   = true;          // 自动开多首单
input bool            InpOpenSellFirst  = true;          // 自动开空首单

input group           "=== 秒进秒出保护 ==="
input int             InpScalpSeconds   = 15;            // 单轮存活<该秒数=秒进秒出
input int             InpScalpMaxStreak = 3;             // 连续N轮秒进秒出则停止EA

//====================== 全局变量 ======================
CTrade   trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;

bool     g_paused     = false;   // 用户暂停
bool     g_stopped    = false;   // 秒进秒出锁定停止
int      g_streak     = 0;       // 连续秒进秒出轮数
datetime g_cycleStart = 0;       // 本轮建仓起始时间
bool     g_prevHasPos = false;

double   g_point;
int      g_digits;

string   PFX = "GBEA_";          // 面板对象前缀

//--- 跨重启持久化的 GlobalVariable 名
string GVN(string k){ return "GBEA_"+_Symbol+"_"+(string)InpMagic+"_"+k; }

void PersistState()
{
   GlobalVariableSet(GVN("stopped"), g_stopped ? 1 : 0);
   GlobalVariableSet(GVN("streak"),  g_streak);
   GlobalVariableSet(GVN("cycle"),   (double)(long)g_cycleStart);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_point  = _Point;
   g_digits = (int)_Digits;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hFast = iMA(_Symbol, InpMATF, InpFastMA, 0, InpMAMethod, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpMATF, InpSlowMA, 0, InpMAMethod, PRICE_CLOSE);
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE)
   { Print("均线句柄创建失败"); return(INIT_FAILED); }

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("⚠ 当前非对冲账户,双向对冲需 Hedging(对冲) 账户模式!");

   if(GlobalVariableCheck(GVN("stopped"))) g_stopped   =(GlobalVariableGet(GVN("stopped"))>0.5);
   if(GlobalVariableCheck(GVN("streak")))  g_streak    =(int)GlobalVariableGet(GVN("streak"));
   if(GlobalVariableCheck(GVN("cycle")))   g_cycleStart=(datetime)(long)GlobalVariableGet(GVN("cycle"));

   BuildPanel();
   EventSetTimer(1);
   RefreshPanel();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTimer(){ RefreshPanel(); }

//====================== 工具函数 ======================
double SpreadPoints()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(g_point<=0) return(0);
   return((ask-bid)/g_point);
}
bool SpreadOK(){ return(SpreadPoints() <= InpMaxSpreadPoints); }

double NormLot(double lot)
{
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(lot>InpMaxLotPerOrder) lot=InpMaxLotPerOrder;   // 单次最大手数封顶
   if(step>0) lot=MathFloor(lot/step+0.5)*step;
   if(lot<minL) lot=minL;
   if(lot>maxL) lot=maxL;
   return(NormalizeDouble(lot,2));
}

bool OpenBuy (double lot,string cmt){ return(trade.Buy (NormLot(lot),_Symbol,0.0,0.0,0.0,cmt)); }
bool OpenSell(double lot,string cmt){ return(trade.Sell(NormLot(lot),_Symbol,0.0,0.0,0.0,cmt)); }

bool ReadMA(double &fast,double &slow)
{
   double a[1], b[1];
   if(CopyBuffer(hFast,0,0,1,a)<1) return(false);
   if(CopyBuffer(hSlow,0,0,1,b)<1) return(false);
   fast=a[0]; slow=b[0];
   return(true);
}

void ScanPositions(int &buyCnt,double &buyVol,double &buyProfit,double &lowestBuy,
                   int &selCnt,double &selVol,double &selProfit,double &highestSell)
{
   buyCnt=0; buyVol=0; buyProfit=0; lowestBuy=0;
   selCnt=0; selVol=0; selProfit=0; highestSell=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      long   type=PositionGetInteger(POSITION_TYPE);
      double vol =PositionGetDouble(POSITION_VOLUME);
      double op  =PositionGetDouble(POSITION_PRICE_OPEN);
      double pf  =PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(type==POSITION_TYPE_BUY)
      {
         buyCnt++; buyVol+=vol; buyProfit+=pf;
         if(lowestBuy==0 || op<lowestBuy) lowestBuy=op;
      }
      else if(type==POSITION_TYPE_SELL)
      {
         selCnt++; selVol+=vol; selProfit+=pf;
         if(op>highestSell) highestSell=op;
      }
   }
}

void CloseAllPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      trade.PositionClose(ticket);
   }
}

//====================== 主逻辑 ======================
void OnTick()
{
   int    buyCnt,selCnt;
   double buyVol,selVol,buyProfit,selProfit,lowestBuy,highestSell;
   ScanPositions(buyCnt,buyVol,buyProfit,lowestBuy,selCnt,selVol,selProfit,highestSell);
   int    totalCnt   =buyCnt+selCnt;
   double totalProfit=buyProfit+selProfit;
   bool   hasPos     =(totalCnt>0);

   //--- 记录本轮建仓开始(由空仓->有仓)
   if(hasPos && !g_prevHasPos){ g_cycleStart=TimeCurrent(); PersistState(); }

   //--- 唯一自动平仓:总浮盈达标全平(无均价止盈止损/无跟踪止损)
   if(hasPos && InpTargetProfit>0 && totalProfit>=InpTargetProfit)
   {
      datetime dur=TimeCurrent()-g_cycleStart;
      CloseAllPositions();
      if(g_cycleStart>0 && dur>=0 && dur<InpScalpSeconds)   // 秒进秒出判定
      {
         g_streak++;
         if(g_streak>=InpScalpMaxStreak){ g_stopped=true; Print("⚠ 连续",g_streak,"轮秒进秒出,EA已停止"); }
      }
      else g_streak=0;
      g_cycleStart=0; g_prevHasPos=false; PersistState(); RefreshPanel();
      return;
   }
   g_prevHasPos=hasPos;

   //--- 停止/暂停:不开新仓
   if(g_stopped || g_paused) return;

   double gridStep=InpGridStepPoints*g_point;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   //--- 首单:无仓位,不看金叉死叉,全天自动开多空首单
   if(totalCnt==0)
   {
      if(!SpreadOK()) return;                 // 点差超限禁止开仓
      if(InpOpenBuyFirst)  OpenBuy (InpFirstLot,"first-buy");
      if(InpOpenSellFirst) OpenSell(InpFirstLot,"first-sell");
      return;
   }

   //--- 逆势阶梯加仓(不看均线交叉;顺势加仓已关闭)
   if(!SpreadOK()) return;                    // 点差超限也禁止加仓
   if(buyCnt>0 && (buyCnt-1)<InpMaxAddCount && bid<=lowestBuy-gridStep)   // 多单逆势=价格下跌
   { OpenBuy(InpAddLot,"add-buy"); return; }
   if(selCnt>0 && (selCnt-1)<InpMaxAddCount && ask>=highestSell+gridStep) // 空单逆势=价格上涨
   { OpenSell(InpAddLot,"add-sell"); return; }
}

//====================== 面板 UI ======================
void SetLine(int i,string text,color clr)
{
   string name=PFX+"l"+(string)i;
   ObjectSetString (0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}

void CreateLabel(string tag,int x,int y,string text,color clr,int fs,string font)
{
   string name=PFX+tag;
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetString (0,name,OBJPROP_TEXT,text);
}

void CreateButton(string tag,int x,int y,int w,int h,string text,color bg)
{
   string name=PFX+tag;
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetString (0,name,OBJPROP_FONT,"Microsoft YaHei");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetString (0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

void CreateRect(string tag,int x,int y,int w,int h,color bg)
{
   string name=PFX+tag;
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,bg);
}

void BuildPanel()
{
   int PX=14, PY=26, PW=300;
   CreateRect  ("bg",   PX-6,PY-6,PW,272,C'28,28,34');
   CreateLabel ("title",PX,PY,"◆ 黄金/BTC 双向阶梯 EA",clrGold,11,"Microsoft YaHei");
   CreateButton("btnToggle",PX,    PY+26,88,24,"暂停",C'0,122,204');
   CreateButton("btnClose", PX+96, PY+26,88,24,"全平",C'176,58,46');
   CreateButton("btnReset", PX+192,PY+26,88,24,"复位",C'92,92,98');
   for(int i=0;i<11;i++) CreateLabel("l"+(string)i,PX,PY+62+i*17,"",clrWhite,9,"Consolas");
}

void RefreshPanel()
{
   int    buyCnt,selCnt;
   double buyVol,selVol,buyProfit,selProfit,lowestBuy,highestSell;
   ScanPositions(buyCnt,buyVol,buyProfit,lowestBuy,selCnt,selVol,selProfit,highestSell);
   double totalProfit=buyProfit+selProfit;
   double sp=SpreadPoints();
   double fast=0,slow=0; bool okma=ReadMA(fast,slow);

   string st = g_stopped ? "已停止(秒进秒出)" : (g_paused ? "已暂停" : "运行中");
   color  stc= g_stopped ? clrOrangeRed     : (g_paused ? clrGold  : clrLime);
   ObjectSetString(0,PFX+"btnToggle",OBJPROP_TEXT, g_paused ? "运行" : "暂停");

   SetLine(0, "状态: "+st, stc);
   SetLine(1, StringFormat("点差 %.0f / 上限%.0f  %s", sp, InpMaxSpreadPoints,
              (sp<=InpMaxSpreadPoints?"可开":"禁开")), (sp<=InpMaxSpreadPoints?clrSilver:clrOrangeRed));
   SetLine(2, okma ? StringFormat("MA%d=%s MA%d=%s [%s]", InpFastMA,DoubleToString(fast,g_digits),
              InpSlowMA,DoubleToString(slow,g_digits),(fast>slow?"多头":"空头")) : "MA: 加载中", clrSilver);
   SetLine(3, StringFormat("多单 %d 笔  手数 %.2f", buyCnt, buyVol), C'120,200,255');
   SetLine(4, StringFormat("  多单浮盈 %.2f", buyProfit), buyProfit>=0?clrLime:clrTomato);
   SetLine(5, StringFormat("空单 %d 笔  手数 %.2f", selCnt, selVol), C'255,180,120');
   SetLine(6, StringFormat("  空单浮盈 %.2f", selProfit), selProfit>=0?clrLime:clrTomato);
   SetLine(7, StringFormat("加仓 多%d/空%d  上限%d", MathMax(0,buyCnt-1), MathMax(0,selCnt-1), InpMaxAddCount), clrSilver);
   SetLine(8, StringFormat("总浮盈 %.2f  目标 %.2f", totalProfit, InpTargetProfit), totalProfit>=0?clrLime:clrTomato);
   SetLine(9, StringFormat("秒进秒出 %d/%d 轮", g_streak, InpScalpMaxStreak), g_streak>0?clrGold:clrSilver);
   SetLine(10,StringFormat("间距%.0f点 首单%.2f 加仓%.2f", InpGridStepPoints, InpFirstLot, InpAddLot), clrGray);
   ChartRedraw();
}
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(sparam==PFX+"btnToggle")
   {
      g_paused=!g_paused;
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RefreshPanel();
   }
   else if(sparam==PFX+"btnClose")           // 手动全平(应急)
   {
      CloseAllPositions();
      g_cycleStart=0; g_prevHasPos=false; PersistState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RefreshPanel();
   }
   else if(sparam==PFX+"btnReset")           // 解除秒进秒出停止
   {
      g_stopped=false; g_streak=0; PersistState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RefreshPanel();
   }
}
//+------------------------------------------------------------------+
