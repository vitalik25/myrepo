#property strict
#property version "2.05"
#property description "Buy-Martingale EA für XAUUSD Cent-Konten (mit Trailing SL)"

#include <Trade\Trade.mqh>
#include <Controls\Button.mqh>

CTrade trade;
CButton m_tradeButton;
CButton m_closeAllButton;

//--- Eingaben
input double MaxLot = 6.00;
input double AbstandPips = 350.0;
input double TakeProfitPips = 150.0;     // Standard TP
input double SingleProfitTPPips = 300.0; // Wenn nur 1 Pos offen und im Gewinn
input int MaxOrderWithMartingale = 8;
input int MaxOrders = 15;
input double Martingale = 1.6;
input double TrailingStopPips = 75.0;
input string EAComment = "BuyMartingaleEA";
input bool IsTrading = false;

// --- Drawdown-Schutz
input double MaxDrawdownPercent = 50.0; // Bei x % Equity-Verlust alles schließen
input bool isDebugEnabled = false;
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
   pipValueCached = PipValue();

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
   m_tradeButton.Text("RUN");
   m_tradeButton.ColorBackground(clrGreen);

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
   ChartSetSymbolPeriod(0, Symbol(), PERIOD_M15);

   magicNumber = GetPersistentMagicNumber();
   StartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   return (INIT_SUCCEEDED);
}

