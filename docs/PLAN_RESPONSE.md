# Response to the Assembly Architecture Plan

> **⚠️ Historical document.** This captures architecture debates from 2026-02-13, before the first deployment.
> Claworc was **removed** during the Team Alpha deployment (2026-02-14) and replaced by `pactl.sh` (direct Docker).
> See [BUILD_LOG.md](BUILD_LOG.md) for the full decision history and [PROJECT_STATE.md](PROJECT_STATE.md) for current state.

> **Date:** 2026-02-13
> **From:** MyPA deployment plan team
> **To:** Assembly Architecture plan team
> **Context:** Both plans target the same goal — team PA platform using OpenClaw ecosystem tools, zero custom code. We ran these plans in parallel to get competing viewpoints, then merged findings.

---

## What We Adopted From Your Plan

We want to be upfront: your plan improved ours in several concrete ways. We adopted the following:

| Your Idea | What We Did |
|-----------|------------|
| Deployment tiers (Solo → Team) | Added Section 20. Solo at $36/mo skipping Claworc entirely — you were right that Claworc on day one is over-provisioning |
| Slack as team channel | Added Slack config to golden template (disabled by default, enabled per-team). Telegram stays as primary 1:1 interface |
| Role-specific SOUL templates | Created `soul-variants/` with team-lead, IC, and sales variants |
| Team communication skill | Created `skills/team-comms/SKILL.md` for routing norms, escalation, PA-to-PA conventions |
| Success criteria | Added Section 22 with 13 explicit completion criteria |
| Tezit Phase 2 as future direction | Added Section 21 preserving federation, context icebergs, TIP, Library of Context |
| Claude API as future TOS-safe fallback | Noted in risk assessment as a fallback option if Max gets cancelled |

These were good ideas and the plan is better for them.

---

## Where We Went a Different Way (and Why)

### 1. Claude Max: Per-Team Subscriptions, Not Shared Proxy or API

**Your position:** Three options — shared Max proxy (TOS risk), API with budget cap (TOS-safe), or Kimi-only (simplest).

**Our position:** One Claude Max subscription per team. Already provisioned.

**Why:** Cost capping is the primary concern, and per-team Max achieves this cleanly. Each team gets $200/mo flat for coding, no usage metering, no surprise bills, no budget-cap infrastructure. If one team hammers Claude with coding requests, other teams are unaffected — no cross-team rate limit contention.

The TOS risk is real but contained. If Anthropic cancels one team's Max, that team falls back to Kimi for coding. Other teams continue. Per-team isolation means the blast radius of a TOS enforcement action is one team, not the whole platform.

We're not ruling out Claude API with caps as a future option — it's noted in the risk assessment. But right now, Max per team is simpler operationally (no token metering, no RelayPlane, no budget alert infrastructure) and the admin already has the accounts created.

**Where you might push back:** "Per-team Max at $200/team is expensive at 5+ teams. API with a $30/mo cap per team would be $150 total vs $1,000 for 5 teams." Fair point. Our counter: most teams won't need Claude for coding. Sales teams, operations teams, admin-heavy teams run Kimi-only. We estimate 2-3 out of 5 teams will use Max, not all 5. The cost tables in our plan reflect this.

### 2. IDENTITY.md: Separate File, Not Merged Into SOUL.md

**Your position:** Separate IDENTITY.md and TOOLS.md files per PA.

**Our position:** We adopted IDENTITY.md but rejected TOOLS.md separation. SOUL.md handles security boundaries (admin-controlled, users cannot modify). IDENTITY.md handles personality (user-customizable). Tool configuration stays in openclaw.json where OpenClaw expects it.

**Why separate IDENTITY.md from SOUL.md:** The separation enforces a clear permission boundary. The admin controls what PAs *can't* do (SOUL.md). The user controls who their PA *is* (IDENTITY.md). If these are in one file, either the user can edit their security boundaries (bad) or the admin controls their PA's personality (kills adoption).

**Why IDENTITY.md matters more than you might think:** We want team members to think of their PA as a best friend, not a corporate tool. PAs that feel personal get used more. More usage means more AI leverage for the team. The IDENTITY.md template encourages users to name their PA, shape its style, teach it preferences. The storage overhead is trivial — a few KB per PA. The engagement return is significant.

