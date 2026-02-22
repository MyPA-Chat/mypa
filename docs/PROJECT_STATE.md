# MyPA Platform — Project State

> Machine-readable project context for CI validation and session continuity.
> This file is the canonical source of truth for deployment state, architecture
> decisions, and workflow definitions. Update it whenever infrastructure changes.

---

## Deployment State

### Infrastructure

| Component | Status | Location | Access |
|-----------|--------|----------|--------|
| Droplet (mypa-fleet) | RUNNING | DO nyc1, ID 100000001, 4vCPU/8GB/160GB | SSH: mypa@203.0.113.20 |
| Ubuntu | 24.04 LTS | — | — |
| Tailscale | Authenticated | Mesh VPN | Admin access |
| Docker | 28.2.2 | — | mypa in docker group |
| Node.js | 22.22.0 | — | Inside PA container |
| fail2ban | Active | — | — |
| UFW | Active (SSH, HTTP, HTTPS) | — | — |
| DOCKER-USER iptables | Active | Persistent via systemd | Blocks public access to 3001/3002/6081 |
| Swap | 2GB | /swapfile | Active, persistent via fstab |
| DO Monitoring | Disk >80%, CPU >90% 5min, Memory >85% | — | Alerts to admin email |

### Services

| Service | Status | Binding | Port | Notes |
|---------|--------|---------|------|-------|
| Twenty CRM (server) | RUNNING (healthy) | 0.0.0.0 | 3002→3000 | Multi-workspace enabled |
| Twenty CRM (PostgreSQL 16) | RUNNING (healthy) | — | 5432 | User: twenty, DB: twenty |
| Twenty CRM (Redis) | RUNNING (healthy) | — | 6379 | — |
| Caddy reverse proxy | RUNNING | 0.0.0.0 | 80, 443 | TLS auto, header sanitization active |
| Admin's PA (mypa-admin-pa) | RUNNING | 0.0.0.0 | 3001→3000 (gw), 6081 (VNC) | Full-capability, token auth |
| pactl | READY | scripts/pactl.sh | N/A | PA lifecycle via Docker |
| Provisioning API | READY | 127.0.0.1 | 9100 | Bearer auth, wraps pactl for Admin-PA |
| Backup cron | Active | 2 AM daily | N/A | PA volumes + CRM pg_dump, 14-day retention |
| PA supervisor | Active | Every 2 min | N/A | Health monitoring |

### DNS (Vercel — admin.example.com)

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| pa.admin.example.com | A | 203.0.113.20 | PA gateway access |
| open.admin.example.com | A | 203.0.113.20 | VNC access |
| MX | MX | smtp.google.com | Google Workspace email |
| google._domainkey | TXT | DKIM | Email authentication |

### DNS (Vercel — team.example.com)

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| team.example.com | ALIAS | Vercel | Landing page |
| *.team.example.com | ALIAS | Vercel | Vercel projects |

### Secrets Management

| Secret | Location | Management |
|--------|----------|------------|
| Gateway token | 1Password ("MyPA Gateway Token - admin-pa", vault: Private) | rotate-gateway-token.sh |
| Google OAuth | 1Password ("Google OAuth Client Secret - MyPA", vault: Private) | Deployed to container |
| Google PA password | 1Password (vault: PA) | Injected via op CLI |
| Twenty CRM app secret | /opt/twenty/.env (APP_SECRET) | On droplet |
| Twenty CRM DB password | /opt/twenty/.env (PG_DATABASE_PASSWORD) | On droplet |
| Brave Search API key | In PA container config | Configured |
| OpenAI API key | In PA auth-profiles.json | For memory-core embeddings |

---

## Architecture Decisions

### Admin CRM — Hub-and-Spoke Model

The platform operator's personal workspace in Twenty CRM is named **the parent company CRM**. It serves as the
private aggregate view across ALL teams.

```
Team Alpha Workspace ──(sync up)──→ Parent Company CRM (admin only)
Team Beta Workspace  ──(sync up)──→ Parent Company CRM
Team Gamma Workspace ──(no sync)──→ (isolated, sync disabled)
                                          │
                                   Admin's Personal PA
                                   reads from here
```

**Rules:**
1. Data flows ONE WAY: team workspaces → parent company CRM. Never the reverse.
2. Nobody else is invited to the parent company CRM — it is the admin's private aggregate.
3. Each team workspace is fully isolated from other team workspaces.
4. CRM sync is a **per-team toggle** — enabled via `--crm-sync` flag during provisioning.
   Default is DISABLED (team CRM data stays local).
