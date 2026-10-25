"""
06_dashboard_exports.py: CSV-Exporte für das Power-BI-Dashboard.

Aufruf aus dem Repo-Root (nach allen anderen Skripten):
    python 02_python/06_dashboard_exports.py

Schreibt nach 03_dashboard/exports/:
    Sternschema (Analysefenster 01/2017 bis 08/2018):
        fact_orders.csv, fact_order_items.csv,
        dim_date.csv, dim_customer.csv, dim_product.csv, dim_seller.csv
    Vorberechnete Hilfstabellen für einzelne Visuals:
        category_pareto.csv, late_rate_region_category.csv,
        delivery_decomposition_region.csv, seller_concentration.csv,
        seller_cohorts.csv
    Die übrigen CSVs (cutoff_tradeoff.csv, delay_class_reviews.csv, ...)
    schreiben die Analyse-Skripte 02 bis 05 selbst.

Alle Beträge in BRL, Dezimaltrennzeichen Punkt.
"""

import sys
from pathlib import Path

import duckdb
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8")

DB_PATH = "data/olist.duckdb"
EXPORT_DIR = Path("03_dashboard/exports")

# ENTSCHEIDUNG: Das Dashboard bekommt nur das Analysefenster und nur die
# Spalten, die ein Visual braucht. So bleiben die Dateien klein, und niemand
# kann im Dashboard versehentlich die abgeschnittenen Randmonate plotten.

# Ausgeschriebene Namen der Bundesstaaten, damit die Power-BI-Karte "PA" nicht
# als Pennsylvania liest.
STATE_NAMES = {
    "AC": "Acre", "AL": "Alagoas", "AP": "Amapá", "AM": "Amazonas", "BA": "Bahia",
    "CE": "Ceará", "DF": "Distrito Federal", "ES": "Espírito Santo", "GO": "Goiás",
    "MA": "Maranhão", "MT": "Mato Grosso", "MS": "Mato Grosso do Sul", "MG": "Minas Gerais",
    "PA": "Pará", "PB": "Paraíba", "PR": "Paraná", "PE": "Pernambuco", "PI": "Piauí",
    "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte", "RS": "Rio Grande do Sul",
    "RO": "Rondônia", "RR": "Roraima", "SC": "Santa Catarina", "SP": "São Paulo",
    "SE": "Sergipe", "TO": "Tocantins",
}

