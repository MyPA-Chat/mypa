#!/usr/bin/env bash
#
# pactl.sh — PA container management via direct Docker commands
#
# Primary provisioning tool for OpenClaw PA containers. Replaces the Claworc
# control plane with simple, auditable shell + Docker commands.
#
# Usage:
#   pactl create <name> [--image <tag>] [--member <name>] [--team <name>] [--email <email>]
#                       [--vnc-port <port>] [--gateway-port <port>]
#   pactl config <name> [--template <dir>] [--gateway-token <tok>] [--show-token]
#                       [--pa-name <display>] [--member-name <name>] [--team-name <team>]
#   pactl start <name>
#   pactl stop <name>
#   pactl restart <name>
#   pactl status [name]
#   pactl list
#   pactl logs <name> [--follow]
#   pactl exec <name> <command...>
#   pactl vnc <name>             # Print noVNC URL
#   pactl backup <name>
#   pactl token-rotate <name>
#   pactl remove <name>          # Stops and removes container (volume preserved)
#   pactl help
#
# Environment:
#   MYPA_IMAGE    — Default OpenClaw Docker image (default: glukw/openclaw-vnc-chrome:latest)
#   MYPA_NETWORK  — Docker network name (default: mypa)
#   MYPA_DATA_DIR — Host directory for bind-mounted config (default: /opt/mypa/data)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[pactl]${NC} $1"; }
warn()  { echo -e "${YELLOW}[pactl]${NC} $1"; }
error() { echo -e "${RED}[pactl]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

MYPA_IMAGE="${MYPA_IMAGE:-glukw/openclaw-vnc-chrome:latest}"
MYPA_NETWORK="${MYPA_NETWORK:-mypa}"
MYPA_DATA_DIR="${MYPA_DATA_DIR:-/opt/mypa/data}"
CONTAINER_PREFIX="mypa-"
VNC_PORT_BASE=6081     # noVNC web UI (first PA gets 6081, second 6082, etc.)
GATEWAY_PORT_BASE=3001 # OpenClaw gateway (first PA gets 3001, second 3002, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../templates" 2>/dev/null && pwd || echo "")"

# ============================================================
# Helpers
# ============================================================

ensure_network() {
  if ! docker network inspect "$MYPA_NETWORK" >/dev/null 2>&1; then
    log "Creating Docker network: $MYPA_NETWORK"
    docker network create "$MYPA_NETWORK"
  fi
}

container_name() {
  echo "${CONTAINER_PREFIX}${1}"
}

container_exists() {
  docker inspect "$(container_name "$1")" >/dev/null 2>&1
}

container_running() {
  local status
  status=$(docker inspect "$(container_name "$1")" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  [[ "$status" == "running" ]]
}

require_container() {
  if ! container_exists "$1"; then
    fatal "Container $(container_name "$1") does not exist. Run: pactl create $1"
  fi
}

# ============================================================
# Commands
# ============================================================

next_available_port() {
  local base=$1
  local port=$base
  while docker ps -a --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; do
    port=$((port + 1))
  done
  echo "$port"
}

cmd_create() {
  local name=""
  local image="$MYPA_IMAGE"
  local member=""
  local team=""
  local email=""
  local vnc_port=""
  local gateway_port=""
  local memory="2g"
  local privileged="false"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --image)        image="$2"; shift 2 ;;
      --member)       member="$2"; shift 2 ;;
      --team)         team="$2"; shift 2 ;;
      --email)        email="$2"; shift 2 ;;
      --vnc-port)     vnc_port="$2"; shift 2 ;;
      --gateway-port) gateway_port="$2"; shift 2 ;;
      --memory)       memory="$2"; shift 2 ;;
      --privileged)   privileged="true"; shift ;;
      -*)             fatal "Unknown flag: $1" ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"; shift
        else
          fatal "Unexpected argument: $1"
        fi
        ;;
    esac
  done

  [[ -z "$name" ]] && fatal "Usage: pactl create <name> [--image <tag>] [--member <name>] [--team <name>] [--email <email>] [--vnc-port <port>] [--gateway-port <port>] [--memory <size>] [--privileged]"

  local cname
  cname=$(container_name "$name")
  local data_dir="$MYPA_DATA_DIR/$name"

  if container_exists "$name"; then
    fatal "Container $cname already exists. Use 'pactl remove $name' first."
  fi

  ensure_network

  # Auto-assign ports if not specified
  [[ -z "$vnc_port" ]]     && vnc_port=$(next_available_port $VNC_PORT_BASE)
  [[ -z "$gateway_port" ]] && gateway_port=$(next_available_port $GATEWAY_PORT_BASE)

  # Create host data directory for config files
  mkdir -p "$data_dir"

  log "Creating PA container: $cname"
  log "  Image:        $image"
  log "  VNC port:     $vnc_port (http://localhost:$vnc_port)"
  log "  Gateway port: $gateway_port"
  log "  Network:      $MYPA_NETWORK"

  # Build label args
  local label_args=()
  label_args+=(--label "mypa.managed=true")
  label_args+=(--label "mypa.name=$name")
  label_args+=(--label "mypa.vnc_port=$vnc_port")
  label_args+=(--label "mypa.gateway_port=$gateway_port")
  [[ -n "$member" ]] && label_args+=(--label "mypa.member=$member")
  [[ -n "$team" ]]   && label_args+=(--label "mypa.team=$team")
  [[ -n "$email" ]]  && label_args+=(--label "mypa.email=$email")

  # Named volumes for persistent data (survive container recreates)
  local vol_openclaw="${CONTAINER_PREFIX}${name}-openclaw"
  local vol_clawd="${CONTAINER_PREFIX}${name}-clawd"
  local vol_chrome="${CONTAINER_PREFIX}${name}-chrome"
  local vol_brew="${CONTAINER_PREFIX}${name}-homebrew"

  # Capability set for systemd-in-Docker + Chrome + VNC
  # SYS_ADMIN: cgroup management for systemd, mount operations
  # SYS_PTRACE: Chrome sandbox process inspection
  # SYS_RESOURCE: rlimits for systemd services
  # NET_ADMIN: network namespace setup
  # AUDIT_WRITE: systemd journal logging
  # Use --privileged flag to override with full privileged mode if needed
  local -a cap_args=()
  if [[ "${privileged:-false}" == "true" ]]; then
    cap_args=(--privileged)
    log "WARNING: Running in privileged mode (use --no-privileged for hardened caps)"
  else
    cap_args=(
      --cap-add SYS_ADMIN
      --cap-add SYS_PTRACE
      --cap-add SYS_RESOURCE
      --cap-add NET_ADMIN
      --cap-add AUDIT_WRITE
      --cap-add MKNOD
      --cap-add DAC_OVERRIDE
    )
  fi

  docker create \
    --name "$cname" \
    --network "$MYPA_NETWORK" \
    --restart unless-stopped \
    "${cap_args[@]}" \
    --cgroupns=host \
    --security-opt label=disable \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${vol_openclaw}:/home/claworc/.openclaw" \
    -v "${vol_clawd}:/home/claworc/clawd" \
    -v "${vol_chrome}:/home/claworc/.config/google-chrome" \
    -v "${vol_brew}:/home/linuxbrew/.linuxbrew" \
    -v "${data_dir}:/opt/pa-config:ro" \
    -p "127.0.0.1:${vnc_port}:6081" \
    -p "127.0.0.1:${gateway_port}:3000" \
    --memory "${memory}" \
    --cpus 2 \
    "${label_args[@]}" \
    "$image"

  log "Container created: $cname"
  log ""
  log "Next steps:"
  log "  1. pactl config $name --template pa-default  # Push golden config"
  log "  2. pactl start $name                         # Start the container"
  log "  3. Open VNC: http://localhost:$vnc_port       # Access browser for Claude auth"
  log "  4. pactl exec $name claude setup-token       # Sync Claude auth token"
}

