#!/usr/bin/env bash
#
# backup-pas.sh — Daily backup of all PA Docker volumes + Twenty CRM database
#
# Usage:
#   ./backup-pas.sh                     # Run all backups
#   ./backup-pas.sh --pa alice-pa       # Backup a single PA
#   ./backup-pas.sh --crm-only          # Backup only Twenty CRM
#   ./backup-pas.sh --list              # List available backups
#   ./backup-pas.sh --restore alice-pa 2026-02-13  # Restore a PA from backup
#
# Cron (add to droplet):
#   0 2 * * * /opt/mypa/scripts/backup-pas.sh >> /var/log/mypa-backup.log 2>&1
#
# Environment:
#   BACKUP_DIR       — Root backup directory (default: /opt/backups)
#   RETENTION_DAYS   — Days to keep backups (default: 14)
#   TWENTY_CONTAINER — Twenty CRM DB container name (default: twenty-db)
#   TWENTY_DB_USER   — Postgres user (default: postgres)
#   TWENTY_DB_NAME   — Database name (default: twenty)
#   PA_NAME_PATTERNS  — Regex for PA container names (default: ^mypa-)
#                       Containers with label mypa.managed=true are discovered first
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[+]${NC} $1"; }
warn()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[!]${NC} $1"; }
error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[x]${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TWENTY_CONTAINER="${TWENTY_CONTAINER:-twenty-db}"
TWENTY_DB_USER="${TWENTY_DB_USER:-twenty}"
TWENTY_DB_NAME="${TWENTY_DB_NAME:-twenty}"
PA_NAME_PATTERNS="${PA_NAME_PATTERNS:-^mypa-}"
TODAY="$(date +%Y-%m-%d)"
TODAY_DIR="$BACKUP_DIR/$TODAY"

# --- Subcommands ---

collect_pa_containers() {
  local container_output
  local containers=()
  local pa_name

  # Primary: discover containers by mypa.managed label
  container_output=$(docker ps --filter "label=mypa.managed=true" --format '{{.Names}}' 2>/dev/null || true)

  if [[ -n "$container_output" ]]; then
    while IFS= read -r pa_name; do
      [[ -n "$pa_name" ]] && containers+=("$pa_name")
    done <<< "$container_output"
  else
    # Fallback: match by name pattern
    container_output=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "$PA_NAME_PATTERNS" || true)
    while IFS= read -r pa_name; do
      [[ -n "$pa_name" ]] && containers+=("$pa_name")
    done <<< "$container_output"
  fi

  printf '%s\n' "${containers[@]}" | sort -u
}

