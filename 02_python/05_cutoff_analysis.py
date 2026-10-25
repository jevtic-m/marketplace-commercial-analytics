"""
05_cutoff_analysis.py: Trade-off zwischen Qualität und Umsatz bei jeder Score-Schwelle.

Aufruf aus dem Repo-Root (nach 03_seller_score.py):
    python 02_python/05_cutoff_analysis.py

Für jede Schwelle von 0 bis 100 wird durchgerechnet, was passiert, wenn alle
Verkäufer unter der Schwelle den Marktplatz verlassen:
    - Wie viele Verkäufer bleiben?
    - Wie viel Umsatz geht verloren?
    - Wie viele Ein-Stern-Bewertungen entfallen?
    - Wie hoch ist die Durchschnittsbewertung des verbleibenden Marktplatzes?

Danach wird eine Schwelle nach einer festen Regel gewählt und mit einem Score
aus 2017 gegen die Bestellungen von 2018 gegengeprüft.

Ausgaben:
    DuckDB-Tabellen seller_cutoff_tradeoff, seller_quadrants
    reports/figures/05_cutoff_tradeoff.png, 05_seller_quadrants.png
    03_dashboard/exports/cutoff_tradeoff.csv, cutoff_summary.csv
"""

import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from chart_style import (  # noqa: E402
    BLUE, ORANGE, TEXT_PRIMARY, TEXT_SECONDARY, apply_style, plt, save_figure,
)

sys.stdout.reconfigure(encoding="utf-8")
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 20)

DB_PATH = "data/olist.duckdb"
EXPORT_DIR = Path("03_dashboard/exports")

# ENTSCHEIDUNG: Wahl des Cutoffs über ein Umsatzbudget. Gewählt wird die
# höchste Schwelle, bei der höchstens 5 % des realisierten Umsatzes verloren
# gehen. Ohne Margendaten lässt sich kein Gewinnoptimum rechnen; das Budget
# ist eine gesetzte Risikobereitschaft. Die naheliegende Alternative "größter
# Abstand zwischen vermiedenen Ein-Stern-Bewertungen und verlorenem Umsatz"
# würde rund 39 % des Umsatzes opfern und ist für einen Marktplatz unrealistisch.
MAX_REVENUE_LOSS_PCT = 5.0

# ENTSCHEIDUNG: "Groß" heißt Top 20 % der Verkäufer nach Umsatz. Diese Gruppe
# trägt rund 82 % des Umsatzes (05_sellers.sql, Abfrage 13).
LARGE_SELLER_QUANTILE = 0.80


def load_delivered_seller_orders(con: duckdb.DuckDBPyConnection, score_table: str) -> pd.DataFrame:
    """Zugestellte Bestellungen je Verkäufer, mit dessen Score.

    ENTSCHEIDUNG: Bewertet werden nur zugestellte Bestellungen (wie in allen
    Bewertungsanalysen). Bestellungen mit mehreren Verkäufern zählen hier
    vollständig mit: Fällt einer ihrer Verkäufer weg, gilt die ganze Bestellung
    mit ihrer Bewertung als entfallen. Der Umsatz entfällt nur für den
    Anteil des ausgeschlossenen Verkäufers.
    """
    query = f"""
        SELECT o.seller_id,
               o.order_id,
               o.purchase_date_id,
               o.seller_revenue::DOUBLE  AS seller_revenue,
               o.review_score::DOUBLE    AS review_score,
               s.score
        FROM v_seller_orders o
        LEFT JOIN {score_table} s ON s.seller_id = o.seller_id
        WHERE o.order_status = 'delivered'
        ORDER BY o.seller_id, o.order_id
    """
    return con.execute(query).df()


