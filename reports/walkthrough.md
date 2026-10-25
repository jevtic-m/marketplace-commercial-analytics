# Walkthrough: das Repo Datei für Datei

Dieses Dokument erklärt jede Datei in der Reihenfolge, in der sie läuft: was sie tut, was herauskommt und wo die fachlichen Entscheidungen stehen. Es setzt kein Vorwissen über das Projekt voraus. Wer nur die Ergebnisse sucht, liest das README; wer verstehen will, wie sie entstehen, liest hier.

Entscheidungen sind im Code mit `-- ENTSCHEIDUNG:` (SQL) oder `# ENTSCHEIDUNG:` (Python) markiert. Die Zeilennummern unten zeigen auf diese Marker. Eine Suche nach `ENTSCHEIDUNG:` in den SQL- und Python-Dateien findet alle 40 Stellen.

---

## 0. Das große Bild

```
data/raw/*.csv  (neun Kaggle-Dateien)
      |
      | 00_load.sql            Rohdaten laden
      v
data/olist.duckdb: neun Rohtabellen
      |
      | 01_schema.sql          Star-Schema bauen
      v
dim_date, dim_customer, dim_seller, dim_product, fact_orders, fact_order_items
      |
      +--> 02_validation.sql    Datenqualität prüfen
      +--> 03_commercial.sql    Umsatz, Kategorien, Regionen, Zahlung
      +--> 04_operations.sql    Lieferzeit, Verzug, Bewertung, Fracht
      +--> 02_delivery_analysis.py   Verzug gegen Bewertung vertieft, Frachttreiber
      +--> 04_rfm.py                 Kunden und Wiederkauf
      +--> 05_sellers.sql       Verkäufer-Views und Abfragen 13-15
              |
              +--> 03_seller_score.py    Score je Verkäufer (Tabellen seller_scorecard, seller_scorecard_2017)
                      |
                      +--> 05_cutoff_analysis.py   Trade-off und Schwelle (Tabellen seller_cutoff_tradeoff, seller_quadrants)
                              |
                              +--> 06_dashboard_exports.py   CSVs für Power BI
```

Zwei Ideen tragen das ganze Projekt:

1. **Ein Kunde ist eine Person, nicht eine Bestellung.** In den Rohdaten bekommt jede Bestellung eine neue `customer_id`. Die echte Person steckt in `customer_unique_id`. Alles, was mit Kunden zu tun hat, läuft deshalb über `customer_unique_id`.
2. **Erst verdichten, dann verbinden.** Eine Bestellung hat mehrere Positionen und manchmal mehrere Zahlungen. Wer beides gleichzeitig an die Bestellung hängt, vervielfacht Zeilen und Beträge (Fan-out). Deshalb wird jede Kindtabelle zuerst auf eine Zeile je Bestellung gebracht.

---

## 1. Vorbereitung: `requirements.txt` und `.gitignore`

- **`requirements.txt`** pinnt die fünf Pakete auf feste Versionen: duckdb 1.5.5, pandas 3.0.5, numpy 2.5.2, scipy 1.18.1, matplotlib 3.11.1. Mit `pip install -r requirements.txt` bekommt jeder dieselbe Umgebung.
- **`.gitignore`** hält die Rohdaten (`data/raw/`), die Datenbankdatei (`data/*.duckdb`), Python-Zwischendateien und eine virtuelle Umgebung aus dem Repo heraus. Die Rohdaten stehen unter einer Lizenz, die eine Weitergabe nur mit Namensnennung erlaubt, und sind über 120 MB groß; die Datenbank wird bei jedem Lauf neu erzeugt.

---

## 2. Hilfsskript `02_python/run_sql.py`

**Was es tut:** Es öffnet `data/olist.duckdb`, zerlegt eine SQL-Datei in einzelne Anweisungen und führt sie nacheinander aus. Jede Anweisung, die eine Tabelle zurückgibt, wird als Text ausgegeben. Befehle wie `CREATE TABLE` werden still ausgeführt.

**Warum:** So läuft jede SQL-Datei mit `python 02_python/run_sql.py <datei>`, ohne dass man die DuckDB-Kommandozeile installieren muss.

**Zahlen:** keine eigenen.

