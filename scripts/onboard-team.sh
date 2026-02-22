#!/usr/bin/env bash
#
# onboard-team.sh — Guided team onboarding workflow for MyPA platform
#
# Walks a platform admin through setting up a new team: CRM workspace,
# admin gateway config, PA provisioning, Tailscale Funnel + Caddy gateway
# exposure, and onboarding card generation for iOS app access.
#
# Usage:
#   Interactive:       ./onboard-team.sh
#   Non-interactive:   ./onboard-team.sh --manifest team.json
#   Resume:            ./onboard-team.sh --resume --state-dir /opt/mypa/state
#   Dry run:           ./onboard-team.sh --dry-run --manifest team.json
#   Help:              ./onboard-team.sh --help
#
# Prerequisites:
#   - Docker running on PA Fleet droplet
#   - pactl.sh in the same directory
#   - Twenty CRM running (TWENTY_CRM_URL)
#   - API key: BRAVE_API_KEY (recommended)
#   - Tailscale installed with Funnel capability
#   - jq, curl, openssl, envsubst available
#
set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1" >&2; }
fatal()   { error "$1"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"; }
prompt()  { echo -en "${CYAN}>>> ${NC}$1 "; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates"
CADDY_TMPL="$TEMPLATE_DIR/caddy/pa-gateway.caddy.tmpl"
CADDY_PA_CONFIG="/etc/caddy/conf.d/pa-gateways.caddy"

# --- Defaults ---
MANIFEST=""
RESUME=false
DRY_RUN=false
STATE_DIR="/opt/mypa/state"
TESTFLIGHT_URL="${TESTFLIGHT_URL:-https://testflight.apple.com/join/XXXXX}"

usage() {
  cat <<'EOF'
Usage:
  ./onboard-team.sh                          Interactive mode (default)
  ./onboard-team.sh --manifest team.json     Non-interactive (all inputs from file)
  ./onboard-team.sh --resume                 Resume interrupted onboarding
  ./onboard-team.sh --dry-run                Validate without side effects

Options:
  --manifest <file>   JSON manifest with team info and member list
  --resume            Resume from state file (finds latest for team)
  --state-dir <dir>   Directory for state files (default: /opt/mypa/state)
  --dry-run           Run pre-flight only, no API calls or provisioning
  --testflight <url>  TestFlight invite URL (default: env TESTFLIGHT_URL)
  -h, --help          Show this help text
EOF
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --manifest)    MANIFEST="$2"; shift 2 ;;
    --resume)      RESUME=true; shift ;;
    --state-dir)   STATE_DIR="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --testflight)  TESTFLIGHT_URL="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             fatal "Unknown argument: $1" ;;
  esac
done

# ============================================================
# State file management
# SECURITY: State files are stored in a restricted directory with
# 600 permissions. Never use `source` to load — parse key=value only.
# ============================================================
STATE_FILE=""

state_file_path() {
  local slug="$1"
  echo "${STATE_DIR}/mypa-onboard-${slug}.state"
}

save_state() {
  [[ -z "$STATE_FILE" ]] && return
  local key="$1" val="$2"
  # Validate key is alphanumeric + underscore only (prevent injection)
  if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    warn "Invalid state key rejected: $key"
    return 1
  fi
  # Update existing key or append
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    chmod 600 "$tmp"
    sed "s|^${key}=.*|${key}=\"${val}\"|" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  else
    echo "${key}=\"${val}\"" >> "$STATE_FILE"
  fi
}

load_state() {
  # SECURITY: Never source state files — parse key=value pairs safely.
  # This prevents arbitrary code execution via malicious state file content.
  [[ -z "$STATE_FILE" || ! -f "$STATE_FILE" ]] && return 1
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Extract key=value (strip surrounding quotes from value)
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"(.*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Export as shell variable using declare (safe, no eval)
      declare -g "$key=$val"
    else
      warn "Skipping malformed state line: ${line:0:40}..."
    fi
  done < "$STATE_FILE"
  return 0
}

scrub_secrets_from_state() {
  # SECURITY: Remove secret values from state file after they've been consumed.
  # Keeps the key with a "SCRUBBED" marker so resume logic still sees the phase completed.
  [[ -z "$STATE_FILE" || ! -f "$STATE_FILE" ]] && return
  local secret_keys="CRM_API_KEY|ADMIN_BOT_TOKEN|GW_TOKEN"
  local tmp
  tmp=$(mktemp)
  chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^($secret_keys)= ]]; then
      echo "${BASH_REMATCH[1]}=\"SCRUBBED\"" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$STATE_FILE"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

