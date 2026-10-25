-- ============================================================================
-- 03_commercial.sql: Umsatz, Kategorien, Regionen, Zahlverhalten
-- ============================================================================
-- Ausführung: python 02_python/run_sql.py 01_sql/03_commercial.sql
-- Voraussetzung: Star-Schema aus 01_schema.sql.
--
-- Gemeinsame Regeln für alle Abfragen in dieser Datei:
--   - Analysefenster: Kaufdatum Januar 2017 bis August 2018
--     (purchase_date_id BETWEEN 20170101 AND 20180831)
--   - Umsatz = Summe price (item_revenue), Fracht getrennt, Währung BRL
--   - Kategorien immer englisch über dim_product.category_en
--
-- ENTSCHEIDUNG: Umsatz ist realisierter Umsatz, also nur Bestellungen mit
-- Status 'delivered'. Offene Bestellungen (shipped, invoiced, processing)
-- können noch storniert werden, stornierte haben keinen Umsatz erzeugt.
-- Zugestellte Bestellungen tragen 97,34 % des Warenumsatzes im Fenster.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Abfrage 5: Umsatz je Monat, mit Wachstum zum Vormonat
-- ----------------------------------------------------------------------------
-- Frage: Wie entwickelt sich der realisierte Umsatz Monat für Monat?
-- Ergebnis: Im Fenster 13.181.027,13 BRL realisierter Umsatz aus 96.211
--   zugestellten Bestellungen. Januar bis August 2018 liegt 141,1 % über
--   Januar bis August 2017. Spitze im November 2017 (987.765 BRL, +52,4 % zum
--   Vormonat, Black Friday), ab März 2018 Plateau bei rund 0,85 bis 0,98 Mio. BRL
--   je Monat. Der durchschnittliche Bestellwert schwankt nur zwischen 124 und 149 BRL.
WITH monthly AS (
    SELECT d.year,
           d.month,
           COUNT(*)                 AS n_orders,
           SUM(f.item_revenue)      AS revenue_brl
    FROM fact_orders f
    JOIN dim_date d ON d.date_id = f.purchase_date_id
    WHERE f.order_status = 'delivered'
      AND f.purchase_date_id BETWEEN 20170101 AND 20180831
    GROUP BY d.year, d.month
)
SELECT year,
       month,
       n_orders,
       ROUND(revenue_brl, 2)                                         AS revenue_brl,
       ROUND(revenue_brl / n_orders, 2)                              AS avg_order_value_brl,
       ROUND(LAG(revenue_brl) OVER (ORDER BY year, month), 2)        AS revenue_prev_month_brl,
       ROUND(100.0 * (revenue_brl - LAG(revenue_brl) OVER (ORDER BY year, month))
             / LAG(revenue_brl) OVER (ORDER BY year, month), 1)      AS growth_vs_prev_month_pct
FROM monthly
ORDER BY year, month;

-- Gesamtsumme und Vergleich der ersten acht Monate 2017 mit 2018
SELECT ROUND(SUM(item_revenue), 2) AS revenue_window_brl,
       COUNT(*)                    AS n_orders_window,
       ROUND(SUM(item_revenue) FILTER (WHERE purchase_date_id BETWEEN 20170101 AND 20170831), 2) AS revenue_jan_aug_2017,
       ROUND(SUM(item_revenue) FILTER (WHERE purchase_date_id BETWEEN 20180101 AND 20180831), 2) AS revenue_jan_aug_2018,
       ROUND(100.0 * SUM(item_revenue) FILTER (WHERE purchase_date_id BETWEEN 20180101 AND 20180831)
             / SUM(item_revenue) FILTER (WHERE purchase_date_id BETWEEN 20170101 AND 20170831) - 100, 1) AS growth_jan_aug_pct
FROM fact_orders
WHERE order_status = 'delivered'
  AND purchase_date_id BETWEEN 20170101 AND 20180831;


