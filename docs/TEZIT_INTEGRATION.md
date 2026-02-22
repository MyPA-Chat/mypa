# Tez Protocol Integration: PA-to-PA Communication for the MyPA Fleet

> **Version:** 1.0 (February 2026)
> **Status:** Integration plan. The Tez Protocol POC exists; this document describes how it connects to the PA fleet.
> **Audience:** Platform operators, contributors, anyone deploying a multi-PA fleet with OpenClaw.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [What the Tez Protocol Is](#what-the-tez-protocol-is)
3. [Integration Architecture](#integration-architecture)
4. [Phase A: Foundation](#phase-a-foundation-week-1)
5. [Phase B: Communication Patterns](#phase-b-communication-patterns-week-2)
6. [Phase C: Replace the Email Bridge](#phase-c-replace-the-email-bridge-week-3-4)
7. [Phase D: Cross-Fleet Federation](#phase-d-cross-fleet-federation-month-2)
8. [What NOT to Build Yet](#what-not-to-build-yet)
9. [Key Design Decisions](#key-design-decisions)
10. [Success Criteria](#success-criteria)

---

## The Problem

A fleet of Personal AI Assistants (PAs) running on OpenClaw has three communication tiers, each with different constraints:

### Same Gateway (Admin PAs)

Admin PAs run as multiple agents within a single OpenClaw gateway process. They communicate via `sessions_send` -- OpenClaw's built-in intra-gateway messaging. This works, but it only works within one process. It cannot cross container boundaries.

### Cross-Container (Team Member PAs on the Same Droplet)

Team member PAs run in separate Docker containers, each with their own gateway. Since `sessions_send` is intra-gateway only, these PAs fall back to an email bridge:

- PAs email each other using PA email addresses with a `[PA-to-PA]` subject prefix
- Inbox check cron jobs run every 2 hours during business hours
- Latency: minutes to hours
- No delivery guarantee
- Unstructured plain text
- Pollutes the email inbox alongside human correspondence

From the fleet's `team-comms` skill:

> *"Use their PA email address (e.g., `alicepa@yourdomain.com`), not the human's personal email. Subject line format: `[PA-to-PA] <topic>`. Expect async response. PA inbox checks run every 2 hours during business hours."*

### Cross-Fleet (PAs on Different Droplets)

There is no mechanism at all. PAs on different infrastructure cannot communicate with each other. The email bridge technically works across droplets (email is global), but it was designed for same-fleet coordination, not cross-fleet structured data exchange.

### What This Means in Practice

A team PA cannot compile a morning briefing from member PAs unless they share a gateway. An admin PA cannot aggregate status from team PAs across multiple droplets without waiting for email round-trips. Escalations lose context as they traverse the email bridge. There is no structured format for passing rich context -- meeting notes, CRM snapshots, error logs -- between PAs.

The fleet needs a purpose-built PA-to-PA communication layer that works across containers, across droplets, and carries structured context -- not just text.

---

## What the Tez Protocol Is

The Tez Protocol (Tezit Protocol v1.2) provides structured, shareable, interrogatable context packages called **Tez bundles**. It was built by team members as a working POC:

- 54 files, Python 3.12
- FastMCP server + Typer CLI
- 82+ commits, 3 active contributors
- 13 test files, full CI (build, lint, type-check, test, security)

### What Is a Tez?

A Tez is a self-contained knowledge package. It could be a meeting summary, a root cause analysis, a document set, a daily briefing -- any context that needs to travel between PAs with structure intact.

```
{tez-id}/
  manifest.json     <-- metadata, access control, permissions (Tezit Protocol v1.2)
  tez.md            <-- human/LLM-readable synthesis with citations
  context/          <-- source files (any format: logs, CSVs, PDFs, markdown)
```

The `manifest.json` carries metadata about the bundle: who created it, who can access it, when it was created, what it contains. The `tez.md` is the LLM-readable narrative -- the part an AI can reason about without parsing raw files. The `context/` directory holds the source material, preserving provenance.

### Three-Layer Architecture

The Tez Protocol separates concerns into three layers:

```
Layer 1: MCP Server (stateless, cloud-hosted)
  - Owns all storage operations (S3 for bundles, DynamoDB for metadata)
  - Generates pre-signed URLs for upload/download
  - Manages access control via DynamoDB recipients list
  - Sends notifications via SendGrid when bundles are shared

Layer 2: CLI (local, zero cloud credentials)
  - Runs inside each PA container
  - Exchanges tokens for pre-signed URLs (never holds cloud credentials)
  - Handles file I/O: building bundles, downloading bundles
  - Constructs protocol-compliant directory structures

Layer 3: PA (the Claude orchestrator)
  - User or cron job triggers the PA
  - PA calls MCP tools (build, share, download, list)
  - PA invokes CLI for local file operations
  - PA synthesizes downloaded context into briefings, escalations, reports
```

This separation means the CLI never touches cloud credentials (it gets time-limited pre-signed URLs from the MCP server), and the MCP server never touches local files (it just generates URLs and manages metadata).

### MCP Tools

| Tool | Purpose |
|------|---------|
| `tez_build` | Reserve a Tez ID, create metadata record, generate upload URLs |
| `tez_build_confirm` | Validate all uploads completed, activate the record |
| `tez_download` | Auth check, generate download URLs for a shared bundle |
| `tez_share` | Add a recipient to the access list, send notification |
| `tez_list` | Query bundles the PA created or that were shared with the PA |
| `tez_info` | Read-only metadata lookup for a specific bundle |
| `tez_delete` | Remove a bundle and its storage |

### Security Model

- **Pre-signed URLs as authorization.** Time-limited, scoped to specific objects. The CLI never holds S3 or DynamoDB credentials.
- **Email-based identity.** Each PA's email address is its Tez identity. No new auth system required -- PA emails are already unique.
- **DynamoDB recipients list is authoritative.** Access control lives in the metadata record, not in S3 bucket policies.
- **Token exchange.** Opaque short-lived tokens are exchanged for pre-signed URLs via a REST endpoint on the MCP server. Tokens expire; URLs expire. No long-lived credentials in PA containers.

---

## Integration Architecture

Every PA in the fleet connects to the same Tez MCP server. The server handles isolation via email-based access control in DynamoDB -- not via network segmentation or separate server instances.

```
FLEET DROPLETS                              AWS
+-----------------------+
| pa-alice              |---+
| pa-carol              |   |    +------------------------+
| pa-team-alpha         |---+--->| Tez MCP Server         |
| (7 PAs)               |   |   | (ECS Fargate)          |
+-----------------------+   |   |                        |
+-----------------------+   |   | DynamoDB: metadata     |
| pa-frank              |---+--->| S3: tez-packages       |
| pa-team-beta          |   |   | SendGrid: notify       |
| (3 PAs)               |   |   +------------------------+
+-----------------------+   |
+-----------------------+   |
| pa-judy               |---+
| pa-team-gamma         |
| (3 PAs)               |
+-----------------------+
  ... (all PAs connect to same MCP server)
```

Key properties of this architecture:

1. **No direct PA-to-PA connections.** PAs never talk to each other. They talk to the Tez server.
2. **No SSH or container access needed.** A PA on Fleet A shares a Tez with a PA on Fleet B via the same cloud endpoint.
3. **Same infrastructure for same-fleet and cross-fleet.** No protocol distinction. The MCP server does not know or care which droplet a PA lives on.
4. **Centralized access control.** DynamoDB is the single source of truth for who can read what.

---

## Phase A: Foundation (Week 1)

### A1. Deploy the Tez MCP Server

The MCP server runs on ECS Fargate as a stateless HTTP service. Infrastructure definitions already exist in the tez-poc repository.

**Infrastructure:**
- ECS Fargate task (single instance serves all PAs across all fleets)
- S3 bucket for Tez bundle storage
- DynamoDB table for metadata and access control
- SendGrid integration for share notifications

**Environment variables:**
```
TEZ_S3_BUCKET=tez-packages-production
TEZ_DYNAMODB_TABLE=tez-metadata
SENDGRID_API_KEY=<from-secrets-manager>
```

**Endpoint:** HTTPS, accessible from all fleet droplets. No Tailscale or VPN required -- the MCP server is a public API with token-based auth.

**Why one server for all teams:** DynamoDB handles tenant isolation via email-based access control. Running per-team MCP servers would add operational complexity with no security benefit -- the access control is in the data layer, not the network layer.

### A2. Install the Tez CLI in PA Containers

The CLI is a Python package installed from the tez-poc repository. The critical design choice here is where to put it.

**Lesson learned from previous deployments:** Binary tools stored inside container filesystems get wiped on every container upgrade. This broke 16 containers during a previous fleet-wide upgrade. The Tez CLI must survive container recreation.

**Solution: Persistent volume mount.**

```
Host: /opt/mypa/shared/bin/tez
Container: /usr/local/bin/tez (bind-mounted, read-only)
```

Installation on the host:
```bash
pip install --target /opt/mypa/shared/lib/tez tez-protocol
ln -sf /opt/mypa/shared/lib/tez/bin/tez /opt/mypa/shared/bin/tez
```

Container launch flag:
```
-v /opt/mypa/shared/bin/tez:/usr/local/bin/tez:ro
```

This follows the same pattern used for other persistent binaries in the fleet. The CLI is read-only inside the container -- a PA cannot modify or replace it.

### A3. Configure PA Identity

Each PA needs a Tez identity tied to its email address. This configuration lives in the PA's persistent data volume (not the container filesystem).

```json
// ~/.tez/config.json (inside PA container, on persistent volume)
{
  "email": "pa.alice@team.example.com",
  "name": "Alice's PA",
  "mcp_endpoint": "https://tez.example.com"
}
```

The email address is the PA's existing workspace email -- no new identity system. The MCP endpoint is the same for all PAs.

### A4. Create the `tez` SKILL.md

A new skill teaches PAs when and how to use Tez bundles. The skill is installed alongside the existing `team-comms` skill.

```markdown
# tez

> Build, share, download, and interrogate Tez bundles for PA-to-PA
> structured communication.

## When to Use Tez

- Sending structured context to another PA (briefings, escalations, reports)
- Sharing multi-file context packages (logs + analysis + recommendations)
- Cross-fleet communication (PAs on different infrastructure)
- Any PA-to-PA message that carries more than plain text

## When NOT to Use Tez

- Human-facing email (use Gmail directly)
- Real-time chat with the user (use Telegram/app)
- Simple single-sentence PA-to-PA messages (email is fine)

## Core Flows

### Build and Share
1. tez_build: reserve ID, upload files
2. tez_build_confirm: activate the bundle
3. tez_share: add recipient PA email, send notification

### Receive and Process
1. tez_list: check for new bundles shared with me
2. tez_download: pull bundle contents
3. Read tez.md for the synthesis, context/ for source material
4. Act on the content (summarize, escalate, incorporate into briefing)
```

---

## Phase B: Communication Patterns (Week 2)

With the foundation in place, the fleet adopts three communication patterns that replace or augment the email bridge.

### B1. Team Briefing Distribution

The most common PA-to-PA communication pattern: a team PA compiles a daily briefing and distributes it to all team member PAs.

**Current state (email bridge):**
```
Team PA emails each member PA individually.
Each email is plain text. No structure.
Member PAs check email every 2 hours.
By the time all PAs have the briefing, half the morning is gone.
```

**With Tez:**
```
Team PA (morning cron, e.g. 6:30 AM):
  1. Compile CRM updates, calendar events, email digest
  2. tez_build("daily-brief-2026-02-23", files=[
       crm-updates.md,
       calendar-summary.md,
       email-digest.md
     ])
  3. tez_build_confirm
  4. tez_share with pa.alice@team.example.com
  5. tez_share with pa.carol@team.example.com
  6. tez_share with pa.frank@team.example.com

Member PAs (inbox check cron, 6:45 AM):
  1. tez_list (filter: new/unread)
  2. tez_download("daily-brief-2026-02-23")
  3. Read tez.md -> structured briefing with CRM citations
  4. Incorporate into member's morning briefing
```

The difference: structured multi-file context arrives as a package, not a flat email. The member PA gets CRM data it can query against, calendar entries it can cross-reference, and an LLM-readable synthesis it can build on.

### B2. Escalation from Individual PA to Team PA

When an individual PA encounters something that needs team-level attention -- a cross-team dependency, a blocked task, an unexpected error -- it escalates via Tez.

```
Individual PA (alice.team.example.com) encounters API breaking change:
  1. tez_build("escalation-api-breaking-change", files=[
       error-logs.txt,
       affected-services.md,
       proposed-fix.md
     ])
  2. tez_build_confirm
  3. tez_share with team-alpha@team.example.com

Team PA receives Tez on next inbox check:
  1. Downloads bundle
  2. Reads tez.md: "API v2 endpoint returns 404. Affects services X, Y.
     Proposed fix: pin to v1 until migration."
  3. Triages: Is this cross-team? Share with other team PAs.
  4. Optionally: tez_share with team-beta@team.example.com
```

The escalation carries its evidence (error logs), its analysis (affected services), and its recommendation (proposed fix) as a structured package. The team PA can reason about it without asking follow-up questions.

### B3. Cross-Team Coordination via Admin PA

The admin PA coordinates across teams. Currently this requires `sessions_send` for same-gateway PAs and has no mechanism for cross-fleet PAs. Tez makes cross-team coordination uniform.

```
Admin PA requests weekly status:
  1. For each team PA (same or different fleet):
     - Email or sessions_send: "Build your weekly status Tez and share it with me"

Each team PA:
  1. tez_build("weekly-status-team-alpha-w08", files=[
       accomplishments.md,
       blockers.md,
       next-week-priorities.md,
       crm-pipeline-snapshot.csv
     ])
  2. tez_share with admin@example.com

Admin PA (once all team Tez bundles arrive):
  1. tez_list (filter: weekly-status-*)
  2. tez_download each
  3. Compile cross-team brief with citations back to each team's Tez
```

This works identically whether the team PAs are on the same droplet, a different droplet, or a different cloud provider. The admin PA does not need SSH access, container access, or `sessions_send` reach to any team PA.

### B4. Tez Inbox Check Cron Job

Each PA gets a new cron job that checks for incoming Tez bundles. This supplements the existing email inbox check.

```json
{
  "id": "tez-inbox-check",
  "schedule": "*/10 5-23 * * *",
  "prompt": "Check for new Tez bundles shared with me using tez_list. For any new or unread bundles, download them and summarize the contents. If any bundle is marked urgent or contains an escalation, alert my owner immediately. Otherwise, incorporate into the next briefing."
}
```

**Frequency: every 10 minutes** during active hours (5 AM to 11 PM). This is 12x faster than the email bridge's 2-hour cycle, with negligible infrastructure cost -- `tez_list` is a single DynamoDB query.

---

## Phase C: Replace the Email Bridge (Week 3-4)

### C1. Update the team-comms Skill

The `team-comms` SKILL.md currently teaches PAs to use the email bridge for PA-to-PA communication. This update changes the routing:

**Before:**
> When communicating with another team member's PA, use their PA email address. Subject line format: `[PA-to-PA] <topic>`.

**After:**
> When communicating with another PA:
> - **Structured context** (briefings, escalations, reports, multi-file packages): Build a Tez bundle and share it with the recipient PA's email.
> - **Simple coordination** (one-line queries, acknowledgments): Email with `[PA-to-PA]` subject is still acceptable.
> - **Human-facing communication**: Always use email. Tez is PA-to-PA only.

The email bridge does not disappear. It remains the fallback for simple messages and the only channel for human-facing communication. Tez handles the structured, context-rich PA-to-PA traffic that email was never designed for.

### C2. Update the team-router Skill

The `team-router` skill currently has a hard limitation documented in its notes:

> *"Team member PAs (Alice, Bob, etc.) are on separate pactl-managed Docker containers and cannot be reached via `sessions_send`. Use email bridge for admin-to-team-member-PA communication."*

With Tez, the team-router skill gains cross-container reach:

- **`/teams briefing`** triggers each team PA to build a Tez and share it with the admin PA. This works across containers and across fleets.
- **`/team <name> <instruction>`** can still use `sessions_send` for same-gateway agents (instant), but falls back to Tez for cross-container or cross-fleet PAs (minutes, structured).
- **`/teams status`** collects Tez-based status bundles instead of relying solely on `sessions_send`.

### C3. Notification Strategies

Tez bundles arrive asynchronously. The fleet supports three notification strategies, deployable incrementally:

**Option A: Cron-based polling (immediate, no new infrastructure)**
- PAs check `tez_list` every 10 minutes via cron
- Matches the existing pattern (email inbox checks are cron-based too)
- Latency: up to 10 minutes
- Deploy first. This is the baseline.

**Option B: Telegram notification (near real-time, uses existing infrastructure)**
- SendGrid sends a notification email when a Tez is shared
- PA's email inbox check (or a dedicated filter) detects the notification
- PA downloads the Tez immediately
- Alternatively: the MCP server calls a webhook that triggers a Telegram message
- Latency: seconds to minutes
- Deploy second, for PAs that need faster response.

**Option C: Webhook endpoint on each PA (real-time, requires PA-side HTTP listener)**
- Each PA exposes a `/tez-notify` webhook endpoint
- MCP server calls the webhook when a Tez is shared
- PA downloads immediately
- Latency: seconds
- Deploy third, only if cron + Telegram notification is insufficient.

---

## Phase D: Cross-Fleet Federation (Month 2+)

### D1. Multi-Team Sharing

The simplest and most impactful federation scenario: a PA on Fleet Alpha shares a Tez with a PA on Fleet Beta. Different droplets, different containers, possibly different cloud providers.

```
pa-alice (Fleet Alpha, 10.0.1.10)
  --> tez_build + tez_share(recipient="pa.frank@beta.example.com")
  --> Tez MCP Server (ECS Fargate)
  --> DynamoDB: recipients updated
  --> SendGrid: notification to pa.frank@beta.example.com

pa-frank (Fleet Beta, 10.0.2.20)
  --> tez_list (cron, discovers new bundle)
  --> tez_download
  --> Structured context arrives, regardless of network topology
```

No SSH tunnels. No VPN. No shared gateway. No email parsing. The MCP server is the rendezvous point, and DynamoDB is the access control layer.

### D2. Admin Aggregation

The admin PA's current aggregation model depends on `sessions_send` for same-gateway agents and email for everything else. With Tez, aggregation becomes uniform:

```
Admin PA (morning cron):
  1. tez_list(filter="weekly-status-*", since="7d")
  2. For each new status Tez:
     - tez_download
     - Extract key metrics from tez.md
     - Cross-reference with CRM data
  3. Build cross-team synthesis
  4. Optionally: tez_build("cross-team-weekly-w08") and share with all team PAs
```

This replaces the hub-and-spoke CRM-only aggregation model with rich, structured context. The admin PA does not need read access to team CRM instances -- the team PAs curate what goes into their status Tez.

### D3. External Sharing (TIP -- Token-scoped Interrogation)

A future capability of the Tez Protocol: sharing context with external parties (clients, partners, auditors) without giving them full download access.

**How TIP works:**
1. PA builds a Tez with sensitive source material in `context/`
2. PA generates a TIP token scoped to that Tez
3. External party receives a URL with the token
4. They can *interrogate* the Tez (ask questions, get AI-generated answers citing the context) but cannot download the raw source files
5. The token has an expiration, an access count limit, and a scope restriction

**Use cases:**
- Share meeting notes with a client (they can ask "What were the action items?" but cannot download the full recording transcript)
- Share an incident report with a partner (they can ask about impact and remediation, but cannot access internal logs)
- Share a project status with an auditor (they can verify compliance claims, but cannot download source data)

TIP is not needed for Phase A-C. It becomes valuable when the fleet starts interacting with external parties through their PAs.

---

## What NOT to Build Yet

These are capabilities that might seem natural but are premature at current fleet scale:

| Capability | Why Not Yet |
|-----------|-------------|
| **Real-time WebSocket connections between PAs** | The fleet has ~18 PAs. Cron-based polling every 10 minutes handles this scale. WebSockets add connection management, reconnection logic, and state. Build when polling latency becomes a real problem, not a theoretical one. |
| **Multi-writer Tez bundles** | Each Tez has one creator. For collaboration, the creator shares a Tez, the recipient builds a response Tez. This is simpler and preserves clear provenance. Multi-writer introduces merge conflicts, locking, and ownership ambiguity. |
| **Ed25519 signed federation** | The MCP server handles identity via email-based auth and DynamoDB access control. Cryptographic signatures matter when PAs communicate without a trusted intermediary. The current architecture always has a trusted intermediary (the MCP server). |
| **Custom Tez web UI** | The CLI and MCP tools are sufficient for PA-to-PA workflows. PAs do not need a web dashboard. Humans who want to inspect Tez bundles can ask their PA. |
| **Redis TokenStore** | The MCP server uses in-memory token storage. This is fine for a single ECS task serving ~20 PAs. Switch to Redis when scaling to multiple MCP server instances or when token persistence across restarts matters. |
| **Per-team MCP servers** | One server with DynamoDB-based isolation is simpler than N servers with N deployments. Split only if regulatory requirements demand infrastructure-level tenant isolation. |

---

## Key Design Decisions

### 1. One MCP Server for All Teams

A single Tez MCP server on ECS Fargate serves all PAs across all fleets. DynamoDB handles tenant isolation through the `recipients[]` field on each Tez record -- only PAs listed as recipients can download a bundle.

**Why not per-team:** Per-team servers mean N deployments, N sets of credentials, N monitoring dashboards. The security benefit is marginal because access control is in DynamoDB, not the network layer. If Team Alpha's MCP server has a bug, it has the same bug as Team Beta's would.

**When to split:** If a team has regulatory requirements for infrastructure-level data isolation (e.g., healthcare data cannot share a DynamoDB table with non-healthcare data), deploy a separate MCP server for that team.

### 2. CLI on Persistent Volume

The Tez CLI is installed on the host at `/opt/mypa/shared/bin/tez` and bind-mounted read-only into containers. This pattern was adopted after a fleet-wide outage where container upgrades wiped all non-volume binaries from 16 containers simultaneously.

**Rule:** Any binary that a PA depends on must either be part of the base container image or stored on a persistent volume. Never `docker cp` a binary into a running container and expect it to survive.

### 3. Cron-Based Inbox Check

The Tez inbox check runs every 10 minutes via cron. This matches the fleet's existing pattern -- email inbox checks are also cron-based. No new infrastructure (no message queue, no WebSocket server, no push notification service).

**Why 10 minutes and not faster:** The fleet's PAs are not real-time systems. They are asynchronous assistants. A 10-minute check cycle means a shared Tez is processed within 10 minutes -- fast enough for briefings, escalations, and coordination. If a specific PA needs faster response, Option B (Telegram notification) or Option C (webhook) can be enabled for that PA individually.

### 4. Email Identity

PA email addresses (`pa.alice@team.example.com`) are already unique identifiers in the fleet. The Tez Protocol uses these as identity -- no new auth system, no new accounts, no new credentials.

**Why not a separate identity system:** Adding a Tez-specific identity (e.g., Tez usernames, Tez API keys) creates a second identity layer that must be provisioned, rotated, and managed. PA emails already exist, are already unique, and are already managed through the fleet's provisioning workflow.

### 5. Gradual Rollout

Start with one team's PAs. Validate the build/share/download cycle works. Validate the cron-based inbox check delivers bundles reliably. Then expand to cross-team, then cross-fleet.

**Rollout sequence:**
1. Team Alpha PAs only (same droplet, same-team sharing)
2. Team Alpha + Team Beta (cross-team, same droplet)
3. Team Alpha + Team Gamma (cross-team, different droplets)
4. All teams

Each step validates a new network path. Problems surface incrementally.

---

## Success Criteria

The integration is complete when:

- [ ] **Same-fleet exchange:** Two PAs on the same droplet can build, share, and download a Tez bundle end-to-end.
- [ ] **Cross-fleet exchange:** Two PAs on different droplets can build, share, and download a Tez bundle end-to-end.
- [ ] **Team briefing distribution:** A team PA can build a daily briefing Tez, share it with all member PAs, and each member PA automatically downloads and processes it via cron.
- [ ] **Escalation flow:** An individual PA can escalate to its team PA via Tez, and the team PA can triage and optionally forward to other team PAs.
- [ ] **Admin aggregation:** The admin PA can collect status Tez bundles from all team PAs (same and different fleets) and compile a cross-team synthesis.
- [ ] **Email bridge retired for PA-to-PA:** No more `[PA-to-PA]` subject line emails between PAs. Email is reserved for human-facing communication.
- [ ] **No SSH or sessions_send required for cross-PA communication:** The admin PA can coordinate with any PA in the fleet without needing container access or shared-gateway adjacency.
- [ ] **Cron-based delivery under 10 minutes:** A Tez shared at time T is downloaded and processed by the recipient PA by T+10 minutes.
- [ ] **Persistent across upgrades:** Container upgrades and recreations do not break Tez CLI availability or PA identity configuration.

---

## Appendix: Tez Bundle Examples

### Daily Briefing Tez

```
daily-brief-2026-02-23/
  manifest.json
    {
      "id": "daily-brief-2026-02-23",
      "creator": "team-alpha@team.example.com",
      "created": "2026-02-23T06:30:00Z",
      "type": "briefing",
      "recipients": [
        "pa.alice@team.example.com",
        "pa.carol@team.example.com",
        "pa.frank@team.example.com"
      ]
    }
  tez.md
    # Team Alpha Daily Briefing -- February 23, 2026

    ## Calendar
    - 09:00 Sprint planning (all hands)
    - 14:00 Client call: Project Gamma status [see context/crm-updates.md]

    ## CRM Updates
    - 3 new leads added yesterday [see context/crm-updates.md, lines 12-34]
    - Pipeline value increased by $45K

    ## Email Digest
    - Vendor replied re: contract renewal [see context/email-digest.md, item 3]
    - Internal: IT maintenance window Saturday 02:00-06:00

    ## Action Items
    - Alice: Prepare client call deck by 13:00
    - Carol: Follow up on 2 stale leads (>7 days no activity)

  context/
    crm-updates.md
    calendar-summary.md
    email-digest.md
```

### Escalation Tez

```
escalation-api-v2-404/
  manifest.json
    {
      "id": "escalation-api-v2-404",
      "creator": "pa.alice@team.example.com",
      "created": "2026-02-23T11:42:00Z",
      "type": "escalation",
      "urgency": "high",
      "recipients": [
        "team-alpha@team.example.com"
      ]
    }
  tez.md
    # Escalation: API v2 Endpoint Returning 404

    ## Summary
    The `/api/v2/users` endpoint started returning 404 at approximately
    11:30 UTC. This affects the CRM sync pipeline and the client-facing
    status dashboard.

    ## Impact
    - CRM sync: blocked (last successful sync: 11:15 UTC)
    - Status dashboard: showing stale data
    - Estimated affected users: 340

    ## Root Cause (preliminary)
    API v2 deployment at 11:25 UTC appears to have dropped the `/users`
    route. See context/error-logs.txt, lines 45-67.

    ## Proposed Fix
    Pin to API v1 endpoint until v2 migration is validated.
    See context/proposed-fix.md for the specific config change.

  context/
    error-logs.txt
    affected-services.md
    proposed-fix.md
```

---

## Appendix: Relationship to Existing Fleet Components

| Component | Current Role | Role After Tez Integration |
|-----------|-------------|---------------------------|
| `sessions_send` | Same-gateway PA-to-PA (admin agents only) | Unchanged. Still the fastest path for same-gateway communication. Tez supplements, does not replace. |
| Email bridge (`[PA-to-PA]` subject) | All cross-container PA-to-PA | Retired for structured communication. Remains for simple one-line queries and human-facing email. |
| `team-comms` SKILL.md | Teaches email bridge conventions | Updated to teach Tez as primary PA-to-PA channel, email as fallback. |
| `team-router` SKILL.md | Routes instructions via `sessions_send` | Updated to support Tez-based collection for cross-container and cross-fleet PAs. |
| Morning briefing cron | Queries same-gateway agents only | Extended to collect Tez-based briefings from all PAs, regardless of location. |
| Twenty CRM | Per-team data store | Unchanged. CRM data feeds into Tez bundles (e.g., daily briefing includes CRM snapshot), but CRM itself is not replaced. |
| Google Workspace (email) | PA identity + email channel | PA email addresses become Tez identity. Email channel remains for human communication. |

---

*This document describes a planned integration. The Tez Protocol POC exists as working software. The fleet integration described here has not yet been deployed.*
