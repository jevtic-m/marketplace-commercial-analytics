-- ============================================================================
-- 05_sellers.sql: Verkäufer-Konzentration, Verkäufer-Kennzahlen, Verkäufer-Kohorten
-- ============================================================================
-- Ausführung: python 02_python/run_sql.py 01_sql/05_sellers.sql
-- Voraussetzung: Star-Schema aus 01_schema.sql.
-- Legt zwei Views an, die 03_seller_score.py und 05_cutoff_analysis.py lesen:
--   v_seller_orders  eine Zeile je Verkäufer und Bestellung
--   v_seller_kpis    eine Zeile je Verkäufer mit allen Kennzahlen
--
-- Analysefenster: Kaufdatum Januar 2017 bis August 2018.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- v_seller_orders: Verkäufer x Bestellung
-- ----------------------------------------------------------------------------
-- ENTSCHEIDUNG: Bewertung, Verspätung und Bearbeitungszeit hängen an der
-- ganzen Bestellung, nicht an einer Position. Bei Bestellungen mit mehreren
-- Verkäufern (1,3 % im Fenster) lässt sich nicht sagen, welcher Verkäufer die
-- Bewertung oder den Verzug verursacht hat. Diese Bestellungen zählen deshalb
-- für Umsatz und Storno bei jedem beteiligten Verkäufer, aber NICHT für
-- Bewertung, Verspätung und Bearbeitungszeit (is_quality_order = false).
--
-- ENTSCHEIDUNG: Negative Bearbeitungszeiten (Übergabe an Logistik vor
-- Zahlungsfreigabe, siehe 02_validation.sql B6) werden hier auf NULL gesetzt,
-- damit sie den Durchschnitt des Verkäufers nicht verfälschen.
CREATE OR REPLACE VIEW v_seller_orders AS
WITH seller_order_revenue AS (
    SELECT seller_id,
           order_id,
           COUNT(*)        AS n_items,
           SUM(price)      AS seller_revenue
    FROM fact_order_items
    GROUP BY seller_id, order_id
),
sellers_per_order AS (
    SELECT order_id, COUNT(DISTINCT seller_id) AS n_sellers_in_order
    FROM fact_order_items
    GROUP BY order_id
)
SELECT r.seller_id,
       r.order_id,
       f.purchase_date_id,
       f.order_status,
       s.n_sellers_in_order,
       r.n_items,
       r.seller_revenue,
       f.order_status IN ('canceled', 'unavailable')                 AS is_canceled,
       (f.order_status = 'delivered'
        AND f.days_total IS NOT NULL
        AND s.n_sellers_in_order = 1)                                AS is_quality_order,
       f.is_late,
       CASE WHEN f.days_seller_handling >= 0 THEN f.days_seller_handling END AS days_seller_handling,
       f.review_score
FROM seller_order_revenue r
JOIN sellers_per_order s ON s.order_id = r.order_id
JOIN fact_orders f       ON f.order_id = r.order_id
WHERE f.purchase_date_id BETWEEN 20170101 AND 20180831;


