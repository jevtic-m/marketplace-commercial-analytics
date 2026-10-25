# Commercial & Operations Analytics — Marktplatz-Analyse

**Business-Frage:** Wo verliert ein Online-Marktplatz Kundenzufriedenheit und Marge, und welche Verkäufer sollte er steuern, fördern oder aussortieren?

**Kernergebnis:** Verkäufer unterhalb Score [X] verursachen [Y] % aller Ein-Stern-Bewertungen bei nur [Z] % des Umsatzes. Ein Ausschluss hebt die Durchschnittsbewertung um [A] Sterne und kostet [Z] % Umsatz.

**Stack:** DuckDB (SQL, 9 verknüpfte Tabellen) · Python (pandas, numpy, scipy, matplotlib) · Power BI

---

## Daten

Brazilian E-Commerce Public Dataset by Olist (Kaggle: `olistbr/brazilian-ecommerce`), Lizenz **CC BY-NC-SA 4.0** (nicht-kommerziell, Namensnennung, Weitergabe unter gleichen Bedingungen). Verkäufernamen sind im Datensatz pseudonymisiert.

- 99.441 Bestellungen, 112.650 Positionen, 103.886 Zahlungszeilen, 99.224 Bewertungen
- 96.096 reale Kunden (über `customer_unique_id`), 3.095 Verkäufer, 32.951 Produkte
- Zeitraum der Rohdaten: September 2016 bis Oktober 2018
- Analysefenster: Januar 2017 bis August 2018 (Begründung unter Annahmen)
- Währung: Brasilianischer Real (BRL)

### Beziehungsdiagramm

```
customers (customer_id, customer_unique_id)      geolocation (zip_prefix, lat, lng)
      |1                                                 | viele Zeilen je zip_prefix
      |                                                  | -> vor Join auf Median verdichten
      |1                                                 |
   orders (order_id) ---------------------------- sellers (seller_id, zip_prefix)
      |1              |1             |1                  |1
      |n              |n             |0..n               |n
 order_items     order_payments   order_reviews     order_items.seller_id
 (order_id,      (order_id,       (order_id,
  order_item_id)  payment_seq)     review_id)
      |n
      |1
   products (product_id, category_pt) --1--1-- category_translation (category_pt -> en)
```

Die Zahlen an den Kanten sind gemessen, nicht angenommen: Eine Bestellung hat 1 bis 21 Positionen (9.803 Bestellungen mit mehr als einer), 2.961 Bestellungen haben mehrere Zahlungszeilen, 547 haben mehrere Bewertungen, 775 haben gar keine Position (fast alle mit Status `unavailable` oder `canceled`). Belegt in `01_sql/02_validation.sql`, Teil A.

## Methodik

1. Neun Rohtabellen in DuckDB geladen und Schlüsselbeziehungen geprüft (`01_sql/00_load.sql`, `02_validation.sql` Teil A)
2. Star-Schema mit vier Dimensionen (`dim_date`, `dim_customer`, `dim_seller`, `dim_product`) und zwei Faktentabellen (`fact_order_items` auf Positionsebene, `fact_orders` auf Bestellebene, vorverdichtet gegen Fan-out) in `01_sql/01_schema.sql`
3. Datenqualitätsprüfungen inkl. Zahlungsabstimmung und Fan-out-Kontrolle (`01_sql/02_validation.sql`, Teil A und B)
4. Kommerzielle Analysen: Umsatz, Kategorien, Regionen, Zahlverhalten [folgt in AP4]
5. Operations: Lieferzeit-Zerlegung, Verzug gegen Versprechen, Bewertungen [folgt in AP4/AP5]
6. Verkäufer-Scorecard und Cutoff-Analyse [folgt in AP6]

## Ergebnisse

[folgt]

## Annahmen und Limitationen

- Kundenbezogene Kennzahlen laufen ausschließlich über `customer_unique_id`. `customer_id` wird pro Bestellung neu vergeben und ist nur der technische Join-Schlüssel zu `orders`. Über `customer_id` gerechnet wäre die Wiederkaufrate exakt null; tatsächlich haben 2.997 Personen mehr als eine Bestellung.
- Zwei Faktentabellen: `fact_orders` ist je `order_id` vorverdichtet (Positionen, Zahlungen, Bewertungen in getrennten CTEs), damit Umsatz und Zahlbetrag nie mehrfach gezählt werden. Kontrollsumme: Warenumsatz 13.591.643,70 BRL, identisch mit der Summe über `order_items`.
- Umsatz ist die Summe der Positionspreise (`price`). Fracht wird getrennt geführt, der Zahlbetrag (`payment_value`) nur für Zahlungsanalysen verwendet.
- Bei 547 Bestellungen mit mehreren Bewertungen zählt die jüngste Bewertung.
- Verzug gegen Lieferversprechen wird in Kalendertagen gerechnet (Zustelldatum minus versprochenes Datum); positiv heißt zu spät.
- Geolocation wird vor dem Join auf den Median je PLZ-Präfix verdichtet, 42 Koordinaten außerhalb Brasiliens werden verworfen.
- **Analysefenster Januar 2017 bis August 2018.** Vor 2017 liegen nur 329 Bestellungen (324 davon im Oktober 2016, im November 2016 keine), nach August 2018 nur 20, weil der Datenabzug dort endet. Beide Ränder würden Zeitreihen verzerren. Das Fenster behält 99.092 Bestellungen (99,65 %).
- **Bestellstatus.** Lieferzeit und Bewertung nur für `delivered` mit gefülltem Zustelldatum (96.203 Bestellungen im Fenster). `canceled` und `unavailable` laufen getrennt als Stornoquote (1,19 % im Fenster).
- **Zahlungsabstimmung.** 254 von 98.665 Bestellungen (0,26 %) weichen beim Zahlbetrag um mehr als 1 % von Warenwert plus Fracht ab, fast alle mit Kreditkarte.
- **Fan-out-Nachweis.** Der naive Join von Bestellungen, Positionen und Zahlungen ergibt 117.601 Zeilen statt 99.441 und überhöht den Zahlbetrag um 26,9 %.
- **Zeitstempel.** Bei 1.359 Bestellungen liegt die Übergabe an die Logistik vor der Zahlungsfreigabe. Für die Lieferzeit-Zerlegung zählen nur Bestellungen mit nicht negativen Teilzeiten.
- Weitere Annahmen folgen mit den jeweiligen Arbeitspaketen.

## Reproduktion

Voraussetzung: Python 3.11 oder neuer. Rohdaten von Kaggle herunterladen und die neun CSV-Dateien nach `data/raw/` legen (nicht im Repo enthalten).

```bash
pip install -r requirements.txt
python 02_python/01_data_prep.py
python 02_python/run_sql.py 01_sql/02_validation.sql
```

`01_data_prep.py` lädt die CSVs (`00_load.sql`), baut das Star-Schema (`01_schema.sql`) und prüft: `fact_orders` = `orders` (99.441 Zeilen), Wiederkaufrate über `customer_unique_id` größer null (3,12 %), Validierung läuft fehlerfrei.

Weitere Schritte folgen mit den nächsten Arbeitspaketen.

## Repo-Struktur

```
01_sql/            SQL-Skripte, nummeriert in Ausführungsreihenfolge
02_python/         Python-Skripte, laufen aus dem Repo-Root
03_dashboard/      CSV-Exporte und DAX-Measures für Power BI
data/raw/          Kaggle-CSVs (nicht im Repo)
data/olist.duckdb  DuckDB-Datei (wird erzeugt, nicht im Repo)
reports/           findings.md, interview_notes.md, walkthrough.md, figures/
```
