# Building MyPA: Part 3 — Fleet Hardening, Tezit Deployment, and Going Mobile

> **Continues from:** [BUILD_LOG_2.md](BUILD_LOG_2.md)
>
> **Date:** 2026-02-23 to 2026-02-24
>
> **Context:** Part 2 ended with 18 PAs running across 5 droplets, Telegram working for the first fleet, and the admin PA (Admin-PA) managing operations from a dedicated server. This part covers the infrastructure hardening sprint: upgrading every container, scaling compute, deploying encrypted communications fleet-wide, building a native iOS app, and the lessons from each.

---

## The Fleet Upgrade: v2026.2.21 → v2026.2.22-2

### The wrong approach first

The OpenClaw CLI has an `openclaw update --yes` command. We tried it on Admin-PA's container first. It returned: `SKIPPED: not-git-install`. The Docker container doesn't have a git checkout of OpenClaw — it's a bundled Node.js app. The `update` command only works for development installs.

**Second attempt:** `pnpm add openclaw@2026.2.22-2` inside the container. This installed the package... as a nested dependency under `/app/node_modules/openclaw/`. But `/app` IS OpenClaw. The root package at `/app` stayed at v2026.2.21. Adding the package to itself just puts it in node_modules — doesn't replace the running code.

**The correct approach:** Docker image. `ghcr.io/openclaw/openclaw:2026.2.22` is the official image. Pull it, recreate the container with the same bind mounts, same port, same config.

```bash
docker pull ghcr.io/openclaw/openclaw:2026.2.22
docker stop <container> && docker rm <container>
docker run -d --name <container> --hostname <hostname> --network host \
  --restart unless-stopped \
  -e OPENCLAW_PREFER_PNPM=1 -e NODE_ENV=production \
  -v /opt/mypa/agents/<name>/data:/home/node/.openclaw \
  ghcr.io/openclaw/openclaw:2026.2.22 node openclaw.mjs gateway
```

### The image change nobody warned us about

v2026.2.22 switched the base image from Alpine to Debian bookworm. This means:
- `apk` commands no longer work (use `apt-get`)
- Chromium package name and installation changed
- All in-container-layer customizations are gone (new image = clean slate)

Everything bind-mounted survived (config, data, workspace). Everything installed inside the container layer did not (Chromium, mcporter, any `npm -g` installs).

### The fleet-wide rollout

Test on Admin-PA first. Verified working. Then rolled out to all 16 fleet PAs across 4 droplets. Inspected each container's bind mounts via `docker inspect`, recreated with identical configs.

**Problem:** On the 2-vCPU droplets (Team Beta, Team Delta), recreating 3 containers simultaneously caused all 3 gateways to do first-run initialization at the same time. CPU pegged at 99%. SSH became unresponsive. The droplets recovered after ~5 minutes when initialization completed, but during that window we couldn't verify or fix anything.

**Lesson:** Stage container recreations on low-spec machines. Start one, wait for initialization to complete (watch CPU in DO dashboard), then start the next. Gateway startup is CPU-intensive — budget for it.

### The container recreation checklist

After recreation, every container needed:

1. `apt-get install chromium` — browser support (Debian package, not Alpine)
2. `npm install -g mcporter` — MCP client CLI
3. Write `/home/node/.mcporter/mcporter.json` — MCP server config
4. Verify gateway is responding at assigned port

Items 1-3 are in the container layer and WILL be lost on next recreation. This is technical debt — the right fix is either a custom Docker image or init scripts in the bind-mounted data volume.

---

## Compute Scaling: 2vCPU → 4vCPU

The CPU saturation during fleet rollout exposed a real constraint: 2-vCPU droplets can't handle 3 simultaneous gateway startups. Under normal operation they're fine, but any maintenance event (upgrade, restart) risks making the droplet unresponsive.

Resized Team Beta, Team Delta, and Team Gamma droplets from 2vCPU/4GB to 4vCPU/8GB. DigitalOcean resize requires shutdown → resize → power-on. Each took about 3 minutes.

After resize, all gateways started cleanly and the droplets stayed responsive during the startup spike.

---

## RAG Memory: Fleet-Wide Enablement

OpenClaw v2026.2.22 includes local RAG memory — the PA can search its own conversation history and stored memories during responses. This was disabled by default.

Enabled on all 18 PAs with:

```json
{
  "memorySearch": {
    "enabled": true,
    "provider": "local",
    "sources": ["memory", "sessions"],
    "experimental": { "sessionMemory": true }
  }
}
```

Injected into each container's `openclaw.json` via `python3 -c "import json; ..."` (not `echo` — shell escaping mangles JSON inside nested SSH/docker exec chains, learned this the hard way with mcporter config).

**Lesson:** Never write JSON via `echo` through SSH + docker exec. The quote stripping across two shell layers turns `{"key":"value"}` into `{key:value}` which isn't valid JSON. Use `python3 -c "import json; json.dump(config, open(path, 'w'))"` — Python handles its own quoting.