5. Team leaders are set as the first admin of their team's workspace.

### Container Naming Convention

| Prefix | Owner | Purpose |
|--------|-------|---------|
| `mypa-` | pactl (primary PA management) | PA containers managed by scripts |
| `twenty-` | Twenty CRM docker-compose | CRM service containers |

### Agent Config Format

The ONLY valid multi-agent config format is `agents.list[]` + top-level `bindings[]`.
Legacy object-keyed agent format (`agents.admin: {...}`) is explicitly rejected by the
schema contract check in `validate-week1.sh`.

### Google Workspace — Two-Workspace Model

| Workspace | Domain | Users | Auth Model | PA Scopes |
|-----------|--------|-------|------------|-----------|
| Personal | admin.example.com | The admin + family | Service account + delegation | Full Google suite |
| Platform | team.example.com | All other PAs | Per-PA OAuth (admin-provisioned) | Gmail + Calendar only |

- Separate Google Workspace subscriptions — no cross-access between workspaces
- Platform OAuth client: "internal" app (auto-approved, no Google review)
- PA accounts in "PA Accounts" OU with 2FA disabled (service identities, not humans)
- Admin completes OAuth consent during provisioning — users never touch Google
- Provisioning time per PA: ~20-25 min (VNC OAuth is the bottleneck)

### Agentic RAG (Memory)

All PAs use OpenClaw's memory-core plugin for agentic RAG:
- `plugins.slots.memory: "memory-core"` (golden template default)
- memory-core uses SQLite + sqlite-vec, OpenAI text-embedding-3-small
- `agents.defaults.memorySearch.extraPaths` — team-shared docs mount point
- Cron job: RAG index refresh every 6 hours

### PA Gateway Exposure (Tailscale + Caddy)

PAs are accessed via the OpenClaw iOS app and webchat.
Gateway access through Tailscale identity or token auth:

```
iPhone (OpenClaw iOS) → wss://pa.admin.example.com/
  → Caddy (TLS + header stripping) → PA container gateway port
```

- Auth: token-based per PA (`gateway.auth.mode: "token"`, `allowTailscale: true`)
- Caddy strips Tailscale identity headers from public internet requests
- Gateway token managed via 1Password + rotate-gateway-token.sh
- Template: `templates/caddy/pa-gateway.caddy.tmpl`

### Security Model

| Layer | Mechanism |
|-------|-----------|
| Network | UFW deny-all + SSH/HTTP/HTTPS, DOCKER-USER iptables (conntrack), Tailscale mesh |
| Host | fail2ban, least-privilege sudoers, root SSH disabled, 2GB swap |
| Reverse Proxy | Caddy header stripping (Tailscale-User-* headers), auto-TLS |
| Gateway | Token auth + Tailscale identity, per-user allowlist, narrow trustedProxies |
| Container | Specific --cap-add (not --privileged), Docker bridge isolation |
| CRM | Multi-workspace isolation, admin-only workspace creation |
| PA | Full-capability paradigm, Docker = security boundary, gateway tool denied |
| Identity | SOUL.md (admin-controlled security), IDENTITY.md (user personality) |
| Secrets | 1Password CLI for rotation/injection, never in git or conversation |

### Auth Strategy

| Surface | Auth Mechanism | Notes |
|---------|---------------|-------|
| PA ↔ Human (primary) | OpenClaw iOS app + gateway token | Direct WebSocket via Caddy |
| PA ↔ Human (secondary) | Telegram bot + pairing code | Optional, not yet configured |
| PA ↔ CRM | Twenty API key (per-workspace) | Workspace-scoped, team-isolated |
| PA ↔ Models | Native Anthropic auth | claude setup-token (1yr), Claude Sonnet 4.6 (Opus 4.6 for planning) |
| PA ↔ Google (admin/family) | Service account + delegation | admin.example.com workspace, full Google suite |
| PA ↔ Google (platform) | Per-PA OAuth (admin-provisioned) | team.example.com workspace, Gmail + Calendar only |
| PA ↔ Host (provisioning) | Provisioning API + bearer token | localhost:9100, wraps pactl, no SSH |
| Admin ↔ Infra | SSH key + Tailscale mesh | No passwords on droplet |
| Admin ↔ Twenty | Server admin account | Created during platform bootstrap |

### Full-Capability PA Paradigm

