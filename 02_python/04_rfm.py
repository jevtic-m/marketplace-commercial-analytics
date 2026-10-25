"""
04_rfm.py: RFM-Segmente und die Frage, was Wiederkäufer von Einmalkäufern unterscheidet.

Aufruf aus dem Repo-Root:
    python 02_python/04_rfm.py

Ehrliche Einordnung vorweg: Nur rund 2 % der Kunden kaufen an mehr als einem Tag.
Die Frequenz-Dimension von RFM ist deshalb fast leer. Die interessantere Frage
ist, was die wenigen Wiederkäufer bei ihrer ersten Bestellung anders erlebt haben.

Alle Kundenkennzahlen laufen über customer_unique_id (die reale Person).

Ausgaben:
    reports/figures/04_repeat_rate_by_category.png
    03_dashboard/exports/rfm_segments.csv, repeat_rate_by_first_order.csv
"""

import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
from scipy import stats

sys.path.insert(0, str(Path(__file__).parent))
from chart_style import BLUE, TEXT_PRIMARY, TEXT_SECONDARY, apply_style, plt, save_figure  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")
pd.set_option("display.width", 200)

DB_PATH = "data/olist.duckdb"
EXPORT_DIR = Path("03_dashboard/exports")

# Stichtag für die Recency: der Tag nach dem Ende des Analysefensters
REFERENCE_DATE = pd.Timestamp("2018-09-01")

# ENTSCHEIDUNG: Wiederkauf = eine weitere zugestellte Bestellung an einem
# späteren Kalendertag innerhalb von 180 Tagen nach dem Erstkauf. Bestellungen
# am selben Tag sind ein aufgeteilter Warenkorb, kein Wiederkauf (784 der 2.789
# Mehrfachbesteller hatten nur solche). Das feste 180-Tage-Fenster sorgt dafür,
# dass jeder Kunde gleich lange Zeit zum Wiederkaufen hatte. Deshalb zählen
# für den Vergleich nur Erstkäufe bis 4. März 2018 (180 Tage vor Fensterende).
REPEAT_WINDOW_DAYS = 180
LAST_FIRST_PURCHASE_FOR_COMPARISON = pd.Timestamp("2018-03-04")