---

## Tezit Protocol: Fleet-Wide Deployment

### Background

Tezit is an encrypt-at-source protocol for PA-to-PA communication. Content is encrypted before leaving the sender, keys are held on a relay server, and destroying the key makes all copies of the content unreadable — worldwide delete.

Phase 14-15 (in Part 1) deployed Tezit to one fleet (Team Alpha) plus Admin-PA. This phase extended it to all 5 droplets.

### Image transfer without direct droplet SSH

The tez-mcp Docker image existed on the Team Alpha droplet. The other droplets needed it too. Direct SCP between droplets failed — no SSH keys between them.

**Solution:** Pipe through the admin workstation.

```bash
# Export from source, pipe through local machine, import on target
ssh source 'docker save tez-mcp:latest | gzip' | ssh target 'gunzip | docker load'
```

70MB image, ~30 seconds per transfer. Not elegant, but it works. Did this for 3 target droplets.

### The deployment per droplet

Each droplet needed:
1. **tez-mcp container** — Python/FastAPI MCP server on port 8100, localhost only
2. **mcporter** on every PA container — CLI bridge between PA and MCP server
3. **mcporter.json** — config pointing to `http://127.0.0.1:8100/mcp`
4. **tez skill** — teaches each PA when and how to use the 9 tez tools

The tez-mcp containers were straightforward Docker runs with environment variables for relay URL, auth secret, and storage quota.

**Problem:** mcporter.json shell escaping (again). Wrote a deployment loop that used `python3` instead of `echo` to write the JSON — lesson learned from the RAG config deployment.

**Problem:** On one droplet, a tez-mcp container already existed from a previous test. `docker run --name tez-mcp` failed with "name already in use." Had to `docker rm -f tez-mcp` first.

### Verification

`mcporter call tez.check_storage` and `mcporter call tez.check_relay` on every PA across all 5 droplets. All returned healthy. 9 tools visible on each.

| Component | Droplets | Status |
|-----------|----------|--------|
| tez-relay | 1 (dedicated) | Running |
| tez-mcp | 5 (all fleet + admin) | Running |
| PAs with tez | 18 (all) | Tools accessible |

---

## Credential Isolation: Git Access Without Exposure

### The problem

Admin-PA needed GitHub access to clone repos and push code. But we didn't want the PA to be able to see or exfiltrate the token — it should be available to `git` but not readable from the PA's workspace or environment.

### The solution: system-level git config

```bash
# System git config (root-owned, not in PA workspace)
git config --system credential.helper 'store --file=/etc/git-credentials'
git config --system user.name "Admin-PA"
git config --system user.email "admin@example.com"

# Credential file (root:node 440 — readable by git process, not writable)
echo "https://user:TOKEN@github.com" > /etc/git-credentials
chmod 440 /etc/git-credentials
chown root:node /etc/git-credentials
```

The PA runs as `node` user. The credential file is owned by `root` with group `node` read access (440). The git process (running as `node`) can read it via the credential helper. But the PA can't `cat /etc/git-credentials` because it's not in the workspace, and `env` won't show it because it's not an environment variable.

### Organization blocking

We also needed to block access to a specific GitHub organization — the PA shouldn't be able to read or push to repos in that org.

```bash
git config --system --add url."https://BLOCKED.invalid/".insteadOf "https://github.com/blocked-org/"
git config --system --add url."https://BLOCKED.invalid/".insteadOf "git@github.com:blocked-org/"
```

Any `git clone/push/pull` targeting that org gets redirected to a dead domain. The PA can work freely with all other orgs.

**Gotcha:** Two `git config --system` calls to the same key overwrite each other. Use `--add` for the second pattern, not just `set`.

---

## The iOS App: From Zero to Fleet Chat in 4 Hours

### Why not the official app?

The official OpenClaw iOS app is in internal preview — not publicly distributed. With an Apple Developer account, the alternative is building from source.

### Finding the right codebase

The OpenClaw GitHub org has `casa` (a HomeKit bridge, not the chat app). The iOS chat app codebase isn't public. Community alternatives exist — we found a clean SwiftUI implementation: multi-agent chat with SSE streaming, ~350 lines of Swift, zero third-party dependencies.

### Security audit before installation

Before putting any third-party code on a phone, we audited every file:

| Check | Result |
|-------|--------|
| Third-party dependencies | Zero (no SPM, CocoaPods, Carthage) |
| Tracking/analytics | None |
| Network destinations | Only user-configured gateway URL |
| Permissions requested | Local network only (justified) |
| Background activity | None |
| Build scripts | Standard compile only |
| Obfuscated code | None |

**Verdict:** Clean. The app talks exclusively to whatever gateway URL you configure, stores conversation history in the iOS sandbox, and does nothing when backgrounded.

