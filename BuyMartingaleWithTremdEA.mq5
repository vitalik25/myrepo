#property strict
#property version "2.0.08"
#property description "Buy-Martingale EA für XAUUSD Cent-Konten (Optimized for RoboForex 2-digit)"

#include <Trade\Trade.mqh>
#include <Controls\Button.mqh>

CTrade trade;
CButton m_tradeButton;
CButton m_closeAllButton;

//--- Eingaben
input double MaxLot = 6.00;
input double AbstandPips = 400.0;
input double TakeProfitPips = 150.0; // Increased from 100 to 150
input double SingleProfitTPPips = 400.0;
input double DistanceMultiplier = 1.15;
input int MaxOrderWithMartingale = 10;
input int MaxOrders = 35;
input double Martingale = 1.2;
input double TrailingStopPips = 150.0; // Increased from 75 to 150
input double SLAfterBidPips = 80; // Increased from 20 to 80
input bool IsTrading = false;

// --- Adaptive TP Settings
input bool UseAdaptiveTP = true;
input double AdaptiveTPIncrement = 30.0; // Add 30 pips per order beyond 5

// --- Drawdown-Schutz
input double MaxDrawdownPercent = 90.0;
input bool isDebugEnabled = false;
input bool isWarnEnabled = true;
double StartEquity = 0.0;

//--- Farben Visualisierung
color clrEntry = clrLime;
color clrTP = clrGold;
bool isTrading = IsTrading;

//--- Struktur fuer offene Positionen
struct OrderInfo
{
   ulong ticket;
   double lots;
   double openPrice;
};
OrderInfo BuyOrders[];

double highestBidSinceOpen = 0.0;
double currentTPPrice = 0.0;
double currentSLPrice = 0.0;
double weightedEntryPrice = 0.0;
double pipValueCached = 0.0;
int magicNumber = 0;
long chartId = ChartID();

//------------------------------------------------------------------
// Initialisierung
int OnInit()
{
   int chart_width = (int)ChartGetInteger(chartId, CHART_WIDTH_IN_PIXELS, 0);
   int chart_height = (int)ChartGetInteger(chartId, CHART_HEIGHT_IN_PIXELS, 0);

   int btn_width = 120;
   int btn_height = 40;
   int margin_top = 20;
   int spacing = 10;

   int total_width = (2 * btn_width) + spacing;
   int x_start = (chart_width / 2) - (total_width / 2);
   int y1 = margin_top;
   int y2 = y1 + btn_height;

   int x1_trade = x_start;
   int x2_trade = x1_trade + btn_width;
   m_tradeButton.Create(chartId, "TradeButton", 0, x1_trade, y1, x2_trade, y2);
   
   // Sync button state with IsTrading input
   if (isTrading)
   {
      m_tradeButton.Text("PAUSE");
      m_tradeButton.ColorBackground(clrRed);
   }
   else
   {
      m_tradeButton.Text("RUN");
      m_tradeButton.ColorBackground(clrGreen);
   }

   int x1_close = x2_trade + spacing;
   int x2_close = x1_close + btn_width;

   m_closeAllButton.Create(chartId, "CloseAllButton", 0, x1_close, y1, x2_close, y2);
   m_closeAllButton.Text("CloseAll");
   m_closeAllButton.ColorBackground(clrOrange);

   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_BID_LINE, true);
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, true);
   ChartSetInteger(0, CHART_SHOW_TRADE_HISTORY, false);

   magicNumber = GetPersistentMagicNumber();
   StartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   pipValueCached = PipValue();

   return (INIT_SUCCEEDED);
}

