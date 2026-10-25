-- ============================================================================
-- 01_schema.sql: Star-Schema aus den neun Rohtabellen
-- ============================================================================
-- Ausführung: python 02_python/run_sql.py 01_sql/01_schema.sql
--   (oder gesammelt: python 02_python/01_data_prep.py)
--
-- Ergebnis: vier Dimensionen (dim_date, dim_customer, dim_seller, dim_product)
-- und zwei Faktentabellen (fact_order_items auf Positionsebene, fact_orders auf
-- Bestellebene). Dazu eine Hilfstabelle stg_geo_prefix (eine Zeile je PLZ-Präfix).
--
-- Reihenfolge beim Löschen: erst Fakten, dann Dimensionen, weil die Fakten
-- Fremdschlüssel auf die Dimensionen haben.
-- ============================================================================

DROP TABLE IF EXISTS fact_orders;
DROP TABLE IF EXISTS fact_order_items;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS stg_geo_prefix;


-- ----------------------------------------------------------------------------
-- Hilfsfunktion: Bundesstaat -> Großregion (die fünf offiziellen Regionen Brasiliens)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE MACRO region_of(state_code) AS
    CASE
        WHEN state_code IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO')           THEN 'Norte'
        WHEN state_code IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'Nordeste'
        WHEN state_code IN ('DF', 'GO', 'MT', 'MS')                             THEN 'Centro-Oeste'
        WHEN state_code IN ('ES', 'MG', 'RJ', 'SP')                             THEN 'Sudeste'
        WHEN state_code IN ('PR', 'RS', 'SC')                                   THEN 'Sul'
        ELSE 'unknown'
    END;


-- ----------------------------------------------------------------------------
-- stg_geo_prefix: Geolocation auf eine Zeile je PLZ-Präfix verdichten
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Die Geolocation-Tabelle hat im Schnitt 52,6 Zeilen je Präfix.
-- Vor dem Join wird sie auf den Median von Breiten- und Längengrad je Präfix
-- verdichtet. Median statt Mittelwert, weil einzelne Ausreißer-Koordinaten den
-- Mittelwert verschieben würden. Zusätzlich werden 42 Koordinaten außerhalb
-- der Bounding Box Brasiliens (Breite -34 bis 6, Länge -74 bis -34) entfernt,
-- weil sie offensichtliche Erfassungsfehler sind.
CREATE TABLE stg_geo_prefix AS
SELECT geolocation_zip_code_prefix              AS zip_prefix,
       MEDIAN(geolocation_lat)::DECIMAL(9,6)    AS lat,
       MEDIAN(geolocation_lng)::DECIMAL(9,6)    AS lng
FROM geolocation
WHERE geolocation_lat BETWEEN -34 AND 6
  AND geolocation_lng BETWEEN -74 AND -34
GROUP BY geolocation_zip_code_prefix;


-- ----------------------------------------------------------------------------
-- dim_date: ein Kalendertag je Zeile, date_id im Format JJJJMMTT
-- ----------------------------------------------------------------------------
CREATE TABLE dim_date (
    date_id     INTEGER PRIMARY KEY,
    date        DATE,
    year        INTEGER,
    quarter     INTEGER,
    month       INTEGER,
    month_name  VARCHAR(12),
    week        INTEGER,
    weekday     VARCHAR(10),
    is_weekend  BOOLEAN
);

INSERT INTO dim_date
SELECT (YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d))::INTEGER AS date_id,
       d::DATE                                              AS date,
       YEAR(d)                                              AS year,
       QUARTER(d)                                           AS quarter,
       MONTH(d)                                             AS month,
       MONTHNAME(d)                                         AS month_name,
       WEEK(d)                                              AS week,
       DAYNAME(d)                                           AS weekday,
       ISODOW(d) IN (6, 7)                                  AS is_weekend
FROM generate_series(DATE '2016-09-01', DATE '2018-12-31', INTERVAL 1 DAY) AS t(d);


