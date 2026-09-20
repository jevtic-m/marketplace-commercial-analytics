# Interview-Notizen

Je Arbeitspaket die typischen Interviewfragen, jede mit einer Antwort in zwei bis drei Sätzen, bezogen auf die echten Ergebnisse dieses Repos.

---

## AP1 / AP2 — Datenmodell und Joins

**Warum ist `customer_id` nicht der Kunde?**
`customer_id` wird bei Olist für jede Bestellung neu vergeben, es ist also eigentlich eine Bestell-Kunden-Kennung. Die reale Person steht in `customer_unique_id`: 99.441 `customer_id` gehören zu 96.096 Personen. Über `customer_id` gerechnet hätte jeder Kunde genau eine Bestellung und die Wiederkaufrate wäre null; tatsächlich haben 2.997 Personen (3,12 %) mehr als einmal bestellt.

**Was passiert, wenn du `orders`, `order_items` und `order_payments` in einem Zug joinst?**
Jede Bestellung mit mehreren Positionen und mehreren Zahlungszeilen wird zum Kreuzprodukt: 3 Positionen mal 2 Zahlungszeilen ergibt 6 Zeilen. Summiert man dann `payment_value`, ist der Betrag dreifach gezählt. Im Datensatz betrifft das 9.803 Bestellungen mit mehreren Positionen und 2.961 mit mehreren Zahlungszeilen. [Konkrete Zeilenzahl des Fan-out folgt in AP3.]

**Wie hast du das Fan-out-Problem gelöst?**
[folgt in AP2]

**Warum zwei Faktentabellen statt einer?**
[folgt in AP2]

**Wann nimmst du einen LEFT JOIN statt INNER JOIN, und was änderte das hier?**
[folgt in AP2]
