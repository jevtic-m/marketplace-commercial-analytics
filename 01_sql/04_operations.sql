-- ============================================================================
-- 04_operations.sql: Lieferzeiten, Verzug gegen Versprechen, Bewertungen, Fracht
-- ============================================================================
-- Ausführung: python 02_python/run_sql.py 01_sql/04_operations.sql
-- Voraussetzung: Star-Schema aus 01_schema.sql.
--
-- Gemeinsame Regeln für alle Abfragen in dieser Datei:
--   - Analysefenster: Kaufdatum Januar 2017 bis August 2018
--   - Lieferzeit und Bewertung nur für order_status = 'delivered' mit
--     gefülltem Zustelldatum (days_total IS NOT NULL)
--   - Region = Großregion des Kunden aus dim_customer
--
-- ENTSCHEIDUNG: Leitgröße ist der Verzug gegen das Versprechen
-- (days_vs_estimate = Zustelldatum minus versprochenes Datum, positiv = zu
-- spät), nicht die absolute Lieferzeit. Der Verzug misst, ob die Erwartung
-- des Kunden erfüllt wurde. Eine lange, aber angekündigte Lieferzeit ist für
-- den Kunden etwas anderes als eine kurze, aber gebrochene Zusage.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Abfrage 9: Lieferzeit-Zerlegung je Region
-- ----------------------------------------------------------------------------
-- Frage: Wie viel der Lieferzeit entfällt auf Zahlungsfreigabe, Bearbeitung
--   beim Verkäufer und Transport, und wie unterscheidet sich das je Region?
-- Ergebnis: Im Schnitt 12,6 Tage vom Kauf bis zur Zustellung (94.844
--   Bestellungen mit plausibler Reihenfolge): 0,4 Tage Freigabe, 2,8 Tage
--   Bearbeitung beim Verkäufer, 9,4 Tage Transport. Die Bearbeitung ist in
--   allen Regionen fast gleich (2,7 bis 2,9 Tage), der Unterschied entsteht
--   im Transport: 7,6 Tage im Sudeste, 19,3 Tage im Norte.
-- ENTSCHEIDUNG: Nur Bestellungen mit nicht negativer Bearbeitungs- und
-- Transportzeit (siehe 02_validation.sql, B6). Sonst würden unmögliche
-- negative Dauern die Durchschnitte verfälschen.
WITH delivered AS (
    SELECT f.*, c.region
    FROM fact_orders f
    JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
    WHERE f.order_status = 'delivered'
      AND f.days_total IS NOT NULL
      AND f.purchase_date_id BETWEEN 20170101 AND 20180831
      AND f.days_seller_handling >= 0
      AND f.days_in_transit >= 0
)
SELECT COALESCE(region, 'Gesamt')         AS region,
       COUNT(*)                                  AS n_orders,
       ROUND(AVG(days_to_approval), 2)           AS avg_days_to_approval,
       ROUND(AVG(days_seller_handling), 2)       AS avg_days_seller_handling,
       ROUND(AVG(days_in_transit), 2)            AS avg_days_in_transit,
       ROUND(AVG(days_total), 2)                 AS avg_days_total,
       ROUND(100.0 * AVG(days_in_transit) / AVG(days_total), 1) AS transit_share_pct
FROM delivered
GROUP BY ROLLUP (region)
ORDER BY GROUPING(region), avg_days_total DESC;


-- ----------------------------------------------------------------------------
-- Abfrage 10: Verzug gegen Versprechen, Anteil verspäteter Lieferungen
-- ----------------------------------------------------------------------------
-- Frage: Wie oft wird das Lieferversprechen gebrochen, je Monat und je Region?
-- Ergebnis: 6,79 % aller Zustellungen kommen nach dem versprochenen Datum.
--   Im Schnitt liegt die Zustellung 11,8 Tage VOR dem Versprechen, die
--   Zusagen sind also großzügig gesetzt. Ausreißer-Monate sind November 2017
--   (12,40 %, Black Friday) sowie Februar und März 2018 (14,13 % und 18,96 %).
--   Nach Region liegt der Nordeste mit 12,76 % fast beim Doppelten des
--   Gesamtwerts, der Norte trotz längster Laufzeit nur bei 8,59 %, weil dort
--   großzügiger zugesagt wird (15,5 Tage Puffer). Spitzenreiter-Staaten:
--   AL 21,46 %, MA 17,46 %; unter den großen Staaten fällt RJ mit 12,15 % auf
--   (SP 4,50 %).

