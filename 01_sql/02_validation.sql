-- ============================================================================
-- 02_validation.sql: Datenqualität und Schlüsselbeziehungen
-- ============================================================================
-- Ausführung: python 02_python/run_sql.py 01_sql/02_validation.sql
-- Jede Aussage zur Datenqualität im README ist durch eine Abfrage hier belegt.
-- Teil A läuft direkt nach 00_load.sql (nur Rohtabellen).
-- Teil B braucht das Star-Schema aus 01_schema.sql.
-- ============================================================================


-- ============================================================================
-- TEIL A: Rohtabellen, Schlüssel und Beziehungen
-- ============================================================================

-- A1. Zeilen und Schlüssel je Tabelle
-- Frage: Ist der vermutete Schlüssel jeder Tabelle wirklich eindeutig?
-- Ergebnis: orders (99.441), customers (99.441), sellers (3.095), products (32.951)
--   sind eindeutig auf ihrem Schlüssel. order_items ist eindeutig auf
--   (order_id, order_item_id), order_payments auf (order_id, payment_sequential).
--   order_reviews ist NICHT eindeutig: 99.224 Zeilen, aber nur 98.410 review_id
--   und 98.673 order_id. Geolocation hat 1.000.163 Zeilen für 19.015 PLZ-Präfixe.
SELECT 'orders' AS table_name, COUNT(*) AS n_rows,
       COUNT(DISTINCT order_id) AS n_distinct_key,
       COUNT(*) = COUNT(DISTINCT order_id) AS key_is_unique
FROM orders
UNION ALL
SELECT 'customers', COUNT(*), COUNT(DISTINCT customer_id),
       COUNT(*) = COUNT(DISTINCT customer_id)
FROM customers
UNION ALL
SELECT 'order_items', COUNT(*), COUNT(DISTINCT (order_id, order_item_id)),
       COUNT(*) = COUNT(DISTINCT (order_id, order_item_id))
FROM order_items
UNION ALL
SELECT 'order_payments', COUNT(*), COUNT(DISTINCT (order_id, payment_sequential)),
       COUNT(*) = COUNT(DISTINCT (order_id, payment_sequential))
FROM order_payments
UNION ALL
SELECT 'order_reviews', COUNT(*), COUNT(DISTINCT review_id),
       COUNT(*) = COUNT(DISTINCT review_id)
FROM order_reviews
UNION ALL
SELECT 'sellers', COUNT(*), COUNT(DISTINCT seller_id),
       COUNT(*) = COUNT(DISTINCT seller_id)
FROM sellers
UNION ALL
SELECT 'products', COUNT(*), COUNT(DISTINCT product_id),
       COUNT(*) = COUNT(DISTINCT product_id)
FROM products
UNION ALL
SELECT 'geolocation', COUNT(*), COUNT(DISTINCT geolocation_zip_code_prefix),
       COUNT(*) = COUNT(DISTINCT geolocation_zip_code_prefix)
FROM geolocation
UNION ALL
SELECT 'category_translation', COUNT(*), COUNT(DISTINCT product_category_name),
       COUNT(*) = COUNT(DISTINCT product_category_name)
FROM category_translation;


-- A2. customer_id gegen customer_unique_id
-- Frage: Wie viele reale Personen stecken hinter den 99.441 customer_id?
-- Ergebnis: 96.096 reale Kunden (customer_unique_id). 2.997 Personen haben mehr
--   als eine Bestellung. Wer über customer_id rechnet, sieht 0 Wiederkäufer.
SELECT COUNT(*)                            AS n_customer_id,
       COUNT(DISTINCT customer_unique_id)  AS n_unique_persons,
       COUNT(*) - COUNT(DISTINCT customer_unique_id) AS n_ids_more_than_persons
FROM customers;

SELECT COUNT(*) AS n_persons_with_repeat_orders
FROM (
    SELECT customer_unique_id
    FROM orders
    JOIN customers USING (customer_id)
    GROUP BY customer_unique_id
    HAVING COUNT(*) > 1
);


