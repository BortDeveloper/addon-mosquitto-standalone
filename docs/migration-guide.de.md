# Mosquitto-ACLs unter Home Assistant OS wirklich durchsetzen — Ansatz, Teststrategie und unterbrechungsarmer Umstieg

> Dieses Dokument beschreibt einen nachvollziehbaren, nachbaubaren Weg, den
> MQTT-Broker einer Home-Assistant-OS-Installation vom offiziellen
> Mosquitto-Add-on auf ein **eigenes lokales Add-on mit Stock-Mosquitto**
> umzustellen — mit funktionierender Datei-ACL, vollständiger Übernahme der
> Retained-Messages und wenigen Sekunden Downtime. Alle Namen, Adressen und
> Topics sind Platzhalter; passe sie an deine Umgebung an.
> English version: [migration-guide.en.md](migration-guide.en.md)
>
> ⚠ **Nutzung auf eigene Gefahr.** Du ersetzt den zentralen MQTT-Broker
> deiner Hausautomation. Teste im Parallelbetrieb, verifiziere vor dem
> Cutover, halte den Rollback-Pfad bereit. Das Vorgehen hat bei meiner
> Installation funktioniert und wird **ohne jede Garantie** und mit sehr
> begrenzter Support-Kapazität geteilt — für dein System bist du allein
> verantwortlich.

## 1. Das Problem

Das offizielle Mosquitto-Add-on von Home Assistant unterstützt seit jeher
eine Datei-ACL über den customize-Mechanismus (`acl_file` in einer
`*.conf`-Datei unter `/share/mosquitto/`). Seit Add-on-Version **7.0**
(Mosquitto 2.1) wird diese ACL jedoch **stillschweigend nicht mehr
durchgesetzt**: In Mosquitto 2.1 wanderte `acl_file` in das
builtin-security-Plugin, und das go-auth-Plugin des Add-ons beantwortet
ACL-Prüfungen **vor** diesem Plugin — mit „erlaubt" für jeden gültigen
Login. Die Datei wird geladen (sie taucht im Log auf), hat aber keinerlei
Wirkung. Upstream-Bug:
[home-assistant/addons#4571](https://github.com/home-assistant/addons/issues/4571).

**So stellst du fest, ob es dich betrifft** (empirischer Negativtest — nicht
auf das Log verlassen, Mosquitto verwirft ACL-Verstöße kommentarlos):

```bash
# Als ein Login, der laut ACL NUR schreiben darf (write-only):
mosquitto_sub -h <broker> -p 8883 <tls-optionen> \
  -u <write-only-login> -P <pass> -t '#' -W 10 -v
# Erwartung bei wirksamer ACL: nichts.
# Bug-Fall: die komplette Retained-Flut aller Topics.

# Gegenprobe Schreibrichtung — Publish auf ein verbotenes Topic,
# dann selbst wieder abonnieren:
mosquitto_pub ... -t test/aclcheck -m x -r
mosquitto_sub ... -t test/aclcheck -W 5
# Bug-Fall: die Nachricht kommt an. (Danach aufräumen: mosquitto_pub ... -r -n)
```

## 2. Lösungsansatz: eigenes lokales Add-on mit Stock-Mosquitto

Zwei naheliegende Alternativen scheiden aus:

- **Downgrade auf Add-on 6.5.2**: der Supervisor unterstützt kein sauberes
  Downgrade von Store-Add-ons; man bleibt dauerhaft auf einer alten Version.
- **Roher Docker-Container auf HAOS**: technisch möglich, aber der
  Supervisor stuft fremde Container als „unsupported" ein (kann Updates
  blockieren), und der Container ist von Backups, Watchdog und
  Lebenszyklus-Verwaltung ausgenommen.

Der saubere Weg ist ein **lokales Add-on**: derselbe Container, aber
Supervisor-verwaltet (Backups, Watchdog, Start/Stop, Port-Verwaltung).
Kernidee:

- Basis-Image **`eclipse-mosquitto`**, gepinnt auf **exakt die
  Mosquitto-Version, die auch das offizielle Add-on ausliefert** (z. B.
  `2.1.2-alpine`). Der Umstieg ist damit ein reiner Auth-Plugin-Tausch
  (go-auth raus, builtin-security rein), kein Broker-Versionssprung.
- **Kein go-auth**: Authentifizierung ausschließlich über `password_file`,
  Autorisierung über `acl_file` — beides greift dann wirklich.
- Die **Logins bleiben Add-on-Optionen** (wie beim offiziellen Add-on) und
  werden beim Umstieg serverseitig per Supervisor-API kopiert — Passwörter
  verlassen den Host nie.
- Ein Startscript (`run.sh`) generiert beim Start `mosquitto.conf` und die
  gehashte Passwortdatei aus den Optionen und `exec`t Mosquitto.

