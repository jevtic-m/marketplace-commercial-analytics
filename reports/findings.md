# Findings — Commercial & Operations Analytics (Olist)

Pro Arbeitspaket drei Teile: Was wurde gemacht, was kam heraus, warum so entschieden.
Alle Zahlen sind berechnet und in den SQL-Dateien beziehungsweise Python-Skripten nachvollziehbar.

---

## AP1 — Daten laden, neun Tabellen verstehen, Schlüsselbeziehungen prüfen

### Was wurde gemacht

- Die neun CSV-Dateien aus `data/raw/` werden mit `01_sql/00_load.sql` unverändert in die DuckDB-Datei `data/olist.duckdb` geladen. Nur die Datentypen werden festgelegt (Preise als DECIMAL, PLZ-Präfixe als INTEGER).
- `02_python/run_sql.py` ist ein kleiner Helfer, der eine SQL-Datei Anweisung für Anweisung ausführt und jedes Abfrageergebnis als Tabelle ausgibt. Damit lässt sich jede SQL-Datei des Projekts ohne DuckDB-Kommandozeile prüfen.
- `01_sql/02_validation.sql` Teil A prüft die Schlüssel jeder Tabelle, die Fremdschlüsselbeziehungen, die Kardinalitäten (wie viele Kindzeilen je Bestellung) und die Vollständigkeit der Zeitstempel.

### Was kam heraus

| Prüfung | Ergebnis |
|---|---|
| Eindeutige Schlüssel | orders, customers, sellers, products, order_items, order_payments, category_translation: ja |
| Nicht eindeutig | order_reviews (99.224 Zeilen, 98.410 review_id, 98.673 order_id), geolocation (1.000.163 Zeilen, 19.015 Präfixe) |
| Reale Kunden | 96.096 `customer_unique_id` hinter 99.441 `customer_id`; 2.997 Personen (3,12 %) mit mehr als einer Bestellung |
| Verwaiste Fremdschlüssel | keine (alle Positionen, Zahlungen, Bewertungen finden ihre Bestellung; alle Positionen finden Produkt und Verkäufer) |
| Bestellungen ohne Position | 775, davon 603 `unavailable` und 164 `canceled` |
| Bestellungen ohne Zahlung | 1 |
| Bestellungen ohne Bewertung | 768 |
| Mehrfach-Kindzeilen | 9.803 Bestellungen mit mehr als einer Position (max. 21), 2.961 mit mehreren Zahlungszeilen, 547 mit mehreren Bewertungen, 1.278 mit mehreren Verkäufern |
| Fehlende Zeitstempel | Zahlungsfreigabe 0,16 %, Übergabe an Logistik 1,79 %, Zustellung 2,98 %; Kauf und Lieferversprechen immer gefüllt |
| Geolocation | 52,6 Zeilen je Präfix, naiver Join auf Kunden ergibt 15.083.455 Zeilen; 42 Koordinaten außerhalb Brasiliens; 278 Kunden und 7 Verkäufer ohne Koordinaten |
| Kategorien | 610 Produkte ohne Kategorie, 2 Kategorien ohne englische Übersetzung (13 Produkte) |

Das Beziehungsdiagramm steht im README. Kurzfassung: `orders` ist die Mitte. Nach oben hängt `customers` (1:1 über `customer_id`), nach unten hängen `order_items`, `order_payments` und `order_reviews` (jeweils 1:n). `order_items` verweist auf `products` und `sellers`. `geolocation` hängt nur über den PLZ-Präfix an Kunden und Verkäufern.

### Warum so entschieden

- **PLZ-Präfixe als INTEGER**: In den CSVs stehen sie als Text mit führenden Nullen. Als Zahl joinen Kunden, Verkäufer und Geolocation sauber, und die führenden Nullen tragen keine Information.
- **Rohtabellen bleiben roh**: In `00_load.sql` passiert nichts Fachliches. Wer später einen Fehler sucht, kann immer gegen die unveränderten Rohdaten prüfen.
- **Eigener SQL-Runner statt DuckDB-CLI**: Ein Python-Skript mit 40 Zeilen macht das Repo von einem frischen Clone aus lauffähig, ohne dass ein zusätzliches Werkzeug installiert werden muss.
- **Bewertungen doppelt**: 547 Bestellungen haben mehr als eine Bewertung, 789 `review_id` tauchen bei mehreren Bestellungen auf. Das ist im Rohdatensatz so. Welche Bewertung zählt, wird in AP2 beim Aufbau von `fact_orders` entschieden.

**Abnahmekriterium AP1** (Beziehungsdiagramm aus dem Kopf skizzierbar): erfüllt. Das Diagramm steht im README, jede Kante ist mit einer Zahl aus `02_validation.sql` Teil A belegt.

---

## AP2 — Star-Schema aufbauen, Zeitstempel-Kennzahlen berechnen

### Was wurde gemacht