**Where you might push back:** "TOOLS.md gives cleaner separation of tool config from identity." Our counter: OpenClaw already has a clean place for tool config — openclaw.json. Adding a third Markdown file that duplicates what's in JSON creates a sync problem. Two files (SOUL.md for security, IDENTITY.md for personality) is the right split.

### 3. Claworc: Docker-First (You Were Right)

**Your position:** Start with Docker Compose mode, escalate to Kubernetes when needed.

**Our original position:** We assumed k3s was required because Claworc's source code references Kubernetes abstractions (PVCs, Deployments, ConfigMaps).

**Updated position:** You were right. We reviewed the Claworc codebase more carefully and found it has a dual-backend architecture — a `ContainerOrchestrator` interface with two complete implementations (`DockerOrchestrator` and `KubernetesOrchestrator`). At startup, it auto-detects the available backend. On a single-server deployment with Docker installed, it uses the Docker backend: containers via Docker socket, Docker volumes for persistence, bridge network for inter-container communication. No k3s required.

**What we changed:** Removed k3s from Phase 0, updated all rollback/backup commands from `kubectl` to `docker` equivalents, updated the Claworc description to reflect Docker mode support. Our plan now matches your simpler Docker-first install path.

**Lesson learned:** We saw K8s references in the source and assumed K8s was required. We should have read the orchestrator interface and auto-detection logic more carefully before making that assumption.

### 4. Agent Config Format

**Your position:** Object-keyed agents with inline bindings:
```json
{ "agents": { "admin": { "workspace": "...", "bindings": [...] } } }
```

**Our position:** Array-based agents with separate bindings:
```json
{ "agents": { "list": [{ "id": "admin-personal", ... }] }, "bindings": [...] }
```

**Why:** Our format was validated against OpenClaw's multi-agent documentation during the research phase. The `list[]` array with `bindings[]` as a separate top-level array matches the documented API. Using the wrong format means the config won't parse — this isn't a style preference, it's a correctness issue.

**Where you might push back:** "The docs might have changed, or there might be multiple supported formats." Possible. We'd recommend testing both against a running OpenClaw instance before either plan goes to production.

### 4b. Week 1 enforcement updates

To make this decision non-negotiable, I added enforceable validation artifacts:

- `scripts/validate-week1.sh` now runs the core template checks and dry-run provisioning checks for both `member` and `admin` modes.
- `scripts/provision-pa.sh` now:
  - validates JSON payloads before API calls,
  - enforces the `agents` object contract (`defaults` + `list` + top-level `bindings` for admin gateway),
  - includes a dry-run mode for format checks without mutating instances,
  - selects the correct OpenClaw template for `member` vs `admin`.
- `docs/ONBOARDING_RUNBOOK.md` now includes a required Week 1 pre-deployment gate, with instructions to run `bash scripts/validate-week1.sh`.
- `.github/workflows/predeployment-gate.yml` enforces the gate as a required CI check on PR and main-branch updates.

Remaining manual requirement: if schema checks and dry-runs both pass but runtime behavior remains uncertain, the team still must run a canary validation against a live instance as documented in `docs/WEEK1_VALIDATION.md`.

### 5. RelayPlane and Claw EA: Not Now

**Your position:** Defer RelayPlane and Claw EA but keep them in the architecture.

**Our position:** Don't include them at all. They add dependencies and failure points without solving problems we have today.

**Why:** Moonshot's prepaid credits can't overspend (physical budget cap). Claude Max is flat rate per team. There's nothing for RelayPlane to budget-manage. Claw EA's governance features (signed policy contracts, scoped tokens) are valuable at enterprise scale but premature for a team of 5-30 PAs managed by one admin.

**Where you might push back:** "If you switch to Claude API later, you'll need RelayPlane for budget enforcement." Agreed — but only then. Adding it now means maintaining a dependency that does nothing useful until a future decision that may never happen. We'll add it when (if) we need it, not before.

### 6. Daily Briefing: Cron Job, Not Antfarm Workflow

**Your position:** `daily-briefing.yml` as an Antfarm workflow.

**Our position:** Morning briefings are cron jobs in openclaw.json.