Repo-Struktur (siehe dieses Repository):

```
<addon-ordner>/
├── config.yaml   # Add-on-Manifest: Ports, Mappings, Optionen + Schema
├── Dockerfile    # FROM eclipse-mosquitto:<version>-alpine + jq + run.sh
└── run.sh        # generiert Konfig + Passwortdatei, startet mosquitto
scripts/deploy.sh # Orchestrierung: install / update / cutover / rollback
```

### Design-Entscheidungen im Detail

**Passwortdatei ohne Klartext auf argv.** `mosquitto_passwd -b` nimmt das
Passwort als Kommandozeilen-Argument — vermeidbar: erst eine
`user:passwort`-Klartextdatei mit `umask 077` schreiben (per `jq` aus
`/data/options.json`), dann **`mosquitto_passwd -U datei`** in-place
hashen. Kein Secret erscheint je in einer Prozessliste.

**Mosquitto als root.** TLS-Keys und die ACL-Datei liegen typischerweise
`600 root:root`; das Add-on-Datenverzeichnis gehört root. Ein
Privilege-Drop würde Persistenz und Datei-Zugriffe brechen — das
offizielle Add-on läuft aus demselben Grund als root (die Log-Warnung ist
bekannt und akzeptiert). Konsequenz: **kein SIGHUP-Reload** verwenden;
Konfig-/ACL-Änderungen immer per Add-on-Neustart ausrollen.

**ACL als Fremd-SSOT.** Die ACL-Datei bleibt dort, wo sie schon liegt
(`/share/mosquitto/…`), gepflegt von ihrem bisherigen Deploy-Prozess. Das
Add-on mappt `share` **read-only** und konsumiert sie nur.

**mTLS unverändert.** Wer den Broker bereits mit `require_certificate`
betreibt, übernimmt Zertifikatspfade als Add-on-Optionen (Mapping
`ssl:ro`). Adresse und PKI bleiben beim Umstieg identisch — deshalb
merken die Clients vom Tausch nichts außer einem Reconnect.

**Wichtig: `max_queued_messages` anheben.** Mosquittos Default (1000)
verwirft bei großen Retained-Beständen (mehrere tausend Messages) Teile
der Retained-Flut, wenn ein Client breite Wildcards abonniert — beobachtet
als `Outgoing messages are being dropped for client …`. Für Installationen
mit vielen Retained-Topics großzügig dimensionieren (z. B. `10000`).

**Defensive Härtung.** Alle Option-Werte, die in die generierte
`mosquitto.conf` interpoliert werden, von Zeilenumbrüchen befreien und
Datei-Pfad-Optionen auf die gemappten Volumes (`/ssl`, `/share`)
beschränken — ein eingebetteter Newline würde sonst beliebige
Broker-Direktiven injizieren. Dem Broker Ressourcen-Grenzen geben
(`max_connections`, `message_size_limit`, `max_queued_bytes` als
Byte-Deckel zur `max_queued_messages`-Zahl). Basis-Image auf den
Manifest-List-Digest und CI-Actions auf Release-Tag-SHAs pinnen; die CI
sowohl die Dockerfile-Konfiguration als auch das gebaute Image auf CVEs
scannen lassen — Gate nur auf CRITICAL, denn der Digest-Pin friert den
CVE-Stand ein und eine rote CI soll heißen: „Zeit für einen bewussten
Basis-Image-Bump".

## 3. Migrationsstrategie: parallel aufbauen, verifizieren, dann umschalten

Der gesamte Umstieg gliedert sich in Phasen, die einzeln risikolos sind
und jederzeit abgebrochen werden können:

### Phase 1 — Parallelbetrieb (kein Risiko für den Bestand)

1. Add-on-Ordner nach `/addons/` kopieren, Store-Reload, installieren.
   Praxis-Hinweis: auf neueren Supervisor-Versionen (2026+, CLI-Umbenennung
   „addons" → „apps") ist `ha addons reload` wirkungslos — die
   **Supervisor-REST-API** ist der stabile Weg:
   `POST /store/reload`, dann `POST /store/addons/local_<slug>/install`.
2. Das neue Add-on lauscht auf einem **alternativen Host-Port**
   (z. B. 18883 statt 8883) — der Alt-Broker läuft unverändert weiter.
3. **Logins serverseitig kopieren**: Optionen des alten Add-ons per API
   lesen, `logins`-Liste in die Optionen des neuen Add-ons mergen. Die
   Passwörter verlassen den Host nie (der Merge läuft per SSH auf dem Host
   selbst, wo das Supervisor-Token liegt).
