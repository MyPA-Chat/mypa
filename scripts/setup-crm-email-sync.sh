#!/usr/bin/env bash
#
# setup-crm-email-sync.sh — Automate Twenty CRM email sync using existing gog OAuth tokens
#
# Key discovery from deployment: CRM email sync does NOT need a browser OAuth flow.
# If gog is already authenticated, we reuse its tokens to set up Twenty's connectedAccount
# and messageChannel entirely via API.
#
# This script runs INSIDE the PA container, after gog and Twenty CRM are configured.
#
# Usage:
#   bash setup-crm-email-sync.sh                    # Auto-detect account from GOG_ACCOUNT
#   bash setup-crm-email-sync.sh --account pa@domain.com
#
# Prerequisites:
#   - gog authenticated (gog auth add <account> completed)
#   - Twenty CRM API key configured (config/twenty.env)
#   - GOG_KEYRING_PASSWORD and GOG_ACCOUNT set in environment
#   - python3.12 available (NOT python3 — container has 3.14 as default, packages on 3.12)
#   - twenty-crm skill installed with helper scripts
#
# Exit codes:
#   0 = success
#   1 = missing prerequisites
#   2 = API call failed
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

# Parse args
ACCOUNT="${GOG_ACCOUNT:-}"
for arg in "$@"; do
  case "$arg" in
    --account) shift; ACCOUNT="${1:-}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--account pa@domain.com]"
      exit 0
      ;;
  esac
done

# --- Prerequisite checks ---

if [[ -z "$ACCOUNT" ]]; then
  fatal "GOG_ACCOUNT not set and --account not provided"
fi

if [[ -z "${GOG_KEYRING_PASSWORD:-}" ]]; then
  fatal "GOG_KEYRING_PASSWORD not set"
fi

if ! command -v python3.12 >/dev/null 2>&1; then
  fatal "python3.12 not found (container has 3.14 as default; pip packages are on 3.12)"
fi

TWENTY_SCRIPTS="skills/twenty-crm/scripts"
if [[ ! -d "$TWENTY_SCRIPTS" ]]; then
  fatal "Twenty CRM skill not installed (expected: $TWENTY_SCRIPTS)"
fi

if [[ ! -f "$TWENTY_SCRIPTS/twenty-graphql.sh" ]] || [[ ! -f "$TWENTY_SCRIPTS/twenty-rest-post.sh" ]]; then
  fatal "Twenty CRM helper scripts not found in $TWENTY_SCRIPTS"
fi

GOG_CREDS="/home/claworc/.config/gogcli/credentials.json"
if [[ ! -f "$GOG_CREDS" ]]; then
  fatal "gog credentials not found at $GOG_CREDS"
fi

log "Setting up CRM email sync for $ACCOUNT"

# --- Step 1: Export refresh token from gog ---

TOKEN_FILE="/tmp/gog-token-export-$$.json"
trap 'rm -f "$TOKEN_FILE"' EXIT

log "Step 1/7: Exporting gog refresh token..."
gog auth tokens export "$ACCOUNT" --out "$TOKEN_FILE"
if [[ ! -s "$TOKEN_FILE" ]]; then
  fatal "Token export failed — is gog authenticated for $ACCOUNT?"
fi

# --- Step 2: Read credentials ---

log "Step 2/7: Reading OAuth credentials..."
CLIENT_ID=$(python3.12 -c "import json; print(json.load(open('$GOG_CREDS'))['client_id'])")
CLIENT_SECRET=$(python3.12 -c "import json; print(json.load(open('$GOG_CREDS'))['client_secret'])")
REFRESH_TOKEN=$(python3.12 -c "import json; print(json.load(open('$TOKEN_FILE'))['refresh_token'])")

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" || -z "$REFRESH_TOKEN" ]]; then
  fatal "Failed to read OAuth credentials"
fi

# --- Step 3: Get fresh access token ---

log "Step 3/7: Getting fresh access token from Google..."
ACCESS_TOKEN=$(python3.12 -c "
import urllib.request, urllib.parse, json
data = urllib.parse.urlencode({
    'client_id': '''$CLIENT_ID''',
    'client_secret': '''$CLIENT_SECRET''',
    'refresh_token': '''$REFRESH_TOKEN''',
    'grant_type': 'refresh_token'
}).encode()
req = urllib.request.Request('https://oauth2.googleapis.com/token', data=data)
resp = urllib.request.urlopen(req)
print(json.loads(resp.read())['access_token'])
")

if [[ -z "$ACCESS_TOKEN" ]]; then
  fatal "Failed to get access token from Google"
fi
log "  Access token obtained (${#ACCESS_TOKEN} chars)"

# --- Step 4: Get workspace member ID ---

log "Step 4/7: Getting Twenty workspace member ID..."
MEMBER_ID=$(bash "$TWENTY_SCRIPTS/twenty-graphql.sh" \
  '{ workspaceMembers { edges { node { id } } } }' \
  | python3.12 -c "import json,sys; print(json.load(sys.stdin)['data']['workspaceMembers']['edges'][0]['node']['id'])")

if [[ -z "$MEMBER_ID" ]]; then
  fatal "Failed to get workspace member ID"
fi
log "  Member ID: $MEMBER_ID"

# --- Step 5: Create connected account ---

log "Step 5/7: Creating connected account in Twenty..."
CONNECTED_RESP=$(bash "$TWENTY_SCRIPTS/twenty-rest-post.sh" "/connectedAccounts" "{
  \"handle\": \"$ACCOUNT\",
  \"provider\": \"google\",
  \"accessToken\": \"$ACCESS_TOKEN\",
  \"refreshToken\": \"$REFRESH_TOKEN\",
  \"accountOwnerId\": \"$MEMBER_ID\",
  \"scopes\": [\"email\", \"https://www.googleapis.com/auth/gmail.readonly\", \"https://www.googleapis.com/auth/calendar\"]
}")

CONNECTED_ID=$(echo "$CONNECTED_RESP" | python3.12 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null || echo "")

if [[ -z "$CONNECTED_ID" ]]; then
  warn "Could not extract connectedAccount ID from response"
  warn "Response: $CONNECTED_RESP"
  warn "You may need to extract the ID manually and run step 6"
  exit 2
fi
log "  Connected account ID: $CONNECTED_ID"

# --- Step 6: Create message channel ---

log "Step 6/7: Creating message channel..."
CHANNEL_RESP=$(bash "$TWENTY_SCRIPTS/twenty-rest-post.sh" "/messageChannels" "{
  \"handle\": \"$ACCOUNT\",
  \"type\": \"EMAIL\",
  \"visibility\": \"SHARE_EVERYTHING\",
  \"isContactAutoCreationEnabled\": true,
  \"contactAutoCreationPolicy\": \"SENT_AND_RECEIVED\",
  \"isSyncEnabled\": true,
  \"excludeNonProfessionalEmails\": false,
  \"excludeGroupEmails\": false,
  \"connectedAccountId\": \"$CONNECTED_ID\"
}")

log "  Message channel response: $CHANNEL_RESP"

# --- Step 7: Clean up ---

log "Step 7/7: Cleaning up..."
# TOKEN_FILE cleaned up by trap

log ""
log "CRM email sync configured for $ACCOUNT"
log "  Connected Account: $CONNECTED_ID"
log "  Status will start as PENDING_CONFIGURATION"
log "  Twenty should begin syncing emails automatically"
log ""
log "Verify with:"
log "  bash $TWENTY_SCRIPTS/twenty-graphql.sh '{ connectedAccounts { edges { node { id handle provider } } } }'"