PAs are full digital workers. All tools enabled except `gateway`:
- exec, process, browser, apply_patch: ALL ENABLED
- Docker container IS the security boundary, not tool deny lists
- SOUL.md = behavioral guidance, not capability restriction
- Antfarm v0.5.1 installed for coding workflows (feature-dev, security-audit, bug-fix)
- 1Password CLI installed for credential access

---

## Provisioning Workflow

### Platform Bootstrap (one-time, already done)

1. Droplet created and hardened (Phase 0) ✓
2. Docker, Tailscale, monitoring installed ✓
3. Twenty CRM deployed with multi-workspace ✓
4. Caddy reverse proxy with TLS ✓
5. DNS configured (admin.example.com via Vercel) ✓
6. pactl operational for PA lifecycle management ✓
7. Parent company CRM server admin created ✓
8. Security hardening sprint complete ✓
9. Admin's PA running with full capability ✓
10. iOS app + webchat connected ✓
11. Antfarm installed in PA container ✓
12. Backup cron + swap configured ✓

### Team Provisioning (PA-as-Provisioner model)

Admin-PA (admin PA) provisions team members autonomously. The admin's input: one instruction.
Access to the host is via a least-privilege Provisioning API (localhost:9100), not SSH.

```
Admin: "Admin-PA, onboard Alice to the parent company"
    │
    ▼
Admin-PA (admin PA, calls Provisioning API + Google Admin SDK):
    ├─ Creates alice@company.example.com (Google Admin SDK)
    ├─ POST /pa/create  {name: "alice-pa", member: "Alice", team: "parent-company"}
    ├─ POST /pa/config  {name: "alice-pa", template: "pa-default"}
    ├─ Injects Claude auth token
    ├─ Does OAuth consent for alice@company.example.com (own browser)
    ├─ POST /caddy/add-route  {name: "alice-pa", domain: "...", gateway_port: ...}
    ├─ Creates CRM workspace API key (if team has CRM)
    ├─ GET  /pa/status/alice-pa  (verify healthy)
    └─ Sends Alice gateway token + instructions
```

**Per-team setup (one-time):**
- Google Workspace on team's domain (Admin-PA as admin)
- Twenty CRM workspace (if team needs CRM, opt-in via --crm-sync)
- OAuth client (internal, shared across team PAs)

**Shared fleet droplet:** All teams share one droplet. Scale vertically (8GB → 16GB → 32GB).
Split to separate droplet only when fleet hits ~80% RAM or compliance requires isolation.

### Team Member Provisioning

Individual PA provisioning follows the same API-driven flow above. Admin-PA handles:

1. Container creation (`POST /pa/create`)
2. Template application (`POST /pa/config`)
3. Auth injection (Claude API key or OAuth token)
4. Google Workspace account setup (if team has GWS)
5. Caddy route + DNS registration
6. CRM workspace key (if applicable)
7. Health verification (`GET /pa/status/:name`)
8. Welcome message with gateway token

See `scripts/provision-pa.sh` for the scripted version, or `workflows/pa-provision/workflow.yml`
for the Antfarm-automated version.

---

## Remaining Interactive Steps

These require browser/interactive auth and cannot be automated:

1. ~~claude auth login inside PA container~~ ✓ DONE (setup-token, 1yr)
2. ~~Parent company CRM admin created~~ ✓ DONE
3. ~~Brave Search API key~~ ✓ DONE
4. ~~iOS app connected~~ ✓ DONE
5. Google Workspace PA account creation (Admin Console) ✓ DONE (admin.example.com)
6. gog OAuth per PA (interactive browser flow) — **IN PROGRESS** (credential deployed, consent flow pending)
7. Telegram bot creation for admin agents only (@BotFather) — NOT YET STARTED
8. Set up team.example.com Google Workspace (platform accounts) — NOT YET STARTED
9. Set up per-company Google Workspaces (company.example.com, etc.) — NOT YET STARTED
10. Provisioning API on host (localhost:9100, bearer auth) — **IN PROGRESS**
11. Provisioning skill for Admin-PA (SKILL.md) — NOT YET STARTED
12. Google Admin SDK access for Admin-PA — NOT YET STARTED

---

## File Inventory

### Scripts (operational)