**Why:** A daily briefing is a single-agent, single-prompt task: "Check email, check calendar, compile briefing." OpenClaw's native cron handles this perfectly. Antfarm is designed for multi-agent, multi-step development workflows with peer verification (planner, developer, verifier, tester, reviewer). Using Antfarm for a cron prompt is like using a CI pipeline to run `echo "hello"`.

**Where you might push back:** "Antfarm's peer verification could validate briefing quality." In theory, yes. In practice, a morning briefing that arrives 10 minutes late because it's going through a 7-agent workflow defeats its purpose. Briefings need to be fast and reliable, not peer-reviewed.

---

## Work Estimate

### Phase 1 Implementation

| Work Stream | Effort | Who |
|-------------|--------|-----|
| Phase 0: Droplet + Tailscale + Docker | 1 day | Admin |
| Phase 1: Twenty CRM + Claude Max proxies | 1 day | Admin |
| Phase 2: Claworc + golden template + IDENTITY.md per PA | 1-2 days | Admin |
| Phase 3: First team pilot (3-5 PAs, end-to-end) | 2-3 days | Admin + team members |
| Phase 4: Admin multi-agent gateway + team-router | 1 day | Admin |
| Phase 5: Security hardening + Antfarm workflows | 1-2 days | Admin |
| Phase 6: Scale to additional teams | 1-2 days per team | Admin |
| Google Workspace OAuth per PA | 15-30 min per PA | Admin (interactive) |
| Telegram bot creation per PA | 5-10 min per PA | Admin |
| **Total for first team live** | **~7-10 working days** | |
| **Total for 3 teams (15-18 PAs)** | **~12-16 working days** | |

The long pole is Phase 3 observation (2-3 days of real usage before scaling). Everything else is configuration, not coding.

### Ongoing Maintenance

| Task | Frequency | Effort |
|------|-----------|--------|
| Onboard new team member | As needed | 30 min (script) |
| Onboard new team/business | As needed | 1-2 hours (manual steps) |
| Credential rotation | 90-day cycle | 1 hour per rotation |
| OpenClaw version updates | As released | 1-2 hours (staged rollout) |
| Security audit | Weekly | 15 min (automated, review results) |
| Claworc monitoring | Daily | 5 min (dashboard check) |

---

## Probability of Success

We're being honest about what we're confident in and what's uncertain.

### High Confidence (>80%)

| Component | Why |
|-----------|-----|
| Kimi K2.5 as primary model | Proven, prepaid, 256k context, actively maintained. If Moonshot fails, DeepSeek is a drop-in replacement. |
| Google Workspace for PA email/calendar | Google Workspace is Google Workspace. gog skill works. OAuth is well-understood. |
| Twenty CRM | Self-hosted, proven, working OpenClaw skill. Already tested. |
| SOUL.md + IDENTITY.md security model | Prompt-based boundaries + tool deny list + sandbox. Defense in depth. |
| Telegram integration | OpenClaw's most mature channel. Pairing, DM policies, well-documented. |
| Per-PA isolation via Claworc containers | Container isolation is commodity technology. The question is Claworc's management layer, not isolation itself. |

### Medium Confidence (50-70%)

| Component | Why | Mitigation |
|-----------|-----|-----------|
| Claworc stability | 17 stars, 1 maintainer, ~14 commits, created Feb 2026. No CI. | Red/Yellow drop criteria defined. Fallback to Docker Compose + script. Monthly drill. |
| Claude Max per-team via proxy | TOS grey area. Both claude-max-api-proxy and lynkr are young. | Kimi fallback handles everything. Per-team isolation limits blast radius. Claude API is future option. |
| OpenClaw multi-agent mode (admin gateway) | Several open issues on session path resolution. | Fall back to email-bridge-only if unstable. Lose real-time aggregation, keep async. |
| Slack integration | Less mature than Telegram in OpenClaw. | Telegram is primary. Slack is additive, not critical. |

### Lower Confidence (30-50%)

| Component | Why | Mitigation |
|-----------|-----|-----------|
| model-router skill accuracy | Task classification is inherently fuzzy. "Help me write an email about code" — is that coding or email? | Users override with `/model claude` or `/model kimi`. Tune config over time. |
| Email bridge latency for cross-PA queries | 2-hour inbox check cycle means admin→team-member-PA queries take minutes, not seconds. | Reduce to 15-min checks for urgent channels. Tezit federation (Phase 2) is the real solution. |
| Scaling beyond 20 businesses | Multi-agent gateway memory pressure, gateway splitting, loss of real-time coordination. | Addressed in Admin Droplet Isolation section. But untested at scale. |