QUERIES = {
    "fact_orders": """
        SELECT f.order_id,
               f.customer_unique_id,
               f.purchase_date_id,
               f.order_status,
               f.n_items,
               f.item_revenue,
               f.freight_total,
               f.paid_total,
               f.max_installments,
               f.payment_type_main,
               f.days_to_approval,
               f.days_seller_handling,
               f.days_in_transit,
               f.days_total,
               f.days_vs_estimate,
               f.is_late,
               f.review_score,
               -- Basis für Lieferzeit- und Bewertungsanalysen
               (f.order_status = 'delivered' AND f.days_total IS NOT NULL) AS is_delivery_base,
               -- Zerlegung der Lieferzeit nur bei plausibler Reihenfolge
               (f.order_status = 'delivered' AND f.days_total IS NOT NULL
                AND f.days_seller_handling >= 0 AND f.days_in_transit >= 0) AS is_decomposition_base,
               f.order_status IN ('canceled', 'unavailable')                AS is_canceled,
               CASE
                   WHEN f.days_vs_estimate IS NULL THEN NULL
                   WHEN f.days_vs_estimate <= 0 THEN 'pünktlich'
                   WHEN f.days_vs_estimate <= 3 THEN '1 bis 3 Tage zu spät'
                   WHEN f.days_vs_estimate <= 7 THEN '4 bis 7 Tage zu spät'
                   ELSE 'über 7 Tage zu spät'
               END AS delay_class,
               CASE
                   WHEN f.days_vs_estimate IS NULL THEN NULL
                   WHEN f.days_vs_estimate <= 0 THEN 1
                   WHEN f.days_vs_estimate <= 3 THEN 2
                   WHEN f.days_vs_estimate <= 7 THEN 3
                   ELSE 4
               END AS delay_class_order
        FROM fact_orders f
        WHERE f.purchase_date_id BETWEEN 20170101 AND 20180831
        ORDER BY f.order_id
    """,
    "fact_order_items": """
        SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id,
               i.customer_unique_id, i.purchase_date_id, i.price, i.freight_value
        FROM fact_order_items i
        WHERE i.purchase_date_id BETWEEN 20170101 AND 20180831
        ORDER BY i.order_id, i.order_item_id
    """,
    "dim_date": """
        SELECT date_id, date, year, quarter, month, month_name, week, weekday, is_weekend,
               strftime(date, '%Y-%m') AS year_month
        FROM dim_date
        WHERE date BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
        ORDER BY date_id
    """,
    "dim_customer": """
        SELECT customer_unique_id, city, state, region
        FROM dim_customer
        WHERE customer_unique_id IN (
            SELECT customer_unique_id FROM fact_orders
            WHERE purchase_date_id BETWEEN 20170101 AND 20180831
        )
        ORDER BY customer_unique_id
    """,
    "dim_product": """
        SELECT product_id, category_en, weight_g, volume_cm3, photos_qty
        FROM dim_product
        WHERE product_id IN (
            SELECT product_id FROM fact_order_items
            WHERE purchase_date_id BETWEEN 20170101 AND 20180831
        )
        ORDER BY product_id
    """,
    "dim_seller": """
        SELECT d.seller_id,
               d.city,
               d.state,
               d.region,
               d.first_sale_date,
               ROUND(s.score, 2)              AS score,
               ROUND(s.review_score, 2)       AS review_component,
               ROUND(s.late_score, 2)         AS late_component,
               ROUND(s.handling_score, 2)     AS handling_component,
               ROUND(s.cancel_score, 2)       AS cancel_component,
               s.n_orders,
               s.n_delivered_orders,
               s.n_quality_orders,
               ROUND(s.revenue_brl, 2)        AS revenue_brl,
               ROUND(s.review_raw, 3)         AS avg_review,
               ROUND(s.late_raw, 4)           AS late_rate,
               ROUND(s.handling_raw, 2)       AS avg_handling_days,
               ROUND(s.cancel_raw, 4)         AS cancel_rate,
               q.quadrant,
               q.is_below_cutoff
        FROM dim_seller d
        JOIN seller_scorecard s USING (seller_id)
        JOIN seller_quadrants q USING (seller_id)
        ORDER BY d.seller_id
    """,
    "category_pareto": """
        WITH category_revenue AS (
            SELECT p.category_en, SUM(i.price) AS revenue_brl, COUNT(DISTINCT i.order_id) AS n_orders
            FROM fact_order_items i
            JOIN fact_orders f ON f.order_id = i.order_id
            JOIN dim_product p ON p.product_id = i.product_id
            WHERE f.order_status = 'delivered'
              AND f.purchase_date_id BETWEEN 20170101 AND 20180831
            GROUP BY p.category_en
        )
        SELECT ROW_NUMBER() OVER (ORDER BY revenue_brl DESC, category_en) AS revenue_rank,
               category_en,
               n_orders,
               ROUND(revenue_brl, 2) AS revenue_brl,
               ROUND(100.0 * revenue_brl / SUM(revenue_brl) OVER (), 3) AS revenue_share_pct,
               ROUND(100.0 * SUM(revenue_brl) OVER (ORDER BY revenue_brl DESC, category_en
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) / SUM(revenue_brl) OVER (), 3)
                     AS cumulative_share_pct
        FROM category_revenue
        ORDER BY revenue_rank
    """,
    "late_rate_region_category": """
        -- Jede Bestellung zählt in jeder Kategorie, aus der sie eine Position enthält, je Kategorie einmal
        WITH order_categories AS (
            SELECT DISTINCT i.order_id, p.category_en
            FROM fact_order_items i
            JOIN dim_product p ON p.product_id = i.product_id
        ),
        top_categories AS (
            SELECT category_en FROM order_categories
            GROUP BY category_en ORDER BY COUNT(*) DESC LIMIT 15
        )
        SELECT c.region,
               oc.category_en,
               COUNT(*)                                                        AS n_orders,
               ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_late) / COUNT(*), 2)  AS late_rate_pct,
               ROUND(AVG(f.review_score), 3)                                   AS avg_review
        FROM order_categories oc
        JOIN fact_orders f  ON f.order_id = oc.order_id
        JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
        WHERE oc.category_en IN (SELECT category_en FROM top_categories)
          AND f.order_status = 'delivered'
          AND f.days_total IS NOT NULL
          AND f.purchase_date_id BETWEEN 20170101 AND 20180831
        GROUP BY c.region, oc.category_en
        ORDER BY c.region, oc.category_en
    """,
    "delivery_decomposition_region": """
        SELECT c.region,
               COUNT(*)                                   AS n_orders,
               ROUND(AVG(f.days_to_approval), 2)          AS avg_days_to_approval,
               ROUND(AVG(f.days_seller_handling), 2)      AS avg_days_seller_handling,
               ROUND(AVG(f.days_in_transit), 2)           AS avg_days_in_transit,
               ROUND(AVG(f.days_total), 2)                AS avg_days_total
        FROM fact_orders f
        JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
        WHERE f.order_status = 'delivered'
          AND f.days_total IS NOT NULL
          AND f.purchase_date_id BETWEEN 20170101 AND 20180831
          AND f.days_seller_handling >= 0
          AND f.days_in_transit >= 0
        GROUP BY c.region
        ORDER BY avg_days_total DESC
    """,
    "seller_concentration": """
        WITH seller_revenue AS (
            SELECT seller_id, SUM(seller_revenue) AS revenue_brl
            FROM v_seller_orders
            WHERE order_status = 'delivered'
            GROUP BY seller_id
        )
        -- Bei gleichem Umsatz entscheidet die seller_id, damit jeder Lauf dieselbe Reihenfolge liefert
        SELECT ROW_NUMBER() OVER (ORDER BY revenue_brl DESC, seller_id)         AS revenue_rank,
               seller_id,
               ROUND(revenue_brl, 2)                                            AS revenue_brl,
               ROUND(100.0 * revenue_brl / SUM(revenue_brl) OVER (), 4)         AS revenue_share_pct,
               ROUND(100.0 * SUM(revenue_brl) OVER (ORDER BY revenue_brl DESC, seller_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) / SUM(revenue_brl) OVER (), 3)
                                                                                AS cumulative_share_pct,
               ROUND(100.0 * ROW_NUMBER() OVER (ORDER BY revenue_brl DESC, seller_id) / COUNT(*) OVER (), 3)
                                                                                AS seller_share_pct
        FROM seller_revenue
        ORDER BY revenue_rank
    """,
    "seller_cohorts": """
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
        cohort_size AS (
            SELECT cohort_month, COUNT(*) AS n_sellers FROM cohorts GROUP BY cohort_month
        ),
        activity AS (
            SELECT c.cohort_month,
                   DATE_DIFF('month', c.cohort_month, m.active_month) AS months_since_start,
                   COUNT(DISTINCT c.seller_id) AS n_active
            FROM cohorts c
            JOIN seller_months m USING (seller_id)
            GROUP BY c.cohort_month, months_since_start
        )
        SELECT strftime(a.cohort_month, '%Y-%m') AS cohort,
               a.months_since_start,
               s.n_sellers,
               a.n_active,
               ROUND(100.0 * a.n_active / s.n_sellers, 1) AS active_pct
        FROM activity a
        JOIN cohort_size s USING (cohort_month)
        ORDER BY cohort, months_since_start
    """,
}


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH, read_only=True)

    for name, query in QUERIES.items():
        frame = con.execute(query).df()
        if name == "dim_customer":
            frame["state_name"] = frame["state"].map(STATE_NAMES)
            frame["state_geo"] = frame["state_name"] + ", Brazil"
        path = EXPORT_DIR / f"{name}.csv"
        frame.to_csv(path, index=False, encoding="utf-8")
        size_mb = path.stat().st_size / 1_000_000
        print(f"{path}: {len(frame):,} Zeilen, {size_mb:.1f} MB")

    con.close()


if __name__ == "__main__":
    main()
