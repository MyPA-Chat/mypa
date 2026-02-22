#!/usr/bin/env bash
#
# provision-pa.sh — Provision a new PA instance via pactl (direct Docker)
#
# Usage:
#   ./provision-pa.sh \
#     --name "alice-pa" \
#     --member "Alice Smith" \
#     --team "Team Alpha" \
#     --email "alicepa@yourdomain.com" \
#     --telegram-token "123456:ABC-DEF" \
#     --type "member"        # or "admin"
#
# Prerequisites:
#   - Docker running on PA Fleet droplet
#   - pactl.sh in the same directory
#   - Template files in ../templates/
#   - API keys in environment (BRAVE_API_KEY recommended)
#
# Twenty CRM Integration:
#   When --type "admin", the script checks for a team workspace in Twenty.
#   Workspace creation itself is manual (Twenty has no API for it). The script
#   verifies the workspace exists and validates the API key against it.
#   Pass TWENTY_WORKSPACE_SUBDOMAIN for the team's CRM workspace subdomain.

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

usage() {
  cat <<EOF
Usage:
  ./provision-pa.sh \
    --name "alice-pa" \
    --member "Alice Smith" \
    --team "Team Alpha" \
    --email "alicepa@yourdomain.com" \
    --telegram-token "123456:ABC-DEF" \
    --type "member"        # or "admin"

Options:
  --gateway-token <tok>    Set gateway auth token (auto-generated if omitted, stored in 1Password)
  --telegram-token <tok>   Telegram bot token (optional — omit for iOS-app-only onboarding)
  --crm-sync               Enable CRM sync from this team's workspace to admin hub (default: disabled)
  --dry-run                Generate config and run all validation gates without provisioning
  -h, --help               Show this help text
EOF
}

validate_json_payload() {
  local label="$1"
  local payload="$2"
  if ! echo "$payload" | jq -e . >/dev/null; then
    fatal "Invalid JSON payload: $label"
  fi
  log "Validated JSON payload: $label"
}

validate_legacy_rejected_format() {
  # Static contract test proving object-keyed formats are rejected by strict schema.
  local legacy_payload='{ "agents": { "admin": { "workspace": "~/.openclaw/workspace-legacy", "bindings": [] } } }'
  if echo "$legacy_payload" | jq -e '(.agents | keys - ["defaults", "list", "_comment"] | length) == 0' >/dev/null; then
    fatal "Legacy object-keyed agent format unexpectedly passes strict key contract."
  fi
  log "Legacy object-keyed format is not accepted by strict agents key contract (expected)."
}

validate_agents_contract() {
  local mode="$1"
  local payload="$2"
  if [[ "$mode" == "admin" ]]; then
    echo "$payload" | jq -e '.agents.defaults' >/dev/null || fatal "admin config missing agents.defaults"
    echo "$payload" | jq -e '.agents.list | type == "array"' >/dev/null || fatal "admin config missing agents.list[]"
    echo "$payload" | jq -e '(.agents | keys - ["defaults", "list", "_comment"] | length) == 0' >/dev/null || fatal "admin config has unsupported top-level agents keys"
    echo "$payload" | jq -e '.bindings | type == "array"' >/dev/null || fatal "admin config missing top-level bindings[]"
    return
  fi

  echo "$payload" | jq -e '.agents.defaults' >/dev/null || fatal "member config missing agents.defaults"
  echo "$payload" | jq -e '(.agents | keys - ["defaults", "_comment"] | length) == 0' >/dev/null || fatal "member config has unexpected top-level agents keys"
  echo "$payload" | jq -e '.agents | has("list") | not' >/dev/null || fatal "member config should not use agents.list[]"
}

require_runtime_env() {
  [[ -z "${BRAVE_API_KEY:-}" ]] && warn "BRAVE_API_KEY not set (web search will be unavailable)"
  [[ -z "${TWENTY_CRM_URL:-}" ]] && fatal "TWENTY_CRM_URL not set"
  [[ -z "${TWENTY_CRM_KEY:-}" ]] && fatal "TWENTY_CRM_KEY not set"
}

