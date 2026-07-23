# Mosquitto Standalone — a local Home Assistant add-on with a working file ACL

**Problem:** Home Assistant's official Mosquitto add-on (≥ 7.0, Mosquitto 2.1)
silently stops enforcing file ACLs configured via the customize mechanism:
its go-auth plugin answers ACL checks before Mosquitto's builtin-security
plugin and allows everything for any valid login
([home-assistant/addons#4571](https://github.com/home-assistant/addons/issues/4571)).
The ACL file is loaded — and ignored.

**Solution:** this repository packages **stock Eclipse Mosquitto** as a
*local* Home Assistant add-on. No go-auth: authentication runs exclusively
via `password_file`, authorization via `acl_file` — both actually take
effect. The add-on stays Supervisor-managed (backups, watchdog, lifecycle),
unlike a raw Docker container, which HAOS marks as "unsupported".

**Migration:** the included deploy script orchestrates a low-risk switch:
run the new broker in parallel on an alternate port, mirror the complete
retained store via an MQTT bridge, verify (including an empirical ACL
negative test), then cut over with a few seconds of downtime — with a
trivial rollback path.

## Documentation

Start here — a full, reproducible walkthrough of the approach, the test
strategy, and the phased migration, including a pitfall table from a real
deployment:

- **[docs/migration-guide.en.md](docs/migration-guide.en.md)** (English)
- **[docs/migration-guide.de.md](docs/migration-guide.de.md)** (Deutsch)

Deutsche Kurzfassung dieses READMEs: [README.de.md](README.de.md)

## Repository layout

```
mosquitto-standalone/   the add-on (copy to /addons/<dir> on the HAOS host)
├── config.yaml         add-on manifest: ports, mappings, options + schema
├── Dockerfile          FROM eclipse-mosquitto:<pinned>-alpine + jq + run.sh
└── run.sh              generates mosquitto.conf + password file, execs mosquitto
scripts/deploy.sh       orchestration: status / install / update / cutover / rollback
deploy.conf.example     template for .local/deploy.conf (gitignored)
```

## Quick start

Prerequisites: HAOS host with SSH access (`ha` CLI + `jq`, `/addons`
writable — the official SSH add-on provides all of this), and an existing
mTLS PKI if you run `require_certificate` (paths are add-on options).

```bash
cp deploy.conf.example .local/deploy.conf   # then edit
./scripts/deploy.sh                          # status of both add-ons
./scripts/deploy.sh --install --apply        # build + run in parallel on :18883
./scripts/deploy.sh --cutover                # review the cutover plan
./scripts/deploy.sh --cutover --apply        # take over the production port
./scripts/deploy.sh --rollback --apply       # back to the official add-on
```

Every phase is a dry run unless you add `--apply`. **Install** is
harmless: the new broker runs in parallel, the old one is untouched, and
logins are copied server-side via the Supervisor API (passwords never
leave the host). **Cutover** costs ~10 seconds; clients reconnect on
their own because the address and PKI stay the same.

## Status

Deployed and verified in production on HAOS (2026): complete retained
takeover, all clients reconnected, ACL negative test passing. See the
migration guide for the measurement methodology and pitfalls.

## License

[MIT](LICENSE)
