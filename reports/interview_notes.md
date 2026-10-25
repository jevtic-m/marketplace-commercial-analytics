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

---

## AP4 / AP5 — Analysen

**Was ist der Unterschied zwischen Lieferzeit und Lieferverzug, und welcher ist für die Zufriedenheit relevant?**
Lieferzeit ist die Dauer vom Kauf bis zur Zustellung, im Schnitt 12,6 Tage. Lieferverzug ist die Differenz zwischen tatsächlichem und versprochenem Zustelldatum, also ob die Zusage gehalten wurde. Für die Bewertung ist der Verzug die stärkere Größe: Pünktliche Lieferungen bekommen 4,29 Sterne, mehr als eine Woche Verzug nur 1,70 Sterne. Die Gegenprobe zeigt, dass auch die Dauer zählt, aber viel weniger: Bei gleicher Dauer geht ein gebrochenes Versprechen mit 1,54 Sternen weniger einher, eine Woche längere Lieferung nur mit 0,15 Sternen.

**Wie hast du die Lieferzeit zerlegt, und warum?**
In drei Abschnitte entlang der Zeitstempel: Zahlungsfreigabe (0,4 Tage), Bearbeitung beim Verkäufer bis zur Übergabe an die Logistik (2,8 Tage) und Transport bis zum Kunden (9,4 Tage). Die Zerlegung zeigt, wer welchen Hebel hat: Die Bearbeitung ist in allen Regionen gleich, der Unterschied zwischen 7,6 Tagen Transport im Sudeste und 19,3 Tagen im Norte liegt bei der Logistik, nicht bei den Verkäufern.

**Dein Befund zeigt: späte Lieferung, schlechte Bewertung. Ist das kausal?**
Nein, nachgewiesen ist ein Zusammenhang. Er ist stark und robust: Er hält bei Bestellungen mit nur einer Position (2,08 Sterne Abstand) und in jeder Region (1,93 bis 2,07 Sterne). Für einen Kausalnachweis bräuchte es aber ein Experiment oder eine Situation, in der Verzug zufällig entsteht, etwa ein Streik beim Logistiker, und das gibt der Datensatz nicht her.

**Welche Störfaktoren könnten beides erklären?**
Ein nachlässiger Verkäufer verschickt spät und packt schlecht, Kunden in entlegenen Regionen bekommen längere Wege und schlechteren Service, und defekte oder falsch beschriebene Ware führt zu Rücksendungen, die als Verzug erscheinen. Dass es weitere Treiber gibt, zeigen die Daten selbst: Bestellungen mit mehreren Verkäufern sind fast nie verspätet (0,95 %), werden aber im Schnitt nur mit 2,86 Sternen bewertet.

---

## AP6 — Scorecard und Cutoff

**Wie hast du die Gewichte der Scorecard gewählt?**
Gesetzt und begründet, nicht optimiert: Bewertung 40 %, Verspätung 30 %, Bearbeitungszeit 15 %, Stornoquote 15 %. Die Bewertung ist das direkte Kundenurteil, die Verspätung der stärkste Begleiter schlechter Bewertungen aus meiner Lieferanalyse. Dass das Ergebnis nicht an diesen Zahlen hängt, habe ich geprüft: Mit gleichen Gewichten korreliert das Ranking zu 0,98 mit meinem, und das untere Quartil bleibt zu 88 % dieselbe Gruppe.

**Was machst du mit Verkäufern, die nur drei Bestellungen hatten?**
Ich dämpfe ihre Kennzahlen zum Marktschnitt: gedämpfter Wert = (n mal eigener Wert plus k mal Marktschnitt) geteilt durch (n plus k). Die Stärke k schätze ich aus den Daten, für die Bewertung sind das rund 26 Bestellungen. Ein Verkäufer mit drei Fünf-Sterne-Bewertungen bekommt deshalb 4,26 statt 5,0 und landet nahe am Durchschnitt, wo er hingehört, solange man wenig über ihn weiß.

**Wie würdest du den optimalen Cutoff bestimmen, wenn du die Marge je Bestellung kennst?**
Ich würde für jede Schwelle den Gewinn rechnen: Marge auf den verbleibenden Umsatz minus die Kosten der verbleibenden Ein-Stern-Erlebnisse (Kundenservice, verlorene Folgekäufe, Ruf), und die Schwelle mit dem höchsten Gewinn wählen. Bei Score 62 kostet der Ausschluss 636.001 BRL Umsatz und vermeidet 902 Ein-Stern-Bewertungen, also rund 705 BRL Umsatz je vermiedener Bewertung. Bei 20 % Marge lohnt er sich nur, wenn eine Ein-Stern-Bewertung den Marktplatz mehr als etwa 141 BRL kostet.