def load_customer_orders(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    """Alle zugestellten Bestellungen im Fenster mit den Merkmalen, die der Kunde erlebt hat."""
    query = """
        WITH main_category AS (
            -- Kategorie der teuersten Position als Hauptkategorie der Bestellung
            SELECT i.order_id,
                   p.category_en,
                   ROW_NUMBER() OVER (PARTITION BY i.order_id
                                      ORDER BY i.price DESC, i.order_item_id) AS category_rank
            FROM fact_order_items i
            JOIN dim_product p ON p.product_id = i.product_id
        )
        SELECT f.order_id,
               f.customer_unique_id,
               d.date                       AS purchase_date,
               f.item_revenue::DOUBLE       AS item_revenue,
               f.freight_total::DOUBLE      AS freight_total,
               f.payment_type_main,
               f.days_total::DOUBLE         AS days_total,
               f.is_late,
               f.review_score,
               c.region,
               m.category_en
        FROM fact_orders f
        JOIN dim_date d     ON d.date_id = f.purchase_date_id
        JOIN dim_customer c ON c.customer_unique_id = f.customer_unique_id
        LEFT JOIN main_category m ON m.order_id = f.order_id AND m.category_rank = 1
        WHERE f.order_status = 'delivered'
          AND f.purchase_date_id BETWEEN 20170101 AND 20180831
    """
    orders = con.execute(query).df()
    orders["purchase_date"] = pd.to_datetime(orders["purchase_date"])
    return orders


def build_rfm(orders: pd.DataFrame) -> pd.DataFrame:
    """Eine Zeile je Kunde mit Recency, Frequency, Monetary und den drei Scores."""
    customers = orders.groupby("customer_unique_id").agg(
        last_purchase=("purchase_date", "max"),
        frequency=("purchase_date", "nunique"),   # Kauftage, nicht Bestellungen
        monetary=("item_revenue", "sum"),
    ).reset_index()
    customers["recency_days"] = (REFERENCE_DATE - customers["last_purchase"]).dt.days

    # R und M als Quintile (5 = am besten). rank(method="first") verhindert,
    # dass gleiche Werte die Quintilsgrenzen sprengen.
    customers["r_score"] = pd.qcut(customers["recency_days"].rank(method="first"),
                                   5, labels=[5, 4, 3, 2, 1]).astype(int)
    customers["m_score"] = pd.qcut(customers["monetary"].rank(method="first"),
                                   5, labels=[1, 2, 3, 4, 5]).astype(int)

    # ENTSCHEIDUNG: F nicht als Quintil, sondern feste Klassen (1 Kauftag = 1,
    # 2 Kauftage = 2, 3 und mehr = 3). Über 97 % der Kunden haben genau einen
    # Kauftag; Quintile wären nicht definiert.
    customers["f_score"] = np.select(
        [customers["frequency"] >= 3, customers["frequency"] == 2], [3, 2], default=1
    )

    conditions = [
        (customers["f_score"] >= 2) & (customers["r_score"] >= 4),
        (customers["f_score"] >= 2),
        (customers["r_score"] >= 4) & (customers["m_score"] >= 4),
        (customers["r_score"] >= 4),
        (customers["m_score"] >= 4),
    ]
    segments = [
        "Wiederkäufer, aktiv",
        "Wiederkäufer, länger inaktiv",
        "Einmalkäufer neu, hoher Wert",
        "Einmalkäufer neu",
        "Einmalkäufer älter, hoher Wert",
    ]
    customers["segment"] = np.select(conditions, segments, default="Einmalkäufer älter")
    return customers


def summarize_segments(customers: pd.DataFrame) -> pd.DataFrame:
    summary = customers.groupby("segment").agg(
        n_customers=("customer_unique_id", "size"),
        revenue_brl=("monetary", "sum"),
        avg_revenue_per_customer=("monetary", "mean"),
        avg_recency_days=("recency_days", "mean"),
    ).reset_index()
    summary["customer_share_pct"] = 100 * summary["n_customers"] / summary["n_customers"].sum()
    summary["revenue_share_pct"] = 100 * summary["revenue_brl"] / summary["revenue_brl"].sum()
    return summary.sort_values("revenue_brl", ascending=False).round(2)


def first_orders_with_repeat_flag(orders: pd.DataFrame) -> pd.DataFrame:
    """Erstbestellung je Kunde plus Kennzeichen, ob innerhalb von 180 Tagen wiedergekauft wurde."""
    orders = orders.sort_values(["customer_unique_id", "purchase_date", "order_id"])
    first_purchase_date = orders.groupby("customer_unique_id")["purchase_date"].transform("min")

    # Erstbestellung: die erste Bestellung am ersten Kauftag
    first_orders = orders[orders["purchase_date"] == first_purchase_date] \
        .drop_duplicates("customer_unique_id").copy()

    # Gab es einen späteren Kauftag innerhalb des Wiederkauffensters?
    later = orders[(orders["purchase_date"] > first_purchase_date)
                   & (orders["purchase_date"] <= first_purchase_date + pd.Timedelta(days=REPEAT_WINDOW_DAYS))]
    repeat_customers = set(later["customer_unique_id"])
    first_orders["is_repeat"] = first_orders["customer_unique_id"].isin(repeat_customers)

    # Nur Kunden, die volle 180 Tage beobachtet werden konnten
    return first_orders[first_orders["purchase_date"] <= LAST_FIRST_PURCHASE_FOR_COMPARISON]


def repeat_rate_by(first_orders: pd.DataFrame, column: str, min_customers: int = 500) -> pd.DataFrame:
    table = first_orders.groupby(column, observed=True).agg(
        n_customers=("is_repeat", "size"),
        n_repeat=("is_repeat", "sum"),
    ).reset_index()
    table["repeat_rate_pct"] = 100 * table["n_repeat"] / table["n_customers"]
    table = table[table["n_customers"] >= min_customers]
    table.insert(0, "attribute", column)
    return table.rename(columns={column: "value"}).round(3)


def compare_groups(first_orders: pd.DataFrame) -> pd.DataFrame:
    """Durchschnittliche Merkmale der Erstbestellung: Wiederkäufer gegen Einmalkäufer."""
    first_orders = first_orders.assign(
        freight_share_pct=100 * first_orders["freight_total"] / first_orders["item_revenue"],
        is_late_pct=100 * first_orders["is_late"].astype(float),
    )
    columns = ["item_revenue", "freight_share_pct", "days_total", "is_late_pct", "review_score"]
    comparison = first_orders[columns + ["is_repeat"]].astype(float).groupby("is_repeat").mean().T
    comparison.columns = ["Einmalkäufer", "Wiederkäufer"]
    return comparison.round(2)


def plot_repeat_rate_by_category(by_category: pd.DataFrame, overall_rate: float) -> None:
    """Horizontale Balken: Wiederkaufrate je Kategorie der Erstbestellung."""
    data = by_category.sort_values("repeat_rate_pct")
    fig, ax = plt.subplots(figsize=(8.5, 7))
    y_positions = np.arange(len(data))
    ax.barh(y_positions, data["repeat_rate_pct"], height=0.65, color=BLUE)
    for y, value in zip(y_positions, data["repeat_rate_pct"]):
        ax.text(value + 0.04, y, f"{value:.1f} %".replace(".", ","), va="center",
                color=TEXT_PRIMARY, fontsize=8,
                bbox={"facecolor": "#fcfcfb", "edgecolor": "none", "pad": 0.5})
    ax.set_yticks(y_positions, data["value"])
    ax.axvline(overall_rate, color=TEXT_SECONDARY, linewidth=0.8, linestyle="--", zorder=0)
    ax.text(overall_rate + 0.04, len(data) - 0.4, f"gesamt {overall_rate:.2f} %".replace(".", ","),
            fontsize=9, color=TEXT_PRIMARY, va="bottom")
    ax.set_xlabel("Anteil Kunden mit weiterem Kauf innerhalb von 180 Tagen (%)")
    ax.set_title("Wiederkaufrate nach Kategorie der Erstbestellung")
    ax.set_ylim(-0.6, len(data) + 0.4)
    ax.grid(axis="y", visible=False)
    save_figure(fig, "04_repeat_rate_by_category.png")


def main() -> None:
    apply_style()
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH, read_only=True)
    orders = load_customer_orders(con)
    con.close()

    customers = build_rfm(orders)
    n_customers = len(customers)
    n_multi_day = int((customers["frequency"] >= 2).sum())
    print(f"Kunden mit zugestellter Bestellung im Fenster: {n_customers:,}")
    print(f"davon mit mehr als einem Kauftag: {n_multi_day:,} ({100 * n_multi_day / n_customers:.2f} %)")
    print(f"Verteilung Kauftage je Kunde: {customers['frequency'].value_counts().sort_index().to_dict()}\n")

    segments = summarize_segments(customers)
    print("RFM-Segmente:")
    print(segments.to_string(index=False), "\n")

    first_orders = first_orders_with_repeat_flag(orders)
    overall_rate = 100 * first_orders["is_repeat"].mean()
    print(f"Vergleichsbasis: {len(first_orders):,} Kunden mit Erstkauf bis {LAST_FIRST_PURCHASE_FOR_COMPARISON.date()}")
    print(f"Wiederkaufrate innerhalb {REPEAT_WINDOW_DAYS} Tagen: {first_orders['is_repeat'].sum():,} "
          f"= {overall_rate:.2f} %\n")

    print("Merkmale der Erstbestellung im Vergleich:")
    print(compare_groups(first_orders).to_string(), "\n")

    first_orders["review_score_first"] = first_orders["review_score"]
    tables = [
        repeat_rate_by(first_orders, "review_score_first"),
        repeat_rate_by(first_orders, "is_late"),
        repeat_rate_by(first_orders, "region"),
        repeat_rate_by(first_orders, "payment_type_main"),
        repeat_rate_by(first_orders, "category_en"),
    ]
    for table in tables:
        sort_column = "value" if table["attribute"].iloc[0] in ("review_score_first", "is_late") else "repeat_rate_pct"
        print(table.sort_values(sort_column, ascending=sort_column == "value").to_string(index=False), "\n")

    # Chi-Quadrat-Test je Merkmal: Ist der Unterschied in der Wiederkaufrate
    # größer, als man bei Zufall erwarten würde? p unter 0,05 = auffällig.
    # Getestet werden nur Ausprägungen mit mindestens 500 Kunden.
    for table in tables:
        contingency = np.column_stack([table["n_repeat"], table["n_customers"] - table["n_repeat"]])
        chi2, p_value, _, _ = stats.chi2_contingency(contingency)
        print(f"Chi-Quadrat-Test {table['attribute'].iloc[0]} x Wiederkauf: "
              f"chi2 = {chi2:.1f}, p = {p_value:.4f}")

    plot_repeat_rate_by_category(tables[4], overall_rate)

    segments.to_csv(EXPORT_DIR / "rfm_segments.csv", index=False)
    pd.concat(tables).to_csv(EXPORT_DIR / "repeat_rate_by_first_order.csv", index=False)


if __name__ == "__main__":
    main()
