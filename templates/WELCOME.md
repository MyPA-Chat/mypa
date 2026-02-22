# Welcome to Your Personal AI

You have a private AI assistant — your PA. It has its own email address, its own
calendar, and its own workspace. It can draft and send email on your behalf (from its
own address), manage your team's CRM, do research, and remember context between
conversations. The more you use it, the better it gets.

---

## Getting Started

### Connect to Your PA

Open **{{PA_URL}}** in any browser. You'll see the OpenClaw web interface.

1. Click **Overview** in the left menu
2. Paste your **Gateway Token** (from your 1Password item) into the token field
3. Click **Connect**

You're in. Your PA is live and ready to talk.

### Link Your Claude Subscription (Required)

Your PA currently runs on a shared API key. **You must switch to your own Claude Max
subscription.** This is not optional — the shared key is temporary and will be removed.

1. Go to [claude.ai](https://claude.ai) and sign up for **Claude Max** ($20/month)
2. Ask your PA: *"Help me link my Claude account"*
3. Your PA will give you a URL to visit — log in with your Claude account
4. Once linked, your PA runs entirely on your subscription

**Why this matters:** Privacy (your conversations stay on your account), reliability
(no shared rate limits), and cost (the team isn't paying for your usage).

> You can also add other AI providers (OpenRouter, etc.) if you want access to
> additional models. Ask your PA for help setting those up.

### Set Up Telegram (Recommended)

Telegram lets you message your PA from your phone without opening a browser. This is
the fastest way to interact day-to-day.

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts to create your bot
3. Copy the bot token BotFather gives you
4. Tell your PA: *"I have my Telegram bot token: [paste token]"*
5. Your PA will connect the channel and confirm
6. Open your new bot in Telegram and send a message — your PA will respond

**Pairing:** The first time you message your PA on a new channel, it may ask you to
confirm the connection in the web interface. This is a one-time security step.

---

## What Your PA Can Do

### Email
Your PA has its own email address (**{{PA_EMAIL}}**). It can send and receive email
independently. You can:
- Ask it to draft and send emails (from its address, on your behalf)
- Forward your own emails to it for processing or follow-up
- Have it monitor its inbox and flag anything important

*"Draft an email to sarah@example.com about the Q1 proposal and send it"*
*"Check your inbox for anything from the client this week"*

### Calendar
Your PA has its own calendar. You can share your calendar with it (via Google Workspace
sharing) so it can see your schedule. It can also create events on its own calendar and
invite you.

*"What's on my calendar this week?"* (if you've shared your calendar)
*"Set up a meeting with the team for Thursday at 3pm"*

### CRM
Your team shares a CRM at **{{CRM_URL}}**. Your PA can look up companies, contacts,
and deals, log notes, and update records.

*"What's the status of the Acme deal?"*
*"Add a note to Sarah's contact record: discussed pricing on today's call"*

### Memory
Your PA keeps notes between sessions. It writes daily logs and maintains long-term
memory about your preferences, projects, and decisions. It also has semantic search
across everything in its workspace — it can find context from weeks ago.

*"Remember that I prefer async updates over meetings"*
*"What did we discuss about the product launch last week?"*

### Research & Writing
Your PA can search the web, read documents, analyze data, and draft content. Give it
background tasks and check back later.

*"Research [topic] and write up a one-page summary"*
*"Prepare briefing notes for my call with [company] tomorrow"*

### Git
Your PA has git access and can work with code repositories — clone, read, commit, and
push (with your approval).

---

## Daily Patterns That Work Well

**Morning:** *"What do I need to know today?"* — PA checks calendar, flags emails,
surfaces anything relevant.

**Email triage:** *"Summarize your unread emails and tell me which need attention"*

**Meeting prep:** *"I have a call with [company] in an hour — pull together context"*

**Background work:** *"Research [topic] and have a summary ready by end of day"*

**End of day:** *"Log what happened today"* — PA captures context for tomorrow.

---

## Quick Reference

| | |
|---|---|
| **Web interface** | {{PA_URL}} |
| **PA's email** | {{PA_EMAIL}} |
| **Team CRM** | {{CRM_URL}} |
| **Telegram** | Set up via your PA (see above) |
| **Claude Max** | [claude.ai](https://claude.ai) — $20/month |

---

## Getting Help

Ask your PA. It knows its own capabilities and will be honest about what's set up and
what isn't. Good first questions:

- *"What can you do?"*
- *"What's your email address?"*
- *"Walk me through [anything]"*
