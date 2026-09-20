"""
01_data_prep.py: baut die DuckDB-Datei von den Roh-CSVs bis zum Star-Schema auf.

Aufruf aus dem Repo-Root:
    python 02_python/01_data_prep.py

Schritte:
    1. 01_sql/00_load.sql      Roh-CSVs in data/olist.duckdb laden
    2. 01_sql/01_schema.sql    Star-Schema (Dimensionen und Faktentabellen) bauen
    3. Drei Pflichtprüfungen, bei denen das Skript mit Fehler abbricht:
       - fact_orders hat genauso viele Zeilen wie orders (kein Fan-out, kein Verlust)
       - Wiederkaufrate über customer_unique_id ist größer als null
       - 01_sql/02_validation.sql läuft fehlerfrei durch
"""

import sys
from pathlib import Path

import duckdb

# Der SQL-Runner liegt im selben Ordner; so lässt er sich importieren.
sys.path.insert(0, str(Path(__file__).parent))
from run_sql import DB_PATH, run_sql_file  # noqa: E402

SQL_DIR = Path("01_sql")


def run_checks(connection: duckdb.DuckDBPyConnection) -> None:
    """Die drei Pflichtprüfungen. Jede schlägt laut fehl, statt still weiterzulaufen."""

    n_orders_raw = connection.execute("SELECT COUNT(*) FROM orders").fetchone()[0]
    n_fact_orders = connection.execute("SELECT COUNT(*) FROM fact_orders").fetchone()[0]
    print(f"Prüfung 1: orders = {n_orders_raw:,} Zeilen, fact_orders = {n_fact_orders:,} Zeilen")
    if n_orders_raw != n_fact_orders:
        raise SystemExit("FEHLER: fact_orders hat nicht dieselbe Zeilenzahl wie orders.")

    n_customers, n_repeat = connection.execute(
        """
        SELECT COUNT(*) AS n_customers,
               COUNT(*) FILTER (WHERE n_orders > 1) AS n_repeat
        FROM (
            SELECT customer_unique_id, COUNT(*) AS n_orders
            FROM fact_orders
            GROUP BY customer_unique_id
        )
        """
    ).fetchone()
    repeat_rate = n_repeat / n_customers
    print(f"Prüfung 2: Wiederkaufrate = {n_repeat:,} von {n_customers:,} Kunden = {repeat_rate:.2%}")
    if repeat_rate <= 0:
        raise SystemExit("FEHLER: Wiederkaufrate ist null. Vermutlich wurde customer_id statt customer_unique_id verwendet.")

    validation_sql = (SQL_DIR / "02_validation.sql").read_text(encoding="utf-8")
    statements = connection.extract_statements(validation_sql)
    for statement in statements:
        connection.execute(statement).fetchall()
    print(f"Prüfung 3: 02_validation.sql läuft fehlerfrei ({len(statements)} Anweisungen)")


if __name__ == "__main__":
    con = duckdb.connect(str(DB_PATH))
    run_sql_file(SQL_DIR / "00_load.sql", con)
    run_sql_file(SQL_DIR / "01_schema.sql", con)
    print()
    run_checks(con)
    con.close()
    print("\nDatenaufbereitung abgeschlossen: data/olist.duckdb ist bereit.")