//------------------------------------------------------------------
// Hauptlogik
//------------------------------------------------------------------
void OnTick()
{
   long marketStatus = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if ((marketStatus & SYMBOL_TRADE_MODE_FULL) == 0)
   {
       if (isWarnEnabled)
           Print("[WARN]: OrderSend verhindert, da Markt geschlossen ist.");
       return;
   }
   
   AktualisiereBuyOrders();
   int orderCount = ArraySize(BuyOrders);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if (CheckAndHandleDrawdown())
   {
      ResetState();
      return;
   }

   if (OpenFirstOrder(orderCount, bid))
   {
      return;
   }

   if (HandleOnePositiveOrder(orderCount, bid))
   {
      return;
   }

   changedAfterManualClosing();

   UpdateTrailingSL();

   if (orderCount > 0 && orderCount < MaxOrders)
   {
       double lastOpen = BuyOrders[orderCount - 1].openPrice;
       
       double dynamicAbstand = AbstandPips;
       if (orderCount > 1)
       {
          dynamicAbstand = AbstandPips * MathPow(DistanceMultiplier, orderCount - 1);
       }
    
       if ((lastOpen - bid) >= PipsToPrice(dynamicAbstand))
       {
          double lot = BerechneLot();
          if (OeffneBuy(lot))
          {
             AktualisiereBuyOrders();
             weightedEntryPrice = BerechneWeightedEntryPrice();
             currentTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);
             SetzeTPForAll(currentTPPrice);
          }
       }
    }

   DrawVisuals(currentTPPrice);
}

bool HandleOnePositiveOrder(int orderCount, double bid)
{
   if (orderCount == 1)
   {
      ulong ticket = BuyOrders[0].ticket;
      if (PositionSelectByTicket(ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if (profit > 0.0)
         {
            currentTPPrice = weightedEntryPrice + PipsToPrice(SingleProfitTPPips);
            if (isDebugEnabled)
               PrintFormat("[DEBUG] SINGLE PROFIT (BUY): profit=%.5f currentTP=%.5f weightedEntry=%.5f", profit, currentTPPrice, weightedEntryPrice);
            highestBidSinceOpen = bid;
            SetzeTPForAll(currentTPPrice);
            DrawVisuals(currentTPPrice);

            if (bid >= currentTPPrice && currentTPPrice > 0)
            {
               CloseAllBuys();
               ResetState();
               return true;
            }
            DrawVisuals(currentTPPrice);
         }
      }
   }
   return false;
}

void changedAfterManualClosing()
{
   double oldWeightedEntryPrice = weightedEntryPrice;
   weightedEntryPrice = BerechneWeightedEntryPrice();
   double newBaseTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);
   if (MathAbs(weightedEntryPrice - oldWeightedEntryPrice) > PipsToPrice(1.0))
   {
      currentTPPrice = newBaseTPPrice;
      if (isDebugEnabled)
         PrintFormat("[DEBUG] TP-Recalculate nach Order-Aenderung: %.5f", currentTPPrice);
      SetzeTPForAll(currentTPPrice);
   }
}

bool OpenFirstOrder(int &orderCount, double bid)
{
   if (orderCount == 0 && isTrading)
   {
      double lot = BerechneLot();
      if (OeffneBuy(lot))
      {
         AktualisiereBuyOrders();
         orderCount = ArraySize(BuyOrders);
         weightedEntryPrice = BerechneWeightedEntryPrice();
         currentTPPrice = BerechneGemeinsamenTPPrice(SingleProfitTPPips);
         highestBidSinceOpen = bid;
         currentSLPrice = 0.0;
         SetzeTPForAll(currentTPPrice);
         DrawVisuals(currentTPPrice);
      }

      if (orderCount == 0)
      {
         ResetState();
      }

      return true;
   }
   return false;
}

