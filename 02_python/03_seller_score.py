"""
03_seller_score.py: Verkäufer-Scorecard (0 bis 100).

Aufruf aus dem Repo-Root (nach 01_sql/05_sellers.sql):
    python 02_python/03_seller_score.py

Schritte:
    1. Kennzahlen je Verkäufer aus der View v_seller_orders berechnen
       (Abgleich mit der SQL-View v_seller_kpis als Kontrolle)
    2. Jede Kennzahl zum Marktmittel hin dämpfen. Die Dämpfungsstärke wird
       aus den Daten geschätzt, nicht geraten.
    3. Jede Kennzahl auf 0 bis 100 normieren (100 = gut)
    4. Gewichteter Gesamtscore
    5. Sensitivität: Wie stark hängt das Ranking an den Gewichten?
    6. Zusätzlich ein Score nur aus 2017er Daten, damit 05_cutoff_analysis.py
       prüfen kann, ob der Score die Qualität in 2018 vorhersagt.

Ausgaben:
    DuckDB-Tabellen seller_scorecard (Fenster 01/2017 bis 08/2018) und
        seller_scorecard_2017 (nur 2017, für die Gegenprobe)
    reports/figures/03_seller_score_distribution.png
    03_dashboard/exports/seller_score_sensitivity.csv
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
pd.set_option("display.max_columns", 20)

DB_PATH = "data/olist.duckdb"
EXPORT_DIR = Path("03_dashboard/exports")

# ENTSCHEIDUNG: Gewichte der Scorecard, gesetzt und begründet, nicht optimiert.
#   Bewertung 40 %: das direkte Urteil des Kunden, an dem der Ruf des Marktplatzes hängt.
#   Verspätung 30 %: der stärkste messbare Begleiter schlechter Bewertungen (AP5)
#                    und ein Versprechen, das der Verkäufer mit beeinflusst.
#   Bearbeitung 15 %: der Teil der Lieferzeit, den der Verkäufer allein steuert;
#                     steckt zum Teil schon in der Verspätung, deshalb weniger Gewicht.
#   Storno 15 %:      selten (Median 0 %), aber jede Stornierung ist ein ganz
#                     gescheiterter Kauf.
# Die Anzahl Bestellungen ist kein eigener Baustein, sondern steuert die Dämpfung.
#
# ENTSCHEIDUNG: Normierung auf 0 bis 100 über feste Anker statt Perzentilen.
# So bedeutet "Score 60" immer dasselbe, unabhängig davon, welche Verkäufer
# gerade aktiv sind. Die schlechten Anker liegen etwa beim 90. bis 95.
# Perzentil der Verkäufer; schlechtere Werte werden auf 0 begrenzt.
COMPONENTS = {
    "review": {
        "label": "Bewertung",
        "order_column": "review_score",      # Wert je Bestellung
        "quality_orders_only": True,
        "worst": 1.0, "best": 5.0,           # 1 Stern = 0 Punkte, 5 Sterne = 100
        "weight": 0.40,
    },
    "late": {
        "label": "Verspätungsquote",
        "order_column": "is_late",
        "quality_orders_only": True,
        "worst": 0.20, "best": 0.0,          # 20 % verspätet = 0 Punkte (rund 3x Marktschnitt)
        "weight": 0.30,
    },
    "handling": {
        "label": "Bearbeitungszeit",
        "order_column": "days_seller_handling",
        "quality_orders_only": True,
        "worst": 10.0, "best": 0.0,          # 10 Tage = 0 Punkte (rund 95. Perzentil)
        "weight": 0.15,
    },
    "cancel": {
        "label": "Stornoquote",
        "order_column": "is_canceled",
        "quality_orders_only": False,        # Storno zählt über alle Bestellungen
        "worst": 0.10, "best": 0.0,          # 10 % storniert = 0 Punkte
        "weight": 0.15,
    },
}

# Grenzen für die geschätzte Dämpfungsstärke (siehe estimate_shrinkage_strength)
MIN_SHRINKAGE = 5
MAX_SHRINKAGE = 100


def load_seller_orders(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    seller_orders = con.execute("SELECT * FROM v_seller_orders").df()
    for column in ["is_late", "is_canceled"]:
        seller_orders[column] = seller_orders[column].astype(float)
    seller_orders["review_score"] = seller_orders["review_score"].astype(float)
    seller_orders["days_seller_handling"] = seller_orders["days_seller_handling"].astype(float)
    seller_orders["seller_revenue"] = seller_orders["seller_revenue"].astype(float)
    return seller_orders


def observations(seller_orders: pd.DataFrame, component: dict) -> pd.DataFrame:
    """Die Einzelwerte, aus denen eine Kennzahl gemittelt wird (eine Zeile je Bestellung)."""
    data = seller_orders
    if component["quality_orders_only"]:
        data = data[data["is_quality_order"]]
    return data[["seller_id", component["order_column"]]].dropna()


def estimate_shrinkage_strength(values: pd.DataFrame, column: str, min_orders: int = 20) -> float:
    """
    Schätzt k = Streuung innerhalb eines Verkäufers / Streuung zwischen Verkäufern.

    Bedeutung von k: Ab k Bestellungen zählt der eigene Durchschnitt eines
    Verkäufers mehr als der Marktdurchschnitt. Ist die Streuung von Bestellung
    zu Bestellung groß und der echte Unterschied zwischen Verkäufern klein,
    braucht es viele Bestellungen, bis man einem Verkäuferwert trauen kann.
    """
    grouped = values.groupby("seller_id")[column]
    counts = grouped.count()
    # Gepoolte Varianz innerhalb der Verkäufer
    within_variance = (grouped.var(ddof=1) * (counts - 1)).sum() / (counts - 1).sum()
    # Varianz der Verkäufer-Mittelwerte, bereinigt um den Zufallsanteil
    large = counts[counts >= min_orders].index
    means_large = grouped.mean()[large]
    between_variance = means_large.var() - (within_variance / counts[large]).mean()
    if between_variance <= 0:
        return MAX_SHRINKAGE
    return float(np.clip(within_variance / between_variance, MIN_SHRINKAGE, MAX_SHRINKAGE))


def compute_scorecard(seller_orders: pd.DataFrame, weights: dict | None = None,
                      shrinkage: dict | None = None) -> tuple[pd.DataFrame, dict]:
    """Kennzahlen, gedämpfte Kennzahlen, Teilscores und Gesamtscore je Verkäufer."""
    # Umsatz zählt nur bei zugestellten Bestellungen (realisierter Umsatz)
    is_delivered = seller_orders["order_status"] == "delivered"
    seller_orders = seller_orders.assign(
        is_delivered=is_delivered,
        delivered_revenue=np.where(is_delivered, seller_orders["seller_revenue"], 0.0),
    )
    sellers = seller_orders.groupby("seller_id").agg(
        n_orders=("order_id", "nunique"),
        n_delivered_orders=("is_delivered", "sum"),
        revenue_brl=("delivered_revenue", "sum"),
        n_quality_orders=("is_quality_order", "sum"),
    )
    weights = weights or {name: c["weight"] for name, c in COMPONENTS.items()}
    estimated_k = {}

    for name, component in COMPONENTS.items():
        values = observations(seller_orders, component)
        column = component["order_column"]
        per_seller = values.groupby("seller_id")[column].agg(["mean", "count"])
        market_mean = values[column].mean()   # gewichtet nach Bestellungen

        # ENTSCHEIDUNG: Dämpfung statt Mindestbestellzahl. Kein Verkäufer
        # fällt heraus, aber wenige Bestellungen ziehen den Wert zum
        # Marktmittel: gedämpft = (n * eigener Wert + k * Markt) / (n + k).
        # k wird je Kennzahl aus den Daten geschätzt (siehe oben).
        k = shrinkage[name] if shrinkage else estimate_shrinkage_strength(values, column)
        estimated_k[name] = k

        n = per_seller["count"].reindex(sellers.index).fillna(0)
        raw = per_seller["mean"].reindex(sellers.index)
        shrunk = (n * raw.fillna(market_mean) + k * market_mean) / (n + k)

        span = component["best"] - component["worst"]
        component_score = ((shrunk - component["worst"]) / span).clip(0, 1) * 100

        sellers[f"{name}_raw"] = raw
        sellers[f"{name}_n"] = n
        sellers[f"{name}_shrunk"] = shrunk
        sellers[f"{name}_score"] = component_score

    sellers["score"] = sum(weights[name] * sellers[f"{name}_score"] for name in COMPONENTS)
    return sellers.reset_index(), estimated_k


def check_against_sql_view(sellers: pd.DataFrame, con: duckdb.DuckDBPyConnection) -> None:
    """Kontrolle: Die Python-Kennzahlen müssen mit der SQL-View v_seller_kpis übereinstimmen."""
    view = con.execute("SELECT seller_id, revenue_brl, avg_review, late_rate, cancel_rate FROM v_seller_kpis").df()
    merged = sellers.merge(view, on="seller_id", suffixes=("", "_sql"))
    checks = {
        "revenue": np.allclose(merged["revenue_brl"], merged["revenue_brl_sql"].astype(float)),
        "review": np.allclose(merged["review_raw"], merged["avg_review"], equal_nan=True),
        "late": np.allclose(merged["late_raw"], merged["late_rate"], equal_nan=True),
        "cancel": np.allclose(merged["cancel_raw"], merged["cancel_rate"], equal_nan=True),
    }
    print(f"Abgleich mit v_seller_kpis ({len(merged):,} Verkäufer): {checks}")
    if not all(checks.values()):
        raise SystemExit("FEHLER: Python-Kennzahlen weichen von der SQL-View ab.")


def sensitivity_analysis(seller_orders: pd.DataFrame, base: pd.DataFrame, shrinkage: dict) -> pd.DataFrame:
    """Wie ändert sich das Ranking, wenn man die Gewichte anders setzt?"""
    alternatives = {
        "Basis 40/30/15/15": {"review": 0.40, "late": 0.30, "handling": 0.15, "cancel": 0.15},
        "Gleichgewichtet 25/25/25/25": {"review": 0.25, "late": 0.25, "handling": 0.25, "cancel": 0.25},
        "Nur Bewertung": {"review": 1.0, "late": 0.0, "handling": 0.0, "cancel": 0.0},
        "Nur Operations 0/50/25/25": {"review": 0.0, "late": 0.50, "handling": 0.25, "cancel": 0.25},
        "Bewertung stärker 60/20/10/10": {"review": 0.60, "late": 0.20, "handling": 0.10, "cancel": 0.10},
    }
    # Vergleich nur bei Verkäufern mit genug Bestellungen, sonst dominiert die Dämpfung
    reliable = base["n_quality_orders"] >= 25
    base_bottom = set(base.loc[reliable].nsmallest(int(reliable.sum() * 0.25), "score")["seller_id"])

    rows = []
    for label, weights in alternatives.items():
        alternative, _ = compute_scorecard(seller_orders, weights=weights, shrinkage=shrinkage)
        merged = base[["seller_id", "score"]].merge(alternative[["seller_id", "score"]],
                                                    on="seller_id", suffixes=("_base", "_alt"))
        merged = merged[merged["seller_id"].isin(base.loc[reliable, "seller_id"])]
        rho = stats.spearmanr(merged["score_base"], merged["score_alt"]).statistic
        alt_bottom = set(merged.nsmallest(len(base_bottom), "score_alt")["seller_id"])
        rows.append({
            "weighting": label,
            "spearman_vs_base": round(rho, 3),
            "bottom_quartile_overlap_pct": round(100 * len(base_bottom & alt_bottom) / len(base_bottom), 1),
        })
    return pd.DataFrame(rows)


def plot_score_distribution(sellers: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(8, 4.2))
    reliable = sellers["n_quality_orders"] >= 25
    ax.hist(sellers.loc[reliable, "score"], bins=np.arange(0, 101, 2), color=BLUE,
            edgecolor="#fcfcfb", linewidth=1)
    median = sellers.loc[reliable, "score"].median()
    ax.axvline(median, color=TEXT_SECONDARY, linewidth=1, linestyle="--")
    ax.set_ylim(0, ax.get_ylim()[1] * 1.1)
    ax.text(median - 1.5, ax.get_ylim()[1] * 0.93, f"Median {median:.1f}".replace(".", ","),
            color=TEXT_PRIMARY, fontsize=9, ha="right",
            bbox={"facecolor": "#fcfcfb", "edgecolor": "none", "pad": 1})
    ax.set_xlim(0, 100)
    ax.set_xlabel("Verkäufer-Score (0 = schlecht, 100 = gut)")
    ax.set_ylabel("Anzahl Verkäufer")
    ax.set_title(f"Score-Verteilung, {reliable.sum()} Verkäufer mit mind. 25 Bestellungen")
    ax.grid(axis="x", visible=False)
    save_figure(fig, "03_seller_score_distribution.png")


def save_table(con: duckdb.DuckDBPyConnection, table_name: str, sellers: pd.DataFrame) -> None:
    con.register("scorecard_frame", sellers)
    con.execute(f"CREATE OR REPLACE TABLE {table_name} AS SELECT * FROM scorecard_frame")
    con.unregister("scorecard_frame")
    print(f"Tabelle {table_name} gespeichert ({len(sellers):,} Verkäufer)")


def main() -> None:
    apply_style()
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH)

    seller_orders = load_seller_orders(con)
    sellers, shrinkage = compute_scorecard(seller_orders)
    check_against_sql_view(sellers, con)

    print("\nGeschätzte Dämpfungsstärke k je Kennzahl (Bestellungen, ab denen der eigene Wert mehr zählt):")
    for name, k in shrinkage.items():
        print(f"  {COMPONENTS[name]['label']}: k = {k:.1f}")

    print("\nScore-Verteilung (alle Verkäufer):")
    print(sellers["score"].describe(percentiles=[0.1, 0.25, 0.5, 0.75, 0.9]).round(2).to_string())
    reliable = sellers["n_quality_orders"] >= 25
    print(f"\nVerkäufer mit mindestens 25 bewertbaren Bestellungen: {reliable.sum():,}")
    print(sellers.loc[reliable, "score"].describe(percentiles=[0.1, 0.25, 0.5, 0.75, 0.9]).round(2).to_string())

    component_columns = [f"{name}_score" for name in COMPONENTS]
    print("\nMittlere Teilscores:")
    print(sellers[component_columns].mean().round(1).to_string())

    print("\nDie 10 schwächsten Verkäufer mit mindestens 25 bewertbaren Bestellungen:")
    print(sellers.loc[reliable].nsmallest(10, "score")[
        ["seller_id", "n_quality_orders", "revenue_brl", "review_raw", "late_raw",
         "handling_raw", "cancel_raw", "score"]].round(3).to_string(index=False))

    sensitivity = sensitivity_analysis(seller_orders, sellers, shrinkage)
    print("\nSensitivität der Gewichte (Verkäufer mit mindestens 25 bewertbaren Bestellungen):")
    print(sensitivity.to_string(index=False))

    plot_score_distribution(sellers)
    save_table(con, "seller_scorecard", sellers)
    sensitivity.to_csv(EXPORT_DIR / "seller_score_sensitivity.csv", index=False)

    # ENTSCHEIDUNG: Zweiter Score nur aus Bestellungen von 2017. Damit prüft
    # 05_cutoff_analysis.py, ob ein Score aus der Vergangenheit die Qualität
    # in 2018 vorhersagt. Ohne diese Gegenprobe wäre der Effekt eines
    # Ausschlusses zu optimistisch, weil der Score dieselben Bewertungen
    # enthält, an denen der Effekt gemessen wird.
    orders_2017 = seller_orders[seller_orders["purchase_date_id"] <= 20171231]
    sellers_2017, _ = compute_scorecard(orders_2017, shrinkage=shrinkage)
    save_table(con, "seller_scorecard_2017", sellers_2017)

    con.close()


if __name__ == "__main__":
    main()
