# MyPA

> Give every team member an AI Personal Assistant — with hard security boundaries, real email, and a personality they'll actually trust.

**[Read the full build story: how we designed and built this from scratch](docs/BUILD_LOG.md)**

---

## What This Is

MyPA gives each team member their own OpenClaw-powered Personal AI Assistant (PA) running in an isolated Docker container. Each PA has email (Gmail), calendar, CRM access, web search, and coding assistance — with security boundaries the user cannot override. The admin controls what PAs can do. The user controls how the PA behaves within those boundaries.

The platform is built entirely from existing validated tools — no custom application code. Zero proprietary dependencies. If we stopped maintaining it tomorrow, you could fork it and run it yourself.

```
pactl (PA management) → OpenClaw containers (one per PA)
                      → Google Workspace (email, calendar, drive)
                      → Twenty CRM (self-hosted, open source)
                      → Claude Sonnet 4.6 (native Anthropic auth)
                      → OpenClaw iOS app (primary channel)
                      → Provisioning API (PA-as-Provisioner model)
```

---

## The Build Story

We built this in public, capturing every decision, dead-end, and hard-won lesson. The [Build Log](docs/BUILD_LOG.md) is the full narrative — structured as a blog series so other teams can replicate it without making the same mistakes.

**The big themes:**

**We audited our control plane, found CVEs, fixed them ourselves — then removed it anyway.**
Claworc was the planned orchestrator for OpenClaw containers. We reverse-engineered its undocumented API, wrote a full security audit pipeline (govulncheck, trivy, grype), found the frontend wouldn't compile at any recent commit, forked it, fixed the TypeScript errors and vulnerable dependencies, got a clean audit result — then spent two more days hitting Docker cgroup incompatibilities, container restart loops, and SSH hardening conflicts. At the end of it, we replaced the whole thing with 460 lines of auditable bash (`pactl.sh`). The lesson: sometimes the right architecture is the boring one.

**The auth simplification we didn't plan for.**
The original design included a Claude Max proxy service — a separate container bridging the PA's OpenAI-compatible API calls to Claude. During the first PA deployment, we discovered OpenClaw already speaks to Anthropic natively. We eliminated the proxy, the systemd unit, and the host-to-container networking complexity. The platform got simpler by accident.

**A backup script that would have deleted your backups.**
During the deployment plan audit, we found `find /opt/backups -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \;` — without `-mindepth 1`, this matches the backup directory itself once it's 14 days old. One command, total data loss. Fixed with one flag.

**Every "security best practice" document we found had at least one dangerous recommendation.**
Including our own. We originally wrote "disable 2FA on PA Google accounts and restrict by IP range instead." Both wrong: Google sees the droplet's public egress IP (not Tailscale's), and disabling 2FA is plainly worse. Caught it in a bootstrap audit.

**Docker bypasses your firewall.** Always. UFW rules don't apply to Docker-managed ports. We documented this (and the iptables DOCKER-USER chain workaround), because almost no setup guide mentions it.

**[Read the full story](docs/BUILD_LOG.md)**

---

## What Each PA Gets

- OpenClaw iOS app (primary channel) + optional Telegram
- Gmail + Calendar + Drive + Contacts (via gog skill)
- CRM access (via Twenty CRM — self-hosted, API-first)
- Web search (via Brave)
- Claude Sonnet 4.6 via native Anthropic auth (1-year OAuth token)
- Morning briefings, inbox monitoring, afternoon priorities (cron)
- Full-capability tools inside Docker boundary: exec, process, browser, apply_patch
- SOUL.md security boundaries (admin-controlled, user cannot override)
- IDENTITY.md personal identity (user-customizable within boundaries)
- Agentic RAG via memory-lancedb (6h cron index refresh)

---

## Architecture Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Container management | `pactl.sh` (bash) | Replaced Claworc after audit. 460 lines, zero binary trust required. |
| Model | Claude Sonnet 4.6 | Native Anthropic auth via `claude setup-token` (1-year token) |
| Primary channel | OpenClaw iOS app | Own TestFlight, no third-party approval, clean gateway client |
| Email/Calendar | Google Workspace + gog skill | One OAuth for everything, real domain, deliverability |
| CRM | Twenty (self-hosted) | Open source, API-first, data stays on your infra |
| Security model | Full-capability + Docker boundary | exec/process/browser all enabled; container = security boundary |
| PA provisioning | PA-as-Provisioner (Provisioning API) | Admin PA calls localhost:9100, no SSH key needed |
| Memory/RAG | memory-lancedb (built-in plugin) | No third-party RAG service, SQLite + sqlite-vec |
| PA identity | SOUL.md (hard) + IDENTITY.md (soft) | Admin-controlled limits + user-customizable personality |
| Bootstrap auth | Shared Anthropic API key → Claude Max migration | PAs work day 1, members upgrade on their schedule |

