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

Auffälligkeiten aus den Laufzeit-Kennzahlen: Verzug gegen Versprechen reicht von -147 bis +188 Tagen, Gesamtlaufzeit bis 209,6 Tage. 1.359 Bestellungen haben eine negative Bearbeitungszeit (Übergabe an Logistik vor Zahlungsfreigabe), vermutlich ein Prozessartefakt beim Buchen der Freigabe. Diese Fälle werden in AP3 gezählt und in den Lieferzeitanalysen nicht bereinigt, weil sie die Reihenfolge der Ereignisse, nicht die Zustellung betreffen.

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
