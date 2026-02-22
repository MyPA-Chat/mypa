#!/usr/bin/env bash
#
# install.sh — Deploy the MyPA Provisioning API to the host
#
# Usage:
#   bash install.sh                      # Install + generate token
#   bash install.sh --token <token>      # Install with specific token
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fatal() { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

INSTALL_DIR="/opt/mypa/services/provisioning-api"
SERVICE_NAME="mypa-provisioning-api"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
API_TOKEN=""
for arg in "$@"; do
  case "$arg" in
    --token)  shift; API_TOKEN="${1:-}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--token <token>]"
      exit 0
      ;;
  esac
done

# Generate token if not provided
if [[ -z "$API_TOKEN" ]]; then
  API_TOKEN=$(openssl rand -hex 16)
  log "Generated API token: ****${API_TOKEN: -4}"
  warn "Store this token in 1Password: op item create --category login --title 'MyPA Provisioning API Token' --vault Private \"password=$API_TOKEN\""
fi

# Install files
log "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/server.js" "$INSTALL_DIR/server.js"
chmod 644 "$INSTALL_DIR/server.js"

# Create .env file with token
cat > "$INSTALL_DIR/.env" <<EOF
PROVISION_API_TOKEN=$API_TOKEN
PACTL_PATH=/opt/mypa/scripts/pactl.sh
CADDY_CONFIG_DIR=/opt/mypa/caddy/sites
CADDY_BIN=/opt/mypa/caddy
CADDYFILE=/opt/mypa/Caddyfile
EOF
chmod 600 "$INSTALL_DIR/.env"
log "Environment file created (chmod 600)"

# Install systemd service
cp "$SCRIPT_DIR/provisioning-api.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Service started successfully"
  # Health check
  local_check=$(curl -sf http://127.0.0.1:9100/health 2>/dev/null || echo "FAIL")
  if echo "$local_check" | grep -q '"ok"'; then
    log "Health check passed"
  else
    warn "Health check failed — check: journalctl -u $SERVICE_NAME"
  fi
else
  fatal "Service failed to start. Check: journalctl -u $SERVICE_NAME"
fi

log ""
log "Provisioning API installed and running on 127.0.0.1:9100"
log "Token: ****${API_TOKEN: -4} (stored in $INSTALL_DIR/.env)"
log ""
log "The admin PA can reach this API via Docker bridge gateway IP."
log "Find the gateway IP: docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'"
log "Example from PA container: curl -H 'Authorization: Bearer <token>' http://<gateway-ip>:9100/health"
