# MyPA Platform — Project State

> Machine-readable project context for CI validation and session continuity.
> This file is the canonical source of truth for deployment state, architecture
> decisions, and workflow definitions. Update it whenever infrastructure changes.

---

## Deployment State

### Infrastructure (Multi-Droplet Fleet)

| Droplet | Spec | Purpose | PAs |
|---------|------|---------|-----|
| admin-pa-dedicated | 4vCPU/8GB | Admin PA + CRM | 1 |
| fleet-alpha | 4vCPU/8GB | Team Alpha (7 PAs + CRM) | 7 |
| fleet-beta | 4vCPU/8GB | Team Beta (3 PAs + CRM) | 3 |
| fleet-delta | 4vCPU/8GB | Team Delta (3 PAs + CRM) | 3 |
| fleet-gamma | 4vCPU/8GB | Team Gamma (3 PAs + CRM) | 3 |
| tez-relay | 1vCPU/1GB | Tezit Protocol relay | 0 |

**Total:** 6 droplets, 17 PAs + 1 Admin PA = 18 active PAs

All fleet droplets run Ubuntu 24.04 LTS, Docker, Caddy (auto-TLS), and OpenClaw v2026.2.22-2 (Debian bookworm base image).

### Per-Droplet Services

Each fleet droplet runs:
- **PA containers** — `--network host`, bind-mounted config at `/opt/mypa/agents/<name>/data`
- **Twenty CRM** — PostgreSQL 16, server, worker, Redis on port 3100
- **Caddy** — Reverse proxy, auto-TLS, `<name>.team.example.com` routes
- **tez-mcp** — Tezit MCP server on port 8100, localhost only

### OpenClaw Container Standard

```bash
docker run -d --name pa-<name> --hostname <name> --network host \
  --restart unless-stopped \
  -e OPENCLAW_PREFER_PNPM=1 -e NODE_ENV=production \
  -v /opt/mypa/agents/pa-<name>/data:/home/node/.openclaw \
  ghcr.io/openclaw/openclaw:2026.2.22 node openclaw.mjs gateway
```

### Container Recreation Checklist

After every container recreate (image upgrade, etc.):
1. `apt-get install chromium` — browser support (Debian)
2. `npm install -g mcporter` — Tezit MCP client
3. Write `/home/node/.mcporter/mcporter.json` — MCP config
4. Verify gateway responds on assigned port

Items 1-3 are in the container layer and will be lost on recreation.

### DNS

| Record Pattern | Type | Purpose |
|----------------|------|---------|
| `<name>.team.example.com` | A | PA gateway access |
| `crm-<team>.team.example.com` | A | CRM web access |
| `relay.team.example.com` | A | Tezit relay |
| `team.example.com` | ALIAS | Landing page (Vercel) |

### Secrets Management

| Secret | Location | Notes |
|--------|----------|-------|
| Gateway tokens | Per-PA in `openclaw.json` | Token auth mode |
| Claude API key | Shared across fleet | In `openclaw.json` per container |
| Brave Search API | Per-PA in `openclaw.json` | Shared key |
| OpenAI API key | Per-PA environment | For STT (Whisper) + embeddings |
| CRM app secrets | `/opt/twenty/.env` per droplet | PostgreSQL + app secrets |
| Git credentials | `/etc/git-credentials` (Admin-PA only) | System-level, root-owned |
| Tez auth secrets | `/tmp/tez-secrets.env` per droplet | Per-droplet relay auth |

---

## Architecture

### Multi-Droplet Fleet Model

```
Admin-PA (dedicated droplet)
    ├── Admin PA container (full fleet management)
    ├── Admin CRM (hub — aggregates all teams)
    └── tez-mcp (encrypted comms)

Fleet Alpha (shared droplet)
    ├── 7 PA containers (individual + team coordinator)
    ├── Team CRM (spoke — syncs up to hub)
    └── tez-mcp

Fleet Beta / Delta / Gamma (shared droplets, same pattern)
    ├── 3 PA containers each
    ├── Team CRM each
    └── tez-mcp each

Tez Relay (dedicated droplet)
    └── Relay server (key authority, federation)
```

### CRM — Hub-and-Spoke Model

```
Team Alpha CRM ──(sync up)──→ Admin CRM (admin only)
Team Beta CRM  ──(sync up)──→ Admin CRM
Team Gamma CRM ──(no sync)──→ (isolated)
                                    │
                             Admin's Personal PA
                             reads from here
```

**Rules:**
1. Data flows ONE WAY: team CRMs → admin CRM. Never the reverse.
2. Admin CRM is the admin's private aggregate — no one else has access.
3. Each team CRM is fully isolated from other team CRMs.
4. CRM sync is a per-team toggle (default: DISABLED).

### Container Naming Convention

| Pattern | Purpose |
|---------|---------|
| `pa-<name>` | PA containers (bind to host port via `--network host`) |
| `twenty-<team>` | CRM containers per team |
| `tez-mcp` | Tezit MCP server (one per droplet) |

### Tezit Protocol

Encrypt-at-source PA-to-PA communication:
- **tez-relay** — Key authority, federation, encrypted key storage
- **tez-mcp** — Per-droplet MCP server (Python/FastAPI, port 8100)
- **mcporter** — CLI bridge in each PA container
- **tez skill** — Teaches PA when/how to use 9 tez tools