cmd_start() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl start <name>"
  require_container "$name"

  if container_running "$name"; then
    warn "$(container_name "$name") is already running"
    return 0
  fi

  log "Starting $(container_name "$name")..."
  docker start "$(container_name "$name")"
  log "Started"
}

cmd_stop() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl stop <name>"
  require_container "$name"

  log "Stopping $(container_name "$name")..."
  docker stop "$(container_name "$name")"
  log "Stopped"
}

cmd_restart() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl restart <name>"
  require_container "$name"

  log "Restarting $(container_name "$name")..."
  docker restart "$(container_name "$name")"
  log "Restarted"
}

cmd_status() {
  local name="${1:-}"

  if [[ -n "$name" ]]; then
    require_container "$name"
    local cname
    cname=$(container_name "$name")

    local status
    status=$(docker inspect "$cname" --format '{{.State.Status}}' 2>/dev/null)
    local started
    started=$(docker inspect "$cname" --format '{{.State.StartedAt}}' 2>/dev/null)
    local image
    image=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null)
    local member
    member=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.member"}}' 2>/dev/null || echo "—")
    local team
    team=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.team"}}' 2>/dev/null || echo "—")

    echo ""
    echo -e "  ${CYAN}$name${NC}"
    echo "  Status:  $status"
    echo "  Image:   $image"
    echo "  Started: $started"
    echo "  Member:  $member"
    echo "  Team:    $team"
    echo ""
  else
    cmd_list
  fi
}