- `01_sql/01_schema.sql` baut aus den neun Rohtabellen vier Dimensionen (`dim_date`, `dim_customer`, `dim_seller`, `dim_product`) und zwei Faktentabellen (`fact_order_items` auf Positionsebene, `fact_orders` auf Bestellebene). Dazu die Hilfstabelle `stg_geo_prefix` mit einer Zeile je PLZ-Präfix.
- `fact_orders` enthält je Bestellung die verdichteten Positionen (Anzahl, Warenumsatz, Fracht), Zahlungen (Gesamtbetrag, maximale Ratenzahl, Hauptzahlart), die maßgebliche Bewertung und die fünf Laufzeit-Kennzahlen aus der Zeitstempelkette.
- `02_python/01_data_prep.py` führt Laden und Schema-Aufbau in einem Schritt aus und bricht ab, wenn eine von drei Pflichtprüfungen scheitert.

### Was kam heraus

| Tabelle | Zeilen |
|---|---|
| dim_date | 852 (1. September 2016 bis 31. Dezember 2018) |
| dim_customer | 96.096 (eine je realer Person) |
| dim_seller | 3.095 |
| dim_product | 32.951 |
| fact_order_items | 112.650 (= order_items) |
| fact_orders | 99.441 (= orders) |

Kontrollsummen: Warenumsatz in `fact_orders` = 13.591.643,70 BRL = Summe `price` in `order_items`. Zahlbetrag = 16.008.872,12 BRL = Summe `payment_value` in `order_payments`. Der Fan-out ist damit nachweislich gelöst: Kein Betrag wird doppelt gezählt, keine Bestellung geht verloren.

Die drei Pflichtprüfungen: `fact_orders` = `orders` = 99.441 Zeilen; Wiederkaufrate 2.997 von 96.096 = 3,12 %; Validierung läuft fehlerfrei.

Auffälligkeiten aus den Laufzeit-Kennzahlen: Verzug gegen Versprechen reicht von -147 bis +188 Tagen, Gesamtlaufzeit bis 209,6 Tage. 1.359 Bestellungen haben eine negative Bearbeitungszeit (Übergabe an Logistik vor Zahlungsfreigabe), vermutlich ein Prozessartefakt beim Buchen der Freigabe. Wie damit umgegangen wird, steht in AP3.

### Warum so entschieden

- **Kundenkennung**: `dim_customer` hat einen Schlüssel je `customer_unique_id`. Bei 250 Personen mit mehreren Adressen zählt die Adresse der jüngsten Bestellung.
- **Geolocation**: Median je PLZ-Präfix, 42 Koordinaten außerhalb Brasiliens vorher entfernt. 269 Kunden und 7 Verkäufer bleiben ohne Koordinaten, weil ihr Präfix in der Geolocation fehlt.
- **Zwei Faktentabellen**: Verkäufer und Produkt sind nur auf Positionsebene eindeutig (1.278 Bestellungen mit mehreren Verkäufern). Umsatz, Zahlung und Bewertung sind auf Bestellebene eindeutig. Eine einzige Tabelle müsste eine der beiden Ebenen verfälschen.
- **Vorverdichtung**: Positionen, Zahlungen und Bewertungen werden in getrennten CTEs je `order_id` auf eine Zeile gebracht, bevor sie an `orders` gehängt werden.
- **LEFT JOIN**: Alle 99.441 Bestellungen bleiben erhalten, auch ohne Position, Zahlung oder Bewertung. Ein INNER JOIN hätte 775 Bestellungen ohne Position und damit fast alle `unavailable`-Fälle verloren, die für die Stornoquote gebraucht werden.
- **Umsatzdefinition**: `item_revenue` = Summe `price`. Fracht getrennt. `paid_total` nur für Zahlungsanalysen, weil Gutscheine und Mehrfachzahlungen den Betrag vom Warenwert entkoppeln.
- **Hauptzahlart**: die Zahlart mit dem größten Betrag je Bestellung. 2.246 Bestellungen kombinieren mehrere Zahlarten, meist Kreditkarte plus Gutschein.
- **Mehrfachbewertungen**: die jüngste Bewertung je Bestellung. Bei 202 der 547 Doppelbewertungen unterscheidet sich die Punktzahl. Die letzte Bewertung ist das endgültige Urteil des Kunden. Auf den Gesamtdurchschnitt wirkt sich das kaum aus (4,086 statt 4,086 über alle Zeilen).
- **Verzug in Kalendertagen**: Das Lieferversprechen ist ein Datum ohne Uhrzeit. Der Verzug wird deshalb als Differenz der Kalendertage berechnet, `is_late` ist Verzug größer null. Die übrigen Laufzeiten sind Dezimaltage aus den vollen Zeitstempeln.
- **Kategorien**: zwei fehlende Übersetzungen von Hand ergänzt, fehlende Kategorie wird `unknown`.
- **first_sale_date** je Verkäufer aus allen Bestellungen unabhängig vom Status, weil es um den Zeitpunkt des Aktivwerdens geht.