-- A3. Referenzielle Integrität zwischen den Tabellen
-- Frage: Gibt es Zeilen, deren Fremdschlüssel ins Leere zeigen?
-- Ergebnis: Keine verwaisten Zeilen bei orders->customers, items->orders,
--   items->products, items->sellers, payments->orders, reviews->orders.
--   Umgekehrt: 775 Bestellungen ohne Position (fast alle 'unavailable' oder
--   'canceled'), 1 Bestellung ohne Zahlung, 768 Bestellungen ohne Bewertung.
SELECT 'orders_without_customer' AS check_name, COUNT(*) AS n_rows
FROM orders o LEFT JOIN customers c USING (customer_id) WHERE c.customer_id IS NULL
UNION ALL
SELECT 'items_without_order', COUNT(*)
FROM order_items i LEFT JOIN orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL
SELECT 'items_without_product', COUNT(*)
FROM order_items i LEFT JOIN products p USING (product_id) WHERE p.product_id IS NULL
UNION ALL
SELECT 'items_without_seller', COUNT(*)
FROM order_items i LEFT JOIN sellers s USING (seller_id) WHERE s.seller_id IS NULL
UNION ALL
SELECT 'payments_without_order', COUNT(*)
FROM order_payments p LEFT JOIN orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL
SELECT 'reviews_without_order', COUNT(*)
FROM order_reviews r LEFT JOIN orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL
SELECT 'orders_without_items', COUNT(*)
FROM orders o LEFT JOIN order_items i USING (order_id) WHERE i.order_id IS NULL
UNION ALL
SELECT 'orders_without_payment', COUNT(*)
FROM orders o LEFT JOIN order_payments p USING (order_id) WHERE p.order_id IS NULL
UNION ALL
SELECT 'orders_without_review', COUNT(*)
FROM orders o LEFT JOIN order_reviews r USING (order_id) WHERE r.order_id IS NULL;

-- Status der Bestellungen ohne Position: fast nur 'unavailable' und 'canceled'
SELECT o.order_status, COUNT(*) AS n_orders_without_items
FROM orders o
LEFT JOIN order_items i USING (order_id)
WHERE i.order_id IS NULL
GROUP BY o.order_status
ORDER BY n_orders_without_items DESC;


-- A4. Kardinalitäten: wie viele Kindzeilen je Bestellung?
-- Frage: Wie oft hat eine Bestellung mehrere Positionen, Zahlungen, Bewertungen?
-- Ergebnis: 9.803 Bestellungen mit mehr als einer Position, 2.961 mit mehr als
--   einer Zahlungszeile, 547 mit mehr als einer Bewertung, 1.278 mit mehreren
--   Verkäufern. Genau diese Bestellungen erzeugen beim naiven Join den Fan-out.
SELECT 'orders_with_multiple_items' AS check_name, COUNT(*) AS n_orders
FROM (SELECT order_id FROM order_items GROUP BY order_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'orders_with_multiple_payment_rows', COUNT(*)
FROM (SELECT order_id FROM order_payments GROUP BY order_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'orders_with_multiple_payment_types', COUNT(*)
FROM (SELECT order_id FROM order_payments GROUP BY order_id HAVING COUNT(DISTINCT payment_type) > 1)
UNION ALL
SELECT 'orders_with_multiple_reviews', COUNT(*)
FROM (SELECT order_id FROM order_reviews GROUP BY order_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'orders_with_multiple_sellers', COUNT(*)
FROM (SELECT order_id FROM order_items GROUP BY order_id HAVING COUNT(DISTINCT seller_id) > 1)
UNION ALL
SELECT 'review_ids_used_for_multiple_orders', COUNT(*)
FROM (SELECT review_id FROM order_reviews GROUP BY review_id HAVING COUNT(*) > 1);


-- A5. Fehlende Werte in den fünf Zeitstempeln
-- Frage: Wie vollständig ist die Zeitstempelkette?
-- Ergebnis: Kaufzeitpunkt und Lieferversprechen sind immer gefüllt.
--   Zahlungsfreigabe fehlt bei 160 (0,16 %), Übergabe an Logistik bei 1.783
--   (1,79 %), Zustellung bei 2.965 (2,98 %). Fehlende Zustellung ist fast
--   immer ein nicht zugestellter Status, nicht ein Datenfehler.
SELECT COUNT(*) AS n_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL) / COUNT(*), 2)      AS pct_missing_purchase,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_approved_at IS NULL) / COUNT(*), 2)             AS pct_missing_approved,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) / COUNT(*), 2)  AS pct_missing_carrier,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) / COUNT(*), 2) AS pct_missing_delivered,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) / COUNT(*), 2) AS pct_missing_estimate
FROM orders;