cmd_list() {
  local containers
  containers=$(docker ps -a --filter "label=mypa.managed=true" --format '{{.Names}}' 2>/dev/null | sort)

  if [[ -z "$containers" ]]; then
    echo "No pactl-managed PA containers found."
    return 0
  fi

  printf "\n  %-20s %-10s %-25s %-20s %-30s\n" "NAME" "STATUS" "MEMBER" "TEAM" "IMAGE"
  printf "  %-20s %-10s %-25s %-20s %-30s\n" "----" "------" "------" "----" "-----"

  while IFS= read -r cname; do
    local status member team image short_name
    status=$(docker inspect "$cname" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    member=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.member"}}' 2>/dev/null || echo "—")
    team=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.team"}}' 2>/dev/null || echo "—")
    image=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || echo "unknown")
    short_name="${cname#"$CONTAINER_PREFIX"}"

    local color="$RED"
    [[ "$status" == "running" ]] && color="$GREEN"

    printf "  %-20s ${color}%-10s${NC} %-25s %-20s %-30s\n" "$short_name" "$status" "$member" "$team" "$image"
  done <<< "$containers"
  echo ""
}

cmd_config() {
  local name=""
  local template_type=""
  local gateway_password=""
  local gateway_token=""
  local pa_display_name=""
  local member_name=""
  local team_name=""
  local show_token=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --template)          template_type="$2"; shift 2 ;;
      --gateway-password)  gateway_password="$2"; shift 2 ;;
      --gateway-token)     gateway_token="$2"; shift 2 ;;
      --pa-name)           pa_display_name="$2"; shift 2 ;;
      --member-name)       member_name="$2"; shift 2 ;;
      --team-name)         team_name="$2"; shift 2 ;;
      --show-token)        show_token=true; shift ;;
      -*)                  fatal "Unknown flag: $1" ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"; shift
        else
          fatal "Unexpected argument: $1"
        fi
        ;;
    esac
  done

  [[ -z "$name" ]] && fatal "Usage: pactl config <name> [--template pa-admin|pa-default] [--gateway-token <token>]"

  require_container "$name"

  if ! container_running "$name"; then
    fatal "Container $(container_name "$name") must be running to push config. Run: pactl start $name"
  fi

  local cname
  cname=$(container_name "$name")

  # Determine template directory
  local tmpl_dir=""
  if [[ -n "$template_type" && -n "$TEMPLATE_DIR" ]]; then
    tmpl_dir="$TEMPLATE_DIR/$template_type"
    [[ -d "$tmpl_dir" ]] || fatal "Template directory not found: $tmpl_dir"
  fi

  # Generate gateway token if not provided (prefer token over password)
  if [[ -n "$gateway_token" ]]; then
    log "Using provided gateway token"
  elif [[ -n "$gateway_password" ]]; then
    # Legacy compat: convert password to token
    gateway_token="$gateway_password"
    log "Using provided gateway password as token (legacy compat)"
  else
    gateway_token=$(openssl rand -hex 16)
    log "Generated new gateway token (use --show-token to display)"
  fi

  # Resolve Docker bridge gateway IP for trustedProxies
  local bridge_gateway=""
  bridge_gateway=$(docker inspect "$cname" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' 2>/dev/null | head -c 15)
  [[ -z "$bridge_gateway" ]] && bridge_gateway="172.18.0.1"
  log "Docker bridge gateway: $bridge_gateway"

  # Defaults for display names
  [[ -z "$pa_display_name" ]] && pa_display_name="$name"
  [[ -z "$member_name" ]] && member_name=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.member"}}' 2>/dev/null || echo "$name")
  [[ -z "$team_name" ]] && team_name=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.team"}}' 2>/dev/null || echo "Personal")

  if [[ -n "$tmpl_dir" ]]; then
    # Push openclaw.json with substitutions
    if [[ -f "$tmpl_dir/openclaw.json" ]]; then
      log "Pushing openclaw.json from $template_type template..."
      local tmp_config
      tmp_config=$(mktemp)

      # Remove the openai-compatible model block — let OpenClaw use native Anthropic auth
      # Substitute remaining template variables
      python3 -c "
import json, sys

with open('$tmpl_dir/openclaw.json') as f:
    config = json.load(f)

# Replace model config: remove openai-compatible, use native Anthropic provider
if 'agents' in config and 'defaults' in config['agents']:
    defaults = config['agents']['defaults']
    if 'model' in defaults:
        # Remove the proxy-based model config; OpenClaw will use its native
        # Anthropic provider after 'openclaw models auth setup-token' runs
        del defaults['model']

# Set hardened gateway auth (token mode + Tailscale)
# Preserve controlUi and rateLimit from template
if 'gateway' in config:
    gw = config['gateway']
    gw['auth'] = {
        'mode': 'token',
        'token': '$gateway_token',
        'allowTailscale': True,
        'rateLimit': {
            'maxAttempts': 10,
            'windowMs': 60000,
            'lockoutMs': 300000
        }
    }
    gw['trustedProxies'] = ['127.0.0.1', '$bridge_gateway']
    gw['tailscale'] = {'mode': 'off', 'resetOnExit': False}
    # Ensure controlUi settings survive (device auth disabled until Tailscale identity auth)
    if 'controlUi' not in gw:
        gw['controlUi'] = {
            'dangerouslyDisableDeviceAuth': True,
            'allowInsecureAuth': True
        }

# Set memory search path
if 'agents' in config and 'defaults' in config['agents']:
    defaults = config['agents']['defaults']
    if 'memorySearch' in defaults:
        defaults['memorySearch']['extraPaths'] = ['/home/claworc/team-docs']

# Clear placeholder API keys — will be set when available
if 'search' in config:
    config['search']['apiKey'] = ''

# Clear placeholder Telegram tokens
if 'channels' in config and 'telegram' in config['channels']:
    tg = config['channels']['telegram']
    if 'accounts' in tg:
        for acct in tg['accounts'].values():
            if isinstance(acct, dict) and 'botToken' in acct:
                token = acct['botToken']
                if token.startswith('\${') or token == 'PLACEHOLDER_BOT_TOKEN':
                    acct['botToken'] = ''

print(json.dumps(config, indent=2))
" > "$tmp_config"

      docker cp "$tmp_config" "$cname:/home/claworc/.openclaw/openclaw.json"
      docker exec "$cname" chown claworc:claworc /home/claworc/.openclaw/openclaw.json
      # Also push to root's config (gateway reads from root's, tools from claworc's)
      docker cp "$tmp_config" "$cname:/root/.openclaw/openclaw.json"
      rm -f "$tmp_config"
      log "  openclaw.json pushed (both /home/claworc + /root)"
    fi

    # Push SOUL.md with substitutions
    if [[ -f "$tmpl_dir/SOUL.md" ]]; then
      log "Pushing SOUL.md..."
      local tmp_soul
      tmp_soul=$(mktemp)

      python3 -c "
import re
with open('$tmpl_dir/SOUL.md') as f:
    content = f.read()
content = content.replace('{{PA_NAME}}', '$pa_display_name')
content = content.replace('{{ADMIN_NAME}}', '$member_name')
content = content.replace('{{MEMBER_NAME}}', '$member_name')
content = content.replace('{{TEAM_NAME}}', '$team_name')
content = content.replace('{{TELEGRAM_BOT}}', 'TBD')
content = content.replace('{{PA_EMAIL}}', 'TBD')
# Remove handlebars each blocks (team PA list — populated later)
content = re.sub(r'\{\{#each.*?\}\}.*?\{\{/each\}\}', '_(No team PAs provisioned yet.)_', content, flags=re.DOTALL)
print(content, end='')
" > "$tmp_soul"

      # Ensure workspace directory exists
      docker exec "$cname" mkdir -p /home/claworc/.openclaw/workspace-personal
      docker cp "$tmp_soul" "$cname:/home/claworc/.openclaw/workspace-personal/SOUL.md"
      docker exec "$cname" chown -R claworc:claworc /home/claworc/.openclaw/workspace-personal
      rm -f "$tmp_soul"
      log "  SOUL.md pushed"
    fi

    # Push IDENTITY.md if it exists (in pa-default, not pa-admin)
    local identity_src=""
    if [[ -f "$tmpl_dir/IDENTITY.md" ]]; then
      identity_src="$tmpl_dir/IDENTITY.md"
    elif [[ -f "$TEMPLATE_DIR/pa-default/IDENTITY.md" ]]; then
      identity_src="$TEMPLATE_DIR/pa-default/IDENTITY.md"
    fi

    if [[ -n "$identity_src" ]]; then
      log "Pushing IDENTITY.md..."
      local tmp_id
      tmp_id=$(mktemp)

      python3 -c "
with open('$identity_src') as f:
    content = f.read()
content = content.replace('{{PA_NAME}}', '$pa_display_name')
content = content.replace('{{MEMBER_NAME}}', '$member_name')
content = content.replace('{{TEAM_NAME}}', '$team_name')
print(content, end='')
" > "$tmp_id"

      docker exec "$cname" mkdir -p /home/claworc/.openclaw/workspace-personal
      docker cp "$tmp_id" "$cname:/home/claworc/.openclaw/workspace-personal/IDENTITY.md"
      docker exec "$cname" chown -R claworc:claworc /home/claworc/.openclaw/workspace-personal
      rm -f "$tmp_id"
      log "  IDENTITY.md pushed"
    fi
  fi

  log ""
  log "Config applied to $cname"
  log "  Gateway auth: token mode"
  if $show_token; then
    log "  Gateway token: $gateway_token"
  else
    log "  Gateway token: ****${gateway_token: -4} (use --show-token to display full token)"
  fi
  log ""
  log "Store the gateway token in 1Password — needed for iOS app connection."
  log "To apply changes: pactl restart $name"
}