4. **Migrations-Bridge**: Das neue Add-on verbindet sich als
   Bridge-*Client* zum Alt-Broker und importiert alles:

   ```
   connection migration
   address <broker-lan-ip>:8883
   topic # in 0
   cleansession true
   notifications false
   ```

   MQTT-Bridges erhalten das Retain-Flag — damit wandert der **komplette
   Retained-Bestand** (Gerätestatus, Steuer-Flags, …) verlustfrei und
   bleibt während des Parallelbetriebs laufend synchron. Die Bridge
   braucht keinen eingehenden Port; sie ist eine ausgehende Verbindung.

### Phase 2 — Verifikation im Parallelbetrieb

Alle Tests laufen gegen den neuen Broker auf dem Alternativ-Port, während
die Produktion unberührt weiterläuft:

1. **Retained-Vollständigkeit**: Anzahl Retained-Messages alt vs. neu
   vergleichen (Messmethode: §4). Erwartung: identisch.
2. **Stichprobe kritischer Retained-Topics**: die Topics, an denen deine
   Automatisierung hängt (Steuer-Flags, Modus-Topics), gezielt abfragen.
3. **Negativtest** (der eigentliche Zweck des Ganzen): mit einem
   write-only-Login auf `#` subscriben — **muss leer bleiben**. Auf dem
   Alt-Broker schlägt derselbe Test im Bug-Fall fehl; das ist der
   Vorher/Nachher-Beweis.
4. **Positivtest**: ein read-berechtigter Login verbindet sich und sieht
   die erwarteten Topics.

### Phase 3 — Cutover (wenige Sekunden Downtime)

Die Reihenfolge ist sicherheitskritisch:

1. **Migrations-Bridge deaktivieren** (Add-on-Option) — **bevor** der
   Port wechselt. Sonst zeigt die Bridge-Adresse nach dem Wechsel auf den
   eigenen Broker: Selbst-Bridge-Schleife.
2. Altes Add-on **stoppen** und `boot=manual` setzen — sonst konkurrieren
   nach dem nächsten Host-Reboot zwei Broker um denselben Port.
3. Host-Port des neuen Add-ons auf den Produktionsport (8883) umziehen
   (Supervisor-API, `network`-Option).
4. Neues Add-on `boot=auto` setzen und **neu starten**.
5. Log beobachten: alle erwarteten Clients reconnecten von selbst, weil
   Adresse und Server-Zertifikat unverändert sind.

Downtime in der Praxis: ~10 Sekunden. MQTT-Clients reconnecten von selbst.

### Phase 4 — Nachkontrollen und Rollback-Pfad

- Client-Liste im Log vollständig? Keine `not authorised`-Einträge?
- **Negativtest jetzt auf dem Produktionsport wiederholen** — muss leer sein.
- Retained-Bestand erneut zählen (nach Broker-Neustart: die Zeile
  `Restored N retained messages` im Log ist die autoritative Zahl).
- Anwendungs-E2E im Alltag: Schalten, Sensorik, Logging.
- **Rollback** bleibt trivial, solange das alte Add-on installiert ist:
  neues Add-on stoppen und zurück auf den Alternativ-Port, altes Add-on
  starten und `boot=auto` setzen. Adresse/PKI unverändert → Clients
  reconnecten ebenso von selbst.

### Phase 5 — Follow-up: privilegierte Clients auf Least-Privilege-Logins umziehen

Der Cutover macht die ACL *durchsetzbar* — aber jeder Client, der noch
einen breiten `readwrite #`-Login nutzt, wird von ihr weiterhin nicht
eingeschränkt. Der übliche Kandidat ist die **HA-MQTT-Integration**
selbst, die historisch oft denselben „Superuser"-Login teilt, über den
auch die Automatisierungslogik läuft. Sie auf einen eigenen Login
umzuziehen (z. B. `read #` plus explizit aufgezählte write-Topics für
Statestream/Birth und die wenigen direkt publizierenden
Dashboard-Taster) ist der Schritt, mit dem die ACL für die exponierteste
Komponente wirklich greift.

Praxis-Hinweise:

- Die Zugangsdaten der Integration liegen in
  `/config/.storage/core.config_entries`. Datei sichern, nur den
  betroffenen Eintrag editieren (Username/Passwort), JSON validieren,
  dann `ha core restart`. (Der Reconfigure-Dialog der UI geht auch.)
- Im Broker-Log prüfen, dass die Integration mit dem neuen Login
  reconnectet (`u'<neuer-login>'`) und keine `not authorised`-Zeilen
  auftauchen.
- Nicht vergessen: **ACL-Drops sind stumm.** Wurde ein Schreibpfad in der
  Bestandsaufnahme übersehen, hört der betroffene Taster/die
  Automatisierung einfach auf zu funktionieren — das ist das Signal, eine
  bewusste ACL-Regel dafür zu ergänzen (und der Grund, warum jedes neue
  direkt publizierende Dashboard-Element eine brauchen sollte).
