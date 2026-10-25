"""
02_delivery_analysis.py: Lieferverzug gegen Kundenzufriedenheit, Frachtkosten und Geografie.

Aufruf aus dem Repo-Root:
    python 02_python/02_delivery_analysis.py

Teil 1 (Kern des Projekts): Hängt die Bewertung am gebrochenen Lieferversprechen
oder an der absoluten Lieferzeit?
    - Durchschnittliche Bewertung je Verzugsklasse mit 95-%-Konfidenzintervall
    - Gegenprobe: Bewertung nach absoluter Lieferzeit, pünktlich gegen verspätet
    - Regression: Bewertung auf "verspätet ja/nein" und Lieferdauer
    - Zwei Robustheitsprüfungen gegen naheliegende Störfaktoren

Teil 2: Frachtkosten
    - Entfernung Verkäufer zu Kunde in Kilometern (Haversine-Formel)
    - Regression Frachtwert auf Gewicht, Volumen und Entfernung
    - Teuerste Routen (Bundesstaat Verkäufer -> Bundesstaat Kunde)

Wichtig: Alles hier sind Zusammenhänge, keine Kausalnachweise.

Ausgaben:
    reports/figures/02_*.png
    03_dashboard/exports/delay_class_reviews.csv, review_by_duration.csv,
    freight_drivers.csv, freight_routes.csv, freight_by_distance.csv
"""

import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
from scipy import stats

sys.path.insert(0, str(Path(__file__).parent))
from chart_style import (  # noqa: E402
    BLUE, BLUE_RAMP_4, BLUE_RAMP_5, ORANGE, TEXT_PRIMARY, TEXT_SECONDARY,
    apply_style, plt, save_figure,
)

sys.stdout.reconfigure(encoding="utf-8")
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 20)

DB_PATH = "data/olist.duckdb"
EXPORT_DIR = Path("03_dashboard/exports")

DELAY_CLASSES = [
    "pünktlich",
    "1 bis 3 Tage zu spät",
    "4 bis 7 Tage zu spät",
    "über 7 Tage zu spät",
]

DURATION_BINS = [0, 7, 14, 21, 30, 1000]
DURATION_LABELS = ["bis 7 Tage", "8 bis 14", "15 bis 21", "22 bis 30", "über 30"]


# ============================================================================
# Teil 1: Lieferverzug gegen Bewertung
# ============================================================================