cmd_vnc() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl vnc <name>"
  require_container "$name"

  local cname
  cname=$(container_name "$name")
  local vnc_port
  vnc_port=$(docker inspect "$cname" --format '{{index .Config.Labels "mypa.vnc_port"}}' 2>/dev/null || echo "")

  if [[ -z "$vnc_port" ]]; then
    # Fall back to reading from port mappings
    vnc_port=$(docker port "$cname" 6081 2>/dev/null | head -1 | cut -d: -f2 || echo "unknown")
  fi

  if container_running "$name"; then
    log "VNC for $name:"
    echo "  http://localhost:$vnc_port (noVNC web UI, container port $vnc_port)"
    echo ""
    echo "  Use this to access Chrome inside the container."
    echo "  For Claude auth: open terminal in VNC, run 'claude setup-token'"
  else
    warn "Container $cname is not running. Start it first: pactl start $name"
  fi
}

cmd_logs() {
  local name=""
  local follow=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --follow|-f) follow=true; shift ;;
      -*)          fatal "Unknown flag: $1" ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"; shift
        else
          fatal "Unexpected argument: $1"
        fi
        ;;
    esac
  done

  [[ -z "$name" ]] && fatal "Usage: pactl logs <name> [--follow]"
  require_container "$name"

  if $follow; then
    docker logs --follow --tail 100 "$(container_name "$name")"
  else
    docker logs --tail 200 "$(container_name "$name")"
  fi
}