def evaluate_cutoff(seller_orders: pd.DataFrame, cutoff: float) -> dict:
    """Kennzahlen des Marktplatzes, wenn alle Verkäufer mit Score unter cutoff wegfallen.

    Verkäufer ohne Score (zum Beispiel neu in 2018 bei der Gegenprobe) bleiben.
    """
    is_excluded_row = seller_orders["score"] < cutoff        # NaN < cutoff ist False
    total_revenue = seller_orders["seller_revenue"].sum()
    lost_revenue = seller_orders.loc[is_excluded_row, "seller_revenue"].sum()

    # Auf Bestellebene: Eine Bestellung entfällt, wenn mindestens ein Verkäufer wegfällt.
    orders = seller_orders.assign(is_excluded_row=is_excluded_row).groupby("order_id").agg(
        review_score=("review_score", "first"),
        is_removed=("is_excluded_row", "max"),
    )
    reviewed = orders.dropna(subset=["review_score"])
    kept = reviewed[~reviewed["is_removed"]]
    n_one_star_total = (reviewed["review_score"] == 1).sum()
    n_one_star_removed = ((reviewed["review_score"] == 1) & reviewed["is_removed"]).sum()

    scored_sellers = seller_orders.dropna(subset=["score"]).drop_duplicates("seller_id")
    return {
        "cutoff": cutoff,
        "n_sellers_excluded": int((scored_sellers["score"] < cutoff).sum()),
        "sellers_kept_pct": 100 * (scored_sellers["score"] >= cutoff).mean(),
        "revenue_lost_pct": 100 * lost_revenue / total_revenue,
        "revenue_kept_pct": 100 - 100 * lost_revenue / total_revenue,
        "orders_removed_pct": 100 * reviewed["is_removed"].mean(),
        "one_star_removed": int(n_one_star_removed),
        "one_star_removed_pct": 100 * n_one_star_removed / n_one_star_total,
        "avg_review_all": reviewed["review_score"].mean(),
        "avg_review_kept": kept["review_score"].mean(),
        "review_uplift": kept["review_score"].mean() - reviewed["review_score"].mean(),
        "one_star_share_kept_pct": 100 * (kept["review_score"] == 1).mean(),
    }


def tradeoff_table(seller_orders: pd.DataFrame) -> pd.DataFrame:
    rows = [evaluate_cutoff(seller_orders, cutoff) for cutoff in range(0, 101)]
    return pd.DataFrame(rows)


def choose_cutoff(tradeoff: pd.DataFrame) -> int:
    within_budget = tradeoff[tradeoff["revenue_lost_pct"] <= MAX_REVENUE_LOSS_PCT]
    return int(within_budget["cutoff"].max())


def assign_quadrants(con: duckdb.DuckDBPyConnection, cutoff: int) -> pd.DataFrame:
    sellers = con.execute("""
        SELECT seller_id, score, revenue_brl, n_delivered_orders, n_quality_orders
        FROM seller_scorecard
    """).df()
    large_threshold = sellers["revenue_brl"].quantile(LARGE_SELLER_QUANTILE)
    is_large = sellers["revenue_brl"] >= large_threshold
    is_good = sellers["score"] >= cutoff
    sellers["quadrant"] = np.select(
        [is_large & is_good, is_large & ~is_good, ~is_large & is_good],
        ["groß und gut", "groß und schwach (Problem)", "klein und gut (fördern)"],
        default="klein und schwach (aussortieren)",
    )
    sellers["is_below_cutoff"] = ~is_good
    sellers.attrs["large_threshold"] = large_threshold
    return sellers


def plot_tradeoff(tradeoff: pd.DataFrame, cutoff: int) -> None:
    data = tradeoff[(tradeoff["cutoff"] >= 40) & (tradeoff["cutoff"] <= 90)]
    fig, (ax_left, ax_right) = plt.subplots(1, 2, figsize=(11.5, 4.4))

    ax_left.plot(data["cutoff"], data["one_star_removed_pct"], color=ORANGE, linewidth=2,
                 label="vermiedene Ein-Stern-Bewertungen")
    ax_left.plot(data["cutoff"], data["revenue_lost_pct"], color=BLUE, linewidth=2,
                 label="verlorener Umsatz")
    ax_left.axvline(cutoff, color=TEXT_SECONDARY, linewidth=1, linestyle="--")
    chosen = tradeoff.loc[tradeoff["cutoff"] == cutoff].iloc[0]
    ax_left.annotate(f"Score {cutoff}: {chosen['one_star_removed_pct']:.1f} % Ein-Stern\n"
                     f"bei {chosen['revenue_lost_pct']:.1f} % Umsatz".replace(".", ","),
                     (cutoff, chosen["one_star_removed_pct"]), xytext=(-150, 60),
                     textcoords="offset points", fontsize=9, color=TEXT_PRIMARY,
                     arrowprops={"arrowstyle": "-", "color": TEXT_SECONDARY, "linewidth": 0.8})
    ax_left.set_xlabel("Score-Schwelle (Verkäufer darunter fallen weg)")
    ax_left.set_ylabel("Anteil in %")
    ax_left.set_title("Was ein Ausschluss bringt und kostet")
    ax_left.legend(loc="upper left")

    ax_right.plot(data["cutoff"], data["avg_review_kept"], color=BLUE, linewidth=2)
    ax_right.axvline(cutoff, color=TEXT_SECONDARY, linewidth=1, linestyle="--")
    ax_right.axhline(chosen["avg_review_all"], color=TEXT_SECONDARY, linewidth=0.8)
    ax_right.text(41, chosen["avg_review_all"] - 0.012,
                  f"heute {chosen['avg_review_all']:.2f}".replace(".", ","), fontsize=9,
                  color=TEXT_PRIMARY, va="top")
    ax_right.set_xlabel("Score-Schwelle")
    ax_right.set_ylabel("Ø Bewertung verbleibender Bestellungen")
    ax_right.set_title("Durchschnittsbewertung danach")
    save_figure(fig, "05_cutoff_tradeoff.png")


