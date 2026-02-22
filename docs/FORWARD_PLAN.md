# MyPA Platform -- Forward Plan

> **Date:** February 19, 2026
> **Author:** The platform operator + Claude
> **Purpose:** Diagnose blockers that stalled scaling, design the path forward

---

## Situation Assessment

### What's Working

- **Infrastructure foundation** -- pactl, Docker, Twenty CRM, Caddy, monitoring all solid
- **Fleet droplet (mypa-fleet)** -- `203.0.113.20`, admin PA running, full-capability
- **SOUL.md / IDENTITY.md split** -- admin-controlled security vs user-controlled personality: right design
- **Deployment handoff doc** -- excellent operational lessons document
- **CI/CD validation** -- predeployment-gate.yml catches config regressions
- **Provisioning API** -- server.js on localhost:9100 is the right model (no SSH needed)

### What Stalled (Root Causes)

**Blocker 1: Claude Auth Provisioning**

The provisioning checklist requires:

```
- [ ] `claude auth login` via VNC browser   <-- blocks here
- [ ] `openclaw models auth setup-token`
```

This is a user-in-the-loop manual step that:

- Requires each user to have their own Claude Max subscription ($200/mo)
- Can't be done on the user's behalf without their credentials
- Requires VNC access to a running container (operationally messy)
- Doesn't scale beyond a handful of PAs

**Root cause:** PA auth was treated like a personal developer tool (individual credentials)
when it should be treated like a platform service (team API key).

**Blocker 2: Update Distribution**

No automated delivery of changes to running containers. The model assumed "deploy once,
runs forever" -- but:

- OpenClaw releases updates regularly (v2026.2.15+ already noted in docs)
- Config changes (SOUL.md, cron jobs) require touching containers
- No mechanism to push changes from this repo to running droplets without SSHing in

**Root cause:** Missing the ops layer between "changes in git" and "changes applied to
production."

**Blocker 3: Lost Admin-PA Access**

Admin-PA's droplet (original personal PA, separate from mypa-fleet):
- Was set up with old Claworc structure (`/home/claworc/` paths are real paths on that droplet)
- Has valuable state: gog OAuth tokens, CRM config, MEMORY.md
- SSH access is broken, but DigitalOcean console access still works (see Phase 0)