init_state() {
  local slug="$1"
  # Ensure state directory exists with restricted permissions
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  STATE_FILE=$(state_file_path "$slug")
  if [[ -f "$STATE_FILE" ]]; then
    # Verify ownership before loading
    if [[ "$(stat -c '%U' "$STATE_FILE" 2>/dev/null || stat -f '%Su' "$STATE_FILE")" != "$(whoami)" ]]; then
      fatal "State file owned by different user — possible tampering: $STATE_FILE"
    fi
    log "Resuming from state file: $STATE_FILE"
    load_state
  else
    log "Creating state file: $STATE_FILE"
    touch "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
}

# ============================================================
# Manifest reader (non-interactive mode)
# ============================================================
manifest_get() {
  local key="$1"
  [[ -z "$MANIFEST" ]] && return 1
  jq -r "$key // empty" "$MANIFEST" 2>/dev/null
}

manifest_member_count() {
  [[ -z "$MANIFEST" ]] && echo 0 && return
  jq -r '.members | length' "$MANIFEST" 2>/dev/null || echo 0
}

manifest_member_field() {
  local idx="$1" field="$2"
  jq -r ".members[$idx].$field // empty" "$MANIFEST" 2>/dev/null
}

# ============================================================
# Interactive input helper
# ============================================================
ask() {
  local var_name="$1" question="$2" default="${3:-}"
  # If manifest mode, skip interactive prompt
  if [[ -n "$MANIFEST" ]]; then return; fi

  if [[ -n "$default" ]]; then
    prompt "$question [$default]: "
  else
    prompt "$question: "
  fi
  local answer
  read -r answer
  if [[ -z "$answer" && -n "$default" ]]; then
    answer="$default"
  fi
  eval "$var_name=\"\$answer\""
}

wait_for_enter() {
  [[ -n "$MANIFEST" ]] && return
  prompt "${1:-Press Enter to continue...}"
  read -r
}

