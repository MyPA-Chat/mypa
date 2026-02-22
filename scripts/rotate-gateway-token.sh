#!/usr/bin/env bash
# rotate-gateway-token.sh — Rotate the PA gateway auth token using 1Password CLI
# Usage: ./scripts/rotate-gateway-token.sh [pa-name]
#
# Generates a 32-char random token, stores it in 1Password, and pushes it
# to the gateway config inside the Docker container. The token never appears
# in git, shell history, or Claude conversations.
#
# Prerequisites: op CLI (1Password) authenticated, ssh access to droplet

set -euo pipefail

PA_NAME="${1:-admin-pa}"
CONTAINER="pa-${PA_NAME}"
DROPLET="user@203.0.113.20"
OP_VAULT="Private"
OP_ITEM="MyPA Gateway Token - ${PA_NAME}"

echo "=== Rotating gateway token for ${CONTAINER} ==="

# Step 1: Generate a 32-char random token
echo "[1/4] Generating random token..."
NEW_TOKEN=$(openssl rand -hex 16) || {
    echo "ERROR: Failed to generate token. Is openssl available?"
    exit 1
}

# Step 2: Store/update in 1Password
echo "[2/4] Storing token in 1Password (vault: ${OP_VAULT}, item: ${OP_ITEM})..."
if op item get "${OP_ITEM}" --vault "${OP_VAULT}" >/dev/null 2>&1; then
    op item edit "${OP_ITEM}" --vault "${OP_VAULT}" "password=${NEW_TOKEN}" >/dev/null
    echo "  Updated existing item."
else
    op item create --category=password --title="${OP_ITEM}" --vault="${OP_VAULT}" "password=${NEW_TOKEN}" >/dev/null
    echo "  Created new item."
fi

# Step 3: Push to BOTH gateway configs inside Docker container
# (OpenClaw has dual configs: root reads one, claworc user reads the other)
echo "[3/4] Pushing token to gateway configs..."
ssh "${DROPLET}" "sudo docker exec ${CONTAINER} python3 -c \"
import json
for path in ['/root/.openclaw/openclaw.json', '/home/claworc/.openclaw/openclaw.json']:
    try:
        with open(path) as f:
            config = json.load(f)
        config['gateway']['auth']['mode'] = 'token'
        config['gateway']['auth']['token'] = '${NEW_TOKEN}'
        config['gateway']['auth'].pop('password', None)
        with open(path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'Updated {path}')
    except FileNotFoundError:
        print(f'Skipped {path} (not found)')
\""

# Step 4: Also update the systemd service ExecStart to not leak the old token in process args
echo "[4/4] Restarting gateway to pick up new token..."
ssh "${DROPLET}" "sudo docker exec ${CONTAINER} bash -c '
pid=\$(pgrep -f \"openclaw-gateway\" | head -1)
if [ -n \"\$pid\" ]; then
    kill \$pid 2>/dev/null
    echo \"Killed gateway PID \$pid, waiting for restart...\"
    sleep 5
    newpid=\$(pgrep -f \"openclaw-gateway\" | head -1)
    echo \"New gateway PID: \$newpid\"
else
    echo \"WARNING: No gateway process found\"
fi
'"

echo ""
echo "=== Token rotated successfully ==="
echo "Token stored in 1Password: ${OP_ITEM}"
echo "Remember to update the OpenClaw iOS app with the new token."
echo ""
echo "To retrieve the token later:"
echo "  op item get \"${OP_ITEM}\" --vault \"${OP_VAULT}\" --fields password"