cmd_exec() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl exec <name> <command...>"
  shift
  [[ $# -eq 0 ]] && fatal "Usage: pactl exec <name> <command...>"
  require_container "$name"

  if ! container_running "$name"; then
    fatal "Container $(container_name "$name") is not running"
  fi

  docker exec -it "$(container_name "$name")" "$@"
}

cmd_backup() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl backup <name>"
  require_container "$name"

  if [[ -x "$SCRIPT_DIR/backup-pas.sh" ]]; then
    "$SCRIPT_DIR/backup-pas.sh" --pa "$(container_name "$name")"
  else
    fatal "backup-pas.sh not found at $SCRIPT_DIR/backup-pas.sh"
  fi
}

cmd_token_rotate() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl token-rotate <name>"
  require_container "$name"

  if ! container_running "$name"; then
    fatal "Container $(container_name "$name") must be running to rotate token"
  fi

  log "Generating new gateway auth token for $name..."

  local cname
  cname=$(container_name "$name")

  # Generate a 32-char hex token (consistent with rotate-gateway-token.sh)
  local new_token
  new_token=$(openssl rand -hex 16)

  # Update both config files (gateway reads from claworc's, some tools from root's)
  docker exec "$cname" python3 -c "
import json
for path in ['/root/.openclaw/openclaw.json', '/home/claworc/.openclaw/openclaw.json']:
    try:
        with open(path) as f:
            config = json.load(f)
        config['gateway']['auth']['mode'] = 'token'
        config['gateway']['auth']['token'] = '$new_token'
        config['gateway']['auth'].pop('password', None)
        with open(path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'Updated {path}')
    except FileNotFoundError:
        print(f'Skipped {path} (not found)')
