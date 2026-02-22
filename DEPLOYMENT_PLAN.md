# MyPA Platform Deployment Plan

> **Note:** This document was written before the first deployment. Several decisions changed during execution:
> - **Claworc was removed** (2026-02-14) — replaced by `pactl.sh` (direct Docker commands)
> - **Kimi K2.5 / claude-max-api-proxy removed** — replaced by Claude Sonnet 4.6 (Opus 4.6 for planning) via native Anthropic auth
> - **Full-capability PA paradigm** — all tools enabled; Docker = security boundary (not OCSAS tool deny lists)
> - **OpenClaw iOS app** is primary channel, not Telegram
>
> See [docs/PROJECT_STATE.md](docs/PROJECT_STATE.md) for current state and [docs/BUILD_LOG.md](docs/BUILD_LOG.md) for full history.
> This plan is kept for historical reference. Claworc-specific steps below are **superseded** by `pactl`.

> **MyPA = OpenClaw Team Control Plane**
>
> Team members get OpenClaw-powered Personal AI Assistants (PAs).
> Platform controls what can be installed and executed.
> Users can't break safety boundaries.
> Zero custom application code — configuration and existing tools only.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Tool Choices and Rationale](#2-tool-choices-and-rationale)
3. [How Antfarm Helps Build This](#3-how-antfarm-helps-build-this)
4. [Default PA Specification](#4-default-pa-specification)
5. [Phase 0: Foundation Infrastructure](#5-phase-0-foundation-infrastructure-day-1-2)
6. [Phase 1: Shared Services](#6-phase-1-shared-services-day-2-3)
7. [Phase 2: PA Golden Template](#7-phase-2-pa-golden-template-day-3-4)
8. [Phase 3: First Team Pilot](#8-phase-3-first-team-pilot-day-4-6)
9. [Phase 4: Multi-Team Admin Setup](#9-phase-4-multi-team-admin-setup-day-6-7)
10. [Phase 5: Security Hardening + Antfarm](#10-phase-5-security-hardening--antfarm-day-7-9)
11. [Phase 6: Scale to All Teams](#11-phase-6-scale-to-all-teams-day-9-14)
12. [Risk Assessment](#12-risk-assessment)
13. [Cost Estimate](#13-cost-estimate)
14. [Multi-Team Membership Model](#14-multi-team-membership-model)
15. [Model Routing Strategy](#15-model-routing-strategy)
16. [Version Management](#16-version-management)
17. [Backup Strategy](#17-backup-strategy)
18. [Team Provisioning Workflow](#18-team-provisioning-workflow)
19. [Admin Droplet Isolation](#19-admin-droplet-isolation)
20. [Deployment Tiers](#20-deployment-tiers)
21. [Phase 2 Vision: Tezit Protocol](#21-phase-2-vision-tezit-protocol)
22. [Success Criteria](#22-success-criteria)
23. [Research Sources](#23-research-sources)

---

## 1. Architecture Overview

```
                    +-------------------------------------+
                    |        ADMIN (Multi-Team)           |
                    |                                     |
                    |  Telegram DMs:                      |
                    |   @admin_personal_pa_bot (personal) |
                    |   @admin_alpha_pa_bot   (Team A)    |
                    |   @admin_beta_pa_bot    (Team B)    |
                    +------------------+------------------+
                                       |
            +--------------------------+-------------------------+
            v                          v                         v
+-------------------------------------------+  +--------------------+
| DO Droplet "PA Fleet"                     |  | (on same droplet   |
|                                           |  |  during pilot)     |
| +-----------+                             |  |                    |
| | Claworc   |  Team A PAs (separate):     |  | +--------------+   |
| | Dashboard |  +------------+             |  | | Twenty CRM   |   |
| | (admin)   |  | Alice PA   | (container) |  | | (PostgreSQL) |   |
| +-----------+  | Bob PA     | (container) |  | | Port 3000    |   |
|                +------------+             |  | +--------------+   |
|                                           |  |                    |
|  Team B PAs (separate):                   |  | +--------------+   |
|  +------------+                           |  | | claude-max   |   |
|  | Carol PA   | (container)               |  | | -api-proxy   |   |
|  | Dave PA    | (container)               |  | | Port 3456    |   |
|  +------------+                           |  | +--------------+   |
|                                           |  |                    |
|  Admin Multi-Agent Gateway (ONE process): |  | +--------------+   |
|  +------------------------------------+   |  | | Tailscale    |   |
|  | Admin-Personal (agent, default)    |   |  | | (mesh VPN)   |   |
|  | Admin-Alpha    (agent)             |   |  | +--------------+   |
|  | Admin-Beta     (agent)             |   |  |                    |
|  | tools.agentToAgent.enabled: true   |   |  | Google Workspace   |
|  | sessions_send works between agents |   |  | (external SaaS)    |
|  +------------------------------------+   |  | - PA email accts   |
|                                           |  | - PA calendars     |
| Each PA has: OpenClaw, gog, twenty-crm,   |  +--------------------+
| model-router, SOUL.md, sandbox, Telegram  |
+-------------------------------------------+
```

> **Critical architecture note:** Admin PAs (Admin-Personal, Admin-Alpha, Admin-Beta)
> run as multiple agents within a **single OpenClaw gateway process**, not as
> separate Docker containers. This is required because `sessions_send` is
> an intra-gateway feature and cannot cross container boundaries. Regular team
> member PAs run as separate Docker containers (managed by `pactl`) with full isolation.

### Droplet Sizing

**Pilot (Phase 0-3): Single Droplet**

| Droplet | Spec | Monthly Cost | Rationale |
|---------|------|-------------|-----------|
| Combined (pilot) | 4 vCPU / 8GB RAM / 160GB SSD | ~$48 | pactl + 3-5 PAs + Twenty CRM. Tight but adequate for pilot. |

**Scale (Phase 4+): Split When Needed**

| Droplet | Spec | Monthly Cost | Rationale |
|---------|------|-------------|-----------|
| PA Fleet | 8 vCPU / 16GB RAM / 320GB SSD | ~$96 | Each OpenClaw container ~1GB RAM. pactl + 10 PAs = ~11GB. Headroom for growth. |
| Shared Services | 4 vCPU / 8GB RAM / 160GB SSD | ~$48 | Twenty CRM. Split from PA Fleet when exceeding 5-6 PAs. |

Scale: Add a second PA Fleet droplet when you exceed ~12-14 PAs.

---

## 2. Tool Choices and Rationale

Every choice was made against three criteria:
1. Does it have active contributors and real users?
2. Does it reduce the integration surface rather than expand it?
3. Could we rip it out and replace it without rewriting everything else?

### pactl — Instance Management

**Choice:** `scripts/pactl.sh` — auditable bash wrapping Docker directly (~460 lines, no external dependencies)

> **Decision:** Claworc was evaluated and removed on 2026-02-14. Trust audit found `CVE-2026-25639` (axios), `CVE-2025-22868` (oauth2), Docker socket mount, privileged containers, `InsecureSkipVerify`, and container restart loops. Replaced by pactl — direct Docker commands with no control plane.

**What pactl provides:**
- `pactl create <name>` — creates container with named volumes, specific `--cap-add` (not `--privileged`), `--cgroupns=host`
- `pactl config <name>` — pushes golden template with variable substitution into running container
- `pactl start/stop/restart/status/list/logs/exec/vnc/backup/token-rotate/remove`
- Auto-assigns VNC port (6081+) and gateway port (3001+) per PA
- Container labeled `mypa.managed=true` for discovery by healthcheck and backup scripts
- Token rotation via `pactl token-rotate` (also integrates with 1Password via `rotate-gateway-token.sh`)

**Why not alternatives:**
- **Claworc:** Removed — CVEs, Docker socket mount, privileged containers, restart loops (see BUILD_LOG.md)
- **Docker Compose:** Would need per-PA compose file; pactl is simpler and more auditable
- **Kubernetes/k3s:** Massive ops overhead for 10-30 PAs on a single droplet

### Model Strategy — Claude Sonnet 4.6 / Opus 4.6

**Choice:** Claude Sonnet 4.6 for all PA execution; Claude Opus 4.6 for planning sessions

> **Supersedes original plan.** Kimi K2.5, claude-max-api-proxy, and the model-router skill were removed (2026-02-14). OpenClaw supports native Anthropic auth directly — no proxy required.

**Model roles:**
- **Claude Sonnet 4.6** — default for all PA tasks: email, calendar, CRM, coding, research, web browsing. Released 2026-02-18.
- **Claude Opus 4.6** — for planning, architecture decisions, complex multi-step reasoning. Use intentionally, not as default.

**Auth setup (per PA, one-time via VNC):**
```bash
# Step 1: On Mac with browser — generates 1-year OAuth token
claude setup-token   # outputs sk-ant-REDACTED

# Step 2: Inside PA container (VNC terminal)
openclaw onboard --non-interactive --accept-risk \
  --auth-choice token --token-provider anthropic \
  --token "sk-ant-REDACTED" \
  --skip-channels --skip-skills --skip-daemon --skip-health --skip-ui \
  --gateway-auth password --gateway-password "$GATEWAY_PASSWORD" \
  --gateway-port 3000 --gateway-bind lan

# Step 3: Persist in container .bashrc
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-REDACTED
```

**Why native auth over proxy:** No TOS risk, no proxy to maintain, 1-year token means ~annual renewal only.

### Google Workspace — PA Email & Calendar

**Choice:** Google Workspace Business Starter (~$7/user/mo) with [gog skill](https://skills.sh/openclaw/openclaw/gog)

**Why not AgentMail or ClawMail:**
- [AgentMail](https://www.agentmail.to/) and [ClawMail](https://clawmail.dev/) are purpose-built for agent email — but PAs need calendar, drive, and contacts too, not just email.
- AgentMail gives `alice-pa@agentmail.to`. Google gives `alice-pa@yourdomain.com` with full calendar, Drive, contacts.
- The `gog` skill is ONE OAuth flow for Gmail + Calendar + Drive + Contacts + Sheets + Docs.
- Recipients see a real domain and know it's a PA, not the human directly.
- Google's domain reputation = better email deliverability than new agent-email domains.

**The separation principle:** Every PA has its own email and calendar. When a PA emails a human, the recipient knows they're communicating with an AI assistant. The PA email is distinct from the human's personal email.

### Twenty CRM — Shared Team CRM

**Choice:** [Twenty CRM](https://twenty.com/) (open source, self-hosted) with [OpenClaw skill](https://github.com/openclaw/skills/blob/main/skills/jhumanj/twenty-crm/SKILL.md)

**Why Twenty:**
- Open source, self-hosted, API-first (REST + GraphQL)
- GPL-licensed — you own the data and deployment
- #1 open-source CRM in 2026 benchmarks
- Working OpenClaw skill on ClawHub
- Self-hosting means CRM data never leaves your infrastructure

**Requirement:** Needs 8GB RAM for Docker with PostgreSQL, hence its own droplet (or shared with claude-max-api-proxy on the Shared Services droplet).

### OCSAS — Security Verification

**Choice:** [OCSAS](https://github.com/gensecaihq/ocsas) (OpenClaw Security Assurance Standard)

**Why:** CIS Benchmark-style checklist mapped to OpenClaw's native security features. Three tiers (L1 solo, L2 team, L3 enterprise). Every check has a verification command. Replaces ad-hoc security reviews with a repeatable, documented process.

- L2 applied to every team member PA
- L3 applied to admin PAs (the platform operator's)

### Antfarm — Agent Team Workflows

**Choice:** [Antfarm](https://github.com/snarktank/antfarm) by Ryan Carson

**Why:** One-command install, YAML + SQLite + cron, zero external dependencies. Three bundled workflows (feature-dev, security-audit, bug-fix). Custom workflows are just YAML and Markdown. Runs wherever OpenClaw runs.

Used in three specific ways — see [How Antfarm Helps Build This](#3-how-antfarm-helps-build-this).

---

## 3. How Antfarm Helps Build This

### The Honest Assessment

Most of this project is **infrastructure and configuration**, not code. You can't Antfarm your way through "set up a DigitalOcean droplet" or "run `gog auth credentials`." Those are manual ops tasks.

Antfarm helps in three specific, surgical ways:

### 3.1 Writing the PA Provisioning Script (Phase 5)

There IS code to write: a provisioning script that takes a new team member's info and automates PA setup. This is a real feature-dev task with testable acceptance criteria.

```bash
antfarm workflow run feature-dev "Build a robust PA provisioning script that:
creates a pactl container from the golden template, injects API keys,
configures Telegram, installs skills, runs OCSAS L2 verification, and
outputs onboarding instructions. Must handle errors gracefully and be idempotent."
```

Antfarm's 7 agents (planner, developer, verifier, tester, reviewer) will plan it, write it, verify it against acceptance criteria, test it, and create a PR.

### 3.2 Security Audit After Each Phase (Phases 3-5)

After deploying PAs, run Antfarm's security-audit workflow against the config repo:

```bash
antfarm workflow run security-audit "Audit the PA platform config repo for
security issues, credential leaks, misconfigurations, and OCSAS compliance gaps"
```

This creates a three-layer security verification:

```
Layer 1: openclaw security audit --deep    (built-in, per-PA)
Layer 2: OCSAS checklist verification      (framework, per-PA)
Layer 3: Antfarm security-audit workflow   (agent-driven, whole deployment)
```

### 3.3 Custom "pa-provision" Workflow (Phase 5, Ongoing)

A reusable Antfarm workflow for onboarding new team members:

```yaml
# workflows/pa-provision/workflow.yml
id: pa-provision
name: Provision New Team PA
agents:
  - id: provisioner
    name: PA Provisioner
    role: Creates and configures new PA instances
  - id: verifier
    name: PA Verifier
    role: Validates PA is correctly configured and secure

steps:
  - id: create-instance
    agent: provisioner
    input: |
      Create a new PA container for {{member_name}} on team {{team_name}} using pactl:
        ./scripts/provision-pa.sh --name "{{pa_name}}" --member "{{member_name}}" --team "{{team_name}}"
      Instance name: {{pa_name}}
      Apply the golden template from templates/pa-default/

  - id: configure-skills
    agent: provisioner
    input: |
      Install and configure skills for {{pa_name}}:
      - gog (OAuth to {{pa_email}})
      - twenty-crm (endpoint: {{crm_url}})
      - model-router (kimi default, claude for coding)
      - calendar

  - id: verify-config
    agent: verifier
    input: |
      Verify PA {{pa_name}} passes all checks:
      - openclaw security audit --deep
      - OCSAS L2 checklist
      - Model routing test (send coding query, verify Claude handles it)
      - Email test (send test email from PA, verify delivery)
      - Calendar test (create event, verify it appears)
      - CRM test (query Twenty, verify response)
```

Usage: `antfarm workflow run pa-provision "Alice for Team Alpha"`

### Where Antfarm is NOT the Right Tool

- DigitalOcean infrastructure setup (manual or Terraform)
- DNS configuration (manual)
- Google Workspace account creation (Admin console or API)
- Telegram bot creation (BotFather, manual)
- Twenty CRM deployment (Docker Compose, one-time)
- Host bootstrap and Docker setup (use `scripts/bootstrap-droplet.sh`)

---

## 4. Default PA Specification

Every new PA is provisioned from this specification. See `templates/pa-default/` for the actual files.

### PA Identity Files

Each PA gets three identity files:

| File | Purpose | Who Controls |
|------|---------|-------------|
| `SOUL.md` | Security boundaries, hard limits, role definition | Admin only — users cannot modify |
| `IDENTITY.md` | Personality, communication style, personal preferences | User-customizable — this is *their* PA |
| Role variant (optional) | Role-specific priorities and briefing format | Admin sets initial, user can request changes |

**Why IDENTITY.md matters:** PAs that feel personal get used more. More usage = more AI leverage for the team. Users should think of their PA as a trusted partner, not a corporate tool. IDENTITY.md encourages this by letting users name their PA, shape its communication style, and teach it their preferences over time.

Available role variants in `templates/soul-variants/`:
- `SOUL-team-lead.md` — unblock team, protect schedule, cross-team awareness
- `SOUL-ic.md` — protect focus time, meeting prep, deep work mode
- `SOUL-sales.md` — pipeline management, follow-up discipline, CRM-heavy

### Built-in Tools — Enable/Deny

| Tool | Status | Rationale |
|------|--------|-----------|
| `web_search` | ENABLED | Requires BRAVE_API_KEY. Safe, read-only. |
| `web_fetch` | ENABLED | URL content extraction. Max 50k chars. |
| `message` | ENABLED | Telegram/Slack/Matrix channel comms. |
| `cron` | ENABLED | Scheduled tasks (briefings, inbox checks). |
| `image` | ENABLED | Image analysis. |
| `sessions_list` | ENABLED | Agent-to-agent visibility. |
| `sessions_history` | ENABLED | Session inspection. |
| `sessions_send` | ENABLED (admin PAs only) | Cross-PA communication. |
| `exec` | **DENIED** | Shell commands — #1 prompt injection vector. |
| `process` | **DENIED** | Background process management. |
| `browser` | **DENIED** | Autonomous browsing — prompt injection highway. |
| `apply_patch` | **DENIED** | File modifications not needed for PA role. |
| `gateway` | **DENIED** | Restart/update — admin only. |
| `elevated` | **DISABLED** | No sandbox escape. |

### Pre-Installed Skills

| Skill | Source | Purpose |
|-------|--------|---------|
| `gog` | `openclaw/openclaw` (bundled) | Gmail + Calendar + Drive + Contacts + Sheets + Docs |
| `twenty-crm` | `jhumanj/twenty-crm` (ClawHub) | CRM queries, company/contact management |
| `model-router` | `digitaladaption/model-router` (ClawHub) | Auto-route coding to Claude, everything else to Kimi |
| `calendar` | `openclaw/skills` (ClawHub) | Cross-provider calendar backup |
| `team-comms` | Local (`skills/team-comms/`) | Communication routing, escalation, PA-to-PA conventions |
| `team-router` | Local (`skills/team-router/`) | Admin only — team routing, provisioning, briefings |

### Skills — DO NOT Install

| Skill Category | Why Not |
|----------------|---------|
| Any unverified ClawHub skill | ClawHavoc: 341 malicious skills found |
| Browser automation skills | Prompt injection risk |
| Shell/terminal skills | Already denied at tool level |
| Crypto/wallet skills | Financial risk |
| Skills not scanned by VirusTotal | Supply chain attack vector |

Always verify skills with [Clawdex](https://clawdex.koi.security/) before installing.

### Default Cron Jobs

| Job | Schedule | Prompt |
|-----|----------|--------|
| Morning briefing | `30 7 * * 1-5` (7:30 AM weekdays) | Check email, calendar for today, CRM updates. Compile morning briefing. |
| Inbox check | `0 */2 9-17 * * 1-5` (every 2h, business hours) | Check for new important emails. Summarize anything urgent. |

### Security Configuration

| Setting | Value | OCSAS Level |
|---------|-------|-------------|
| `gateway.bind` | `127.0.0.1` | L1 |
| `gateway.auth.mode` | `token` | L1 |
| `channels.telegram.dmPolicy` | `pairing` | L1 |
| `channels.telegram.groupPolicy` | `disabled` | L1 |
| `channels.telegram.configWrites` | `false` | L1 |
| `sandbox.mode` | `non-main` (L2) / `all` (L3 for admin) | L2/L3 |
| `sandbox.workspaceAccess` | `ro` (L2) / `none` (L3 for admin) | L2/L3 |
| `sandbox.docker.network` | `none` | L2 |
| `sandbox.docker.memory` | `512m` | L2 |
| `sandbox.docker.cpus` | `1` | L2 |
| `tools.elevated.enabled` | `false` | L2 |

---

## 5. Phase 0: Foundation Infrastructure (Day 1-2)

**Goal:** Bare metal ready, networking secure, nothing exposed to the public internet.

This phase is fully manual. No agents, no automation.

### 0.1 Create DigitalOcean Droplet (Single for Pilot)

- **Pilot Droplet:** 4vCPU / 8GB RAM / 160GB SSD, Ubuntu 24.04, enable monitoring
- Runs everything: Claworc + PAs + Twenty CRM + claude-max-api-proxy
- Split to two droplets when PA count exceeds 5-6 (see Droplet Sizing above)
- Enable DigitalOcean firewall: allow SSH (22), deny all else initially
- Enable DigitalOcean backups (weekly)
- **Set up DO monitoring alerts:** disk > 80%, CPU > 90% sustained 5min, memory > 85%

### 0.2 Harden the Droplet

```bash
# On the droplet:
apt update && apt upgrade -y

# Create non-root user
adduser mypa && usermod -aG sudo mypa

# Disable root SSH login
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

# Install fail2ban
apt install fail2ban -y

# Enable UFW
ufw default deny incoming
ufw allow ssh
ufw enable
```

### 0.3 Install Tailscale on the Droplet + Your Local Machine

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

- All admin access goes through Tailscale mesh VPN
- DO firewall stays deny-all for public internet
- Claworc dashboard only accessible via Tailscale IP

### 0.4 Install Docker on the Droplet

```bash
apt install docker.io docker-compose-v2 -y
systemctl enable docker
# Verify: docker info
```

Claworc supports both Docker and Kubernetes backends. It auto-detects at startup — on a single-server deployment with Docker installed, it uses the Docker backend (manages containers via Docker socket, Docker volumes for persistence, bridge network for inter-container communication). No k3s or Kubernetes required.

### 0.5 DNS Configuration

- `pa.yourdomain.com` -> PA Fleet droplet (Tailscale-only access)
- CRM subdomain if needed (Tailscale-only)

### Verification Gate

- [ ] Droplet running, updated, hardened
- [ ] Tailscale mesh connects your machine to the droplet
- [ ] SSH works only via Tailscale IP
- [ ] Docker running (`docker info` confirms Docker Engine active)
- [ ] No ports exposed to public internet except SSH (prefer Tailscale-only)
- [ ] fail2ban active
- [ ] UFW enabled with deny-all incoming default
- [ ] DO monitoring alerts configured (disk, CPU, memory)

---

## 6. Phase 1: Shared Services (Day 2-3)

**Goal:** Twenty CRM running on the droplet, first team's Claude Max proxy running, accessible via localhost.

### 1.1 Deploy Twenty CRM

```bash
# On the droplet
mkdir -p /opt/twenty && cd /opt/twenty

# Download Twenty's Docker Compose
curl -o docker-compose.yml \
  https://raw.githubusercontent.com/twentyhq/twenty/main/packages/twenty-docker/docker-compose.yml

# Configure .env (see Twenty docs for required variables)
# Required: ACCESS_TOKEN_SECRET, LOGIN_TOKEN_SECRET, POSTGRES_PASSWORD
# Generate secrets: openssl rand -base64 32

docker compose up -d
```

- Verify: Twenty accessible at `http://<tailscale-ip>:3000`
- Create admin account
- Set up initial workspace
- Generate API key for PA skill configuration (save securely)

### 1.2 Deploy Claude Max Proxy (Per-Team)

Each team gets its own Claude Max subscription and proxy instance. For the pilot, deploy the first team's proxy:

```bash
# On the droplet
npm install -g @anthropic-ai/claude-code
npm install -g claude-max-api-proxy

# Authenticate with this team's Max subscription
claude login  # Use the team's Claude Max account credentials
```

Create a systemd service per team. For the pilot team (port 3456):
```bash
cat > /etc/systemd/system/claude-max-proxy-pilot.service << 'EOF'
[Unit]
Description=Claude Max API Proxy — Pilot Team
After=network.target

[Service]
Type=simple
User=mypa
ExecStart=/usr/bin/claude-max-api-proxy --port 3456
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable claude-max-proxy-pilot
systemctl start claude-max-proxy-pilot
```

- Verify: `curl http://localhost:3456/v1/models`
- Test: Send a coding request, confirm Claude responds

**When adding more teams:** Create another systemd service on the next port (3457, 3458, etc.), authenticated to that team's Max account. Each team's PAs point `CLAUDE_PROXY_URL` to their team's proxy port. Teams that don't need coding assistance skip this entirely.

### 1.3 Create Shared API Keys

- **Brave Search API:** Sign up at brave.com/search/api, generate key
- **Moonshot API:** Sign up at platform.moonshot.ai, add $10 prepaid credits, generate key
- Store all keys in a password manager

### Verification Gate

- [ ] Twenty CRM accessible and functioning via Tailscale
- [ ] Admin account created, workspace configured, API key generated
- [ ] claude-max-api-proxy responding, Claude models listed
- [ ] Test query through proxy returns Claude response
- [ ] Proxy running as systemd service (survives reboot)
- [ ] Brave Search API key valid
- [ ] Moonshot API key valid, credits loaded

---

## 7. Phase 2: PA Golden Template (Day 3-4)

**Goal:** A reusable configuration that any new PA is provisioned from. Get this right and every PA deployment is copy-paste. Get it wrong and you debug each PA individually.

### 2.1 Deploy PA Container Management

> **SUPERSEDED:** This section originally described deploying Claworc. Claworc was
> removed (2026-02-14) after CVEs and trust issues. The current approach uses `pactl.sh`
> (direct Docker commands). See `scripts/pactl.sh` and `scripts/bootstrap-droplet.sh`.

```bash
# On PA Fleet droplet — pactl is the current tool
# scripts/bootstrap-droplet.sh handles host setup
# scripts/pactl.sh handles PA lifecycle (create/start/stop/config/backup)
pactl create alice-pa --member "Alice" --team "Team Alpha"
pactl config alice-pa --template pa-default
pactl start alice-pa
```

### 2.2 Create the Golden Template

The golden template lives in this repository under `templates/`. Every PA is provisioned from these files.

Files:
- `templates/pa-default/openclaw.json` — Master PA config
- `templates/pa-default/SOUL.md` — Security boundaries (team member version)
- `templates/pa-default/IDENTITY.md` — Per-PA personality template (user-customizable)
- `templates/pa-default/model-router-config.json` — Task-based model routing
- `templates/pa-admin/openclaw.json` — Admin multi-agent gateway config
- `templates/pa-admin/SOUL.md` — Security boundaries (admin cross-team version)
- `templates/soul-variants/SOUL-team-lead.md` — Team lead role priorities
- `templates/soul-variants/SOUL-ic.md` — Individual contributor role priorities
- `templates/soul-variants/SOUL-sales.md` — Sales role priorities

See the actual template files in this repository for contents.

### 2.3 Create Google Workspace PA Accounts

For each team member who will have a PA:

1. Open Google Workspace Admin Console
2. Create user: `alicepa@yourdomain.com`
3. Set a strong password (store in password manager)
4. Assign Google Workspace Business Starter license
5. Disable 2FA on PA accounts (PAs can't do TOTP)
6. Compensate: restrict login to droplet's Tailscale IP range in Google Admin > Security

### 2.4 Draft the Provisioning Script

See `scripts/provision-pa.sh` in this repository.

The script will be refined by Antfarm's feature-dev workflow in Phase 5, but a working draft is needed now for manual provisioning in Phase 3.

### Verification Gate

- [ ] Claworc dashboard accessible and functional
- [ ] Test instance created and running in Claworc
- [ ] Golden template files committed to this repo
- [ ] SOUL.md template has all necessary boundaries
- [ ] IDENTITY.md template ready for per-PA customization
- [ ] Role-specific SOUL variants available (team-lead, IC, sales)
- [ ] Tool policy denies exec/process/browser/apply_patch/gateway
- [ ] Model routing configured (Kimi default, Claude for coding)
- [ ] Cron jobs defined (morning briefing, inbox check)
- [ ] Google Workspace PA accounts created
- [ ] Provisioning script drafted

---

## 8. Phase 3: First Team Pilot (Day 4-6)

**Goal:** One team fully operational with PAs. Real humans using real PAs for real work.

**Why pilot with one team first:** Integration issues surface here. OAuth flows fail. Telegram pairing is confusing. CRM queries return unexpected results. Cron timing is wrong. Finding these with 3-4 PAs is manageable. Finding them with 20 is a fire.

### 3.1 Provision Pilot Team PAs

> **SUPERSEDED:** Steps a-d below originally used Claworc dashboard and Moonshot/Kimi.
> Current approach uses `pactl` + `provision-pa.sh` + native Anthropic auth (Claude Sonnet 4.6).
> See `scripts/provision-pa.sh` and `docs/admin-pa-deployment-handoff.md` for current process.

For each member of the pilot team (e.g., Alice, Bob, plus the admin as Admin-TeamA):

**a) Create PA container** using pactl (replaces Claworc dashboard):
```bash
./scripts/provision-pa.sh --name alice-pa --member "Alice Smith" --team "Team Alpha" --email alice-pa@yourdomain.com
```

**b) Apply golden template** — provision-pa.sh handles this automatically.

**c) Set environment variables** — pactl handles injection; key vars are:
```
BRAVE_API_KEY=<shared>
PA_GATEWAY_TOKEN=<generated by pactl>
```

**d) Install skills** — configured in `templates/pa-default/openclaw.json`:
```bash
# Skills auto-install on first run via openclaw.json skills.installed list
# gog and twenty-crm are pre-configured in the golden template
```

**e) Configure Telegram:**
1. Create bot via @BotFather (one per PA)
2. Set bot token in PA config
3. Team member messages their bot, receives pairing code
4. Admin approves: `openclaw pairing approve telegram <CODE>`

**f) OAuth Google Workspace for gog:**
```bash
# From PA terminal (via Claworc dashboard):
gog auth credentials ~/client_secret.json
# Authorize with the PA's Google Workspace email
# Test: gog gmail list
```

**g) Configure Twenty CRM skill:**
- Create `config/twenty.env` with CRM URL and API key
- Test: Ask PA "Who are our contacts in Twenty?"

### 3.2 Test Each PA End-to-End

Send each PA these test messages via Telegram:

```
1. "What model are you running?"
   Expected: Kimi K2.5

2. "Write a Python function to sort a list"
   Expected: Model-router switches to Claude

3. "Check my email"
   Expected: Queries Gmail via gog skill

4. "What's on my calendar today?"
   Expected: Queries Google Calendar

5. "Look up Acme Corp in our CRM"
   Expected: Queries Twenty CRM

6. "Search the web for OpenClaw security best practices"
   Expected: Uses Brave Search

7. "/model status"
   Expected: Shows Kimi primary, Claude fallback
```

### 3.3 Run Security Verification

On each PA:
```bash
openclaw security audit --deep
openclaw security audit --fix

# OCSAS L2 checklist:
# [ ] Gateway auth enabled
# [ ] DM pairing active
# [ ] Session isolation active (dmScope: per-channel-peer)
# [ ] Sandbox enabled (mode: non-main)
# [ ] Tool deny list applied
# [ ] File permissions 700/600
```

### 3.4 Observe for 2-3 Days

Let the pilot team use their PAs for real work. Watch for:
- Rate limit issues (Claude Max being hit too often?)
- Cron job timing (morning briefings arriving at wrong time?)
- Email deliverability (PA emails landing in spam?)
- CRM query accuracy
- Model router classification errors
- Any unexpected PA behavior (prompt injection from email content?)

### Verification Gate

- [ ] Every pilot team member can chat with their PA via Telegram
- [ ] Email: PA can read inbox and send messages from PA email account
- [ ] Calendar: PA can check schedule and create events
- [ ] CRM: PA can query and update Twenty
- [ ] Model routing: coding tasks go to Claude, everything else to Kimi
- [ ] Morning briefing fires correctly at 7:30 AM
- [ ] Security audit passes with no critical findings
- [ ] No unexpected PA behaviors observed over 48+ hours

---

## 9. Phase 4: Multi-Team Admin Setup (Day 6-7)

**Goal:** Admin can operate across all teams from a personal PA that aggregates information.

> **Critical:** Admin PAs use OpenClaw's multi-agent mode (multiple agents within
> one gateway process), NOT separate Claworc containers. This is required because
> `sessions_send` is intra-gateway only — it cannot cross container boundaries.

### 4.1 Create Admin Multi-Agent Gateway

See `templates/pa-admin/openclaw.json` for the full gateway template.

Instead of separate Claworc containers, create ONE OpenClaw instance with multiple agents.
Start with your personal agent, then add one agent per team/business as you onboard them:

```jsonc
{
  "agents": {
    "list": [
      {
        "id": "admin-personal",
        "default": true,
        "name": "Personal",
        "workspace": "~/.openclaw/workspace-personal"
      },
      {
        "id": "admin-alpha",
        "name": "Team Alpha",
        "workspace": "~/.openclaw/workspace-alpha"
      },
      {
        "id": "admin-beta",
        "name": "Team Beta",
        "workspace": "~/.openclaw/workspace-beta"
      }
    ]
  },

  "bindings": [
    { "agentId": "admin-personal", "match": { "channel": "telegram", "accountId": "personal" } },
    { "agentId": "admin-alpha", "match": { "channel": "telegram", "accountId": "alpha" } },
    { "agentId": "admin-beta", "match": { "channel": "telegram", "accountId": "beta" } }
  ],

  "tools": {
    "agentToAgent": {
      "enabled": true,
      "allow": ["*"]  // Wildcard — new team agents auto-allowed
    }
  },

  "channels": {
    "telegram": {
      "accounts": {
        "personal": { "botToken": "${ADMIN_PERSONAL_BOT_TOKEN}" },
        "alpha": { "botToken": "${ADMIN_ALPHA_BOT_TOKEN}" },
        "beta": { "botToken": "${ADMIN_BETA_BOT_TOKEN}" }
      },
      "dmPolicy": "pairing",
      "groupPolicy": "disabled",
      "configWrites": false
    }
  }
}
```

Each agent gets:
- Its own workspace with team-scoped SOUL.md, memory, and files
- Its own Telegram bot (via multi-account support)
- Its own Google Workspace email (e.g., `admin-pa-alpha@yourdomain.com`)
- Team-scoped CRM access
- OCSAS L3 security (sandbox mode `all`, workspace access `none`)

**What multi-agent gives you:** `sessions_send` works natively between admin-personal, admin-alpha, and admin-beta because they share one gateway process.

**What you lose vs. separate containers:** All three admin agents share one process. A crash affects all three. Accept this tradeoff — admin PAs are the only ones that need cross-agent communication.

### 4.2 Configure Cross-Team Briefing

The personal agent's cron job uses `sessions_send` to query team agents:

```jsonc
{
  "cron": {
    "jobs": [
      {
        "id": "cross-team-briefing",
        "schedule": "0 7 * * 1-5",
        "prompt": "Compile cross-team morning briefing: 1) Use sessions_send to ask agent admin-alpha: 'Team Alpha status today?' 2) Use sessions_send to ask agent admin-beta: 'Team Beta status today?' 3) Check personal email and calendar. 4) Combine into one briefing."
      }
    ]
  }
}
```

### 4.3 Install the team-router Skill

The `team-router` skill (see `skills/team-router/SKILL.md`) gives your personal agent commands for orchestrating teams:

| Command | Purpose |
|---------|---------|
| `/team <name> <instruction>` | Route an instruction to a specific team's sub-agent |
| `/teams status` | Get brief status from every team sub-agent |
| `/teams briefing` | Compile a full cross-team morning briefing |
| `/team new <name>` | Initiate provisioning for a new team/business |
| `/team remove <name>` | Decommission a team sub-agent |
| `/teams list` | List all active team sub-agents |

This skill runs ONLY on the master PA (admin-personal) and uses `sessions_send` to communicate with team sub-agents within the same gateway.

See [Team Provisioning Workflow](#18-team-provisioning-workflow) for how `/team new` works end-to-end.

### 4.4 Test Cross-Agent Communication

```
You -> @admin_personal_pa_bot: "Ask my Team Alpha agent what's on today's agenda"
Personal agent -> sessions_send -> admin-alpha agent -> responds (same gateway)
Personal agent -> compiles and delivers summary to you
```

### 4.5 Cross-Container PA Communication (Admin to Team Member PAs)

Admin PAs **cannot** use `sessions_send` to reach regular team members' PAs (Alice, Bob, Carol) because those run in separate Claworc containers with separate gateways.

For admin-to-team-member-PA communication, use the **email bridge**:
- Admin PA emails `alicepa@yourdomain.com` with a query
- Alice's PA picks it up on its next inbox check (every 2 hours, or reduced to every 15 min for urgent queries)
- Alice's PA replies via email
- Admin PA reads the reply

This is async but requires zero custom code — just Google Workspace + gog skill.

### Verification Gate

- [ ] Admin multi-agent gateway running with three agents
- [ ] Each agent accessible via separate Telegram bots
- [ ] Personal agent successfully queries team agents via `sessions_send`
- [ ] Cross-team morning briefing compiles and delivers correctly
- [ ] Team-scoped isolation verified: Alpha agent workspace can't access Beta workspace
- [ ] OCSAS L3 passes on admin gateway
- [ ] Email bridge tested: Admin PA emails team member PA, gets response

---

## 10. Phase 5: Security Hardening + Antfarm (Day 7-9)

**Goal:** Production-grade security, automated provisioning, repeatable verification.

### 5.1 Install Antfarm on Personal PA

```bash
curl -fsSL https://raw.githubusercontent.com/snarktank/antfarm/v0.4.1/scripts/install.sh | bash
```

### 5.2 Run Antfarm Security Audit

```bash
antfarm workflow run security-audit \
  "Audit the PA platform config repo for security issues, credential leaks, and misconfigurations"
```

### 5.3 Build Provisioning Script with Antfarm Feature-Dev

```bash
antfarm workflow run feature-dev \
  "Build a robust PA provisioning script that: creates a Claworc instance,
  applies the golden template, injects API keys, configures Telegram,
  installs skills, runs OCSAS L2 verification, and outputs onboarding
  instructions. Must handle errors gracefully and be idempotent."
```

### 5.4 Build Custom pa-provision Workflow

Write and test the YAML workflow (see Part 3 above), commit to `workflows/pa-provision/`.

### 5.5 Full OCSAS Verification

```bash
# On every PA:
openclaw security audit --deep
# Verify all OCSAS L2 checks pass (L3 for admin PAs)
# Document any exceptions and why they're accepted
```

### 5.6 Credential Rotation Schedule

| Credential | Rotation | Method |
|-----------|----------|--------|
| Moonshot API key | 90 days | Regenerate on platform.moonshot.ai, update PA env |
| Claude Max setup-token | 90 days | `claude setup-token`, update proxy |
| Brave API key | 90 days | Regenerate, update PA env |
| Telegram bot tokens | 90 days | @BotFather /revoke, new token, update PA config |
| Google Workspace OAuth | Auto-refresh | gog handles via refresh tokens |
| Twenty CRM API key | 90 days | Regenerate in Twenty, update PA skill config |
| Claworc admin password | 90 days | Change in dashboard |
| Gateway auth tokens | 90 days | Per PA, regenerate and restart |

### Verification Gate

- [ ] Antfarm security-audit completed with no critical findings
- [ ] Provisioning script tested and working end-to-end
- [ ] Custom pa-provision workflow tested
- [ ] All PAs pass OCSAS L2 (L3 for admin PAs)
- [ ] Credential rotation schedule documented
- [ ] Calendar reminders set for 90-day rotations
- [ ] Antfarm installed and working on Personal PA

---

## 11. Phase 6: Scale to All Teams (Day 9-14)

**Goal:** All teams onboarded, all members have PAs, everything monitored.

### 6.1 For Each Additional Team/Business

Use your master PA's `/team new` command to initiate team provisioning:

```
/team new <business-name>
```

The team-router skill will generate all configuration artifacts. Then complete the manual steps:

1. Create Telegram bot via @BotFather for the team sub-agent
2. Add bot token to gateway env
3. Create Google Workspace PA account for the team
4. Add the generated agent block + binding + telegram account to admin gateway `openclaw.json`
5. Restart admin gateway
6. Verify via `/teams list` that the new agent is online

**For each team member** within that business:

1. Create member's Telegram bot via @BotFather
2. Create Google Workspace PA account via Admin Console
3. Run provisioning script (or `antfarm workflow run pa-provision`)
4. Configure team-specific SOUL.md if needed
5. Connect to team's Twenty CRM workspace

### 6.2 Scaling Infrastructure

If PA Fleet droplet exceeds ~12 PAs (approaching 16GB RAM):
- Spin up PA Fleet #2 on DigitalOcean (same spec)
- Install Claworc agent on it (connects to Claworc control plane)
- Provision new PAs on the second droplet

### 6.3 Document the Onboarding Runbook

A step-by-step guide that any team lead can follow to request a new PA. See `docs/ONBOARDING_RUNBOOK.md`.

### 6.4 Set Up Monitoring

| What to Monitor | How | Frequency |
|----------------|-----|-----------|
| Instance health | Claworc dashboard | Daily |
| Per-PA usage | `openclaw status --usage` | Weekly |
| Moonshot credits | platform.moonshot.ai dashboard | Weekly |
| Claude Max usage | Anthropic console + proxy logs | Weekly |
| CRM health | Twenty admin panel | Weekly |
| Email deliverability | Google Workspace admin | Weekly |
| Security posture | `openclaw security audit` | Weekly |

### Verification Gate

- [ ] All teams have PAs provisioned and working
- [ ] All team members confirmed they can interact with their PA
- [ ] Cross-team briefing working for admin
- [ ] Monitoring in place and being checked
- [ ] Onboarding runbook documented
- [ ] No critical security findings across any PA
- [ ] API costs within expected range

---

## 12. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Claude Max cancelled by Anthropic (TOS) | Medium | High | Per-team Max subscriptions limit blast radius — losing one doesn't affect other teams. Kimi fallback handles everything. No PA goes dark. Future option: switch to Claude API with per-team budget caps (TOS-safe, pay-per-use). |
| Claworc fails in production | Medium | High | **Red/Yellow drop criteria defined above.** First Red trigger -> migrate to docker compose + admin script that week. Run monthly failover drill so exit is practiced, not theoretical. Do NOT scale past 5 PAs until 2-4 week probation passes. |
| Claworc abandoned (17 stars, 1 maintainer) | Medium | Medium | Fallback architecture: keep OpenClaw containers, replace control plane with `docker compose` + `pactl` script + Caddy reverse proxy. |
| `sessions_send` doesn't work across containers | **Confirmed** | **Resolved** | Admin PAs run as multi-agent single gateway. Regular team member PAs use email bridge for async cross-PA queries. |
| Multi-agent mode bugs (admin PAs) | Medium | Medium | OpenClaw multi-agent has several open issues on session path resolution. If unstable, fall back to separate admin PAs with email bridge only (lose real-time cross-team aggregation, keep async). |
| Model-router misclassifies tasks | High | Low | Users `/model claude` or `/model kimi` to override. Tune classification config. |
| Google PA accounts flagged for bot behavior | Low | Medium | Send at human pace. PA signature identifies as AI. Monitor Google Admin alerts. |
| Prompt injection via inbound email | Medium | High | SOUL.md boundaries + tool deny list + sandbox. Even if model follows injected instructions, it can't exec, write, or install. |
| Twenty CRM goes down | Low | Low | PA gracefully handles unavailability. Fix CRM independently. |
| Moonshot rate limits or outage | Medium | Medium | Add DeepSeek as tertiary fallback. OpenClaw fallback chain handles automatically. |
| Droplet runs out of disk space | Medium | High | DO monitoring alerts at 80%. Resize disk or add volume. Weekly log rotation. |
| Claude Max proxy rate-limited per team | Medium | Low | Each team has its own proxy and subscription — no cross-team contention. Teams without coding needs skip Max entirely. |
| Single Tailscale account compromise | Low | Critical | Enable Tailscale ACLs to restrict which devices can reach which services. MFA on Tailscale account. |
| OpenClaw update breaks skills or config | Medium | High | Pin versions. Test on one PA for 24h before rolling out. Rollback via container recreation with previous image. Never update on Fridays. |
| PA data loss (container corruption) | Low | High | Daily per-PA Docker volume backup via `docker cp`. 14-day retention. Restore individual PAs without affecting others. |

---

## 13. Cost Estimate

### Pilot Cost (Phase 0-3, 1 team, 3-5 PAs)

| Item | Monthly Cost |
|------|-------------|
| DO single droplet (4vCPU/8GB) | $48 |
| Claude Max (1 team subscription) | $200 |
| Moonshot Kimi prepaid (3-5 PAs) | $10-15 |
| Google Workspace (3-5 PA accounts x $7) | $21-35 |
| Brave Search API (free tier) | $0 |
| DigitalOcean backups | ~$10 |
| **Total for pilot (1 team, 3-5 PAs)** | **~$290-310/mo** |

**Per-PA cost at pilot: ~$60-100/month.** High per-PA but low total. Validate before scaling.

### Scale Cost (Phase 4-6, 3 teams, 15-20 PAs)

| Item | Monthly Cost |
|------|-------------|
| DO PA Fleet droplet (8vCPU/16GB) | $96 |
| DO Shared Services droplet (4vCPU/8GB) | $48 |
| Claude Max (3 team subscriptions x $200) | $600 |
| Moonshot Kimi prepaid (15-20 PAs moderate usage) | $30-60 |
| Google Workspace (15-20 PA accounts x $7) | $105-140 |
| Brave Search API (free tier may suffice) | $0-5 |
| DigitalOcean backups | ~$20 |
| **Total for 3 teams, ~18 PAs** | **~$900-970/mo** |

**Per-PA cost at 18 PAs: ~$50-54/month.** Claude Max per-team is the dominant cost. Teams without heavy coding needs can skip Max to bring this down significantly.

### Cost Scaling

| Teams | PAs | Droplets | Claude Max | Google WS | Monthly Total | Per-PA |
|-------|-----|----------|-----------|-----------|--------------|--------|
| 1 | 3-5 | 1x $48 | 1x $200 | $21-35 | ~$290-310 | ~$62-97 |
| 2 | 8-10 | 2x $144 | 2x $400 | $56-70 | ~$610-630 | ~$63-76 |
| 3 | 15-18 | 2x $144 | 3x $600 | $105-126 | ~$870-900 | ~$50-58 |
| 5 | 25-30 | 3x $240 | 5x $1000 | $175-210 | ~$1440-1480 | ~$49-58 |

**Cost optimization:** Not every team needs Claude Max. Teams focused on email/CRM/scheduling (not coding) can run Kimi-only, dropping their per-team cost by $200/mo. At 5 teams where 3 need coding support, the total drops to ~$1040-1080/mo.

The main variable costs are Claude Max (per-team) and Google Workspace (per-PA). Infrastructure amortizes well.

---

## 14. Multi-Team Membership Model

### The Problem

The platform operator runs numerous businesses, each with its own team. The operator needs to be part of every team with isolated context per business. Regular team members are on one team. Adding a new business/team should be as automated as possible — the master PA should drive the provisioning.

### The Solution: Multi-Agent Single Gateway for Admin

> **Key constraint validated Feb 13, 2026:** `sessions_send` is intra-gateway
> only. It cannot cross Docker container boundaries. Admin PAs must run as
> multiple agents within one OpenClaw gateway process.

```
The Platform Operator
|
+-- ONE OpenClaw Gateway (single Claworc container)
|   |
|   +-- Agent "admin-personal" (default)  ->  @admin_personal_pa_bot
|   |   |-- SOUL.md: "You are the operator's cross-team command center"
|   |   |-- gog: admin-pa@yourdomain.com
|   |   +-- sessions_send to admin-alpha and admin-beta (SAME gateway)
|   |
|   +-- Agent "admin-alpha"               ->  @admin_alpha_pa_bot
|   |   |-- SOUL.md: "You are the operator's PA for Team Alpha"
|   |   |-- gog: admin-pa-alpha@yourdomain.com
|   |   +-- Workspace: Team Alpha context, memory, files
|   |
|   +-- Agent "admin-beta"                ->  @admin_beta_pa_bot
|       |-- SOUL.md: "You are the operator's PA for Team Beta"
|       |-- gog: admin-pa-beta@yourdomain.com
|       +-- Workspace: Team Beta context, memory, files
|
+-- tools.agentToAgent.enabled: true
    allow: ["*"]  (wildcard — new teams auto-allowed)
```

**Why multi-agent single gateway (not separate containers):**
- `sessions_send` works natively between agents on the same gateway
- Each agent still has its own workspace, sessions, SOUL.md, and auth profiles
- Context isolation via separate workspaces (no bleed between teams)
- Each agent has its own email identity per team
- Multiple Telegram bot accounts supported via OpenClaw's multi-account feature

**What you lose vs. separate containers:**
- All three admin agents share one process — a crash affects all three
- Multi-agent mode has known bugs (several open GitHub issues on session path resolution)
- This pattern is designed for "one user, multiple personas" — which is exactly the admin use case

**Regular team members** get one PA in a separate Claworc container. Simple.

**Communication between admin and team member PAs** (e.g., querying Alice's PA) uses the email bridge — admin PA emails `alicepa@yourdomain.com`, Alice's PA picks it up on inbox check. Async but zero custom code.

### Scaling to Many Businesses

With the `team-router` skill (see `skills/team-router/SKILL.md`), adding a new business is a conversation:

```
You: /team new Acme Corp
PA:  I'll set up Acme Corp. What team members?
You: Just me for now
PA:  Here's everything needed:
     - Agent config block (add to admin gateway openclaw.json)
     - Binding entry (telegram routing)
     - Telegram account entry (bot token)
     - SOUL.md draft (scoped to Acme Corp)
     - Manual steps checklist
     Ready to proceed?
```

The `agentToAgent.allow: ["*"]` wildcard means new team agents are immediately allowed to communicate with your personal agent — no config update needed for the allow list.

**Practical limits:** Each sub-agent within the multi-agent gateway adds ~200-500MB RAM. At 10+ businesses, consider the admin droplet isolation described in [Admin Droplet Isolation](#19-admin-droplet-isolation).

### Cross-Team Aggregation

Your personal agent's morning cron uses `sessions_send` (intra-gateway):

```
7:00 AM - sessions_send to admin-alpha: "Team Alpha status today?"
7:01 AM - sessions_send to admin-beta: "Team Beta status today?"
7:05 AM - Check personal email and calendar
7:05 AM - Compile unified briefing, send to operator via Telegram DM
```

This is cross-team aggregation built with zero custom code — just OpenClaw's built-in `sessions_send` within a multi-agent gateway.

---

## 15. Model Routing Strategy

### Default Configuration

```
90% of traffic: Kimi K2.5 (cheap, fast, 256k context)
    |-- Email management, CRM lookups, summarization
    |-- Calendar queries, scheduling
    |-- Web research
    |-- Morning briefings, cron jobs
    |-- General conversation
    +-- Heartbeats and status checks

10% of traffic: Claude (via Max proxy, $200/mo flat)
    +-- Code generation, debugging, refactoring
```

### How Routing Works

The [model-router skill](https://github.com/openclaw/skills/blob/main/skills/digitaladaption/model-router/SKILL.md) classifies every incoming request:

| Task Type | Routed To | Why |
|-----------|-----------|-----|
| `simple` | Kimi K2.5 | Weather, schedule, quick queries |
| `coding` | Claude (via proxy) | Best code quality |
| `research` | Kimi K2.5 | Strong reasoning, huge context |
| `creative` | Kimi K2.5 | Adequate for drafts, emails |
| `math` | Kimi K2.5 | Good mathematical reasoning |
| `vision` | Kimi K2.5 | Multimodal capable |
| `long_context` | Kimi K2.5 | 256k tokens |

### Why This Protects Each Team's Max Subscription

Most PA traffic isn't coding. Morning briefings, inbox checks, calendar queries, CRM lookups, email drafting — that's 80-90% of daily PA work. All hits Kimi (pennies).

Claude Max only gets hit for explicit coding requests. Each team has its own Max subscription and proxy, so one team's heavy coding usage doesn't affect another team's rate limits.

### Manual Override

Any user can type:
- `/model claude` — force Claude for current session
- `/model kimi` — switch back to Kimi
- `/model status` — show current model and routing

### Proxy Architecture

```
Team Alpha proxy (port 3456)          Team Beta proxy (port 3457)
  <-- Alice PA (coding only)            <-- Carol PA (coding only)
  <-- Bob PA (coding only)              <-- Dave PA (coding only)
  --> Claude CLI (Alpha Max acct)       --> Claude CLI (Beta Max acct)
```

One proxy instance per team, one Max subscription per team. Teams without significant coding needs can skip Max entirely — their PAs use Kimi for everything.

### Fallback Chain

If Claude Max is rate-limited or down:
```
Primary: Kimi K2.5 (all traffic)
Coding: Claude (via Max proxy) -> if rate-limited -> Kimi K2.5
```

If Kimi is down:
```
Primary: Kimi K2.5 -> if down -> Claude (via Max proxy)
```

No PA ever goes fully dark. The fallback chain always has somewhere to route.

---

## 16. Version Management

### Pin OpenClaw Versions

Every PA must run a pinned OpenClaw version. Never auto-update.

```bash
# Pin to specific version in Claworc instance config or Docker tag
OPENCLAW_VERSION=2026.2.10
```

### Update Strategy

| Step | Action |
|------|--------|
| 1. Test | Update ONE non-critical PA to the new version. Observe for 24h. |
| 2. Pilot | If clean, update pilot team PAs (3-5 instances). Observe for 48h. |
| 3. Roll | If clean, update remaining PAs in batches of 3-5. |
| 4. Pin | Update the pinned version in the golden template. |

**Rollback:** Stop the PA container, retag to the previous image version, restart. Docker volume data persists across container recreation: `docker stop <pa-name> && docker rm <pa-name>` then re-provision with the previous OpenClaw version.

**Skill updates:** Same approach. Never update skills across all PAs simultaneously. Test on one, observe, then roll out. Always verify skills with Clawdex before updating.

**Never update during:** Active team work hours, before major deadlines, or on Fridays.

---

## 17. Backup Strategy

### Per-PA Backup

Each Claworc PA instance has persistent data in Docker volumes. These survive container restarts but NOT volume deletion or disk failure.

| Data | Location | Backup Method | Frequency |
|------|----------|---------------|-----------|
| PA workspace (SOUL.md, memory, files) | Docker volume (`bot-<name>-openclaw`) | `docker cp` to backup dir | Daily |
| PA sessions (conversation history) | Docker volume (`bot-<name>-openclaw`) | `docker cp` to backup dir | Daily |
| PA config (openclaw.json) | Claworc SQLite DB + Docker volume | Stored in this git repo (templates/) | On change |
| Google Workspace data (email, calendar) | Google servers | Google Vault / Takeout | Weekly |
| Twenty CRM data | PostgreSQL on droplet | `pg_dump` to backup dir | Daily |
| Golden templates | This git repo | Git (already backed up) | On change |

### Backup Script (add to cron on droplet)

```bash
#!/bin/bash
# /opt/scripts/backup-pas.sh — run daily at 2 AM
# See scripts/backup-pas.sh for the current implementation
BACKUP_DIR="/opt/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

# Backup each PA's Docker volume data (pactl-managed containers labeled mypa.managed=true)
for PA in $(docker ps --filter "label=mypa.managed=true" --format '{{.Names}}'); do
  docker cp "$PA:/root/.openclaw" "$BACKUP_DIR/$PA/" 2>/dev/null || echo "WARN: Failed to backup $PA"
done

# Backup Twenty CRM database
docker exec twenty-db pg_dump -U twenty twenty > "$BACKUP_DIR/twenty-crm.sql"

# Retain 14 days of backups
find /opt/backups -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \;
```

### Restore a Single PA

If a PA container is corrupted, restore from backup without affecting other PAs:

```bash
# 1. Stop the PA: pactl stop alice-pa
# 2. Copy backup data back into the container
docker cp /opt/backups/2026-02-13/alice-pa/ alice-pa:/root/.openclaw/
# 3. Start the PA: pactl start alice-pa
```

### DigitalOcean Backups (Whole Droplet)

DO weekly backups provide disaster recovery for the entire droplet. These are the safety net, not the primary backup mechanism. The per-PA backups above handle granular recovery.

---

## 18. Team Provisioning Workflow

### Overview

When you have numerous businesses, each needing its own team, provisioning must be as frictionless as possible. The `team-router` skill on your master PA drives this process, generating all config artifacts so you only handle the manual steps that require external services (BotFather, Google Workspace Admin).

### How `/team new` Works End-to-End

```
Step 1: You tell your master PA
        /team new "Acme Corp"

Step 2: PA asks for details
        - Business display name
        - Team members (or "just me for now")
        - CRM workspace needs

Step 3: PA generates artifacts
        a) Agent config block for admin gateway openclaw.json
        b) Binding entry for Telegram routing
        c) Telegram account entry for bot token
        d) SOUL.md draft scoped to the new business
        e) Manual steps checklist

Step 4: You complete manual steps
        [ ] Create Telegram bot via @BotFather
        [ ] Add bot token to gateway env
        [ ] Create Google Workspace PA account
        [ ] Add config to admin gateway openclaw.json
        [ ] Restart admin gateway

Step 5: PA verifies
        - sessions_list to confirm new agent appears
        - sessions_send ping to confirm agent responds
        - Reports result to you
```

### What Can Be Automated (and What Can't)

| Step | Automated? | Why / Why Not |
|------|-----------|---------------|
| Generate config artifacts | Yes | PA produces JSON snippets ready to paste |
| SOUL.md draft | Yes | PA generates from template, scoped to business |
| Create Telegram bot | **No** | Requires @BotFather interaction (Telegram policy) |
| Create Google Workspace account | **No** | Requires Admin Console or Workspace API with admin credentials |
| Edit openclaw.json | **No (deliberate)** | Config changes are reviewed, committed to git |
| Restart gateway | **No** | Side-effect-heavy, must be human-initiated |
| Verify new agent | Yes | PA uses sessions_list + sessions_send |

### Why Config Changes Stay Manual

The team-router skill generates config but does NOT modify files. This is intentional:

1. **Safety** — a prompt injection can't trick the PA into adding a rogue agent
2. **Auditability** — config changes go through git (review, commit, push)
3. **Reversibility** — if something is wrong, you haven't already applied it

### Provisioning Team Members Within a Business

After the team sub-agent is online, team member PAs are provisioned as separate Claworc containers using the standard workflow:

```bash
# Option A: Antfarm workflow
antfarm workflow run pa-provision \
  "Alice Smith for Acme Corp, email alicepa-acme@yourdomain.com"

# Option B: Script
./scripts/provision-pa.sh \
  --name "alice-acme-pa" \
  --member "Alice Smith" \
  --team "Acme Corp" \
  --email "alicepa-acme@yourdomain.com" \
  --telegram-token "<TOKEN>" \
  --type "member"
```

These member PAs are independent containers — they don't need to be in the admin gateway. Your team sub-agent (admin-acme) coordinates with them via email bridge.

### Files

| File | Purpose |
|------|---------|
| `skills/team-router/SKILL.md` | Team routing and provisioning commands |
| `templates/pa-admin/openclaw.json` | Admin multi-agent gateway template |
| `templates/pa-admin/SOUL.md` | Admin PA identity and boundaries |
| `workflows/pa-provision/workflow.yml` | Antfarm workflow for member PA provisioning |
| `scripts/provision-pa.sh` | Provisioning script for member PAs |
| `docs/ONBOARDING_RUNBOOK.md` | Step-by-step onboarding guide |

---

## 19. Admin Droplet Isolation

### Why Isolate the Admin Gateway

Your admin multi-agent gateway is architecturally different from team member PAs:

- It runs ONE process with multiple agents (your personal + all team sub-agents)
- A crash takes down ALL your team visibility simultaneously
- It processes cross-team data — the highest-value target on the platform
- It grows with every new business you add

Team member PAs, by contrast, are isolated containers — one crash affects one person.

### When to Split

**Keep on the same droplet** (pilot / < 5 businesses):
- Single droplet handles everything
- Simpler ops, lower cost
- Acceptable blast radius

**Split to dedicated admin droplet** (> 5 businesses OR production):
- Admin gateway gets its own 4vCPU/8GB droplet
- Team member PA fleet stays on the PA Fleet droplet(s)
- Admin droplet only runs: admin gateway + Tailscale
- Cost: additional ~$48/mo

### Split Architecture

```
Admin Droplet ($48/mo)              PA Fleet Droplet(s) ($96/mo)
+---------------------------+       +---------------------------+
| Admin Multi-Agent Gateway |       | Claworc                   |
|  admin-personal           |       |  Alice PA (container)     |
|  admin-alpha              |       |  Bob PA   (container)     |
|  admin-beta               |       |  Carol PA (container)     |
|  admin-gamma              |       |  Dave PA  (container)     |
|  admin-delta              |       |  ...                      |
|  ...                      |       +---------------------------+
| Tailscale                 |
+---------------------------+       Shared Services ($48/mo)
                                    +---------------------------+
Communication:                      | Twenty CRM                |
  Admin <-> Sub-agents: sessions_send| claude-max-api-proxy      |
  Admin <-> Member PAs: email bridge | Tailscale                 |
                                    +---------------------------+
```

### Memory Planning for Admin Gateway

Each sub-agent within the multi-agent gateway adds overhead:

| Business Count | Agents | Est. RAM | Droplet Spec |
|---------------|--------|----------|-------------|
| 1-5 | 2-6 | 2-4 GB | 4vCPU / 8GB (shared OK) |
| 5-10 | 6-11 | 4-6 GB | 4vCPU / 8GB (dedicated) |
| 10-20 | 11-21 | 6-10 GB | 8vCPU / 16GB (dedicated) |
| 20+ | 21+ | 10+ GB | Consider splitting into multiple gateways |

At 20+ businesses, consider splitting into two admin gateways (e.g., gateway A for businesses 1-10, gateway B for 11-20), each on its own droplet. Your personal agent would run on gateway A and use email bridge to coordinate with gateway B. This loses real-time `sessions_send` for the B group but keeps the architecture manageable.

---

## 20. Deployment Tiers

The same architecture scales from one person to a multi-team organization. No migration, no reprovisioning. Start where you are and grow.

### Tier 0: Solo ($31-55/mo)

Skip Claworc. Run one OpenClaw gateway with your personal PA:

```bash
openclaw setup
# Configure SOUL.md + IDENTITY.md, install skills, add Telegram channel
```

| Item | Cost |
|------|------|
| DO droplet (2vCPU/4GB) | $24/mo |
| Google Workspace (1 PA) | $7/mo |
| Kimi K2.5 credits | ~$5/mo |
| Claude Max (optional) | $0 or $200/mo |
| **Total** | **$36/mo** (or $236/mo with Claude) |

No Claworc, no CRM, no multi-agent. Just you and your PA.

### Tier 1: Solo + First Team (1-3 members, $69-269/mo)

Still no Claworc. Use multi-agent mode in one gateway — all team members' PAs share one process:

```json
{ "agents": { "list": [
  { "id": "admin-personal", "default": true },
  { "id": "alice", "name": "Alice" },
  { "id": "bob", "name": "Bob" }
]}}
```

`sessions_send` works between all PAs. Isolation via separate workspaces and agentDirs. Add Twenty CRM when you need shared contacts.

| Item | Cost |
|------|------|
| DO droplet (4vCPU/8GB) | $48/mo |
| Google Workspace (3 PAs) | $21/mo |
| Kimi K2.5 | ~$10/mo |
| Claude Max (1 team, optional) | $0 or $200/mo |
| **Total** | **$79/mo** (or $279/mo with Claude) |

### Tier 2: Team (4-12 members, $200-500/mo)

Add Claworc for team member container isolation. Admin stays on multi-agent gateway. Add Twenty CRM.

This is Phase 0-3 of the deployment plan. See those phases for details.

### Tier 3: Multi-Team (13+ members, multiple businesses)

Multiple teams, admin droplet isolation, per-team Claude Max. This is Phase 4-6 of the deployment plan.

**When to move up a tier:** When you need the isolation or management features of the next tier, not when you hit a PA count threshold. A solo user with 3 PAs who trusts them can stay on Tier 1 indefinitely.

---

## 21. Phase 2 Vision: Tezit Protocol

> **Status:** Future direction. Do not build until Phase 1 teams are running and real usage patterns emerge.

The email bridge between containers works but is async (minutes of latency) and lacks structure. The Tezit protocol addresses these limitations properly, without custom hacks.

### Concepts Worth Preserving

| Concept | What It Is | How It Ships |
|---------|-----------|-------------|
| **Context icebergs** | Structured layers (background, fact, artifact, constraint, hint) attached to any message | OpenClaw skill + lightweight context store |
| **TIP** | Token-scoped guest interrogation — let external parties query your PA using their own AI resources | Standalone microservice with HTTP endpoints |
| **Library of Context** | FTS5 engagement-scored search across all preserved context | OpenClaw skill + SQLite (could run inside each PA) |
| **Federation** | Ed25519 signed cross-instance messaging | Properly solves `sessions_send` cross-gateway limitation |
| **Mirrors** | Lossy external shares with deep link back to canonical context | Skill that generates mirror links |

### Why Federation Matters

The email bridge is a Phase 1 workaround. Federation is the Phase 2 real solution:

- **Email bridge:** Async (minutes), unstructured, no delivery guarantee, pollutes inbox
- **Federation:** Real-time, structured, cryptographically verified identity, purpose-built for PA-to-PA

Federation would let PAs on separate Claworc containers communicate directly, signed with Ed25519 keys, without needing to share a gateway or route through email. This eliminates the admin multi-agent gateway's scaling ceiling (20+ businesses) because any PA could coordinate with any other PA regardless of where it runs.

### When to Build

Start Tezit work when:
1. Phase 1 teams are running for 4+ weeks
2. Real usage patterns show where the email bridge falls short
3. You have concrete examples of what cross-PA communication needs to carry (context icebergs? just text? structured data?)

Don't build Tezit on assumptions. Build it on observed pain.

---

## 22. Success Criteria

Phase 1 is done when all of the following are true:

1. Admin has a working multi-agent gateway with personal PA + per-team sub-PAs
2. Admin PA can aggregate cross-team briefings via `sessions_send`
3. Every team member has their own PA with personalized IDENTITY.md
4. PAs communicate with humans via Telegram (and optionally Slack for team channels)
5. PAs communicate with each other via email bridge (or shared Slack channel)
6. Twenty CRM is accessible to all PAs via skill
7. Claude Max proxy running per-team for coding tasks
8. Kimi K2.5 handling 80-90% of PA traffic
9. A new team member can be onboarded in < 30 minutes via provisioning script
10. A new team/business can be initiated via `/team new` in < 1 hour (including manual steps)
11. OCSAS L2 passes on all team member PAs, L3 on admin PAs
12. No custom application code is running in production — configuration and existing tools only
13. Team members report their PA is useful (qualitative — are they actually using it daily?)

---

## 23. Research Sources

### Core Projects
- [OpenClaw](https://github.com/openclaw/openclaw) — The AI agent runtime
- [Claworc](https://github.com/gluk-w/claworc) — Multi-instance orchestrator
- [openclaw-multitenant](https://github.com/jomafilms/openclaw-multitenant) — Multi-tenant platform layer (reference, not used directly)
- [Antfarm](https://github.com/snarktank/antfarm) — Agent team workflows
- [Twenty CRM](https://github.com/twentyhq/twenty) — Open-source CRM

### Security
- [OCSAS](https://github.com/gensecaihq/ocsas) — OpenClaw Security Assurance Standard
- [Clawdex](https://clawdex.koi.security/) — Skill security scanner by Koi Security
- [CVE-2026-25253](https://nvd.nist.gov/vuln/detail/CVE-2026-25253) — 1-click RCE vulnerability (patched in v2026.1.29)
- [ClawHavoc](https://www.koi.ai/blog/clawhavoc-341-malicious-clawedbot-skills-found-by-the-bot-they-were-targeting) — 341 malicious skills campaign
- [VirusTotal OpenClaw Blog](https://blog.virustotal.com/2026/02/from-automation-to-infection-how.html) — Skill weaponization analysis
- [OpenClaw Security Docs](https://docs.openclaw.ai/gateway/security) — Official security documentation

### Skills & Integrations
- [Twenty CRM Skill](https://github.com/openclaw/skills/blob/main/skills/jhumanj/twenty-crm/SKILL.md) — CRM OpenClaw integration
- [model-router Skill](https://github.com/openclaw/skills/blob/main/skills/digitaladaption/model-router/SKILL.md) — Task-based model routing
- [gog Skill](https://skills.sh/openclaw/openclaw/gog) — Google Workspace integration
- [Awesome OpenClaw Skills](https://github.com/VoltAgent/awesome-openclaw-skills) — Curated skill directory (3,002 skills)

### Deployment & Infrastructure
- [DigitalOcean OpenClaw 1-Click](https://marketplace.digitalocean.com/apps/openclaw) — Marketplace deployment
- [DigitalOcean App Platform](https://www.digitalocean.com/blog/openclaw-digitalocean-app-platform) — Multi-agent fleet
- [OpenClaw Docker Docs](https://docs.openclaw.ai/install/docker) — Container deployment
- [claude-max-api-proxy](https://github.com/atalovesyou/claude-max-api-proxy) — Max subscription proxy (verified: 74 stars, MIT, npm v1.0.0)
- [lynkr](https://www.npmjs.com/package/lynkr) — Multi-backend Claude proxy (v7.2.5, Apache-2.0, more mature alternative)
- [OpenClaw Multi-Agent Routing](https://docs.openclaw.ai/concepts/multi-agent) — Official multi-agent documentation

### Related Tools (Evaluated, Not Used)
- [ClawDeck](https://github.com/clawdeckio/clawdeck) — Kanban dashboard for agents
- [ClawControl](https://clawcontrol.dev/) — Mission control (SaaS, $19-59/mo)
- [RelayPlane](https://relayplane.com/) — Cost optimization proxy
- [Claw EA](https://clawea.com/channels) — Enterprise governance
- [AgentMail](https://www.agentmail.to/) — Agent email infrastructure
- [ClawMail](https://clawmail.dev/) — Agent email (beta)
