# Architecture

As of **2026-11-20**, add-on version **1.0.5** (`mosquitto-standalone/config.yaml`). Motivation and the
step-by-step migration: [migration-guide.en.md](migration-guide.en.md) (Deutsch:
[migration-guide.de.md](migration-guide.de.md)). Where this document and the code disagree, the code wins:
`mosquitto-standalone/config.yaml`, `mosquitto-standalone/run.sh`, `mosquitto-standalone/Dockerfile`,
`scripts/deploy.sh`, `.github/workflows/ci.yml`.

Every perspective has a sketch as a plain-text diagram (readable in any editor, terminal and on GitHub, no
renderer needed). Names, hosts and addresses are placeholders, as everywhere in this repository.

| Perspective | Question | Section |
|---|---|---|
| Context | Who and what talks to the broker and to this repository? | [1](#1-context) |
| Building blocks | What does the repository consist of, what does each part do? | [2](#2-building-blocks) |
| Deployment | What runs where — devices, containers, networks, protocols, ports? | [3](#3-deployment) |
| Runtime | How do startup, migration phases and the ACL proof run? | [4](#4-runtime) |
| Data | Where do code, configuration, certificates, logins and persistence live — and what is backed up? | [5](#5-data) |
| Security | Which trust zones and protection layers exist? | [6](#6-security) |
| Delivery | How does a change get onto the HAOS host? | [7](#7-delivery-and-deploy) |
| Recovery | What is needed when, to get the broker back after a failure? | [8](#8-recovery) |
| Decisions | Which decisions shape the design? | [9](#9-decisions) |

**Relation to `ha-addon-mosquitto`:** according to the commit history (e.g. `74a1e2d`, `3214588`), this
public repository is a **sanitized snapshot** of a private single source of truth named `ha-addon-mosquitto`:
changes are made there and copied here without real targets, keys or secrets. Nothing in this repository
depends on the private one at build or run time.

## 1. Context

```text
                                  ┌──────────── HAOS host (Home Assistant OS) ─────────────┐
  MQTT clients (LAN) ── MQTT/TLS ▶│  Mosquitto Standalone add-on      host port 8883       │
  (client certificate + login)    │  (during migration: 18883)                             │
                                  │                                                        │
  HA MQTT integration ─ MQTT/TLS ▶│  Supervisor ── builds, starts, watches the add-on      │
                                  │  official Mosquitto add-on (core_mosquitto)            │
                                  │    migration source, afterwards rollback target        │
                                  │  /share/mosquitto/  ACL file   /ssl/  PKI material     │
                                  └──────▲────────────────────────────▲───────────────▲────┘
                                         │ SSH (deploy key)           │ MQTT/TLS      │ ACL file
                                         │ deploy.sh                  │ verification  │ (external
  Operator workstation ──────────────────┘                            │               │  process)
     │  .local/deploy.conf, deploy key                                │               │
     │  SSH ─────────────────────────────▶ verification host ─────────┘          ACL deploy process
     │                                     (mosquitto-clients + client cert)     (outside this repo)
     │ git push (code only)
     ▼
  GitHub (public) ── CI: shellcheck, gitleaks, trivy config, trivy image
```

| Actor / system | Role | Defined in |
|---|---|---|
| MQTT clients | home-automation devices and services; connect with client certificate (mTLS) plus login | outside this repo |
| HA MQTT integration | Home Assistant's own MQTT client, configured manually (host, port, TLS, login) | guide §3 phase 5, §6 |
| Supervisor | builds the image locally, manages options, ports, boot, watchdog, backups | `config.yaml` |
| Official add-on `core_mosquitto` | broker before the switch; migration bridge source; rollback target | `deploy.sh` (`OLD_SLUG`) |
| Operator workstation | runs `scripts/deploy.sh` with `.local/deploy.conf` (gitignored) | `deploy.sh`, `deploy.conf.example` |
| Verification host | any host with `mosquitto-clients` and a valid client certificate; runs the retained count and ACL proof | `deploy.conf.example` (`VERIFY_*`) |
| ACL deploy process | maintains `/share/mosquitto/accesscontrollist`; the add-on only reads it | `config.yaml` (comment), guide §2 |
| GitHub | public repository + CI gate | `.github/workflows/ci.yml` |

## 2. Building blocks

```text
  Repository addon-mosquitto-standalone                        Image (built on the HAOS host)
  ┌───────────────────────────────────────────────┐            ┌────────────────────────────────────┐
  │ mosquitto-standalone/       (the add-on)      │            │ eclipse-mosquitto:2.1.2-alpine     │
  │   config.yaml  manifest: slug, port, mounts,  │───────────▶│   pinned by manifest-list digest   │
  │                watchdog, options + schema     │            │ + jq (apk)                         │
  │   Dockerfile   base image + jq + run.sh       │───────────▶│ + /run.sh   (CMD, no entrypoint)   │
  │   run.sh       options ─▶ passwd + conf, exec │───────────▶│                                    │
  │                                               │            └────────────────────────────────────┘
  │ scripts/deploy.sh  status / install / update  │
  │                    cutover / rollback /       │────── SSH + Supervisor REST API ──▶ HAOS host
  │                    verify-acl                 │
  │ deploy.conf.example  template for             │
  │                      .local/deploy.conf       │
  │ .github/workflows/ci.yml  CI gate             │
  │ .shellcheckrc  .trivyignore  lint / scanner   │
  │                              exceptions       │
  │ .gitattributes  eol=lf (run.sh in Alpine)     │
  │ .gitignore      .local/                       │
  │ docs/  migration guide EN/DE, this document   │
  └───────────────────────────────────────────────┘
```

| Part | Responsibility | Key facts |
|---|---|---|
| `config.yaml` | Supervisor manifest | slug `mosquitto_standalone` (installed as `local_mosquitto_standalone`), `arch: amd64`, `init: false`, `startup: system`, `boot: manual`, port `8883/tcp: 18883`, watchdog `tcp://[HOST]:[PORT:8883]`, mounts `ssl:ro`, `share:ro` |
| `Dockerfile` | image recipe | `FROM eclipse-mosquitto:2.1.2-alpine@sha256:…`, `apk add jq`, `ENTRYPOINT []`, `CMD ["/run.sh"]` |
| `run.sh` | container start | reads `/data/options.json`, validates paths, writes `/data/passwd` (hashed) and `/data/mosquitto.conf`, optional bridge, `exec mosquitto` |
| `scripts/deploy.sh` | orchestration from the workstation | every phase is a dry run without `--apply`; all Supervisor calls run on the host via SSH |
| CI | quality and supply-chain gate | shellcheck, gitleaks (full history), trivy config (HIGH/CRITICAL), trivy image (CRITICAL) |

Add-on options (schema in `config.yaml`): `cafile`, `certfile`, `keyfile`, `acl_file`, `logins[]`
(`username`, `password`), `migration_bridge` (`enabled` default `false`, `address`, `remote_username`,
`bridge_cafile`, `bridge_certfile`, `bridge_keyfile`).

## 3. Deployment

```text
  Operator workstation (Windows, Git Bash)        Verification host (optional, but required for the ACL proof)
  ┌──────────────────────────────────┐            ┌──────────────────────────────────────┐
  │ repo clone, .local/deploy.conf,  │ SSH        │ mosquitto-clients, client cert + key │
  │ deploy key (IdentitiesOnly,      │───────────▶│ password via stdin, -P on its argv   │
  │ StrictHostKeyChecking=yes)       │            └──────────────────┬───────────────────┘
  └────────────────┬─────────────────┘                               │ MQTT over TLS
                   │ SSH root@<haos-host>  (tar stream, commands)    │ host:18883 / host:8883
                   ▼                                                 │
  HAOS host ─────────────────────────────────────────────────────────┼────────────────────────────
  │                                                                  │
  │  SSH add-on (ha CLI, jq, curl; /addons writable; $SUPERVISOR_TOKEN)
  │     │ HTTP http://supervisor/...  (store/reload, install, update, options, start/stop/restart)
  │     ▼                                                            │
  │  Supervisor ── builds image from /addons/mosquitto-standalone    │
  │     │ manages                         watchdog: TCP connect ─┐   │
  │     ▼                                                        ▼   ▼
  │  ┌── container local_mosquitto_standalone ───────────┐   host port 18883 (parallel)
  │  │ mosquitto, listener 8883, require_certificate     │◀──    or 8883 (after cutover)
  │  │ /data   rw  options.json, passwd, conf, db        │   ▲
  │  │ /ssl    ro  ca.crt, broker.crt/.key, bridge cert  │   │ MQTT over TLS
  │  │ /share  ro  mosquitto/accesscontrollist           │   │
  │  └──────────────────────┬────────────────────────────┘   │
  │                         │ bridge (only while enabled): outgoing MQTT/TLS to <old-broker>:8883
  │                         ▼                                │
  │  ┌── container core_mosquitto (official add-on) ─────┐   │
  │  │ before cutover: host port 8883                    │   │
  │  │ after cutover: stopped, boot=manual (rollback)    │   │
  │  └───────────────────────────────────────────────────┘   │
  └──────────────────────────────────────────────────────────┼────────────────────────────────────
                                                             │
  LAN: MQTT clients, HA MQTT integration ────────────────────┘
```

| Connection | Protocol | Port | Direction | Notes |
|---|---|---|---|---|
| Clients → broker | MQTT over TLS, client certificate required | host 8883 (migration: 18883) → container 8883 | inbound | no plaintext listener, `allow_anonymous false` |
| Supervisor watchdog → broker | TCP connect | mapped host port of container 8883 | host-internal | restarts the add-on on hangs |
| Migration bridge → old broker | MQTT over TLS, bridge certificate + `remote_username` | `<old-broker>:8883` | outgoing | only while `migration_bridge.enabled=true`; `topic # in 0` |
| Workstation → HAOS host | SSH (BatchMode, deploy key) | SSH port of the SSH add-on (not set in the repo) | outgoing | tar stream of the add-on folder + remote commands |
| SSH add-on → Supervisor | HTTP REST, bearer `SUPERVISOR_TOKEN` | `http://supervisor` | host-internal | token never leaves the host |
| Workstation → verification host | SSH | (not set in the repo) | outgoing | password handed over on stdin |
| Verification host → broker | MQTT over TLS | 18883 / 8883 | outgoing | retained count, ACL proof |

The container network of the Supervisor and the exact client population are not described in this
repository; they are HAOS defaults resp. installation-specific.

## 4. Runtime

### 4.1 Container start (`run.sh`)

```text
  Supervisor start / restart / watchdog
        │ writes /data/options.json from the add-on options
        ▼
  run.sh (set -eu, umask 077)
   ├─ 1. read cafile, certfile, keyfile, acl_file  (jq, line breaks stripped)
   │      path outside /ssl/ or /share/ or file missing ──────────────▶ exit 1 (add-on does not start)
   ├─ 2. logins[] ─▶ /data/passwd "user:pass" (0600) ─▶ mosquitto_passwd -U (hash in place)
   ├─ 3. write /data/mosquitto.conf
   │      user root, persistence /data/, log error/warning/notice, limits,
   │      listener 8883 + cafile/certfile/keyfile + require_certificate,
   │      PFS-only cipher list (TLS <= 1.2), TLS 1.3 at library default,
   │      allow_anonymous false, password_file, acl_file
   ├─ 4. migration_bridge.enabled = true ?
   │      yes: password of remote_username from logins[] (missing ──▶ exit 1),
   │           bridge paths checked, connection block appended (topic # in 0)
   │      no:  "migration bridge off (normal operation)"
   └─ 5. exec mosquitto -c /data/mosquitto.conf
```

Configuration or ACL changes take effect only through an add-on restart (no SIGHUP reload, `run.sh` header).

### 4.2 Migration phases (`deploy.sh`)

```text
  ┌──────────────┐ --install --with-bridge --apply ┌─────────────────────────────┐
  │ official     │────────────────────────────────▶│ parallel operation          │
  │ add-on only  │   copy add-on, store reload,    │ old: 8883   new: 18883      │
  │ (port 8883)  │   install, copy logins from     │ bridge pulls '#' incl.      │
  └──────────────┘   core_mosquitto, start         │ retained from old broker    │
                                                   └──────────────┬──────────────┘
                                                                  │ verify: retained count old/new,
                                                                  │ positive + negative ACL test
                                                                  ▼
                                                   ┌─────────────────────────────┐
         --rollback --apply                        │ --cutover --apply           │
  ┌──────────────────────────────┐                 │ 1 bridge enabled=false      │
  │ new: stop, boot=manual,      │◀────────────────│ 2 old: stop, boot=manual    │
  │      port back to 18883      │   any time      │ 3 new: host port 8883       │
  │ old: start, boot=auto        │                 │ 4 new: boot=auto            │
  └──────────────────────────────┘                 │ 5 restart + ACL proof       │
                                                   └──────────────┬──────────────┘
                                                                  ▼
                                                   ┌─────────────────────────────┐
                                                   │ normal operation            │
                                                   │ new: 8883, bridge off       │
                                                   │ --update --apply: sync,     │
                                                   │   rebuild, restart, proof   │
                                                   └─────────────────────────────┘
```

The order in `--cutover` is safety-critical: the bridge is switched off **before** the port changes,
otherwise the bridge address would point at this broker itself (self-bridge loop). `--install` never arms
the bridge implicitly; `--with-bridge` arms it only if `core_mosquitto` reports `state=started`.

### 4.3 ACL enforcement proof (`--verify-acl`, end of `--update` and `--cutover`)

```text
  deploy.sh (workstation)     HAOS host (SSH add-on)        verification host           broker
     │ host port of add-on        │                               │                        │
     │───────────────────────────▶│ GET /addons/<new>/info        │                        │
     │◀──── network["8883/tcp"] ──│                               │                        │
     │ password of VERIFY_LOGIN   │                               │                        │
     │───────────────────────────▶│ (from add-on options)         │                        │
     │◀───────────────────────────│                               │                        │
     │ SSH, password on stdin ───────────────────────────────────▶│ mosquitto_sub '#' -W 10│
     │                            │                               │───────────────────────▶│
     │                            │                               │◀── messages (n >= 1) ──│ positive
     │ same for VERIFY_NEG_LOGIN ────────────────────────────────▶│───────────────────────▶│
     │                            │                               │◀── nothing (n = 0) ────│ negative
     │ connection errors (refused, TLS, not authorised) ─▶ CONN-ERR ─▶ FAIL
     ▼
  [ACL-VERIFY] utc=… commit=… broker=…:port positive[…]=PASS negative[…]=PASS result=PASS
  result != PASS ─▶ exit 1 (fail closed); --no-verify skips with a warning
```

## 5. Data

Principle visible in the repo: **code → Git/GitHub; targets, keys and secrets → stay local
(`.local/`, gitignored) or on the HAOS host.** gitleaks scans the full history in CI.

```text
  GitHub (public)                    Workstation                         HAOS host
  ┌──────────────────────────┐       ┌──────────────────────────┐        ┌──────────────────────────────────────┐
  │ add-on source, deploy.sh,│ clone │ repo clone               │  tar   │ /addons/mosquitto-standalone         │
  │ CI, docs, templates      │──────▶│ .local/deploy.conf ─ ─ ─ │─ ─ ─ ─▶│   (copy of the add-on source)        │
  └──────────────────────────┘       │ .local/ssh/ (deploy key) │  SSH   │ add-on data dir (/data in container):│
     gitleaks over full history      │   not in Git; backup:    │        │   options.json  logins in plaintext  │
                                     │   not stated (gap)       │        │   passwd        hashed logins        │
                                     └──────────────────────────┘        │   mosquitto.conf  generated          │
                                                                         │                 (bridge: password)   │
                                                                         │   persistence   retained store etc.  │
                                                                         │ /ssl/      CA, broker cert/key,      │
                                                                         │            bridge client cert/key    │
                                                                         │ /share/mosquitto/accesscontrollist   │
                                                                         │ /config/.storage/core.config_entries │
                                                                         │   HA MQTT integration login          │
                                                                         └──────────────────┬───────────────────┘
                                                                                            │ HA backup
                                                                                            ▼ (Supervisor)
                                                                           add-on data: yes (run.sh header);
                                                                           /ssl, /share, /addons, /config:
                                                                           not stated in the repo
```

| Data | Location | Source of truth | Backup (as far as the repo says) |
|---|---|---|---|
| Add-on source, deploy script, CI, docs | Git, GitHub | repository | Git / GitHub |
| Copy of the add-on source | `/addons/mosquitto-standalone` on the host | repository (overwritten on every `--install`/`--update`) | reproducible from Git |
| Image | local Docker on the host | `Dockerfile` (digest-pinned base) | not needed; rebuilt by the Supervisor |
| Add-on options incl. **logins in plaintext** | Supervisor; `/data/options.json` | Supervisor options (copied from `core_mosquitto` on install, edited afterwards) | add-on data dir is part of HA backups (`run.sh` header) |
| Password file (hashed) | `/data/passwd` | generated from the options at every start | regenerable |
| `mosquitto.conf` (bridge block contains `remote_password`) | `/data/mosquitto.conf` | generated at every start | regenerable |
| Persistence (retained messages, sessions) | `/data/` (`persistence_location`) | broker runtime | in the add-on data dir; content of the persistence file not described further |
| TLS material (CA, broker cert/key, bridge client cert/key) | `/ssl/...` (read-only mount) | existing PKI, **outside this repo** | **not stated** (gap) |
| ACL file | `/share/mosquitto/accesscontrollist` (read-only mount) | external ACL deploy process, **outside this repo** | **not stated** (gap) |
| HA MQTT integration login | `/config/.storage/core.config_entries` | Home Assistant | **not stated** (gap) |
| Deploy targets, verify settings | `.local/deploy.conf` (gitignored) | operator | **not stated** (gap) |
| Deploy key | `.local/ssh/` (default from the template, gitignored) | operator | **not stated** (gap) |
| Supervisor token | environment of the SSH add-on on the host | Supervisor | not needed; provided by HAOS |
| Evidence lines `[ACL-VERIFY]` | console output of `deploy.sh` | operator copies them into an audit log | audit log location **not stated** |

## 6. Security

```text
   Zone 0: LAN                 Zone 1: broker listener            Zone 2: broker core           Zone 3: host / admin
  ┌──────────────┐   ┌──────────────────────────────┐   ┌────────────────────────────┐   ┌────────────────────────┐
  │ MQTT client  │──▶│ Layer 1: TLS                 │──▶│ Layer 2: password_file     │   │ SSH add-on (root)      │
  └──────────────┘   │ require_certificate (mTLS),  │   │ allow_anonymous false,     │   │ deploy key, strict     │
                     │ PFS-only ciphers <= TLS 1.2, │   │ PBKDF2-hashed logins       │   │ host key checking      │
                     │ TLS 1.3 default suites,      │   │            │               │   │ SUPERVISOR_TOKEN stays │
                     │ no plaintext listener        │   │            ▼               │   │ on the host            │
                     │ limits: 100 connections,     │   │ Layer 3: acl_file          │   │ read-only mounts       │
                     │ 1 MiB messages, 10000 msgs / │   │ (builtin-security only,    │   │ /ssl, /share           │
                     │ 32 MiB queue                 │   │  no go-auth)               │   └────────────────────────┘
                     └──────────────────────────────┘   └────────────────────────────┘
   Input hardening in run.sh: line breaks stripped from options, file paths only under /ssl/ or /share/.
   Supply chain: base image by digest, CI actions by commit SHA, gitleaks, trivy config + image scan.
```

| Topic | Measure | Where |
|---|---|---|
| Authentication | client certificate **and** login (cert ≠ login: any valid cert, login chosen by `-u`) | `run.sh`, guide §4 |
| Authorization | stock `acl_file`, no go-auth → ACL enforced (the reason for this add-on, #4571) | `run.sh`, `config.yaml` |
| ACL proof | empirical positive + negative test, fail closed after `--update`/`--cutover` | `deploy.sh` `verify_acl` |
| Secrets on argv | passwords never on argv of `deploy.sh` or in `mosquitto_passwd`; exception: `mosquitto_sub -P` on the verification host (accepted, documented) | `run.sh`, `deploy.sh` |
| Secrets at rest | logins in plaintext in the Supervisor options and `/data/options.json`; bridge password in `/data/mosquitto.conf`; files 0600 via `umask 077` | `run.sh` |
| Root in container | deliberate (keys/ACL `600 root:root`, root-owned `/data`); trivy DS-0002 suppressed with rationale | `run.sh`, `.trivyignore` |
| Config injection | newline stripping, path allow-list | `run.sh` |
| Self-bridge loop | bridge default off; `--with-bridge` only with running old broker; cutover disables bridge first | `config.yaml`, `deploy.sh` |
| Two brokers on one port | old add-on `boot=manual` at cutover, new add-on `boot: manual` until cutover | `config.yaml`, `deploy.sh` |
| `$SYS` topics | not matched by `#` in ACL rules; explicit rule needed if wanted | guide §6 |
| Devices without mTLS | not served by this broker; a separate edge adapter was chosen instead of a second listener (commit `74a1e2d`) | commit history |

## 7. Delivery and deploy

```text
  Workstation                   GitHub (CI)              HAOS host: SSH add-on       Supervisor / add-on
     │ git commit                  │                           │                          │
     │ git push ──────────────────▶│ shellcheck, gitleaks,     │                          │
     │                             │ trivy config, trivy image │                          │
     │ bump version in config.yaml │ (gate; no deployment)     │                          │
     │ deploy.sh --update  (dry run: plan only)                │                          │
     │ deploy.sh --update --apply                              │                          │
     │ tar mosquitto-standalone/ over SSH ────────────────────▶│ rm -rf + extract         │
     │                             │                           │ into /addons/            │
     │                             │                           │ POST /store/reload ─────▶│
     │                             │                           │ POST /store/addons/      │
     │                             │                           │ local_…/update ─────────▶│ rebuild image,
     │                             │                           │                          │ restart (~15 s)
     │ ACL proof via verification host (4.3) ─────────────────────────────────────────────▶│
     │ [ACL-VERIFY] … result=PASS  ─▶ copy into the audit log │                          │
```

- Deploys are **deliberately manual** (operator-triggered, never scheduled); CI is a gate only, it never
  deploys (README, "Automation").
- No registry: the Supervisor builds the image locally from `/addons/mosquitto-standalone`.
- `--update` requires a version bump in `config.yaml`; otherwise the Supervisor sees no update.
- The source is delivered from the working tree of the workstation clone (tar stream), not from GitHub; the
  evidence line records `git rev-parse --short HEAD`.
- Rollback of a bad version: no older image is kept; the way back is redeploying an older commit with a
  higher version number, or `--rollback` to the official add-on (inferred from `deploy.sh`; not documented
  as a procedure).

## 8. Recovery

The repository contains **no dedicated recovery runbook**. This section derives the path from
`deploy.sh`, `config.yaml`, `run.sh` and the guide, and marks what is missing as a **gap**.

Sources:

| Code | Source | Contains for this broker |
|---|---|---|
| **G** | GitHub / Git clone | add-on source, `deploy.sh`, `deploy.conf.example`, docs |
| **L** | operator's local files (`.local/`) | `deploy.conf` (targets, verify settings), deploy key — backup location **not stated** |
| **H** | Home Assistant backup (Supervisor) | add-on data dir (`/data`: options incl. logins, persistence) per `run.sh`; whether `/ssl`, `/share`, `/addons`, `/config` are included is **not stated** |
| **E** | external systems outside this repo | PKI (CA and certificates), ACL deploy process, HAOS installation itself |
| **S** | HAOS host at runtime | `SUPERVISOR_TOKEN`, Supervisor API, SSH add-on |

### 8.1 Flow

Markers: `access` = account or access path, `secret` = password or key, `setting` = configuration,
`[G] [L] [H] [E] [S]` = source.

```text
                                  ┌────────────┐
                                  │  failure   │
                                  └─────┬──────┘
                                        ▼
                              What is lost / broken?
       ┌────────────────────────────────┼──────────────────────────────────────┐
       │ add-on misbehaves              │ add-on gone, host OK                 │ HAOS host lost
       │ after an update                │                                      ▼
       ▼                                │          ╔═ H: host ═══════════════════════════════════════════════
  R1 deploy.sh --rollback --apply       │          ║ H0 install HAOS, restore HA backup       secret: backup
     (back to core_mosquitto,           │          ║    (Supervisor)                          password if any [E]
     needs it installed)    [G][L][S]   │          ║                                          content [H]
  or redeploy older commit with         │          ║ H1 SSH add-on: ha CLI, jq, /addons       access: SSH
     bumped version (--update)  [G]     │          ║    writable, operator's public key       setting: SSH port
       │                                │          ║                                          secret: deploy key [L]
       │                                │          ║ H2 new host key ─▶ known_hosts           setting: host key
       │                                │          ║    (StrictHostKeyChecking=yes aborts      fingerprint [E]
       │                                │          ║    otherwise)
       │                                │          ╚═══════════════════════════════╤════════════════════════
       │                                │                                          ▼
       │                                │          ╔═ P: prerequisites on the host ═════════════════════════
       │                                └─────────▶║ P1 /ssl: ca.crt, broker.crt/.key         secret: broker key,
       │                                           ║    (paths = add-on options)              CA [E] or [H]?
       │                                           ║ P2 /share/mosquitto/accesscontrollist    setting: ACL [E]
       │                                           ║    (missing file ─▶ run.sh exit 1)       or [H]?
       │                                           ║ P3 .local/deploy.conf: BROKER_SSH,       setting [L]
       │                                           ║    SSH_IDENTITY, VERIFY_*
       │                                           ╚═══════════════════════════════╤════════════════════════
       │                                                                           ▼
       │                                           ╔═ A: add-on ═════════════════════════════════════════════
       │                                           ║ A1 add-on restored by HA backup?
       │                                           ║    yes ─▶ check options, port 8883, boot=auto     [H]
       │                                           ║    no  ─▶ deploy.sh --install --apply           [G][L][S]
       │                                           ║           (no --with-bridge!) copies logins from
       │                                           ║           core_mosquitto ─ GAP: fails or is stale
       │                                           ║           if the official add-on is gone/outdated
       │                                           ║ A2 logins: compare with the inventory    secret: logins
       │                                           ║    (incl. least-privilege logins)        [H] or GAP
       │                                           ║ A3 host port 18883 ─▶ 8883, boot=auto    setting
       │                                           ║    deploy.sh --cutover stops core_mosquitto first;
       │                                           ║    without it installed: GAP, set port/boot via
       │                                           ║    Supervisor manually
       │                                           ║ A4 retained store: from /data [H]; otherwise empty,
       │                                           ║    clients republish only what they retain themselves
       │                                           ╚═══════════════════════════════╤════════════════════════
       │                                                                           ▼
       │                                           ╔═ V: acceptance ═════════════════════════════════════════
       └──────────────────────────────────────────▶║ V1 log: "migration bridge off", clients reconnect
                                                   ║ V2 deploy.sh --verify-acl                secret: client
                                                   ║    positive + negative, result=PASS      cert on verify
                                                   ║                                          host [E], logins
                                                   ║                                          from options [S]
                                                   ║ V3 HA MQTT integration connected          setting:
                                                   ║    (core.config_entries)                 [H] or GAP
                                                   ║ V4 [ACL-VERIFY] line into the audit log  location: GAP
                                                   ╚═════════════════════════════════════════════════════════
```

### 8.2 What is needed when

| Step | Access | Secret | Setting | Source |
|---|---|---|---|---|
| Restore HAOS + HA backup | HAOS console / UI | backup password, if the backup is encrypted (not stated) | – | H, E |
| Reach the host from the workstation | SSH to the SSH add-on | deploy key (`SSH_IDENTITY`) | `BROKER_SSH`, SSH port, host key in `known_hosts` | L, E |
| Get the code | Git clone / GitHub | – (public repo) | – | G |
| TLS material on the host | host file system (`/ssl`) | broker private key, CA, bridge client key | paths `cafile`, `certfile`, `keyfile` | E (or H — not stated) |
| ACL file on the host | ACL deploy process | – | `/share/mosquitto/accesscontrollist` | E (or H — not stated) |
| Install the add-on | SSH → Supervisor API | `SUPERVISOR_TOKEN` (on the host only) | slug `local_mosquitto_standalone`, `boot`, host port | G, S |
| Logins | Supervisor options | all broker passwords | `logins[]` | H; from `core_mosquitto` via `--install`; otherwise **gap** |
| Production port + autostart | Supervisor API / UI | – | `network 8883/tcp = 8883`, `boot=auto`, `migration_bridge.enabled=false` | S |
| Retained store | – | – | `persistence_location /data/` | H; otherwise lost |
| ACL proof | SSH to the verification host | client cert + key there, `VERIFY_LOGIN`/`VERIFY_NEG_LOGIN` passwords (looked up server-side) | `VERIFY_SSH`, `VERIFY_LOGIN`, `VERIFY_NEG_LOGIN`, `VERIFY_TLS_ARGS`, `VERIFY_SUDO` | L, E, S |
| HA MQTT integration | HA UI or `/config/.storage/core.config_entries` | its login | host, port, TLS, login | H (not stated) |

### 8.3 Gaps

- No recovery runbook and no stated backup for `.local/` (deploy config, deploy key).
- Origin and backup of the PKI (CA key, broker and bridge certificates) are outside this repo and not
  described.
- Origin and backup of the ACL file: "existing ACL deploy process", not described here.
- Whether an HA backup covers `/ssl`, `/share`, `/addons` and `/config` is not stated; only the add-on data
  dir is.
- `deploy.sh --install` copies logins only from `core_mosquitto`; there is no scripted path to restore logins
  when the official add-on is missing or its logins are outdated (e.g. least-privilege logins added after the
  cutover, guide phase 5).
- `deploy.sh --cutover` assumes `core_mosquitto` is installed (it stops it first); without it the port switch
  must be done by hand.
- No inventory of logins and clients in the repo (deliberately: sanitized export).
- Location of the audit log for `[ACL-VERIFY]` lines is not stated.

## 9. Decisions

No formal ADRs exist; the decisions are documented in code comments, the guide and commit messages.

| No. | Decision | Rationale / consequence |
|---|---|---|
| D1 | Stock Eclipse Mosquitto without go-auth | the official add-on (≥ 7.0) does not enforce file ACLs (#4571); here `password_file` + `acl_file` are the only auth mechanism |
| D2 | Local add-on instead of a raw container | stays Supervisor-managed (backups, watchdog, lifecycle); raw containers make HAOS "unsupported" |
| D3 | Same Mosquitto version as the official add-on (2.1.2), base image pinned by digest | switch is a pure auth-plugin swap, no version jump; digest freezes the CVE baseline |
| D4 | Logins stay add-on options, copied server-side | passwords never leave the host; same shape as the official add-on |
| D5 | Parallel operation on 18883 + migration bridge `topic # in 0` | lossless retained takeover, low-risk switch, trivial rollback |
| D6 | Bridge off by default, armed only explicitly | prevents the self-bridge loop after the cutover (v1.0.4) |
| D7 | Restart instead of SIGHUP | deterministic state after config/ACL changes |
| D8 | Mosquitto runs as root | keys/ACL `600 root:root`, root-owned `/data`; same as the official add-on |
| D9 | Mandatory, fail-closed ACL proof after `--update`/`--cutover` | ACL enforcement is a runtime property and must be re-proven (v1.0.4) |
| D10 | Explicit TLS policy: PFS-only ciphers for TLS ≤ 1.2, `tls_version` not pinned | BSI TR-02102-2; pinning would disable TLS 1.3 (v1.0.5) |
| D11 | Supervisor REST API instead of the `ha` CLI for store/install | CLI rename "addons" → "apps" (2026) made `ha addons reload` a no-op |
| D12 | Manual, operator-triggered deploys; CI only as a gate | live broker, separation of duties |
| D13 | No second (legacy) listener; non-mTLS devices via a separate edge adapter | broker stays configuration-lean (v1.0.6 reverted, commit `74a1e2d`) |
| D14 | Public repo as sanitized snapshot of a private source of truth | no targets, keys or secrets in Git; gitleaks over the full history |