**Abnahmekriterium AP2** (`fact_orders` steht, Fan-out nachweislich gelöst): erfüllt. Zeilenzahl 99.441 = `orders`, Umsatz- und Zahlungssumme stimmen auf den Cent mit den Rohtabellen überein. Der explizite Fan-out-Nachweis (naiver Join gegen Aggregation) steht in `02_validation.sql`, Abfrage B4 (siehe AP3).

---

## AP3 — Datenqualität: Validierungen, Zahlungsabstimmung, Randzeiträume

### Was wurde gemacht

`01_sql/02_validation.sql` hat jetzt einen Teil B, der auf dem Star-Schema läuft. Er prüft die Verteilung der Bestellstatus, den Abgleich von Status und Zustelldatum, die Zahlungsabstimmung, den Fan-out beim naiven Join, die Ränder des Zeitraums, die Reihenfolge der Zeitstempel und die Größe der Analysebasis. Danach wurde die Datenbank aus den Rohdaten komplett neu gebaut, und die drei Pflichtprüfungen liefen erneut durch.

### Was kam heraus

| Prüfung | Ergebnis |
|---|---|
| Status `delivered` | 96.478 von 99.441 Bestellungen (97,02 %) |
| `canceled` + `unavailable` | 625 + 609 = 1.234 (1,24 %), im Analysefenster 1.182 (1,19 %) |
| Status und Zustelldatum widersprüchlich | 8 `delivered` ohne Datum, 6 mit Datum ohne `delivered` |
| Zahlungsabweichung über 1 % | 254 von 98.665 Bestellungen (0,26 %), 236 zahlen mehr, 18 weniger |
| Gesamtdifferenz Zahlung gegen Ware plus Fracht | +2.870,39 BRL |
| Abweichungen nach Hauptzahlart | 243 Kreditkarte, 7 Debitkarte, 4 Gutschein, 0 Boleto |
| Naiver Dreifach-Join | 117.601 Zeilen statt 99.441; Zahlbetrag 20.308.134,71 statt 16.008.872,12 BRL (+26,9 %); Warenumsatz 14.209.115,34 statt 13.591.643,70 BRL (+4,5 %) |
| `fact_orders` | trifft beide Summen auf den Cent |
| Ränder | 329 Bestellungen vor Januar 2017 (324 davon im Oktober 2016), 20 nach August 2018 |
| Im Fenster | 99.092 Bestellungen (99,65 %), im Schnitt 4.955 je Monat |
| Zeitstempel-Reihenfolge | 1.359 Übergaben an Logistik vor Zahlungsfreigabe (Median -0,74 Tage, 450 unter -1 Tag), 23 Zustellungen vor Übergabe, 0 Zustellungen vor Kauf |
| Basis Lieferanalysen im Fenster | 96.203 zugestellte Bestellungen mit Datum, 95.560 davon mit Bewertung |
| Verspätet im Fenster | 6.531 (6,79 %) |

Pflichtprüfungen nach Neuaufbau: `fact_orders` = `orders` = 99.441 Zeilen, Wiederkaufrate 3,12 % (größer null), `02_validation.sql` läuft fehlerfrei. Alle drei bestanden.

### Warum so entschieden

- **Bestellstatus**: Lieferzeit- und Bewertungsanalysen nutzen nur `delivered` mit gefülltem Zustelldatum (96.470 Bestellungen, im Fenster 96.203). Die doppelte Bedingung ist nötig, weil Status und Datum in 14 Fällen nicht zusammenpassen. `canceled` und `unavailable` werden als Stornoquote getrennt ausgewiesen. Umsatz wird als realisierter Umsatz der zugestellten Bestellungen gerechnet; das sind 97,34 % des Warenumsatzes im Fenster, die Wahl verschiebt also kaum etwas.
- **Bestellungen, die nie zugestellt wurden**: Sie bleiben in `fact_orders`, fließen aber nicht in Lieferzeit oder Verzug ein, weil es keine Zustellung gibt, die man messen könnte. Sie tragen auffällig schlechte Bewertungen (zum Beispiel `unavailable` im Schnitt 1,53 Sterne gegenüber 4,16 bei `delivered`). Die Stornoquote wird deshalb als eigene Verkäuferkennzahl geführt.
- **Zahlungsabstimmung**: Die Abweichungen sind selten (0,26 %) und fast nur bei Kreditkarte, was zu Ratenzuschlägen passt. Gutscheine erklären sie nicht: Von 3.766 Bestellungen mit Gutscheinanteil weichen nur 6 ab, weil Gutscheine als eigene Zahlungszeile mitgezählt sind. Das bestätigt die Umsatzdefinition: Umsatz ist `price`, Fracht getrennt, der Zahlbetrag nur für Zahlungsanalysen.
- **Analysefenster Januar 2017 bis August 2018**: Vor 2017 gibt es nur 329 Bestellungen, fast alle in einem einzigen Monat, im November 2016 gar keine. Nach August 2018 gibt es nur 20 Bestellungen, weil der Datenabzug dort endet. Beide Ränder würden in Zeitreihen ein Nichts am Anfang und einen künstlichen Absturz am Ende zeigen. Das Fenster behält 99,65 % aller Bestellungen.
- **Negative Bearbeitungszeiten**: Die Werte bleiben in `fact_orders` stehen, damit nichts still verändert wird. Für die Zerlegung der Lieferzeit und für die Bearbeitungszeit je Verkäufer zählen aber nur Bestellungen, bei denen Bearbeitung und Transport nicht negativ sind. Eine negative Dauer ist unmöglich und würde Durchschnitte verfälschen. Gesamtlaufzeit und Verzug sind nicht betroffen, weil keine Zustellung vor dem Kauf liegt.

