"""
run_sql.py: führt eine SQL-Datei Anweisung für Anweisung gegen data/olist.duckdb aus.

Aufruf aus dem Repo-Root:
    python 02_python/run_sql.py 01_sql/00_load.sql

Jede Anweisung, die Zeilen zurückgibt (SELECT), wird als Tabelle ausgegeben.
So lassen sich alle SQL-Dateien des Projekts ohne DuckDB-Kommandozeile prüfen.
"""

import sys
from pathlib import Path

import duckdb
import pandas as pd

DB_PATH = Path("data/olist.duckdb")

# Ausgabe nicht abschneiden, damit auch breite Ergebnistabellen lesbar bleiben
pd.set_option("display.width", 220)
pd.set_option("display.max_columns", 40)
pd.set_option("display.max_rows", 300)


def run_sql_file(sql_path: Path, connection: duckdb.DuckDBPyConnection) -> None:
    sql_text = sql_path.read_text(encoding="utf-8")
    statements = connection.extract_statements(sql_text)
    print(f"=== {sql_path} ({len(statements)} Anweisungen) ===")

    result_number = 0
    for statement in statements:
        result = connection.execute(statement)
        columns = [column[0] for column in result.description] if result.description else []
        # DROP/CREATE/UPDATE liefern nur "Success" oder "Count" zurück, die
        # überspringen wir. Ausgegeben werden nur echte Abfrageergebnisse.
        if columns and columns not in (["Success"], ["Count"]):
            result_number += 1
            frame = result.fetchdf()
            print(f"\n--- Ergebnis {result_number} ({len(frame)} Zeilen) ---")
            print(frame.to_string(index=False))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Aufruf: python 02_python/run_sql.py <sql-datei> [weitere sql-dateien]")
        sys.exit(1)

    con = duckdb.connect(str(DB_PATH))
    for argument in sys.argv[1:]:
        run_sql_file(Path(argument), con)
    con.close()