//------------------------------------------------------------------
// Hauptlogik
//------------------------------------------------------------------
void OnTick()
{
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

   // --- 5. Nachkauf-Logik ---
   if (orderCount > 0)
   {
      double lastOpen = BuyOrders[orderCount - 1].openPrice;
      if ((lastOpen - bid) >= PipsToPrice(AbstandPips) && orderCount < MaxOrders)
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
   // HIER: Prüft und korrigiert den TP, wenn eine Position manuell geschlossen wurde
   double oldWeightedEntryPrice = weightedEntryPrice;

   // Berechne den neuen gewichteten Einstiegspreis
   weightedEntryPrice = BerechneWeightedEntryPrice();

   // Berechne den Basis-TP basierend auf dem NEUEN gewichteten Einstieg
   double newBaseTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);

   // Prüfe, ob sich der Einstiegspreis signifikant geändert hat (z.B. > 1 Pip)
   if (MathAbs(weightedEntryPrice - oldWeightedEntryPrice) > PipsToPrice(1.0))
   {
      // Der TP wird nach einer manuellen Schließung immer auf den Basis-TP zurückgesetzt,
      // da das Trailing TP entfernt wurde.
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
         currentTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);
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
// Trailing Stop-Loss Update
//------------------------------------------------------------------
void UpdateTrailingSL()
{
   if (ArraySize(BuyOrders) == 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double weightedPrice = BerechneWeightedEntryPrice();

   // 1. Berechne den aktuellen Gewinn in Pips seit dem gewichteten Einstieg
   // Da es Buy-Positionen sind, gilt: (Bid - gewichteter Einstieg) / Pip-Wert
   double currentProfitPips = (bid - weightedPrice) / pipValueCached;

   // Aktivierungsschwelle: SL wird nur gesetzt, wenn der Gewinn die Trailing-Schwelle überschreitet.
   // TrailingStopPips (z.B. 75 Pips) ist hier der MINIMALE Profit, den das Netz
   // haben muss, damit der Stop-Loss aktiviert wird.

   if (currentProfitPips >= TrailingStopPips)
   {
      // 2. Berechnung des neuen SL-Preises: Bid-Preis minus Trailing-Abstand (in Pips)
      // Der Abstand, den der SL zum aktuellen Preis hält, wird mit TrailingStopPips beibehalten.
      double newSL = bid - PipsToPrice(TrailingStopPips); // HIER: TrailingStopPips als Abstand verwendet

      // NEUER SPREAD-AUSGLEICH
      double currentSpread = ask - bid;

      // 3. BREAK-EVEN-GARANTIE (Korrektur):
      // Der Stop-Loss muss MINDESTENS den gewichteten Einstiegspreis abdecken.
      // Wir ziehen den newSL nur nach, wenn er HÖHER ist als der aktuelle SL.

      // Zuerst den Break-Even-Preis berechnen (Einstieg + minimaler Puffer für Kosten, z.B. 1 Pip)
      double breakEvenPrice = weightedPrice + currentSpread + PipsToPrice(3.0); // 1.0 Pip Puffer

      // Der neue SL ist der HÖHERE Wert aus (dem berechneten Trailing SL) und (dem Break-Even SL)
      double finalSL = MathMax(newSL, breakEvenPrice);

      // 3. Nur nachziehen (SL nur erhöhen)
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

            // Führe die Aktualisierung nur durch, wenn SL > 0 (nicht bei 0.0)
            if (currentSLPrice > 0.0)
            {
               OrderSend(req, res);
            }
         }
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
   weightedEntryPrice = 0;
}

//------------------------------------------------------------------
// Pip-Wert
double PipValue()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // --- Metalle (XAU, XAG, XPT, XPD, etc.) → 1 pip = point
   if (StringFind(_Symbol, "XAU") == 0 || StringFind(_Symbol, "XAG") == 0)
      return point;

   // --- Standard-FX-Paare (z. B. EURUSD 1.08854 → 5 Digits) → 1 pip = 10 * point
   //if (digits == 3 || digits == 5)
   //   return point * 10.0;

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
// Lot-Berechnung für MT5 ProCent Accounts
// Start = 0.01 Lot pro 100 USD (10.000 Cent)
// Danach Martingale bis max. 10 Orders
// Danach wieder BasisLot (z.B. 0.01)
double BerechneLot()
{
   double balanceCent = AccountInfoDouble(ACCOUNT_EQUITY); // Balance in Cent
   double balanceUSD = balanceCent / 100.0;                // Umrechnen in USD
   int orderIndex = ArraySize(BuyOrders);

   // --- Startlot = 0.01 Lot pro 100 USD
   double startLot = balanceUSD * 0.0001;
   startLot = NormalizeLot(startLot);
   double lot = 0.00;

   if (orderIndex < MaxOrderWithMartingale)
   {
      // --- Martingale bis max. 10 Orders
      lot = startLot * MathPow(Martingale, orderIndex);
   }
   else
   {
      // --- Ab der 11. Order wieder BasisLot
      lot = startLot;
   }

   if (lot > MaxLot)
   {
      lot = startLot;
   }

   PrintFormat("StartLot = %.5f,  OderIndex= %.5f, Lot = %.5f", startLot, orderIndex, lot);

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
      ulong ticket = PositionGetInteger(POSITION_TICKET);
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
// Weighted Entry & gemeinsamer TP
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

// Standard: gewichteter Einstieg + TakeProfitPips
double BerechneGemeinsamenTPPrice(double tpPips)
{
   double currentWeighted = BerechneWeightedEntryPrice();
   if (currentWeighted <= 0.0)
      return 0.0;
   return currentWeighted + PipsToPrice(tpPips);
}

//------------------------------------------------------------------
// Setze TP fuer alle Buys
void SetzeTPForAll(double tpPrice)
{
   MqlTradeRequest req;
   MqlTradeResult res;
   for (int i = 0; i < ArraySize(BuyOrders); i++)
   {
      ZeroMemory(req);
      ZeroMemory(res);

      req.action = TRADE_ACTION_SLTP;
      req.position = BuyOrders[i].ticket;
      req.symbol = _Symbol;

      // Wir behalten den aktuellen SL bei (entweder 0.0 oder der Trailing SL)
      req.sl = NormalizeDouble(currentSLPrice, _Digits);
      req.tp = NormalizeDouble(tpPrice, _Digits);

      if (OrderSend(req, res))
      {
         if (isDebugEnabled)
            PrintFormat("TP/SL aktualisiert fuer Ticket %I64u", BuyOrders[i].ticket);
      }
      else
      {
         if (res.comment != "No changes")
            if (isDebugEnabled)
               PrintFormat("TP/SL-Update fehlgeschlagen fuer Ticket %I64u: %s", BuyOrders[i].ticket, res.comment);
      }
   }
}

//------------------------------------------------------------------
// Buy-Oeffnung
bool OeffneBuy(double lots)
{
   trade.SetExpertMagicNumber((long)magicNumber);
   bool ok = trade.Buy(lots, NULL, 0, 0, NULL, EAComment);
   if (!ok)
      if (isDebugEnabled)
         PrintFormat("OeffneBuy fehlgeschlagen! Lots=%.2f, Comment=%s, Error=%s", lots, EAComment, trade.ResultComment());
      else
         PrintFormat("BUY geoeffnet: %.2f Lots @ %.5f", lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
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
      req.deviation = 10;
      req.magic = (long)magicNumber;

      if (!OrderSend(req, res))
         if (isDebugEnabled)
            PrintFormat("Schliessen fehlgeschlagen fuer Ticket %I64u: %s", BuyOrders[i].ticket, res.comment);
         else
            PrintFormat("BUY geschlossen fuer Ticket %I64u", BuyOrders[i].ticket);
   }
}

// ------------------------------------------------------------------
// Prüft Drawdown relativ zum StartEquity und schließt alle Positionen
// (Handel bleibt aktiv, es wird nichts deaktiviert)
bool CheckAndHandleDrawdown()
{
   if (StartEquity <= 0.0)
      return false;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = StartEquity - currentEquity;
   double lossPercent = (loss / StartEquity) * 100.0;

   if (lossPercent >= MaxDrawdownPercent)
   {
      if (isDebugEnabled)
         PrintFormat("DRAWNDOWN %.2f%% >= %.2f%% -> Alle Positionen werden geschlossen!", lossPercent, MaxDrawdownPercent);

      // Alle offenen Positionen schließen
      AktualisiereBuyOrders();
      CloseAllBuys();
      ArrayFree(BuyOrders);
      ClearAllObjects();

      // Neues StartEquity setzen, damit Drawdown nicht mehrfach auslöst
      StartEquity = currentEquity;

      if (isDebugEnabled)
         PrintFormat("Alle Positionen geschlossen – Handel läuft weiter. Neues StartEquity=%.2f", StartEquity);
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
   ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 1);
}

// Klick auf Button abfangen
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
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

      // --- NEU: Button: Close All ---
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
            Print("Manuelles Schließen aller Positionen angefordert.");
            CloseAllBuys();
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
   // Name of the file where we store the magic number
   string filename = "magic_" + IntegerToString(chartId) + ".txt";

   if (isDebugEnabled)
      Print("[DEBUG] Magic Number file " + filename);

   // --- Try to read existing magic number ---
   int fileHandle = FileOpen(filename, FILE_READ | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      magicNumber = (int)StringToInteger(FileReadString(fileHandle));
      if (isDebugEnabled)
         Print("[DEBUG] LESE FILE " + (string)magicNumber);
      FileClose(fileHandle);
   }

   // --- If not found, create a new one ---
   if (magicNumber == 0)
   {
      MathSrand((uint)TimeLocal() + chartId);
      magicNumber = (int)(100000 + MathRand() % 900000); // 6-digit number

      fileHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT);
      if (fileHandle != INVALID_HANDLE)
      {
         if (isDebugEnabled)
            Print("[DEBUG] SCHREIBE FILE " + (string)magicNumber);
         FileWrite(fileHandle, magicNumber);
         FileClose(fileHandle);
      }
   }

   return magicNumber;
}