#!/bin/sh
# run.sh — startup script of the Mosquitto Standalone add-on (runs INSIDE
# the container).
#
# Flow:
#   1. build the password_file from the add-on options (hashed via
#      mosquitto_passwd -U — passwords NEVER appear on argv)
#   2. generate mosquitto.conf (mTLS listener, acl_file from the options)
#   3. optionally append the migration bridge to the old broker
#   4. exec mosquitto
#
# Design decisions / pitfalls:
#   - Everything generated lives in /data (add-on data dir: survives
#     restarts, included in HA backups). umask 077, because password_file
#     and the bridge config contain plaintext secrets (the Supervisor's
#     options.json sits there the same way).
#   - Mosquitto runs as root (explicit "user root"): /ssl keys and the
#     ACL file are typically 600 root:root, and /data is owned by root —
#     a privilege drop would break persistence writes. The official
#     add-on does the same (its log warning is known/accepted).
#   - Do NOT use SIGHUP reloads: always roll out config/ACL changes via
#     an add-on restart (deterministic state, see the migration guide).
set -eu

OPTS=/data/options.json          # written by the Supervisor from config.yaml options
CONF=/data/mosquitto.conf
PASSWD=/data/passwd
umask 077

# tr -d '\n': embedded line breaks in option values would inject arbitrary
# Mosquitto directives into the generated config — strip them defensively.
CAFILE=$(jq -r '.cafile' "$OPTS" | tr -d '\n')
CERTFILE=$(jq -r '.certfile' "$OPTS" | tr -d '\n')
KEYFILE=$(jq -r '.keyfile' "$OPTS" | tr -d '\n')
ACLFILE=$(jq -r '.acl_file' "$OPTS" | tr -d '\n')

