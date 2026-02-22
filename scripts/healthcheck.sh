#!/usr/bin/env bash
#
# healthcheck.sh — Proactive monitoring for MyPA platform components
#
# Checks PA containers, Twenty CRM, disk and memory usage.
# Designed for cron.
#
# Usage:
#   ./healthcheck.sh                   # Run all checks, output summary
#   ./healthcheck.sh --notify          # Run checks + send Telegram alert on WARN/CRITICAL
#   ./healthcheck.sh --json            # Output JSON (for log aggregation)
#   ./healthcheck.sh --help
#
# Cron:
#   */15 * * * * /opt/mypa/scripts/healthcheck.sh >> /var/log/mypa-health.log 2>&1
#   */15 * * * * /opt/mypa/scripts/healthcheck.sh --notify 2>&1
#
# Exit codes:
#   0 = all OK
#   1 = at least one WARN
#   2 = at least one CRITICAL
#
# Environment:
#   TWENTY_CRM_URL              — Twenty CRM health endpoint (default: http://localhost:3000)
#   DISK_WARN_PCT               — Disk usage warn threshold (default: 80)
#   DISK_CRIT_PCT               — Disk usage critical threshold (default: 90)
#   MEM_WARN_PCT                — Memory usage warn threshold (default: 85)
#   HEALTHCHECK_TELEGRAM_TOKEN  — Telegram bot token for --notify
#   HEALTHCHECK_TELEGRAM_CHAT_ID — Telegram chat ID for --notify
#

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

TWENTY_CRM_URL="${TWENTY_CRM_URL:-http://localhost:3000}"
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"
MEM_WARN_PCT="${MEM_WARN_PCT:-85}"

NOTIFY=false
JSON_OUTPUT=false
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Parse args
for arg in "$@"; do
  case "$arg" in
    --notify) NOTIFY=true ;;
    --json)   JSON_OUTPUT=true ;;
    --help|-h)
      cat <<EOF
Usage:
  $0                  Run all checks
  $0 --notify         Also send Telegram alert on WARN/CRITICAL
  $0 --json           Output as JSON
  $0 --help           Show this help
EOF
      exit 0
      ;;
    *) fatal "Unknown argument: $arg" ;;
  esac
done

# ============================================================
# Result tracking
# ============================================================

declare -a RESULTS=()
WORST_STATUS=0  # 0=OK, 1=WARN, 2=CRITICAL

record() {
  local component="$1"
  local status="$2"  # OK, WARN, CRITICAL
  local detail="$3"

  RESULTS+=("$status|$component|$detail")

  case "$status" in
    CRITICAL) [[ $WORST_STATUS -lt 2 ]] && WORST_STATUS=2 ;;
    WARN)     [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1 ;;
  esac
}

# ============================================================
# Check: PA containers
# ============================================================

check_pa_containers() {
  local containers
  # Check pactl-managed containers
  containers=$(docker ps -a --filter "label=mypa.managed=true" --format '{{.Names}}' 2>/dev/null || true)

  if [[ -z "$containers" ]]; then
    record "PA Containers" "WARN" "No PA containers found"
    return
  fi

  local total=0
  local running=0
  local stopped_names=()

  while IFS= read -r name; do
    total=$((total + 1))
    local status
    status=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$status" == "running" ]]; then
      running=$((running + 1))
    else
      stopped_names+=("$name($status)")
    fi
  done <<< "$containers"

  if [[ $running -eq $total ]]; then
    record "PA Containers" "OK" "$running/$total running"
  elif [[ ${#stopped_names[@]} -gt 0 ]]; then
    record "PA Containers" "CRITICAL" "$running/$total running; stopped: ${stopped_names[*]}"
  fi
}

# ============================================================
# Check: Twenty CRM
# ============================================================

check_twenty_crm() {
  local http_code
  http_code=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 10 "$TWENTY_CRM_URL" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" ]]; then
    record "Twenty CRM" "OK" "HTTP $http_code at $TWENTY_CRM_URL"
  elif [[ "$http_code" == "000" ]]; then
    record "Twenty CRM" "CRITICAL" "Unreachable at $TWENTY_CRM_URL"
  else
    record "Twenty CRM" "WARN" "HTTP $http_code at $TWENTY_CRM_URL"
  fi
}

# ============================================================
# Check: Disk usage
# ============================================================

check_disk() {
  local usage
  usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')

  if [[ -z "$usage" ]]; then
    # macOS fallback
    usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
  fi

  if [[ "$usage" -ge "$DISK_CRIT_PCT" ]]; then
    record "Disk Usage" "CRITICAL" "${usage}% (threshold: ${DISK_CRIT_PCT}%)"
  elif [[ "$usage" -ge "$DISK_WARN_PCT" ]]; then
    record "Disk Usage" "WARN" "${usage}% (threshold: ${DISK_WARN_PCT}%)"
  else
    record "Disk Usage" "OK" "${usage}%"
  fi
}

# ============================================================
# Check: Memory usage
# ============================================================

check_memory() {
  local usage

  if command -v free >/dev/null 2>&1; then
    # Linux
    local total used
    total=$(free -m | awk '/^Mem:/ {print $2}')
    used=$(free -m | awk '/^Mem:/ {print $3}')
    if [[ "$total" -gt 0 ]]; then
      usage=$(( (used * 100) / total ))
    else
      usage=0
    fi
  else
    # macOS — approximate
    local pages_free pages_active pages_wired page_size
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./, ""); print $3}')
    pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./, ""); print $3}')
    pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./, ""); print $4}')

    if [[ -n "$pages_free" && -n "$pages_active" && -n "$pages_wired" ]]; then
      local total_pages=$(( pages_free + pages_active + pages_wired ))
      local used_pages=$(( pages_active + pages_wired ))
      usage=$(( (used_pages * 100) / total_pages ))
    else
      record "Memory" "WARN" "Unable to determine memory usage"
      return
    fi
  fi

  if [[ "$usage" -ge "$MEM_WARN_PCT" ]]; then
    record "Memory" "WARN" "${usage}% (threshold: ${MEM_WARN_PCT}%)"
  else
    record "Memory" "OK" "${usage}%"
  fi
}