def load_reviewed_deliveries(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    """Zugestellte, bewertete Bestellungen im Analysefenster, eine Zeile je Bestellung."""
    query = """
        WITH sellers_per_order AS (
            SELECT order_id, COUNT(DISTINCT seller_id) AS n_sellers
            FROM fact_order_items
            GROUP BY order_id
        )
        SELECT f.order_id,
               f.review_score,
               f.days_total::DOUBLE        AS days_total,
               f.days_vs_estimate::DOUBLE  AS days_vs_estimate,
               f.is_late,
               f.n_items,
               s.n_sellers,
               c.region
        FROM fact_orders f
        JOIN dim_customer c      ON c.customer_unique_id = f.customer_unique_id
        JOIN sellers_per_order s ON s.order_id = f.order_id
        WHERE f.order_status = 'delivered'
          AND f.days_total IS NOT NULL
          AND f.review_score IS NOT NULL
          AND f.purchase_date_id BETWEEN 20170101 AND 20180831
    """
    return con.execute(query).df()


def assign_delay_class(days_vs_estimate: pd.Series) -> pd.Series:
    """Verzugsklasse wie in 04_operations.sql, Abfrage 11."""
    # ENTSCHEIDUNG: Klassengrenzen pünktlich (<= 0), 1-3, 4-7, über 7 Tage.
    # Sie folgen der Wahrnehmung des Kunden: ein paar Tage, etwa eine Woche,
    # mehr als eine Woche. Dieselben Grenzen wie in der SQL-Abfrage 11.
    conditions = [
        days_vs_estimate <= 0,
        days_vs_estimate <= 3,
        days_vs_estimate <= 7,
    ]
    labels = np.select(conditions, DELAY_CLASSES[:3], default=DELAY_CLASSES[3])
    return pd.Series(pd.Categorical(labels, categories=DELAY_CLASSES, ordered=True),
                     index=days_vs_estimate.index)


def summarize_by_delay_class(orders: pd.DataFrame) -> pd.DataFrame:
    """Bewertung je Verzugsklasse, mit 95-%-Konfidenzintervall des Mittelwerts."""
    rows = []
    for delay_class, group in orders.groupby("delay_class", observed=True):
        scores = group["review_score"]
        mean = scores.mean()
        # t-Verteilung für das Konfidenzintervall des Mittelwerts
        ci_low, ci_high = stats.t.interval(0.95, len(scores) - 1, loc=mean, scale=stats.sem(scores))
        rows.append({
            "delay_class": delay_class,
            "n_orders": len(scores),
            "order_share_pct": 100 * len(scores) / len(orders),
            "avg_review": mean,
            "ci95_low": ci_low,
            "ci95_high": ci_high,
            "one_star_pct": 100 * (scores == 1).mean(),
            "one_or_two_star_pct": 100 * (scores <= 2).mean(),
            "five_star_pct": 100 * (scores == 5).mean(),
        })
    return pd.DataFrame(rows).round(3)


def review_by_duration(orders: pd.DataFrame) -> pd.DataFrame:
    """Gegenprobe: Bewertung nach absoluter Lieferdauer, getrennt nach pünktlich und verspätet."""
    orders = orders.assign(
        duration_class=pd.cut(orders["days_total"], bins=DURATION_BINS, labels=DURATION_LABELS)
    )
    table = (
        orders.groupby(["duration_class", "is_late"], observed=True)["review_score"]
        .agg(avg_review="mean", n_orders="size")
        .reset_index()
    )
    table["delivery"] = np.where(table["is_late"], "verspätet", "pünktlich")
    return table[["duration_class", "delivery", "n_orders", "avg_review"]].round(3)


def regression_late_and_duration(orders: pd.DataFrame) -> dict:
    """Lineare Regression: Bewertung = a + b1 * verspätet + b2 * Lieferdauer in Tagen."""
    # ENTSCHEIDUNG: Eine einfache lineare Regression statt eines komplexeren
    # Modells. Sie beantwortet genau eine Frage: Wie viel Sterne "kostet" ein
    # gebrochenes Versprechen bei gleicher Lieferdauer, und wie viel ein Tag
    # mehr Lieferdauer bei gleichem Pünktlichkeitsstatus? Das ist eine
    # Beschreibung des Zusammenhangs, kein Kausaleffekt.
    is_late = orders["is_late"].astype(float).to_numpy()
    duration = orders["days_total"].to_numpy()
    y = orders["review_score"].to_numpy(dtype=float)

    X = np.column_stack([np.ones(len(y)), is_late, duration])
    coefficients, *_ = np.linalg.lstsq(X, y, rcond=None)
    residuals = y - X @ coefficients
    r_squared = 1 - residuals.var() / y.var()

    return {
        "intercept": coefficients[0],
        "stars_late": coefficients[1],
        "stars_per_day_duration": coefficients[2],
        "stars_per_week_duration": coefficients[2] * 7,
        "days_duration_equal_to_being_late": coefficients[1] / coefficients[2],
        "r_squared": r_squared,
    }


def correlation_tests(orders: pd.DataFrame) -> dict:
    """Rangkorrelation und Gruppenvergleich. Bewertungen sind ordinal (1 bis 5),
    deshalb Spearman und Mann-Whitney statt Pearson und t-Test."""
    on_time = orders[~orders["is_late"]]
    late = orders[orders["is_late"]]
    spearman_delay = stats.spearmanr(orders["days_vs_estimate"], orders["review_score"])
    spearman_duration_on_time = stats.spearmanr(on_time["days_total"], on_time["review_score"])
    mann_whitney = stats.mannwhitneyu(on_time["review_score"], late["review_score"])
    return {
        "spearman_delay_vs_review": spearman_delay.statistic,
        "spearman_delay_p": spearman_delay.pvalue,
        "spearman_duration_vs_review_on_time": spearman_duration_on_time.statistic,
        "mann_whitney_p": mann_whitney.pvalue,
        "late_share_of_orders_pct": 100 * len(late) / len(orders),
        "late_share_of_one_star_pct": 100 * (late["review_score"] == 1).sum()
                                      / (orders["review_score"] == 1).sum(),
    }


def confounder_checks(orders: pd.DataFrame) -> dict:
    """Zwei einfache Robustheitsprüfungen gegen naheliegende Störfaktoren."""
    # Prüfung 1: Nur Bestellungen mit genau einer Position. Damit fällt
    # "komplizierte Mehrfachbestellung" als gemeinsame Ursache weg.
    single_item = orders[orders["n_items"] == 1]
    single_gap = (single_item.loc[~single_item["is_late"], "review_score"].mean()
                  - single_item.loc[single_item["is_late"], "review_score"].mean())

    # Prüfung 2: Bestellungen mit mehreren Verkäufern sind selten verspätet,
    # werden aber trotzdem schlecht bewertet: ein Hinweis auf weitere Treiber.
    multi_seller = orders[orders["n_sellers"] > 1]

    # Prüfung 3: Der Abstand pünktlich gegen verspätet je Region
    by_region = orders.groupby(["region", "is_late"])["review_score"].mean().unstack()
    region_gaps = (by_region[False] - by_region[True]).round(2).to_dict()

    return {
        "single_item_n": len(single_item),
        "single_item_gap_stars": single_gap,
        "multi_seller_n": len(multi_seller),
        "multi_seller_late_pct": 100 * multi_seller["is_late"].mean(),
        "multi_seller_avg_review": multi_seller["review_score"].mean(),
        "single_seller_avg_review": orders.loc[orders["n_sellers"] == 1, "review_score"].mean(),
        "gap_by_region": region_gaps,
    }


def plot_review_by_delay_class(summary: pd.DataFrame) -> None:
    fig, (ax_left, ax_right) = plt.subplots(1, 2, figsize=(11, 4.4))

    x_positions = np.arange(len(summary))
    labels = [label.replace(" zu spät", "\nzu spät") for label in summary["delay_class"]]

    # Links: durchschnittliche Bewertung mit Konfidenzintervall
    errors = [summary["avg_review"] - summary["ci95_low"], summary["ci95_high"] - summary["avg_review"]]
    ax_left.bar(x_positions, summary["avg_review"], width=0.6, color=BLUE_RAMP_4,
                yerr=errors, ecolor=TEXT_SECONDARY, capsize=3)
    for x, value in zip(x_positions, summary["avg_review"]):
        ax_left.text(x, value + 0.08, f"{value:.2f}".replace(".", ","), ha="center",
                     color=TEXT_PRIMARY, fontsize=10, fontweight="bold")
    ax_left.set_xticks(x_positions, labels)
    ax_left.set_ylim(0, 5)
    ax_left.set_ylabel("Ø Bewertung (Sterne)")
    ax_left.set_title("Ø Bewertung je Verzugsklasse")
    ax_left.grid(axis="x", visible=False)

    # Rechts: Anteil der Ein-Stern-Bewertungen
    ax_right.bar(x_positions, summary["one_star_pct"], width=0.6, color=BLUE_RAMP_4)
    for x, value in zip(x_positions, summary["one_star_pct"]):
        ax_right.text(x, value + 1.5, f"{value:.1f} %".replace(".", ","), ha="center",
                      color=TEXT_PRIMARY, fontsize=10, fontweight="bold")
    ax_right.set_xticks(x_positions, labels)
    ax_right.set_ylim(0, 80)
    ax_right.set_ylabel("Anteil Ein-Stern-Bewertungen (%)")
    ax_right.set_title("Anteil Ein-Stern-Bewertungen")
    ax_right.grid(axis="x", visible=False)

    fig.suptitle("Je größer der Verzug gegen das Versprechen, desto schlechter die Bewertung "
                 "(Zusammenhang, kein Kausalnachweis)", x=0.01, ha="left", fontsize=10,
                 color=TEXT_SECONDARY)
    save_figure(fig, "02_review_by_delay_class.png")


def plot_review_by_duration(duration_table: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(8, 4.4))
    for delivery, color in [("pünktlich", BLUE), ("verspätet", ORANGE)]:
        subset = duration_table[duration_table["delivery"] == delivery]
        ax.plot(subset["duration_class"].astype(str), subset["avg_review"], color=color,
                linewidth=2, marker="o", markersize=7, label=delivery)
        last = subset.iloc[-1]
        ax.annotate(delivery, (len(subset) - 1, last["avg_review"]), xytext=(8, 0),
                    textcoords="offset points", va="center", color=TEXT_PRIMARY, fontsize=9)
    ax.set_ylim(1, 5)
    ax.set_xlabel("Lieferdauer vom Kauf bis zur Zustellung")
    ax.set_ylabel("Ø Bewertung (Sterne)")
    ax.set_title("Bei gleicher Lieferdauer: verspätet wird deutlich schlechter bewertet")
    ax.legend(loc="lower left")
    save_figure(fig, "02_review_by_duration_on_time_vs_late.png")


# ============================================================================
# Teil 2: Frachtkosten und Geografie
# ============================================================================
# ENTSCHEIDUNG: Die Frachtanalyse steht im selben Skript wie die Lieferanalyse,
# weil beide an derselben Geografie hängen (Verkäufer konzentriert im Südosten,
# Kunden im ganzen Land). Die Entfernung ist die Luftlinie zwischen den
# Median-Koordinaten der PLZ-Präfixe; Straßenkilometer sind länger, die
# Reihenfolge der Entfernungen bleibt aber erhalten.

def load_freight_items(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    """Positionen zugestellter Bestellungen im Fenster, mit Gewicht, Volumen und Koordinaten."""
    query = """
        SELECT i.order_id,
               i.price::DOUBLE           AS price,
               i.freight_value::DOUBLE   AS freight_value,
               p.category_en,
               p.weight_g::DOUBLE        AS weight_g,
               p.volume_cm3::DOUBLE      AS volume_cm3,
               s.state                   AS seller_state,
               c.state                   AS customer_state,
               s.lat::DOUBLE             AS seller_lat,
               s.lng::DOUBLE             AS seller_lng,
               c.lat::DOUBLE             AS customer_lat,
               c.lng::DOUBLE             AS customer_lng
        FROM fact_order_items i
        JOIN fact_orders f  ON f.order_id = i.order_id
        JOIN dim_product p  ON p.product_id = i.product_id
        JOIN dim_seller s   ON s.seller_id = i.seller_id
        JOIN dim_customer c ON c.customer_unique_id = i.customer_unique_id
        WHERE f.order_status = 'delivered'
          AND f.purchase_date_id BETWEEN 20170101 AND 20180831
    """
    return con.execute(query).df()


def haversine_km(lat1, lng1, lat2, lng2) -> np.ndarray:
    """Luftlinie zwischen zwei Koordinaten auf der Erdkugel, in Kilometern."""
    earth_radius_km = 6371
    lat1, lng1, lat2, lng2 = (np.radians(v) for v in (lat1, lng1, lat2, lng2))
    a = (np.sin((lat2 - lat1) / 2) ** 2
         + np.cos(lat1) * np.cos(lat2) * np.sin((lng2 - lng1) / 2) ** 2)
    return 2 * earth_radius_km * np.arcsin(np.sqrt(a))


def freight_drivers(items: pd.DataFrame) -> pd.DataFrame:
    """Welcher Faktor erklärt den Frachtwert am meisten: Gewicht, Volumen oder Entfernung?"""
    # ENTSCHEIDUNG: Zwei Blickwinkel nebeneinander. (1) R² jedes Faktors allein:
    # Wie viel der Streuung erklärt er für sich? (2) Standardisierte
    # Koeffizienten im gemeinsamen Modell: Welcher Faktor wiegt am schwersten,
    # wenn die anderen gleich bleiben? Gewicht und Volumen hängen stark
    # zusammen (Korrelation rund 0,8), deshalb teilen sie sich ihre Erklärungskraft.
    data = items.dropna(subset=["weight_g", "volume_cm3", "distance_km"])
    y = data["freight_value"].to_numpy()
    predictors = {"weight_g": "Gewicht", "volume_cm3": "Volumen", "distance_km": "Entfernung"}

    def r_squared(columns: list) -> float:
        X = np.column_stack([np.ones(len(data))] + [data[c].to_numpy() for c in columns])
        coefficients, *_ = np.linalg.lstsq(X, y, rcond=None)
        residuals = y - X @ coefficients
        return 1 - residuals.var() / y.var()

    standardized = data[list(predictors)].apply(lambda col: (col - col.mean()) / col.std())
    y_standardized = (y - y.mean()) / y.std()
    X = np.column_stack([np.ones(len(data)), standardized.to_numpy()])
    betas, *_ = np.linalg.lstsq(X, y_standardized, rcond=None)

    rows = []
    for position, (column, label) in enumerate(predictors.items(), start=1):
        rows.append({
            "driver": label,
            "r_squared_alone": r_squared([column]),
            "standardized_beta_joint_model": betas[position],
        })
    rows.append({
        "driver": "Alle drei zusammen",
        "r_squared_alone": r_squared(list(predictors)),
        "standardized_beta_joint_model": np.nan,
    })
    result = pd.DataFrame(rows).round(3)
    result.attrs["n_items"] = len(data)
    result.attrs["corr_weight_volume"] = data["weight_g"].corr(data["volume_cm3"])
    return result


def freight_by_distance(items: pd.DataFrame) -> pd.DataFrame:
    bins = [-1, 100, 500, 1000, 2000, 5000]
    labels = ["bis 100 km", "100 bis 500 km", "500 bis 1.000 km", "1.000 bis 2.000 km", "über 2.000 km"]
    data = items.dropna(subset=["distance_km"]).assign(
        distance_band=lambda d: pd.cut(d["distance_km"], bins=bins, labels=labels)
    )
    table = data.groupby("distance_band", observed=True).agg(
        n_items=("freight_value", "size"),
        avg_freight_brl=("freight_value", "mean"),
        freight_sum=("freight_value", "sum"),
        price_sum=("price", "sum"),
    ).reset_index()
    table["freight_share_pct"] = 100 * table["freight_sum"] / table["price_sum"]
    return table.drop(columns=["freight_sum", "price_sum"]).round(2)


def most_expensive_routes(items: pd.DataFrame, min_items: int = 200) -> pd.DataFrame:
    """Routen Verkäufer-Staat -> Kunden-Staat mit mindestens min_items Positionen."""
    # ENTSCHEIDUNG: Mindestens 200 Positionen je Route, damit einzelne teure
    # Sendungen das Ranking nicht bestimmen.
    routes = items.groupby(["seller_state", "customer_state"]).agg(
        n_items=("freight_value", "size"),
        avg_freight_brl=("freight_value", "mean"),
        avg_distance_km=("distance_km", "mean"),
        freight_sum=("freight_value", "sum"),
        price_sum=("price", "sum"),
    ).reset_index()
    routes["freight_share_pct"] = 100 * routes["freight_sum"] / routes["price_sum"]
    routes["route"] = routes["seller_state"] + " -> " + routes["customer_state"]
    routes = routes[routes["n_items"] >= min_items]
    columns = ["route", "seller_state", "customer_state", "n_items", "avg_distance_km",
               "avg_freight_brl", "freight_share_pct"]
    return routes.sort_values("avg_freight_brl", ascending=False)[columns].round(2)


def plot_freight_by_distance(table: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(8, 4.2))
    x_positions = np.arange(len(table))
    ax.bar(x_positions, table["freight_share_pct"], width=0.6, color=BLUE_RAMP_5)
    for x, value in zip(x_positions, table["freight_share_pct"]):
        ax.text(x, value + 0.5, f"{value:.1f} %".replace(".", ","), ha="center",
                color=TEXT_PRIMARY, fontsize=10, fontweight="bold")
    ax.set_xticks(x_positions, table["distance_band"].astype(str))
    ax.set_ylabel("Fracht in % des Warenwerts")
    ax.set_xlabel("Luftlinie Verkäufer zu Kunde")
    ax.set_title("Frachtanteil steigt mit der Entfernung")
    ax.grid(axis="x", visible=False)
    save_figure(fig, "02_freight_share_by_distance.png")


# ============================================================================
# Ausführung
# ============================================================================

def main() -> None:
    apply_style()
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH, read_only=True)

    # ---------------- Teil 1 ----------------
    orders = load_reviewed_deliveries(con)
    orders["delay_class"] = assign_delay_class(orders["days_vs_estimate"])
    print(f"Basis Teil 1: {len(orders):,} zugestellte, bewertete Bestellungen im Fenster\n")

    summary = summarize_by_delay_class(orders)
    print("Bewertung je Verzugsklasse:")
    print(summary.to_string(index=False), "\n")

    duration_table = review_by_duration(orders)
    print("Gegenprobe, Bewertung nach Lieferdauer:")
    print(duration_table.pivot(index="duration_class", columns="delivery",
                               values=["avg_review", "n_orders"]).to_string(), "\n")

    regression = regression_late_and_duration(orders)
    print("Regression Bewertung = a + b1 * verspätet + b2 * Lieferdauer:")
    for key, value in regression.items():
        print(f"  {key}: {value:.4f}")

    tests = correlation_tests(orders)
    print("\nKorrelation und Tests:")
    for key, value in tests.items():
        print(f"  {key}: {value:.4g}")

    confounders = confounder_checks(orders)
    print("\nRobustheitsprüfungen:")
    for key, value in confounders.items():
        print(f"  {key}: {value if isinstance(value, dict) else round(value, 3)}")

    plot_review_by_delay_class(summary)
    plot_review_by_duration(duration_table)
    summary.to_csv(EXPORT_DIR / "delay_class_reviews.csv", index=False)
    duration_table.to_csv(EXPORT_DIR / "review_by_duration.csv", index=False)

    # ---------------- Teil 2 ----------------
    items = load_freight_items(con)
    items["distance_km"] = haversine_km(items["seller_lat"], items["seller_lng"],
                                        items["customer_lat"], items["customer_lng"])
    print(f"\nBasis Teil 2: {len(items):,} Positionen, "
          f"{items['distance_km'].notna().sum():,} mit Koordinaten auf beiden Seiten")
    print(f"Median-Entfernung: {items['distance_km'].median():.0f} km")

    drivers = freight_drivers(items)
    print(f"\nTreiber des Frachtwerts ({drivers.attrs['n_items']:,} Positionen, "
          f"Korrelation Gewicht-Volumen {drivers.attrs['corr_weight_volume']:.2f}):")
    print(drivers.to_string(index=False))

    distance_table = freight_by_distance(items)
    print("\nFrachtanteil nach Entfernung:")
    print(distance_table.to_string(index=False))

    routes = most_expensive_routes(items)
    print("\nTeuerste Routen (mindestens 200 Positionen), nach Ø Fracht:")
    print(routes.head(10).to_string(index=False))
    print("\nNach Frachtanteil am Warenwert:")
    print(routes.sort_values("freight_share_pct", ascending=False).head(5).to_string(index=False))

    plot_freight_by_distance(distance_table)
    drivers.to_csv(EXPORT_DIR / "freight_drivers.csv", index=False)
    distance_table.to_csv(EXPORT_DIR / "freight_by_distance.csv", index=False)
    routes.to_csv(EXPORT_DIR / "freight_routes.csv", index=False)

    con.close()


if __name__ == "__main__":
    main()
