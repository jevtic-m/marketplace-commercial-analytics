-- ============================================================================
-- 00_load.sql: Rohdaten (neun CSV-Dateien) in die DuckDB-Datei laden
-- ============================================================================
-- Ausführung aus dem Repo-Root:  python 02_python/run_sql.py 01_sql/00_load.sql
-- Ergebnis: neun Rohtabellen in data/olist.duckdb, unverändert bis auf
-- Datentypen. Alles Fachliche (Kennzahlen, Star-Schema) passiert in 01_schema.sql.
--
-- Zeilenzahlen nach dem Laden (Stand Rohdaten Kaggle):
--   orders 99.441 | order_items 112.650 | order_payments 103.886
--   order_reviews 99.224 | customers 99.441 | sellers 3.095
--   products 32.951 | geolocation 1.000.163 | category_translation 71
-- ============================================================================

-- ENTSCHEIDUNG: PLZ-Präfixe werden als INTEGER geladen. In den CSVs stehen sie
-- als Text mit führenden Nullen (z. B. "01037"). Als Zahl lassen sie sich
-- zwischen Kunden, Verkäufern und Geolocation sauber joinen. Die führenden
-- Nullen tragen keine Information, weil alle Präfixe fünfstellig gemeint sind.

DROP TABLE IF EXISTS orders;
CREATE TABLE orders AS
SELECT order_id,
       customer_id,
       order_status,
       order_purchase_timestamp,
       order_approved_at,
       order_delivered_carrier_date,
       order_delivered_customer_date,
       order_estimated_delivery_date
FROM read_csv_auto('data/raw/olist_orders_dataset.csv');

DROP TABLE IF EXISTS order_items;
CREATE TABLE order_items AS
SELECT order_id,
       order_item_id::INTEGER          AS order_item_id,
       product_id,
       seller_id,
       shipping_limit_date,
       price::DECIMAL(10,2)            AS price,
       freight_value::DECIMAL(10,2)    AS freight_value
FROM read_csv_auto('data/raw/olist_order_items_dataset.csv');

DROP TABLE IF EXISTS order_payments;
CREATE TABLE order_payments AS
SELECT order_id,
       payment_sequential::INTEGER     AS payment_sequential,
       payment_type,
       payment_installments::INTEGER   AS payment_installments,
       payment_value::DECIMAL(10,2)    AS payment_value
FROM read_csv_auto('data/raw/olist_order_payments_dataset.csv');

DROP TABLE IF EXISTS order_reviews;
CREATE TABLE order_reviews AS
SELECT review_id,
       order_id,
       review_score::INTEGER           AS review_score,
       review_comment_title,
       review_comment_message,
       review_creation_date,
       review_answer_timestamp
FROM read_csv_auto('data/raw/olist_order_reviews_dataset.csv');

DROP TABLE IF EXISTS customers;
CREATE TABLE customers AS
SELECT customer_id,
       customer_unique_id,
       customer_zip_code_prefix::INTEGER AS customer_zip_code_prefix,
       customer_city,
       customer_state
FROM read_csv_auto('data/raw/olist_customers_dataset.csv');

DROP TABLE IF EXISTS sellers;
CREATE TABLE sellers AS
SELECT seller_id,
       seller_zip_code_prefix::INTEGER AS seller_zip_code_prefix,
       seller_city,
       seller_state
FROM read_csv_auto('data/raw/olist_sellers_dataset.csv');

DROP TABLE IF EXISTS products;
CREATE TABLE products AS
SELECT product_id,
       product_category_name,
       product_name_lenght::INTEGER        AS product_name_length,
       product_description_lenght::INTEGER AS product_description_length,
       product_photos_qty::INTEGER         AS product_photos_qty,
       product_weight_g::INTEGER           AS product_weight_g,
       product_length_cm::INTEGER          AS product_length_cm,
       product_height_cm::INTEGER          AS product_height_cm,
       product_width_cm::INTEGER           AS product_width_cm
FROM read_csv_auto('data/raw/olist_products_dataset.csv');

DROP TABLE IF EXISTS geolocation;
CREATE TABLE geolocation AS
SELECT geolocation_zip_code_prefix::INTEGER AS geolocation_zip_code_prefix,
       geolocation_lat,
       geolocation_lng,
       geolocation_city,
       geolocation_state
FROM read_csv_auto('data/raw/olist_geolocation_dataset.csv');

DROP TABLE IF EXISTS category_translation;
CREATE TABLE category_translation AS
SELECT product_category_name,
       product_category_name_english
FROM read_csv_auto('data/raw/product_category_name_translation.csv');

-- Kontrolle: Zeilenzahl je Rohtabelle
SELECT 'orders' AS table_name, COUNT(*) AS n_rows FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews', COUNT(*) FROM order_reviews
UNION ALL SELECT 'customers', COUNT(*) FROM customers
UNION ALL SELECT 'sellers', COUNT(*) FROM sellers
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'geolocation', COUNT(*) FROM geolocation
UNION ALL SELECT 'category_translation', COUNT(*) FROM category_translation;
