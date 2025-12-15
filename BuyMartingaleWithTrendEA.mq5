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
input double TakeProfitPips = 150.0; // Erhöht von 100 auf 150 für bessere Recovery
input double SingleProfitTPPips = 400.0;
input double DistanceMultiplier = 1.15;
input int MaxOrderWithMartingale = 10; // Nur noch informativ - Martingale läuft weiter bis MaxLot
input int MaxOrders = 35;
input double Martingale = 1.2;
input double TrailingStopPips = 150.0; // Erhöht von 75 auf 150 für RoboForex Spread
input double SLAfterBidPips = 80; // Erhöht von 20 auf 80 wegen Spread-Kompensation
input bool IsTrading = false;

// --- Adaptive TP Einstellungen (NEU)
input bool UseAdaptiveTP = true; // TP skaliert automatisch mit Anzahl der Orders
input double AdaptiveTPIncrement = 30.0; // Pro Order über 5 werden 30 Pips zum TP addiert

// --- Drawdown-Schutz
input double MaxDrawdownPercent = 90.0; // Bei 90% Equity-Verlust alles schließen
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

   // --- RUN/PAUSE Button (links) ---
   int x1_trade = x_start;
   int x2_trade = x1_trade + btn_width;
   m_tradeButton.Create(chartId, "TradeButton", 0, x1_trade, y1, x2_trade, y2);
   
   // FIXED: Button-Status wird jetzt mit IsTrading Input synchronisiert
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

   // --- Close All Button (rechts) ---
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
   // --- Pruefen, ob Handel erlaubt ist ---
   long marketStatus = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if ((marketStatus & SYMBOL_TRADE_MODE_FULL) == 0)
   {
       // Der EA sollte hier keine Order senden (Markt geschlossen)
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

   // --- 1. Keine offenen Orders ---
   if (OpenFirstOrder(orderCount, bid))
   {
      return;
   }

   // --- 2. Spezialfall: Nur eine Position und im Gewinn ---
   if (HandleOnePositiveOrder(orderCount, bid))
   {
      return;
   }

   // --- 3. Offene Orders: Anpassung des TP nach manueller Änderung ---
   changedAfterManualClosing();

   // --- 4. Trailing SL ---
   UpdateTrailingSL();

   // --- 5. Nachkauf-Logik mit dynamischem Abstand ---
    if (orderCount > 0 && orderCount < MaxOrders)
    {
       double lastOpen = BuyOrders[orderCount - 1].openPrice;
       
       // 1. Berechnung des dynamischen Abstands
       double dynamicAbstand = AbstandPips;
       if (orderCount > 1)
       {
          // Der Abstand wird exponentiell mit DistanceMultiplier erhöht
          dynamicAbstand = AbstandPips * MathPow(DistanceMultiplier, orderCount - 1);
       }
    
       // 2. Prüfung: Ist der Abstand zur letzten Order groß genug?
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
// VERBESSERT: Trailing Stop-Loss mit Spread-Awareness
//------------------------------------------------------------------
void UpdateTrailingSL()
{
   if (ArraySize(BuyOrders) == 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double weightedPrice = BerechneWeightedEntryPrice();

   // 1. Berechne den aktuellen Gewinn in Pips seit dem gewichteten Einstieg
   double currentProfitPips = (bid - weightedPrice) / pipValueCached;

   // Aktivierungsschwelle: SL wird nur gesetzt, wenn Gewinn die Trailing-Schwelle überschreitet
   if (currentProfitPips >= TrailingStopPips)
   {
      // 2. FIXED: Spread-bewusste Buffer-Berechnung
      // Der Buffer muss MINDESTENS Spread + 30 Pips betragen
      double currentSpread = ask - bid;
      double spreadPips = currentSpread / pipValueCached;
      
      // Mindestbuffer: Spread + 30 Pips Sicherheitsmarge
      double minBufferPips = spreadPips + 30.0;
      double actualBufferPips = MathMax(SLAfterBidPips, minBufferPips);
      
      if (isDebugEnabled && actualBufferPips > SLAfterBidPips)
         PrintFormat("[DEBUG] SL buffer adjusted: %.0f → %.0f pips (spread: %.0f)", 
                     SLAfterBidPips, actualBufferPips, spreadPips);
      
      // 3. Berechnung des neuen SL-Preises mit dynamischem Buffer
      double newSL = bid - PipsToPrice(actualBufferPips);

      // 4. BREAK-EVEN-GARANTIE mit Spread-Kompensation
      double safetyPufferPips = 50.0;
      if (ArraySize(BuyOrders) == 1)
      {
         // Einzelorder benötigt größeren Puffer für garantierten Gewinn
         safetyPufferPips = 80.0;
      }

      // Break-Even Preis = gewichteter Einstieg + aktueller Spread + Sicherheitspuffer
      double breakEvenPrice = weightedPrice + currentSpread + PipsToPrice(safetyPufferPips);
      
      // Der finale SL ist das MAXIMUM aus (Trailing SL) und (Break-Even SL)
      double finalSL = MathMax(newSL, breakEvenPrice);

      // 5. Nur nachziehen (SL nur erhöhen, nie senken)
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

            // Führe die Aktualisierung nur durch, wenn SL > 0
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

// --- Hilfsfunktion: State zurücksetzen ---
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
// Pip-Wert für RoboForex 2-Digit Gold
double PipValue()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // --- Metalle (XAU, XAG, XPT, XPD, etc.) → 1 pip = point
   // RoboForex XAUUSD: 2 digits (z.B. 2600.45) → 1 pip = 0.01
   if (StringFind(_Symbol, "XAU") == 0 || StringFind(_Symbol, "XAG") == 0)
      return point;

   // --- Standard-FX-Paare (z. B. EURUSD 1.08854 → 5 Digits) → 1 pip = 10 * point
    if (digits == 3 || digits == 5)
      return point * 10.0;

   // --- sonst (Indices, Krypto etc.) → 1 pip = point
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
// VERBESSERT: Lot-Berechnung - Martingale läuft weiter bis MaxLot
// Start = 0.01 Lot pro 100 USD (10.000 Cent)
// Martingale-Progression wird fortgesetzt, begrenzt nur durch MaxLot
//------------------------------------------------------------------
double BerechneLot()
{
   double balanceCent = AccountInfoDouble(ACCOUNT_EQUITY); // Balance in Cent
   double balanceUSD = balanceCent / 100.0;                // Umrechnen in USD
   int orderIndex = ArraySize(BuyOrders);

   // --- Startlot = 0.01 Lot pro 100 USD
   double startLot = balanceUSD * 0.0001;
   startLot = NormalizeLot(startLot);
   
   // FIXED: Martingale-Progression läuft kontinuierlich weiter
   // Wird nur durch MaxLot begrenzt, nicht mehr nach 10 Orders zurückgesetzt
   double lot = startLot * MathPow(Martingale, orderIndex);
   
   if (lot > MaxLot)
   {
      // FIXED: Verwende MaxLot statt zurück zu startLot
      // Dies erhält die Recovery-Power in extremen Drawdowns
      lot = MaxLot;
      
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
// VERBESSERT: Adaptive TP-Berechnung basierend auf Order-Anzahl
// TP skaliert automatisch mit der Tiefe des Drawdowns
//------------------------------------------------------------------
double BerechneGemeinsamenTPPrice(double tpPips)
{
   double currentWeighted = BerechneWeightedEntryPrice();
   if (currentWeighted <= 0.0)
      return 0.0;
   
   int orderCount = ArraySize(BuyOrders);
   double adaptiveTP = tpPips;
   
   // FIXED: Adaptive TP - TP wird mit Anzahl der Orders erhöht
   // Dies stellt sicher, dass auch frühe Orders profitabel schließen
   if (UseAdaptiveTP && orderCount > 5)
   {
      // Für jede Order über 5 wird AdaptiveTPIncrement (30 Pips) zum TP addiert
      // Beispiel: 12 Orders = 150 + (12-5)×30 = 360 Pips TP
      adaptiveTP = tpPips + ((orderCount - 5) * AdaptiveTPIncrement);
      
      if (isDebugEnabled)
         PrintFormat("[DEBUG] Adaptive TP: %d orders → %.0f pips (base: %.0f, increment: %.0f)", 
                     orderCount, adaptiveTP, tpPips, AdaptiveTPIncrement);
   }
   
   return currentWeighted + PipsToPrice(adaptiveTP);
}

//------------------------------------------------------------------
// Setze TP fuer alle Buys (mit Broker-Mindestabstand-Prüfung)
void SetzeTPForAll(double tpPrice)
{
    MqlTradeRequest req;
    MqlTradeResult res;
    
    // --- Broker-Anforderungen abrufen ---
    // Mindestabstand (in Points) für Stops
    int stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    
    // Aktueller Marktpreis
    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    // Umrechnung des Mindestabstands in einen Preis
    double minDistancePrice = (double)stopLevelPoints * _Point;
    
    // --- TP-Prüfung (relevant für BUY: muss über Ask sein) ---
    // Der TP muss MINDESTENS (Ask + Mindestabstand) sein
    double minSafeTP = currentAsk + minDistancePrice;
    double normalizedTargetTP = NormalizeDouble(tpPrice, _Digits);

    if (normalizedTargetTP < minSafeTP && normalizedTargetTP > 0)
    {
        if (isWarnEnabled)
             PrintFormat("[WARN] TP-Korrektur: Ziel-TP (%.5f) liegt zu nah am Ask (%.5f). Erhöht auf MinSafe: %.5f", 
                         normalizedTargetTP, currentAsk, minSafeTP);
                         
        // TP auf minimal sicheren Abstand + einen Point Puffer setzen
        normalizedTargetTP = NormalizeDouble(minSafeTP + _Point, _Digits);  
    }
    
    // --- SL-Prüfung (relevant für BUY: muss unter Bid sein) ---
    // Der SL muss MAXIMAL (Bid - Mindestabstand) sein
    double maxSafeSL = currentBid - minDistancePrice;
    double normalizedSL = NormalizeDouble(currentSLPrice, _Digits);

    // Die Prüfung nur durchführen, wenn der SL aktiv ist (currentSLPrice > 0)
    if (normalizedSL > 0 && normalizedSL > maxSafeSL) 
    {
         if (isWarnEnabled)
             PrintFormat("[WARN] SL-Korrektur: Ziel-SL (%.5f) liegt zu nah am Bid (%.5f). Gesenkt auf MaxSafe: %.5f", 
                         normalizedSL, currentBid, maxSafeSL);
                         
         // SL auf maximal sicheren Abstand - einen Point Puffer setzen
         normalizedSL = NormalizeDouble(maxSafeSL - _Point, _Digits); 
    }

    for (int i = 0; i < ArraySize(BuyOrders); i++)
    {
        // --- Prüfen, ob ein Update überhaupt nötig ist ---
        // Dies verhindert unnötige [No changes]-Meldungen
        double currentPositionTP = 0.0;
        double currentPositionSL = 0.0;
        
        if(PositionSelectByTicket(BuyOrders[i].ticket))
        {
            currentPositionTP = PositionGetDouble(POSITION_TP);
            currentPositionSL = PositionGetDouble(POSITION_SL);
        }
        
        // Nur senden, wenn sich der TP oder der SL tatsächlich ändert
        if(MathAbs(currentPositionTP - normalizedTargetTP) > _Point || 
           MathAbs(currentPositionSL - normalizedSL) > _Point)
        {
            ZeroMemory(req);
            ZeroMemory(res);

            req.action = TRADE_ACTION_SLTP;
            req.position = BuyOrders[i].ticket;
            req.symbol = _Symbol;
            req.sl = normalizedSL;        // Verwende den geprüften SL-Wert
            req.tp = normalizedTargetTP;  // Verwende den geprüften TP-Wert

            if (!OrderSend(req, res))
            {
                // Warnung nur anzeigen, wenn es sich nicht um "No changes" handelt
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
      req.deviation = 50; // FIXED: Erhöht von 10 auf 50 für bessere Fill-Rate
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
   
   // Zyklus beendet → neuen Startpunkt setzen
   StartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
}

//------------------------------------------------------------------
// VERBESSERT: Drawdown-Check mit Margin-Level-Überwachung
// Prüft Drawdown relativ zum StartEquity und schließt alle Positionen
// Zusätzlich: Margin-Level-Schutz gegen Margin Call
bool CheckAndHandleDrawdown()
{
   if (StartEquity <= 0.0)
      return false;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = StartEquity - currentEquity;
   double lossPercent = (loss / StartEquity) * 100.0;
   
   // FIXED: Auch Margin-Level überwachen
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   bool marginCritical = (marginLevel < 150.0 && marginLevel > 0);

   if (lossPercent >= MaxDrawdownPercent)
   {
      PrintFormat("[CRITICAL] DRAWDOWN %.2f%% >= %.2f%% -> Alle Positionen werden geschlossen!", lossPercent, MaxDrawdownPercent);

      // Alle offenen Positionen schließen
      AktualisiereBuyOrders();
      CloseAllBuys();
      ArrayFree(BuyOrders);
      ClearAllObjects();

      // Neues StartEquity setzen, damit Drawdown nicht mehrfach auslöst
      StartEquity = currentEquity;

      PrintFormat("[INFO] Alle Positionen geschlossen – Handel läuft weiter. Neues StartEquity=%.2f", StartEquity);
      return true;
   }
   
   // FIXED: Zusätzlicher Schutz bei niedrigem Margin Level
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

//------------------------------------------------------------------
// Visualisierung mit verbessertem TP-Label
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

   // TP-Linie
   string tpName = "EA_TP_Line_" + _Symbol;
   ObjectCreate(0, tpName, OBJ_HLINE, 0, 0, tpPrice);
   ObjectSetInteger(0, tpName, OBJPROP_COLOR, clrTP);
   ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 2);
   
   // FIXED: TP-Label zeigt jetzt adaptive Pips an
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

         // Toggle the button state und appearance
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

         ChartRedraw(chartId); // Update the chart
      }

      // --- Button: Close All ---
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
            
            // BUGFIX: Internen Zustand nach manuellem Schließen zurücksetzen
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
// Persistente Magic Number (Chart-spezifisch)
int GetPersistentMagicNumber()
{
   // Name der Datei, in der die Magic Number gespeichert wird
   string filename = "magic_" + IntegerToString(chartId) + ".txt";

   if (isDebugEnabled)
      Print("[DEBUG] Magic Number file " + filename);

   // --- Versuche, existierende Magic Number zu lesen ---
   int fileHandle = FileOpen(filename, FILE_READ | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      magicNumber = (int)StringToInteger(FileReadString(fileHandle));
      if (isDebugEnabled)
         Print("[DEBUG] Magic Number gelesen: " + (string)magicNumber);
      FileClose(fileHandle);
   }

   // --- Wenn nicht gefunden, erstelle eine neue ---
   if (magicNumber == 0)
   {
      MathSrand((uint)TimeLocal() + chartId);
      magicNumber = (int)(100000 + MathRand() % 900000); // 6-stellige Zahl

      fileHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT);
      if (fileHandle != INVALID_HANDLE)
      {
         if (isDebugEnabled)
            Print("[DEBUG] Magic Number geschrieben: " + (string)magicNumber);
         FileWrite(fileHandle, magicNumber);
         FileClose(fileHandle);
      }
   }

   return magicNumber;
}