### Overall Assessment

**Phase 1 with one team: ~85% probability of success.** The core components (OpenClaw, Google Workspace, Kimi, Telegram, Twenty CRM) are all proven. The risks are in the management layer (Claworc) and the Claude proxy, both of which have defined fallbacks.

**Scaling to 3 teams: ~70%.** Each additional team introduces the same patterns (proven) but puts more stress on the admin gateway and Claworc. The uncertainty is whether multi-agent mode stays stable with 5-10 agents.

**Scaling to 10+ teams: ~50%.** Architecture is designed for this but untested. Gateway splitting, admin droplet isolation, and 20+ agent memory pressure are theoretical plans, not validated patterns. This is where Tezit federation becomes necessary.

---

## Open Source Scalability: team.example.com

### Can Others Adopt This?

The plan is explicitly designed for reproducibility:

| Aspect | How It's Reproducible |
|--------|----------------------|
| Zero custom code | Nothing to build. Everything is config, templates, and existing tools. |
| Golden template | Copy `templates/pa-default/`, fill in env vars, deploy. |
| IDENTITY.md | Users customize their own PA personality. No admin involvement. |
| Role variants | Pick the SOUL variant that matches the role. Append to base SOUL.md. |
| Provisioning script | `provision-pa.sh` takes (name, email, team, token) and produces a PA. |
| Antfarm workflow | `antfarm workflow run pa-provision "Name for Team"` — one command. |
| Onboarding runbook | Step-by-step guide any team lead can follow. |

### What Makes This Hard to Adopt (Honestly)

| Barrier | Severity | Possible Solution |
|---------|----------|------------------|
| Google Workspace OAuth per PA | Medium | Interactive flow, can't fully automate. Each PA needs manual OAuth. |
| Telegram bot creation | Low | @BotFather is manual but fast (5 min). Could script via Telegram API. |
| Claworc knowledge | Medium | Limited docs, small community. Adopters need to debug Go if something breaks. |
| Admin multi-agent gateway | Medium | Non-obvious architecture. Most people think "one container per PA" not "multiple agents in one gateway." |
| Claude Max TOS ambiguity | Medium | Organizations with compliance requirements may not accept the risk. Need Claude API option documented. |

### Path to Open Source Project

**What to ship as team.example.com open source:**

```
team.example.com/
├── templates/          # Golden configs, ready to deploy
├── skills/             # team-router, team-comms (and future skills)
├── scripts/            # Provisioning automation
├── workflows/          # Antfarm workflows
├── docs/               # Runbooks, architecture docs
└── examples/           # Example deployments (solo, team, multi-team)
```

**What NOT to ship:**
- Env files, API keys, bot tokens (obviously)
- Organization-specific SOUL.md content
- Org-specific IDENTITY.md content (those are user-generated)

**Effort to make this adoptable by others:** ~2-3 weeks after our own deployment stabilizes. Primarily:
1. Parameterize all org-specific values (domain names, team names) into documented env vars
2. Write `examples/` directory with concrete solo, team, and multi-team setups
3. Test the provisioning script against a clean Claworc instance
4. Write a `CONTRIBUTING.md` with architecture decisions and how to add skills/templates

### Adoption Estimate

| Timeline | Milestone |
|----------|-----------|
| Month 1 | Our own deployment running, 1 team live |
| Month 2 | 3 teams live, operational patterns documented |
| Month 3 | Open source release — templates, scripts, docs |
| Month 4-6 | Community feedback, first external adopters |
| Month 6+ | Tezit Phase 2 work begins (if validated) |

---

## Upstream Dependency Management

We depend on 7 open-source projects. Each will ship updates in the coming weeks and months. Here's how we stay current without breaking production.

### Version Pinning Strategy