//------------------------------------------------------------------
// IMPROVED: Trailing Stop-Loss Update with Spread Awareness
//------------------------------------------------------------------
void UpdateTrailingSL()
{
   if (ArraySize(BuyOrders) == 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double weightedPrice = BerechneWeightedEntryPrice();

   double currentProfitPips = (bid - weightedPrice) / pipValueCached;

   if (currentProfitPips >= TrailingStopPips)
   {
      // Calculate current spread
      double currentSpread = ask - bid;
      double spreadPips = currentSpread / pipValueCached;
      
      // Buffer must be: Spread + Safety margin (minimum 30 pips)
      double minBufferPips = spreadPips + 30.0;
      double actualBufferPips = MathMax(SLAfterBidPips, minBufferPips);
      
      if (isDebugEnabled && actualBufferPips > SLAfterBidPips)
         PrintFormat("[DEBUG] SL buffer adjusted: %.0f → %.0f pips (spread: %.0f)", 
                     SLAfterBidPips, actualBufferPips, spreadPips);
      
      double newSL = bid - PipsToPrice(actualBufferPips);

      // Break-even guarantee with spread compensation
      double safetyPufferPips = 50.0;
      if (ArraySize(BuyOrders) == 1)
      {
         safetyPufferPips = 80.0;
      }

      double breakEvenPrice = weightedPrice + currentSpread + PipsToPrice(safetyPufferPips);
      double finalSL = MathMax(newSL, breakEvenPrice);

      if (finalSL > currentSLPrice)
      {
         currentSLPrice = finalSL;

         MqlTradeRequest req;
         MqlTradeResult res;
         for (int i = 0; i < ArraySize(BuyOrders); i++)
         {
            ZeroMemory(req);
            ZeroMemory(res);
            req.action = TRADE_ACTION_SLTP;
            req.position = BuyOrders[i].ticket;
            req.symbol = _Symbol;
            req.sl = NormalizeDouble(currentSLPrice, _Digits);
            req.tp = NormalizeDouble(currentTPPrice, _Digits);

            if (currentSLPrice > 0.0)
            {
               OrderSend(req, res);
            }
         }
         
         if (isDebugEnabled)
            PrintFormat("[DEBUG] Trailing SL updated to %.5f (buffer: %.0f pips)", currentSLPrice, actualBufferPips);
      }
   }
}

void ResetState()
{
   ArrayFree(BuyOrders);
   ClearAllObjects();
   highestBidSinceOpen = 0;
   currentTPPrice = 0;
   currentSLPrice = 0;
   weightedEntryPrice = 0;
}

//------------------------------------------------------------------
// Pip-Wert
double PipValue()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // RoboForex XAUUSD: 2 digits → 1 pip = 0.01 = point
   if (StringFind(_Symbol, "XAU") == 0 || StringFind(_Symbol, "XAG") == 0)
      return point;

   if (digits == 3 || digits == 5)
      return point * 10.0;

   return point;
}

double PipsToPrice(double pips)
{
   return pips * pipValueCached;
}

//------------------------------------------------------------------
// Lotberechnung Cent-Konto
double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step <= 0)
      step = 0.01;
   double lots = MathFloor(lot / step + 0.0000001) * step;
   double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if (lots < minlot)
      lots = minlot;
   if (lots > maxlot)
      lots = maxlot;
   return NormalizeDouble(lots, 2);
}

//------------------------------------------------------------------
// IMPROVED: Lot Calculation - Continue Martingale with MaxLot Cap
//------------------------------------------------------------------
double BerechneLot()
{
   double balanceCent = AccountInfoDouble(ACCOUNT_EQUITY);
   double balanceUSD = balanceCent / 100.0;
   int orderIndex = ArraySize(BuyOrders);

   double startLot = balanceUSD * 0.0001;
   startLot = NormalizeLot(startLot);
   
   // Continue Martingale progression, capped at MaxLot
   double lot = startLot * MathPow(Martingale, orderIndex);
   
   if (lot > MaxLot)
   {
      lot = MaxLot; // Use MaxLot instead of resetting to startLot
      
      if (isWarnEnabled && orderIndex == MaxOrderWithMartingale)
         PrintFormat("[INFO] Order %d reached MaxLot (%.2f), maintaining max size", orderIndex + 1, MaxLot);
   }

   if (isDebugEnabled)
      PrintFormat("[DEBUG] Order %d: StartLot=%.5f, Calculated=%.5f, Final=%.5f", 
                  orderIndex + 1, startLot, startLot * MathPow(Martingale, orderIndex), lot);

   return NormalizeLot(lot);
}