def plot_quadrants(sellers: pd.DataFrame, cutoff: int) -> None:
    data = sellers[sellers["revenue_brl"] > 0]
    fig, ax = plt.subplots(figsize=(9, 5.5))
    below = data["score"] < cutoff
    sizes = 6 + 60 * np.sqrt(data["n_delivered_orders"] / data["n_delivered_orders"].max())
    ax.scatter(data.loc[~below, "revenue_brl"], data.loc[~below, "score"], s=sizes[~below],
               color=BLUE, alpha=0.45, edgecolors="#fcfcfb", linewidths=0.5, label=f"Score ab {cutoff}")
    ax.scatter(data.loc[below, "revenue_brl"], data.loc[below, "score"], s=sizes[below],
               color=ORANGE, alpha=0.8, edgecolors="#fcfcfb", linewidths=0.5, label=f"Score unter {cutoff}")
    ax.set_xscale("log")
    ax.axhline(cutoff, color=TEXT_SECONDARY, linewidth=1, linestyle="--")
    ax.axvline(sellers.attrs["large_threshold"], color=TEXT_SECONDARY, linewidth=1, linestyle="--")
    ax.set_xlabel("Realisierter Umsatz je Verkäufer (BRL, logarithmisch)")
    ax.set_ylabel("Verkäufer-Score")
    ax.set_title("Verkäufer nach Umsatz und Score (Blasengröße = Bestellungen)")
    x_min, x_max = ax.get_xlim()
    ax.text(x_max * 0.7, 92, "groß und gut", ha="right", fontsize=9, color=TEXT_PRIMARY)
    ax.text(x_max * 0.7, cutoff - 4, "groß und schwach", ha="right", fontsize=9, color=TEXT_PRIMARY)
    ax.text(x_min * 1.5, 92, "klein und gut", fontsize=9, color=TEXT_PRIMARY)
    ax.text(x_min * 1.5, cutoff - 4, "klein und schwach", fontsize=9, color=TEXT_PRIMARY)
    ax.set_ylim(30, 95)
    ax.legend(loc="lower right")
    save_figure(fig, "05_seller_quadrants.png")