-- A6. Geolocation: mehrere Zeilen je PLZ-Präfix und Koordinaten außerhalb Brasiliens
-- Frage: Wie stark würde ein direkter Join auf die Geolocation die Kunden vervielfachen?
-- Ergebnis: Im Schnitt 52,6 Zeilen je Präfix. Ein direkter Join customers x
--   geolocation ergibt 15.083.455 Zeilen statt 99.441. 42 Koordinaten liegen
--   außerhalb Brasiliens und werden vor der Verdichtung entfernt.
--   157 Kunden-Präfixe (278 Kunden) und 7 Verkäufer-Präfixe haben keine
--   Koordinaten; diese bleiben ohne lat/lng.
SELECT COUNT(*) AS n_geo_rows,
       COUNT(DISTINCT geolocation_zip_code_prefix) AS n_prefixes,
       ROUND(COUNT(*) * 1.0 / COUNT(DISTINCT geolocation_zip_code_prefix), 1) AS rows_per_prefix,
       COUNT(*) FILTER (WHERE NOT (geolocation_lat BETWEEN -34 AND 6
                                   AND geolocation_lng BETWEEN -74 AND -34)) AS n_outside_brazil
FROM geolocation;

SELECT COUNT(*) AS n_rows_naive_customer_geo_join
FROM customers c
JOIN geolocation g ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix;

SELECT 'customers_without_geo_prefix' AS check_name, COUNT(*) AS n_rows
FROM customers c
LEFT JOIN (SELECT DISTINCT geolocation_zip_code_prefix FROM geolocation) g
       ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL
UNION ALL
SELECT 'sellers_without_geo_prefix', COUNT(*)
FROM sellers s
LEFT JOIN (SELECT DISTINCT geolocation_zip_code_prefix FROM geolocation) g
       ON s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL;


-- A7. Kategorien ohne englische Übersetzung
-- Frage: Lässt sich jede Kategorie übersetzen?
-- Ergebnis: 610 Produkte ohne Kategorie. Zwei Kategorien ('pc_gamer' und
--   'portateis_cozinha_e_preparadores_de_alimentos') fehlen in der
--   Übersetzungstabelle und werden im Schema von Hand übersetzt.
SELECT COUNT(*) FILTER (WHERE p.product_category_name IS NULL) AS n_products_without_category,
       COUNT(*) FILTER (WHERE p.product_category_name IS NOT NULL
                          AND t.product_category_name IS NULL) AS n_products_without_translation,
       COUNT(DISTINCT p.product_category_name) FILTER (WHERE t.product_category_name IS NULL) AS n_categories_without_translation
FROM products p
LEFT JOIN category_translation t USING (product_category_name);

SELECT DISTINCT p.product_category_name AS untranslated_category
FROM products p
LEFT JOIN category_translation t USING (product_category_name)
WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL;


-- ============================================================================
-- TEIL B: Star-Schema, Bestellstatus, Zahlungsabstimmung, Fan-out, Zeitfenster
-- (braucht 01_schema.sql)
-- ============================================================================

-- B1. Verteilung von order_status, Anteil delivered
-- Frage: Wie viele Bestellungen wurden tatsächlich zugestellt?
-- Ergebnis: 96.478 von 99.441 (97,02 %) sind 'delivered'. 'canceled' (625) und
--   'unavailable' (609) zusammen 1,24 %. Der Rest (shipped, invoiced,
--   processing, created, approved) sind offene Bestellungen zum Datenstand.
SELECT order_status,
       COUNT(*) AS n_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_orders,
       ROUND(AVG(review_score), 2) AS avg_review_score
