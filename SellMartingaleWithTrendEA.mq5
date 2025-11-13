#property strict
#property version "2.05"
#property description "Sell-Martingale EA für XAUUSD Cent-Konten (mit Trailing SL)"

#include <Trade\Trade.mqh>
#include <Controls\Button.mqh>

CTrade trade;
CButton m_tradeButton;
CButton m_closeAllButton;

//--- Eingaben
input double MaxLot = 6.00;
input double AbstandPips = 350.0;
input double TakeProfitPips = 150.0;
input double SingleProfitTPPips = 300.0;
input int MaxOrderWithMartingale = 8;
input int MaxOrders = 15;
input double Martingale = 1.6;
input double TrailingStopPips = 75.0;        // ab wieviel Gewinn SL aktiviert wird
input string EAComment = "SellMartingaleEA"; // PASST: Kommentar geändert
input bool IsTrading = false;

// --- Drawdown-Schutz
input double MaxDrawdownPercent = 50.0; // Bei x % Equity-Verlust alles schließen
input bool isDebugEnabled = false;
double StartEquity = 0.0;

//--- Farben Visualisierung
color clrEntry = clrRed; // PASST: Farbe für Sell (Rot)
color clrTP = clrGold;
bool isTrading = IsTrading;

//--- Struktur fuer offene Positionen
struct OrderInfo
{
   ulong ticket;
   double lots;
   double openPrice;
};
OrderInfo SellOrders[];

double lowestAskSinceOpen = 0.0;
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
   AktualisiereSellOrders();                           // PASST: Funktionsaufruf geändert
   int orderCount = ArraySize(SellOrders);             // PASST: Array-Name geändert
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // PASST: Wir nutzen ASK für SELL-Einstieg/TP

   if (CheckAndHandleDrawdown())
   {
      ResetState();
      return;
   }

   // --- 1. Keine offenen Orders ---
   if (OpenFirstOrder(orderCount, ask))
   {
      return;
   }

   // --- 2. Spezialfall: Nur eine Order und im Gewinn ---
   if (HandleOnePositiveOrder(orderCount, ask))
   {
      return;
   }

   // --- 2. Offene Orders: Anpassung des TP nach manueller Änderung ---
   ChangedAfterManualClosing();

   // --- 4. TP erreicht? Alles schließen ---
   if (ask <= currentTPPrice && currentTPPrice > 0)
   {
      CloseAllSells();
      ResetState();
      return;
   }

   // --- 6. Trailing SL ---
   UpdateTrailingSL();

   // --- 7. Nachkauf-Logik (Nachlegen bei Verlust) ---
   if (orderCount > 0)
   {
      double lastOpen = SellOrders[orderCount - 1].openPrice;
      if ((ask - lastOpen) >= PipsToPrice(AbstandPips) && orderCount < MaxOrders)
      {
         double lot = BerechneLot();
         if (OeffneSell(lot))
         {
            AktualisiereSellOrders();
            weightedEntryPrice = BerechneWeightedEntryPrice();
            currentTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);
            SetzeTPForAll(currentTPPrice);
         }
      }
   }

   DrawVisuals(currentTPPrice);
}

bool HandleOnePositiveOrder(int orderCount, double ask)
{
   // --- 3. Spezialfall: Nur 1 Position und im Gewinn ---
   if (orderCount == 1)
   {
      ulong ticket = SellOrders[0].ticket;
      if (PositionSelectByTicket(ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if (profit > 0.0)
         {
            currentTPPrice = weightedEntryPrice - PipsToPrice(SingleProfitTPPips);
            if (isDebugEnabled)
               PrintFormat("[DEBUG] SINGLE PROFIT (SELL): profit=%.5f currentTP=%.5f weightedEntry=%.5f", profit, currentTPPrice, weightedEntryPrice);

            lowestAskSinceOpen = ask;
            SetzeTPForAll(currentTPPrice);
            DrawVisuals(currentTPPrice);

            if (ask <= currentTPPrice && currentTPPrice > 0)
            {
               CloseAllSells();
               ResetState();
               return true;
            }
            DrawVisuals(currentTPPrice);
         }
      }
   }
   return false;
}

void ChangedAfterManualClosing()
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
      currentTPPrice = newBaseTPPrice;
      if (isDebugEnabled)
         PrintFormat("[DEBUG] TP-Recalculate nach Order-Aenderung: %.5f", currentTPPrice);
      SetzeTPForAll(currentTPPrice);
   }
}

bool OpenFirstOrder(int &orderCount, double ask)
{
   if (orderCount == 0 && isTrading)
   {
      double lot = BerechneLot();
      if (OeffneSell(lot)) // PASST: Funktionsaufruf geändert
      {
         AktualisiereSellOrders(); // PASST: Funktionsaufruf geändert
         orderCount = ArraySize(SellOrders);
         weightedEntryPrice = BerechneWeightedEntryPrice();
         currentTPPrice = BerechneGemeinsamenTPPrice(TakeProfitPips);
         lowestAskSinceOpen = ask; // PASST: Tracking umgekehrt
         currentSLPrice = 0.0;
         SetzeTPForAll(currentTPPrice);
         DrawVisuals(currentTPPrice);
      }

      if (orderCount == 0)
         ResetState();

      return true;
   }
   return false;
}