-- ----------------------------------------------------------------------------
-- dim_customer: eine Zeile je realer Person (customer_unique_id)
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Kundenkennung ist customer_unique_id, nicht customer_id.
-- customer_id wird je Bestellung neu vergeben; 99.441 customer_id gehören zu
-- 96.096 Personen. Über customer_id wäre jede Wiederkaufanalyse wertlos.
--
-- ENTSCHEIDUNG: 250 Personen haben bei mehreren Bestellungen unterschiedliche
-- PLZ-Präfixe (39 sogar unterschiedliche Bundesstaaten). Die Dimension nimmt
-- die Adresse der jüngsten Bestellung, weil sie den aktuellen Wohnort am besten
-- beschreibt. Für Lieferanalysen auf Bestellebene wird ohnehin die Adresse der
-- jeweiligen Bestellung über fact_orders -> customers verwendet, nicht die Dimension.
CREATE TABLE dim_customer (
    customer_unique_id  VARCHAR(40) PRIMARY KEY,
    city                VARCHAR(60),
    state               VARCHAR(4),
    region              VARCHAR(20),
    zip_prefix          INTEGER,
    lat                 DECIMAL(9,6),
    lng                 DECIMAL(9,6)
);

INSERT INTO dim_customer
WITH ranked_addresses AS (
    SELECT c.customer_unique_id,
           c.customer_city,
           c.customer_state,
           c.customer_zip_code_prefix,
           ROW_NUMBER() OVER (
               PARTITION BY c.customer_unique_id
               ORDER BY o.order_purchase_timestamp DESC, o.order_id
           ) AS address_rank
    FROM customers c
    JOIN orders o USING (customer_id)
)
SELECT r.customer_unique_id,
       r.customer_city                      AS city,
       r.customer_state                     AS state,
       region_of(r.customer_state)          AS region,
       r.customer_zip_code_prefix           AS zip_prefix,
       g.lat,
       g.lng
FROM ranked_addresses r
LEFT JOIN stg_geo_prefix g ON g.zip_prefix = r.customer_zip_code_prefix
WHERE r.address_rank = 1;


-- ----------------------------------------------------------------------------
-- dim_seller: eine Zeile je Verkäufer, mit Datum der ersten Bestellung
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: first_sale_date ist der Kaufzeitpunkt der ersten Bestellung
-- mit einer Position dieses Verkäufers, unabhängig vom Bestellstatus. Für
-- Verkäufer-Kohorten zählt, wann der Verkäufer am Marktplatz aktiv wurde,
-- nicht ob die erste Bestellung zugestellt wurde.
CREATE TABLE dim_seller (
    seller_id        VARCHAR(40) PRIMARY KEY,
    city             VARCHAR(60),
    state            VARCHAR(4),
    region           VARCHAR(20),
    zip_prefix       INTEGER,
    lat              DECIMAL(9,6),
    lng              DECIMAL(9,6),
    first_sale_date  DATE
);

INSERT INTO dim_seller
WITH first_sales AS (
    SELECT i.seller_id,
           MIN(o.order_purchase_timestamp)::DATE AS first_sale_date
    FROM order_items i
    JOIN orders o USING (order_id)
    GROUP BY i.seller_id
)
SELECT s.seller_id,
       s.seller_city                    AS city,
       s.seller_state                   AS state,
       region_of(s.seller_state)        AS region,
       s.seller_zip_code_prefix         AS zip_prefix,
       g.lat,
       g.lng,
       f.first_sale_date
FROM sellers s
LEFT JOIN stg_geo_prefix g ON g.zip_prefix = s.seller_zip_code_prefix
LEFT JOIN first_sales f USING (seller_id);


-- ----------------------------------------------------------------------------
-- dim_product: eine Zeile je Produkt, Kategorie übersetzt, Volumen berechnet
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Zwei Kategorien fehlen in der Übersetzungstabelle und werden
-- von Hand übersetzt (pc_gamer -> pc_gamer, portateis_cozinha_e_preparadores_
-- de_alimentos -> portable_kitchen_appliances). 610 Produkte ohne Kategorie
-- bekommen 'unknown', damit sie in Summen nicht verloren gehen, aber in
-- Kategorie-Rankings sichtbar als Restgruppe erscheinen.
CREATE TABLE dim_product (
    product_id   VARCHAR(40) PRIMARY KEY,
    category_pt  VARCHAR(60),
    category_en  VARCHAR(60),
    weight_g     INTEGER,
    length_cm    INTEGER,
    height_cm    INTEGER,
    width_cm     INTEGER,
    volume_cm3   INTEGER,
    photos_qty   INTEGER
);

INSERT INTO dim_product
SELECT p.product_id,
       COALESCE(p.product_category_name, 'unknown') AS category_pt,
       COALESCE(t.product_category_name_english,
                CASE p.product_category_name
                    WHEN 'pc_gamer' THEN 'pc_gamer'
                    WHEN 'portateis_cozinha_e_preparadores_de_alimentos' THEN 'portable_kitchen_appliances'
                END,
                'unknown')                            AS category_en,
       p.product_weight_g                             AS weight_g,
       p.product_length_cm                            AS length_cm,
       p.product_height_cm                            AS height_cm,
       p.product_width_cm                             AS width_cm,
       p.product_length_cm * p.product_height_cm * p.product_width_cm AS volume_cm3,
       p.product_photos_qty                           AS photos_qty
