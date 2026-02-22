# Team Onboarding Workflow — `scripts/onboard-team.sh`

## Goal

One script that guides the platform admin through setting up a new team from scratch — from CRM workspace to verified, working PAs with iPhone app access. Primary onboarding channel is the **official OpenClaw iOS app** (built from source, distributed via our own TestFlight). Telegram remains as a secondary/fallback channel.

---

## Key Architecture Decision: Official OpenClaw iOS App as Primary Channel

### Why Not Aight

Aight (aight.cool) was initially considered but has three blockers:
1. **TestFlight signup barrier**: Each user must individually sign up and be approved for Aight's TestFlight — we can't guarantee acceptance
2. **Paid conversion risk**: Aight may convert to a paid subscription model
3. **Skills marketplace concern**: Aight includes a ClawHub skills marketplace that lets users install skills beyond admin selection. Server-side controls mitigate risk, but it's unnecessary exposure.

### Why Official OpenClaw iOS App

The official iOS app source lives in the OpenClaw monorepo at [`apps/ios`](https://github.com/openclaw/openclaw/tree/main/apps/ios):

- **Open source**: Full Swift source, build from `apps/ios/` with `pnpm ios:build`
- **Our own TestFlight**: Build with fastlane (included in repo), distribute via our Apple Developer account — no third-party approval needed
- **No skills marketplace**: Clean gateway client only (WebSocket, chat, voice, camera, location)
- **Setup-code onboarding**: v2026.2.9 added `/pair` command + setup code flow
- **Build requirements**: Xcode (current stable), pnpm, xcodegen
- **Alpha status**: UI changing, background unstable — but functional for our use case

### How Members Connect (Two Paths)

**Path A — Gateway Password (simplest)**:
1. Member installs app from our TestFlight link
2. Opens app → Settings → Manual Gateway
3. Enters URL (`wss://mypa-fleet.ts.net/alice-pa/`) + password
4. Taps Connect — done

**Path B — Setup Code (via Telegram bootstrap)**:
1. Member messages PA's Telegram bot: `/pair`
2. Bot responds with a setup code (base64 JSON: gateway URL + short-lived token)
3. Member opens app → Settings → paste setup code → Connect
4. Admin approves: `/pair approve` in Telegram

Path A is primary (no Telegram needed). Path B is available when Telegram bots are configured.

### Gateway Exposure via Tailscale Funnel

Each PA container runs an OpenClaw gateway on `127.0.0.1:3000` (inside container). For the iOS app to connect from the public internet:

```
iPhone (OpenClaw iOS)
    │
    ▼ wss://mypa-fleet.ts.net/alice-pa/
    │
Tailscale Funnel (port 443, public HTTPS)
    │
    ▼ localhost:18789
    │
Caddy (path-based WebSocket proxy, strips prefix)
    │  /alice-pa/* → container gateway port 3001
    │  /bob-pa/*   → container gateway port 3002
    ▼
PA Container (OpenClaw gateway)
```

**Why Caddy intermediary**: Tailscale Funnel supports path-based routing (`--set-path`), but doesn't strip path prefixes. OpenClaw gateways expect connections at `/`. Caddy's `handle_path` directive strips the prefix before proxying.

**No conflict with existing Caddy**: Public DNS (`crm.team.example.com`) resolves to the droplet's public IP → Caddy on 0.0.0.0:443. Tailscale Funnel resolves `mypa-fleet.ts.net` through the Tailscale network stack → forwarded to localhost:18789. Different interfaces, no port conflict.

**Auth per PA**: Each PA's OpenClaw config sets `gateway.auth.mode: "password"` with a unique generated password. Members receive their PA's URL + password during onboarding.

---

## Key Architecture Decision: Agentic RAG for Team Knowledge

### Built-in Memory System

OpenClaw has published, built-in support for agentic RAG via memory plugins. We use this instead of unvetted third-party skills.

**Enable long-term memory plugin** (add to golden templates):
```json
{
  "plugins": {
    "slots": { "memory": "memory-lancedb" },
    "entries": { "memory-lancedb": { "enabled": true } }
  }
}
```

**Add memory sources** (per-agent, team-shared docs):
```json
{
  "agents": {
    "defaults": {
      "memorySearch": {
        "extraPaths": ["../team-docs", "/srv/shared-notes/overview.md"]
      }
    }
  }
}
```

**Verify**:
```bash
openclaw plugins list
openclaw memory status --deep --index --verbose
openclaw memory search "what did we decide about onboarding"
```

**Cron-based index refresh** (add to golden template cron jobs):
```bash
openclaw cron add --name "RAG index refresh" \
  --cron "0 */6 * * *" \
  --session isolated \
  --message "Run memory index and report drift" \
  --announce
```

### Implementation in Templates

Add to both `pa-default/openclaw.json` and `pa-admin/openclaw.json`:
- `plugins.slots.memory: "memory-lancedb"` (default memory backend)
- `plugins.entries.memory-lancedb.enabled: true`
- `agents.defaults.memorySearch.extraPaths` (team docs mount point)
- New cron job: RAG index refresh every 6 hours

Team docs mount path is configured during provisioning via `onboard-team.sh` — each team gets its own shared docs volume.

---

## What Exists Today

| Asset | What it does | Gap |
|-------|-------------|-----|
| `provision-pa.sh` | Creates a PA via pactl, applies golden template, starts it | No gateway exposure, no iOS app URL generation, Telegram token still required |
| `ONBOARDING_RUNBOOK.md` | Step-by-step manual guide | Telegram-only, no iOS app flow, no state tracking |
| `skills/team-router/SKILL.md` | `/team new` generates config artifacts via the master PA | Generates text artifacts only, no gateway exposure |
| `templates/team-sync-config.json` | Per-team CRM sync toggle | Config template, no provisioning logic |
| `templates/pa-default/openclaw.json` | Golden PA config | No memory plugin, no password auth, Telegram required |

## Design: `scripts/onboard-team.sh`

One interactive script. Runs on the droplet (or locally via Tailscale SSH). Two modes:
- **Interactive** (default): Prompts for each input, prints instructions for manual steps, waits for confirmation, runs automated steps
- **Non-interactive** (`--manifest team.json`): Reads all inputs from a JSON manifest file, skips prompts, fails on any missing data

### State File for Resume

Onboarding can take 30+ minutes (Google Admin, OAuth are slow manual steps). The script writes a state file after each completed phase so it can resume if interrupted.

```
State file: /tmp/mypa-onboard-<team-slug>.state (or --state-dir override)
Format: KEY=VALUE pairs (sourceable bash)
```

Example:
```bash
TEAM_NAME="Acme Corp"
TEAM_SLUG="acme-corp"
PHASE="members"           # resume point
CRM_WORKSPACE_CREATED=true
CRM_WORKSPACE_URL="https://acme-corp.crm.team.example.com"
CRM_API_KEY="eyJ..."
CRM_SYNC=false
ADMIN_AGENT_CONFIGURED=true
ADMIN_BOT_TOKEN="123456:ABC..."
FUNNEL_CONFIGURED=true
CADDY_PA_CONFIG="/etc/caddy/conf.d/pa-gateways.caddy"
MEMBERS_PROVISIONED="alice-acme-pa|wss://mypa-fleet.ts.net/alice-acme-pa/,bob-acme-pa|wss://mypa-fleet.ts.net/bob-acme-pa/"
MEMBERS_REMAINING="carol-acme-pa"
```

Resume: `./onboard-team.sh --resume --state-dir /tmp`

### JSON Manifest for Non-Interactive Mode

```json
{
  "team_name": "Acme Corp",
  "crm_sync": false,
  "leader": {
    "name": "Alice Smith",
    "email": "alice@acme.com"
  },
  "members": [
    {
      "name": "Alice Smith",
      "email": "alicepa-acme@yourdomain.com",
      "type": "member"
    },
    {
      "name": "Bob Jones",
      "email": "bobpa-acme@yourdomain.com",
      "type": "member"
    }
  ],
  "admin_bot_token": "111111:GHI...",
  "crm_api_key": "eyJ..."
}
```

Note: `telegram_token` per member is no longer required (iOS app is primary). Telegram bot tokens can be added later as a secondary channel.

### Script Phases

#### Phase 1: Pre-flight Checks
- Verify pactl.sh exists and is executable
- Verify env vars: `BRAVE_API_KEY`, `TWENTY_CRM_URL`, `TWENTY_CRM_KEY`
- Verify Twenty CRM is healthy (`/healthz`)
- Verify templates exist (`pa-default/openclaw.json`, `pa-admin/openclaw.json`, `SOUL.md`, `IDENTITY.md`)
- Verify Tailscale is running and Funnel is enabled: `tailscale status`, check MagicDNS + Funnel node attributes
- Verify Caddy PA gateway config directory exists
- Run `validate-week1.sh` (dry-run validation gates)
- If any check fails: print what's missing, exit with instructions

#### Phase 2: Team Setup (Interactive)
1. **Collect team info** (or read from manifest):
   - Team display name
   - Team slug (auto-generated from name, confirm with user)
   - Team leader name and email
   - CRM sync toggle (y/n, default n)
   - Number of team members to provision

2. **Create CRM workspace**:
   - Print instructions: "Go to https://crm.team.example.com → Admin → Create Workspace"
   - Prompt: "Enter the subdomain you created (e.g., acme-corp):"
   - Verify workspace exists: `curl https://<slug>.crm.team.example.com/healthz`
   - Prompt: "Create an API key in the new workspace → Settings → API Keys. Paste it here:"
   - Verify API key works: test REST call
   - Set team leader as workspace admin (print instructions if can't automate)
   - Save to state: `CRM_WORKSPACE_CREATED=true`, URL, key

3. **Update team-sync-config.json**:
   - Read existing config from droplet (or template)
   - Add team entry with sync_enabled based on toggle
   - Write updated config

4. **Configure admin gateway** (admin's master PA):
   - Generate agent config block: `{"id": "admin-<slug>", "name": "<Team Name>", "workspace": "~/.openclaw/workspace-<slug>"}`
   - Generate binding entry: `{"agentId": "admin-<slug>", "match": {"channel": "telegram", "accountId": "<slug>"}}`
   - Print instructions for @BotFather: "Create bot @admin_<slug>_pa_bot, copy the token" (admin's team agent only — NOT per member)
   - Prompt: "Paste the bot token for the admin team agent:"
   - Generate Telegram account entry with the token
   - Print ALL three config snippets in a copy-paste-ready block
   - Print instructions: "Add these to your admin gateway openclaw.json, commit, and restart"
   - Prompt: "Press Enter when the admin gateway is restarted..."
   - Save to state: `ADMIN_AGENT_CONFIGURED=true`

5. **Set up Tailscale Funnel + Caddy PA routing** (one-time per droplet, idempotent):
   - If Caddy PA gateway listener not configured:
     - Add Caddy config block listening on `localhost:18789` for PA WebSocket proxying
     - Reload Caddy
   - Set up Tailscale Funnel: `tailscale funnel --bg 18789`
   - Verify Funnel is serving: `tailscale funnel status`
   - Save Tailscale hostname to state: `FUNNEL_HOSTNAME=mypa-fleet.ts.net`
   - Save to state: `FUNNEL_CONFIGURED=true`

#### Phase 3: Member Provisioning Loop
For each team member:
1. **Collect member info** (or read from manifest):
   - Member name
   - PA instance name (auto: `<firstname>-<slug>-pa`)
   - PA email
   - PA type (member/admin)
2. **Manual pre-reqs** (batched — print ALL at once, then wait):
   - Print: "For ALL members, create Google Workspace accounts:"
   - "  [ ] <email> for <name>"
   - After all listed: "Complete the above, then press Enter"
   - (No Telegram bot creation needed — iOS app is primary)
3. **Provision via `provision-pa.sh`**:
   - Generate a unique gateway password for this PA: `openssl rand -hex 16`
   - Delegate: `provision-pa.sh --name <pa-name> --member <name> --team <team> --email <email> --type <type> [--crm-sync] --gateway-password <password>`
   - Note: `--telegram-token` is now optional (deferred to secondary channels phase)
   - Capture exit code and output
   - If success: add to `MEMBERS_PROVISIONED` in state
   - If failure: add to `MEMBERS_FAILED`, print error, continue with next member
4. **Expose PA gateway via Caddy + Funnel**:
   - Get container's mapped gateway port from Docker labels: `docker inspect "mypa-${pa_name}" --format '{{index .Config.Labels "mypa.gateway_port"}}'`
   - Add Caddy route: `handle_path /<pa-name>/* { reverse_proxy localhost:<port> }`
   - Reload Caddy
   - PA URL: `wss://<FUNNEL_HOSTNAME>/<pa-name>/`
5. **Generate member onboarding card** (printed to terminal + saved to file):
   ```
   ┌─────────────────────────────────────────────┐
   │  PA READY: alice-acme-pa                    │
   │                                             │
   │  1. Install OpenClaw iOS from TestFlight:   │
   │     https://testflight.apple.com/join/XXXXX │
   │                                             │
   │  2. Open app → Settings → Manual Gateway    │
   │     URL:      wss://mypa-fleet.ts.net/      │
   │               alice-acme-pa/                 │
   │     Password: a1b2c3d4e5f6...               │
   │                                             │
   │  3. Tap Connect — you're in!                │
   │                                             │
   │  (Optional) Telegram fallback:              │
   │  Ask admin to create a bot at @BotFather    │
   └─────────────────────────────────────────────┘
   ```
6. Save to state after each member

#### Phase 4: Post-Provisioning Verification
1. **List all provisioned PAs**: `docker ps --filter "label=mypa.managed=true" --filter "label=mypa.team=<team>" --format '{{.Names}}'`
2. **For each PA**: Check status is "running"
3. **Test gateway connectivity**: `curl -sf https://<FUNNEL_HOSTNAME>/<pa-name>/healthz`
4. **Print manual steps remaining** (per PA):
   - gog OAuth (interactive browser): "Open VNC via `pactl vnc <PA name>` → Terminal → run `gog auth credentials ~/client_secret.json`"
   - "Send each member their onboarding card (printed above)"
5. **Print verification test matrix** (for each PA, after member connects via iOS app):
   - "What model are you running?" → Claude Sonnet 4.6
   - "Check my email" → Gmail query
   - "What's on my calendar?" → Calendar query
   - "Look up any contact in CRM" → Twenty CRM query
   - "Run ls -la" → Should refuse
   - "What do you remember about X?" → Tests RAG memory
6. **Print summary**:
   ```
   TEAM ONBOARDING COMPLETE: Acme Corp
   ─────────────────────────────────────
   CRM Workspace:  https://acme-corp.crm.team.example.com
   CRM Sync:       DISABLED (team-local only)
   Admin Agent:    admin-acme-corp (in master gateway)
   Gateway:        wss://mypa-fleet.ts.net/<pa-name>/
   Memory:         memory-lancedb (RAG index refresh every 6h)
   Members:        2 provisioned, 0 failed
     - alice-acme-pa  RUNNING  wss://mypa-fleet.ts.net/alice-acme-pa/
     - bob-acme-pa    RUNNING  wss://mypa-fleet.ts.net/bob-acme-pa/

   MEMBER ONBOARDING CARDS: saved to /tmp/mypa-onboard-acme-corp-cards/

   REMAINING MANUAL STEPS:
     [ ] gog OAuth for each PA (interactive browser flow)
     [ ] Send onboarding cards to team members
     [ ] End-to-end verification tests (after members connect)
     [ ] Brief team members on PA capabilities

   OPTIONAL (add later):
     [ ] Create Telegram bots per member at @BotFather (secondary channel)
     [ ] Configure Slack integration per team
     [ ] Add team-specific docs to memory extraPaths
   ```

### What Gets Automated vs. Prompted

| Step | Automated | Why |
|------|-----------|-----|
| Pre-flight checks | Yes | API calls + file checks |
| CRM workspace creation | **No** — prints instructions | Twenty has no public workspace creation API |
| CRM API key verification | Yes | REST call with key |
| Team sync config update | Yes | jq write to config file |
| Admin gateway config generation | Yes | JSON snippets from template |
| Admin gateway config application | **No** — prints snippets | Safety: config changes go through git |
| Admin gateway restart | **No** — waits for user | Side-effect-heavy |
| @BotFather bot (admin agent only) | **No** — prints instructions | Telegram policy, 1 bot not N |
| Google Workspace account creation | **No** — prints instructions | Requires Admin Console |
| PA provisioning (pactl) | Yes | Delegates to `provision-pa.sh` |
| Gateway password generation | Yes | `openssl rand -hex 16` |
| Tailscale Funnel setup | Yes | `tailscale funnel` CLI |
| Caddy PA route addition | Yes | Config write + reload |
| PA gateway URL generation | Yes | Computed from Funnel hostname + PA name |
| Onboarding card generation | Yes | Template with PA-specific values |
| Memory plugin config | Yes | Included in golden template |
| RAG cron job | Yes | Included in golden template |
| PA status verification | Yes | Docker inspect + gateway health check |
| gog OAuth | **No** — prints instructions | Interactive browser flow |
| Telegram per-member bots | **Deferred** — optional secondary channel | Not needed for iOS-app-first onboarding |

---

## iOS App Build & Distribution

### One-Time Setup (Admin)

1. Clone OpenClaw repo: `git clone https://github.com/openclaw/openclaw.git`
2. Build iOS app: `pnpm install && pnpm ios:build`
3. Set up fastlane with Apple Developer account credentials
4. Submit to TestFlight: `cd apps/ios && fastlane beta`
5. Get TestFlight invite link to share with all team members

### Distribution

All team members across all teams use the same TestFlight link. No per-user approval — anyone with the link can install. TestFlight allows up to 10,000 external testers.

### Updates

When OpenClaw releases a new version with iOS improvements:
1. Pull latest from upstream
2. Rebuild: `pnpm ios:build`
3. Submit to TestFlight: `fastlane beta`
4. TestFlight auto-notifies users of the update

---

## Files to Create/Modify

### New: `scripts/onboard-team.sh`
- ~500-600 lines
- Dependencies: `jq`, `curl`, `envsubst`, `openssl`, `tailscale`, `bash 4+`
- Sources: `provision-pa.sh` (delegates, doesn't duplicate)
- Reuses: `pactl` commands and Docker inspect for PA management

### Modify: `scripts/provision-pa.sh`
- Add `--gateway-password <password>` flag (optional — if provided, sets `gateway.auth.mode: "password"` in the applied config)
- Make `--telegram-token` optional (not required when iOS app is primary)
- When telegram token is omitted, skip Telegram config injection but keep the channel entry disabled

### Modify: `templates/pa-default/openclaw.json`
- Add `gateway.auth.password` placeholder: `"${PA_GATEWAY_PASSWORD}"`
- Add `discovery.mdns.mode: "off"` (containers don't need Bonjour)
- Add `plugins.slots.memory: "memory-lancedb"`
- Add `plugins.entries.memory-lancedb.enabled: true`
- Add `agents.defaults.memorySearch.extraPaths` (team docs mount)
- Add RAG index refresh cron job (every 6 hours)

### Modify: `templates/pa-admin/openclaw.json`
- Same plugin/memory/RAG additions as pa-default

### New: `templates/caddy/pa-gateway.caddy.tmpl`
- Template for Caddy PA gateway routing config
- Used by onboard-team.sh to add per-PA routes

### Modify: `.github/workflows/predeployment-gate.yml`
- Add `bash -n scripts/onboard-team.sh` to "Validate shell scripts" step

### Modify: `scripts/validate-week1.sh`
- Add `scripts/onboard-team.sh` to operational scripts syntax check array

### Modify: `docs/PROJECT_STATE.md`
- Add `scripts/onboard-team.sh` to File Inventory table
- Update Team Provisioning section to reference iOS app + Funnel flow
- Add OpenClaw iOS TestFlight link to Remaining Interactive Steps
- Add memory-lancedb to Architecture Decisions

### Modify: `docs/BUILD_LOG.md`
- Add section about iOS app decision (official vs Aight, build-from-source, Funnel architecture)
- Add section about RAG integration decision

### Modify: `docs/ONBOARDING_RUNBOOK.md`
- Add "Option D: Guided Script" pointing to `onboard-team.sh`
- Add iOS app setup instructions alongside existing Telegram flow
- Mark Telegram as secondary/optional channel

---

## Verification

After implementation:
1. `bash -n scripts/onboard-team.sh` — syntax check passes
2. `./scripts/onboard-team.sh --help` — prints usage without side effects
3. `./scripts/onboard-team.sh --dry-run --manifest test-manifest.json` — validates manifest, runs pre-flight offline, exits before API calls
4. `bash scripts/validate-week1.sh` — existing validation still passes
5. CI passes: `predeployment-gate.yml` includes new script
6. Template JSON validation: `jq . templates/pa-default/openclaw.json` (with new plugin/memory fields)

For live testing (on droplet):
7. Verify Tailscale Funnel setup: `tailscale funnel status` shows port 18789
8. Verify Caddy PA routing: `curl -sf https://mypa-fleet.ts.net/<test-pa>/healthz`
9. Run interactively for a real team — verify each phase, state file, provision-pa.sh delegation
10. Build iOS app from source, submit to TestFlight, install on iPhone
11. Connect via iOS app: enter URL + password, confirm chat works
12. Verify RAG: `openclaw memory status --deep` inside PA container
13. Kill mid-run, then `--resume` — verify pickup from saved phase
14. Run with `--manifest` for a second team — verify non-interactive path
