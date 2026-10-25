"""
chart_style.py: gemeinsamer Diagrammstil für alle Python-Skripte.

Ein Ort für Farben und Achsenformat, damit alle Charts im Repo gleich aussehen.
Die Farben sind farbfehlsichtigkeits-geprüft: Blau und Orange sind auch bei
Rot-Grün-Schwäche gut zu unterscheiden. Für geordnete Klassen (zum Beispiel
Verzugsklassen) gibt es eine einfarbige Blau-Rampe von hell nach dunkel.
"""

import matplotlib

matplotlib.use("Agg")  # Charts nur als Datei speichern, kein Fenster öffnen
import matplotlib.pyplot as plt  # noqa: E402

SURFACE = "#fcfcfb"
TEXT_PRIMARY = "#0b0b0b"
TEXT_SECONDARY = "#52514e"
GRID = "#e4e3df"

BLUE = "#2a78d6"     # erste Reihe
ORANGE = "#eb6834"   # zweite Reihe
AQUA = "#1baf7a"     # dritte Reihe

# Einfarbige Rampe für geordnete Klassen (hell = wenig, dunkel = viel)
BLUE_RAMP_4 = ["#86b6ef", "#5598e7", "#256abf", "#104281"]
BLUE_RAMP_5 = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#104281"]

FIGURE_DIR = "reports/figures"


def apply_style() -> None:
    """Zurückhaltende Achsen, dünnes Gitter, lesbare Schrift."""
    plt.rcParams.update({
        "figure.facecolor": SURFACE,
        "axes.facecolor": SURFACE,
        "savefig.facecolor": SURFACE,
        "axes.edgecolor": GRID,
        "axes.labelcolor": TEXT_SECONDARY,
        "axes.titlecolor": TEXT_PRIMARY,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.titlelocation": "left",
        "axes.labelsize": 10,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.axisbelow": True,
        "grid.color": GRID,
        "grid.linewidth": 0.8,
        "xtick.color": TEXT_SECONDARY,
        "ytick.color": TEXT_SECONDARY,
        "xtick.labelsize": 9,
        "ytick.labelsize": 9,
        "legend.frameon": False,
        "legend.fontsize": 9,
        "font.size": 10,
        "figure.dpi": 110,
    })


def save_figure(fig, file_name: str) -> str:
    """Speichert ein Diagramm unter reports/figures/ und gibt den Pfad zurück."""
    path = f"{FIGURE_DIR}/{file_name}"
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"Diagramm gespeichert: {path}")
    return path