| Script | Purpose | CI Validated |
|--------|---------|-------------|
| scripts/bootstrap-droplet.sh | Phase 0 infrastructure setup | bash -n ✓ |
| scripts/provision-pa.sh | PA provisioning (pactl + templates) | bash -n ✓, dry-run ✓ |
| scripts/pactl.sh | Primary PA container management (--gateway-token, --cap-add) | bash -n ✓ |
| scripts/backup-pas.sh | PA + CRM backup with retention (daily 2 AM cron) | bash -n ✓ |
| scripts/healthcheck.sh | Proactive monitoring (cron-friendly) | bash -n ✓ |
| scripts/install-antfarm.sh | Antfarm v0.5.1 bootstrap | bash -n ✓ |
| scripts/rotate-gateway-token.sh | 1Password-managed gateway token rotation | bash -n ✓ |
| scripts/onboard-team.sh | Guided team onboarding workflow | bash -n ✓ |
| scripts/validate-week1.sh | Pre-deployment validation gates | bash -n ✓ |
| scripts/validate-antfarm-workflow.sh | Antfarm workflow contract check | bash -n ✓ |
| scripts/setup-github-gates.sh | GitHub branch protection | bash -n ✓ |

### Templates

| Template | Purpose |
|----------|---------|
| templates/pa-default/openclaw.json | Golden PA config (token auth, full-capability) |
| templates/pa-default/SOUL.md | Security boundaries (admin-controlled) |
| templates/pa-default/IDENTITY.md | PA personality (user-customizable) |
| templates/pa-admin/openclaw.json | Admin multi-agent gateway (token auth) |
| templates/pa-admin/SOUL.md | Admin cross-team boundaries |
| templates/caddy/pa-gateway.caddy.tmpl | Caddy PA routing (header stripping) |
| templates/soul-variants/SOUL-*.md | Role-specific variants (team-lead, IC, sales) |
| templates/team-sync-config.json | CRM sync config template |

### Services

| Service | Purpose |
|---------|---------|
| services/provisioning-api/server.js | Least-privilege HTTP API wrapping pactl for PA provisioning |
| services/provisioning-api/install.sh | Deploy provisioning API to host |
| services/provisioning-api/provisioning-api.service | Systemd unit (hardened: NoNewPrivileges, ProtectSystem) |

### Skills

| Skill | Purpose |
|-------|---------|
| skills/team-router/SKILL.md | Team routing, provisioning commands (admin only) |
| skills/team-comms/SKILL.md | Communication routing, PA-to-PA conventions |

### Workflows

| Workflow | Purpose |
|----------|---------|
| workflows/pa-provision/workflow.yml | Antfarm PA provisioning workflow |

### CI/CD

| Workflow | Purpose |
|----------|---------|
| .github/workflows/predeployment-gate.yml | Shell syntax, template contracts, dry-run |

---

## Version History

| Date | Change | By |
|------|--------|---|
| 2026-02-14 | Phase 0 complete: droplet bootstrapped, hardened, monitoring | Claude + Admin |
| 2026-02-14 | Phase 1 deployed: Twenty CRM, shared services | Claude + Admin |
| 2026-02-14 | Tailscale authenticated, droplet on tailnet | Admin |
| 2026-02-14 | Security audit fixes: least-privilege sudo, idempotency | Claude + Admin |
| 2026-02-14 | Twenty CRM multi-workspace enabled | Claude |
| 2026-02-14 | DNS configured (admin.example.com + team.example.com) | Claude |
| 2026-02-14 | Caddy reverse proxy with auto-TLS | Claude |
| 2026-02-14 | Parent company CRM architecture defined (hub-and-spoke) | Admin |
| 2026-02-14 | Claworc removed, pactl promoted, native Anthropic auth | Claude + Admin |
| 2026-02-14 | Golden templates: memory-core, token auth, mDNS off | Claude |
| 2026-02-14 | Team onboarding: onboard-team.sh, Caddy gateway | Claude + Admin |
| 2026-02-15 | Full-capability PA paradigm: SOUL rewrite, all tools enabled | Claude + Admin |
| 2026-02-15 | iOS app connected via Tailscale identity bypass patches | Claude + Admin |
| 2026-02-16 | Security hardening sprint: iptables, header stripping, token rotation | Claude + Admin |
| 2026-02-16 | 1Password integration: secret rotation, credential injection | Claude + Admin |
| 2026-02-16 | Antfarm v0.5.1 + op CLI installed in PA container | Claude |
| 2026-02-16 | Backup cron (daily 2 AM) + 2GB swap deployed | Claude |
| 2026-02-16 | Google OAuth credential deployed, consent flow pending | Claude |
| 2026-02-16 | Provisioning API built (replaces SSH key for PA-as-provisioner) | Claude + Admin |
| 2026-02-16 | Security review pass 2: 6 additional fixes (bootstrap iptables, backup encryption, antfarm fail-closed) | Claude |