**Blocker 4: Claworc References** (see [TODO: Claworc Cleanup](#todo-claworc-cleanup))

Multiple files still contain operational Claworc references. Needs systematic cleanup.

---

## Solutions

### Fix 1: Team Anthropic API Key (Solve Auth Provisioning)

**Switch from individual Claude subscriptions to Anthropic API keys.**

Instead of:
```bash
# Requires user's Claude account + VNC browser session
claude auth login
openclaw models auth setup-token
```

Use:
```bash
# Admin creates key in Anthropic Console, injects at container creation
docker create mypa-alice-pa -e ANTHROPIC_API_KEY=sk-ant-REDACTED
```

**Implementation steps:**
1. Admin creates one Anthropic API key per team in Anthropic Console (one-time)
2. Store API key in 1Password per-team vault
3. Update `provision-pa.sh` to accept `--api-key` flag and inject as env var
4. Update `templates/pa-default/openclaw.json` to use API key auth mode
5. Update `rotate-gateway-token.sh` to also handle API key rotation

**Cost:** ~$5-30/user/month pay-per-token vs $200/mo Claude Max per user. At team scale,
API keys are significantly cheaper for moderate use.

**Upgrade path:** If a user already has Claude Max and wants to connect it personally, they
can still do the `claude setup-token` flow and that token takes priority. Both models work.

**Note on gog OAuth:** The Google Workspace OAuth consent flow (VNC browser, one-time per
PA) is still required -- Google's security model mandates it. But it's a known one-time step,
not a recurring blocker. Everything after first auth is automated via API.

---

### Fix 2: Three-Layer Update Pipeline (Solve Update Distribution)

**Layer 1: Watchtower (OpenClaw version updates)**

Add Watchtower to each droplet. It monitors Docker Hub, pulls new OpenClaw images,
does rolling restarts. No human intervention for version updates.

```yaml
# Add to droplet services
watchtower:
  image: containrrr/watchtower
  command: --schedule "0 2 * * 0" --cleanup   # Sundays 2 AM
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
  labels:
    - "mypa.managed=true"
```

**Layer 2: GitOps Pull Agent (config/template changes)**

A systemd timer on each droplet that pulls this repo and applies config changes:

```bash
# /etc/systemd/system/mypa-gitops.timer -- every 15 minutes
# /opt/mypa/gitops-sync.sh:
#   1. git pull private repo
#   2. compare template checksums to deployed configs
#   3. docker cp new SOUL.md / IDENTITY.md / email-rules.yaml into containers
#   4. docker exec to reload cron jobs if changed
#   5. log what was updated (rotation log for audit)
```

Result: SOUL.md and config changes in this repo automatically reach all PAs within 15 min.
No SSH. No manual steps.

**Layer 3: Provisioning API + Admin PA (targeted commands)**

The Provisioning API already exists at `localhost:9100`. Extend it:

```
POST /pa/update-config   -- apply new template to running container
POST /pa/restart         -- graceful restart
POST /pa/install-skill   -- install or update a skill
GET  /pa/version         -- get current OpenClaw version
GET  /pa/health          -- full health report
```

Then Admin-PA can orchestrate updates:

> "Admin-PA, roll out the new SOUL.md to all Team Alpha PAs"
-> Admin-PA calls POST /pa/update-config for each PA -> all updated, no SSH

**Layer 4: GitHub Actions + Tailscale (host-level script/infra changes)**

For changes to pactl.sh, provision-pa.sh, services/ -- things that live on the host:

```yaml
# .github/workflows/deploy-to-fleet.yml
on:
  push:
    branches: [main]
    paths: ['scripts/**', 'services/**']
jobs:
  deploy:
    steps:
      - uses: tailscale/github-action@v2
        with:
          authkey: ${{ secrets.TAILSCALE_AUTHKEY }}
      - run: ssh mypa@203.0.113.20 'cd /opt/mypa && git pull && ./scripts/apply-updates.sh'
```

Triggered on PR merge. No manual SSH for script updates.

---

### Fix 3: Admin-PA Recovery

**Step 1: Regain access without SSH**

```bash
# Option A: DigitalOcean web console
# DO Dashboard -> Droplets -> [Admin-PA droplet] -> Access -> Launch Droplet Console
# No SSH needed -- web-based terminal

# Option B: doctl CLI
doctl compute droplet-action password-reset --droplet-id <ADMIN_PA_DROPLET_ID>
# Then console in with new root password

# Option C: Add SSH key via DO API
doctl compute ssh-key import my-key --public-key-file ~/.ssh/id_ed25519.pub
doctl compute droplet-action rebuild --droplet-id <ADMIN_PA_DROPLET_ID> ...
```

**Step 2: Export valuable state**

Once in, export before touching anything:

```bash
# gog OAuth tokens
cp -r /home/claworc/.config/gogcli/ /tmp/admin-pa-gog-backup/

# OpenClaw workspace (MEMORY.md, daily logs, CRM config)
cp -r /home/claworc/.openclaw/workspace/ /tmp/admin-pa-workspace-backup/

# Tar and scp back to local machine
tar czf /tmp/admin-pa-backup.tar.gz /tmp/admin-pa-gog-backup /tmp/admin-pa-workspace-backup
# scp root@<admin-pa-ip>:/tmp/admin-pa-backup.tar.gz ~/Desktop/
```

**Step 3: Decision -- Consolidate or Keep Separate**

| Option | Pros | Cons |
|--------|------|------|
| **A: Migrate to Fleet (recommended)** | -$48/mo, less ops overhead, simpler | Admin-PA shares droplet with team PAs |
| **B: Keep separate, migrate to pactl** | Cleaner admin/team separation | +$48/mo, two droplets to maintain |
| **C: Retire, use existing admin PA** | Simplest, zero migration work | Loses Admin-PA's accumulated memory/gog tokens |

**Recommendation: Option A.** The Fleet droplet (4vCPU/8GB) easily handles both the admin
PA and team member PAs. Create a new admin PA container on Fleet using pactl, restore workspace
data. Admin-PA's identity, memory, and name are preserved. The old droplet is retired.

---

## TODO: Claworc Cleanup

> **Note:** Historical references explaining *why* Claworc was removed (BUILD_LOG.md) should
> be KEPT -- that's valuable architectural context. Only remove references that imply Claworc
> is still an active tool.

**Note on deployment handoff doc paths:** The `/home/claworc/` paths in that file are
REAL paths on the old Admin-PA droplet (Claworc created a `claworc` system user). They are
accurate documentation of the old system -- update them AFTER migrating Admin-PA, not before.

Files requiring operational Claworc reference removal:

| File | Lines | Action |
|------|-------|--------|
| `DEPLOYMENT_PLAN.md` | ~232 | Replace "Creates a Claworc instance" -> "Creates a pactl container" |
| `DEPLOYMENT_PLAN.md` | ~276 | Update team provision instruction text to use pactl |
| `DEPLOYMENT_PLAN.md` | ~309 | Remove/annotate "Initial Claworc deployment" as historical |
| `README.md` | 123 | Already good ("Claworc removed") -- keep |
| `docs/BUILD_LOG.md` | All | Keep history sections, verify no implied-active references |
| `docs/deployment-handoff.md` | 65-67, 121, 136-137 | Update `/home/claworc/` paths AFTER Admin-PA migration |

---

## The Forward Architecture

### Multi-Team Model (Clarified)

```
Admin (Platform Operator)
  |
  +-- Claude Code (mac) -- planning, infrastructure, code
  |
  +-- Admin-PA (on Fleet droplet) -- admin PA, cross-team orchestration
      +-- team-router skill: /team alpha <instruction>
      +-- Provisioning API access (localhost:9100)
      +-- Google Admin SDK (create team PA accounts)
      +-- PA-to-PA email bridge to Team PAs
          |
          +-- Team Alpha
          |   +-- Team PA (pa-team-alpha) -- coordinator for Team Alpha
          |   |   +-- team@company.example.com email (not a person's email)
          |   |   +-- Morning briefing with all Team Alpha member PAs
          |   |   +-- Routes external contacts to right member PA
          |   |   +-- CRM read access: Team Alpha workspace in Twenty
          |   +-- pa-alice -- Alice's personal PA
          |   +-- pa-bob   -- Bob's personal PA
          |   +-- Twenty CRM: alpha.team.example.com workspace
          |
          +-- Next Company (future)
              +-- Team PA (pa-team-nextco)
              +-- pa-charlie
              +-- Twenty CRM: nextco.team.example.com workspace
```

### The Missing Piece: Team PA

Current design has admin PA (Admin-PA) and individual member PAs, but is missing the
**team-level PA** -- a shared PA for each team that:

- Has access to the team's shared CRM workspace
- Receives team-wide external emails and routes them intelligently
- Runs team briefings (morning status across all members, not just individual briefings)
- Coordinates when member A's PA needs to interact with member B's PA
- Is the external-facing "team assistant" (team@company.com)

This is the "team OpenClaw helping to orchestrate all the team members" from the vision.

**Implementation:**
- One additional PA container per team: `pa-team-<team>`
- New SOUL variant: `SOUL-team-coordinator.md` (focuses on routing and coordination)
- PA-to-PA email bridge with member PAs (no new infrastructure, just protocols)
- CRM access: read across team workspace, write for team-level contacts

**Why email bridge (not sessions_send) for team PA <-> member PA:**
- `sessions_send` only works within the same gateway process
- Team members are in separate containers (correct for isolation)
- Email is async, auditable, and doesn't require custom protocol
- Trade-off: async latency (~10 min poll cycle) vs real-time. Acceptable for team coordination.

**When to add real-time inter-PA communication:**
Phase 2 future option: Lightweight webhook protocol via Provisioning API.
PA sends `POST /pa/message/<target-pa-name>` with message payload.
Target PA's cron job polls `/pa/inbox`. This would reduce latency to seconds.
Not needed for Phase 3, revisit in Phase 4.

---

## Phased Execution Plan

### Phase 0: Recovery (Days 1-3)

- [ ] Log into DigitalOcean dashboard -> find Admin-PA droplet (separate from mypa-fleet)
- [ ] Regain console access (DO web console or doctl password reset)
- [ ] Export gog OAuth tokens, workspace data, MEMORY.md from Admin-PA droplet
- [ ] Document Admin-PA droplet: ID, IP, current running state, what's broken
- [ ] Decision: Consolidate onto Fleet (Option A) or keep separate (Option B)
- [ ] Remove Claworc references from DEPLOYMENT_PLAN.md and BUILD_LOG.md (not deployment-handoff yet -- after migration)

### Phase 1: Fix Auth Provisioning (Days 3-7)

- [ ] Create Anthropic API key for platform (Anthropic Console)
- [ ] Store in 1Password (vault: PA Platform)
- [ ] Update `provision-pa.sh` to accept `--api-key` flag
- [ ] Update `templates/pa-default/openclaw.json` for API key auth mode
- [ ] Test: provision one new container with API key -- verify Claude responds
- [ ] Update provisioning checklist in deployment handoff doc (remove VNC auth requirement)
- [ ] Update `rotate-gateway-token.sh` to include API key rotation

### Phase 2: Update Distribution (Days 7-14)

- [ ] Add Watchtower service to Fleet droplet
- [ ] Write `scripts/gitops-sync.sh` (15-min pull + apply)
- [ ] Write systemd unit files: `mypa-gitops.timer`, `mypa-gitops.service`
- [ ] Add gitops setup to `bootstrap-droplet.sh`
- [ ] Extend `services/provisioning-api/server.js` with update/version/health endpoints
- [ ] Build `.github/workflows/deploy-to-fleet.yml` with Tailscale SSH
- [ ] Test full cycle: change SOUL.md -> merge PR -> verify change appears in container within 15 min

### Phase 3: Admin-PA Migration + Team Alpha Completion (Days 14-28)

- [ ] Migrate Admin-PA to Fleet droplet (or keep separate -- per decision in Phase 0)
- [ ] Restore Admin-PA's gog OAuth tokens and workspace data in new container
- [ ] Deploy Provisioning API on Fleet host (localhost:9100)
- [ ] Deploy team-router skill to Admin-PA
- [ ] Provision remaining Team Alpha member PAs (API key model)
- [ ] Provision Team Alpha Team PA (pa-team-alpha)
- [ ] Write `templates/soul-variants/SOUL-team-coordinator.md`
- [ ] Configure team@company.example.com email in Team Alpha Team PA
- [ ] Complete gog OAuth for all Team Alpha PAs (VNC consent, one per PA)
- [ ] Complete remaining PROJECT_STATE.md items (Telegram, Workspace)
- [ ] Update deployment handoff doc `/home/claworc/` paths to reflect pactl structure

### Phase 4: Multi-Team Readiness (Month 2)

- [ ] Onboard second company using same playbook
- [ ] Document what still required manual steps -- reduce to minimum
- [ ] Admin-PA can receive: "Onboard Alice to Zenith team" -> fully autonomous provisioning
- [ ] Provisioning API + Google Admin SDK + CRM API all callable by Admin-PA
- [ ] Open source prep: clean secret history, add LICENSE, review public-facing docs
- [ ] Publish blog: "How we built team PAs in 6 weeks with zero custom code"

---

## Key Design Decisions

### Why Anthropic API Keys (Not Individual Subscriptions)?

| Factor | Individual Claude Max ($200/mo) | Anthropic API Key |
|--------|--------------------------------|-------------------|
| Provisioning | Requires user VNC auth | Zero user action |
| Cost | $200/mo flat per user | ~$5-30/mo usage-based |
| Control | User owns the credential | Admin owns, can revoke |
| Scale | Manual per user | Automated at provision time |
| Upgrade path | Works as override if user has Max | Yes -- user token takes priority |

Decision: **API keys by default.** Allow personal token override for power users.

### Why Docker Email Bridge (Not Custom Protocol) for Team PA?

`sessions_send` is intra-gateway only. Custom PA-to-PA protocol would require:
- New server component (adds complexity, attack surface)
- Auth between PAs (another credential to manage)
- Ops overhead (another service to monitor)

Email (via gog) is:
- Already deployed on every PA
- Auditable (thread in CRM)
- Async (fine for team coordination)
- No new infrastructure

Decision: **Email bridge now.** Revisit webhook protocol in Phase 4 if latency is a problem.

### Why One Shared Fleet Droplet (Not Per-Team Droplets)?

Current spec: 4vCPU/8GB/160GB. At ~512MB per PA container:
- Comfortable capacity: ~12-14 concurrent PAs
- With Twenty CRM + Caddy: ~8-10 PAs per droplet
- Split when RAM hits 80% OR compliance requires isolation

Decision: **Shared fleet droplet now, per-team droplets when scale or compliance demands it.**
Adding a second droplet is a `bootstrap-droplet.sh` run + DNS update -- no re-architecture.

---

## What This Unlocks

Once these fixes are in place:

1. **Provisioning a new PA** becomes a 3-step flow:
   - Admin: `./provision-pa.sh --name alice-pa --member "Alice" --team "alpha" --email alice@company.example.com`
   - One VNC session for Google OAuth consent (unavoidable, ~5 min)
   - Automated: everything else (CRM, email sync, cron, skills)

2. **Pushing a config update** becomes:
   - Edit SOUL.md in this repo
   - Merge PR -> gitops-sync.sh applies to all containers within 15 min
   - Zero SSH

3. **Onboarding a new team** becomes:
   - Admin-PA receives: "Onboard the Zenith team: Alice, Bob, Carol"
   - Admin-PA calls Provisioning API for each member
   - Admin does 3 VNC OAuth sessions
   - Done

4. **Updating OpenClaw** becomes:
   - OpenClaw publishes new image to Docker Hub
   - Watchtower pulls and restarts each container at 2 AM Sunday
   - Zero human action

---

*End of Forward Plan*