# Verify that the Twenty CRM workspace API key is valid by hitting the healthz endpoint
# and attempting a simple API call. This catches bad keys before PA provisioning.
verify_twenty_workspace() {
  local crm_url="$1"
  local crm_key="$2"
  local team="$3"

  log "Verifying Twenty CRM access for team '$team'..."

  # Health check
  local health_status
  health_status=$(curl -sf "${crm_url}/healthz" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
  if [[ "$health_status" != "ok" ]]; then
    warn "Twenty CRM at ${crm_url} is not healthy (status: $health_status)"
    warn "Ensure the team workspace exists at the correct subdomain"
    fatal "Twenty CRM health check failed"
  fi

  # Test API key with a lightweight query
  local api_test
  api_test=$(curl -sf "${crm_url}/rest/metadata/objects" \
    -H "Authorization: Bearer ${crm_key}" 2>/dev/null || echo "FAIL")

  if [[ "$api_test" == "FAIL" ]] || echo "$api_test" | jq -e '.error' >/dev/null 2>&1; then
    warn "Twenty CRM API key is invalid or lacks permissions for this workspace"
    warn "Generate a new key in Twenty: Settings > API Keys"
    fatal "Twenty CRM API key validation failed"
  fi

  log "Twenty CRM workspace verified for team '$team'"
}

# --- Parse arguments ---
PA_NAME=""
MEMBER_NAME=""
TEAM_NAME=""
PA_EMAIL=""
TELEGRAM_TOKEN=""
PA_TYPE="member"
CRM_SYNC=false
DRY_RUN=false
GATEWAY_TOKEN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)          PA_NAME="$2"; shift 2 ;;
    --member)        MEMBER_NAME="$2"; shift 2 ;;
    --team)          TEAM_NAME="$2"; shift 2 ;;
    --email)         PA_EMAIL="$2"; shift 2 ;;
    --telegram-token) TELEGRAM_TOKEN="$2"; shift 2 ;;
    --type)          PA_TYPE="$2"; shift 2 ;;
    --gateway-token) GATEWAY_TOKEN="$2"; shift 2 ;;
    --crm-sync)      CRM_SYNC=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# --- Validate required args ---
[[ -z "$PA_NAME" ]]        && fatal "Missing --name"
[[ -z "$MEMBER_NAME" ]]    && fatal "Missing --member"
[[ -z "$TEAM_NAME" ]]      && fatal "Missing --team"
[[ -z "$PA_EMAIL" ]]       && fatal "Missing --email"
# --telegram-token is optional (iOS app is primary onboarding channel)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
OPENCLAW_TEMPLATE="$TEMPLATE_DIR/pa-default/openclaw.json"

if [[ "$PA_TYPE" == "admin" ]]; then
  SOUL_TEMPLATE="$TEMPLATE_DIR/pa-admin/SOUL.md"
  OPENCLAW_TEMPLATE="$TEMPLATE_DIR/pa-admin/openclaw.json"
else
  SOUL_TEMPLATE="$TEMPLATE_DIR/pa-default/SOUL.md"
fi

[[ ! -f "$TEMPLATE_DIR/pa-default/openclaw.json" ]]           && fatal "Missing template: pa-default/openclaw.json"
[[ ! -f "$SOUL_TEMPLATE" ]]                                    && fatal "Missing template: $SOUL_TEMPLATE"
[[ ! -f "$TEMPLATE_DIR/pa-default/IDENTITY.md" ]]              && fatal "Missing template: pa-default/IDENTITY.md"
[[ ! -f "$OPENCLAW_TEMPLATE" ]]                               && fatal "Missing template: $OPENCLAW_TEMPLATE"

# ============================================================
# Dry-run validation (runs before any API calls)
# ============================================================
log "Validating golden template ($PA_TYPE)..."

# Substitute environment variables into the template
# In dry-run mode, unset env vars become empty strings — that's fine for validation
OPENCLAW_CONFIG=$(envsubst < "$OPENCLAW_TEMPLATE" 2>/dev/null || cat "$OPENCLAW_TEMPLATE")