//------------------------------------------------------------------
// Positionsermittlung
void AktualisiereBuyOrders()
{
   ArrayFree(BuyOrders);
   int total = PositionsTotal();
   for (int i = 0; i < total; i++)
   {
      ulong posTicket = PositionGetTicket(i);

      if (posTicket == 0)
         continue;

      if (PositionSelectByTicket(posTicket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if (symbol == _Symbol &&
             PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY &&
             PositionGetInteger(POSITION_MAGIC) == (long)magicNumber)
         {
            OrderInfo info;
            info.ticket = PositionGetInteger(POSITION_TICKET);
            info.lots = PositionGetDouble(POSITION_VOLUME);
            info.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            int n = ArraySize(BuyOrders);
            ArrayResize(BuyOrders, n + 1);
            BuyOrders[n] = info;
         }
      }
   }
}

//------------------------------------------------------------------
// Weighted Entry
double BerechneWeightedEntryPrice()
{
   double sumLots = 0.0, sumPriceLots = 0.0;
   for (int i = 0; i < ArraySize(BuyOrders); i++)
   {
      sumLots += BuyOrders[i].lots;
      sumPriceLots += BuyOrders[i].openPrice * BuyOrders[i].lots;
   }
   if (sumLots <= 0.0)
      return 0.0;
   return sumPriceLots / sumLots;
}

//------------------------------------------------------------------
// IMPROVED: Adaptive TP Calculation
//------------------------------------------------------------------
double BerechneGemeinsamenTPPrice(double tpPips)
{
   double currentWeighted = BerechneWeightedEntryPrice();
   if (currentWeighted <= 0.0)
      return 0.0;
   
   int orderCount = ArraySize(BuyOrders);
   double adaptiveTP = tpPips;
   
   // Adaptive TP: Scale with number of orders
   if (UseAdaptiveTP && orderCount > 5)
   {
      // For every order beyond 5, add AdaptiveTPIncrement pips
      // Example: Order 12 = 150 + (12-5)×30 = 360 pips
      adaptiveTP = tpPips + ((orderCount - 5) * AdaptiveTPIncrement);
      
      if (isDebugEnabled)
         PrintFormat("[DEBUG] Adaptive TP: %d orders → %.0f pips (base: %.0f, increment: %.0f)", 
                     orderCount, adaptiveTP, tpPips, AdaptiveTPIncrement);
   }
   
   return currentWeighted + PipsToPrice(adaptiveTP);
}

//------------------------------------------------------------------
// Setze TP fuer alle Buys (mit Broker-Mindestabstand-Pruefung)
void SetzeTPForAll(double tpPrice)
{
    MqlTradeRequest req;
    MqlTradeResult res;
    
    int stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    
    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    double minDistancePrice = (double)stopLevelPoints * _Point;
    
    double minSafeTP = currentAsk + minDistancePrice;
    double normalizedTargetTP = NormalizeDouble(tpPrice, _Digits);

    if (normalizedTargetTP < minSafeTP && normalizedTargetTP > 0)
    {
        if (isWarnEnabled)
             PrintFormat("[WARN] TP-Korrektur: Ziel-TP (%.5f) liegt zu nah am Ask (%.5f). Erhöht auf MinSafe: %.5f", 
                         normalizedTargetTP, currentAsk, minSafeTP);
                         
        normalizedTargetTP = NormalizeDouble(minSafeTP + _Point, _Digits);  
    }
    
    double maxSafeSL = currentBid - minDistancePrice;
    double normalizedSL = NormalizeDouble(currentSLPrice, _Digits);

    if (normalizedSL > 0 && normalizedSL > maxSafeSL) 
    {
         if (isWarnEnabled)
             PrintFormat("[WARN] SL-Korrektur: Ziel-SL (%.5f) liegt zu nah am Bid (%.5f). Gesenkt auf MaxSafe: %.5f", 
                         normalizedSL, currentBid, maxSafeSL);
                         
         normalizedSL = NormalizeDouble(maxSafeSL - _Point, _Digits); 
    }

    for (int i = 0; i < ArraySize(BuyOrders); i++)
    {
        double currentPositionTP = 0.0;
        double currentPositionSL = 0.0;
        
        if(PositionSelectByTicket(BuyOrders[i].ticket))
        {
            currentPositionTP = PositionGetDouble(POSITION_TP);
            currentPositionSL = PositionGetDouble(POSITION_SL);
        }
        
        if(MathAbs(currentPositionTP - normalizedTargetTP) > _Point || 
           MathAbs(currentPositionSL - normalizedSL) > _Point)
        {
            ZeroMemory(req);
            ZeroMemory(res);

            req.action = TRADE_ACTION_SLTP;
            req.position = BuyOrders[i].ticket;
            req.symbol = _Symbol;
            req.sl = normalizedSL;
            req.tp = normalizedTargetTP;

            if (!OrderSend(req, res))
            {
                if (res.comment != "No changes")
                {
                    if (isWarnEnabled)
                         PrintFormat("[WARN] TP/SL-Update fehlgeschlagen fuer Ticket %I64u: %s", BuyOrders[i].ticket, res.comment);
                }
            }
            else
            {
               if (isDebugEnabled)
                   PrintFormat("[DEBUG] TP/SL aktualisiert fuer Ticket %I64u auf SL %.5f / TP %.5f", BuyOrders[i].ticket, normalizedSL, normalizedTargetTP);
            }
        }
    }
}

//------------------------------------------------------------------
// Buy-Oeffnung
bool OeffneBuy(double lots)
{
   string EAComment = "BuyMartingaleEA_v2.08";
   trade.SetExpertMagicNumber((long)magicNumber);
   bool ok = trade.Buy(lots, NULL, 0, 0, 0, EAComment);
   if (!ok)
   {
      if (isWarnEnabled)
         PrintFormat("[WARN] OeffneBuy fehlgeschlagen! Lots=%.2f, Error=%s", lots, trade.ResultComment());
   }
   else
   {
      PrintFormat("[INFO] BUY geoeffnet: %.2f Lots @ %.5f", lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
   }
   return ok;
}

//------------------------------------------------------------------
// Alle Buy-Orders schliessen
void CloseAllBuys()
{
   MqlTradeRequest req;
   MqlTradeResult res;
   for (int i = 0; i < ArraySize(BuyOrders); i++)
   {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.position = BuyOrders[i].ticket;
      req.volume = BuyOrders[i].lots;
      req.type = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      req.deviation = 50; // Increased from 10 to 50 for better fill rate
      req.magic = (long)magicNumber;

      if (!OrderSend(req, res))
      {
         if (isWarnEnabled)
            PrintFormat("[WARN] Schliessen fehlgeschlagen fuer Ticket %I64u: %s", BuyOrders[i].ticket, res.comment);
      }
      else
      {
         PrintFormat("[INFO] BUY geschlossen fuer Ticket %I64u", BuyOrders[i].ticket);
      }
   }
   
   StartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
}

//------------------------------------------------------------------
// IMPROVED: Drawdown Check with Margin Level Monitoring
bool CheckAndHandleDrawdown()
{
   if (StartEquity <= 0.0)
      return false;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = StartEquity - currentEquity;
   double lossPercent = (loss / StartEquity) * 100.0;
   
   // Also check margin level
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   bool marginCritical = (marginLevel < 150.0 && marginLevel > 0);

   if (lossPercent >= MaxDrawdownPercent)
   {
      PrintFormat("[CRITICAL] DRAWDOWN %.2f%% >= %.2f%% -> Alle Positionen werden geschlossen!", lossPercent, MaxDrawdownPercent);

      AktualisiereBuyOrders();
      CloseAllBuys();
      ArrayFree(BuyOrders);
      ClearAllObjects();

      StartEquity = currentEquity;

      PrintFormat("[INFO] Alle Positionen geschlossen – Handel läuft weiter. Neues StartEquity=%.2f", StartEquity);
      return true;
   }
   
   if (marginCritical && ArraySize(BuyOrders) > 0)
   {
      PrintFormat("[CRITICAL] LOW MARGIN: %.2f%% - Schließe alle Positionen!", marginLevel);
      
      AktualisiereBuyOrders();
      CloseAllBuys();
      ArrayFree(BuyOrders);
      ClearAllObjects();
      
      StartEquity = currentEquity;
      return true;
   }

   return false;
}

//------------------------------------------------------------------
// Visualisierung
void ClearAllObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for (int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if (StringFind(name, "EA_") == 0)
         ObjectDelete(0, name);
   }
}

void DrawVisuals(double tpPrice)
{
   ClearAllObjects();

   for (int i = 0; i < ArraySize(BuyOrders); i++)
   {
      string name = StringFormat("EA_%s_%I64u_Entry", _Symbol, BuyOrders[i].ticket);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, BuyOrders[i].openPrice);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrEntry);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

      string label = StringFormat("EA_%s_%I64u_Label", _Symbol, BuyOrders[i].ticket);
      string text = StringFormat("BUY #%d | %.2f lots @ %.2f", i + 1, BuyOrders[i].lots, BuyOrders[i].openPrice);
      ObjectCreate(0, label, OBJ_TEXT, 0, TimeCurrent(), BuyOrders[i].openPrice);
      ObjectSetString(0, label, OBJPROP_TEXT, text);
      ObjectSetInteger(0, label, OBJPROP_COLOR, clrEntry);
      ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, label, OBJPROP_ANCHOR, ANCHOR_LEFT);

      double labelOffset = PipValue() * (5 + 10 * i);
      ObjectMove(0, label, 0, TimeCurrent(), BuyOrders[i].openPrice + labelOffset);
   }

   string tpName = "EA_TP_Line_" + _Symbol;
   ObjectCreate(0, tpName, OBJ_HLINE, 0, 0, tpPrice);
   ObjectSetInteger(0, tpName, OBJPROP_COLOR, clrTP);
   ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 2);
   
   // Add TP label
   string tpLabel = "EA_TP_Label_" + _Symbol;
   int orderCount = ArraySize(BuyOrders);
   double tpPipsUsed = UseAdaptiveTP && orderCount > 5 ? 
                       TakeProfitPips + ((orderCount - 5) * AdaptiveTPIncrement) : 
                       TakeProfitPips;
   string tpText = StringFormat("TP: %.2f (%.0f pips) | Orders: %d", tpPrice, tpPipsUsed, orderCount);
   ObjectCreate(0, tpLabel, OBJ_TEXT, 0, TimeCurrent(), tpPrice);
   ObjectSetString(0, tpLabel, OBJPROP_TEXT, tpText);
   ObjectSetInteger(0, tpLabel, OBJPROP_COLOR, clrTP);
   ObjectSetInteger(0, tpLabel, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, tpLabel, OBJPROP_ANCHOR, ANCHOR_LEFT);
}