---

## 3. `02_python/01_data_prep.py` (ruft `00_load.sql` und `01_schema.sql` auf)

**Was es tut:** Es baut die Datenbank in drei Schritten auf und bricht mit einer Fehlermeldung ab, wenn eine von drei Pflichtprüfungen scheitert.

### 3a. `01_sql/00_load.sql`: Rohdaten laden

Liest die neun CSV-Dateien und legt je eine Tabelle an: `orders`, `order_items`, `order_payments`, `order_reviews`, `customers`, `sellers`, `products`, `geolocation`, `category_translation`. Inhaltlich wird nichts verändert, nur Datentypen werden festgelegt (Preise als Dezimalzahl, PLZ-Präfixe als ganze Zahl). Auch zwei Tippfehler in den Spaltennamen (`lenght`) werden korrigiert.

**Zahlen:** orders 99.441, order_items 112.650, order_payments 103.886, order_reviews 99.224, customers 99.441, sellers 3.095, products 32.951, geolocation 1.000.163, category_translation 71 Zeilen.

**Entscheidung:**
- Zeile 14: PLZ-Präfixe als INTEGER, damit Kunden, Verkäufer und Geolocation sauber zusammenpassen.

### 3b. `01_sql/01_schema.sql`: Star-Schema

Baut aus den Rohtabellen das Analysemodell:

| Tabelle | Eine Zeile je | Inhalt | Zeilen |
|---|---|---|---|
| `stg_geo_prefix` | PLZ-Präfix | Median-Koordinaten (Hilfstabelle) | 19.010 |
| `dim_date` | Kalendertag | Jahr, Quartal, Monat, Woche, Wochentag | 852 |
| `dim_customer` | reale Person | Stadt, Bundesstaat, Region, Koordinaten | 96.096 |
| `dim_seller` | Verkäufer | Stadt, Bundesstaat, Region, Koordinaten, Datum des ersten Verkaufs | 3.095 |
| `dim_product` | Produkt | englische Kategorie, Gewicht, Maße, Volumen | 32.951 |
| `fact_order_items` | Position | Preis, Fracht, Verweise auf Produkt, Verkäufer, Kunde, Datum | 112.650 |
| `fact_orders` | Bestellung | Status, Umsatz, Fracht, Zahlung, fünf Laufzeiten, Verspätung, Bewertung | 99.441 |

Außerdem ein kleines Makro `region_of`, das jedem Bundesstaat eine der fünf Großregionen Brasiliens zuordnet.

Der Kern ist `fact_orders` (Tabelle ab Zeile 279, Befüllung ab Zeile 299): Drei CTEs (`items`, `payments`, `reviews`) verdichten Positionen, Zahlungen und Bewertungen je `order_id`; erst dann werden sie per LEFT JOIN an `orders` gehängt. Die fünf Laufzeiten:

| Spalte | Rechnung |
|---|---|
| `days_to_approval` | Zahlungsfreigabe minus Kauf |
| `days_seller_handling` | Übergabe an Logistik minus Zahlungsfreigabe |
| `days_in_transit` | Zustellung minus Übergabe an Logistik |
| `days_total` | Zustellung minus Kauf |
| `days_vs_estimate` | Zustelldatum minus versprochenes Datum in Kalendertagen, positiv = zu spät |

**Entscheidungen:**
- Zeile 41: Geolocation auf den Median je Präfix verdichten, 42 Koordinaten außerhalb Brasiliens vorher entfernen.
- Zeile 88: Kundenkennung ist `customer_unique_id`.
- Zeile 92: Bei Personen mit mehreren Adressen zählt die Adresse der jüngsten Bestellung.
- Zeile 135: `first_sale_date` ist die erste Bestellung des Verkäufers, egal welcher Status.
- Zeile 174: Zwei fehlende Kategorie-Übersetzungen von Hand ergänzt, fehlende Kategorie wird `unknown`.
- Zeile 213: Zwei Faktentabellen statt einer.
- Zeile 249: Vorverdichtung gegen Fan-out.
- Zeile 254: LEFT JOIN statt INNER JOIN, damit keine Bestellung verloren geht.
- Zeile 258: Umsatz = Summe `price`, Zahlbetrag nur für Zahlungsanalysen.
- Zeile 264: Hauptzahlart = Zahlart mit dem größten Betrag.
- Zeile 268: Bei Mehrfachbewertungen zählt die jüngste.
- Zeile 273: Verzug in Kalendertagen, die anderen Laufzeiten in Dezimaltagen.

