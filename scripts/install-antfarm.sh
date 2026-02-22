#!/usr/bin/env bash
#
# install-antfarm.sh — one-command bootstrap for Antfarm on the PA host
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

if ! command -v node >/dev/null 2>&1; then
  fatal "Node.js is required (Node 22+) for antfarm."
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  fatal "Node.js 22+ is required. Current major version is ${NODE_MAJOR}."
fi

ANTFARM_VERSION="v0.5.1"
# SHA-256 of the official install script — update when upgrading ANTFARM_VERSION
ANTFARM_INSTALLER_SHA256="VERIFY_ON_FIRST_RUN"

log "Installing antfarm ${ANTFARM_VERSION} from official source..."
ANTFARM_INSTALLER="/tmp/antfarm-install.sh"
curl -fsSL -o "$ANTFARM_INSTALLER" "https://raw.githubusercontent.com/snarktank/antfarm/${ANTFARM_VERSION}/scripts/install.sh"
# Verify download succeeded and is a shell script (not an error page)
if [[ ! -s "$ANTFARM_INSTALLER" ]] || ! head -1 "$ANTFARM_INSTALLER" | grep -q "^#!"; then
  rm -f "$ANTFARM_INSTALLER"
  fatal "Antfarm installer download failed or is not a valid script"
fi
# Verify SHA-256 checksum if a real hash is pinned
if [[ "$ANTFARM_INSTALLER_SHA256" != "VERIFY_ON_FIRST_RUN" ]]; then
  local_sha256=$(sha256sum "$ANTFARM_INSTALLER" | cut -d' ' -f1)
  if [[ "$local_sha256" != "$ANTFARM_INSTALLER_SHA256" ]]; then
    rm -f "$ANTFARM_INSTALLER"
    fatal "Antfarm installer checksum mismatch! Expected: $ANTFARM_INSTALLER_SHA256 Got: $local_sha256"
  fi
  log "Antfarm installer checksum verified."
else
  rm -f "$ANTFARM_INSTALLER"
  fatal "Antfarm installer checksum not pinned. Refusing to execute unverified script.
  To pin the checksum:
    1. Download: curl -fsSL -o /tmp/antfarm-install.sh 'https://raw.githubusercontent.com/snarktank/antfarm/${ANTFARM_VERSION}/scripts/install.sh'
    2. Inspect: less /tmp/antfarm-install.sh
    3. Hash:   sha256sum /tmp/antfarm-install.sh
    4. Update ANTFARM_INSTALLER_SHA256 in this script with the hash
    5. Re-run this script"
fi
bash "$ANTFARM_INSTALLER"
rm -f "$ANTFARM_INSTALLER"

if ! command -v antfarm >/dev/null 2>&1; then
  fatal "antfarm command not found after install"
fi

log "Installing MyPA pa-provision workflow into local antfarm db..."
antfarm workflow install pa-provision

log "Available workflows:"
antfarm workflow list

log "Antfarm bootstrap complete."