**Abnahmekriterium AP3** (Validierungsabfragen laufen, Ergebnisse dokumentiert): erfüllt. `02_validation.sql` läuft mit 23 Anweisungen fehlerfrei, jede Abfrage trägt ihr Ergebnis als Kommentar, die Zahlen stehen oben in der Tabelle.

---

## AP4 — SQL-Abfragen 5 bis 12: Kommerz und Operations

### Was wurde gemacht

- `01_sql/03_commercial.sql` enthält die Abfragen 5 bis 8: Umsatz je Monat mit Vormonatswachstum über `LAG`, Pareto der Kategorien mit kumuliertem Anteil über `SUM() OVER (ORDER BY ...)`, Bestellwert je Bundesstaat und Region, Zahlungsverhalten.
- `01_sql/04_operations.sql` enthält die Abfragen 9 bis 12: Zerlegung der Lieferzeit, Verspätungsquote je Monat, Region und Bundesstaat, Bewertung nach Verzugsklasse, Frachtanteil je Kategorie und Entfernungsklasse.
- Jede Abfrage hat einen Kommentarblock mit der Frage und dem Ergebnis in Zahlen. Alle Abfragen nutzen das Analysefenster Januar 2017 bis August 2018 und nur zugestellte Bestellungen.
- `02_validation.sql` hat eine Prüfung B8 bekommen: Wie viele Bestellungen landen über die Kundendimension in einem anderen Bundesstaat als ihre eigene Lieferadresse? Antwort: 43 von 99.441.

### Was kam heraus

**Kommerz**

| Kennzahl | Wert |
|---|---|
| Realisierter Umsatz im Fenster | 13.181.027,13 BRL aus 96.211 zugestellten Bestellungen |
| Wachstum Jan–Aug 2018 gegen Jan–Aug 2017 | +141,1 % |
| Stärkster Monat | November 2017, 987.765 BRL (+52,4 % zum Vormonat) |
| Durchschnittlicher Bestellwert je Monat | zwischen 124 und 149 BRL |
| Konzentration Kategorien | Top 7 von 74 machen 49,9 % des Umsatzes, 18 Kategorien machen 81,3 % |
| Top-Kategorie | health_beauty, 1.229.558 BRL (9,33 %) |
| Bestellwert nach Region | Norte 181,96 BRL, Sudeste 130,61 BRL |
| Frachtanteil nach Region | Norte 22,7 %, Sudeste 15,2 % |
| Anteil Sudeste an Bestellungen | 68,6 % |
| Kreditkarte als Hauptzahlart | 75,44 % der Bestellungen, 78,42 % des Zahlbetrags, im Schnitt 3,55 Raten |
| Raten nach Bestellwert | 2,08 unter 50 BRL bis 7,29 ab 500 BRL |

**Operations**

| Kennzahl | Wert |
|---|---|
| Gesamtlaufzeit | 12,6 Tage im Schnitt |
| davon Freigabe / Bearbeitung / Transport | 0,4 / 2,8 / 9,4 Tage |
| Bearbeitung je Region | 2,7 bis 2,9 Tage, also überall gleich |
| Transport je Region | Sudeste 7,6 Tage, Norte 19,3 Tage |
| Verspätungsquote gesamt | 6,79 % |
| Puffer zum Versprechen | im Schnitt 11,8 Tage zu früh zugestellt |
| Schlechteste Monate | März 2018 18,96 %, Februar 2018 14,13 %, November 2017 12,40 % |
| Verspätungsquote Nordeste | 12,76 %, fast doppelt so hoch wie gesamt |
| Schlechteste Bundesstaaten | AL 21,46 %, MA 17,46 %; RJ 12,15 % gegenüber SP 4,50 % |
| Bewertung pünktlich | 4,29 Sterne, 6,6 % Ein-Stern |
| Bewertung 1–3 Tage zu spät | 3,29 Sterne, 25,1 % Ein-Stern |
| Bewertung 4–7 Tage zu spät | 2,10 Sterne, 58,6 % Ein-Stern |
| Bewertung über 7 Tage zu spät | 1,70 Sterne, 69,8 % Ein-Stern |
| Höchster Frachtanteil Kategorie | electronics 29,5 %, office_furniture 25,0 % |
| Frachtanteil nach Entfernung | gleicher Staat 13,0 %, gleiche Region 17,4 %, andere Region 18,8 % |
| Verkäufer-Standort | 83,7 % der Positionen kommen aus dem Sudeste |

