# Actually enforcing Mosquitto ACLs on Home Assistant OS — approach, test strategy, and a low-disruption migration

> This document describes a reproducible way to move the MQTT broker of a
> Home Assistant OS installation from the official Mosquitto add-on to a
> **custom local add-on running stock Mosquitto** — with a working file
> ACL, a complete takeover of all retained messages, and only a few
> seconds of downtime. All names, addresses, and topics are placeholders;
> adapt them to your environment.
> Deutsche Version: [migration-guide.de.md](migration-guide.de.md)

## 1. The problem

Home Assistant's official Mosquitto add-on has long supported a file ACL
via the customize mechanism (`acl_file` in a `*.conf` file under
`/share/mosquitto/`). Since add-on version **7.0** (Mosquitto 2.1),
however, this ACL is **silently no longer enforced**: Mosquitto 2.1 moved
`acl_file` into the builtin-security plugin, and the add-on's go-auth
plugin answers ACL checks **before** that plugin — with "allow" for every
valid login. The file is loaded (it shows up in the log) but has no
effect whatsoever. Upstream bug:
[home-assistant/addons#4571](https://github.com/home-assistant/addons/issues/4571).

**How to find out whether you are affected** (empirical negative test — do
not rely on the log; Mosquitto drops ACL violations silently):

```bash
# As a login that per the ACL may ONLY publish (write-only):
mosquitto_sub -h <broker> -p 8883 <tls-options> \
  -u <write-only-login> -P <pass> -t '#' -W 10 -v
# Expected with a working ACL: nothing.
# Bug case: the full retained flood of all topics.

# Cross-check for the write direction — publish to a forbidden topic,
# then subscribe to it yourself:
mosquitto_pub ... -t test/aclcheck -m x -r
mosquitto_sub ... -t test/aclcheck -W 5
# Bug case: the message arrives. (Clean up afterwards: mosquitto_pub ... -r -n)
```

## 2. Solution approach: a custom local add-on running stock Mosquitto

Two obvious alternatives are ruled out:

- **Downgrading to add-on 6.5.2**: the Supervisor does not support clean
  downgrades of store add-ons; you would be stuck on an old version forever.
- **A raw Docker container on HAOS**: technically possible, but the
  Supervisor marks foreign containers as "unsupported" (which can block
  updates), and the container is excluded from backups, watchdog, and
  lifecycle management.

The clean path is a **local add-on**: the same container, but
Supervisor-managed (backups, watchdog, start/stop, port management).
Core idea:

- Base image **`eclipse-mosquitto`**, pinned to **exactly the Mosquitto
  version the official add-on ships** (e.g. `2.1.2-alpine`). The switch
  then is a pure auth-plugin swap (go-auth out, builtin-security in), not
  a broker version jump.
- **No go-auth**: authentication exclusively via `password_file`,
  authorization via `acl_file` — both actually take effect.
- The **logins remain add-on options** (as with the official add-on) and
  are copied server-side via the Supervisor API during the switch —
  passwords never leave the host.
- A startup script (`run.sh`) generates `mosquitto.conf` and the hashed
  password file from the options at start and `exec`s Mosquitto.

Repository layout (see this repository):

```
<addon-folder>/
├── config.yaml   # add-on manifest: ports, mappings, options + schema
├── Dockerfile    # FROM eclipse-mosquitto:<version>-alpine + jq + run.sh
└── run.sh        # generates config + password file, starts mosquitto
scripts/deploy.sh # orchestration: install / update / cutover / rollback
```

### Design decisions in detail

**Password file without plaintext on argv.** `mosquitto_passwd -b` takes
the password as a command-line argument — avoidable: first write a
`user:password` plaintext file with `umask 077` (via `jq` from
`/data/options.json`), then hash it in place with
**`mosquitto_passwd -U file`**. No secret ever appears in a process list.

**Mosquitto as root.** TLS keys and the ACL file are typically
`600 root:root`; the add-on data directory is owned by root. A privilege
drop would break persistence and file access — the official add-on runs
as root for the same reason (the log warning is known and accepted).
Consequence: **do not use SIGHUP reloads**; always roll out config/ACL
changes via an add-on restart.

**ACL as an external single source of truth.** The ACL file stays where
it already lives (`/share/mosquitto/…`), maintained by its existing
deploy process. The add-on maps `share` **read-only** and only consumes it.

**mTLS unchanged.** If your broker already runs with
`require_certificate`, take the certificate paths over as add-on options
(mapping `ssl:ro`). Address and PKI stay identical across the switch —
which is why clients notice nothing but a reconnect.

**Important: raise `max_queued_messages`.** Mosquitto's default (1000)
drops parts of the retained flood for clients subscribing to broad
wildcards when the retained store is large (several thousand messages) —
observed as `Outgoing messages are being dropped for client …`. Size it
generously for installations with many retained topics (e.g. `10000`).

## 3. Migration strategy: build in parallel, verify, then switch

The migration splits into phases that are individually risk-free and can
be aborted at any time:

### Phase 1 — Parallel operation (no risk to production)

1. Copy the add-on folder to `/addons/`, reload the store, install.
   Practical note: on newer Supervisor versions (2026+, CLI rename
   "addons" → "apps") `ha addons reload` is a no-op — the
   **Supervisor REST API** is the stable path:
   `POST /store/reload`, then `POST /store/addons/local_<slug>/install`.
2. The new add-on listens on an **alternate host port** (e.g. 18883
   instead of 8883) — the old broker keeps running untouched.
3. **Copy logins server-side**: read the old add-on's options via the
   API, merge the `logins` list into the new add-on's options. Passwords
   never leave the host (the merge runs via SSH on the host itself, where
   the Supervisor token lives).
4. **Migration bridge**: the new add-on connects as a bridge *client* to
   the old broker and imports everything:

   ```
   connection migration
   address <broker-lan-ip>:8883
   topic # in 0
   cleansession true
   notifications false
   ```

   MQTT bridges preserve the retain flag — so the **complete retained
   store** (device states, control flags, …) migrates losslessly and
   stays continuously in sync during parallel operation. The bridge needs
   no inbound port; it is an outgoing connection.

### Phase 2 — Verification during parallel operation

All tests run against the new broker on the alternate port while
production continues untouched:

1. **Retained completeness**: compare the number of retained messages old
   vs. new (measurement method: §4). Expectation: identical.
2. **Spot-check critical retained topics**: query the topics your
   automation depends on (control flags, mode topics) explicitly.
3. **Negative test** (the entire point of the exercise): subscribe to `#`
   with a write-only login — **must stay empty**. On the old broker the
   same test fails in the bug case; that is your before/after proof.
4. **Positive test**: a read-entitled login connects and sees the
   expected topics.

### Phase 3 — Cutover (a few seconds of downtime)

The order is safety-critical:

1. **Disable the migration bridge** (add-on option) — **before** the port
   changes. Otherwise the bridge address points at your own broker after
   the switch: self-bridge loop.
2. **Stop** the old add-on and set `boot=manual` — otherwise two brokers
   compete for the same port after the next host reboot.
3. Move the new add-on's host port to the production port (8883)
   (Supervisor API, `network` option).
4. Set the new add-on to `boot=auto` and **restart** it.
5. Watch the log: all expected clients reconnect on their own because the
   address and server certificate are unchanged.

Downtime in practice: ~10 seconds. MQTT clients reconnect by themselves.

### Phase 4 — Post-checks and rollback path

- Client list in the log complete? No `not authorised` entries?
- **Repeat the negative test, now on the production port** — must be empty.
- Count the retained store again (after a broker restart, the log line
  `Restored N retained messages` is the authoritative number).
- Application-level end-to-end in daily use: switching, sensors, logging.
- **Rollback** stays trivial as long as the old add-on remains installed:
  stop the new add-on and move it back to the alternate port, start the
  old add-on and set `boot=auto`. Address/PKI unchanged → clients
  reconnect on their own again.

## 4. Test strategy: measuring without fooling yourself

These points turned out to be decisive:

**ACL violations do not appear in the log.** Mosquitto silently discards
forbidden publishes and simply delivers nothing for forbidden
subscriptions. The only reliable check is the empirical
negative/positive test with real client connections (§1).

**Counting retained messages — two traps.**

1. `mosquitto_sub --retained-only` disconnects on the **first live
   event**. On a broker with ongoing traffic, the count therefore aborts
   mid-flood and yields randomly low, fluctuating values. More robust:
   subscribe normally and evaluate the retain flag in the format string:
   ```bash
   mosquitto_sub ... -F '%r' -t '#' -W 15 | grep -c '^1'
   ```
2. Even then, `max_queued_messages` (default 1000) limits delivery of the
   flood to a single subscriber — recognizable by
   `Outgoing messages are being dropped` in the broker log. Raise the
   limit first, then measure. Fluctuating counts across repeated
   measurements are the leading symptom of delivery drops (a stable store
   yields identical numbers).

**The authoritative number after a restart.** `Restored N retained
messages` at broker startup is the most reliable statement about the
store contents — independent of delivery effects.

**Use cert ≠ login.** With mTLS plus separate password auth, a test host
may connect with *any* valid client certificate and select the login
under test via `-u/-P`. That way, negative and positive tests can run
from a single measurement host.

## 5. Pitfalls (found during the real deployment)

| Pitfall | Symptom | Fix |
|---|---|---|
| Supervisor CLI rename (2026: "addons" → "apps") | `ha addons reload` does not reload the store; install fails with "does not exist in the store" | Use the Supervisor REST API directly (`/store/reload`, `/store/addons/<slug>/install`) |
| Watchdog template validator | Add-on is silently rejected at store reload (visible only in the Supervisor log: `Can't read .../config.yaml`) | `watchdog: tcp://[HOST]:[PORT:8883]` — **without** the `/tcp` suffix in the PORT template |
| Bridge client certificate with intermediate CA | Old broker logs `certificate verify failed`, bridge never connects | Use a certificate signed directly by the client CA, or the full chain (leaf + intermediate) as `bridge_certfile` |
| Windows development: CRLF | `run.sh` with a CRLF shebang does not start in the Alpine container | `.gitattributes` with `* text=auto eol=lf` from the start |
| `per_listener_settings` | Deprecation warning (Mosquitto 2.1) | Omit the option |
| Silent failure of the store reload | Local add-on never appears in the store | Read the Supervisor log: validation errors are listed there with file and reason |

## 6. Limitations / residual risks

- **Supervisor MQTT service discovery**: add-ons that obtain their MQTT
  credentials automatically from the official add-on lose that source.
  Check beforehand whether any installed add-on uses it.
- The **HA MQTT integration** must be configured manually (host, port,
  TLS, login) — then it survives the switch unchanged.
- `$SYS` topics are not matched by `#` in ACL rules; if you need them,
  add an explicit rule.
- The official add-on's plaintext ports (1883 etc.) disappear if your
  add-on only offers the TLS listener — depending on your setup that is
  intended, or something to add.
- A future fix of upstream bug #4571 changes nothing about this setup —
  you are simply independent of it.
