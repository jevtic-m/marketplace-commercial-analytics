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
