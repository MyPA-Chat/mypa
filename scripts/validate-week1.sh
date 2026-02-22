#!/usr/bin/env bash
#
# validate-week1.sh — enforce pre-deployment validation gates for MyPA
#
# This script is intended to run in CI before merging deployment-affecting changes.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_TEMPLATE="$ROOT_DIR/templates/pa-default/openclaw.json"
ADMIN_TEMPLATE="$ROOT_DIR/templates/pa-admin/openclaw.json"

validate_json_file() {
  local path="$1"
  jq -e . "$path" > /dev/null || fatal "Invalid JSON file: $path"
  log "JSON valid: $path"
}

validate_agents_contract() {
  local mode="$1"
  local json="$2"
  if [[ "$mode" == "admin" ]]; then
    echo "$json" | jq -e '.agents.defaults' > /dev/null || fatal "admin template missing agents.defaults"
    echo "$json" | jq -e '.agents.list | type == "array"' > /dev/null || fatal "admin template missing agents.list[]"
    echo "$json" | jq -e '.bindings | type == "array"' > /dev/null || fatal "admin template missing top-level bindings[]"
    echo "$json" | jq -e '(.agents | keys - ["defaults", "list", "_comment"] | length) == 0' > /dev/null || fatal "admin template has unsupported agents keys"
    return
  fi

  echo "$json" | jq -e '.agents.defaults' > /dev/null || fatal "member template missing agents.defaults"
  echo "$json" | jq -e '(.agents | keys - ["defaults", "_comment"] | length) == 0' > /dev/null || fatal "member template has unexpected agents keys"
}

validate_legacy_rejected() {
  local legacy_payload='{ "agents": { "admin": { "workspace": "~/.openclaw/workspace-legacy", "bindings": [] } } }'
  if echo "$legacy_payload" | jq -e '(.agents | keys - ["defaults", "list", "_comment"] | length) == 0' > /dev/null; then
    fatal "Legacy object-keyed agent payload unexpectedly passes strict key contract."
  fi
  log "Legacy object-keyed agent payload rejected by schema contract check (expected)."
}

run_dry_run_checks() {
  local mode="$1"
  log "Running provision script dry-run check for $mode config..."
  if [[ "$mode" == "admin" ]]; then
    bash "$SCRIPT_DIR/provision-pa.sh" \
      --name "mypa-week1-admin-dryrun" \
      --member "MyPA Dryrun Admin" \
      --team "Pilot Team" \
      --email "dryrun-admin@example.com" \
      --telegram-token "000000:dry-run-admin-token" \
      --type "admin" \
      --dry-run
  else
    bash "$SCRIPT_DIR/provision-pa.sh" \
      --name "mypa-week1-member-dryrun" \
      --member "MyPA Dryrun Member" \
      --team "Pilot Team" \
      --email "dryrun-member@example.com" \
      --telegram-token "000000:dry-run-member-token" \
      --type "member" \
      --dry-run
  fi
}

validate_template_contract() {
  local mode="$1"
  local path="$2"
  local json
  json="$(cat "$path")"
  validate_json_file "$path"
  validate_agents_contract "$mode" "$json"
}

validate_operational_scripts() {
  log "Checking operational scripts parse correctly..."
  local scripts=(
    "$SCRIPT_DIR/backup-pas.sh"
    "$SCRIPT_DIR/pactl.sh"
    "$SCRIPT_DIR/bootstrap-droplet.sh"
    "$SCRIPT_DIR/healthcheck.sh"
    "$SCRIPT_DIR/onboard-team.sh"
  )
  for script in "${scripts[@]}"; do
    if [[ -f "$script" ]]; then
      bash -n "$script" || fatal "Syntax error in $(basename "$script")"
      log "Syntax OK: $(basename "$script")"
    else
      fatal "Required operational script not found: $(basename "$script")"
    fi
  done
}

main() {
  log "Week 1 pre-deployment validation bootstrapping..."
  [[ -f "$DEFAULT_TEMPLATE" ]] || fatal "Missing $DEFAULT_TEMPLATE"
  [[ -f "$ADMIN_TEMPLATE" ]] || fatal "Missing $ADMIN_TEMPLATE"

  validate_template_contract "member" "$DEFAULT_TEMPLATE"
  validate_template_contract "admin" "$ADMIN_TEMPLATE"
  validate_legacy_rejected

  run_dry_run_checks "member"
  run_dry_run_checks "admin"

  validate_operational_scripts

  if [[ -n "${OPENCLAW_CANARY_URL:-}" && -n "${OPENCLAW_CANARY_TOKEN:-}" && -n "${OPENCLAW_CANARY_INSTANCE:-}" ]]; then
    log "Canary variables detected. After this script, run live config apply and startup checks against:"
    echo "  OPENCLAW_CANARY_URL=$OPENCLAW_CANARY_URL"
    echo "  OPENCLAW_CANARY_INSTANCE=$OPENCLAW_CANARY_INSTANCE"
    log "For API-level runtime confirmation of both formats, follow docs/WEEK1_VALIDATION.md."
  else
    warn "No OpenClaw canary endpoint variables set; runtime cross-format matrix test should be completed manually for the deployment host."
  fi

  log "Week 1 validation checks passed."
}

main "$@"