FROM products p
LEFT JOIN category_translation t USING (product_category_name);


-- ----------------------------------------------------------------------------
-- fact_order_items: Positionsebene (für Produkt- und Verkäuferanalysen)
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Zwei Faktentabellen statt einer. fact_order_items bleibt auf
-- Positionsebene, weil Verkäufer und Produkt nur dort eindeutig sind (1.278
-- Bestellungen haben mehrere Verkäufer). fact_orders (unten) ist auf
-- Bestellebene vorverdichtet, damit Umsatz, Zahlung und Bewertung nie
-- vervielfacht werden. Wer beide braucht, joint über order_id.
CREATE TABLE fact_order_items (
    order_id            VARCHAR(40),
    order_item_id       INTEGER,
    product_id          VARCHAR(40) REFERENCES dim_product(product_id),
    seller_id           VARCHAR(40) REFERENCES dim_seller(seller_id),
    customer_unique_id  VARCHAR(40) REFERENCES dim_customer(customer_unique_id),
    purchase_date_id    INTEGER REFERENCES dim_date(date_id),
    price               DECIMAL(10,2),
    freight_value       DECIMAL(10,2),
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO fact_order_items
SELECT i.order_id,
       i.order_item_id,
       i.product_id,
       i.seller_id,
       c.customer_unique_id,
       (YEAR(o.order_purchase_timestamp) * 10000
        + MONTH(o.order_purchase_timestamp) * 100
        + DAY(o.order_purchase_timestamp))::INTEGER AS purchase_date_id,
       i.price,
       i.freight_value
FROM order_items i
JOIN orders o USING (order_id)
JOIN customers c USING (customer_id);


-- ----------------------------------------------------------------------------
-- fact_orders: Bestellebene, vorverdichtet (löst das Fan-out-Problem)
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Vorverdichtung gegen Fan-out. Positionen, Zahlungen und
-- Bewertungen werden in getrennten CTEs je order_id auf eine Zeile gebracht
-- und erst dann an orders gehängt. Ein direkter Dreifach-Join würde bei
-- 3 Positionen x 2 Zahlungen 6 Zeilen erzeugen und den Umsatz dreifach zählen.
--
-- ENTSCHEIDUNG: LEFT JOIN statt INNER JOIN, damit alle 99.441 Bestellungen
-- erhalten bleiben, auch die 775 ohne Position, die 1 ohne Zahlung und die
-- 768 ohne Bewertung. Sie sind für Stornoquoten und Statusanalysen wichtig.
--
-- ENTSCHEIDUNG: Zahlungsabstimmung. paid_total ist die Summe aller
-- Zahlungszeilen (inkl. Gutscheine). Umsatz ist immer die Summe der price-
-- Werte (item_revenue), Fracht getrennt (freight_total). paid_total wird nur
-- für Zahlungsanalysen verwendet. Die Abweichung wird in 02_validation.sql
-- Teil B ausgewiesen.
--
-- ENTSCHEIDUNG: payment_type_main ist die Zahlart mit dem größten Anteil am
-- Zahlbetrag der Bestellung. Bei 2.246 Bestellungen mit mehreren Zahlarten
-- (typisch: Kreditkarte plus Gutschein) zählt damit die Hauptzahlart.
--
-- ENTSCHEIDUNG: Mehrfachbewertungen. 547 Bestellungen haben mehr als eine
-- Bewertung, bei 202 davon mit unterschiedlicher Punktzahl. Es zählt die
-- jüngste Bewertung (spätestes review_creation_date, bei Gleichstand spätestes
-- review_answer_timestamp), weil sie das letzte Urteil des Kunden abbildet.
--
-- ENTSCHEIDUNG: Verzug gegen Versprechen wird in ganzen Kalendertagen
-- gerechnet (Zustelldatum minus versprochenes Datum). Das Versprechen ist ein
-- Tag, keine Uhrzeit. Eine Zustellung um 18 Uhr am versprochenen Tag ist
-- pünktlich, nicht 0,75 Tage zu spät. is_late = Verzug > 0 Tage.
-- Die übrigen Laufzeiten (days_*) werden als Dezimaltage aus den Zeitstempeln
-- gerechnet, weil dort die Dauer interessiert, nicht ein Stichtag.
CREATE TABLE fact_orders (
    order_id                VARCHAR(40) PRIMARY KEY,
    customer_unique_id      VARCHAR(40),
    purchase_date_id        INTEGER,
    order_status            VARCHAR(20),
    n_items                 INTEGER,
    item_revenue            DECIMAL(10,2),
    freight_total           DECIMAL(10,2),
    paid_total              DECIMAL(10,2),
    max_installments        INTEGER,
    payment_type_main       VARCHAR(20),
    days_to_approval        DECIMAL(6,2),
    days_seller_handling    DECIMAL(6,2),
    days_in_transit         DECIMAL(6,2),
    days_total              DECIMAL(6,2),
    days_vs_estimate        DECIMAL(6,2),
    is_late                 BOOLEAN,
    review_score            INTEGER
);

INSERT INTO fact_orders
WITH items AS (
    -- eine Zeile je Bestellung: Positionen verdichtet
    SELECT order_id,
           COUNT(*)            AS n_items,
           SUM(price)          AS item_revenue,
           SUM(freight_value)  AS freight_total
    FROM order_items
    GROUP BY order_id
),
payments AS (
    -- eine Zeile je Bestellung: Zahlungen verdichtet
    SELECT order_id,
           SUM(payment_value)          AS paid_total,
           MAX(payment_installments)   AS max_installments
    FROM order_payments
    GROUP BY order_id
),
payment_type_ranked AS (
    -- Zahlart mit dem größten Betrag je Bestellung
    SELECT order_id,
           payment_type,
           ROW_NUMBER() OVER (
               PARTITION BY order_id
               ORDER BY SUM(payment_value) DESC, MIN(payment_sequential)
           ) AS type_rank
    FROM order_payments
    GROUP BY order_id, payment_type
),
reviews AS (
    -- jüngste Bewertung je Bestellung
    SELECT order_id,
           review_score,
           ROW_NUMBER() OVER (
               PARTITION BY order_id
               ORDER BY review_creation_date DESC, review_answer_timestamp DESC, review_id
           ) AS review_rank
    FROM order_reviews
)
SELECT o.order_id,
       c.customer_unique_id,
       (YEAR(o.order_purchase_timestamp) * 10000
        + MONTH(o.order_purchase_timestamp) * 100
        + DAY(o.order_purchase_timestamp))::INTEGER                AS purchase_date_id,
       o.order_status,
       COALESCE(i.n_items, 0)                                       AS n_items,
       i.item_revenue,
       i.freight_total,
       p.paid_total,
       p.max_installments,
       pt.payment_type,
       ROUND(EPOCH(o.order_approved_at - o.order_purchase_timestamp) / 86400.0, 2)                    AS days_to_approval,
       ROUND(EPOCH(o.order_delivered_carrier_date - o.order_approved_at) / 86400.0, 2)                AS days_seller_handling,
       ROUND(EPOCH(o.order_delivered_customer_date - o.order_delivered_carrier_date) / 86400.0, 2)    AS days_in_transit,
       ROUND(EPOCH(o.order_delivered_customer_date - o.order_purchase_timestamp) / 86400.0, 2)        AS days_total,
       DATE_DIFF('day', o.order_estimated_delivery_date::DATE, o.order_delivered_customer_date::DATE) AS days_vs_estimate,
       CASE
           WHEN o.order_delivered_customer_date IS NULL THEN NULL
           ELSE o.order_delivered_customer_date::DATE > o.order_estimated_delivery_date::DATE
       END                                                          AS is_late,
       r.review_score
FROM orders o
JOIN customers c USING (customer_id)
LEFT JOIN items i USING (order_id)
LEFT JOIN payments p USING (order_id)
LEFT JOIN payment_type_ranked pt ON pt.order_id = o.order_id AND pt.type_rank = 1
LEFT JOIN reviews r ON r.order_id = o.order_id AND r.review_rank = 1;


-- ----------------------------------------------------------------------------
-- Kontrolle: Zeilenzahlen des Star-Schemas
-- ----------------------------------------------------------------------------
SELECT 'dim_date' AS table_name, COUNT(*) AS n_rows FROM dim_date
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_seller', COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_product', COUNT(*) FROM dim_product
UNION ALL SELECT 'fact_order_items', COUNT(*) FROM fact_order_items
UNION ALL SELECT 'fact_orders', COUNT(*) FROM fact_orders
UNION ALL SELECT 'orders (Rohdaten, Vergleich)', COUNT(*) FROM orders;