-- ----------------------------------------------------------------------------
-- Abfrage 6: Umsatz und Anteil je Kategorie, kumuliert (Pareto)
-- ----------------------------------------------------------------------------
-- Frage: Wie stark konzentriert sich der Umsatz auf wenige Kategorien?
-- Ergebnis: 74 Kategorien (inklusive 'unknown'). Die Top 7 machen 49,9 % des
--   Umsatzes, 18 Kategorien (24 % aller Kategorien) machen 81,3 %. Spitzenreiter
--   ist health_beauty mit 1.229.558 BRL (9,33 %), vor watches_gifts (8,83 %)
--   und bed_bath_table (7,76 %).
-- Hinweis zur Körnung: fact_order_items (Positionen) wird mit fact_orders
-- (eine Zeile je Bestellung) verbunden. Das ist ein n:1-Join, jede Position
-- findet genau eine Bestellung, deshalb entsteht kein Fan-out.
WITH category_revenue AS (
    SELECT p.category_en,
           COUNT(DISTINCT i.order_id)   AS n_orders,
           SUM(i.price)                 AS revenue_brl
    FROM fact_order_items i
    JOIN fact_orders f  ON f.order_id = i.order_id
    JOIN dim_product p  ON p.product_id = i.product_id
    WHERE f.order_status = 'delivered'
      AND f.purchase_date_id BETWEEN 20170101 AND 20180831
    GROUP BY p.category_en
)
SELECT ROW_NUMBER() OVER (ORDER BY revenue_brl DESC)              AS revenue_rank,
       category_en,
       n_orders,
       ROUND(revenue_brl, 2)                                       AS revenue_brl,
       ROUND(100.0 * revenue_brl / SUM(revenue_brl) OVER (), 2)    AS revenue_share_pct,
       ROUND(100.0 * SUM(revenue_brl) OVER (ORDER BY revenue_brl DESC
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue_brl) OVER (), 2)                        AS cumulative_share_pct
FROM category_revenue
ORDER BY revenue_rank;


-- ----------------------------------------------------------------------------
-- Abfrage 7: Durchschnittlicher Bestellwert je Bundesstaat und Region
-- ----------------------------------------------------------------------------
-- Frage: Wo bestellen Kunden viel, wo wenig, und was kostet sie die Fracht?
-- Ergebnis: Sudeste trägt 68,6 % der Bestellungen, hat aber mit 130,61 BRL den
--   niedrigsten Bestellwert. Norte liegt bei 181,96 BRL und zahlt 22,7 % Fracht
--   auf den Warenwert gegenüber 15,2 % im Sudeste. Höchster Bundesstaat ist PB
--   (218,46 BRL), niedrigster SP (125,15 BRL, Frachtanteil 13,9 %).
-- ENTSCHEIDUNG: Der Bundesstaat kommt aus dim_customer (Adresse der jüngsten
-- Bestellung der Person). Nur 39 Personen haben in mehreren Bundesstaaten
-- bestellt; die Abweichung ist in 02_validation.sql (B8) beziffert.
SELECT c.region,
       c.state,
       COUNT(*)                                          AS n_orders,
       ROUND(SUM(f.item_revenue), 2)                     AS revenue_brl,
       ROUND(AVG(f.item_revenue), 2)                     AS avg_order_value_brl,
       ROUND(AVG(f.freight_total), 2)                    AS avg_freight_brl,
       ROUND(100.0 * SUM(f.freight_total) / SUM(f.item_revenue), 1) AS freight_share_pct
FROM fact_orders f
JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY c.region, c.state
ORDER BY avg_order_value_brl DESC;

-- Verdichtet auf die fünf Großregionen
SELECT c.region,
       COUNT(*)                                          AS n_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS order_share_pct,
       ROUND(SUM(f.item_revenue), 2)                     AS revenue_brl,
       ROUND(AVG(f.item_revenue), 2)                     AS avg_order_value_brl,
       ROUND(AVG(f.freight_total), 2)                    AS avg_freight_brl,
       ROUND(100.0 * SUM(f.freight_total) / SUM(f.item_revenue), 1) AS freight_share_pct
