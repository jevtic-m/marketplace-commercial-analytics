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

**Abnahmekriterium AP2** (`fact_orders` steht, Fan-out nachweislich gelöst): erfüllt. Zeilenzahl 99.441 = `orders`, Umsatz- und Zahlungssumme stimmen auf den Cent mit den Rohtabellen überein. Der explizite Fan-out-Nachweis (naiver Join gegen Aggregation) folgt als Abfrage in AP3.

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
