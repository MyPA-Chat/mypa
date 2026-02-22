# team-router

> Route instructions to team sub-agents and orchestrate team lifecycle from the master PA.

## Commands

### `/team <name> <instruction>`

Route an instruction to a specific team's sub-agent.

When the user says `/team <name> <instruction>`:
1. Look up the agent ID for that team name. Agent IDs follow the pattern `admin-<teamname>` (lowercase, hyphens for spaces). If the team name is ambiguous, list available teams and ask the user to clarify.
2. Use `sessions_send` to forward the instruction to that agent.
3. Wait for the agent's response.
4. Present the response to the user, prefixed with the team name in bold.

Examples:
- `/team alpha Check the CRM for recent updates` → sessions_send to agent `admin-alpha`
- `/team beta What's on tomorrow's calendar?` → sessions_send to agent `admin-beta`
- `/team acme-corp Update contact John Smith, add note: met at conference` → sessions_send to agent `admin-acme-corp`

### `/teams status`

Get a brief status from every team sub-agent.

When the user says `/teams status`:
1. Get the list of all agents using `sessions_list`.
2. For each agent that is NOT `admin-personal` (i.e., each team sub-agent):
   a. Use `sessions_send` to ask: "Brief status — what's active today? 2-3 bullet points max."
   b. Collect the response.
3. Compile all responses into a unified summary, grouped by team name.
4. Present to the user.

If any agent fails to respond within 30 seconds, note it as "[Team X: no response]" and continue with the others.

### `/teams briefing`

Compile a full cross-team morning briefing.

When the user says `/teams briefing`:
1. For each team sub-agent:
   a. sessions_send: "Morning briefing for today. Include: key meetings, deadlines, CRM updates, any urgent items."
   b. Collect the response.
2. Check the personal agent's own email and calendar.
3. Compile everything into the standard briefing format:

```
CROSS-TEAM BRIEFING — [date]

PERSONAL
- Email: [summary of personal inbox]
- Calendar: [today's personal events]

TEAM ALPHA
- [briefing from admin-alpha]

TEAM BETA
- [briefing from admin-beta]

[...additional teams...]

ACTION ITEMS
- [anything requiring immediate attention, across all teams]

CONFLICTS
- [any scheduling overlaps or cross-team resource conflicts]
```

### `/team new <business-name>`

Initiate the provisioning workflow for a new team/business.

When the user says `/team new <name>`:
1. Acknowledge the request and explain what's needed.
2. Ask the user for:
   - Business/team display name (e.g., "Acme Corp")
   - Team members (names and emails) — or "just me for now"
   - Any specific CRM workspace needs
3. Generate the following artifacts and present them to the user:

**a) Sub-agent configuration block** (to be added to the admin gateway's openclaw.json):
```jsonc
{
  "id": "admin-<team-slug>",
  "name": "<Business Name>",
  "workspace": "~/.openclaw/workspace-<team-slug>"
}
```

**b) Binding entry:**
```jsonc
{ "agentId": "admin-<team-slug>", "match": { "channel": "telegram", "accountId": "<team-slug>" } }
```

**c) Telegram account entry:**
```jsonc
"<team-slug>": { "botToken": "${ROB_<TEAM_SLUG>_BOT_TOKEN}" }
```

**d) SOUL.md draft** for the new team sub-agent, using the admin SOUL template but scoped to the new business.

**e) Team member PA provisioning checklist:**
```
MANUAL STEPS (admin must complete):
[ ] Create Telegram bot via @BotFather: @admin_<slug>_pa_bot
[ ] Add bot token to gateway env: ADMIN_<SLUG>_BOT_TOKEN=<token>
[ ] Create Google Workspace account: admin-pa-<slug>@yourdomain.com
[ ] Add agent block to admin gateway openclaw.json
[ ] Restart admin gateway (agentToAgent allow: ["*"] auto-allows new agents)
[ ] Pair with new Telegram bot

FOR EACH TEAM MEMBER:
[ ] Create Telegram bot: @<member>_<slug>_pa_bot
[ ] Create Google Workspace account: <member>pa-<slug>@yourdomain.com
[ ] Run: ./scripts/provision-pa.sh --name "<member>-<slug>-pa" \
      --member "<Member Name>" --team "<Business Name>" \
      --email "<member>pa-<slug>@yourdomain.com" \
      --telegram-token "<token>" --type "member"
```

4. After presenting all artifacts, ask: "Ready to proceed? Complete the manual steps above, then tell me when the gateway is restarted and I'll verify the new team agent is online."

5. Once the user confirms the gateway is restarted:
   a. Use `sessions_list` to verify the new agent appears.
   b. Use `sessions_send` to the new agent: "Hello, confirm you are online and identify yourself."
   c. Report the result to the user.

### `/team remove <name>`

Decommission a team sub-agent.

When the user says `/team remove <name>`:
1. Confirm with the user: "This will remove the <name> team agent. Team member PAs will continue running independently. Confirm?"
2. If confirmed, generate the removal checklist:
```
REMOVAL STEPS:
[ ] Remove agent block from admin gateway openclaw.json
[ ] Remove binding entry
[ ] Remove Telegram account entry
[ ] Restart admin gateway
[ ] Archive workspace: ~/.openclaw/workspace-<slug>
[ ] Revoke Telegram bot token via @BotFather
[ ] Suspend Google Workspace PA account
[ ] Update cross-team briefing cron (if hardcoded team list)
```

### `/teams list`

List all active team sub-agents.

When the user says `/teams list`:
1. Use `sessions_list` to get all agents.
2. For each agent that is NOT `admin-personal`, display:
   - Agent ID
   - Team name
   - Status (responding / not responding — test with a quick sessions_send ping)

## Notes

- This skill runs ONLY on the master PA (admin-personal agent).
- All `/team` commands use `sessions_send`, which works because all admin agents share one gateway.
- The `/team new` command generates config artifacts but does NOT modify files — the admin must apply changes manually and restart the gateway. This is intentional: config changes should be deliberate, reviewed, and committed to git.
- Team member PAs (Alice, Bob, etc.) run in separate Docker containers managed by `pactl` and cannot be reached via `sessions_send`. Use the email bridge for admin→team-member-PA communication.