FROM fact_orders f
JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY c.region
ORDER BY avg_order_value_brl DESC;


-- ----------------------------------------------------------------------------
-- Abfrage 8: Zahlungsverhalten
-- ----------------------------------------------------------------------------
-- Frage: Wie zahlen Kunden, und wovon hängt die Zahl der Raten ab?
-- Ergebnis: Kreditkarte ist Hauptzahlart bei 75,44 % der Bestellungen und
--   78,42 % des Zahlbetrags, Boleto bei 19,89 %. Kreditkartenkunden zahlen im
--   Schnitt in 3,55 Raten. Die Ratenzahl steigt mit dem Bestellwert von 2,08
--   (unter 50 BRL) auf 7,29 (ab 500 BRL). Je Kategorie reicht sie von 4,80
--   (office_furniture) bis 2,03 (electronics).

-- 8a. Verteilung der Hauptzahlart je Bestellung (eine Zeile je Bestellung)
SELECT payment_type_main,
       COUNT(*)                                            AS n_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS order_share_pct,
       ROUND(SUM(paid_total), 2)                           AS paid_total_brl,
       ROUND(100.0 * SUM(paid_total) / SUM(SUM(paid_total)) OVER (), 2) AS paid_share_pct,
       ROUND(AVG(max_installments), 2)                     AS avg_installments
FROM fact_orders
WHERE order_status = 'delivered'
  AND purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY payment_type_main
ORDER BY n_orders DESC;

-- 8b. Raten nach Bestellwert-Klasse (nur Kreditkarte, weil nur dort Raten möglich sind)
-- ENTSCHEIDUNG: Ratenanalysen nur für Bestellungen mit Hauptzahlart
-- Kreditkarte. Boleto, Debitkarte und Gutschein kennen keine Raten und würden
-- den Durchschnitt künstlich Richtung 1 ziehen.
SELECT CASE
           WHEN item_revenue < 50   THEN '1: unter 50 BRL'
           WHEN item_revenue < 100  THEN '2: 50 bis 100 BRL'
           WHEN item_revenue < 200  THEN '3: 100 bis 200 BRL'
           WHEN item_revenue < 500  THEN '4: 200 bis 500 BRL'
           ELSE                          '5: ab 500 BRL'
       END                                                 AS order_value_class,
       COUNT(*)                                            AS n_orders,
       ROUND(AVG(max_installments), 2)                     AS avg_installments,
       ROUND(100.0 * COUNT(*) FILTER (WHERE max_installments >= 6) / COUNT(*), 1) AS pct_6_or_more_installments
FROM fact_orders
WHERE order_status = 'delivered'
  AND purchase_date_id BETWEEN 20170101 AND 20180831
  AND payment_type_main = 'credit_card'
GROUP BY order_value_class
ORDER BY order_value_class;

-- 8c. Raten je Kategorie (nur Kreditkarte, Kategorien mit mindestens 500 Bestellungen)
-- Eine Bestellung zählt in jeder Kategorie, aus der sie mindestens eine
-- Position enthält, aber je Kategorie nur einmal (DISTINCT gegen Fan-out).
WITH order_categories AS (
    SELECT DISTINCT i.order_id, p.category_en
    FROM fact_order_items i
    JOIN dim_product p ON p.product_id = i.product_id
)
SELECT oc.category_en,
       COUNT(*)                               AS n_orders,
       ROUND(AVG(f.item_revenue), 2)          AS avg_order_value_brl,
       ROUND(AVG(f.max_installments), 2)      AS avg_installments
FROM order_categories oc
JOIN fact_orders f ON f.order_id = oc.order_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
  AND f.payment_type_main = 'credit_card'
GROUP BY oc.category_en
HAVING COUNT(*) >= 500
ORDER BY avg_installments DESC;