-- 10a. je Kaufmonat
SELECT d.year,
       d.month,
       COUNT(*)                                             AS n_orders,
       COUNT(*) FILTER (WHERE f.is_late)                    AS n_late,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_late) / COUNT(*), 2) AS late_rate_pct,
       ROUND(AVG(f.days_vs_estimate), 1)                    AS avg_days_vs_estimate
FROM fact_orders f
JOIN dim_date d ON d.date_id = f.purchase_date_id
WHERE f.order_status = 'delivered'
  AND f.days_total IS NOT NULL
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

-- 10b. je Region des Kunden (Gesamtzeile über ROLLUP)
SELECT COALESCE(c.region, 'Gesamt')                   AS region,
       COUNT(*)                                             AS n_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_late) / COUNT(*), 2) AS late_rate_pct,
       ROUND(AVG(f.days_vs_estimate), 1)                    AS avg_days_vs_estimate,
       ROUND(AVG(f.days_total), 1)                          AS avg_days_total
FROM fact_orders f
JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
WHERE f.order_status = 'delivered'
  AND f.days_total IS NOT NULL
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY ROLLUP (c.region)
ORDER BY GROUPING(c.region), late_rate_pct DESC;

-- 10c. je Bundesstaat des Kunden, sortiert nach Verspätungsquote
SELECT c.region,
       c.state,
       COUNT(*)                                             AS n_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_late) / COUNT(*), 2) AS late_rate_pct,
       ROUND(AVG(f.days_vs_estimate), 1)                    AS avg_days_vs_estimate,
       ROUND(AVG(f.days_total), 1)                          AS avg_days_total
FROM fact_orders f
JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
WHERE f.order_status = 'delivered'
  AND f.days_total IS NOT NULL
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY c.region, c.state
ORDER BY late_rate_pct DESC;


-- ----------------------------------------------------------------------------
-- Abfrage 11: Lieferverzug gegen Bewertung (zentrale Analyse)
-- ----------------------------------------------------------------------------
-- Frage: Wie hängt die Bewertung mit dem Verzug gegen das Versprechen zusammen?
-- Ergebnis: Pünktliche Lieferungen (93,33 % der bewerteten Bestellungen)
--   erhalten im Schnitt 4,29 Sterne, 1 bis 3 Tage Verzug 3,29, 4 bis 7 Tage
--   2,10, über 7 Tage 1,70. Der Anteil der Ein-Stern-Bewertungen steigt von
--   6,6 % bei pünktlicher Lieferung auf 69,8 % bei über 7 Tagen Verzug.
-- Das ist ein Zusammenhang, kein Kausalnachweis. Defekte Ware, falsche
-- Beschreibung oder ein unzuverlässiger Verkäufer können sowohl Verzug als
-- auch schlechte Bewertungen erklären.
WITH reviewed AS (
    SELECT f.review_score,
           f.days_vs_estimate,
           CASE
               WHEN f.days_vs_estimate <= 0 THEN 'a: pünktlich'
               WHEN f.days_vs_estimate <= 3 THEN 'b: 1 bis 3 Tage zu spät'
               WHEN f.days_vs_estimate <= 7 THEN 'c: 4 bis 7 Tage zu spät'
               ELSE                              'd: über 7 Tage zu spät'
           END AS delay_class
    FROM fact_orders f
    WHERE f.order_status = 'delivered'
      AND f.days_total IS NOT NULL
      AND f.review_score IS NOT NULL
      AND f.purchase_date_id BETWEEN 20170101 AND 20180831
)
SELECT delay_class,
       COUNT(*)                                                       AS n_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)             AS order_share_pct,
       ROUND(AVG(review_score), 2)                                    AS avg_review_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 1) / COUNT(*), 1)  AS pct_one_star,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 1) AS pct_one_or_two_stars,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 5) / COUNT(*), 1)  AS pct_five_stars
