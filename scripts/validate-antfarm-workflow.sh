#!/usr/bin/env bash
#
# validate-antfarm-workflow.sh — lightweight sanity checks for custom Antfarm workflow files
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

FILE="${1:-workflows/pa-provision/workflow.yml}"

[[ -f "$FILE" ]] || fatal "Missing workflow file: $FILE"
command -v yq >/dev/null 2>&1 || fatal "yq is required for YAML parsing in $FILE"

require_present() {
  local label="$1"
  local expression="$2"
  local value
  value="$(yq e "$expression" "$FILE" 2>/dev/null || echo "__MISSING__")"
  if [[ "$value" == "__MISSING__" || "$value" == "null" || -z "$value" ]]; then
    fatal "Missing required Antfarm field in ${FILE}: ${label}"
  fi
  log "Found required field: ${label}"
}

require_min_count() {
  local label="$1"
  local expression="$2"
  local min_count="$3"
  local count
  count="$(yq e "$expression" "$FILE" 2>/dev/null || echo "__MISSING__")"
  if [[ "$count" == "__MISSING__" || "$count" == "null" ]]; then
    count=0
  fi

  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    fatal "Invalid count for ${label} in ${FILE}: ${count}"
  fi

  if [[ "$count" -lt "$min_count" ]]; then
    fatal "Expected at least ${min_count} matches for ${label} in ${FILE}; found ${count}"
  fi
  log "${label}: ${count}"
}

require_id_count() {
  local label="$1"
  local array_expr="$2"
  local id="$3"
  local count
  count="$(yq e "${array_expr} | map(select(.id == \"${id}\")) | length" "$FILE" 2>/dev/null || echo "__MISSING__")"

  if [[ "$count" == "__MISSING__" || "$count" == "null" ]]; then
    count=0
  fi
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
    fatal "Missing required ${label}: ${id}"
  fi
  log "Found required ${label}: ${id}"
}

require_field_match_count() {
  local label="$1"
  local array_expr="$2"
  local field_name="$3"
  local field_value="$4"
  local count
  count="$(yq e "${array_expr} | map(select(.${field_name} == \"${field_value}\")) | length" "$FILE" 2>/dev/null || echo "0")"

  if [[ "$count" == "null" ]]; then
    count=0
  fi
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
    fatal "Missing required ${label}: ${field_value}"
  fi
  log "Found required ${label}: ${field_value}"
}

require_present "workflow id" ".id"
require_present "workflow name" ".name"
require_min_count "agent definitions" ".agents | length" 2
require_min_count "variables block" ".variables | length" 1
require_min_count "workflow steps" ".steps | length" 4
require_min_count "step input blocks" "[.steps[] | select(has(\"input\"))] | length" 5

require_id_count "agent" ".agents" "provisioner"
require_id_count "agent" ".agents" "verifier"

required_step_names=(
  "create-instance"
  "verify-instance-running"
  "verify-skills"
  "verify-security"
  "generate-report"
)

for required_step_name in "${required_step_names[@]}"; do
  require_field_match_count "workflow step" ".steps" "id" "$required_step_name"
done

required_vars=(
  "member_name"
  "team_name"
  "pa_name"
  "pa_email"
  "telegram_token"
  "pa_type"
)

for required_var in "${required_vars[@]}"; do
  require_field_match_count "workflow variable" ".variables" "name" "$required_var"
done

if ! grep -q "antfarm workflow run pa-provision" README.md; then
  warn "README.md does not contain an explicit pa-provision command reference."
fi

if [[ ! -f scripts/provision-pa.sh ]]; then
  fatal "Workflow depends on scripts/provision-pa.sh, but file is missing."
fi

log "Antfarm workflow checks passed: ${FILE}"