-- ----------------------------------------------------------------------------
-- Abfrage 13: Verkäufer-Ranking nach Umsatz mit kumuliertem Anteil
-- ----------------------------------------------------------------------------
-- Frage: Wie konzentriert ist der Marktplatz auf wenige Verkäufer?
-- Ergebnis: ERGEBNIS_13
WITH seller_revenue AS (
    SELECT seller_id,
           SUM(seller_revenue) AS revenue_brl
    FROM v_seller_orders
    WHERE order_status = 'delivered'
    GROUP BY seller_id
),
ranked AS (
    SELECT seller_id,
           revenue_brl,
           ROW_NUMBER() OVER (ORDER BY revenue_brl DESC, seller_id)             AS revenue_rank,
           COUNT(*) OVER ()                                                    AS n_sellers,
           100.0 * revenue_brl / SUM(revenue_brl) OVER ()                      AS revenue_share_pct,
           100.0 * SUM(revenue_brl) OVER (ORDER BY revenue_brl DESC, seller_id
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                 / SUM(revenue_brl) OVER ()                                    AS cumulative_share_pct
    FROM seller_revenue
)
SELECT revenue_rank,
       seller_id,
       ROUND(revenue_brl, 2)            AS revenue_brl,
       ROUND(revenue_share_pct, 3)      AS revenue_share_pct,
       ROUND(cumulative_share_pct, 2)   AS cumulative_share_pct,
       ROUND(100.0 * revenue_rank / n_sellers, 2) AS seller_percentile
FROM ranked
WHERE revenue_rank <= 20
ORDER BY revenue_rank;

-- Konzentration auf einen Blick: Umsatzanteil der Top 1 %, 5 %, 10 %, 20 %
WITH seller_revenue AS (
    SELECT seller_id, SUM(seller_revenue) AS revenue_brl
    FROM v_seller_orders
    WHERE order_status = 'delivered'
    GROUP BY seller_id
),
ranked AS (
    SELECT revenue_brl,
           PERCENT_RANK() OVER (ORDER BY revenue_brl DESC) AS rank_pct
    FROM seller_revenue
)
SELECT COUNT(*)                                                               AS n_sellers_with_revenue,
       ROUND(100.0 * SUM(revenue_brl) FILTER (WHERE rank_pct < 0.01) / SUM(revenue_brl), 1) AS top_1pct_share,
       ROUND(100.0 * SUM(revenue_brl) FILTER (WHERE rank_pct < 0.05) / SUM(revenue_brl), 1) AS top_5pct_share,
       ROUND(100.0 * SUM(revenue_brl) FILTER (WHERE rank_pct < 0.10) / SUM(revenue_brl), 1) AS top_10pct_share,
       ROUND(100.0 * SUM(revenue_brl) FILTER (WHERE rank_pct < 0.20) / SUM(revenue_brl), 1) AS top_20pct_share,
       ROUND(100.0 * SUM(revenue_brl) FILTER (WHERE rank_pct >= 0.50) / SUM(revenue_brl), 1) AS bottom_50pct_share
FROM ranked;


-- ----------------------------------------------------------------------------
-- Abfrage 14: Verkäufer-Kennzahlen kombiniert (Grundlage der Scorecard)
-- ----------------------------------------------------------------------------
-- Frage: Wie schneidet jeder Verkäufer bei Umsatz, Bestellungen, Bearbeitung,
--   Pünktlichkeit, Storno und Bewertung ab?
-- Ergebnis: ERGEBNIS_14
-- Jede Kennzahl wird in einem eigenen CTE auf Verkäuferebene verdichtet und
-- erst dann zusammengeführt. So kann keine Kennzahl eine andere vervielfachen.
CREATE OR REPLACE VIEW v_seller_kpis AS
WITH volume AS (
    SELECT seller_id,
           COUNT(*)                                             AS n_orders,
           COUNT(*) FILTER (WHERE order_status = 'delivered')   AS n_delivered_orders,
           SUM(seller_revenue) FILTER (WHERE order_status = 'delivered') AS revenue_brl
    FROM v_seller_orders
    GROUP BY seller_id
),
cancellations AS (
    SELECT seller_id,
           COUNT(*) FILTER (WHERE is_canceled)                  AS n_canceled,
           AVG(is_canceled::INTEGER)                            AS cancel_rate
    FROM v_seller_orders
    GROUP BY seller_id
),
delivery_quality AS (
    SELECT seller_id,
           COUNT(*)                                             AS n_quality_orders,
           AVG(is_late::INTEGER)                                AS late_rate,
           AVG(days_seller_handling)                            AS avg_handling_days
    FROM v_seller_orders
    WHERE is_quality_order
    GROUP BY seller_id
),
reviews AS (
    SELECT seller_id,
           COUNT(review_score)                                  AS n_reviews,
           AVG(review_score)                                    AS avg_review,
           COUNT(*) FILTER (WHERE review_score = 1)             AS n_one_star
    FROM v_seller_orders
    WHERE is_quality_order
    GROUP BY seller_id
)
SELECT d.seller_id,
       d.state,
       d.region,
       d.first_sale_date,
       v.n_orders,
       v.n_delivered_orders,
       COALESCE(v.revenue_brl, 0)                AS revenue_brl,
       c.n_canceled,
       c.cancel_rate,
       COALESCE(q.n_quality_orders, 0)           AS n_quality_orders,
       q.late_rate,
       q.avg_handling_days,
       COALESCE(r.n_reviews, 0)                  AS n_reviews,
       r.avg_review,
       COALESCE(r.n_one_star, 0)                 AS n_one_star
FROM volume v
JOIN dim_seller d          ON d.seller_id = v.seller_id
JOIN cancellations c       ON c.seller_id = v.seller_id
LEFT JOIN delivery_quality q ON q.seller_id = v.seller_id
LEFT JOIN reviews r          ON r.seller_id = v.seller_id;

-- Überblick: Verteilung der Kennzahlen über alle Verkäufer
SELECT COUNT(*)                                                  AS n_sellers,
       COUNT(*) FILTER (WHERE n_delivered_orders < 10)           AS n_sellers_under_10_orders,
       ROUND(MEDIAN(n_delivered_orders), 0)                      AS median_delivered_orders,
       ROUND(MEDIAN(avg_review), 2)                              AS median_avg_review,
       ROUND(100 * MEDIAN(late_rate), 2)                         AS median_late_rate_pct,
       ROUND(MEDIAN(avg_handling_days), 2)                       AS median_handling_days,
       ROUND(100 * MEDIAN(cancel_rate), 2)                       AS median_cancel_rate_pct,
       COUNT(*) FILTER (WHERE cancel_rate > 0)                   AS n_sellers_with_cancellations
FROM v_seller_kpis;

-- Die 15 umsatzstärksten Verkäufer mit allen Kennzahlen
SELECT seller_id,
       state,
       n_delivered_orders,
       ROUND(revenue_brl, 2)              AS revenue_brl,
       ROUND(avg_handling_days, 2)        AS avg_handling_days,
       ROUND(100 * late_rate, 1)          AS late_rate_pct,
       ROUND(100 * cancel_rate, 2)        AS cancel_rate_pct,
       ROUND(avg_review, 2)               AS avg_review
FROM v_seller_kpis
ORDER BY revenue_brl DESC, seller_id
LIMIT 15;


-- ----------------------------------------------------------------------------
-- Abfrage 15: Verkäufer-Kohorten
-- ----------------------------------------------------------------------------
-- Frage: Wie viele Verkäufer eines Startmonats sind 1, 3, 6 und 12 Monate
--   später noch aktiv?
-- Ergebnis: ERGEBNIS_15
-- ENTSCHEIDUNG: Ersatz für die Kunden-Retention, die bei rund 2 %
-- Wiederkäufern fast leer wäre. Kohorte = Monat der ersten Bestellung des
-- Verkäufers (dim_seller.first_sale_date). Aktiv in einem Monat = mindestens
-- eine Bestellung mit Kaufdatum in diesem Monat, egal welcher Status.
-- Kohorten ab Januar 2017; ein Monatsabstand zählt nur, wenn er vor Ende
-- August 2018 beobachtbar ist, sonst NULL.
WITH seller_months AS (
    SELECT DISTINCT
           i.seller_id,
           DATE_TRUNC('month', d.date) AS active_month
    FROM fact_order_items i
    JOIN dim_date d ON d.date_id = i.purchase_date_id
    WHERE i.purchase_date_id BETWEEN 20170101 AND 20180831
),
cohorts AS (
    SELECT seller_id,
           DATE_TRUNC('month', first_sale_date) AS cohort_month
    FROM dim_seller
    WHERE first_sale_date BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
),
activity AS (
    SELECT c.cohort_month,
           c.seller_id,
           DATE_DIFF('month', c.cohort_month, m.active_month) AS months_since_start
    FROM cohorts c
    JOIN seller_months m USING (seller_id)
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS n_sellers
    FROM cohorts
    GROUP BY cohort_month
)
SELECT strftime(s.cohort_month, '%Y-%m')                                 AS cohort,
       s.n_sellers,
       CASE WHEN s.cohort_month + INTERVAL 1 MONTH <= DATE '2018-08-01' THEN
           ROUND(100.0 * COUNT(DISTINCT a.seller_id) FILTER (WHERE a.months_since_start = 1) / s.n_sellers, 1)
       END AS active_month_1_pct,
       CASE WHEN s.cohort_month + INTERVAL 3 MONTH <= DATE '2018-08-01' THEN
           ROUND(100.0 * COUNT(DISTINCT a.seller_id) FILTER (WHERE a.months_since_start = 3) / s.n_sellers, 1)
       END AS active_month_3_pct,
       CASE WHEN s.cohort_month + INTERVAL 6 MONTH <= DATE '2018-08-01' THEN
           ROUND(100.0 * COUNT(DISTINCT a.seller_id) FILTER (WHERE a.months_since_start = 6) / s.n_sellers, 1)
       END AS active_month_6_pct,
       CASE WHEN s.cohort_month + INTERVAL 12 MONTH <= DATE '2018-08-01' THEN
           ROUND(100.0 * COUNT(DISTINCT a.seller_id) FILTER (WHERE a.months_since_start = 12) / s.n_sellers, 1)
       END AS active_month_12_pct
FROM cohort_size s
LEFT JOIN activity a USING (cohort_month)
GROUP BY s.cohort_month, s.n_sellers
ORDER BY s.cohort_month;

-- Gewichteter Durchschnitt über alle beobachtbaren Kohorten
WITH seller_months AS (
    SELECT DISTINCT i.seller_id, DATE_TRUNC('month', d.date) AS active_month
    FROM fact_order_items i
    JOIN dim_date d ON d.date_id = i.purchase_date_id
    WHERE i.purchase_date_id BETWEEN 20170101 AND 20180831
),
cohorts AS (
    SELECT seller_id, DATE_TRUNC('month', first_sale_date) AS cohort_month
    FROM dim_seller
    WHERE first_sale_date BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
),
offsets AS (
    SELECT * FROM (VALUES (1), (3), (6), (12)) AS t(months_since_start)
)
SELECT o.months_since_start,
       COUNT(DISTINCT c.seller_id)                                           AS n_sellers_observable,
       ROUND(100.0 * COUNT(DISTINCT m.seller_id) / COUNT(DISTINCT c.seller_id), 1) AS active_pct
FROM offsets o
JOIN cohorts c
  ON c.cohort_month + TO_MONTHS(o.months_since_start) <= DATE '2018-08-01'
LEFT JOIN seller_months m
  ON m.seller_id = c.seller_id
 AND m.active_month = c.cohort_month + TO_MONTHS(o.months_since_start)
GROUP BY o.months_since_start
ORDER BY o.months_since_start;
