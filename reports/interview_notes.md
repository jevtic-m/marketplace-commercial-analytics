# Interview-Notizen

Je Arbeitspaket die typischen Interviewfragen, jede mit einer Antwort in zwei bis drei Sätzen, bezogen auf die echten Ergebnisse dieses Repos.

---

## AP1 / AP2 — Datenmodell und Joins

**Warum ist `customer_id` nicht der Kunde?**
`customer_id` wird bei Olist für jede Bestellung neu vergeben, es ist also eigentlich eine Bestell-Kunden-Kennung. Die reale Person steht in `customer_unique_id`: 99.441 `customer_id` gehören zu 96.096 Personen. Über `customer_id` gerechnet hätte jeder Kunde genau eine Bestellung und die Wiederkaufrate wäre null; tatsächlich haben 2.997 Personen (3,12 %) mehr als einmal bestellt.

**Was passiert, wenn du `orders`, `order_items` und `order_payments` in einem Zug joinst?**
Jede Bestellung mit mehreren Positionen und mehreren Zahlungszeilen wird zum Kreuzprodukt: 3 Positionen mal 2 Zahlungszeilen ergibt 6 Zeilen. Summiert man dann `payment_value`, ist der Betrag dreifach gezählt. In diesem Datensatz liefert der naive Dreifach-Join 117.601 Zeilen statt 99.441 Bestellungen, und die Summe der Zahlungen steigt von 16,0 auf 20,3 Millionen BRL, also um 26,9 %. Das Gefährliche daran: Die Abfrage läuft ohne Fehlermeldung durch.

**Wie hast du das Fan-out-Problem gelöst?**
Durch Vorverdichtung vor dem Join: In `01_schema.sql` fassen drei getrennte CTEs die Positionen, die Zahlungen und die Bewertungen jeweils auf eine Zeile je `order_id` zusammen. Erst diese verdichteten Zwischenergebnisse werden per LEFT JOIN an `orders` gehängt. Die Kontrolle: `fact_orders` hat exakt 99.441 Zeilen wie `orders`, und die Umsatzsumme (13.591.643,70 BRL) stimmt auf den Cent mit der Summe über `order_items` überein.

**Warum zwei Faktentabellen statt einer?**
Weil zwei verschiedene Fragen zwei verschiedene Körnungen brauchen. Verkäufer und Produkt sind nur auf Positionsebene eindeutig (1.278 Bestellungen haben mehrere Verkäufer), Umsatz, Zahlung und Bewertung dagegen nur auf Bestellebene. `fact_order_items` bedient Produkt- und Verkäuferanalysen, `fact_orders` alles auf Bestellebene, und beide hängen über `order_id` zusammen.

**Wann nimmst du einen LEFT JOIN statt INNER JOIN, und was änderte das hier?**
LEFT JOIN, wenn die linke Seite vollständig bleiben muss, auch ohne Treffer rechts. Bei `fact_orders` hätte ein INNER JOIN auf die Positionen 775 Bestellungen entfernt, darunter 603 mit Status `unavailable` und 164 `canceled`, also genau die Fälle, die für die Stornoquote gebraucht werden. Ein INNER JOIN auf die Bewertungen hätte 768 weitere Bestellungen still verschwinden lassen.

---

## AP3 — Datenqualität

**Wie hast du geprüft, ob die Zahlungen zu den Bestellwerten passen?**
Ich habe je Bestellung die Summe aller Zahlungszeilen mit Warenwert plus Fracht verglichen und alle Abweichungen über 1 % gezählt. Das betrifft 254 von 98.665 Bestellungen (0,26 %), fast alle mit Kreditkarte, was zu Ratenzuschlägen passt; Gutscheine erklären die Abweichung nicht, weil sie als eigene Zahlungszeile mitlaufen. Deshalb ist Umsatz bei mir der Warenpreis, und der Zahlbetrag wird nur für Zahlungsanalysen verwendet.

**Warum hast du den Analysezeitraum beschnitten?**
Weil die Ränder keine echten Marktdaten sind, sondern Anlauf und Abschnitt des Datenabzugs: 329 Bestellungen vor 2017, fast alle im Oktober 2016, und nur 20 nach August 2018. In einer Monatskurve sähe das aus wie ein Start aus dem Nichts und ein Einbruch am Ende. Das Fenster Januar 2017 bis August 2018 behält 99,65 % aller Bestellungen.

**Wie gehst du mit Bestellungen um, die nie zugestellt wurden?**
Sie bleiben im Modell, aber nicht in der Lieferzeit- und Bewertungsanalyse, weil es keine Zustellung gibt, die man messen könnte. Stornierte und nicht lieferbare Bestellungen (1,19 % im Fenster) laufen als eigene Stornoquote, auch je Verkäufer. Dass sie im Schnitt nur mit 1,5 bis 1,8 Sternen bewertet werden, zeigt, warum man sie nicht einfach weglassen darf.