FROM reviewed
GROUP BY delay_class
ORDER BY delay_class;


-- ----------------------------------------------------------------------------
-- Abfrage 12: Frachtanteil am Warenwert je Kategorie und je Entfernungsklasse
-- ----------------------------------------------------------------------------
-- Frage: Wo frisst die Fracht einen großen Teil des Warenwerts?
-- Ergebnis: Den höchsten Frachtanteil hat electronics mit 29,5 % des
--   Warenwerts (billige Kleinteile, Durchschnittspreis 56,79 BRL), gefolgt von
--   office_furniture mit 25,0 % (schwer, Median 11 kg). Nach Entfernung steigt
--   der Frachtanteil von 13,0 % im gleichen Bundesstaat auf 18,8 % bei
--   Lieferung in eine andere Großregion. 83,7 % aller Positionen kommen von
--   Verkäufern aus dem Sudeste.
-- ENTSCHEIDUNG: Entfernungsklasse über Bundesstaaten statt Kilometer:
-- gleicher Bundesstaat, gleiche Großregion, andere Großregion. Das ist in SQL
-- ohne Geo-Funktionen robust und für das Management lesbar. Die genaue
-- Distanz in Kilometern folgt in der Python-Frachtanalyse.

-- 12a. je Kategorie (Kategorien mit mindestens 500 Positionen)
SELECT p.category_en,
       COUNT(*)                                             AS n_items,
       ROUND(AVG(i.price), 2)                               AS avg_price_brl,
       ROUND(AVG(i.freight_value), 2)                       AS avg_freight_brl,
       ROUND(100.0 * SUM(i.freight_value) / SUM(i.price), 1) AS freight_share_pct,
       ROUND(MEDIAN(p.weight_g), 0)                         AS median_weight_g
FROM fact_order_items i
JOIN fact_orders f  ON f.order_id = i.order_id
JOIN dim_product p  ON p.product_id = i.product_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY p.category_en
HAVING COUNT(*) >= 500
ORDER BY freight_share_pct DESC;

-- 12b. je Entfernungsklasse zwischen Verkäufer- und Kundenstaat
SELECT CASE
           WHEN s.state = c.state   THEN '1: gleicher Bundesstaat'
           WHEN s.region = c.region THEN '2: gleiche Großregion'
           ELSE                          '3: andere Großregion'
       END                                                  AS distance_class,
       COUNT(*)                                             AS n_items,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS item_share_pct,
       ROUND(AVG(i.price), 2)                               AS avg_price_brl,
       ROUND(AVG(i.freight_value), 2)                       AS avg_freight_brl,
       ROUND(100.0 * SUM(i.freight_value) / SUM(i.price), 1) AS freight_share_pct
FROM fact_order_items i
JOIN fact_orders f   ON f.order_id = i.order_id
JOIN dim_seller s    ON s.seller_id = i.seller_id
JOIN dim_customer c  ON c.customer_unique_id = i.customer_unique_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY distance_class
ORDER BY distance_class;

-- 12c. Wo sitzen die Verkäufer? Anteil der Positionen je Verkäufer-Region
SELECT s.region                                             AS seller_region,
       COUNT(DISTINCT s.seller_id)                          AS n_sellers,
       COUNT(*)                                             AS n_items,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS item_share_pct
FROM fact_order_items i
JOIN fact_orders f ON f.order_id = i.order_id
JOIN dim_seller s  ON s.seller_id = i.seller_id
WHERE f.order_status = 'delivered'
  AND f.purchase_date_id BETWEEN 20170101 AND 20180831
GROUP BY s.region
ORDER BY n_items DESC;
