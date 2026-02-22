# Outbound Data Classification Rules

> **MANDATORY pre-send check.** Before sending ANY data outside the container
> (email, Telegram, API calls, file exports), classify every piece of information
> against these tiers. This file is loaded every session via AGENTS.md.

---

## Tier 1: NEVER SEND (any channel)

Credentials, tokens, API keys, passwords, keyring passwords, OAuth secrets,
SSH keys, gateway tokens, database connection strings, `.env` file contents.

Children's names/existence (if marked PRIVATE). SSNs, bank account numbers,
credit card numbers, government IDs.

**Action:** Block entirely. No exceptions. If a task requires sending these,
refuse and explain why. The human must handle credential transfer directly.

---

## Tier 2: NEVER via email or unencrypted channel

Home addresses, family members' contact details (emails, phone numbers),
personal financial details (income, MRR, debt, compensation),
employee compensation details, vendor contract terms with dollar amounts,
health information, legal matters.

**Action:** These may only be shared via encrypted channel (e.g., Tailscale-gated
endpoint, encrypted file, or in-person). Never in email, Telegram, or any channel
that transits the public internet in plaintext.

---

## Tier 3: Redact or summarize before sending

Internal infrastructure details (IP addresses, port numbers, security config),
full CRM data dumps, vendor contract terms (without dollar amounts),
full flight itineraries with confirmation codes, complete contact lists.

**Action:** Summarize to the minimum needed. "Meeting in Philadelphia Feb 17-20"
not the full itinerary with flight numbers and confirmation codes. "CRM has 5
companies and 12 contacts" not the full dump.

---

## Tier 4: OK to send

Meeting times and general calendar info, task status updates, public company
information, general project updates, information the recipient already knows,
anything the owner has explicitly approved for that recipient.

**Action:** Send freely.

---

## How to Apply

Before composing any outbound message:
1. List every piece of data you're about to include
2. Classify each item against the tiers above
3. Remove or redact anything Tier 1-3
4. If the message becomes meaningless without Tier 2-3 data, tell the owner
   what you can't send and ask them to handle it directly
5. When in doubt, classify UP (treat as more sensitive)

## Special Cases

- **Handoff documents**: Always Tier 3+ items must be scrubbed before sending
- **Briefing emails to owner**: Tier 4 freely. Tier 3 summarized. Tier 2 only if
  the email is to the owner's own trusted address. Tier 1 never.
- **Emails to third parties**: Tier 4 only unless owner explicitly approves
- **CRM notes**: Tier 3 data can be stored in CRM (it's internal), but never
  exported in bulk via email