### 3c. Pflichtprüfungen in `01_data_prep.py`

| Prüfung | Ergebnis |
|---|---|
| `fact_orders` hat so viele Zeilen wie `orders` | 99.441 = 99.441 |
| Wiederkaufrate über `customer_unique_id` größer null | 2.997 von 96.096 Kunden = 3,12 % |
| `02_validation.sql` läuft fehlerfrei | 24 Anweisungen ohne Fehler |

---

## 4. `01_sql/02_validation.sql`: Datenqualität

**Was es tut:** Prüft in Teil A die Rohtabellen und in Teil B das Star-Schema. Jede Abfrage hat über sich einen Kommentar mit Frage und Ergebnis. Jede Aussage zur Datenqualität im README stammt von hier.

**Zahlen Teil A (Rohdaten):**

| Prüfung | Ergebnis |
|---|---|
| A1 Schlüssel | eindeutig überall außer `order_reviews` und `geolocation` |
| A2 Personen | 99.441 `customer_id` gehören zu 96.096 Personen, 2.997 mit mehreren Bestellungen |
| A3 Verwaiste Zeilen | keine; 775 Bestellungen ohne Position, 1 ohne Zahlung, 768 ohne Bewertung |
| A4 Mehrfachzeilen | 9.803 Bestellungen mit mehreren Positionen (höchstens 21), 2.961 mit mehreren Zahlungen, 547 mit mehreren Bewertungen, 1.278 mit mehreren Verkäufern |
| A5 Fehlende Zeitstempel | Freigabe 0,16 %, Übergabe 1,79 %, Zustellung 2,98 % |
| A6 Geolocation | 52,6 Zeilen je Präfix; naiver Join auf Kunden ergibt 15.083.455 Zeilen |
| A7 Kategorien | 610 Produkte ohne Kategorie, 2 Kategorien ohne Übersetzung |

**Zahlen Teil B (Schema):**

| Prüfung | Ergebnis |
|---|---|
| B1 Status | 97,02 % `delivered`, 1,24 % `canceled` oder `unavailable` |
| B2 Status gegen Zustelldatum | 8 + 6 widersprüchliche Fälle, Analysebasis 96.470 |
| B3 Zahlungsabstimmung | 254 von 98.665 Bestellungen (0,26 %) weichen um mehr als 1 % ab, 243 davon Kreditkarte |
| B4 Fan-out | naiver Join 117.601 Zeilen, Zahlbetrag +26,9 %; `fact_orders` exakt |
| B5 Ränder | 329 Bestellungen vor 2017, 20 nach August 2018; im Fenster 99.092 (99,65 %) |
| B6 Zeitstempel-Reihenfolge | 1.359 Übergaben vor Freigabe, 23 Zustellungen vor Übergabe |
| B7 Analysebasis | 96.203 zugestellte Bestellungen im Fenster, 6,79 % verspätet, Stornoquote 1,19 % |
| B8 Bundesstaat | nur 43 Bestellungen landen über die Kundendimension in einem anderen Staat |

**Entscheidungen:**
- Zeile 241: Behandlung der Bestellstatus (was in welche Kennzahl einfließt).
- Zeile 335: Analysefenster Januar 2017 bis August 2018.
- Zeile 361: Negative Teilzeiten bleiben in den Daten, werden aber aus der Zerlegung der Lieferzeit herausgehalten.

---

## 5. `01_sql/03_commercial.sql`: Abfragen 5 bis 8

**Was es tut:** Beantwortet die kommerziellen Fragen. Alle Abfragen nutzen das Analysefenster und nur zugestellte Bestellungen.