FROM fact_orders
GROUP BY order_status
ORDER BY n_orders DESC;


-- B2. Status gegen Zustelldatum
-- Frage: Passt der Status zum Zustelldatum?
-- Ergebnis: 8 Bestellungen sind 'delivered' ohne Zustelldatum, 6 haben ein
--   Zustelldatum ohne Status 'delivered'. Deshalb gilt für alle Lieferzeit-
--   und Bewertungsanalysen die doppelte Bedingung: Status 'delivered' UND
--   Zustelldatum gefüllt. Basis: 96.470 Bestellungen.
SELECT COUNT(*) FILTER (WHERE order_status = 'delivered' AND days_total IS NULL)      AS n_delivered_without_date,
       COUNT(*) FILTER (WHERE order_status <> 'delivered' AND days_total IS NOT NULL) AS n_date_without_delivered,
       COUNT(*) FILTER (WHERE order_status = 'delivered' AND days_total IS NOT NULL)  AS n_delivery_analysis_base
FROM fact_orders;


-- B3. Zahlungsabstimmung: paid_total gegen item_revenue + freight_total
-- Frage: Bei wie vielen Bestellungen weicht der Zahlbetrag um mehr als 1 % vom
--   Warenwert plus Fracht ab?
-- Ergebnis: 254 von 98.665 Bestellungen (0,26 %) mit beiden Beträgen weichen
--   um mehr als 1 % ab, davon 236 nach oben und 18 nach unten. Über alle
--   Bestellungen liegt der Zahlbetrag um 2.870,39 BRL über Warenwert plus
--   Fracht. 243 der 254 Abweichungen sind Kreditkartenbestellungen (vermutlich
--   Ratenzuschläge). Gutscheine erklären die Abweichung NICHT: von 3.766
--   Bestellungen mit Gutscheinanteil weichen nur 6 ab, weil Gutscheine als
--   eigene Zahlungszeile mitgezählt werden. Fazit: Umsatz = price,
--   Zahlbetrag nur für Zahlungsanalysen.
SELECT COUNT(*) AS n_orders_with_both_amounts,
       COUNT(*) FILTER (WHERE ABS(paid_total - (item_revenue + freight_total))
                              / (item_revenue + freight_total) > 0.01)   AS n_deviation_over_1pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE ABS(paid_total - (item_revenue + freight_total))
                                            / (item_revenue + freight_total) > 0.01) / COUNT(*), 2) AS pct_deviation_over_1pct,
       COUNT(*) FILTER (WHERE paid_total > (item_revenue + freight_total) * 1.01) AS n_paid_more,
       COUNT(*) FILTER (WHERE paid_total < (item_revenue + freight_total) * 0.99) AS n_paid_less,
       ROUND(SUM(paid_total) - SUM(item_revenue + freight_total), 2)              AS total_difference_brl
FROM fact_orders
WHERE item_revenue IS NOT NULL
  AND paid_total IS NOT NULL;

-- Abweichungen nach Hauptzahlart
SELECT payment_type_main,
       COUNT(*) AS n_orders,
       COUNT(*) FILTER (WHERE ABS(paid_total - (item_revenue + freight_total))
                              / (item_revenue + freight_total) > 0.01) AS n_deviation_over_1pct
FROM fact_orders
WHERE item_revenue IS NOT NULL
  AND paid_total IS NOT NULL
GROUP BY payment_type_main
ORDER BY n_orders DESC;

-- Abweichungen bei Bestellungen mit Gutscheinanteil
SELECT COUNT(*) FILTER (WHERE has_voucher)                 AS n_orders_with_voucher,
       COUNT(*) FILTER (WHERE has_voucher AND deviates)    AS n_voucher_orders_deviating,
       COUNT(*) FILTER (WHERE NOT has_voucher AND deviates) AS n_other_orders_deviating