### Warum so entschieden

- **Realisierter Umsatz**: Nur zugestellte Bestellungen zählen als Umsatz. Offene Bestellungen können noch storniert werden. Weil zugestellte Bestellungen 97,34 % des Warenumsatzes tragen, ändert die Wahl am Bild nichts.
- **Verzug gegen Versprechen als Leitgröße**: Kunden bekommen beim Kauf ein Lieferdatum genannt. Ob dieses Datum gehalten wird, misst die Erwartung, nicht die Dauer. Dass der Norte trotz 22,6 Tagen Laufzeit eine niedrigere Verspätungsquote hat als der Nordeste, zeigt den Unterschied: Dort wird großzügiger versprochen.
- **Verzugsklassen**: pünktlich (null oder weniger Tage), 1 bis 3, 4 bis 7, über 7 Tage. Die Grenzen folgen dem Gefühl des Kunden: ein paar Tage, etwa eine Woche, mehr als eine Woche.
- **Zerlegung der Lieferzeit nur bei plausibler Reihenfolge**: 94.844 von 96.203 zugestellten Bestellungen im Fenster. Ohne diesen Filter würden unmögliche negative Bearbeitungszeiten den Durchschnitt drücken.
- **Ratenanalysen nur bei Kreditkarte**: Nur dort gibt es Raten. Andere Zahlarten würden den Schnitt auf 1 ziehen.
- **Kategorie bei Ratenanalysen**: Eine Bestellung zählt in jeder Kategorie, aus der sie eine Position enthält, aber je Kategorie nur einmal. Damit gibt es innerhalb einer Kategorie keinen Fan-out.
- **Entfernungsklasse über Bundesstaaten**: In SQL robust und für das Management lesbar. Kilometer folgen in der Python-Frachtanalyse.
- **Bundesstaat aus der Kundendimension**: Nur 43 Bestellungen (0,043 %) würden über die Lieferadresse einem anderen Staat zugeordnet. Die Abweichung vom Datenmodell, eine eigene Lieferadresse in `fact_orders` zu führen, lohnt sich dafür nicht.

**Abnahmekriterium AP4** (alle Abfragen 5–12 laufen, jede mit Interpretationssatz): erfüllt. Beide Dateien laufen fehlerfrei, jede Abfrage trägt Frage und Ergebnis mit Zahl im Kommentar.

---

## AP5 — Lieferverzug gegen Bewertung, Frachtanalyse, Wiederkäufer (Python)

### Was wurde gemacht

- `02_python/02_delivery_analysis.py`, Teil 1: Bewertung je Verzugsklasse mit 95-%-Konfidenzintervall, Gegenprobe nach absoluter Lieferdauer, eine einfache Regression (Bewertung auf "verspätet ja/nein" und Lieferdauer), Rangkorrelation und drei Robustheitsprüfungen gegen naheliegende Störfaktoren.
- `02_python/02_delivery_analysis.py`, Teil 2: Luftlinie zwischen Verkäufer und Kunde in Kilometern, Regression des Frachtwerts auf Gewicht, Volumen und Entfernung, Frachtanteil nach Entfernungsband, teuerste Routen.
- `02_python/04_rfm.py`: RFM-Segmente je realer Person und der Vergleich Wiederkäufer gegen Einmalkäufer anhand dessen, was sie bei ihrer ersten Bestellung erlebt haben.
- `02_python/chart_style.py`: gemeinsamer Diagrammstil (Farben, Achsen), damit alle Charts gleich aussehen.
- Charts liegen in `reports/figures/`, CSV-Exporte in `03_dashboard/exports/`.

### Was kam heraus

**Verzug und Bewertung** (95.560 zugestellte, bewertete Bestellungen im Fenster)

| Verzugsklasse | Anteil | Ø Bewertung (95-%-Konfidenzintervall) | Ein-Stern | Ein- oder Zwei-Stern |
|---|---|---|---|---|
| pünktlich | 93,3 % | 4,29 (4,28–4,30) | 6,6 % | 9,2 % |
| 1 bis 3 Tage zu spät | 1,9 % | 3,29 (3,22–3,36) | 25,1 % | 32,1 % |
| 4 bis 7 Tage zu spät | 1,8 % | 2,10 (2,03–2,18) | 58,6 % | 67,6 % |
| über 7 Tage zu spät | 2,9 % | 1,70 (1,65–1,74) | 69,8 % | 79,3 % |