| Abfrage | Frage | Ergebnis |
|---|---|---|
| 5 | Umsatz je Monat mit Vormonatswachstum (`LAG`) | 13.181.027 BRL im Fenster; Jan–Aug 2018 +141,1 % gegen Vorjahr; Spitze November 2017 mit 987.765 BRL |
| 6 | Pareto der Kategorien (`SUM() OVER`) | 18 von 74 Kategorien machen 81,3 %; health_beauty führt mit 9,33 % |
| 7 | Bestellwert je Bundesstaat und Region | Norte 181,96 BRL, Sudeste 130,61 BRL; Frachtanteil 22,7 % gegen 15,2 % |
| 8 | Zahlungsverhalten | Kreditkarte 75,44 % der Bestellungen; Raten von 2,08 (unter 50 BRL) bis 7,29 (ab 500 BRL) |

Gut zu wissen: In Abfrage 6 wird `fact_order_items` mit `fact_orders` verbunden. Das ist erlaubt, weil jede Position genau eine Bestellung hat (n:1). Gefährlich wäre nur, zwei Tabellen mit je mehreren Zeilen pro Bestellung gleichzeitig anzuhängen.

**Entscheidungen:**
- Zeile 13: Umsatz ist realisierter Umsatz, also nur zugestellte Bestellungen.
- Zeile 105: Bundesstaat aus der Kundendimension.
- Zeile 162: Ratenanalysen nur für Kreditkarte.

---

## 6. `01_sql/04_operations.sql`: Abfragen 9 bis 12

**Was es tut:** Beantwortet die Operations-Fragen. Basis sind zugestellte Bestellungen mit Zustelldatum im Fenster.

| Abfrage | Frage | Ergebnis |
|---|---|---|
| 9 | Zerlegung der Lieferzeit je Region | 12,6 Tage = 0,4 Freigabe + 2,8 Bearbeitung + 9,4 Transport; Transport 7,6 Tage im Sudeste, 19,3 im Norte |
| 10a | Verspätungsquote je Monat | Spitzen November 2017 (12,40 %), Februar 2018 (14,13 %), März 2018 (18,96 %) |
| 10b, 10c | Verspätungsquote je Region und Staat | gesamt 6,79 %, Nordeste 12,76 %, Alagoas 21,46 % |
| 10d | Zusage und nötiger Puffer | Zusage im Median 22 Tage (Sudeste) bis 37 Tage (Norte); 7 Tage mehr im Nordeste senken die Quote auf 6,57 % |
| 11 | Bewertung nach Verzugsklasse (Kernabfrage) | 4,29 / 3,29 / 2,10 / 1,70 Sterne; Ein-Stern-Anteil 6,6 % bis 69,8 % |
| 12 | Frachtanteil je Kategorie und Entfernung | electronics 29,5 %; gleicher Staat 13,0 %, andere Region 18,8 %; 83,7 % der Positionen aus dem Sudeste |

**Entscheidungen:**
- Zeile 13: Leitgröße ist der Verzug gegen das Versprechen, nicht die Dauer.
- Zeile 31: Lieferzeit-Zerlegung nur mit nicht negativen Teilzeiten.
- Zeile 197: Entfernungsklassen über Bundesstaaten, Kilometer folgen in Python.

---

## 7. Hilfsskript `02_python/chart_style.py`

**Was es tut:** Legt Farben, Schriftgrößen und Achsenstil für alle Diagramme fest und speichert Diagramme nach `reports/figures/`. Die Farben (Blau `#2a78d6`, Orange `#eb6834`) sind auch bei Rot-Grün-Schwäche unterscheidbar. Geordnete Klassen wie Verzugsklassen bekommen eine einfarbige Blau-Rampe von hell nach dunkel.

---

## 8. `02_python/02_delivery_analysis.py`: Verzug gegen Bewertung, Fracht

**Was es tut, Teil 1:** Prüft die Kernhypothese "Nicht die Dauer ärgert, sondern das gebrochene Versprechen" auf 95.560 zugestellten, bewerteten Bestellungen.

