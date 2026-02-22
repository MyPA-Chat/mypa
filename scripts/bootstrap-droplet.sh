#!/usr/bin/env bash
#
# bootstrap-droplet.sh — Phase 0 infrastructure setup for MyPA PA Fleet droplet
#
# Codifies the manual steps from DEPLOYMENT_PLAN.md Phase 0 into an
# idempotent, repeatable script. Safe to re-run — skips already-completed steps.
#
# Usage:
#   sudo ./bootstrap-droplet.sh              # Full setup
#   sudo ./bootstrap-droplet.sh --check      # Verify current state without changes
#   sudo ./bootstrap-droplet.sh --help
#
# Must be run as root on a fresh Ubuntu 24.04 droplet.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
fatal() { error "$1"; exit 1; }

CHECK_ONLY=false
MYPA_USER="${MYPA_USER:-mypa}"

case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  --help|-h)
    cat <<EOF
Usage:
  sudo $0              Full Phase 0 setup
  sudo $0 --check      Verify current state without changes

Environment:
  MYPA_USER   Non-root admin user to create (default: mypa)

Requires: root on Ubuntu 24.04
EOF
    exit 0
    ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  fatal "This script must be run as root. Use: sudo $0"
fi

# ============================================================
# Status tracking
# ============================================================

declare -a DONE=()
declare -a SKIPPED=()
declare -a TODO=()

mark_done()    { DONE+=("$1"); }
mark_skipped() { SKIPPED+=("$1"); }
mark_todo()    { TODO+=("$1"); }

# ============================================================
# Step 1: System update
# ============================================================

step_system_update() {
  if $CHECK_ONLY; then
    info "System packages: check manually with 'apt list --upgradable'"
    mark_skipped "System update (check-only mode)"
    return
  fi

  # Wait for any background apt processes (common on fresh DO droplets)
  local retries=0
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [[ $retries -eq 0 ]]; then
      log "Waiting for background apt to finish..."
    fi
    retries=$((retries + 1))
    if [[ $retries -gt 60 ]]; then
      fatal "apt lock held for over 5 minutes — investigate manually"
    fi
    sleep 5
  done

  log "Updating system packages..."
  apt update -qq && apt upgrade -y -qq
  mark_done "System update"
}

# ============================================================
# Step 2: Create non-root user
# ============================================================

