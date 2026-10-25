# Dashboard-Layout (Power BI)

Bauplan für das vierseitige Marktplatz-Dashboard. Für jede Seite steht, welches Visual, welche Felder und welche Achsen. Die Daten liegen als CSV in `exports/`, die Measures in `measures.dax`.

Die Exporte sind abgeleitet aus dem Olist-Datensatz (Kaggle, Lizenz CC BY-NC-SA 4.0) und umfassen nur das Analysefenster Januar 2017 bis August 2018. Alle Beträge in BRL.

---

## 1. Daten laden

**Import:** Daten abrufen > Text/CSV, Dateiursprung UTF-8, Gebietsschema "Englisch (Vereinigte Staaten)", weil Dezimalzahlen mit Punkt geschrieben sind. Wahrheitswerte stehen als `True`/`False` und werden als Typ "Wahr/Falsch" gesetzt.

| Tabelle | Datei | Rolle | Schlüssel |
|---|---|---|---|
| fact_orders | fact_orders.csv | Fakten, eine Zeile je Bestellung | order_id |
| fact_order_items | fact_order_items.csv | Fakten, eine Zeile je Position | order_id + order_item_id |
| dim_date | dim_date.csv | Datum, als Datumstabelle markieren (Spalte `date`) | date_id |
| dim_customer | dim_customer.csv | Kunde je realer Person | customer_unique_id |
| dim_product | dim_product.csv | Produkt mit englischer Kategorie | product_id |
| dim_seller | dim_seller.csv | Verkäufer mit Score und Quadrant | seller_id |
| cutoff_tradeoff | cutoff_tradeoff.csv | Trade-off je Schwelle 0 bis 100, ohne Beziehung | cutoff |
| category_pareto | category_pareto.csv | Kategorien mit kumuliertem Anteil, ohne Beziehung | category_en |
| late_rate_region_category | late_rate_region_category.csv | Heatmap-Daten, ohne Beziehung | region + category_en |
| delivery_decomposition_region | delivery_decomposition_region.csv | Lieferzeit-Zerlegung, ohne Beziehung | region |
| seller_concentration | seller_concentration.csv | Verkäufer-Ranking nach Umsatz, ohne Beziehung | revenue_rank |
| delay_class_reviews | delay_class_reviews.csv | Bewertung je Verzugsklasse mit Konfidenzintervall | delay_class |

**Beziehungen** (alle 1:n, einfache Filterrichtung):

```
dim_date[date_id]                 1 -> n  fact_orders[purchase_date_id]
dim_customer[customer_unique_id]  1 -> n  fact_orders[customer_unique_id]
fact_orders[order_id]             1 -> n  fact_order_items[order_id]
dim_product[product_id]           1 -> n  fact_order_items[product_id]
dim_seller[seller_id]             1 -> n  fact_order_items[seller_id]
```

`fact_order_items` bekommt bewusst keine eigene Beziehung zu `dim_date` und `dim_customer`. Datum und Kunde filtern die Positionen über `fact_orders`. Sonst gäbe es zwei Filterwege, und Power BI würde einen davon stillschweigend deaktivieren.

**Sortierung:** `fact_orders[delay_class]` nach `fact_orders[delay_class_order]` sortieren, `dim_date[month_name]` nach `dim_date[month]`.

**Farben:** Blau `#2a78d6` für die Hauptreihe, Orange `#eb6834` für die zweite Reihe und für "unter der Schwelle", Aqua `#1baf7a` für eine dritte Reihe. Für geordnete Klassen und Karten eine einfarbige Blau-Rampe von hell `#86b6ef` bis dunkel `#104281`. Nie zwei Werteachsen in einem Visual: Größen mit unterschiedlicher Einheit bekommen zwei Visuals.

**Seitenfilter auf allen Seiten:** Datumsschieberegler auf `dim_date[date]` und Datenschnitt `dim_customer[region]` in einer Zeile oben.

---

## 2. Seite 1: Marktplatz-Überblick

**Zielgruppe:** Geschäftsführung und Category Management. Frage: Wie groß ist der Marktplatz, wächst er, und wo entsteht der Umsatz?