| Schritt | Ergebnis |
|---|---|
| Bewertung je Verzugsklasse mit 95-%-Konfidenzintervall | pünktlich 4,29 (4,28–4,30), über 7 Tage 1,70 (1,65–1,74) |
| Anteil verspäteter Bestellungen | 6,7 % der Bestellungen, aber 36,8 % aller Ein-Stern-Bewertungen |
| Gegenprobe nach Lieferdauer | pünktlich: 4,42 (bis 7 Tage) bis 3,67 (über 30 Tage); verspätet in jeder Dauerklasse deutlich darunter |
| Regression Bewertung auf verspätet und Dauer | verspätet −1,54 Sterne, eine Woche Dauer −0,15 Sterne, R² 0,169 |
| Rangkorrelation | Verzug gegen Bewertung −0,18 |
| Robustheit | nur Einzelpositionen: Abstand 2,08 Sterne; je Region 1,93 bis 2,07; Bestellungen mit mehreren Verkäufern 2,86 Sterne trotz 0,95 % Verspätung |

**Was es tut, Teil 2:** Rechnet für 109.346 Positionen die Luftlinie zwischen Verkäufer und Kunde (Haversine-Formel) und fragt, was den Frachtwert treibt.

| Schritt | Ergebnis |
|---|---|
| R² allein | Gewicht 0,374, Volumen 0,340, Entfernung 0,154; alle drei 0,555 |
| Standardisierte Koeffizienten | Gewicht 0,40, Entfernung 0,40, Volumen 0,26 |
| Frachtanteil nach Entfernung | 11,8 % bis 100 km, 22,7 % über 2.000 km |
| Teuerste Route | SP nach PB, 43,31 BRL je Position; höchster Anteil SP nach MA, 31,2 % |

**Ausgaben:** drei Diagramme (`02_*.png`), fünf CSVs in `03_dashboard/exports/`.

**Entscheidungen:**
- Zeile 93: Verzugsklassen wie in SQL-Abfrage 11.
- Zeile 144: Einfache lineare Regression, Ergebnis in Sternen lesbar, kein Kausaleffekt.
- Zeile 270: Fracht im selben Skript, Entfernung als Luftlinie.
- Zeile 314: Zwei Blickwinkel auf die Frachttreiber (R² allein und gemeinsames Modell).
- Zeile 370: Routen erst ab 200 Positionen.

---

## 9. `02_python/04_rfm.py`: Kunden und Wiederkauf

**Was es tut:** Baut RFM-Segmente je Person und vergleicht Wiederkäufer mit Einmalkäufern anhand ihrer ersten Bestellung.

| Schritt | Ergebnis |
|---|---|
| Kunden im Fenster | 93.104, davon 2.005 (2,15 %) mit mehr als einem Kauftag |
| RFM | ältere Einmalkäufer mit hohem Wert: 22,7 % der Kunden, 43,0 % des Umsatzes; alle Wiederkäufer: 2,15 % der Kunden, 4,1 % des Umsatzes |
| Wiederkauf in 180 Tagen | 1.112 von 56.194 Kunden (1,98 %) |
| Was unterscheidet | Kategorie (p < 0,001): fashion_bags_accessories 3,3 % gegen cool_stuff 1,0 %; Region (p = 0,002): Sudeste 2,14 % gegen Nordeste 1,47 %; Bewertung und Pünktlichkeit nicht signifikant (p = 0,062 und 0,055) |

**Ausgaben:** `04_repeat_rate_by_category.png`, zwei CSVs.

**Entscheidungen:**
- Zeile 38: Wiederkauf = späterer Kauftag innerhalb von 180 Tagen; Erstkäufe bis 4. März 2018, damit jeder Kunde gleich lange beobachtet wird.
- Zeile 100: F-Score als feste Klassen statt Quintile.

---

## 10. `01_sql/05_sellers.sql`: Verkäufer-Views und Abfragen 13 bis 15

**Was es tut:** Legt zwei Views an, die die Python-Skripte danach lesen, und beantwortet drei Verkäuferfragen.

- `v_seller_orders`: eine Zeile je Verkäufer und Bestellung, mit Verkäuferumsatz, Storno-Kennzeichen, Bewertung, Verspätung, Bearbeitungszeit und dem Kennzeichen `is_quality_order` (zugestellt, mit Datum, nur ein Verkäufer).
- `v_seller_kpis`: eine Zeile je Verkäufer, jede Kennzahl in einem eigenen CTE verdichtet (Abfrage 14).

