# Mosquitto Standalone — lokales Home-Assistant-Add-on mit wirksamer Datei-ACL

**Problem:** Das offizielle Mosquitto-Add-on von Home Assistant (≥ 7.0,
Mosquitto 2.1) setzt Datei-ACLs aus dem customize-Mechanismus
stillschweigend nicht mehr durch: sein go-auth-Plugin beantwortet
ACL-Prüfungen vor Mosquittos builtin-security-Plugin und erlaubt jedem
gültigen Login alles
([home-assistant/addons#4571](https://github.com/home-assistant/addons/issues/4571)).
Die ACL-Datei wird geladen — und ignoriert.

**Lösung:** Dieses Repository verpackt **Stock-Eclipse-Mosquitto** als
*lokales* Home-Assistant-Add-on. Kein go-auth: Authentifizierung läuft
ausschließlich über `password_file`, Autorisierung über `acl_file` —
beides greift wirklich. Das Add-on bleibt Supervisor-verwaltet (Backups,
Watchdog, Lebenszyklus), anders als ein roher Docker-Container, den HAOS
als „unsupported" einstuft.

> ## ⚠ Haftungsausschluss — Nutzung auf eigene Gefahr
>
> Dieses Projekt ersetzt ein Kernstück deiner Hausautomations-Infrastruktur:
> den MQTT-Broker. **Sei vorsichtig.** Teste im Parallelbetrieb, verifiziere
> gründlich vor dem Cutover und halte den Rollback-Pfad bereit. Der Ansatz
> hat bei *meiner* Installation funktioniert — er muss nicht zu deiner
> passen. Alles hier wird **ohne jede Garantie oder Gewährleistung**
> bereitgestellt (siehe [LICENSE](LICENSE)). Ich pflege das als geteilten
> Workaround mit sehr begrenzter Kapazität: keine Zusagen zu Support,
> Fixes oder zeitnahen Reaktionen auf Issues/PRs. Für Änderungen an deinem
> System bist du allein verantwortlich.

**Migration:** Das mitgelieferte Deploy-Script orchestriert einen
risikoarmen Umstieg: neuer Broker parallel auf einem Alternativ-Port,
vollständige Übernahme des Retained-Bestands per MQTT-Bridge,
Verifikation (inkl. empirischem ACL-Negativtest), dann Cutover mit
wenigen Sekunden Downtime — mit trivialem Rollback-Pfad.

## Dokumentation

Der vollständige, nachbaubare Ablauf (Ansatz, Teststrategie,
Phasen-Migration, Stolperstein-Tabelle aus einem echten Deploy):

- **[docs/migration-guide.de.md](docs/migration-guide.de.md)** (Deutsch)
- **[docs/migration-guide.en.md](docs/migration-guide.en.md)** (English)

English version of this README: [README.md](README.md)

## Schnellstart

Voraussetzungen: HAOS-Host mit SSH-Zugang (`ha`-CLI + `jq`, `/addons`
beschreibbar — das offizielle SSH-Add-on bringt alles mit) und eine
bestehende mTLS-PKI, falls `require_certificate` genutzt wird (Pfade sind
Add-on-Optionen).

```bash
cp deploy.conf.example .local/deploy.conf   # dann anpassen
./scripts/deploy.sh                          # Status beider Add-ons
./scripts/deploy.sh --install --with-bridge --apply  # Migration: bauen +
                                             # parallel auf :18883, Bridge armiert
./scripts/deploy.sh --install --apply        # Re-Run/Repair OHNE Bridge
./scripts/deploy.sh --update --apply         # neue Add-on-Version ausrollen
./scripts/deploy.sh --cutover                # Cutover-Plan ansehen
./scripts/deploy.sh --cutover --apply        # Produktionsport übernehmen
./scripts/deploy.sh --rollback --apply       # zurück zum offiziellen Add-on
./scripts/deploy.sh --verify-acl             # ACL-Enforcement-Nachweis
```

Jede Phase ist ohne `--apply` ein Dry-Run. **Install** ist gefahrlos:
der neue Broker läuft parallel, der alte bleibt unberührt, Logins werden
serverseitig per Supervisor-API übernommen (Passwörter verlassen den Host
nie). Die Migrations-Bridge wird **nur** mit `--with-bridge` armiert
(fail-safe Default — ein Re-Run von `--install` kann keine Selbst-Bridge
scharfschalten). **Cutover** kostet ~10 Sekunden; Clients reconnecten von
selbst, weil Adresse und PKI gleich bleiben.

`--update` und `--cutover` enden fail-closed mit dem scriptbaren
ACL-Nachweis (`--verify-acl`): Positivtest (Login mit `read #` muss auf
`#` liefern) plus Negativtest (write-only-Login darf **nichts** liefern).
Die `ACL-VERIFY`-Zeile (UTC + Commit) ist der wiederkehrende Beleg — nach
jedem Broker-Update/-Neustart erneut fahren. Konfiguration:
`VERIFY_SSH`/`VERIFY_LOGIN`/`VERIFY_NEG_LOGIN`/`VERIFY_TLS_ARGS` in
`.local/deploy.conf`; `--no-verify` ist der explizite Notausstieg.

## Lizenz

[MIT](LICENSE)