step_create_user() {
  if id "$MYPA_USER" >/dev/null 2>&1; then
    log "User '$MYPA_USER' already exists"
  elif $CHECK_ONLY; then
    warn "User '$MYPA_USER' does not exist"
    mark_todo "Create user '$MYPA_USER'"
    return
  else
    log "Creating user '$MYPA_USER'..."
    adduser --disabled-password --gecos "MyPA Admin" "$MYPA_USER"
    mark_done "Create user '$MYPA_USER'"
  fi

  # Always enforce hardening even if user pre-existed
  if $CHECK_ONLY; then
    return
  fi

  # Ensure sudo group membership
  usermod -aG sudo "$MYPA_USER" 2>/dev/null || true

  # Least-privilege sudo: only the commands mypa actually needs
  cat > "/etc/sudoers.d/$MYPA_USER" <<SUDOERS
# MyPA operator — least-privilege sudo policy
# Docker lifecycle
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/docker *
# Service management
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *, /usr/bin/systemctl stop *, /usr/bin/systemctl restart *, /usr/bin/systemctl enable *, /usr/bin/systemctl status *, /usr/bin/systemctl daemon-reload, /usr/bin/systemctl is-active *
# Firewall
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw *
# Package management (for deploys)
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/apt *, /usr/bin/apt-get *
# Tailscale
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/tailscale *, /usr/sbin/tailscale *
# File ownership under managed paths
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/chown * /opt/mypa/*, /usr/bin/chown * /opt/backups/*
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /opt/mypa/*, /usr/bin/mkdir -p /opt/backups/*
# Config file writes
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/*
# npm global installs
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/bin/npm install -g *
# Reboot
$MYPA_USER ALL=(ALL) NOPASSWD: /usr/sbin/reboot
SUDOERS
  chmod 440 "/etc/sudoers.d/$MYPA_USER"
  # Validate sudoers syntax — NEVER fall back to NOPASSWD:ALL
  if ! visudo -cf "/etc/sudoers.d/$MYPA_USER" >/dev/null 2>&1; then
    # Remove the invalid file so the system stays in a known state
    rm -f "/etc/sudoers.d/$MYPA_USER"
    fatal "Sudoers validation failed for $MYPA_USER. Fix the sudoers template above and re-run. Refusing to fall back to NOPASSWD:ALL."
  else
    log "Enforced least-privilege sudo for $MYPA_USER"
  fi

  # Always enforce SSH key ownership and permissions
  if [[ -f /root/.ssh/authorized_keys ]]; then
    mkdir -p "/home/$MYPA_USER/.ssh"
    cp /root/.ssh/authorized_keys "/home/$MYPA_USER/.ssh/authorized_keys"
    chown -R "$MYPA_USER:$MYPA_USER" "/home/$MYPA_USER/.ssh"
    chmod 700 "/home/$MYPA_USER/.ssh"
    chmod 600 "/home/$MYPA_USER/.ssh/authorized_keys"
    log "Enforced SSH key ownership for $MYPA_USER"
  fi
}

# ============================================================
# Step 3: Restrict root SSH login (key-only, no password)
# ============================================================

step_disable_root_ssh() {
  local sshd_config="/etc/ssh/sshd_config"

  # Use prohibit-password, NOT "no" — keeps key-based root access alive so
  # the operator can never be fully locked out if mypa user setup fails.
  # Password-based root login is still blocked (protects against brute force).
  if sshd -T 2>/dev/null | grep -qi "^permitrootlogin prohibit-password"; then
    log "Root SSH restricted to key-only (verified via sshd -T)"
    mark_skipped "Restrict root SSH (already done)"
    return
  fi

  if $CHECK_ONLY; then
    warn "Root SSH login is NOT restricted to key-only"
    mark_todo "Restrict root SSH login to key-only"
    return
  fi

  log "Restricting root SSH to key-only (prohibit-password)..."

  # Ensure the user exists and can SSH before modifying root access
  if ! id "$MYPA_USER" >/dev/null 2>&1; then
    fatal "Cannot restrict root SSH — user '$MYPA_USER' does not exist yet"
  fi

  # Remove all existing PermitRootLogin lines (commented or not, in all sshd config files)
  # to avoid conflicts from Ubuntu's default drop-in files
  sed -i '/^[[:space:]]*#\?[[:space:]]*PermitRootLogin/d' "$sshd_config"
  find /etc/ssh/sshd_config.d/ -type f -exec sed -i '/PermitRootLogin/d' {} \; 2>/dev/null || true
  # Append the canonical setting
  echo "PermitRootLogin prohibit-password" >> "$sshd_config"

  # Validate config before restarting (prevents lockout from bad config)
  if ! sshd -t 2>/dev/null; then
    sed -i '/^PermitRootLogin prohibit-password$/d' "$sshd_config"
    # WARN only — do not fatal/exit. Remaining bootstrap steps (Docker, UFW, fail2ban)
    # are independent of SSH config and must complete even if this step fails.
    # A failed PermitRootLogin change means root SSH stays at its current setting,
    # which is acceptable (the droplet was already accessible to get here).
    warn "sshd config validation failed after PermitRootLogin change — reverted"
    mark_todo "Manually restrict root SSH on this droplet"
    return
  fi

  # Ubuntu 24.04 uses ssh.service, older versions use sshd.service
  if systemctl restart ssh 2>/dev/null; then
    log "Restarted ssh.service"
  elif systemctl restart sshd 2>/dev/null; then
    log "Restarted sshd.service"
  else
    warn "Could not restart SSH service — verify manually"
  fi
  mark_done "Restrict root SSH to key-only"
}

# ============================================================
# Step 4: Install fail2ban
# ============================================================

step_install_fail2ban() {
  # Always write the whitelist (idempotent) — Tailscale range + loopback.
  # This prevents fail2ban from banning the operator during bootstrapping.
  local jail_local="/etc/fail2ban/jail.local"
  _write_fail2ban_whitelist() {
    if ! grep -q "ignoreip" "$jail_local" 2>/dev/null; then
      mkdir -p /etc/fail2ban
      cat >> "$jail_local" << 'JAILEOF'
[DEFAULT]
# Whitelist loopback + Tailscale CGNAT range so the operator is never banned
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10
JAILEOF
      log "fail2ban whitelist written (loopback + Tailscale)"
    else
      log "fail2ban whitelist already present"
    fi
  }

  if command -v fail2ban-server >/dev/null 2>&1; then
    log "fail2ban already installed"
    _write_fail2ban_whitelist
    if systemctl is-active --quiet fail2ban; then
      log "fail2ban is running"
      systemctl reload fail2ban 2>/dev/null || true
      mark_skipped "fail2ban (already installed and running)"
    else
      if $CHECK_ONLY; then
        warn "fail2ban installed but not running"
        mark_todo "Start fail2ban"
      else
        systemctl enable fail2ban
        systemctl start fail2ban
        mark_done "fail2ban started"
      fi
    fi
  elif $CHECK_ONLY; then
    warn "fail2ban not installed"
    mark_todo "Install fail2ban"
  else
    log "Installing fail2ban..."
    apt install -y -qq fail2ban
    _write_fail2ban_whitelist
    systemctl enable fail2ban
    systemctl start fail2ban
    mark_done "Install fail2ban"
  fi
}

# ============================================================
# Step 5: Configure UFW
# ============================================================

step_configure_ufw() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "UFW already active"
    mark_skipped "UFW (already active)"
  elif $CHECK_ONLY; then
    warn "UFW not active"
    mark_todo "Configure UFW"
  else
    log "Configuring UFW..."
    apt install -y -qq ufw 2>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow http   # required for Caddy TLS cert provisioning (Let's Encrypt ACME)
    ufw allow https
    ufw --force enable
    mark_done "Configure UFW"
  fi
}

# ============================================================
# Step 6: Install Docker
# ============================================================

step_install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    if systemctl is-active --quiet docker; then
      log "Docker daemon is running"
      mark_skipped "Docker (already installed and running)"
    else
      if $CHECK_ONLY; then
        warn "Docker installed but not running"
        mark_todo "Start Docker daemon"
      else
        systemctl enable docker
        systemctl start docker
        mark_done "Docker daemon started"
      fi
    fi
  elif $CHECK_ONLY; then
    warn "Docker not installed"
    mark_todo "Install Docker"
  else
    log "Installing Docker..."
    apt install -y -qq docker.io docker-compose-v2
    systemctl enable docker
    systemctl start docker
    mark_done "Install Docker"
  fi

  # Always enforce docker group membership (even if Docker pre-existed)
  if ! $CHECK_ONLY && id "$MYPA_USER" >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
    if ! id -nG "$MYPA_USER" | grep -qw docker; then
      usermod -aG docker "$MYPA_USER"
      log "Added $MYPA_USER to docker group"
    fi
  fi
}

# ============================================================
# Step 6b: Docker cgroupns fix for OpenClaw containers
# ============================================================

step_docker_cgroupns_fix() {
  local daemon_json="/etc/docker/daemon.json"

  if [[ -f "$daemon_json" ]] && grep -q "default-cgroupns-mode" "$daemon_json" 2>/dev/null; then
    log "Docker cgroupns fix already applied"
    mark_skipped "Docker cgroupns fix (already applied)"
    return
  fi

  if $CHECK_ONLY; then
    warn "Docker cgroupns fix not applied (OpenClaw VNC containers need --cgroupns=host)"
    mark_todo "Apply Docker cgroupns fix"
    return
  fi

  log "Applying Docker cgroupns fix (required for OpenClaw VNC containers)..."

  # OpenClaw VNC image runs systemd as PID 1. Docker 28 + Ubuntu 24.04
  # defaults to --cgroupns=private which silently kills systemd (exit 255).
  # Fix: set host mode as default.
  if [[ -f "$daemon_json" ]]; then
    # Merge with existing config
    local tmp
    tmp=$(mktemp)
    jq '. + {"default-cgroupns-mode": "host"}' "$daemon_json" > "$tmp" 2>/dev/null && mv "$tmp" "$daemon_json"
  else
    echo '{"default-cgroupns-mode": "host"}' > "$daemon_json"
  fi

  systemctl restart docker
  log "Docker cgroupns fix applied and Docker restarted"
  mark_done "Docker cgroupns fix"
}

# ============================================================
# Step 7: Install Tailscale
# ============================================================

step_install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    local ts_status
    ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | head -1 || echo "unknown")
    log "Tailscale already installed ($ts_status)"
    mark_skipped "Tailscale (already installed)"
  elif $CHECK_ONLY; then
    warn "Tailscale not installed"
    mark_todo "Install Tailscale"
  else
    log "Installing Tailscale via signed apt repository..."
    # Use Tailscale's signed apt repo instead of piping a remote script to bash
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
      | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt update -qq
    apt install -y -qq tailscale
    mark_done "Install Tailscale"
    warn "Run 'tailscale up' to authenticate and join your tailnet"
    mark_todo "Authenticate Tailscale (manual: tailscale up)"
  fi
}

# ============================================================
# Step 7b: Docker port isolation (DOCKER-USER iptables)
# ============================================================

step_docker_port_isolation() {
  local service_file="/etc/systemd/system/docker-port-isolation.service"

  if [[ -f "$service_file" ]] && systemctl is-active --quiet docker-port-isolation; then
    log "Docker port isolation service already active"
    mark_skipped "Docker port isolation (already active)"
    return
  fi

  if $CHECK_ONLY; then
    warn "Docker port isolation not configured (DOCKER-USER chain)"
    mark_todo "Install docker-port-isolation.service"
    return
  fi

  log "Installing Docker port isolation (DOCKER-USER iptables rules)..."

  # Docker-published ports bypass UFW. The DOCKER-USER chain is the only
  # iptables hook that fires BEFORE Docker's NAT rules forward traffic to
  # containers. We use conntrack to match NEW connections from external
  # interfaces destined for PA/CRM port ranges and DROP them.
  # Tailscale (tailscale0) and loopback are explicitly allowed.
  cat > "$service_file" <<'UNIT'
[Unit]
Description=Docker port isolation (DOCKER-USER chain rules)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  iptables -N DOCKER-USER 2>/dev/null || true; \
  iptables -F DOCKER-USER 2>/dev/null || true; \
  iptables -A DOCKER-USER -i lo -j RETURN; \
  iptables -A DOCKER-USER -i tailscale0 -j RETURN; \
  iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN; \
  iptables -A DOCKER-USER -p tcp -m multiport --dports 3000:3100 -m conntrack --ctstate NEW -j DROP; \
  iptables -A DOCKER-USER -p tcp -m multiport --dports 6081:6100 -m conntrack --ctstate NEW -j DROP; \
  iptables -A DOCKER-USER -j RETURN'

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now docker-port-isolation
  mark_done "Docker port isolation (DOCKER-USER chain)"
}

# ============================================================
# Step 8: Create directory structure
# ============================================================

step_create_dirs() {
  local dirs=("/opt/mypa" "/opt/mypa/data" "/opt/mypa/scripts" "/opt/backups")
  local all_exist=true

  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      all_exist=false
      break
    fi
  done

  if $all_exist; then
    log "MyPA directory structure exists"
    mark_skipped "Directory structure (already exists)"
  elif $CHECK_ONLY; then
    warn "MyPA directory structure incomplete"
    mark_todo "Create /opt/mypa and /opt/backups"
  else
    log "Creating MyPA directory structure..."
    for dir in "${dirs[@]}"; do
      mkdir -p "$dir"
    done
    if id "$MYPA_USER" >/dev/null 2>&1; then
      chown -R "$MYPA_USER:$MYPA_USER" /opt/mypa /opt/backups
    fi
    mark_done "Create directory structure"
  fi
}

# ============================================================
# Step 8b: Pre-pull OpenClaw container image
# ============================================================

step_pull_openclaw_image() {
  local image="glukw/openclaw-vnc-chrome:latest"

  if docker image inspect "$image" >/dev/null 2>&1; then
    log "OpenClaw image already pulled: $image"
    mark_skipped "Pull OpenClaw image (already present)"
    return
  fi

  if $CHECK_ONLY; then
    warn "OpenClaw image not present: $image"
    mark_todo "Pull OpenClaw image"
    return
  fi

  log "Pulling OpenClaw container image: $image"
  docker pull "$image"
  mark_done "Pull OpenClaw image: $image"
}

# ============================================================
# Run all steps
# ============================================================

main() {
  echo ""
  if $CHECK_ONLY; then
    echo -e "${CYAN}=== MyPA Droplet Health Check ===${NC}"
  else
    echo -e "${CYAN}=== MyPA Phase 0: Droplet Bootstrap ===${NC}"
  fi
  echo ""

  step_system_update
  step_create_user
  step_disable_root_ssh
  step_install_fail2ban
  step_configure_ufw
  step_install_docker
  step_docker_cgroupns_fix
  step_docker_port_isolation
  step_install_tailscale
  step_create_dirs
  step_pull_openclaw_image

  # Summary
  echo ""
  echo -e "${CYAN}=== Summary ===${NC}"
  echo ""

  if [[ ${#DONE[@]} -gt 0 ]]; then
    echo -e "${GREEN}Completed:${NC}"
    for item in "${DONE[@]}"; do
      echo "  [+] $item"
    done
  fi

  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Already done:${NC}"
    for item in "${SKIPPED[@]}"; do
      echo "  [-] $item"
    done
  fi

  if [[ ${#TODO[@]} -gt 0 ]]; then
    echo -e "${RED}Manual steps remaining:${NC}"
    for item in "${TODO[@]}"; do
      echo "  [ ] $item"
    done
  fi

  # Always remind about manual steps
  echo ""
  echo -e "${CYAN}Manual follow-ups:${NC}"
  echo "  [ ] Enable DigitalOcean backups (weekly) in DO dashboard"
  echo "  [ ] Set DO monitoring alerts: disk > 80%, CPU > 90% sustained 5min, memory > 85%"
  echo "  [ ] Configure DNS: pa.yourdomain.com -> droplet Tailscale IP"
  echo "  [ ] Authenticate Tailscale: tailscale up (if not already done)"
  echo "  [ ] Verify SSH works via Tailscale IP: ssh $MYPA_USER@<tailscale-ip>"
  echo ""
}

main "$@"