| Abfrage | Frage | Ergebnis |
|---|---|---|
| 13 | Wie konzentriert ist der Umsatz? | Top 1 % 25,9 %, Top 10 % 67,0 %, Top 20 % 82,2 %, untere Hälfte 3,4 % |
| 14 | Kennzahlen je Verkäufer | 3.068 Verkäufer, Median 6 zugestellte Bestellungen, 1.834 unter 10 |
| 15 | Verkäufer-Kohorten | aktiv nach 1 / 3 / 6 / 12 Monaten: 57,6 / 52,4 / 44,4 / 35,2 % |

**Entscheidungen:**
- Zeile 17: Bewertung, Verspätung und Bearbeitung je Verkäufer nur aus Bestellungen mit genau einem Verkäufer.
- Zeile 24: Negative Bearbeitungszeiten werden zu NULL.
- Zeile 209: Verkäufer-Kohorten als Ersatz für Kunden-Retention.

---

## 11. `02_python/03_seller_score.py`: Verkäufer-Scorecard

**Was es tut:** Berechnet für jeden Verkäufer einen Score von 0 bis 100 in vier Schritten:

1. **Kennzahl je Verkäufer** aus `v_seller_orders`: Durchschnittsbewertung, Verspätungsquote, Bearbeitungszeit, Stornoquote. Ein Abgleich mit `v_seller_kpis` stellt sicher, dass Python und SQL dasselbe rechnen.
2. **Dämpfung zum Marktmittel:** gedämpft = (n × eigener Wert + k × Marktwert) / (n + k). Die Stärke k wird aus den Daten geschätzt: Bewertung 26, Verspätung 42, Stornoquote 65, Bearbeitungszeit 5 (Untergrenze). Ein Verkäufer mit drei Fünf-Sterne-Bewertungen landet so bei 4,26 statt 5,0.
3. **Normierung auf 0 bis 100** über feste Anker: 1 bis 5 Sterne, 20 % bis 0 % Verspätung, 10 bis 0 Tage Bearbeitung, 10 % bis 0 % Storno.
4. **Gewichteter Gesamtscore:** 40 % Bewertung, 30 % Verspätung, 15 % Bearbeitung, 15 % Storno.

| Ergebnis | Wert |
|---|---|
| Score der 691 Verkäufer mit mindestens 25 bewertbaren Bestellungen | Median 78,2, unteres Quartil unter 73,6, Minimum 39,2 |
| Rangkorrelation mit anderen Gewichten | 0,96 bis 0,98, nur "Bewertung allein" 0,75 |

Am Ende rechnet das Skript einen zweiten Score nur aus den Bestellungen von 2017 (Tabelle `seller_scorecard_2017`, 1.784 Verkäufer) für die Gegenprobe im nächsten Schritt.

**Ausgaben:** Tabellen `seller_scorecard` und `seller_scorecard_2017`, Diagramm `03_seller_score_distribution.png`, CSV `seller_score_sensitivity.csv`.

**Entscheidungen:**
- Zeile 43: Gewichte 40/30/15/15 mit Begründung.
- Zeile 53: Feste Anker statt Perzentile.
- Zeile 158: Dämpfung statt Mindestbestellzahl, k aus den Daten.
- Zeile 287: Zweiter Score aus 2017 für die Gegenprobe.

---

## 12. `02_python/05_cutoff_analysis.py`: Trade-off und Schwelle

**Was es tut:** Rechnet für jede Schwelle von 0 bis 100 durch, was passiert, wenn alle Verkäufer darunter den Marktplatz verlassen: verlorener Umsatz, entfallene Ein-Stern-Bewertungen, neue Durchschnittsbewertung. Dann wählt es eine Schwelle, ordnet Verkäufer in Quadranten und prüft das Ergebnis mit dem 2017er Score gegen die Bestellungen von 2018.