def main() -> None:
    apply_style()
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH)

    # ---------------- Trade-off im gesamten Fenster ----------------
    seller_orders = load_delivered_seller_orders(con, "seller_scorecard")
    tradeoff = tradeoff_table(seller_orders)
    cutoff = choose_cutoff(tradeoff)
    chosen = tradeoff.loc[tradeoff["cutoff"] == cutoff].iloc[0]

    print("Trade-off (Ausschnitt):")
    columns = ["cutoff", "n_sellers_excluded", "revenue_lost_pct", "one_star_removed_pct",
               "avg_review_kept", "review_uplift", "orders_removed_pct"]
    print(tradeoff.loc[tradeoff["cutoff"].between(45, 80), columns].round(3).to_string(index=False))

    print(f"\nGewählter Cutoff (höchstens {MAX_REVENUE_LOSS_PCT:.0f} % Umsatzverlust): Score {cutoff}")
    for key, value in chosen.items():
        print(f"  {key}: {value:.4f}" if isinstance(value, float) else f"  {key}: {value}")

    max_gap = tradeoff.loc[(tradeoff["one_star_removed_pct"] - tradeoff["revenue_lost_pct"]).idxmax()]
    print(f"\nZum Vergleich, Regel 'größter Abstand': Score {int(max_gap['cutoff'])}, "
          f"Umsatzverlust {max_gap['revenue_lost_pct']:.1f} %, "
          f"vermiedene Ein-Stern {max_gap['one_star_removed_pct']:.1f} %")

    # ---------------- Quadranten ----------------
    sellers = assign_quadrants(con, cutoff)
    quadrant_summary = sellers.groupby("quadrant").agg(
        n_sellers=("seller_id", "size"),
        revenue_brl=("revenue_brl", "sum"),
        avg_score=("score", "mean"),
    )
    quadrant_summary["revenue_share_pct"] = 100 * quadrant_summary["revenue_brl"] / quadrant_summary["revenue_brl"].sum()
    print(f"\nQuadranten (groß = Umsatz ab {sellers.attrs['large_threshold']:,.0f} BRL, gut = Score ab {cutoff}):")
    print(quadrant_summary.round(2).to_string())

    # ---------------- Unteres Quartil der verlässlich bewerteten Verkäufer ----------------
    reliable = sellers[sellers["n_quality_orders"] >= 25]
    lower_quartile_limit = reliable["score"].quantile(0.25)
    lower_quartile = set(reliable.loc[reliable["score"] < lower_quartile_limit, "seller_id"])
    in_quartile = seller_orders["seller_id"].isin(lower_quartile)
    orders_in_quartile = set(seller_orders.loc[in_quartile, "order_id"])
    order_reviews = seller_orders.drop_duplicates("order_id").set_index("order_id")["review_score"].dropna()
    one_star_orders = set(order_reviews[order_reviews == 1].index)
    quartile_one_star_pct = 100 * len(one_star_orders & orders_in_quartile) / len(one_star_orders)
    quartile_revenue_pct = 100 * seller_orders.loc[in_quartile, "seller_revenue"].sum() / seller_orders["seller_revenue"].sum()
    print(f"\nUnteres Score-Quartil der {len(reliable)} Verkäufer mit mindestens 25 bewertbaren Bestellungen "
          f"(Score unter {lower_quartile_limit:.1f}, {len(lower_quartile)} Verkäufer): "
          f"{quartile_one_star_pct:.1f} % der Ein-Stern-Bewertungen bei {quartile_revenue_pct:.1f} % des Umsatzes")

    # ---------------- Gegenprobe: Score aus 2017, Wirkung in 2018 ----------------
    orders_2018 = load_delivered_seller_orders(con, "seller_scorecard_2017")
    orders_2018 = orders_2018[orders_2018["purchase_date_id"] >= 20180101]
    out_of_sample = evaluate_cutoff(orders_2018, cutoff)
    n_sellers_2018 = orders_2018["seller_id"].nunique()
    n_unscored_2018 = orders_2018.loc[orders_2018["score"].isna(), "seller_id"].nunique()
    print(f"\nGegenprobe: Score aus 2017, angewendet auf {orders_2018['order_id'].nunique():,} Bestellungen 2018 "
          f"({n_sellers_2018:,} Verkäufer, davon {n_unscored_2018:,} ohne 2017er Score, die bleiben):")
    for key, value in out_of_sample.items():
        print(f"  {key}: {value:.4f}" if isinstance(value, float) else f"  {key}: {value}")

    # ---------------- Ausgaben ----------------
    plot_tradeoff(tradeoff, cutoff)
    plot_quadrants(sellers, cutoff)

    summary = pd.DataFrame([
        {"metric": "chosen_cutoff", "value": cutoff},
        {"metric": "n_sellers_excluded", "value": chosen["n_sellers_excluded"]},
        {"metric": "revenue_lost_pct", "value": round(chosen["revenue_lost_pct"], 2)},
        {"metric": "one_star_removed_pct", "value": round(chosen["one_star_removed_pct"], 2)},
        {"metric": "avg_review_all", "value": round(chosen["avg_review_all"], 3)},
        {"metric": "avg_review_kept", "value": round(chosen["avg_review_kept"], 3)},
        {"metric": "review_uplift", "value": round(chosen["review_uplift"], 3)},
        {"metric": "out_of_sample_2018_revenue_lost_pct", "value": round(out_of_sample["revenue_lost_pct"], 2)},
        {"metric": "out_of_sample_2018_one_star_removed_pct", "value": round(out_of_sample["one_star_removed_pct"], 2)},
        {"metric": "out_of_sample_2018_review_uplift", "value": round(out_of_sample["review_uplift"], 3)},
        {"metric": "lower_quartile_one_star_pct", "value": round(quartile_one_star_pct, 2)},
        {"metric": "lower_quartile_revenue_pct", "value": round(quartile_revenue_pct, 2)},
    ])
    tradeoff.round(4).to_csv(EXPORT_DIR / "cutoff_tradeoff.csv", index=False)
    summary.to_csv(EXPORT_DIR / "cutoff_summary.csv", index=False)

    con.register("tradeoff_frame", tradeoff)
    con.execute("CREATE OR REPLACE TABLE seller_cutoff_tradeoff AS SELECT * FROM tradeoff_frame")
    con.register("quadrant_frame", sellers[["seller_id", "quadrant", "is_below_cutoff"]])
    con.execute("CREATE OR REPLACE TABLE seller_quadrants AS SELECT * FROM quadrant_frame")
    con.close()


if __name__ == "__main__":
    main()