- Verspätete Bestellungen sind 6,7 % der bewerteten Bestellungen, aber 36,8 % aller Ein-Stern-Bewertungen.
- **Gegenprobe Lieferdauer:** Auch bei pünktlicher Lieferung sinkt die Bewertung mit der Dauer, aber langsam: von 4,42 (bis 7 Tage) auf 3,67 (über 30 Tage). Verspätete Lieferungen liegen in jeder Dauerklasse deutlich darunter, zum Beispiel bei 8 bis 14 Tagen 3,34 statt 4,32.
- **Regression:** Bei gleicher Lieferdauer geht ein gebrochenes Versprechen mit 1,54 Sternen weniger einher. Eine Woche mehr Lieferdauer bei gleichem Pünktlichkeitsstatus mit 0,15 Sternen weniger. Rechnerisch entspricht ein gebrochenes Versprechen also rund 74 Tagen zusätzlicher Lieferdauer. Das Modell erklärt 16,9 % der Streuung der Bewertungen; der Rest hängt an anderen Dingen.
- **Rangkorrelation:** Verzug gegen Bewertung -0,18; Lieferdauer gegen Bewertung bei pünktlichen Lieferungen -0,13.
- **Robustheit:** Bei Bestellungen mit nur einer Position (86.061) beträgt der Abstand pünktlich gegen verspätet 2,08 Sterne. In jeder Region liegt er zwischen 1,93 und 2,07 Sternen. Bestellungen mit mehreren Verkäufern (1.258) sind fast nie verspätet (0,95 %), werden aber im Schnitt nur mit 2,86 Sternen bewertet gegenüber 4,17 bei einem Verkäufer. Es gibt also eindeutig weitere Treiber schlechter Bewertungen neben dem Verzug.

**Fracht** (109.880 Positionen, 109.346 mit Koordinaten, Median-Entfernung 432 km)

| Treiber | R² allein | Standardisierter Koeffizient im gemeinsamen Modell |
|---|---|---|
| Gewicht | 0,374 | 0,402 |
| Volumen | 0,340 | 0,263 |
| Entfernung | 0,154 | 0,398 |
| alle drei | 0,555 | |

- Gewicht erklärt allein am meisten. Im gemeinsamen Modell wiegen Gewicht und Entfernung etwa gleich schwer. Volumen verliert dort an Gewicht, weil es stark mit dem Gewicht zusammenhängt (Korrelation 0,81).
- Frachtanteil am Warenwert nach Luftlinie: bis 100 km 11,8 %, 100–500 km 15,7 %, 500–1.000 km 17,7 %, 1.000–2.000 km 19,3 %, über 2.000 km 22,7 %.
- Teuerste Route nach Ø Fracht: SP nach PB mit 43,31 BRL je Position. Höchster Frachtanteil: SP nach MA mit 31,2 % des Warenwerts. Neun der zehn teuersten Routen beginnen in SP und enden im Norden oder Nordosten.

**Kunden und Wiederkauf** (93.104 Kunden mit zugestellter Bestellung im Fenster)

- 2.005 Kunden (2,15 %) haben an mehr als einem Tag gekauft. 784 weitere hatten mehrere Bestellungen nur am selben Tag.
- RFM: Die größte Umsatzgruppe sind ältere Einmalkäufer mit hohem Bestellwert: 22,7 % der Kunden, 43,0 % des Umsatzes. Alle Wiederkäufer zusammen sind 2,15 % der Kunden und 4,1 % des Umsatzes.
- Wiederkauf innerhalb von 180 Tagen: 1.112 von 56.194 Kunden mit Erstkauf bis 4. März 2018 (1,98 %).
- **Was Wiederkäufer unterscheidet:** Am deutlichsten die Kategorie der Erstbestellung (Chi-Quadrat p unter 0,001): fashion_bags_accessories 3,3 %, pet_shop 3,0 %, bed_bath_table 2,7 % gegenüber cool_stuff 1,0 %. Dann die Region (p = 0,002): Sudeste 2,14 % gegenüber Nordeste 1,47 %. Bewertung und Pünktlichkeit der Erstbestellung zeigen die erwartete Richtung (5 Sterne 2,12 % gegen 1 Stern 1,68 %; pünktlich 2,01 % gegen verspätet 1,55 %), sind aber nicht signifikant (p = 0,062 und 0,055).

### Warum so entschieden

