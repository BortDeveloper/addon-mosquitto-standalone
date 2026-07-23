#!/usr/bin/env bash
#
# deploy.sh — bring the "Mosquitto Standalone" add-on onto the HAOS host
# and orchestrate the broker switch (motivation: README.md — the official
# add-on's file ACL is not enforced, home-assistant/addons#4571).
#
# Phases (each is a dry run without --apply):
#   status    (default) show the state of both add-ons
#   --install copy the add-on to /addons, build it, copy the logins from
#             the official add-on (server-side — passwords never leave
#             the host), start it in PARALLEL on host port 18883; the
#             migration bridge pulls the retained store from the old broker.
#   --update  roll out a new add-on version (sync source, rebuild, restart).
#   --cutover order is safety-critical (self-bridge loop!):
#             1. migration_bridge.enabled=false
#             2. stop old add-on + boot=manual
#             3. host port 18883 -> 8883   4. boot=auto
#             5. restart + verification
#   --rollback stop the new add-on / back to 18883, start the official
#             add-on again (boot=auto). Clients reconnect on their own.
#
# Examples:
#   ./scripts/deploy.sh                       # status
#   ./scripts/deploy.sh --install --apply
#   ./scripts/deploy.sh --cutover             # review the plan
#   ./scripts/deploy.sh --cutover --apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/.local/deploy.conf"
ADDON_DIRNAME="mosquitto-standalone"
NEW_SLUG="local_mosquitto_standalone"
OLD_SLUG="core_mosquitto"
MIGRATION_PORT=18883
FINAL_PORT=8883
PHASE="status"
DRY_RUN=1
QUIET=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { [[ "${QUIET}" -eq 1 ]] || printf '%s [INFO]  %s\n' "$(ts)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install|--update|--cutover|--rollback] [--apply] [--config FILE] [--quiet]

  (no phase)    Show the status of both broker add-ons.
  --install     Install the add-on + run it in parallel on :${MIGRATION_PORT}.
  --update      Roll out a new add-on version (sync source, rebuild, restart).
  --cutover     Replace the old broker (take over port ${FINAL_PORT}).
  --rollback    Back to the official add-on.
  --apply       Actually execute the phase (without: dry run / plan).
  --config FILE Deploy configuration (default: .local/deploy.conf).
  --quiet       Less output.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)  PHASE="install"; shift ;;
    --update)   PHASE="update"; shift ;;
    --cutover)  PHASE="cutover"; shift ;;
    --rollback) PHASE="rollback"; shift ;;
    --apply)    DRY_RUN=0; shift ;;
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