Architecture: content encrypted before leaving sender, keys held on relay. Destroying key = all copies become unreadable (worldwide delete).

### Security Model

| Layer | Mechanism |
|-------|-----------|
| Network | UFW deny-all + SSH/HTTP/HTTPS, Tailscale mesh, `--network host` |
| Host | fail2ban, least-privilege sudoers, root SSH disabled |
| Reverse Proxy | Caddy header stripping, auto-TLS, no public container ports |
| Gateway | Token auth per PA, device pairing for web/mobile |
| Container | Docker isolation, bind-mounted config only |
| CRM | Multi-workspace isolation, admin-only workspace creation |
| PA | Full-capability paradigm, Docker = security boundary |
| Identity | SOUL.md (admin-controlled security), IDENTITY.md (user personality) |
| Git | System-level credentials (root-owned), org blocking via URL rewrite |
| Comms | Tezit encrypt-at-source, key destruction = content evaporation |

### Auth Strategy

| Surface | Auth Mechanism |
|---------|---------------|
| PA ↔ Human (web) | Gateway token + device pairing |
| PA ↔ Human (mobile) | iOS app + gateway token |
| PA ↔ Human (Telegram) | Bot token + pairing code |
| PA ↔ CRM | Twenty API key (per-workspace) |
| PA ↔ Models | Anthropic API key (Claude Opus 4.6) |
| PA ↔ Google | Service account + delegation / OAuth |
| PA ↔ PA | Tezit Protocol (encrypted, key-mediated) |
| Admin ↔ Infra | SSH key + Tailscale mesh |

### Full-Capability PA Paradigm

PAs are full digital workers. All tools enabled except `gateway`:
- exec, process, browser, apply_patch: ALL ENABLED
- Docker container IS the security boundary, not tool deny lists
- SOUL.md = behavioral guidance, not capability restriction
- RAG memory enabled (local provider, memory + sessions)

---

## Fleet Features

| Feature | Status | Notes |
|---------|--------|-------|
| OpenClaw v2026.2.22-2 | All 18 PAs | Debian bookworm base |
| RAG memory | All 18 PAs | Local provider, session memory |
| Whisper STT | All 18 PAs | OpenAI API key required |
| Chromium browser | All 18 PAs | In container layer (lost on recreate) |
| Tezit Protocol | All 18 PAs + relay | 9 tools per PA, encrypted comms |
| Telegram | Select PAs | Bot per PA, pairing-based auth |
| iOS app | Available | SwiftUI, multi-gateway, TestFlight-ready |
| CRM (Twenty) | 5 instances | Hub (admin) + 4 spokes (teams) |
| Google Workspace | Admin PA | Service account, gog CLI |
| Git access | Admin PA only | System-level credentials, org blocking |

---

## File Inventory

### Scripts

| Script | Purpose |
|--------|---------|
| scripts/bootstrap-droplet.sh | Infrastructure setup |
| scripts/provision-pa.sh | PA provisioning (pactl + templates) |
| scripts/pactl.sh | PA container management |
| scripts/backup-pas.sh | PA + CRM backup (daily cron) |
| scripts/healthcheck.sh | Proactive monitoring |
| scripts/rotate-gateway-token.sh | Token rotation |
| scripts/onboard-team.sh | Team onboarding workflow |

### Templates

| Template | Purpose |
|----------|---------|
| templates/pa-default/openclaw.json | Golden PA config |
| templates/pa-default/SOUL.md | Security boundaries (admin-controlled) |
| templates/pa-default/IDENTITY.md | PA personality (user-customizable) |
| templates/pa-admin/openclaw.json | Admin multi-agent config |
| templates/caddy/pa-gateway.caddy.tmpl | Caddy routing template |

### Services

| Service | Purpose |
|---------|---------|
| services/provisioning-api/ | HTTP API wrapping pactl for provisioning |
| services/tez-relay/ | Tezit Protocol relay server |
| services/tez-mcp/ | Tezit MCP server (per-droplet) |

### Skills

| Skill | Purpose |
|-------|---------|
| skills/team-router/SKILL.md | Team routing, provisioning |
| skills/team-comms/SKILL.md | Communication routing |
| skills/tez/SKILL.md | Tezit Protocol usage |

---

## Version History

| Date | Change |
|------|--------|
| 2026-02-14 | Phase 0-5: Bootstrap, CRM, templates, provisioning |
| 2026-02-15 | Full-capability PA paradigm, iOS app connected |
| 2026-02-16 | Security hardening, 1Password, backups, provisioning API |
| 2026-02-17 | Fleet Alpha live (7 PAs), auth gap discovered and fixed |
| 2026-02-19 | Multi-droplet architecture, 4 team fleets deployed (18 PAs) |
| 2026-02-20 | Telegram pairing flow established, web UI fixes |
| 2026-02-22 | Tezit Protocol deployed (relay + 2 fleets), first tez sent |
| 2026-02-23 | Fleet upgrade to v2026.2.22-2, RAG memory, Tezit fleet-wide |
| 2026-02-24 | Compute scaling (4vCPU), iOS app built, Telegram expansion |