- **Verzug gegen Versprechen als Leitgröße** wurde nicht nur gesetzt, sondern geprüft. Die Gegenprobe zeigt ehrlich, dass auch die Dauer eine Rolle spielt. Der Verzug wiegt aber rund zehnmal schwerer als eine zusätzliche Woche Lieferzeit.
- **Spearman und Mann-Whitney statt Pearson und t-Test**: Bewertungen sind Stufen von 1 bis 5, keine metrischen Werte. Rangverfahren setzen keine Normalverteilung voraus. Für die Regression wird die Bewertung trotzdem wie eine Zahl behandelt, weil das Ergebnis dann in "Sternen" lesbar ist; das ist eine bewusste Vereinfachung.
- **Robustheitsprüfungen**: Sie können einen Störfaktor nicht ausschließen, aber zeigen, ob der Befund an einer naheliegenden Teilgruppe hängt. Er hängt weder an Mehrfachbestellungen noch an einer Region.
- **Kausalität**: Nirgends wird behauptet, dass Verzug schlechte Bewertungen verursacht. Defekte Ware, falsche Produktbeschreibung oder ein insgesamt nachlässiger Verkäufer können beides erklären.
- **Frachtanalyse im Lieferskript**: Fracht und Lieferzeit hängen an derselben Geografie (Verkäufer im Südosten, Kunden im ganzen Land). Deshalb stehen beide Analysen in einem Skript, statt ein zusätzliches Skript einzuführen.
- **Entfernung als Luftlinie** zwischen den Median-Koordinaten der PLZ-Präfixe. Die echte Straßenstrecke ist länger, die Reihenfolge der Entfernungen bleibt aber erhalten.
- **Routen erst ab 200 Positionen**, damit einzelne teure Sendungen kein Ranking bestimmen.
- **Wiederkauf-Definition**: späterer Kauftag innerhalb von 180 Tagen. Gleicher Tag zählt nicht, weil das ein aufgeteilter Warenkorb ist. Das feste Fenster gibt jedem Kunden gleich viel Zeit; deshalb zählen nur Erstkäufe bis 4. März 2018.
- **F-Score als feste Klassen** (1, 2, 3+ Kauftage), weil über 97 % der Kunden genau einen Kauftag haben.
- **Hauptkategorie einer Bestellung** = Kategorie der teuersten Position.

**Abnahmekriterium AP5** (Kernbefund steht als Zahl): erfüllt. Pünktlich 4,29 Sterne, über 7 Tage Verzug 1,70 Sterne. Bei gleicher Lieferdauer geht ein gebrochenes Versprechen mit 1,54 Sternen weniger einher.

---

## AP6 — Verkäufer-Scorecard und Cutoff-Analyse

### Was wurde gemacht

- `01_sql/05_sellers.sql`: Abfragen 13 bis 15 (Umsatzkonzentration, Verkäufer-Kennzahlen, Verkäufer-Kohorten). Dazu zwei Views: `v_seller_orders` (eine Zeile je Verkäufer und Bestellung) und `v_seller_kpis` (eine Zeile je Verkäufer).
- `02_python/03_seller_score.py`: Scorecard von 0 bis 100 aus vier Kennzahlen. Jede Kennzahl wird zum Marktmittel gedämpft, auf 0 bis 100 normiert und gewichtet. Die Python-Kennzahlen werden gegen die SQL-View abgeglichen. Zusätzlich ein zweiter Score nur aus Bestellungen von 2017.
- `02_python/05_cutoff_analysis.py`: Für jede Schwelle von 0 bis 100 wird gerechnet, was ein Ausschluss aller Verkäufer darunter bringt und kostet. Dann wird eine Schwelle nach fester Regel gewählt, in Quadranten eingeordnet und mit dem 2017er Score gegen die Bestellungen von 2018 gegengeprüft.

### Was kam heraus

**Konzentration und Kohorten (SQL)**

| Kennzahl | Wert |
|---|---|
| Verkäufer mit realisiertem Umsatz | 2.945 |
| Umsatzanteil Top 1 % / 5 % / 10 % / 20 % | 25,9 % / 53,0 % / 67,0 % / 82,2 % |
| Umsatzanteil untere Hälfte | 3,4 % |
| Verkäufer mit weniger als 10 zugestellten Bestellungen | 1.834 von 3.068 (60 %) |
| Median zugestellte Bestellungen je Verkäufer | 6 |
| Aktiv nach 1 / 3 / 6 / 12 Monaten | 57,6 % / 52,4 % / 44,4 % / 35,2 % |

**Scorecard**

| Baustein | Gewicht | 0 Punkte bei | 100 Punkte bei | Geschätzte Dämpfung k |
|---|---|---|---|---|
| Bewertung | 40 % | 1 Stern | 5 Sterne | 26 Bestellungen |
| Verspätungsquote | 30 % | 20 % | 0 % | 42 Bestellungen |
| Bearbeitungszeit | 15 % | 10 Tage | 0 Tage | 5 (Untergrenze) |
| Stornoquote | 15 % | 10 % | 0 % | 65 Bestellungen |

- Abgleich Python gegen SQL-View: Umsatz, Bewertung, Verspätung und Storno stimmen für alle 3.068 Verkäufer überein.
- Score-Verteilung der 691 Verkäufer mit mindestens 25 bewertbaren Bestellungen: Median 78,2, unteres Quartil unter 73,6, Minimum 39,2.
- Beispiel Dämpfung: Ein Verkäufer mit drei Fünf-Sterne-Bewertungen bekommt nicht 5,0, sondern 4,26, weil der Marktschnitt bei 4,17 liegt und erst ab rund 26 Bestellungen der eigene Wert überwiegt.
- Sensitivität der Gewichte (Rangkorrelation mit dem Basis-Score): gleichgewichtet 0,977, nur Operations 0,963, Bewertung stärker 0,980, nur Bewertung 0,746. Das untere Quartil bleibt bei den ersten drei Varianten zu 88 bis 94 % dasselbe.