[[ -f "${CONFIG_FILE}" ]] || { err "Configuration missing: ${CONFIG_FILE} (template: deploy.conf.example)"; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
[[ -n "${BROKER_SSH:-}" ]] || { err "BROKER_SSH missing in ${CONFIG_FILE}"; exit 1; }
[[ -d "${REPO_ROOT}/${ADDON_DIRNAME}" ]] || { err "Add-on source missing: ${REPO_ROOT}/${ADDON_DIRNAME}"; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes)
if [[ -n "${SSH_IDENTITY:-}" ]]; then
  # Absolute paths are taken as-is, relative ones resolve against the repo root.
  case "${SSH_IDENTITY}" in
    /*) SSH_OPTS+=(-i "${SSH_IDENTITY}") ;;
    *)  SSH_OPTS+=(-i "${REPO_ROOT}/${SSH_IDENTITY}") ;;
  esac
fi

bssh() { ssh "${SSH_OPTS[@]}" "${BROKER_SSH}" "$@"; }

# All Supervisor API calls run on the target host (that is where the
# SUPERVISOR_TOKEN lives); this script never sees passwords. JSON bodies
# go to curl via stdin (-d @-) to avoid quoting acrobatics here.
api_get_raw() { # $1=slug -> info JSON on stdout
  bssh 'curl -s http://supervisor/addons/'"$1"'/info -H "Authorization: Bearer $SUPERVISOR_TOKEN"'
}
api_post() { # $1=slug, $2=endpoint, $3=json-body ('' = no body)
  if [[ -n "$3" ]]; then
    printf '%s' "$3" | bssh 'R=$(curl -s -X POST http://supervisor/addons/'"$1"'/'"$2"' -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" -d @-);
      [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "API '"$1"'/'"$2"' failed: $R" >&2; exit 1; }'
  else
    bssh 'R=$(curl -s -X POST http://supervisor/addons/'"$1"'/'"$2"' -H "Authorization: Bearer $SUPERVISOR_TOKEN");
      [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "API '"$1"'/'"$2"' failed: $R" >&2; exit 1; }'
  fi
}

show_status() {
  log "=== old broker (${OLD_SLUG}) ==="
  api_get_raw "${OLD_SLUG}" \
    | jq -r '.data | "  state=\(.state) boot=\(.boot) version=\(.version) logins=\(.options.logins | map(.username) | join(","))"' \
    || warn "old add-on not queryable"
  log "=== new add-on (${NEW_SLUG}) ==="
  local info
  if info="$(api_get_raw "${NEW_SLUG}")" && [[ "$(jq -r '.result' <<<"${info}")" == "ok" ]]; then
    jq -r '.data | "  state=\(.state) boot=\(.boot) version=\(.version) host_port=\(.network["8883/tcp"]) bridge=\(.options.migration_bridge.enabled) logins=\(.options.logins | map(.username) | join(","))"' <<<"${info}"
  else
    log "  (not installed yet)"
  fi
}

do_install() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] plan --install:"
    log "  1. ${ADDON_DIRNAME}/ -> ${BROKER_SSH}:/addons/${ADDON_DIRNAME}"
    log "  2. store reload + install ${NEW_SLUG} (local image build)"
    log "  3. copy the official add-on's logins server-side (bridge on)"
    log "  4. start on host port :${MIGRATION_PORT} (old broker untouched)"
    log "  5. verification: add-on log + retained comparison old/new"
    return
  fi

  log "1/5 transfer add-on source ..."
  tar -C "${REPO_ROOT}" -cf - "${ADDON_DIRNAME}" \
    | bssh "rm -rf '/addons/${ADDON_DIRNAME}' && tar -C /addons -xf -"

  log "2/5 reload store + install (local build, may take a while) ..."
  # Deliberately against the Supervisor API instead of the ha CLI: the CLI
  # was renamed from "addons" to "apps" in 2026 and "ha addons reload" is
  # a no-op on new hosts — the API endpoints are stable.
  bssh 'R=$(curl -s -X POST http://supervisor/store/reload -H "Authorization: Bearer $SUPERVISOR_TOKEN");
    [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "store/reload failed: $R" >&2; exit 1; }'
  sleep 3
  # Idempotent: if the add-on is already installed, only the source/store
  # were refreshed (rebuilds on changes go through a version bump).
  if api_get_raw "${NEW_SLUG}" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    log "  already installed — install skipped"
  else
    bssh 'R=$(curl -s -X POST http://supervisor/store/addons/'"${NEW_SLUG}"'/install -H "Authorization: Bearer $SUPERVISOR_TOKEN");
      [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "install failed: $R" >&2; exit 1; }
      echo "  add-on installed (image built locally)"'
  fi

  log "3/5 copy logins from the official add-on (server-side) ..."
  # Fetch the NEW add-on's current options (= schema defaults), replace
  # only the logins and enable the bridge — path options stay untouched
  # and the schema stays satisfied.
  bssh 'set -e; T=$SUPERVISOR_TOKEN
    L=$(curl -s http://supervisor/addons/'"${OLD_SLUG}"'/info -H "Authorization: Bearer $T" | jq ".data.options.logins")
    O=$(curl -s http://supervisor/addons/'"${NEW_SLUG}"'/info -H "Authorization: Bearer $T" | jq ".data.options")
    B=$(jq -n --argjson o "$O" --argjson l "$L" "{options: (\$o | .logins = \$l | .migration_bridge.enabled = true)}")
    R=$(curl -s -X POST http://supervisor/addons/'"${NEW_SLUG}"'/options -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d "$B")
    [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "options set failed: $R" >&2; exit 1; }
    echo "  logins copied: $(echo "$L" | jq -r "map(.username) | join(\",\")")"'

  log "4/5 start the add-on (parallel on :${MIGRATION_PORT}) ..."
  api_post "${NEW_SLUG}" start ''
  sleep 8

  log "5/5 verification: add-on log (last lines) ..."
  bssh "ha addons logs ${NEW_SLUG} 2>/dev/null | tail -15" | sed 's/^/    /' || true
  verify_retained || warn "retained comparison not possible — check manually"

  log "-> expectation: 'migration bridge ... active', bridge connect in the log,"
  log "   retained counts old/new converge (the bridge needs a few seconds)."
  log "-> cutover once the numbers match: $(basename "$0") --cutover --apply"
}

# Retained comparison old (:${FINAL_PORT}) vs. new (:${MIGRATION_PORT}) —
# best effort from a host with mosquitto-clients + a valid client
# certificate (VERIFY_SSH in deploy.conf; empty = skipped). The login used
# for counting (VERIFY_LOGIN, must have 'read #' in the ACL) is looked up
# in the old add-on's options server-side and handed to the measurement
# host via stdin — never through this script's argv (mosquitto_sub itself
# unfortunately only supports -P; the argv visibility stays confined to
# the measurement host).
# Measurement method: count the retain flag via the format string. Do NOT
# use --retained-only — it disconnects on the first live message and
# yields fluctuating undercounts on a busy broker (see the guide, §4).
verify_retained() {
  [[ -n "${VERIFY_SSH:-}" ]] || { warn "VERIFY_SSH not set — check skipped"; return 1; }
  [[ -n "${VERIFY_LOGIN:-}" ]] || { warn "VERIFY_LOGIN not set — check skipped"; return 1; }
  local pw old_n new_n broker_host="${BROKER_SSH#*@}"
  pw="$(api_get_raw "${OLD_SLUG}" | jq -r --arg u "${VERIFY_LOGIN}" '.data.options.logins[] | select(.username == $u) | .password')" || return 1
  [[ -n "${pw}" ]] || { warn "login ${VERIFY_LOGIN} not found"; return 1; }
  count_retained() { # $1=port -> number of retained messages
    printf '%s\n' "${pw}" | ssh "${SSH_OPTS[@]}" "${VERIFY_SSH}" 'read -r PW;
      mosquitto_sub -h '"${broker_host}"' -p '"$1"' '"${VERIFY_TLS_ARGS:-}"' \
        -i retained-count-'"$1"' -u '"${VERIFY_LOGIN}"' -P "$PW" \
        -F "%r" -t "#" -W 15 2>/dev/null | grep -c "^1"'
  }
  old_n="$(count_retained "${FINAL_PORT}")" || return 1
  new_n="$(count_retained "${MIGRATION_PORT}")" || return 1
  log "  retained messages: old=${old_n}  new=${new_n}"
}

# Roll out a new add-on version: sync the source, store reload, update API
# (rebuilds the image and restarts the add-on with the new version).
# Precondition: version in config.yaml was bumped — otherwise the
# Supervisor sees no update.
do_update() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] plan --update:"
    log "  1. ${ADDON_DIRNAME}/ -> ${BROKER_SSH}:/addons/${ADDON_DIRNAME} + store reload"
    log "  2. POST /store/addons/${NEW_SLUG}/update (rebuild + restart, ~15 s downtime)"
    return
  fi
  log "1/2 transfer add-on source + store reload ..."
  tar -C "${REPO_ROOT}" -cf - "${ADDON_DIRNAME}" \
    | bssh "rm -rf '/addons/${ADDON_DIRNAME}' && tar -C /addons -xf -"
  bssh 'R=$(curl -s -X POST http://supervisor/store/reload -H "Authorization: Bearer $SUPERVISOR_TOKEN");
    [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "store/reload failed: $R" >&2; exit 1; }'
  sleep 3
  log "2/2 run the update (rebuild + restart) ..."
  bssh 'R=$(curl -s -X POST http://supervisor/store/addons/'"${NEW_SLUG}"'/update -H "Authorization: Bearer $SUPERVISOR_TOKEN");
    [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "update failed: $R" >&2; exit 1; }'
  sleep 10
  bssh "ha addons logs ${NEW_SLUG} 2>/dev/null | tail -10" | sed 's/^/    /' || true
}

do_cutover() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] plan --cutover (order is safety-critical):"
    log "  1. ${NEW_SLUG}: migration_bridge.enabled=false (loop protection BEFORE the port change)"
    log "  2. ${OLD_SLUG}: stop + boot=manual (no ${FINAL_PORT} conflict after reboot)"
    log "  3. ${NEW_SLUG}: host port ${MIGRATION_PORT} -> ${FINAL_PORT}"
    log "  4. ${NEW_SLUG}: boot=auto"
    log "  5. ${NEW_SLUG}: restart + verification (reconnects, no self-bridge)"
    log "  Short downtime (~10 s); all clients reconnect on their own."
    return
  fi

  log "1/5 set migration_bridge.enabled=false (logins are kept) ..."
  bssh 'set -e; T=$SUPERVISOR_TOKEN
    O=$(curl -s http://supervisor/addons/'"${NEW_SLUG}"'/info -H "Authorization: Bearer $T" | jq ".data.options | .migration_bridge.enabled = false")
    R=$(curl -s -X POST http://supervisor/addons/'"${NEW_SLUG}"'/options -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d "{\"options\": $O}")
    [ "$(echo "$R" | jq -r .result)" = "ok" ] || { echo "options set failed: $R" >&2; exit 1; }'

  log "2/5 stop the old broker + boot=manual ..."
  api_post "${OLD_SLUG}" stop ''
  api_post "${OLD_SLUG}" options '{"boot": "manual"}'

  log "3/5 move the host port to ${FINAL_PORT} ..."
  api_post "${NEW_SLUG}" options '{"network": {"8883/tcp": '"${FINAL_PORT}"'}}'

  log "4/5 boot=auto for the new add-on ..."
  api_post "${NEW_SLUG}" options '{"boot": "auto"}'

  log "5/5 restart + verification ..."
  api_post "${NEW_SLUG}" restart ''
  sleep 10
  bssh "ha addons logs ${NEW_SLUG} 2>/dev/null | grep -iE 'new client connected|error|migration' | tail -15" | sed 's/^/    /' || true

  echo "" >&2
  warn "=============================================================================="
  warn " POST-CHECKS after the cutover:"
  warn "  1. Log above: 'migration bridge off (normal operation)' + all clients"
  warn "     connected again."
  warn "  2. NEGATIVE TEST (must pass now!): subscribing to '#' with a write-only"
  warn "     login must deliver NOTHING — the ACL is now actually enforced."
  warn "  3. Critical retained topics present (whatever your automation relies on)."
  warn "  4. Application-level end-to-end in daily use."
  warn " ROLLBACK at any time: $(basename "$0") --rollback --apply"
  warn "=============================================================================="
}

do_rollback() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "[dry-run] plan --rollback:"
    log "  1. ${NEW_SLUG}: stop, boot=manual, port back to ${MIGRATION_PORT}"
    log "  2. ${OLD_SLUG}: start + boot=auto"
    return
  fi
  log "1/2 stop the new add-on + back to :${MIGRATION_PORT} ..."
  api_post "${NEW_SLUG}" stop ''
  api_post "${NEW_SLUG}" options '{"boot": "manual"}'
  api_post "${NEW_SLUG}" options '{"network": {"8883/tcp": '"${MIGRATION_PORT}"'}}'
  log "2/2 start the official add-on + boot=auto ..."
  api_post "${OLD_SLUG}" start ''
  api_post "${OLD_SLUG}" options '{"boot": "auto"}'
  log "Rollback done — clients reconnect to the old broker."
}

log "phase: ${PHASE} | mode: $([[ ${DRY_RUN} -eq 1 ]] && echo DRY-RUN || echo APPLY) | target: ${BROKER_SSH}"
case "${PHASE}" in
  status)   show_status ;;
  install)  do_install ;;
  update)   do_update ;;
  cutover)  do_cutover ;;
  rollback) do_rollback ;;
esac
log "Done."