" 2>/dev/null || {
    warn "Failed to update config files. Manual update required."
    echo "  Token: ****${new_token: -4} (use 'pactl config $name --show-token' to display)"
    echo "  Update gateway.auth.token in openclaw.json, then: pactl restart $name"
    return 1
  }

  # Restart gateway process to pick up new token
  docker exec "$cname" bash -c '
    pid=$(pgrep -f "openclaw-gateway" | head -1)
    if [ -n "$pid" ]; then
      kill $pid 2>/dev/null
      sleep 3
    fi
  ' 2>/dev/null || true

  log "Token rotated successfully."
  log "New token: ****${new_token: -4} (use 'pactl config $name --show-token' to display full token)"
  log ""
  log "Store in 1Password: op item edit \"MyPA Gateway Token - $name\" --vault Private \"password=<token>\""
  log "Update the OpenClaw iOS app with the new token."
}

cmd_remove() {
  local name="${1:-}"
  [[ -z "$name" ]] && fatal "Usage: pactl remove <name>"
  require_container "$name"

  local cname
  cname=$(container_name "$name")
  local volume="${CONTAINER_PREFIX}${name}-data"

  if container_running "$name"; then
    log "Stopping $cname..."
    docker stop "$cname"
  fi

  log "Removing container $cname (volume $volume is preserved)..."
  docker rm "$cname"

  log "Container removed. Data volume '$volume' is still intact."
  log "To delete the volume: docker volume rm $volume"
  log "To recreate: pactl create $name"
}