| Dependency | Pinned Version | Update Channel |
|-----------|---------------|---------------|
| OpenClaw | `2026.2.x` (pin minor) | GitHub releases + changelog review |
| Claworc | `latest` (no tags yet) | Git commit hash pin until tagged releases exist |
| Twenty CRM | Docker tag pin | GitHub releases |
| Antfarm | `v0.4.x` | GitHub releases |
| gog skill | ClawHub version pin | ClawHub + Clawdex security scan |
| twenty-crm skill | ClawHub version pin | ClawHub + Clawdex security scan |
| model-router skill | ClawHub version pin | ClawHub + Clawdex security scan |

### Staged Rollout Process

```
Upstream releases new version
    │
    ▼
1. Read changelog + diff — any breaking changes?
    │
    ▼
2. Update ONE non-critical PA (test canary)
    │  Observe 24 hours
    ▼
3. Update pilot team PAs (3-5 instances)
    │  Observe 48 hours
    ▼
4. Roll to remaining PAs in batches of 3-5
    │
    ▼
5. Update pinned version in golden template
    │
    ▼
6. Commit to git, push
```

**Rollback:** Stop PA container, recreate with previous image version. Docker volume data persists. Takes < 2 minutes.

**Never update:** During active team work hours, before major deadlines, on Fridays, or when more than one dependency has a pending update (update one at a time).

### Monitoring Upstream Projects

| Project | Watch For | Check Frequency |
|---------|----------|----------------|
| OpenClaw | Security advisories (CVEs), breaking changes in multi-agent, skill API changes | Weekly (GitHub watch) |
| Claworc | Any commit (small repo, read every diff) | Weekly |
| Twenty CRM | Major version bumps, GraphQL schema changes | Biweekly |
| Antfarm | Workflow format changes | Monthly |
| Skills (gog, twenty-crm, model-router) | Clawdex security scans, version bumps | Before any update |
| claude-max-api-proxy / lynkr | Anthropic TOS changes, proxy breaking | Weekly |
| OCSAS | New checks, level changes | Monthly |

### What Happens When a Dependency Dies

| Scenario | Response | Effort |
|----------|----------|--------|
| Claworc abandoned | Docker Compose + `pactl` script + Caddy proxy. Monthly drill prepares for this. | 1-2 days |
| claude-max-api-proxy blocked by Anthropic | Switch to lynkr, or Claude API with caps, or Kimi-only for coding | 2-4 hours per team |
| OpenClaw major breaking change | Pin old version. Evaluate migration when stable. Test on canary first. | 1-2 weeks |
| gog skill breaks | File issue upstream. Fork if unresponsive in 7 days. gog is core to PA function. | Hours (fork) to days (fix) |
| Twenty CRM major migration | Freeze CRM version. Migrate on a scheduled maintenance window. Backup first. | 1 day |
| Kimi K2.5 discontinued | DeepSeek V3 as drop-in replacement. Same OpenAI-compatible API. | 1-2 hours (change baseUrl + apiKey) |

---

## Invitation to Respond

We've made these decisions based on our research and the admin's specific situation (multiple businesses, Max accounts already created, operational simplicity over cost optimization). But we may be wrong.

Specific questions we'd value your perspective on:

1. ~~**Claworc Docker vs K8s:**~~ **Resolved.** You were right — Claworc has a complete Docker backend. We've updated our plan to use Docker mode. No k3s required.

2. ~~**Agent config format:**~~ **Resolved.** We reviewed OpenClaw's source code. The Zod schema uses `.strict()` on the `agents` object — only `defaults` and `list` keys are accepted. Object-keyed format (`"agents": { "admin": {...} }`) would fail validation at startup. Our `agents.list[]` + top-level `bindings[]` format is the only supported structure. This is not a runtime test — it's a schema constraint.

3. **RelayPlane timing:** At what team count or spend level would you add RelayPlane? We want a concrete trigger, not "when needed."

4. **Federation timeline:** You position Federation as Phase 2. How many months of email-bridge pain do you think it takes before the investment in Ed25519 federation is justified? We're guessing 2-3 months, but you may have better signal.

5. **Cost at 5+ teams:** Our per-team Max model gets expensive at 5+ teams ($1,000/mo in Max alone). Your API-with-cap option is cheaper. At what point do you think we should switch? We want a defined trigger, not a gut feel.

We're not trying to win an argument. We're trying to build the best plan. If you have evidence that changes any of our positions, we'll adopt it.