# ============================================================
# Check: Docker daemon
# ============================================================

check_docker() {
  if docker info >/dev/null 2>&1; then
    record "Docker" "OK" "Daemon running"
  else
    record "Docker" "CRITICAL" "Docker daemon not responding"
  fi
}

# ============================================================
# Check: DOCKER-USER iptables rules
# ============================================================

check_docker_user_rules() {
  # Verify that DOCKER-USER chain has DROP rules for container ports.
  # These prevent Docker-published ports from being reachable from the public internet.
  if ! command -v iptables >/dev/null 2>&1; then
    record "DOCKER-USER" "WARN" "iptables not available (cannot verify port isolation)"
    return
  fi

  local rules
  rules=$(iptables -L DOCKER-USER -n 2>/dev/null || echo "")

  if [[ -z "$rules" ]]; then
    record "DOCKER-USER" "WARN" "DOCKER-USER chain not found or empty"
    return
  fi

  local has_gateway_drop=false
  local has_vnc_drop=false
  if echo "$rules" | grep -q "DROP.*dpts:3000:3100"; then
    has_gateway_drop=true
  fi
  if echo "$rules" | grep -q "DROP.*dpts:6081:6100"; then
    has_vnc_drop=true
  fi

  if $has_gateway_drop && $has_vnc_drop; then
    record "DOCKER-USER" "OK" "Port isolation rules active (3000-3100, 6081-6100)"
  else
    record "DOCKER-USER" "WARN" "Missing DROP rules for container ports — run: systemctl restart docker-port-isolation"
  fi
}

# ============================================================
# Output
# ============================================================

output_text() {
  echo ""
  echo "=== MyPA Health Check: $TIMESTAMP ==="
  echo ""

  for result in "${RESULTS[@]}"; do
    IFS='|' read -r status component detail <<< "$result"
    local color="$GREEN"
    case "$status" in
      WARN)     color="$YELLOW" ;;
      CRITICAL) color="$RED" ;;
    esac
    printf "  ${color}%-8s${NC}  %-25s  %s\n" "[$status]" "$component" "$detail"
  done

  echo ""
  case $WORST_STATUS in
    0) echo -e "  ${GREEN}Overall: OK${NC}" ;;
    1) echo -e "  ${YELLOW}Overall: WARN${NC}" ;;
    2) echo -e "  ${RED}Overall: CRITICAL${NC}" ;;
  esac
  echo ""
}

output_json() {
  local items=()
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r status component detail <<< "$result"
    items+=("{\"component\":\"$component\",\"status\":\"$status\",\"detail\":\"$detail\"}")
  done

  local overall="OK"
  [[ $WORST_STATUS -eq 1 ]] && overall="WARN"
  [[ $WORST_STATUS -eq 2 ]] && overall="CRITICAL"

  printf '{"timestamp":"%s","overall":"%s","checks":[%s]}\n' \
    "$TIMESTAMP" "$overall" "$(IFS=,; echo "${items[*]}")"
}

send_telegram_alert() {
  if [[ -z "${HEALTHCHECK_TELEGRAM_TOKEN:-}" || -z "${HEALTHCHECK_TELEGRAM_CHAT_ID:-}" ]]; then
    return
  fi

  # Only alert on WARN or CRITICAL
  if [[ $WORST_STATUS -eq 0 ]]; then
    return
  fi

  local emoji="⚠️"
  local overall="WARN"
  if [[ $WORST_STATUS -eq 2 ]]; then
    emoji="🚨"
    overall="CRITICAL"
  fi

  local message="$emoji *MyPA Health: $overall*%0A%0A"

  for result in "${RESULTS[@]}"; do
    IFS='|' read -r status component detail <<< "$result"
    if [[ "$status" != "OK" ]]; then
      message+="*$component*: $status — $detail%0A"
    fi
  done

  message+="%0A_$TIMESTAMP_"

  curl -sf -X POST \
    "https://api.telegram.org/bot${HEALTHCHECK_TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${HEALTHCHECK_TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown" \
    >/dev/null 2>&1 || true
}

# ============================================================
# Main
# ============================================================

check_docker
check_pa_containers
check_twenty_crm
check_disk
check_memory
check_docker_user_rules

if $JSON_OUTPUT; then
  output_json
else
  output_text
fi

if $NOTIFY; then
  send_telegram_alert
fi

exit $WORST_STATUS