---

## LLM Auth: Two-Stage Onboarding

**Stage 1 — Bootstrap (admin does this, zero user action):**
```bash
docker exec <pa-name> bash -c \
  'openclaw onboard --non-interactive --auth-choice token \
   --token-provider anthropic --token "sk-ant-REDACTED"'
```
PA works immediately. Member can start using it within minutes of provisioning.

**Stage 2 — Migrate to Claude Max (member does when ready, ~2 min):**
```bash
# Admin runs, gets a one-time URL, sends to member:
docker exec <pa-name> bash -c 'claude auth login'
# Member visits URL, logs into claude.ai, done.
# Then remove shared key:
docker exec <pa-name> bash -c 'openclaw config unset anthropic_api_key'
```

---

## Quick Start

1. Read [docs/BUILD_LOG.md](docs/BUILD_LOG.md) — the full journey and why things are designed as they are
2. Read [DEPLOYMENT_PLAN.md](DEPLOYMENT_PLAN.md) — the full deployment plan
3. Check [docs/PROJECT_STATE.md](docs/PROJECT_STATE.md) — current fleet state
4. Bootstrap a droplet: `bash scripts/bootstrap-droplet.sh`
5. Onboard a team: `bash scripts/onboard-team.sh`

---

## Repository Structure

```
mypa/
├── DEPLOYMENT_PLAN.md                    # Full deployment plan (start here)
├── templates/
│   ├── pa-default/                       # Team member PA config + identity
│   │   ├── openclaw.json                 # Golden PA config (token auth, full-capability)
│   │   ├── SOUL.md                       # Security boundaries (admin-controlled)
│   │   ├── IDENTITY.md                   # PA personality (user-customizable)
│   │   └── config/                       # Email rules, CRM config, data classification
│   ├── pa-admin/                         # Admin multi-agent gateway config
│   └── soul-variants/                    # Role-specific SOUL variants (lead, IC, sales)
├── scripts/
│   ├── pactl.sh                          # PA container management (create/config/start/stop)
│   ├── provision-pa.sh                   # PA provisioning orchestration
│   ├── bootstrap-droplet.sh              # Phase 0 infrastructure setup (idempotent)
│   ├── onboard-team.sh                   # Guided 4-phase team onboarding
│   ├── backup-pas.sh                     # PA + CRM backup with 14-day retention
│   └── healthcheck.sh                    # Proactive monitoring (cron-friendly)
├── services/
│   └── provisioning-api/                 # Least-privilege HTTP API wrapping pactl
├── skills/
│   ├── team-router/                      # Team routing + provisioning commands
│   └── team-comms/                       # PA-to-PA communication norms
├── workflows/
│   └── pa-provision/workflow.yml         # Antfarm provisioning workflow
└── docs/
    ├── BUILD_LOG.md                      # Full build history — read this
    ├── PROJECT_STATE.md                  # Current deployment state
    ├── ONBOARDING_RUNBOOK.md             # Step-by-step onboarding guide
    └── FORWARD_PLAN.md                   # Roadmap: update distribution, Tezit protocol
```

---

## Cost

~$48/mo per 8GB DigitalOcean droplet (handles 10-15 PA containers) + $7/user/mo Google Workspace. Model cost: one Anthropic API key (shared, ~$5-30/user/month) or one Claude Max subscription per member ($20-200/mo) once migrated.

---

## Multi-Team Model

One admin PA (Admin-PA) plus one sub-agent per team, all in a single OpenClaw gateway. The `team-router` skill lets the admin PA initiate teams, route instructions, and compile cross-team briefings. Regular team members get one PA in a separate container. Team coordinator PAs (one per company) sit between the admin and individual members.

---

## What's Next

Once teams are running, the [Tezit protocol](DEPLOYMENT_PLAN.md) adds structured context (icebergs), real-time PA-to-PA federation (replacing the email bridge), and guest interrogation. Build it on observed usage patterns, not assumptions.

---

*Built in public. Mistakes documented. [Read the build log.](docs/BUILD_LOG.md)*