| Ergebnis | Wert |
|---|---|
| Gewählte Schwelle | Score 62 (höchste mit höchstens 5 % Umsatzverlust) |
| Betroffene Verkäufer | 62 |
| Ihr Anteil an Ein-Stern-Bewertungen | 9,7 % (902) |
| Ihr Anteil am Umsatz | 4,8 % (636.001 BRL) |
| Durchschnittsbewertung | 4,156 auf 4,185 (+0,029) |
| Gegenprobe 2017er Score auf 2018 | 3,3 % Ein-Stern bei 2,2 % Umsatz, +0,009 Sterne |
| Regel "größter Abstand" zum Vergleich | Score 76 mit 39,0 % Umsatzverlust, unrealistisch |
| Quadranten | 587 groß und gut, 27 groß und schwach (4,4 % Umsatz), 2.419 klein und gut, 35 klein und schwach |
| Unteres Score-Quartil (173 verlässlich bewertete Verkäufer) | 36,7 % der Ein-Stern-Bewertungen bei 23,3 % Umsatz |

**Ausgaben:** Tabellen `seller_cutoff_tradeoff` und `seller_quadrants`, zwei Diagramme (`05_*.png`), `cutoff_tradeoff.csv` und `cutoff_summary.csv`.

**Entscheidungen:**
- Zeile 42: Schwelle über ein Umsatzbudget von 5 %.
- Zeile 50: "Groß" = Top 20 % der Verkäufer nach Umsatz (ab 4.420 BRL).
- Zeile 58: Nur zugestellte Bestellungen; eine Bestellung entfällt, sobald einer ihrer Verkäufer wegfällt.

---

## 13. `02_python/06_dashboard_exports.py`: CSV-Exporte

**Was es tut:** Schreibt das Star-Schema (nur Analysefenster) und fünf vorberechnete Hilfstabellen nach `03_dashboard/exports/`. Alle Exporte sind fest sortiert, damit jeder Lauf bytegleiche Dateien liefert.

| Datei | Zeilen |
|---|---|
| fact_orders.csv | 99.092 |
| fact_order_items.csv | 112.279 |
| dim_customer.csv | 95.774 |
| dim_product.csv | 32.787 |
| dim_seller.csv | 3.068 (mit Score und Quadrant) |
| dim_date.csv | 608 |
| category_pareto, late_rate_region_category, delivery_decomposition_region, seller_concentration, seller_cohorts | je klein |

**Entscheidung:**
- Zeile 32: Nur Analysefenster und nur benötigte Spalten exportieren.

---

## 14. `03_dashboard/measures.dax` und `03_dashboard/layout.md`

Keine ausführbaren Dateien, sondern der Bauplan für Power BI.

- **`measures.dax`** enthält alle Kennzahlen als DAX: Umsatz, Bestellungen, Bestellwert, Bewertung, Verspätungsquote, Lieferzeit-Zerlegung und den Cutoff-Simulator. Der Simulator rechnet dieselbe Logik wie `05_cutoff_analysis.py`; drei Kontroll-Measures lesen zum Vergleich die vorberechneten Werte aus `cutoff_tradeoff.csv`.
- **`layout.md`** beschreibt das Datenmodell (welche Beziehungen, warum keine doppelten Filterwege) und je Seite Zielgruppe, Visuals, Felder, Achsen und Kontrollwerte.

Die Power-BI-Datei und die Screenshots fehlen noch. Sie entstehen von Hand nach `layout.md`; die Screenshots gehören nach `03_dashboard/screenshots/` unter den dort genannten Namen.

---

## 15. `reports/`

- **`findings.md`**: je Arbeitsschritt was gemacht wurde, was herauskam und warum so entschieden wurde. Ohne Code lesbar.
- **`interview_notes.md`**: die typischen Interviewfragen mit Antworten aus den echten Ergebnissen, dazu die 90-Sekunden-Story.
- **`figures/`**: alle Diagramme, die das README einbindet.
- **`walkthrough.md`**: dieses Dokument.

---

## 16. Alle Entscheidungsstellen auf einen Blick