backup_single_pa() {
  local pa_name="$1"
  local dest="$TODAY_DIR/$pa_name"
  mkdir -p "$dest"

  if ! docker inspect "$pa_name" >/dev/null 2>&1; then
    error "Container not found: $pa_name"
    return 1
  fi

  log "Backing up $pa_name..."

  # Copy the OpenClaw data directory from the container
  # Try paths in order: claworc user (current image), root, legacy .clawdbot
  if docker cp "$pa_name:/home/claworc/.openclaw" "$dest/openclaw" 2>/dev/null; then
    local size
    size=$(du -sh "$dest/openclaw" 2>/dev/null | cut -f1)
    log "  $pa_name: $size backed up (claworc)"
  elif docker cp "$pa_name:/root/.openclaw" "$dest/openclaw" 2>/dev/null; then
    local size
    size=$(du -sh "$dest/openclaw" 2>/dev/null | cut -f1)
    log "  $pa_name: $size backed up (root)"
  else
    error "  $pa_name: Failed to backup — no .openclaw directory found"
    return 1
  fi

  # Record container metadata for restore (redact secrets from env vars)
  docker inspect "$pa_name" --format '{{.Config.Image}}' > "$dest/image.txt" 2>/dev/null || true
  # Write env vars with secrets redacted
  docker inspect "$pa_name" --format '{{json .Config.Env}}' 2>/dev/null \
    | python3 -c "
import json, sys, re
try:
    envs = json.load(sys.stdin)
    secret_patterns = re.compile(r'(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIALS)', re.IGNORECASE)
    redacted = []
    for e in envs:
        k, _, v = e.partition('=')
        if secret_patterns.search(k):
            redacted.append(f'{k}=REDACTED')
        else:
            redacted.append(e)
    json.dump(redacted, sys.stdout, indent=2)
except: json.dump([], sys.stdout)
" > "$dest/env.json" 2>/dev/null || echo '[]' > "$dest/env.json"

  # Redact secrets from backed-up OpenClaw configs
  for cfg in "$dest"/openclaw/openclaw.json "$dest"/openclaw/agents/*/agent/auth-profiles.json; do
    [[ -f "$cfg" ]] || continue
    python3 -c "
import json, sys, re
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    secret_keys = re.compile(r'(token|secret|password|apiKey|api_key|botToken|credentials)', re.IGNORECASE)
    def redact(obj):
        if isinstance(obj, dict):
            return {k: ('REDACTED' if secret_keys.search(k) and isinstance(v, str) else redact(v)) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [redact(i) for i in obj]
        return obj
    with open(sys.argv[1], 'w') as f: json.dump(redact(d), f, indent=2)
except: pass
" "$cfg" 2>/dev/null || true
  done

  return 0
}

backup_all_pas() {
  mkdir -p "$TODAY_DIR"

  local total=0
  local success=0
  local failed=0
  local containers

  log "Starting PA backup run: $TODAY"
  containers=$(collect_pa_containers)
  if [[ -z "$containers" ]]; then
    warn "No PA containers found (looked for label mypa.managed=true and pattern '$PA_NAME_PATTERNS')"
    return 0
  fi

  while IFS= read -r pa_name; do
    [[ -z "$pa_name" ]] && continue
    total=$((total + 1))
    if backup_single_pa "$pa_name"; then
      success=$((success + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$containers"

  log "PA backup complete: $success/$total succeeded, $failed failed"
}

backup_crm() {
  mkdir -p "$TODAY_DIR"

  if ! docker inspect "$TWENTY_CONTAINER" >/dev/null 2>&1; then
    warn "Twenty CRM container not found: $TWENTY_CONTAINER — skipping CRM backup"
    return 0
  fi

  log "Backing up Twenty CRM database..."
  if docker exec "$TWENTY_CONTAINER" pg_dump -U "$TWENTY_DB_USER" "$TWENTY_DB_NAME" > "$TODAY_DIR/twenty-crm.sql" 2>/dev/null; then
    local size
    size=$(du -sh "$TODAY_DIR/twenty-crm.sql" 2>/dev/null | cut -f1)
    log "  CRM dump: $size"
  else
    error "  CRM backup failed"
    return 1
  fi
}

encrypt_backup() {
  local day_dir="$1"
  if ! command -v age >/dev/null 2>&1; then
    warn "age not installed — backup NOT encrypted. Install: apt install age"
    return 0
  fi
  if [[ -z "${BACKUP_AGE_RECIPIENT:-}" ]]; then
    warn "BACKUP_AGE_RECIPIENT not set — backup NOT encrypted. Set to an age public key."
    return 0
  fi
  local archive="$day_dir.tar.gz"
  local encrypted="$day_dir.tar.gz.age"
  tar czf "$archive" -C "$(dirname "$day_dir")" "$(basename "$day_dir")" 2>/dev/null
  age -r "$BACKUP_AGE_RECIPIENT" -o "$encrypted" "$archive" 2>/dev/null
  if [[ -f "$encrypted" ]]; then
    rm -f "$archive"
    rm -rf "$day_dir"
    local size
    size=$(du -sh "$encrypted" 2>/dev/null | cut -f1)
    log "Backup encrypted: $encrypted ($size)"
  else
    warn "Encryption failed — keeping unencrypted backup"
    rm -f "$archive"
  fi
}

prune_old_backups() {
  log "Pruning backups older than $RETENTION_DAYS days..."
  local pruned=0

  # Prune unencrypted backup directories
  while IFS= read -r old_dir; do
    if [[ -n "$old_dir" ]]; then
      rm -rf "$old_dir"
      pruned=$((pruned + 1))
      log "  Pruned: $(basename "$old_dir")"
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' -mtime +"$RETENTION_DAYS" 2>/dev/null)

  # Prune encrypted backup archives (.tar.gz.age)
  while IFS= read -r old_file; do
    if [[ -n "$old_file" ]]; then
      rm -f "$old_file"
      pruned=$((pruned + 1))
      log "  Pruned: $(basename "$old_file")"
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name '20*.tar.gz.age' -mtime +"$RETENTION_DAYS" 2>/dev/null)

  if [[ "$pruned" -eq 0 ]]; then
    log "  No backups older than $RETENTION_DAYS days"
  else
    log "  Pruned $pruned old backup(s)"
  fi
}

list_backups() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "No backups found at $BACKUP_DIR"
    return 0
  fi

  echo "Available backups in $BACKUP_DIR:"
  echo ""

  # List encrypted backup archives
  for age_file in "$BACKUP_DIR"/20*.tar.gz.age; do
    [[ -f "$age_file" ]] || continue
    local fname size day
    fname=$(basename "$age_file")
    size=$(du -sh "$age_file" 2>/dev/null | cut -f1)
    day="${fname%.tar.gz.age}"
    printf "  %s  %6s  [ENCRYPTED] (decrypt: age -d -i <key> %s | tar xzf -)\n" "$day" "$size" "$age_file"
  done

  # List unencrypted backup directories
  for day_dir in "$BACKUP_DIR"/20*; do
    [[ -d "$day_dir" ]] || continue
    local day
    day=$(basename "$day_dir")
    local size
    size=$(du -sh "$day_dir" 2>/dev/null | cut -f1)
    local pa_count=0
    local has_crm="no"
    [[ -f "$day_dir/twenty-crm.sql" ]] && has_crm="yes"

    printf "  %s  %6s  PAs: " "$day" "$size"

    # List individual PAs
    for pa_dir in "$day_dir"/*; do
      [[ -d "$pa_dir" ]] || continue
      local pa_dir_name pa_name pa_size
      pa_dir_name=$(basename "$pa_dir")
      if [[ ! "$pa_dir_name" =~ $PA_NAME_PATTERNS ]]; then
        continue
      fi
      pa_name=$(basename "$pa_dir")
      pa_count=$((pa_count + 1))
      pa_size=$(du -sh "$pa_dir" 2>/dev/null | cut -f1)
      printf "    - %s (%s)\n" "$pa_name" "$pa_size"
    done
    echo "$pa_count  CRM: $has_crm"
  done
}

restore_pa() {
  local pa_name="$1"
  local backup_date="$2"
  local source="$BACKUP_DIR/$backup_date/$pa_name"
  local encrypted="$BACKUP_DIR/${backup_date}.tar.gz.age"
  local decrypted_temp=false

  # Handle encrypted backups: decrypt first, then restore from extracted dir
  if [[ ! -d "$source" ]] && [[ -f "$encrypted" ]]; then
    if ! command -v age >/dev/null 2>&1; then
      fatal "Backup is encrypted but 'age' is not installed. Install: apt install age"
    fi
    local age_key="${BACKUP_AGE_IDENTITY:-}"
    if [[ -z "$age_key" ]]; then
      fatal "Backup is encrypted. Set BACKUP_AGE_IDENTITY to your age private key file path."
    fi
    log "Decrypting backup archive..."
    age -d -i "$age_key" "$encrypted" | tar xzf - -C "$BACKUP_DIR" 2>/dev/null \
      || fatal "Failed to decrypt backup. Check your age identity key."
    if [[ ! -d "$source" ]]; then
      fatal "Decrypted archive does not contain $pa_name"
    fi
    decrypted_temp=true
    log "Backup decrypted to $source"
  fi

  if [[ ! -d "$source/openclaw" ]]; then
    fatal "No backup found at $source/openclaw"
  fi

  if ! docker inspect "$pa_name" >/dev/null 2>&1; then
    fatal "Container $pa_name does not exist. Create it with pactl first, then restore."
  fi

  local status
  status=$(docker inspect "$pa_name" --format '{{.State.Status}}' 2>/dev/null)
  if [[ "$status" == "running" ]]; then
    warn "Container $pa_name is running. Stop it before restoring."
    warn "Run: docker stop $pa_name"
    fatal "Aborting restore — container must be stopped first"
  fi

  local restore_target
  if docker exec "$pa_name" test -d /home/claworc/.openclaw 2>/dev/null; then
    restore_target="/home/claworc/.openclaw"
  elif docker exec "$pa_name" test -d /root/.openclaw 2>/dev/null; then
    restore_target="/root/.openclaw"
  else
    fatal "No known OpenClaw data directory found in $pa_name"
  fi

  log "Restoring $pa_name from $backup_date backup..."
  docker exec "$pa_name" sh -c "rm -rf '$restore_target'"
  docker cp "$source/openclaw" "$pa_name:$restore_target"
  log "Restore complete. Start the container to verify."
  log "Run: docker start $pa_name"
  if $decrypted_temp; then
    rm -rf "$BACKUP_DIR/$backup_date"
    log "Cleaned up temporary decrypted backup directory."
  fi
}

# --- Main ---

usage() {
  cat <<EOF
Usage:
  $0                                  Run full backup (all PAs + CRM + prune)
  $0 --pa <name>                      Backup a single PA container
  $0 --crm-only                       Backup only Twenty CRM
  $0 --list                           List available backups
  $0 --restore <name> <date>          Restore a PA from backup (container must be stopped)
  $0 -h, --help                       Show this help
EOF
}

case "${1:-}" in
  --pa)
    [[ -z "${2:-}" ]] && fatal "Usage: $0 --pa <container-name>"
    mkdir -p "$TODAY_DIR"
    backup_single_pa "$2"
    ;;
  --crm-only)
    backup_crm
    ;;
  --list)
    list_backups
    ;;
  --restore)
    [[ -z "${2:-}" || -z "${3:-}" ]] && fatal "Usage: $0 --restore <container-name> <backup-date>"
    restore_pa "$2" "$3"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    backup_all_pas
    backup_crm
    encrypt_backup "$TODAY_DIR"
    prune_old_backups
    log "Full backup run complete."
    ;;
  *)
    fatal "Unknown argument: $1. Use --help for usage."
    ;;
esac