cmd_help() {
  cat <<'EOF'
pactl — PA container management via direct Docker commands

Commands:
  create <name> [opts]      Create a new PA container
    --image <tag>             OpenClaw image (default: glukw/openclaw-vnc-chrome:latest)
    --member <name>           Team member name (stored as label)
    --team <name>             Team name (stored as label)
    --email <email>           PA email address (stored as label)
    --vnc-port <port>         noVNC port (auto-assigned from 6081)
    --gateway-port <port>     Gateway port (auto-assigned from 3001)
    --memory <size>           Container memory limit (default: 2g)

  config <name> [opts]      Push config into a running PA container
    --template <type>         Template dir (pa-admin or pa-default)
    --gateway-token <tok>     Gateway auth token (auto-generated if omitted)
    --pa-name <display>       PA display name for SOUL/IDENTITY
    --member-name <name>      Member name for SOUL/IDENTITY
    --team-name <team>        Team name for SOUL/IDENTITY

  start <name>              Start a stopped PA container
  stop <name>               Stop a running PA container
  restart <name>            Restart a PA container
  status [name]             Show status (one PA or all)
  list                      List all pactl-managed PA containers
  vnc <name>                Print noVNC URL for browser access
  logs <name> [--follow]    Show container logs
  exec <name> <cmd...>      Run a command inside a PA container
  backup <name>             Backup a single PA (delegates to backup-pas.sh)
  token-rotate <name>       Generate and apply new gateway auth token
  remove <name>             Remove container (data volume preserved)
  help                      Show this help

Quick start (single PA):
  pactl create my-pa --member "Alice" --team "Personal"
  pactl start my-pa
  pactl config my-pa --template pa-default --member-name "Alice"
  pactl restart my-pa
  pactl vnc my-pa                     # Get VNC URL for Claude auth
  pactl exec my-pa claude setup-token # Sync Claude auth (1yr token)

Environment:
  MYPA_IMAGE      Default OpenClaw image (glukw/openclaw-vnc-chrome:latest)
  MYPA_NETWORK    Docker network name (mypa)
  MYPA_DATA_DIR   Host config directory (/opt/mypa/data)

Notes:
  - pactl uses 'mypa-' container prefix
  - Data persists in Docker volumes: mypa-<name>-openclaw, mypa-<name>-clawd, mypa-<name>-chrome, etc.
  - Removing a container does NOT delete its volumes
  - VNC provides browser access for interactive auth (Claude, Google OAuth)
  - Pure Docker — no external control plane required
EOF
}

# ============================================================
# Main dispatch
# ============================================================

case "${1:-help}" in
  create)       shift; cmd_create "$@" ;;
  config)       shift; cmd_config "$@" ;;
  start)        shift; cmd_start "$@" ;;
  stop)         shift; cmd_stop "$@" ;;
  restart)      shift; cmd_restart "$@" ;;
  status)       shift; cmd_status "$@" ;;
  list)         shift; cmd_list ;;
  vnc)          shift; cmd_vnc "$@" ;;
  logs)         shift; cmd_logs "$@" ;;
  exec)         shift; cmd_exec "$@" ;;
  backup)       shift; cmd_backup "$@" ;;
  token-rotate) shift; cmd_token_rotate "$@" ;;
  remove)       shift; cmd_remove "$@" ;;
  help|-h|--help) cmd_help ;;
  *)            fatal "Unknown command: $1. Run 'pactl help' for usage." ;;
esac