// Klick auf Button abfangen
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if (id == CHARTEVENT_OBJECT_CLICK)
   {
      if (sparam == "TradeButton")
      {
         isTrading = !isTrading;

         if (isTrading)
         {
            m_tradeButton.Text("PAUSE");
            m_tradeButton.ColorBackground(clrRed);
         }
         else
         {
            m_tradeButton.Text("RUN");
            m_tradeButton.ColorBackground(clrGreen);
         }

         if (isDebugEnabled)
            Print("[DEBUG] TRADING IS: " + (string)isTrading);

         ChartRedraw(chartId);
      }

      if (sparam == "CloseAllButton")
      {
         AktualisiereBuyOrders();
         if (ArraySize(BuyOrders) == 0)
         {
            MessageBox("Es sind keine offenen Positionen zum Schließen vorhanden.", "Information", MB_OK | MB_ICONINFORMATION);
            return;
         }

         int result = MessageBox("Wollen Sie wirklich ALLE Positionen schließen?", "ALLE Positionen schließen", MB_YESNO | MB_ICONQUESTION);

         if (result == IDYES)
         {
            Print("[INFO] Manuelles Schließen aller Positionen angefordert.");
            CloseAllBuys();
            ResetState();
           
            m_tradeButton.Text("RUN");
            m_tradeButton.ColorBackground(clrGreen);
            isTrading = false;
            ChartRedraw(chartId);
         }
      }
   }
}

//+------------------------------------------------------------------+
int GetPersistentMagicNumber()
{
   string filename = "magic_" + IntegerToString(chartId) + ".txt";

   if (isDebugEnabled)
      Print("[DEBUG] Magic Number file " + filename);

   int fileHandle = FileOpen(filename, FILE_READ | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      magicNumber = (int)StringToInteger(FileReadString(fileHandle));
      if (isDebugEnabled)
         Print("[DEBUG] Magic Number gelesen: " + (string)magicNumber);
      FileClose(fileHandle);
   }

   if (magicNumber == 0)
   {
      MathSrand((uint)TimeLocal
