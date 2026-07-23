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

CAFILE=$(jq -r '.cafile' "$OPTS")
CERTFILE=$(jq -r '.certfile' "$OPTS")
KEYFILE=$(jq -r '.keyfile' "$OPTS")
ACLFILE=$(jq -r '.acl_file' "$OPTS")

for f in "$CAFILE" "$CERTFILE" "$KEYFILE" "$ACLFILE"; do
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
log_type warning
log_type notice
connection_messages true

# Large retained stores (several thousand messages) exceed Mosquitto's
# default max_queued_messages=1000 when a client subscribes to broad
# wildcards — parts of the retained flood get dropped ("Outgoing messages
# are being dropped", observed during the first deployment). Raise the
# limit generously.
max_queued_messages 10000

listener 8883
cafile $CAFILE
certfile $CERTFILE
keyfile $KEYFILE
require_certificate true

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
  MB_ADDR=$(jq -r '.migration_bridge.address' "$OPTS")
  MB_USER=$(jq -r '.migration_bridge.remote_username' "$OPTS")
  MB_PW=$(jq -r --arg u "$MB_USER" '.logins[] | select(.username == $u) | .password' "$OPTS")
  if [ -z "$MB_PW" ]; then
    echo "[run.sh] ERROR: migration_bridge.enabled, but login '$MB_USER' missing in logins" >&2
    exit 1
  fi
  cat >> "$CONF" <<EOF

connection migration-oldbroker
address $MB_ADDR
bridge_cafile $(jq -r '.migration_bridge.bridge_cafile' "$OPTS")
bridge_certfile $(jq -r '.migration_bridge.bridge_certfile' "$OPTS")
bridge_keyfile $(jq -r '.migration_bridge.bridge_keyfile' "$OPTS")
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