**Cutoff**

| Kennzahl bei Score 62 | Wert |
|---|---|
| Verkäufer unter der Schwelle | 62 |
| Anteil an allen Ein-Stern-Bewertungen | 9,7 % (902 Bewertungen) |
| Anteil am Umsatz | 4,8 % (636.001 BRL) |
| Durchschnittsbewertung vorher / nachher | 4,156 / 4,185 (+0,029 Sterne) |
| Gegenprobe 2017er Score auf 2018 | 3,3 % der Ein-Stern-Bewertungen bei 2,2 % Umsatz, +0,009 Sterne |
| Regel "größter Abstand" zum Vergleich | Score 76, 55,1 % Ein-Stern bei 39,0 % Umsatz |

- Quadranten (groß = Top 20 % nach Umsatz, ab 4.420 BRL; gut = Score ab 62): 587 groß und gut (78,6 % Umsatz), 27 groß und schwach (4,4 %), 2.419 klein und gut (16,6 %), 35 klein und schwach (0,4 %).
- Unteres Score-Quartil der 691 verlässlich bewerteten Verkäufer (173 Verkäufer, Score unter 73,6): 36,7 % der Ein-Stern-Bewertungen bei 23,3 % des Umsatzes.

**Was das heißt:** Schwache Verkäufer tragen etwa doppelt so viel Anteil an Ein-Stern-Bewertungen wie an Umsatz. Ein Ausschluss allein bewegt die Durchschnittsbewertung aber kaum, und mit einem Score aus der Vergangenheit schrumpft der Effekt auf ein Drittel. Schlechte Erlebnisse sind über den ganzen Marktplatz verteilt, nicht in wenigen Verkäufern gebündelt. Aussortieren ist deshalb ein Werkzeug für wenige klare Fälle, der größere Hebel liegt beim Lieferversprechen.

### Warum so entschieden

- **Verkäuferzuordnung**: Bewertung, Verspätung und Bearbeitung zählen nur bei Bestellungen mit genau einem Verkäufer, weil sich bei mehreren Verkäufern nicht sagen lässt, wer verantwortlich ist. Umsatz und Storno zählen bei jedem beteiligten Verkäufer.
- **Gewichte 40/30/15/15**: Bewertung als direktes Kundenurteil am stärksten, Verspätung als stärkster Begleiter schlechter Bewertungen aus AP5, Bearbeitung und Storno geringer, weil die Bearbeitung zum Teil in der Verspätung steckt und Stornos selten sind. Die Gewichte sind gesetzt, nicht optimiert; die Sensitivitätsprüfung zeigt, dass das Ranking kaum daran hängt.
- **Feste Anker statt Perzentile**: "Score 60" bedeutet so immer dasselbe, auch wenn sich die Verkäuferbasis ändert.
- **Dämpfung statt Mindestbestellzahl**: Kein Verkäufer fällt aus der Bewertung, aber wenige Bestellungen ziehen ihn zum Marktschnitt. Die Stärke k wird je Kennzahl geschätzt als Verhältnis der Streuung innerhalb eines Verkäufers zur echten Streuung zwischen Verkäufern. Für die Bearbeitungszeit ergibt das einen sehr kleinen Wert (Verkäufer sind dort sehr konstant), deshalb greift die Untergrenze von 5.
- **Cutoff über ein Umsatzbudget von höchstens 5 %**: Ohne Margendaten gibt es kein Gewinnoptimum. Ein Budget ist eine bewusst gesetzte Risikobereitschaft. Die Regel "größter Abstand zwischen vermiedenen Ein-Stern-Bewertungen und verlorenem Umsatz" hätte 39 % Umsatz gekostet.
- **Gegenprobe mit 2017er Score**: Der Score enthält die Bewertungen, an denen der Effekt gemessen wird. Ohne Gegenprobe wäre der Effekt eines Ausschlusses zu optimistisch.
- **Bestellungen mit mehreren Verkäufern im Cutoff**: Fällt einer der Verkäufer weg, entfällt die Bestellung samt Bewertung; der Umsatz entfällt nur für dessen Anteil.
- **Verkäufer-Kohorten statt Kunden-Kohorten**: Bei rund 2 % Wiederkäufern wäre eine Kunden-Kohortentabelle fast leer.

**Abnahmekriterium AP6** (Trade-off-Tabelle liegt vor, Schlagzeile gefüllt): erfüllt. Die Tabelle steht in `03_dashboard/exports/cutoff_tradeoff.csv` (Schwellen 0 bis 100), die Schlagzeile im README ist mit berechneten Zahlen gefüllt.
