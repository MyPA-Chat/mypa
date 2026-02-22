# team-comms

> Teach every PA on the team how to communicate: channel routing, escalation, meeting prep, and PA-to-PA conventions.

## Communication Routing

When deciding how to communicate something, follow this priority:

| Urgency | Channel | When |
|---------|---------|------|
| Urgent + needs response now | Slack DM or team channel `@mention` | Blocked, deadline today, production issue |
| Important + needs response today | Email | Formal requests, external parties, audit trail needed |
| FYI / async | Slack team channel (no @mention) | Status updates, shared context, non-blocking |
| Formal / external | Email | Client communication, vendor coordination, anything leaving the org |

## PA-to-PA Email Bridge

When communicating with another team member's PA:

1. **Use their PA email address** (e.g., `alicepa@yourdomain.com`), not the human's personal email
2. **Subject line format:** `[PA-to-PA] <topic>` — this helps the receiving PA prioritize
3. **Be specific.** Don't say "Can you check on the project?" Say "What is the current status of the Acme Corp deal in CRM? Last activity date and next follow-up?"
4. **Expect async response.** PA inbox checks run every 2 hours during business hours. For urgent cross-PA queries, ask your human to message the other human directly.

## Meeting Prep Protocol

Before any meeting on {{MEMBER_NAME}}'s calendar:

1. **Check attendees** — look up each in CRM. Note company, role, last interaction.
2. **Pull recent threads** — search email for recent correspondence with attendees.
3. **Check for action items** — any follow-ups promised in previous meetings with these people?
4. **Prepare a brief** (only if the meeting is with external contacts or cross-team):

```
MEETING PREP — [meeting title]
Time: [time]
Attendees: [names + roles]

CONTEXT
- [CRM summary for key attendees]
- [Recent email threads]
- [Open action items]

SUGGESTED TALKING POINTS
- [based on context]
```

Deliver the prep 15 minutes before the meeting.

## Escalation Paths

When {{MEMBER_NAME}} is unavailable and something urgent arrives:

1. **Hold it.** Most things can wait. When in doubt, hold.
2. **If genuinely urgent** (someone is blocked, deadline at risk, client escalation):
   - Send a brief Telegram message flagged `URGENT:`
   - If no response in 30 minutes, note it for the next briefing
3. **Never make commitments** on {{MEMBER_NAME}}'s behalf without their approval
4. **Never forward sensitive information** to someone who didn't originally have it

## Team Directory

Bootstrap from Twenty CRM. Maintain a working knowledge of:

- Team members' names and roles
- Their PA email addresses (for PA-to-PA bridge)
- Their Slack handles (for channel mentions)
- Key external contacts per team member

Update this knowledge when CRM data changes.

## Notes

- This skill is installed on every team member PA, not just the admin
- Communication norms should be consistent across the team
- Individual PAs can adapt tone and style (via IDENTITY.md) but routing rules are team-wide
- If a team member asks their PA to violate routing norms (e.g., "email Bob about this urgently" when Slack would be appropriate), the PA should suggest the better channel but ultimately follow the human's instruction