//------------------------------------------------------------------
// Trailing Stop-Loss Update
//------------------------------------------------------------------
void UpdateTrailingSL()
{
   if (ArraySize(SellOrders) == 0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double weightedPrice = BerechneWeightedEntryPrice();

   // 1. Berechne den aktuellen Gewinn in Pips
   double currentProfitPips = (weightedPrice - ask) / pipValueCached;

   // Aktivierungsschwelle: SL wird nur gesetzt, wenn der Gewinn die Schwelle überschreitet.
   if (currentProfitPips >= TrailingStopPips)
   {
      // 2. Berechnung des idealen Trailing SL-Preises:
      // Er liegt ÜBER dem aktuellen ASK-Preis, gesichert durch TrailingStopPips (z.B. 75 Pips)
      double newTrailingSL = ask + PipsToPrice(TrailingStopPips);

      // NEUER SPREAD-AUSGLEICH
      double currentSpread = ask - bid;

      // 3. Break-Even-Schutz: SL darf den Einstiegspreis nicht überschreiten (Sell)
      // Wir sichern hier 1 Pip Gewinn
      double breakEvenPrice = weightedPrice - currentSpread - PipsToPrice(3.0);

      // 4. Der tatsächliche SL-Preis:
      // Er muss der NIEDRIGSTE Preis sein zwischen (newTrailingSL) und (BreakEvenPrice),
      // da der SL bei Sell kleiner (tiefer) als der Einstiegspreis sein muss, um Gewinn zu sichern.
      double finalSL = MathMin(newTrailingSL, breakEvenPrice);

      // 5. Nur nachziehen (SL nur verringern)
      // Bei SELL wird der SL kleiner (näher zum TP).
      if (finalSL < currentSLPrice || currentSLPrice == 0.0)
      {
         currentSLPrice = finalSL;

         MqlTradeRequest req;
         MqlTradeResult res;
         for (int i = 0; i < ArraySize(SellOrders); i++)
         {
            ZeroMemory(req);
            ZeroMemory(res);
            req.action = TRADE_ACTION_SLTP;
            req.position = SellOrders[i].ticket;
            req.symbol = _Symbol;
            req.sl = NormalizeDouble(currentSLPrice, _Digits);
            req.tp = NormalizeDouble(currentTPPrice, _Digits);

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
   ArrayFree(SellOrders); // PASST: Array-Name geändert
   ClearAllObjects();
   lowestAskSinceOpen = 0; // PASST: Variable geändert
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
   int orderIndex = ArraySize(SellOrders);

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
void AktualisiereSellOrders() // PASST: Funktionsname geändert
{
   ArrayFree(SellOrders); // PASST: Array-Name geändert
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
             PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && // PASST: Positionstyp geändert
             PositionGetInteger(POSITION_MAGIC) == (long)magicNumber)
         {
            OrderInfo info;
            info.ticket = PositionGetInteger(POSITION_TICKET);
            info.lots = PositionGetDouble(POSITION_VOLUME);
            info.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            int n = ArraySize(SellOrders);  // PASST: Array-Name geändert
            ArrayResize(SellOrders, n + 1); // PASST: Array-Name geändert
            SellOrders[n] = info;           // PASST: Array-Name geändert
         }
      }
   }
}

//------------------------------------------------------------------
// Weighted Entry & gemeinsamer TP
double BerechneWeightedEntryPrice()
{
   double sumLots = 0.0, sumPriceLots = 0.0;
   for (int i = 0; i < ArraySize(SellOrders); i++) // PASST: Array-Name geändert
   {
      sumLots += SellOrders[i].lots;                                // PASST: Array-Name geändert
      sumPriceLots += SellOrders[i].openPrice * SellOrders[i].lots; // PASST: Array-Name geändert
   }
   if (sumLots <= 0.0)
      return 0.0;
   return sumPriceLots / sumLots;
}

// Standard: gewichteter Einstieg - TakeProfitPips
double BerechneGemeinsamenTPPrice(double tpPips)
{
   double currentWeighted = BerechneWeightedEntryPrice();
   if (currentWeighted <= 0.0)
      return 0.0;
   return currentWeighted - PipsToPrice(tpPips); // PASST: TP liegt UNTER Einstieg
}

//------------------------------------------------------------------
// TP-Only: Setze TP fuer alle Sells
void SetzeTPForAll(double tpPrice)
{
   MqlTradeRequest req;
   MqlTradeResult res;
   for (int i = 0; i < ArraySize(SellOrders); i++) // PASST: Array-Name geändert
   {
      ZeroMemory(req);
      ZeroMemory(res);

      req.action = TRADE_ACTION_SLTP;
      req.position = SellOrders[i].ticket; // PASST: Array-Name geändert
      req.symbol = _Symbol;

      req.sl = NormalizeDouble(currentSLPrice, _Digits);
      req.tp = NormalizeDouble(tpPrice, _Digits);

      if (OrderSend(req, res))
      {
         if (isDebugEnabled)
            PrintFormat("TP aktualisiert fuer Ticket %I64u", SellOrders[i].ticket); // PASST: Array-Name geändert
      }
      else
      {
         if (res.comment != "No changes")
            if (isDebugEnabled)
               PrintFormat("TP-Update fehlgeschlagen fuer Ticket %I64u: %s", SellOrders[i].ticket, res.comment); // PASST: Array-Name geändert
      }
   }
}

//------------------------------------------------------------------
// Sell-Oeffnung
bool OeffneSell(double lots) // PASST: Funktionsname geändert
{
   trade.SetExpertMagicNumber((long)magicNumber);
   bool ok = trade.Sell(lots, NULL, 0, 0, NULL, EAComment); // PASST: trade.Sell
   if (!ok)
      if (isDebugEnabled)
         PrintFormat("OeffneSell fehlgeschlagen! Lots=%.2f, Comment=%s, Error=%s", lots, EAComment, trade.ResultComment());
      else
         PrintFormat("SELL geoeffnet: %.2f Lots @ %.5f", lots, SymbolInfoDouble(_Symbol, SYMBOL_BID)); // PASST: BID für SELL
   return ok;
}

//------------------------------------------------------------------
// Alle Sell-Orders schliessen
void CloseAllSells() // PASST: Funktionsname geändert
{
   MqlTradeRequest req;
   MqlTradeResult res;
   for (int i = 0; i < ArraySize(SellOrders); i++) // PASST: Array-Name geändert
   {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.position = SellOrders[i].ticket;               // PASST: Array-Name geändert
      req.volume = SellOrders[i].lots;                   // PASST: Array-Name geändert
      req.type = ORDER_TYPE_BUY;                         // PASST: Schließen einer SELL-Position erfolgt durch BUY
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // PASST: ASK zum Schließen
      req.deviation = 10;
      req.magic = (long)magicNumber;

      if (!OrderSend(req, res))
         if (isDebugEnabled)
            PrintFormat("Schliessen fehlgeschlagen fuer Ticket %I64u: %s", SellOrders[i].ticket, res.comment); // PASST: Array-Name geändert
         else
            PrintFormat("SELL geschlossen fuer Ticket %I64u", SellOrders[i].ticket); // PASST: Array-Name geändert
   }
}

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
      AktualisiereSellOrders();
      CloseAllSells();
      ArrayFree(SellOrders);
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

//------------------------------------------------------------------
// Visualisierung
void DrawVisuals(double tpPrice)
{
   ClearAllObjects();

   for (int i = 0; i < ArraySize(SellOrders); i++) // PASST: Array-Name geändert
   {
      string name = StringFormat("EA_%s_%I64u_Entry", _Symbol, SellOrders[i].ticket); // PASST: Array-Name geändert
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, SellOrders[i].openPrice);                // PASST: Array-Name geändert
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrEntry);                             // PASST: Farbe ist jetzt Rot
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

      string label = StringFormat("EA_%s_%I64u_Label", _Symbol, SellOrders[i].ticket);                               // PASST: Array-Name geändert
      string text = StringFormat("SELL #%d | %.2f lots @ %.2f", i + 1, SellOrders[i].lots, SellOrders[i].openPrice); // PASST: Label geändert
      ObjectCreate(0, label, OBJ_TEXT, 0, TimeCurrent(), SellOrders[i].openPrice);                                   // PASST: Array-Name geändert
      ObjectSetString(0, label, OBJPROP_TEXT, text);
      ObjectSetInteger(0, label, OBJPROP_COLOR, clrEntry);
      ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, label, OBJPROP_ANCHOR, ANCHOR_LEFT);

      double labelOffset = PipValue() * (5 + 10 * i);
      ObjectMove(0, label, 0, TimeCurrent(), SellOrders[i].openPrice - labelOffset); // PASST: Offset NACH UNTEN
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
         AktualisiereSellOrders();
         if (ArraySize(SellOrders) == 0)
         {
            MessageBox("Es sind keine offenen Positionen zum Schließen vorhanden.", "Information", MB_OK | MB_ICONINFORMATION);
            return;
         }

         int result = MessageBox("Wollen Sie wirklich ALLE Positionen schließen?", "ALLE Positionen schließen", MB_YESNO | MB_ICONQUESTION);

         if (result == IDYES)
         {
            Print("Manuelles Schließen aller Positionen angefordert.");
            CloseAllSells();
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