**Was spricht dagegen, einfach alle schlecht bewerteten Verkäufer auszuschließen?**
Erstens Zufall: 60 % der Verkäufer haben weniger als 10 Bestellungen, ihre Durchschnittsbewertung schwankt stark. Zweitens wirkt es weniger als gedacht: Mit einem Score aus 2017 entfallen in 2018 nur 3,3 % der Ein-Stern-Bewertungen bei 2,2 % Umsatz, die Durchschnittsbewertung steigt um 0,01 Sterne. Drittens hängen schlechte Bewertungen stark am gebrochenen Lieferversprechen, das teils bei der Logistik liegt, und 27 große, schwache Verkäufer mit 4,4 % Umsatz verliert man ungern ohne Qualitätsprogramm.

---

## AP7 / AP8 — Dashboard und Empfehlung

**An wen richtet sich dein Dashboard, und woran erkennt man das?**
Jede Seite hat eine Zielgruppe und eine Frage: der Überblick an Geschäftsführung und Category Management (Wachstum, Kategorien, Regionen), Operations an die Logistik (Lieferzeit-Zerlegung, Verspätung, Bewertung nach Verzug), die Verkäuferseite an das Seller Management (Quadranten, Scorecard), der Cutoff-Simulator an die Marktplatz-Leitung. Man erkennt es an den Kennzahlen und Reglern: Die Logistik sieht Tage und Verspätungsquoten, die Leitung sieht Umsatzverlust gegen vermiedene Ein-Stern-Bewertungen und kann die Schwelle selbst verschieben.

**Welche deiner drei Empfehlungen ist die teuerste in der Umsetzung?**
Die regionale Lagerhaltung für den Nordosten: Sie braucht Fläche, Bestand und neue Prozesse, bevor ein einziger Real Fracht gespart ist. Am günstigsten ist die Anpassung der Lieferzusagen, technisch nur eine Konfiguration; ihr Risiko liegt woanders, weil eine längere Zusage Käufe kosten kann, deshalb der A/B-Test. Das Qualitätsprogramm für Verkäufer liegt dazwischen und kostet vor allem Personal für Betreuung und Nachverfolgung.

**Was würdest du als Nächstes analysieren, wenn du mehr Zeit hättest?**
Erstens die Kommentartexte der Bewertungen: Damit ließe sich trennen, ob ein Ein-Stern-Urteil an der Lieferung oder am Produkt hängt, und das wäre der direkteste Weg zu den Störfaktoren. Zweitens Margendaten, um den Cutoff über Gewinn statt über ein Umsatzbudget zu wählen. Drittens ein Vorhersagemodell für schlechte Bewertungen auf Bestellebene, mit strenger Trennung nach Zeit, weil die Gegenprobe gezeigt hat, wie stark ein Score aus der Vergangenheit an Wirkung verliert.

---

## Die 90-Sekunden-Story

> Ein Online-Marktplatz verkauft nichts selbst, er haftet mit seinem Ruf für tausende Verkäufer. Meine Frage war, wo dabei Kundenzufriedenheit und Geld verloren gehen.
>
> Grundlage waren rund 99.000 echte Bestellungen eines brasilianischen Marktplatzes in neun verknüpften Tabellen: Bestellungen, Positionen, Zahlungen, Bewertungen, Verkäufer, Produkte, Geodaten.
>
> Der erste Schritt war ein sauberes Datenmodell. Wer Bestellungen, Positionen und Zahlungen naiv zusammenjoint, bekommt hier 117.601 statt 99.441 Zeilen und überhöht die Zahlungen um 27 %, ohne Fehlermeldung. Und von den zwei Kundenkennungen identifiziert nur eine die reale Person; mit der falschen ist die Wiederkaufrate null statt drei Prozent.
>
> Der zentrale Befund: Kunden stört weniger die lange Lieferung als das gebrochene Versprechen. Pünktliche Lieferungen bekommen im Schnitt 4,29 Sterne, mehr als eine Woche Verzug 1,70. Bei gleicher Lieferdauer kostet ein gebrochenes Versprechen 1,5 Sterne, eine Woche mehr Dauer nur 0,15. Das ist ein Zusammenhang, kein Beweis, aber er hält in jeder Region und bei Einzelbestellungen.
>
> Daraus habe ich eine Verkäufer-Scorecard gebaut und einen Regler: Die 62 Verkäufer unter Score 62 tragen 9,7 % der Ein-Stern-Bewertungen bei 4,8 % des Umsatzes. Aber ein Ausschluss hebt die Durchschnittsbewertung nur um 0,03 Sterne, und mit einem Score aus dem Vorjahr bleibt ein Drittel davon übrig. Die Empfehlung lautet deshalb: wenige Verkäufer gezielt coachen und Lieferzusagen realistisch setzen, vor allem im Nordeste, wo jede achte Lieferung zu spät kommt.
>
> Gelernt habe ich, dass die eigentliche Arbeit im Datenmodell steckt, und dass eine ehrliche Gegenprobe eine schöne Schlagzeile manchmal kleiner macht. Genau das ist ihr Wert.