# Inject Telegram bot token (if provided)
if [[ -n "$TELEGRAM_TOKEN" ]]; then
  if [[ "$PA_TYPE" == "admin" ]]; then
    OPENCLAW_CONFIG=$(echo "$OPENCLAW_CONFIG" | jq \
      --arg token "$TELEGRAM_TOKEN" \
      '.channels.telegram.accounts.personal.botToken = $token')
  else
    OPENCLAW_CONFIG=$(echo "$OPENCLAW_CONFIG" | jq \
      --arg token "$TELEGRAM_TOKEN" \
      '.channels.telegram.botToken = $token')
  fi
else
  # No Telegram token — disable the Telegram channel
  if [[ "$PA_TYPE" != "admin" ]]; then
    OPENCLAW_CONFIG=$(echo "$OPENCLAW_CONFIG" | jq '.channels.telegram.enabled = false')
  fi
  warn "No --telegram-token provided. Telegram channel disabled. Use iOS app for primary access."
fi

# Inject gateway token (if provided — otherwise pactl config auto-generates one)
if [[ -n "$GATEWAY_TOKEN" ]]; then
  OPENCLAW_CONFIG=$(echo "$OPENCLAW_CONFIG" | jq \
    --arg tok "$GATEWAY_TOKEN" \
    '.gateway.auth.mode = "token" | .gateway.auth.token = $tok')
fi

validate_json_payload "openclaw.json template ($PA_TYPE)" "$OPENCLAW_CONFIG"
validate_agents_contract "$PA_TYPE" "$OPENCLAW_CONFIG"
validate_legacy_rejected_format

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run complete. JSON config validation and format checks passed."
  exit 0
fi

# ============================================================
# Live deployment — require runtime env from here on
# ============================================================
require_runtime_env

# Verify pactl.sh exists
[[ ! -x "$SCRIPT_DIR/pactl.sh" ]] && fatal "pactl.sh not found or not executable at $SCRIPT_DIR/pactl.sh"

# ============================================================
# Step 0: Verify Twenty CRM workspace exists for this team
# ============================================================
verify_twenty_workspace "$TWENTY_CRM_URL" "$TWENTY_CRM_KEY" "$TEAM_NAME"

# ============================================================
# Step 0b: Update team sync config (per-team CRM → admin hub toggle)
# ============================================================
SYNC_CONFIG="${TEAM_SYNC_CONFIG:-/opt/mypa/team-sync-config.json}"
if [[ -f "$SYNC_CONFIG" ]]; then
  log "Updating team sync config: crm_sync=$CRM_SYNC for team '$TEAM_NAME'"
  tmp_sync=$(mktemp)
  jq --arg team "$TEAM_NAME" \
     --arg url "$TWENTY_CRM_URL" \
     --arg key "$TWENTY_CRM_KEY" \
     --argjson sync "$CRM_SYNC" \
     '.teams[$team] = {sync_enabled: $sync, workspace_url: $url, api_key: $key}' \
     "$SYNC_CONFIG" > "$tmp_sync" && mv "$tmp_sync" "$SYNC_CONFIG"
  if [[ "$CRM_SYNC" == "true" ]]; then
    log "CRM sync ENABLED: $TEAM_NAME → admin hub"
  else
    log "CRM sync DISABLED for $TEAM_NAME (records stay in team workspace only)"
  fi
else
  warn "Team sync config not found at $SYNC_CONFIG — skipping sync toggle"
  warn "Deploy templates/team-sync-config.json to $SYNC_CONFIG on the droplet"
fi

# ============================================================
# Step 1: Create PA container via pactl
# ============================================================
log "Creating PA container: $PA_NAME"

"$SCRIPT_DIR/pactl.sh" create "$PA_NAME" \
  --member "$MEMBER_NAME" \
  --team "$TEAM_NAME" \
  --email "$PA_EMAIL" || fatal "Failed to create PA container"

log "Container created: mypa-$PA_NAME"