| Position | Visual | Felder | Achsen und Formatierung |
|---|---|---|---|
| Oben, 5 Karten | Karte | `[Revenue BRL]`, `[Orders Delivered]`, `[Avg Order Value BRL]`, `[Avg Review]`, `[Late Rate]` | Umsatz in Mio. BRL mit zwei Nachkommastellen, Bestellwert in BRL, Bewertung mit zwei Nachkommastellen, Verspätungsquote in % |
| Mitte links | Liniendiagramm | Achse `dim_date[year_month]`, Wert `[Revenue BRL]` | X: Monat Jan 2017 bis Aug 2018, Y: Umsatz BRL ab 0. Tooltip: `[Revenue MoM %]` |
| Mitte links, darunter | Liniendiagramm | Achse `dim_date[year_month]`, Wert `[Orders Delivered]` | X wie oben, Y: Anzahl Bestellungen ab 0. Eigenes Visual statt zweiter Y-Achse |
| Mitte rechts | Linien- und gruppiertes Säulendiagramm | Tabelle `category_pareto`, gefiltert auf `revenue_rank` <= 20. X: `category_en` (sortiert nach `revenue_rank`), Säulen: `revenue_share_pct`, Linie: `cumulative_share_pct` | Beide Werte in %, eine gemeinsame Y-Achse 0 bis 100 (sekundäre Achse ausschalten). Konstante Linie bei 80 % |
| Unten | Flächenkartogramm | Ort `dim_customer[state_geo]`, Farbsättigung `[Revenue BRL]` | Einfarbige Blau-Rampe. Tooltip: `[Avg Order Value BRL]`, `[Freight Share]` |

**Kontrollwerte (ganzes Fenster):** Umsatz 13.181.027 BRL, 96.211 zugestellte Bestellungen, Bestellwert 137,00 BRL, Bewertung 4,16, Verspätungsquote 6,79 %. Top-Kategorie health_beauty 9,33 %, 18 Kategorien erreichen 81,3 % kumuliert.

---

## 3. Seite 2: Operations

**Zielgruppe:** Logistik und Operations. Frage: Wo dauert es, wo wird das Versprechen gebrochen, und was kostet das an Zufriedenheit?

| Position | Visual | Felder | Achsen und Formatierung |
|---|---|---|---|
| Oben links | Gestapeltes Balkendiagramm | Y: `dim_customer[region]`, Werte: `[Avg Days To Approval]`, `[Avg Days Seller Handling]`, `[Avg Days In Transit]` | X: Tage ab 0. Reihenfolge der Segmente Freigabe, Bearbeitung, Transport. Sortiert nach Gesamtlänge. Kontrolle gegen `delivery_decomposition_region.csv` |
| Oben rechts | Liniendiagramm | Achse `dim_date[year_month]`, Wert `[Late Rate]` | Y: % ab 0. Konstante Linie beim Gesamtwert 6,79 % |
| Unten links, **Kernvisual** | Gruppiertes Säulendiagramm | X: `fact_orders[delay_class]`, Y: `[Avg Review]`. Tooltip: `[Reviewed Orders]`, `[One Star Share]` | Y: Sterne 0 bis 5. Einfarbige Blau-Rampe hell (pünktlich) bis dunkel (über 7 Tage). Datenbeschriftung an. Untertitel: "Zusammenhang, kein Kausalnachweis" |
| Unten Mitte | Gruppiertes Säulendiagramm | X: `fact_orders[delay_class]`, Y: `[One Star Share]` | Y: % 0 bis 80. Gleiche Farben wie das Kernvisual |
| Unten rechts | Matrix als Heatmap | Tabelle `late_rate_region_category`. Zeilen `category_en`, Spalten `region`, Wert `late_rate_pct` | Bedingte Formatierung Hintergrund: Farbskala Blau hell bis dunkel. Tooltip `n_orders` |

**Kontrollwerte:** Lieferzeit 12,6 Tage (0,4 Freigabe, 2,8 Bearbeitung, 9,4 Transport). Bewertung pünktlich 4,29, 1 bis 3 Tage 3,29, 4 bis 7 Tage 2,10, über 7 Tage 1,70. Verspätungsquote Nordeste 12,76 %.

---

## 4. Seite 3: Verkäufer

**Zielgruppe:** Seller Management und Key Account. Frage: Welche Verkäufer tragen den Umsatz, und welche davon sind schwach?