FROM (
    SELECT f.order_id,
           ABS(f.paid_total - (f.item_revenue + f.freight_total))
               / (f.item_revenue + f.freight_total) > 0.01 AS deviates,
           EXISTS (SELECT 1 FROM order_payments p
                   WHERE p.order_id = f.order_id AND p.payment_type = 'voucher') AS has_voucher
    FROM fact_orders f
    WHERE f.item_revenue IS NOT NULL AND f.paid_total IS NOT NULL
);


-- B4. Nachweis des Fan-out-Problems
-- Frage: Was passiert beim naiven Dreifach-Join orders x order_items x order_payments?
-- Ergebnis: Der naive Join liefert 117.601 Zeilen statt 99.441 Bestellungen.
--   Die Summe über payment_value wird 20.308.134,71 BRL statt 16.008.872,12
--   (+26,9 %), die Summe über price 14.209.115,34 statt 13.591.643,70 (+4,5 %).
--   Die vorverdichtete fact_orders trifft beide Summen auf den Cent.
SELECT 'naiver Dreifach-Join' AS method,
       COUNT(*)                              AS n_rows,
       ROUND(SUM(p.payment_value), 2)        AS sum_payment_value,
       ROUND(SUM(i.price), 2)                AS sum_price
FROM orders o
JOIN order_items i USING (order_id)
JOIN order_payments p USING (order_id)
UNION ALL
SELECT 'fact_orders (vorverdichtet)',
       COUNT(*),
       ROUND(SUM(paid_total), 2),
       ROUND(SUM(item_revenue), 2)
FROM fact_orders
UNION ALL
SELECT 'Rohtabellen einzeln (Referenz)',
       (SELECT COUNT(*) FROM orders),
       (SELECT ROUND(SUM(payment_value), 2) FROM order_payments),
       (SELECT ROUND(SUM(price), 2) FROM order_items);


-- B5. Ränder des Zeitraums
-- Frage: Wie viele Bestellungen liegen außerhalb des Analysefensters
--   Januar 2017 bis August 2018?
-- Ergebnis: 329 Bestellungen vor dem Fenster (Sep 2016 bis Dez 2016, davon 324
--   allein im Oktober 2016) und 20 danach (Sep/Okt 2018). Im Fenster liegen
--   99.092 Bestellungen (99,65 %), im Schnitt 4.955 je Monat. Die Ränder
--   würden in Zeitreihen ein leeres Jahresende 2016 und einen künstlichen
--   Absturz im September 2018 zeigen.
SELECT LEFT(purchase_date_id::VARCHAR, 6) AS year_month,
       COUNT(*) AS n_orders,
       CASE WHEN purchase_date_id BETWEEN 20170101 AND 20180831
            THEN 'im Fenster' ELSE 'Rand' END AS window_flag
FROM fact_orders
GROUP BY year_month, window_flag
ORDER BY year_month;

SELECT COUNT(*) FILTER (WHERE purchase_date_id < 20170101)                       AS n_before_window,
       COUNT(*) FILTER (WHERE purchase_date_id BETWEEN 20170101 AND 20180831)    AS n_in_window,
       COUNT(*) FILTER (WHERE purchase_date_id > 20180831)                       AS n_after_window,
       ROUND(100.0 * COUNT(*) FILTER (WHERE purchase_date_id BETWEEN 20170101 AND 20180831) / COUNT(*), 2) AS pct_in_window
FROM fact_orders;


