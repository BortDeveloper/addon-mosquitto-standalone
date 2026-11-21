# local.beispiel/ – Beispielzustand der privaten Daten

Dieser Ordner ist versioniert und enthält **nur synthetische Beispiele** (stack-master ADR-0044).
Er macht einen frischen Checkout lauffähig, ohne dass private Daten im Repo stehen.

| Zustand | `.local` zeigt auf | Wann |
|---|---|---|
| Beispielzustand | `local.beispiel/` (dieser Ordner) | frischer Checkout, noch keine privaten Daten |
| Betrieb | `~/.local/share/<projekt>/` (unter Windows im Benutzerprofil) | private Daten vorhanden, z. B. aus dem Backup geholt |

`.local` ist immer ein Link (unter Windows eine Junction), nie ein Ordner im Arbeitsbaum, und steht in
`.gitignore`. Den Link legt `control-plane/kit/installieren.sh <repo>` an.

## Private Daten holen

1. Den Projektstand aus dem Backup in ein leeres Verzeichnis wiederherstellen
   (`ctl-agent restore <projekt> --nach <leer>`), dann den Ordner `<daten>/<projekt>` aus der
   Wiederherstellung nach `~/.local/share/<projekt>/` verschieben.
2. `bash control-plane/kit/installieren.sh <repo>` erneut ausführen. Das Skript stellt `.local` von
   `local.beispiel/` auf `~/.local/share/<projekt>/` um. Es entfernt dabei nur den Link, nie Inhalte.

## Regeln

- Hier nur Werte, die erkennbar Beispiele sind: Adressen aus RFC 5737 (`192.0.2.x`, `198.51.100.x`,
  `203.0.113.x`), Domains `*.example`/`*.invalid`/`*.test`, Namen wie `Musterdorf` und Platzhalter wie `<name>`.
- Jede Datei, die Skripte unter `.local/` erwarten, hat hier ein gültiges Beispiel mit derselben Form.
- Der Datenwächter prüft diesen Ordner wie jeden anderen; im Beispielzustand gilt nur die (leere) Beispiel-
  Prüfliste, er meldet das als Hinweis.
