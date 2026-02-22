#!/usr/bin/env bash
#
# setup-github-gates.sh — configure branch protection for MyPA policy checks
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

REPO="${1:-${GITHUB_REPOSITORY:-}}"
BRANCH="${2:-main}"
CHECKS="${3:-predeployment-gate}"

if [[ -z "$REPO" ]]; then
  if command -v git >/dev/null 2>&1; then
    REPO="$(git remote get-url origin | sed -E 's#https://github.com/##; s#git@github.com:##; s#\\.git$##')"
  fi
fi
[[ -z "$REPO" ]] && fatal "Unable to determine repository. Set GITHUB_REPOSITORY or pass <owner/repo>."

if ! command -v gh >/dev/null 2>&1; then
  fatal "GitHub CLI is required (`gh`)."
fi

if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
  warn "No token env found; gh CLI will use its default auth flow."
fi

IFS=',' read -r -a CHECK_ARRAY <<< "$CHECKS"
CONTEXT_JSON="["
for check in "${CHECK_ARRAY[@]}"; do
  check="$(echo "$check" | xargs)"
  [[ -z "$check" ]] && continue
  if [[ "$CONTEXT_JSON" != "[" ]]; then
    CONTEXT_JSON+=", "
  fi
  CONTEXT_JSON+="\"$check\""
done
CONTEXT_JSON+="]"

log "Configuring protection for ${REPO}@${BRANCH} with required checks: ${CHECKS}"

PAYLOAD=$(cat <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${CONTEXT_JSON}
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null
}
EOF
)

echo "$PAYLOAD" | gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input -
log "Branch protection applied for ${REPO}/${BRANCH}."
log "Optional follow-up: create CODEOWNERS file for review ownership and enable code owner reviews."