# Path check: the only allowed prefixes are /ssl/ and /share/ — the only
# mapped volumes (config.yaml). If this fails, the value is either a typo
# or an injection attempt.
validate_ssl_or_share_path() {
  case "$1" in
    /ssl/*|/share/*) ;;
    *) echo "[run.sh] ERROR: file path outside /ssl/ or /share/: $1" >&2; exit 1 ;;
  esac
}
for f in "$CAFILE" "$CERTFILE" "$KEYFILE" "$ACLFILE"; do
  validate_ssl_or_share_path "$f"
  [ -f "$f" ] || { echo "[run.sh] ERROR: file missing: $f" >&2; exit 1; }
done

# --- 1) password_file --------------------------------------------------------
# First a plaintext "user:pass" file (0600 thanks to umask), then hash it
# in place: mosquitto_passwd -U converts the file to PBKDF2 without any
# password ever appearing on a command line.
jq -r '.logins[] | .username + ":" + .password' "$OPTS" > "$PASSWD"
mosquitto_passwd -U "$PASSWD"

# --- 2) base configuration ---------------------------------------------------
# mTLS required, no plaintext listener, no anonymous access. Unlike the
# official add-on, builtin-security is the ONLY auth mechanism — the file
# ACL therefore actually takes effect (no go-auth, see the guide).
cat > "$CONF" <<EOF
user root
persistence true
persistence_location /data/
log_dest stdout
# NOTE: as soon as ANY log_type is listed explicitly, all unlisted types
# are disabled — without "error" here, error logging would be silently off.
log_type error
log_type warning
log_type notice
connection_messages true

# Large retained stores (several thousand messages) exceed Mosquitto's
# default max_queued_messages=1000 when a client subscribes to broad
# wildcards — parts of the retained flood get dropped ("Outgoing messages
# are being dropped", observed during the first deployment). Raise the
# limit generously.
max_queued_messages 10000

# Resource limits: bound connection floods and pathologically large
# messages (1 MiB is generous for typical home-automation payloads).
max_connections 100
message_size_limit 1048576
# Byte cap complementing max_queued_messages (10000 x 1 MiB would allow
# a theoretical 10 GiB queue); 32 MiB sits far above a typical retained
# flood of a few hundred KB.
max_queued_bytes 33554432

listener 8883
cafile $CAFILE
certfile $CERTFILE
keyfile $KEYFILE
require_certificate true

# TLS policy — set explicitly instead of inheriting the OpenSSL/base-image
# default (S-4), measured against BSI TR-02102-2: Perfect Forward Secrecy
# is required, so the TLS<=1.2 suite list is pinned to ECDHE key exchange
# with AEAD ciphers only (AES-GCM / ChaCha20-Poly1305); the static-RSA /
# non-PFS suites that ship in OpenSSL's default TLS-1.2 list are dropped.
# Being explicit also stops a future base-image / openssl.cnf change from
# silently widening the suite list.
# TLS 1.3 stays enabled and is NOT restricted here on purpose: mosquitto's
# tls_version selects EXACTLY ONE protocol version (it has no "minimum
# only" form), so pinning "tlsv1.2" would DROP TLS 1.3 — the opposite of
# TR-02102-2's preference. TLS 1.3 suites are all PFS+AEAD already and are
# governed by ciphers_tls1.3, left at the library default (PFS-only). A
# future TLS-1.3-only listener is possible once every MQTT client is
# confirmed 1.3-capable (run a compatibility test first).
ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256

allow_anonymous false
password_file $PASSWD
acl_file $ACLFILE
EOF

# --- 3) migration bridge (only while migration_bridge.enabled=true) ----------
# This broker connects as a CLIENT to the old broker and imports
# everything ("topic # in 0") — MQTT bridges preserve the retain flag, so
# the complete retained store migrates with it.
# !! Loop hazard: if the address points at THIS broker after the cutover,
# you get a self-bridge. deploy.sh --cutover therefore force-disables the
# option BEFORE the host port changes.
if [ "$(jq -r '.migration_bridge.enabled' "$OPTS")" = "true" ]; then
  MB_ADDR=$(jq -r '.migration_bridge.address' "$OPTS" | tr -d '\n')
  MB_USER=$(jq -r '.migration_bridge.remote_username' "$OPTS" | tr -d '\n')
  MB_PW=$(jq -r --arg u "$MB_USER" '.logins[] | select(.username == $u) | .password' "$OPTS" | tr -d '\n')
  if [ -z "$MB_PW" ]; then
    echo "[run.sh] ERROR: migration_bridge.enabled, but login '$MB_USER' missing in logins" >&2
    exit 1
  fi
  MB_BRIDGE_CAFILE=$(jq -r '.migration_bridge.bridge_cafile' "$OPTS" | tr -d '\n')
  MB_BRIDGE_CERTFILE=$(jq -r '.migration_bridge.bridge_certfile' "$OPTS" | tr -d '\n')
  MB_BRIDGE_KEYFILE=$(jq -r '.migration_bridge.bridge_keyfile' "$OPTS" | tr -d '\n')
  for f in "$MB_BRIDGE_CAFILE" "$MB_BRIDGE_CERTFILE" "$MB_BRIDGE_KEYFILE"; do
    validate_ssl_or_share_path "$f"
  done
  cat >> "$CONF" <<EOF

connection migration-oldbroker
address $MB_ADDR
bridge_cafile $MB_BRIDGE_CAFILE
bridge_certfile $MB_BRIDGE_CERTFILE
bridge_keyfile $MB_BRIDGE_KEYFILE
remote_username $MB_USER
remote_password $MB_PW
remote_clientid mosquitto-standalone-migration
topic # in 0
notifications false
cleansession true
restart_timeout 5 30
EOF
  echo "[run.sh] migration bridge to old broker active ($MB_ADDR, topic # in 0)"
else
  echo "[run.sh] migration bridge off (normal operation)"
fi

echo "[run.sh] starting mosquitto (file ACL is enforced — no go-auth)"
exec mosquitto -c "$CONF"