# ============================================================
# Slug generation
# ============================================================
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ============================================================
# PHASE 1: Pre-flight Checks
# ============================================================
phase_preflight() {
  header "PHASE 1: Pre-flight Checks"

  local failed=false

  # Required env vars
  for var in BRAVE_API_KEY; do
    if [[ -z "${!var:-}" ]]; then
      warn "Missing env var: $var (web search will be unavailable)"
    else
      log "Env var set: $var"
    fi
  done

  # pactl.sh must be present and executable
  if [[ ! -x "$SCRIPT_DIR/pactl.sh" ]]; then
    error "Missing or not executable: $SCRIPT_DIR/pactl.sh"
    failed=true
  else
    log "pactl.sh found: $SCRIPT_DIR/pactl.sh"
  fi

  # Templates
  for tmpl in pa-default/openclaw.json pa-default/SOUL.md pa-default/IDENTITY.md pa-admin/openclaw.json pa-admin/SOUL.md; do
    if [[ ! -f "$TEMPLATE_DIR/$tmpl" ]]; then
      error "Missing template: $tmpl"
      failed=true
    else
      log "Template found: $tmpl"
    fi
  done

  # JSON validity
  for json in pa-default/openclaw.json pa-admin/openclaw.json; do
    if [[ -f "$TEMPLATE_DIR/$json" ]]; then
      jq -e . "$TEMPLATE_DIR/$json" >/dev/null 2>&1 || { error "Invalid JSON: $json"; failed=true; }
    fi
  done

  # Caddy template
  [[ ! -f "$CADDY_TMPL" ]] && { error "Missing: $CADDY_TMPL"; failed=true; }

  # provision-pa.sh
  [[ ! -f "$SCRIPT_DIR/provision-pa.sh" ]] && { error "Missing: provision-pa.sh"; failed=true; }

  # jq, curl, openssl
  for cmd in jq curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { error "Missing command: $cmd"; failed=true; }
  done

  # Manifest validation (if provided)
  if [[ -n "$MANIFEST" ]]; then
    [[ ! -f "$MANIFEST" ]] && fatal "Manifest file not found: $MANIFEST"
    jq -e . "$MANIFEST" >/dev/null 2>&1 || fatal "Invalid JSON in manifest: $MANIFEST"
    jq -e '.team_name' "$MANIFEST" >/dev/null 2>&1 || fatal "Manifest missing team_name"
    jq -e '.members | type == "array"' "$MANIFEST" >/dev/null 2>&1 || fatal "Manifest missing members[]"
    log "Manifest validated: $MANIFEST"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run: skipping connectivity checks"
    [[ "$failed" == "true" ]] && fatal "Pre-flight checks failed (see above)"
    log "Dry-run pre-flight checks passed"
    exit 0
  fi

  # Docker connectivity
  if docker info >/dev/null 2>&1; then
    log "Docker is running"
  else
    error "Docker is not running or not accessible"
    failed=true
  fi

  # Twenty CRM connectivity
  if [[ -n "${TWENTY_CRM_URL:-}" ]]; then
    local crm_status
    crm_status=$(curl -sf "${TWENTY_CRM_URL}/healthz" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
    if [[ "$crm_status" == "ok" ]]; then
      log "Twenty CRM healthy at ${TWENTY_CRM_URL}"
    else
      error "Twenty CRM unhealthy: $crm_status"
      failed=true
    fi
  else
    warn "TWENTY_CRM_URL not set — CRM workspace setup will require manual URL input"
  fi

  # Tailscale
  if command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then
      log "Tailscale is running"
    else
      error "Tailscale is installed but not connected"
      failed=true
    fi
  else
    error "Tailscale not installed (required for Funnel gateway exposure)"
    failed=true
  fi

  [[ "$failed" == "true" ]] && fatal "Pre-flight checks failed (see above)"
  log "All pre-flight checks passed"
}

# ============================================================
# PHASE 2: Team Setup
# ============================================================
phase_team_setup() {
  header "PHASE 2: Team Setup"

  # --- 2.1: Collect team info ---
  local team_name team_slug leader_name leader_email crm_sync member_count

  if [[ -n "$MANIFEST" ]]; then
    team_name=$(manifest_get '.team_name')
    leader_name=$(manifest_get '.leader.name')
    leader_email=$(manifest_get '.leader.email')
    crm_sync=$(manifest_get '.crm_sync // false')
    member_count=$(manifest_member_count)
  else
    ask team_name "Team display name (e.g., Acme Corp)"
    ask leader_name "Team leader name"
    ask leader_email "Team leader email"
    ask crm_sync "Enable CRM sync to admin hub? (y/n)" "n"
    [[ "$crm_sync" == "y" || "$crm_sync" == "yes" ]] && crm_sync=true || crm_sync=false
    ask member_count "Number of team members to provision" "1"
  fi

  [[ -z "$team_name" ]] && fatal "Team name is required"
  [[ -z "$leader_name" ]] && fatal "Leader name is required"
  [[ -z "$leader_email" ]] && fatal "Leader email is required"

  team_slug=$(slugify "$team_name")
  if [[ -z "$MANIFEST" ]]; then
    ask team_slug "Team slug" "$team_slug"
  fi

  log "Team: $team_name (slug: $team_slug)"
  log "Leader: $leader_name <$leader_email>"
  log "CRM Sync: $crm_sync"
  log "Members: $member_count"

  # Init state file
  init_state "$team_slug"
  save_state "TEAM_NAME" "$team_name"
  save_state "TEAM_SLUG" "$team_slug"
  save_state "LEADER_NAME" "$leader_name"
  save_state "LEADER_EMAIL" "$leader_email"
  save_state "CRM_SYNC" "$crm_sync"
  save_state "MEMBER_COUNT" "$member_count"
  save_state "PHASE" "team_setup"

  # --- 2.2: CRM workspace ---
  if [[ "${CRM_WORKSPACE_CREATED:-}" != "true" ]]; then
    header "CRM Workspace Setup"
    echo -e "${BOLD}Manual step:${NC} Create a Twenty CRM workspace for this team."
    echo ""
    echo "  1. Go to your Twenty CRM admin panel"
    echo "  2. Admin Panel -> Create Workspace"
    echo "  3. Name it: $team_name"
    echo "  4. Set subdomain to: $team_slug"
    echo "  5. Set $leader_name ($leader_email) as workspace admin"
    echo ""

    local crm_subdomain
    if [[ -n "$MANIFEST" ]]; then
      crm_subdomain="$team_slug"
    else
      ask crm_subdomain "Enter the subdomain you created" "$team_slug"
    fi

    local crm_workspace_url="${TWENTY_CRM_URL:-https://crm.yourdomain.com}/${crm_subdomain}"
    log "Verifying workspace at $crm_workspace_url..."

    local ws_health
    ws_health=$(curl -sf "${crm_workspace_url}/healthz" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
    if [[ "$ws_health" != "ok" ]]; then
      warn "Workspace at $crm_workspace_url returned: $ws_health"
      warn "This might be normal if DNS hasn't propagated yet."
      wait_for_enter "Press Enter once the workspace is accessible..."
    else
      log "Workspace healthy: $crm_workspace_url"
    fi

    # API key
    echo ""
    echo -e "${BOLD}Manual step:${NC} Create an API key in the new workspace."
    echo "  Go to: $crm_workspace_url -> Settings -> API Keys -> Create"
    echo ""

    local crm_api_key
    if [[ -n "$MANIFEST" ]]; then
      crm_api_key=$(manifest_get '.crm_api_key')
    else
      ask crm_api_key "Paste the API key"
    fi

    if [[ -n "$crm_api_key" ]]; then
      local api_test
      api_test=$(curl -sf "${crm_workspace_url}/rest/metadata/objects" \
        -H "Authorization: Bearer ${crm_api_key}" 2>/dev/null || echo "FAIL")
      if [[ "$api_test" == "FAIL" ]] || echo "$api_test" | jq -e '.error' >/dev/null 2>&1; then
        warn "API key validation failed — double-check the key and workspace URL"
      else
        log "CRM API key verified"
      fi
    fi

    save_state "CRM_WORKSPACE_CREATED" "true"
    save_state "CRM_WORKSPACE_URL" "$crm_workspace_url"
    save_state "CRM_API_KEY" "${crm_api_key:-}"
    save_state "CRM_SUBDOMAIN" "$crm_subdomain"
  else
    log "CRM workspace already configured (skipping)"
  fi

  # --- 2.3: Team sync config ---
  local sync_config="${TEAM_SYNC_CONFIG:-/opt/mypa/team-sync-config.json}"
  if [[ -f "$sync_config" ]]; then
    log "Updating team sync config: crm_sync=$crm_sync"
    local tmp_sync
    tmp_sync=$(mktemp)
    jq --arg team "$team_slug" \
       --arg url "${CRM_WORKSPACE_URL:-}" \
       --arg key "${CRM_API_KEY:-}" \
       --argjson sync "${crm_sync}" \
       '.teams[$team] = {sync_enabled: $sync, workspace_url: $url, api_key: $key}' \
       "$sync_config" > "$tmp_sync" && mv "$tmp_sync" "$sync_config"
    log "Team sync config updated"
  else
    warn "Team sync config not found at $sync_config — skipping"
  fi
  # API key is no longer needed once team sync config has been written.
  save_state "CRM_API_KEY" "SCRUBBED"

  # --- 2.4: Admin gateway config ---
  if [[ "${ADMIN_AGENT_CONFIGURED:-}" != "true" ]]; then
    header "Admin Gateway Config (Platform Admin's Master PA)"

    local agent_id="admin-${team_slug}"
    echo ""
    echo -e "${BOLD}Add the following to your admin gateway openclaw.json:${NC}"
    echo ""
    echo -e "${CYAN}--- agents.list[] entry ---${NC}"
    echo "{"
    echo "  \"id\": \"$agent_id\","
    echo "  \"name\": \"$team_name\","
    echo "  \"workspace\": \"~/.openclaw/workspace-${team_slug}\""
    echo "}"
    echo ""
    echo -e "${CYAN}--- bindings[] entry ---${NC}"
    echo "{"
    echo "  \"agentId\": \"$agent_id\","
    echo "  \"match\": { \"channel\": \"telegram\", \"accountId\": \"${team_slug}\" }"
    echo "}"
    echo ""

    # Admin bot token
    echo -e "${BOLD}Manual step:${NC} Create a Telegram bot for the admin team agent."
    echo "  1. Message @BotFather on Telegram"
    echo "  2. /newbot -> name: Admin ${team_name} PA -> username: admin_${team_slug}_pa_bot"
    echo "  3. Copy the bot token"
    echo ""

    local admin_bot_token
    if [[ -n "$MANIFEST" ]]; then
      admin_bot_token=$(manifest_get '.admin_bot_token')
    else
      ask admin_bot_token "Paste the admin bot token (or press Enter to skip)"
    fi

    if [[ -n "$admin_bot_token" ]]; then
      echo ""
      echo -e "${CYAN}--- channels.telegram.accounts entry ---${NC}"
      echo "\"${team_slug}\": {"
      echo "  \"botToken\": \"$admin_bot_token\""
      echo "}"
      echo ""
    fi

    echo -e "${BOLD}After adding the config:${NC}"
    echo "  1. Commit the changes"
    echo "  2. Restart the admin gateway"
    echo ""

    wait_for_enter "Press Enter when the admin gateway is configured and restarted..."

    save_state "ADMIN_AGENT_CONFIGURED" "true"
    save_state "ADMIN_BOT_TOKEN" "${admin_bot_token:-}"
    save_state "ADMIN_AGENT_ID" "$agent_id"
  else
    log "Admin gateway already configured (skipping)"
  fi
  # Bot token is no longer needed after admin config is completed.
  save_state "ADMIN_BOT_TOKEN" "SCRUBBED"

  # --- 2.5: Tailscale Funnel + Caddy ---
  if [[ "${FUNNEL_CONFIGURED:-}" != "true" ]]; then
    header "Gateway Exposure (Tailscale Funnel + Caddy)"

    # Caddy PA gateway config
    if [[ ! -f "$CADDY_PA_CONFIG" ]]; then
      log "Installing Caddy PA gateway config..."
      local caddy_dir
      caddy_dir=$(dirname "$CADDY_PA_CONFIG")
      if [[ ! -d "$caddy_dir" ]]; then
        sudo mkdir -p "$caddy_dir" 2>/dev/null || mkdir -p "$caddy_dir"
      fi
      sudo cp "$CADDY_TMPL" "$CADDY_PA_CONFIG" 2>/dev/null || cp "$CADDY_TMPL" "$CADDY_PA_CONFIG"
      log "Caddy PA gateway config installed at $CADDY_PA_CONFIG"

      # Reload Caddy
      if command -v caddy >/dev/null 2>&1; then
        sudo caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || warn "Caddy reload failed — reload manually"
      elif systemctl is-active caddy >/dev/null 2>&1; then
        sudo systemctl reload caddy 2>/dev/null || warn "Caddy reload failed — reload manually"
      else
        warn "Caddy not found — reload manually after verifying config"
      fi
    else
      log "Caddy PA gateway config already exists"
    fi

    # Tailscale Funnel
    log "Setting up Tailscale Funnel on port 18789..."
    if tailscale funnel --bg 18789 2>/dev/null; then
      log "Tailscale Funnel active on port 18789"
    else
      warn "Tailscale Funnel setup returned non-zero — check 'tailscale funnel status'"
    fi

    # Get Tailscale hostname
    local ts_hostname
    ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//' || echo "")
    if [[ -z "$ts_hostname" ]]; then
      if [[ -n "$MANIFEST" ]]; then
        fatal "Could not determine Tailscale hostname"
      else
        ask ts_hostname "Enter Tailscale hostname (e.g., mypa-fleet.ts.net)"
      fi
    fi

    log "Funnel hostname: $ts_hostname"
    save_state "FUNNEL_CONFIGURED" "true"
    save_state "FUNNEL_HOSTNAME" "$ts_hostname"
  else
    log "Funnel already configured (skipping)"
  fi

  scrub_secrets_from_state
  save_state "PHASE" "members"
  log "Team setup complete"
}

# ============================================================
# PHASE 3: Member Provisioning
# ============================================================
phase_members() {
  header "PHASE 3: Member Provisioning"

  # Reload state
  load_state || true
  local team_slug="${TEAM_SLUG:-}"
  local team_name="${TEAM_NAME:-}"
  local crm_sync="${CRM_SYNC:-false}"
  local funnel_hostname="${FUNNEL_HOSTNAME:-mypa-fleet.ts.net}"
  local member_count="${MEMBER_COUNT:-0}"

  [[ -z "$team_slug" ]] && fatal "No team slug in state — run team setup first"

  # Create cards directory (restricted — contains gateway tokens)
  local cards_dir="${STATE_DIR}/mypa-onboard-${team_slug}-cards"
  mkdir -p "$cards_dir"
  chmod 700 "$cards_dir"

  # --- Batch manual pre-reqs ---
  if [[ -z "$MANIFEST" ]]; then
    echo ""
    echo -e "${BOLD}Manual step:${NC} Create Google Workspace accounts for ALL team members."
    echo "  Go to: admin.google.com -> Users -> Add User"
    echo ""
    echo "  Members to provision:"
  fi

  # Collect member info first (for batch display)
  declare -a member_names member_emails member_types member_pa_names
  local i=0

  while [[ $i -lt $member_count ]]; do
    local m_name m_email m_type m_pa_name

    if [[ -n "$MANIFEST" ]]; then
      m_name=$(manifest_member_field "$i" "name")
      m_email=$(manifest_member_field "$i" "email")
      m_type=$(manifest_member_field "$i" "type")
      [[ -z "$m_type" ]] && m_type="member"
    else
      echo ""
      echo -e "${BOLD}--- Member $((i+1)) of $member_count ---${NC}"
      ask m_name "Member name"
      ask m_email "PA email (Google Workspace account)"
      ask m_type "PA type (member/admin)" "member"
    fi

    # Auto-generate PA instance name (slugified — no special chars, no collisions)
    local firstname
    firstname=$(echo "$m_name" | awk '{print $1}' | tr '[:upper:]' '[:lower:]' \
      | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    m_pa_name="${firstname}-${team_slug}-pa"

    if [[ ! "$m_pa_name" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]]; then
      error "Invalid PA name generated: '$m_pa_name'. Check member name and team slug."
      continue
    fi

    member_names+=("$m_name")
    member_emails+=("$m_email")
    member_types+=("$m_type")
    member_pa_names+=("$m_pa_name")

    if [[ -z "$MANIFEST" ]]; then
      echo "  [ ] $m_email for $m_name (PA: $m_pa_name)"
    fi

    i=$((i + 1))
  done

  if [[ -z "$MANIFEST" && $member_count -gt 0 ]]; then
    echo ""
    wait_for_enter "Complete the Google Workspace accounts above, then press Enter..."
  fi

  # --- Provision loop ---
  local provisioned="" failed=""
  i=0

  while [[ $i -lt $member_count ]]; do
    local pa_name="${member_pa_names[$i]}"
    local m_name="${member_names[$i]}"
    local m_email="${member_emails[$i]}"
    local m_type="${member_types[$i]}"

    # Check if already provisioned (for resume)
    if echo "${MEMBERS_PROVISIONED:-}" | grep -q "$pa_name"; then
      log "Already provisioned: $pa_name (skipping)"
      i=$((i + 1))
      continue
    fi

    header "Provisioning: $pa_name ($m_name)"

    # Generate gateway token
    local gw_token
    gw_token=$(openssl rand -hex 16)

    # Build provision-pa.sh arguments
    local provision_args=(
      --name "$pa_name"
      --member "$m_name"
      --team "$team_name"
      --email "$m_email"
      --type "$m_type"
      --gateway-token "$gw_token"
    )
    [[ "$crm_sync" == "true" ]] && provision_args+=(--crm-sync)

    # Delegate to provision-pa.sh
    log "Delegating to provision-pa.sh..."
    local provision_output
    if provision_output=$(bash "$SCRIPT_DIR/provision-pa.sh" "${provision_args[@]}" 2>&1); then
      log "Provisioning succeeded: $pa_name"

      # Get gateway port from Docker labels
      local gateway_port
      gateway_port=$(docker inspect "mypa-${pa_name}" --format '{{index .Config.Labels "mypa.gateway_port"}}' 2>/dev/null || echo "")

      # If we couldn't get the port, use a fallback
      if [[ -z "$gateway_port" ]]; then
        warn "Could not auto-detect gateway port for $pa_name"
        if [[ -z "$MANIFEST" ]]; then
          ask gateway_port "Enter the container's gateway port (check: docker inspect mypa-${pa_name})"
        else
          warn "Skipping Caddy route — add manually"
          gateway_port=""
        fi
      fi

      # Add Caddy route
      if [[ -n "$gateway_port" && -f "$CADDY_PA_CONFIG" ]]; then
        log "Adding Caddy route: /${pa_name}/* -> localhost:${gateway_port}"
        local caddy_block
        caddy_block=$(printf '\n\thandle_path /%s/* {\n\t\t# SECURITY: Strip Tailscale headers to prevent forgery\n\t\trequest_header -Tailscale-User-Login\n\t\trequest_header -Tailscale-User-Name\n\t\trequest_header -Tailscale-User-Login-Raw\n\t\trequest_header -Tailscale-User-Profile-Pic\n\t\treverse_proxy localhost:%s\n\t}\n' "$pa_name" "$gateway_port")

        # Insert before the closing respond/brace
        local tmp_caddy
        tmp_caddy=$(mktemp)
        sed "/respond \"Unknown PA gateway path\" 404/i\\
$(echo "$caddy_block" | sed 's/\\/\\\\/g; s/$/\\/')
" "$CADDY_PA_CONFIG" > "$tmp_caddy" 2>/dev/null && \
          sudo mv "$tmp_caddy" "$CADDY_PA_CONFIG" 2>/dev/null || \
          mv "$tmp_caddy" "$CADDY_PA_CONFIG"

        # Reload Caddy
        if command -v caddy >/dev/null 2>&1; then
          sudo caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || warn "Caddy reload failed"
        elif systemctl is-active caddy >/dev/null 2>&1; then
          sudo systemctl reload caddy 2>/dev/null || warn "Caddy reload failed"
        fi
      fi

      # Generate PA URL
      local pa_url="wss://${funnel_hostname}/${pa_name}/"

      # Generate onboarding card (contains gateway token — restricted file)
      local card_file="${cards_dir}/${pa_name}.txt"
      cat > "$card_file" <<CARD

  +---------------------------------------------+
  |  PA READY: ${pa_name}
  |
  |  1. Install OpenClaw iOS from TestFlight:
  |     ${TESTFLIGHT_URL}
  |
  |  2. Open app -> Settings -> Manual Gateway
  |     URL:      ${pa_url}
  |     Token:    (see secure card file)
  |
  |  3. Tap Connect -- you're in!
  |
  |  (Optional) Telegram fallback:
  |  Ask admin to create a bot at @BotFather
  +---------------------------------------------+

  GATEWAY TOKEN: ${gw_token}
  (Deliver this token securely — do not send via unencrypted email or chat)

CARD
      chmod 600 "$card_file"
      # Print card location to terminal (NOT the token itself)
      log "Onboarding card saved: $card_file"
      log "  PA URL: ${pa_url}"
      log "  Token: stored in card file (use: cat $card_file)"

      # Track provisioned (store PA name and URL only, not token)
      if [[ -n "$provisioned" ]]; then
        provisioned="${provisioned},${pa_name}|${pa_url}"
      else
        provisioned="${pa_name}|${pa_url}"
      fi
      save_state "MEMBERS_PROVISIONED" "$provisioned"

    else
      error "Provisioning failed for $pa_name"
      echo "$provision_output" | tail -5
      if [[ -n "$failed" ]]; then
        failed="${failed},${pa_name}"
      else
        failed="${pa_name}"
      fi
      save_state "MEMBERS_FAILED" "$failed"
    fi

    i=$((i + 1))
  done

  save_state "PHASE" "verify"
  log "Member provisioning complete"
}

# ============================================================
# PHASE 4: Post-Provisioning Verification
# ============================================================
phase_verify() {
  header "PHASE 4: Post-Provisioning Verification"

  load_state || true
  local team_slug="${TEAM_SLUG:-}"
  local team_name="${TEAM_NAME:-}"
  local funnel_hostname="${FUNNEL_HOSTNAME:-mypa-fleet.ts.net}"
  local crm_sync="${CRM_SYNC:-false}"
  local crm_url="${CRM_WORKSPACE_URL:-}"
  local admin_agent="${ADMIN_AGENT_ID:-admin-${team_slug}}"

  # Parse provisioned members
  local provisioned="${MEMBERS_PROVISIONED:-}"
  local failed="${MEMBERS_FAILED:-}"

  if [[ -n "$provisioned" ]]; then
    log "Checking provisioned PAs..."

    local count_ok=0 count_fail=0
    IFS=',' read -ra members <<< "$provisioned"
    for entry in "${members[@]}"; do
      local pa_name pa_url gw_pass
      pa_name=$(echo "$entry" | cut -d'|' -f1)
      pa_url=$(echo "$entry" | cut -d'|' -f2)
      gw_pass=$(echo "$entry" | cut -d'|' -f3)

      # Check instance status via Docker
      local instance_status
      instance_status=$(docker inspect "mypa-${pa_name}" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")

      if [[ "$instance_status" == "running" ]]; then
        log "$pa_name: RUNNING"
        count_ok=$((count_ok + 1))
      else
        warn "$pa_name: $instance_status"
        count_fail=$((count_fail + 1))
      fi
    done
  fi

  # --- Final Summary ---
  local cards_dir="${STATE_DIR}/mypa-onboard-${team_slug}-cards"
  local num_provisioned=0 num_failed=0
  [[ -n "$provisioned" ]] && num_provisioned=$(echo "$provisioned" | tr ',' '\n' | wc -l | tr -d ' ')
  [[ -n "$failed" ]] && num_failed=$(echo "$failed" | tr ',' '\n' | wc -l | tr -d ' ')

  echo ""
  echo "============================================"
  echo "  TEAM ONBOARDING COMPLETE: $team_name"
  echo "============================================"
  echo ""
  echo "  CRM Workspace:  ${crm_url:-not configured}"
  echo "  CRM Sync:       $(if [[ "$crm_sync" == "true" ]]; then echo 'ENABLED -> admin hub'; else echo 'DISABLED (team-local only)'; fi)"
  echo "  Admin Agent:    $admin_agent (in master gateway)"
  echo "  Gateway Base:   wss://${funnel_hostname}/"
  echo "  Memory:         memory-lancedb (RAG index refresh every 6h)"
  echo "  Members:        ${num_provisioned} provisioned, ${num_failed} failed"
  echo ""

  if [[ -n "$provisioned" ]]; then
    IFS=',' read -ra members <<< "$provisioned"
    for entry in "${members[@]}"; do
      local pa_name pa_url
      pa_name=$(echo "$entry" | cut -d'|' -f1)
      pa_url=$(echo "$entry" | cut -d'|' -f2)
      echo "    - $pa_name  wss://${funnel_hostname}/${pa_name}/"
    done
    echo ""
  fi

  if [[ -n "$failed" ]]; then
    echo "  FAILED:"
    IFS=',' read -ra fail_list <<< "$failed"
    for f in "${fail_list[@]}"; do
      echo "    - $f"
    done
    echo ""
  fi

  echo "  ONBOARDING CARDS: saved to ${cards_dir}/"
  echo ""
  echo "  REMAINING MANUAL STEPS:"
  echo "    [ ] gog OAuth for each PA (interactive browser flow)"
  echo "        Open VNC (pactl vnc <name>) -> Terminal ->"
  echo "        gog auth credentials ~/client_secret.json"
  echo "    [ ] Send onboarding cards to team members"
  echo "    [ ] End-to-end verification tests (after members connect)"
  echo "    [ ] Brief team members on PA capabilities"
  echo ""
  echo "  VERIFICATION TEST MATRIX (per PA, after member connects):"
  echo "    1. \"What model are you running?\"      -> Expected: Claude model name"
  echo "    2. \"Check my email\"                   -> Gmail query"
  echo "    3. \"What's on my calendar?\"            -> Calendar query"
  echo "    4. \"Look up any contact in CRM\"        -> Twenty query"
  echo "    5. \"Run ls -la\"                        -> Should REFUSE"
  echo "    6. \"What do you remember about X?\"     -> Tests RAG"
  echo ""
  echo "  OPTIONAL (add later):"
  echo "    [ ] Create Telegram bots per member at @BotFather"
  echo "    [ ] Configure Slack integration per team"
  echo "    [ ] Add team-specific docs to memory extraPaths"
  echo ""
  echo "============================================"

  save_state "PHASE" "done"
  scrub_secrets_from_state
  log "Onboarding workflow complete (secrets scrubbed from state file)"
}

# ============================================================
# Main
# ============================================================
main() {
  echo ""
  echo -e "${BOLD}MyPA Team Onboarding Workflow${NC}"
  echo "────────────────────────────────"
  echo ""

  # Determine starting phase
  local start_phase="preflight"

  if [[ "$RESUME" == "true" ]]; then
    # Find latest state file
    local latest_state
    latest_state=$(ls -t "${STATE_DIR}"/mypa-onboard-*.state 2>/dev/null | head -1 || echo "")
    if [[ -z "$latest_state" ]]; then
      fatal "No state file found in ${STATE_DIR}/ — nothing to resume"
    fi
    STATE_FILE="$latest_state"
    load_state
    start_phase="${PHASE:-preflight}"
    log "Resuming from phase: $start_phase (state: $STATE_FILE)"
  fi

  case "$start_phase" in
    preflight|pre_flight)
      phase_preflight
      phase_team_setup
      phase_members
      phase_verify
      ;;
    team_setup)
      phase_team_setup
      phase_members
      phase_verify
      ;;
    members)
      phase_members
      phase_verify
      ;;
    verify)
      phase_verify
      ;;
    done)
      log "This team's onboarding is already complete."
      log "State file: $STATE_FILE"
      echo "To re-run, delete the state file and start over."
      ;;
    *)
      fatal "Unknown phase: $start_phase"
      ;;
  esac
}

main "$@"