| Thema | Datei und Zeile |
|---|---|
| PLZ-Präfix als Zahl | `01_sql/00_load.sql:14` |
| Geolocation verdichten | `01_sql/01_schema.sql:41` |
| Kundenkennung | `01_sql/01_schema.sql:88` |
| Adresse bei mehreren Wohnorten | `01_sql/01_schema.sql:92` |
| Erster Verkauf eines Verkäufers | `01_sql/01_schema.sql:135` |
| Fehlende Kategorie-Übersetzungen | `01_sql/01_schema.sql:174` |
| Zwei Faktentabellen | `01_sql/01_schema.sql:213` |
| Vorverdichtung gegen Fan-out | `01_sql/01_schema.sql:249` |
| LEFT JOIN statt INNER JOIN | `01_sql/01_schema.sql:254` |
| Umsatzdefinition und Zahlungsabstimmung | `01_sql/01_schema.sql:258` |
| Hauptzahlart | `01_sql/01_schema.sql:264` |
| Mehrfachbewertungen | `01_sql/01_schema.sql:268` |
| Verzug in Kalendertagen | `01_sql/01_schema.sql:273` |
| Behandlung der Bestellstatus | `01_sql/02_validation.sql:241` |
| Analysefenster | `01_sql/02_validation.sql:335` |
| Negative Teilzeiten | `01_sql/02_validation.sql:361` |
| Realisierter Umsatz | `01_sql/03_commercial.sql:13` |
| Bundesstaat aus der Kundendimension | `01_sql/03_commercial.sql:105` |
| Raten nur bei Kreditkarte | `01_sql/03_commercial.sql:162` |
| Verzug als Leitgröße | `01_sql/04_operations.sql:13` |
| Zerlegung nur bei plausibler Reihenfolge | `01_sql/04_operations.sql:31` |
| Entfernungsklassen über Bundesstaaten | `01_sql/04_operations.sql:197` |
| Verkäuferzuordnung bei mehreren Verkäufern | `01_sql/05_sellers.sql:17` |
| Negative Bearbeitungszeit je Verkäufer | `01_sql/05_sellers.sql:24` |
| Verkäufer-Kohorten | `01_sql/05_sellers.sql:209` |
| Verzugsklassen | `02_python/02_delivery_analysis.py:93` |
| Einfache Regression | `02_python/02_delivery_analysis.py:144` |
| Fracht im Lieferskript, Luftlinie | `02_python/02_delivery_analysis.py:270` |
| Frachttreiber aus zwei Blickwinkeln | `02_python/02_delivery_analysis.py:314` |
| Mindestgröße je Route | `02_python/02_delivery_analysis.py:370` |
| Gewichte der Scorecard | `02_python/03_seller_score.py:43` |
| Feste Anker | `02_python/03_seller_score.py:53` |
| Dämpfung statt Mindestbestellzahl | `02_python/03_seller_score.py:158` |
| Score aus 2017 für die Gegenprobe | `02_python/03_seller_score.py:287` |
| Wiederkauf-Definition | `02_python/04_rfm.py:38` |
| F-Score als feste Klassen | `02_python/04_rfm.py:100` |
| Wahl des Cutoffs | `02_python/05_cutoff_analysis.py:42` |
| Definition "groß" | `02_python/05_cutoff_analysis.py:50` |
| Bestellungen im Cutoff | `02_python/05_cutoff_analysis.py:58` |
| Exportumfang | `02_python/06_dashboard_exports.py:32` |

---

## 17. Wenn etwas nicht läuft

- **"No such file" beim Laden:** Die neun Kaggle-CSVs müssen direkt in `data/raw/` liegen, mit ihren Originalnamen.
- **"Table does not exist":** Die Reihenfolge stimmt nicht. `01_data_prep.py` muss zuerst laufen, `05_sellers.sql` vor `03_seller_score.py`, und `03_seller_score.py` vor `05_cutoff_analysis.py`.
- **Ein Pflichtcheck in `01_data_prep.py` schlägt fehl:** Dann ist am Schema etwas kaputt. Die Meldung sagt, welche Prüfung; die häufigste Ursache wäre ein Join, der Zeilen vervielfacht oder verliert.
- **Umlaute sehen in der Windows-Konsole falsch aus:** Die Skripte stellen die Ausgabe auf UTF-8 um. Falls ein Terminal das nicht unterstützt, hilft vorher `set PYTHONIOENCODING=utf-8`.
- **Zahlen weichen vom README ab:** Ein Lauf auf denselben Rohdaten liefert bytegleiche Ergebnisdateien. Abweichungen bedeuten andere Rohdaten oder andere Paketversionen; deshalb sind die Versionen in `requirements.txt` gepinnt.