- Bei der Verifikation nicht vom Birth-Topic täuschen lassen: die
  Birth-Message der Integration ist per Default **nicht retained** — ein
  nachträglicher Subscribe zeigt nichts, selbst wenn alles funktioniert.

## 4. Teststrategie: Messen ohne sich selbst zu täuschen

Diese Punkte haben sich als entscheidend erwiesen:

**ACL-Verstöße erscheinen nicht im Log.** Mosquitto verwirft verbotene
Publishes kommentarlos und liefert bei verbotenen Subscriptions einfach
nichts. Die einzige belastbare Prüfung ist der empirische Negativ-/
Positivtest mit echten Client-Verbindungen (§1).

**Retained zählen — zwei Fallen.**

1. `mosquitto_sub --retained-only` trennt die Verbindung beim **ersten
   Live-Event**. Auf einem Broker mit laufendem Traffic bricht die Zählung
   also mitten in der Retained-Flut ab und liefert zufällig zu kleine,
   schwankende Werte. Robuster: normal subscriben und das Retain-Flag im
   Format-String auswerten:
   ```bash
   mosquitto_sub ... -F '%r' -t '#' -W 15 | grep -c '^1'
   ```
2. Selbst dann begrenzt `max_queued_messages` (Default 1000) die
   Zustellung der Flut an einen einzelnen Subscriber — erkennbar an
   `Outgoing messages are being dropped` im Broker-Log. Erst Limit
   anheben, dann messen. Schwankende Zählwerte bei wiederholter Messung
   sind das Leitsymptom für Zustell-Drops (ein stabiler Store liefert
   identische Zahlen).

**Autoritative Zahl nach Neustart.** `Restored N retained messages` beim
Broker-Start ist die verlässlichste Aussage über den Store-Inhalt —
unabhängig von Zustell-Effekten.

**Cert ≠ Login nutzen.** Bei mTLS mit separater Passwort-Auth darf ein
Testhost mit *irgendeinem* gültigen Client-Zertifikat verbinden und den
jeweils zu testenden Login per `-u/-P` wählen. So lassen sich Negativ- und
Positivtests von einem einzigen Messhost fahren.

## 5. Stolpersteine (gefunden beim echten Deploy)

| Stolperstein | Symptom | Lösung |
|---|---|---|
| Supervisor-CLI-Umbenennung (2026: „addons" → „apps") | `ha addons reload` lädt den Store nicht neu; Install schlägt mit „does not exist in the store" fehl | Supervisor-REST-API direkt nutzen (`/store/reload`, `/store/addons/<slug>/install`) |
| Watchdog-Template-Validator | Add-on wird beim Store-Reload stillschweigend verworfen (nur im Supervisor-Log sichtbar: `Can't read .../config.yaml`) | `watchdog: tcp://[HOST]:[PORT:8883]` — **ohne** `/tcp`-Suffix im PORT-Template |
| Bridge-Client-Zertifikat mit Zwischen-CA | Alt-Broker loggt `certificate verify failed`, Bridge verbindet nie | Ein direkt von der Client-CA signiertes Zertifikat verwenden oder die volle Kette (Leaf+Intermediate) als `bridge_certfile` |
| Windows-Entwicklung: CRLF | `run.sh` mit CRLF-Shebang startet im Alpine-Container nicht | `.gitattributes` mit `* text=auto eol=lf` von Anfang an |
| `per_listener_settings` | Deprecation-Warnung (Mosquitto 2.1) | Option weglassen |
| Explizite `log_type`-Liste | Error-Meldungen fehlen stumm im Broker-Log | `log_type error` mit aufnehmen — jede explizite `log_type`-Liste deaktiviert alle ungenannten Typen |
| Silent-Fail des Store-Reloads | Lokales Add-on erscheint nie im Store | Supervisor-Log lesen: Validierungsfehler stehen dort mit Datei und Grund |

## 6. Grenzen / Restrisiken

- **Supervisor-MQTT-Service-Discovery**: Add-ons, die ihre MQTT-Zugangsdaten
  automatisch vom offiziellen Add-on beziehen, verlieren diese Quelle.
  Vorher prüfen, ob installierte Add-ons das nutzen.
- Die **HA-MQTT-Integration** muss manuell konfiguriert sein (Host, Port,
  TLS, Login) — dann übersteht sie den Tausch unverändert.
- `$SYS`-Topics matcht `#` in ACL-Regeln nicht; wer sie braucht, braucht
  eine explizite Regel.
- Klartext-Ports des offiziellen Add-ons (1883 u. a.) entfallen, wenn das
  eigene Add-on nur den TLS-Listener anbietet — je nach Bestand gewollt
  oder nachzurüsten.
- Der Fix des Upstream-Bugs #4571 ändert an diesem Setup nichts — man ist
  dann einfach unabhängig davon.
