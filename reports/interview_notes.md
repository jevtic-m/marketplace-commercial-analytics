# Interview-Notizen

Je Arbeitspaket die typischen Interviewfragen, jede mit einer Antwort in zwei bis drei Sätzen, bezogen auf die echten Ergebnisse dieses Repos.

---

## AP1 / AP2 — Datenmodell und Joins

**Warum ist `customer_id` nicht der Kunde?**
`customer_id` wird bei Olist für jede Bestellung neu vergeben, es ist also eigentlich eine Bestell-Kunden-Kennung. Die reale Person steht in `customer_unique_id`: 99.441 `customer_id` gehören zu 96.096 Personen. Über `customer_id` gerechnet hätte jeder Kunde genau eine Bestellung und die Wiederkaufrate wäre null; tatsächlich haben 2.997 Personen (3,12 %) mehr als einmal bestellt.

**Was passiert, wenn du `orders`, `order_items` und `order_payments` in einem Zug joinst?**
Jede Bestellung mit mehreren Positionen und mehreren Zahlungszeilen wird zum Kreuzprodukt: 3 Positionen mal 2 Zahlungszeilen ergibt 6 Zeilen. Summiert man dann `payment_value`, ist der Betrag dreifach gezählt. Im Datensatz betrifft das 9.803 Bestellungen mit mehreren Positionen und 2.961 mit mehreren Zahlungszeilen. [Konkrete Zeilenzahl des Fan-out folgt in AP3.]

**Wie hast du das Fan-out-Problem gelöst?**
Durch Vorverdichtung vor dem Join: In `01_schema.sql` fassen drei getrennte CTEs die Positionen, die Zahlungen und die Bewertungen jeweils auf eine Zeile je `order_id` zusammen. Erst diese verdichteten Zwischenergebnisse werden per LEFT JOIN an `orders` gehängt. Die Kontrolle: `fact_orders` hat exakt 99.441 Zeilen wie `orders`, und die Umsatzsumme (13.591.643,70 BRL) stimmt auf den Cent mit der Summe über `order_items` überein.

**Warum zwei Faktentabellen statt einer?**
Weil zwei verschiedene Fragen zwei verschiedene Körnungen brauchen. Verkäufer und Produkt sind nur auf Positionsebene eindeutig (1.278 Bestellungen haben mehrere Verkäufer), Umsatz, Zahlung und Bewertung dagegen nur auf Bestellebene. `fact_order_items` bedient Produkt- und Verkäuferanalysen, `fact_orders` alles auf Bestellebene, und beide hängen über `order_id` zusammen.

**Wann nimmst du einen LEFT JOIN statt INNER JOIN, und was änderte das hier?**
LEFT JOIN, wenn die linke Seite vollständig bleiben muss, auch ohne Treffer rechts. Bei `fact_orders` hätte ein INNER JOIN auf die Positionen 775 Bestellungen entfernt, darunter 603 mit Status `unavailable` und 164 `canceled`, also genau die Fälle, die für die Stornoquote gebraucht werden. Ein INNER JOIN auf die Bewertungen hätte 768 weitere Bestellungen still verschwinden lassen.