-- B6. Reihenfolge der Zeitstempel
-- Frage: Kommen die Ereignisse immer in der erwarteten Reihenfolge?
-- Ergebnis: Bei 1.359 Bestellungen liegt die Übergabe an die Logistik vor der
--   Zahlungsfreigabe (negative Bearbeitungszeit, Median -0,74 Tage, 450 Fälle
--   unter -1 Tag, Minimum -171 Tage; in fact_orders nach Rundung auf zwei
--   Nachkommastellen 1.334 Fälle), bei 23 die Zustellung vor der Übergabe.
--   Kein Fall von Zustellung vor Kauf. Gesamtlaufzeit und Verzug gegen
--   Versprechen sind davon also nicht betroffen.
-- ENTSCHEIDUNG: Die Werte bleiben in fact_orders unverändert stehen. Für die
--   Lieferzeit-Zerlegung (Bearbeitung plus Transport) und für die
--   Bearbeitungszeit je Verkäufer werden nur Bestellungen mit plausibler
--   Reihenfolge verwendet (beide Teilzeiten >= 0). Negative Dauern sind
--   physikalisch unmöglich und würden Durchschnitte nach unten ziehen.
SELECT COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp)                    AS n_approved_before_purchase,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_approved_at)                AS n_carrier_before_approval,
       COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date)    AS n_delivered_before_carrier,
       COUNT(*) FILTER (WHERE order_delivered_customer_date < order_purchase_timestamp)        AS n_delivered_before_purchase
FROM orders;

-- Verteilung der negativen Bearbeitungszeiten
SELECT COUNT(*)                                            AS n_negative_handling,
       COUNT(*) FILTER (WHERE days_seller_handling < -1)   AS n_below_minus_1_day,
       MEDIAN(days_seller_handling)                        AS median_days,
       MIN(days_seller_handling)                           AS min_days
FROM fact_orders
WHERE days_seller_handling < 0;


-- B7. Basis für die Analysen im Fenster
-- Frage: Wie groß ist die Datenbasis für Lieferzeit- und Bewertungsanalysen?
-- Ergebnis: 96.203 zugestellte Bestellungen mit Zustelldatum im Fenster,
--   davon 95.560 mit Bewertung. 6.531 davon (6,79 %) kamen nach dem
--   versprochenen Datum an. Stornoquote im Fenster (canceled + unavailable):
--   1.182 Bestellungen (1,19 %). 97,34 % des Warenumsatzes im Fenster
--   entfallen auf zugestellte Bestellungen.
SELECT COUNT(*)                                                     AS n_orders_in_window,
       COUNT(*) FILTER (WHERE order_status = 'delivered' AND days_total IS NOT NULL) AS n_delivered_with_date,
       COUNT(*) FILTER (WHERE order_status = 'delivered' AND days_total IS NOT NULL
                          AND review_score IS NOT NULL)             AS n_delivered_with_review,
       COUNT(*) FILTER (WHERE order_status = 'delivered' AND is_late) AS n_late,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status = 'delivered' AND is_late)
             / COUNT(*) FILTER (WHERE order_status = 'delivered' AND days_total IS NOT NULL), 2) AS pct_late,
       COUNT(*) FILTER (WHERE order_status IN ('canceled', 'unavailable')) AS n_canceled_or_unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status IN ('canceled', 'unavailable')) / COUNT(*), 2) AS pct_canceled_or_unavailable,
       ROUND(100.0 * SUM(item_revenue) FILTER (WHERE order_status = 'delivered') / SUM(item_revenue), 2) AS pct_revenue_delivered
FROM fact_orders
WHERE purchase_date_id BETWEEN 20170101 AND 20180831;

-- B8. Bundesstaat der Bestellung gegen Bundesstaat in dim_customer
-- Frage: Wie viele Bestellungen würden über dim_customer (jüngste Adresse)
--   einem anderen Bundesstaat zugeordnet als über ihre eigene Lieferadresse?
-- Ergebnis: 43 von 99.441 Bestellungen (0,043 %). Die Zuordnung über
--   dim_customer ist für Regionalanalysen also praktisch verlustfrei.
SELECT COUNT(*)                                                    AS n_orders,
       COUNT(*) FILTER (WHERE c.customer_state <> dc.state)        AS n_orders_other_state,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.customer_state <> dc.state) / COUNT(*), 3) AS pct_orders_other_state
FROM orders o
JOIN customers c     USING (customer_id)
JOIN dim_customer dc ON dc.customer_unique_id = c.customer_unique_id;
