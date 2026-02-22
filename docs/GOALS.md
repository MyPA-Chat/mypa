# MyPA -- Project Goals

## The User Experience Goal

A new team member should receive a 1Password share link. After opening it, the only
things they need to do themselves are:

1. **Link their Claude subscription** -- mandatory, not optional. The bootstrap API key
   is temporary and expensive. Users must switch to their own Claude Max account.
2. **Set up Telegram** -- create a bot via @BotFather, connect it. The PA walks them
   through it.

That's it. Everything else should already work when they arrive.

## What "Already Works" Means

Before a user is onboarded, the admin must have completed:

- [ ] PA container deployed and healthy (gateway responding)
- [ ] Google Workspace account created (pa.name@team.example.com)
- [ ] Google OAuth credentials injected and tokens generated (`gog auth`)
- [ ] CRM connected (twenty.env configured, API key set)
- [ ] SOUL.md with team context injected
- [ ] IDENTITY.md with the PA's name and role
- [ ] Skills installed (gog, twenty-crm)
- [ ] Caddy route configured with valid TLS cert
- [ ] DNS record pointing to the fleet droplet
- [ ] Gateway token saved in 1Password with onboarding instructions
- [ ] Memory indexing enabled (RAG search)

## The Admin Experience Goal

Once a fleet is deployed, the admin's only ongoing responsibility is:

- **Push updates** to OpenClaw containers as the code and services improve
- **Manage Google Workspace accounts** (create/disable as team changes)
- **Monitor health** (heartbeat, container status)

The admin should NOT need to:
- Touch individual PA configs for routine operations
- Manually intervene in user setup flows
- Debug channel connections (the PA handles its own Telegram setup)

## Key Architecture Principles

1. **The PA has its own identity.** It has its own email (pa.name@team.example.com), its own
   calendar, its own workspace. It is not logged into the user's accounts. Users can
   choose to forward email or share calendars, but the PA operates from its own accounts.

2. **LLM costs are the user's responsibility.** The bootstrap API key gets them started.
   They must migrate to their own Claude Max subscription. The PA will prompt them to do
   this. If they don't, the admin will kill their container.

3. **One CRM per team.** Twenty CRM runs as a single stack (server + postgres + redis)
   per fleet droplet. All team members share it.

4. **No iPhone app dependency.** The iOS app requires a developer account and is not
   publicly available. Users connect via the web UI or Telegram (or any other chat
   channel they connect).

5. **Factory-reproducible.** Every fleet deployment should be reproducible from the
   factory repo. Manifests define teams, deploy scripts build them. No snowflake servers.

## Current Gaps (as of 2026-02-21)

- [x] Google Workspace OAuth -- service account auth configured on 8 of 12 member PAs
- [x] openclaw.json validation errors -- fixed (removed invalid `skills.gog` key)
- [x] RAG memory -- vector search enabled on Team Alpha (8GB droplet); FTS-only on 4GB droplets
      (local embedding model uses ~700MB/container, OOMs on 4GB with 3 PAs + CRM)
- [x] Onboarding instructions -- all 12 1Password items updated with full instructions
- [x] gog CLI installed on all 16 containers, gog skill deployed to all workspaces
- [x] All 16 PA endpoints + 4 CRM endpoints returning 200
- [x] All containers switched to `--network host` (bridge mode + loopback bind = 502)
- [ ] Google Workspace user limit reached (10 accounts on free tier) -- need upgrade to
      create accounts for remaining team members
- [ ] Team PA accounts (team-alpha, team-beta, team-delta, team-gamma) -- no dedicated
      Google Workspace emails; may not need them
- [ ] 4GB droplets should be upgraded to 8GB for vector memory search

## Operational Lessons Learned

1. **Docker networking**: Always use `--network host` for OpenClaw containers. Bridge mode
   with `-p` port mapping fails because the gateway binds to container-internal loopback.
2. **Local embedding model**: The `embeddinggemma-300m` GGUF model uses ~700MB per container.
   On 4GB droplets with 3 PAs + CRM, this causes OOM. Use FTS-only on small droplets.
3. **Google Workspace service account**: Domain-wide delegation works headlessly -- no browser
   needed. Use `gog auth service-account set --key=/path/to/sa.json email@domain` per container.
4. **gog binary not in OpenClaw image**: Must be `docker cp`'d into each container after creation.
   The binary is ~22MB Linux amd64.
5. **openclaw.json skill keys**: Don't put custom keys under `skills.*` -- OpenClaw validates
   the schema and rejects unrecognized keys, which blocks ALL config-dependent commands.