| Position | Visual | Felder | Achsen und Formatierung |
|---|---|---|---|
| Oben, 3 Karten | Karte | `[Sellers With Revenue]`, Top-10-%-Umsatzanteil (aus `seller_concentration`: Summe `revenue_share_pct` bei `seller_share_pct` <= 10), `[Seller Cutoff]` | Anteil in % |
| Links, groß | Streudiagramm | Werte: `dim_seller[seller_id]`, X: `dim_seller[revenue_brl]`, Y: `dim_seller[score]`, Größe: `dim_seller[n_delivered_orders]`, Legende: `dim_seller[quadrant]` | X logarithmisch. Y: Score 30 bis 95. Konstante Linien: Y = 62 (Cutoff), X = 4.420 BRL (Grenze Top 20 % nach Umsatz). Filter `n_delivered_orders` > 0. Tooltip: `avg_review`, `late_rate`, `avg_handling_days`, `cancel_rate` |
| Rechts oben | Tabelle | `dim_seller`: `seller_id`, `state`, `quadrant`, `score`, `review_component`, `late_component`, `handling_component`, `cancel_component`, `n_quality_orders`, `revenue_brl`, `avg_review`, `late_rate` | Sortierbar, standardmäßig nach `score` aufsteigend. Bedingte Formatierung auf `score` (Datenbalken) |
| Rechts unten | Balkendiagramm | Tabelle `seller_concentration`, Filter `revenue_rank` <= 20. Y: `revenue_rank`, X: `revenue_share_pct` | X in %. Tooltip `cumulative_share_pct` |

**Warum Score statt roher Bewertung auf der Y-Achse:** Der Score ist zum Marktmittel gedämpft. Die rohe Durchschnittsbewertung eines Verkäufers mit drei Bestellungen springt zwischen 1 und 5 und würde die Quadranten mit Zufall füllen. Die rohe Bewertung steht im Tooltip.

**Kontrollwerte:** 2.945 Verkäufer mit Umsatz, Top 10 % tragen 67,0 %. Quadranten: 587 groß und gut, 27 groß und schwach (4,4 % Umsatz), 2.419 klein und gut, 35 klein und schwach.

---

## 5. Seite 4: Cutoff-Simulator

**Zielgruppe:** Marktplatz-Leitung. Frage: Was kostet und bringt es, Verkäufer unter einer Score-Schwelle auszuschließen?

| Position | Visual | Felder | Achsen und Formatierung |
|---|---|---|---|
| Oben | Datenschnitt als Schieberegler | `CutoffParam[Cutoff]`, Einzelauswahl | Bereich 0 bis 100, Startwert 62 |
| Darunter, 5 Karten | Karte | `[Sellers Excluded]`, `[Revenue Lost %]`, `[One Star Avoided %]`, `[Avg Review Kept]`, `[Review Uplift]` | Prozent mit einer Nachkommastelle, Bewertung mit zwei, Uplift mit Vorzeichen |
| Mitte links | Liniendiagramm | Tabelle `cutoff_tradeoff`. X: `cutoff`, Werte: `revenue_lost_pct`, `one_star_removed_pct` | Beide in %, eine Y-Achse 0 bis 100. X-Achse 40 bis 90. Konstante X-Linie bei `[Seller Cutoff]`. Farben: Umsatz Blau, Ein-Stern Orange |
| Mitte rechts | Liniendiagramm | Tabelle `cutoff_tradeoff`. X: `cutoff`, Wert: `avg_review_kept` | Y: Sterne 4,1 bis 4,6. Konstante Y-Linie bei 4,16 (heute) |
| Unten | Textfeld | Hinweis zur Gegenprobe | "Mit einem Score aus 2017 entfallen 2018 nur 3,3 % der Ein-Stern-Bewertungen bei 2,2 % Umsatz. Die Kurve oben ist die optimistische Obergrenze." |

**Kontrollwerte bei Score 62:** 62 Verkäufer ausgeschlossen, 4,83 % Umsatz verloren, 9,68 % der Ein-Stern-Bewertungen vermieden, Bewertung 4,156 auf 4,185. Die Measures mit "(Tabelle)" im Namen lesen dieselben Werte aus `cutoff_tradeoff.csv` und müssen mit den dynamischen Measures übereinstimmen.

---

## 6. Screenshots

Nach dem Bau je Seite einen Screenshot als PNG nach `03_dashboard/screenshots/` exportieren:

```
03_dashboard/screenshots/01_overview.png
03_dashboard/screenshots/02_operations.png
03_dashboard/screenshots/03_sellers.png
03_dashboard/screenshots/04_cutoff_simulator.png
```

Das README bindet genau diese Dateinamen ein.