### The architectural mismatch

The community app was built for a single gateway with multiple agents (tabs for different agent personas on the same server). Our fleet has 18 PAs, each on their own gateway at their own URL with their own auth token.

**Changes required:**
1. **Agent model** — added `gatewayURL` and `team` fields. Each PA is its own agent with its own URL.
2. **Settings** — per-agent token storage instead of single global token.
3. **Gateway service** — accepts URL + token per request instead of a global config.
4. **Navigation** — replaced tab bar (can't fit 18 tabs) with a sidebar list grouped by team.
5. **Token pre-population** — pulled auth tokens from all 18 PA containers, embedded as first-launch defaults.

### The build error

First build failed: `Cannot code sign because the target does not have an Info.plist file`. The project uses XcodeGen to generate the Xcode project from a `project.yml`. Adding `GENERATE_INFOPLIST_FILE: "YES"` to the build settings and regenerating fixed it.

The only remaining error was code signing — selecting the developer team in Xcode's UI, which can't be done from CLI.

### Distribution

With a paid Apple Developer account ($99/year), the app can be distributed via TestFlight to up to 10,000 testers. Each team gets a version with only their PAs visible. The admin gets the full fleet view.

---

## Telegram Expansion: New Teams Go Live

### The pattern that works

After establishing the Telegram pairing flow in Part 2, extending to new teams followed a clean pattern:

1. **User creates bot** via @BotFather — gets a bot token
2. **Admin injects token** via `openclaw channels add --channel telegram --token <TOKEN>`
3. **User messages bot** — gets a pairing code
4. **Admin approves** via `openclaw pairing approve telegram <CODE>`

The v2026.2.22 CLI made step 2 much cleaner — `channels add` handles config modification and validation, versus the manual JSON injection we used in Part 2.

### Pairing code expiration

**Problem:** Pairing codes expire quickly (< 2 minutes). If the admin isn't watching for the code in real time, it expires and the user has to message the bot again. This happened twice during onboarding — by the time the admin ran the approve command, the code was gone.

**Mitigation:** The admin runs a polling loop that auto-approves the moment a request appears:

```bash
for i in $(seq 1 12); do
  pending=$(docker exec <container> openclaw devices list | grep -A5 "Pending")
  if [ -n "$pending" ]; then
    reqid=$(echo "$pending" | grep -oE '[0-9a-f-]{36}')
    docker exec <container> openclaw devices approve "$reqid"
    break
  fi
  sleep 5
done
```

Not elegant, but eliminates the timing race.

### Device pairing vs Telegram pairing

OpenClaw has TWO pairing systems:
- **Device pairing** (`devices list/approve`) — for web UI and API access. Uses request IDs.
- **Telegram pairing** (`pairing list/approve`) — for Telegram DM access. Uses pairing codes.

The web UI shows "pairing required" when it needs device pairing, not Telegram pairing. This confused us initially — running `pairing approve` when the UI needed `devices approve`.

---

## Lessons From This Sprint

### On container orchestration

**The Docker image IS the deployment unit, not the container.** In-place updates (`openclaw update`, `pnpm add`) don't work for Docker deployments. Pull the new image, recreate the container with the same mounts. Everything in the container layer is ephemeral. Everything you need to survive must be bind-mounted.

**Container recreation is a multi-step process.** The OpenClaw gateway image is minimal — no browser, no additional tools. Post-creation setup (Chromium, mcporter, etc.) is required and will be lost on next recreation. Track this in a checklist. Better yet, build a custom image or use init scripts.

### On fleet operations at scale

**Don't hot-deploy on constrained hardware.** Gateway initialization is CPU-intensive. Three simultaneous startups on a 2-vCPU box will saturate the CPU and make SSH unresponsive. Stage deployments: one container at a time, verify each before starting the next.

**Shell escaping breaks at depth 2.** `ssh host 'docker exec container echo "json"'` strips one layer of quotes. The JSON arrives malformed. Always use a language runtime (Python, Node) to write structured data inside containers.

### On security boundaries

**Git credential isolation works with system-level config.** The credential helper reads from a root-owned file, the PA process can trigger git operations, but can't directly read the token. This is defense in depth — the Docker container is the primary boundary, the file permissions are the secondary.

**Organization blocking via URL rewriting is effective.** `url.insteadOf` redirects at the git protocol level. The PA can't accidentally or intentionally interact with blocked orgs. No network-level firewall rules needed.

### On mobile deployment

**Audit third-party code before installation.** Even a "simple" iOS app could phone home, track analytics, or exfiltrate data. The security audit took 20 minutes and confirmed zero dependencies, zero tracking, and gateway-only network access. Worth every minute.

**Community implementations can be better than official ones.** The official iOS app is unreleased. The community version was functional, auditable, and customizable. The modification from single-gateway to multi-gateway took about an hour.

---

*Last updated: 2026-02-24*