# ============================================================
# Step 2: Start PA container
# ============================================================
log "Starting PA container..."

"$SCRIPT_DIR/pactl.sh" start "$PA_NAME" || fatal "Failed to start PA container"

# Wait for container to be running
log "Waiting for container to come online..."
STATUS="unknown"
for i in {1..15}; do
  STATUS=$(docker inspect "mypa-${PA_NAME}" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "running" ]]; then
    break
  fi
  sleep 2
done

if [[ "$STATUS" != "running" ]]; then
  fatal "Container did not start within 30 seconds. Status: $STATUS"
fi

log "Container is running"

# ============================================================
# Step 3: Apply golden template via pactl config
# ============================================================
log "Applying golden template via pactl config..."

local_template="pa-default"
[[ "$PA_TYPE" == "admin" ]] && local_template="pa-admin"

# Pass --gateway-token if provided; otherwise pactl auto-generates one
local -a gw_args=()
[[ -n "$GATEWAY_TOKEN" ]] && gw_args+=(--gateway-token "$GATEWAY_TOKEN")

"$SCRIPT_DIR/pactl.sh" config "$PA_NAME" \
  --template "$local_template" \
  "${gw_args[@]}" \
  --pa-name "$PA_NAME" \
  --member-name "$MEMBER_NAME" \
  --team-name "$TEAM_NAME" || fatal "Failed to apply config"

log "Golden template applied"

# ============================================================
# Step 4: Restart to pick up config
# ============================================================
"$SCRIPT_DIR/pactl.sh" restart "$PA_NAME" || warn "Restart failed (non-fatal)"

# Get VNC URL for summary
VNC_PORT=$(docker inspect "mypa-${PA_NAME}" --format '{{index .Config.Labels "mypa.vnc_port"}}' 2>/dev/null || echo "unknown")

# ============================================================
# Step 5: Output summary
# ============================================================
echo ""
echo "============================================"
echo "  PA PROVISIONED SUCCESSFULLY"
echo "============================================"
echo ""
echo "  Instance:      $PA_NAME"
echo "  Container:     mypa-$PA_NAME"
echo "  Member:        $MEMBER_NAME"
echo "  Team:          $TEAM_NAME"
echo "  Email:         $PA_EMAIL"
echo "  Type:          $PA_TYPE"
echo "  CRM Sync:      $(if $CRM_SYNC; then echo 'ENABLED → admin hub'; else echo 'DISABLED (team-local only)'; fi)"
echo "  Status:        $STATUS"
echo "  Gateway Auth:  token (managed via 1Password)"
echo "  VNC:           http://localhost:$VNC_PORT (noVNC web UI)"
echo "  CRM URL:       $TWENTY_CRM_URL"
echo ""
echo "  NEXT STEPS:"
echo "  1. Store gateway token in 1Password: scripts/rotate-gateway-token.sh $PA_NAME"
echo "  2. Open VNC to run: claude setup-token"
echo "  3. Team member connects via OpenClaw iOS app (gateway + token)"
echo "  4. Run gog OAuth: gog auth credentials ~/client_secret.json"
echo "     (authorize with $PA_EMAIL)"
echo "  5. Test: Ask PA 'What model are you running?'"
echo "  6. Test: Ask PA 'Check my email'"
echo "  7. Test: Ask PA 'What's on my calendar today?'"
echo "  8. Test: Ask PA 'Look up any contact in our CRM'"
echo ""
if [[ "$PA_TYPE" == "admin" ]]; then
echo "  TEAM ADMIN NOTES:"
echo "  - This PA has admin access to the team's Twenty CRM workspace"
echo "  - CRM data syncs ONE-WAY to admin hub (platform admin's aggregate view)"
echo "  - Team members cannot see the admin hub or other team workspaces"
echo ""
fi
echo "  MANAGE:"
echo "  pactl status $PA_NAME     # Check status"
echo "  pactl logs $PA_NAME       # View logs"
echo "  pactl vnc $PA_NAME        # Get VNC URL"
echo "  pactl restart $PA_NAME    # Restart"
echo "============================================"
