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
