# MyPA Fleet Operations Guide

Repeatable procedures for maintaining, upgrading, and troubleshooting PA fleet deployments. No secrets — use `op` CLI for all credentials.

---

## Container Architecture

Each PA runs in a Docker container with three bind-mounted volumes:

```
/opt/mypa/agents/<name>/data          → /home/node/.openclaw     (config + workspace)
/opt/mypa/shared/bin/gog              → /usr/local/bin/gog       (Google Workspace CLI, read-only)
/opt/mypa/agents/<name>/gogcli-config → /home/node/.config/gogcli (gog auth per PA)
```

**Critical rule:** Anything not on a bind-mounted path is destroyed on container recreation. Never rely on `docker cp` for persistent state.

---

## Upgrading OpenClaw

### Pre-flight

```bash
# Check current version
docker exec <name> node /app/openclaw.mjs --version 2>/dev/null || \
  docker inspect <name> --format '{{.Config.Image}}'

# Check latest release
curl -s https://api.github.com/repos/openclaw/openclaw/releases/latest | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])"
```

### Per-Container Upgrade

```bash
NAME="pa-example"
NEW_IMAGE="ghcr.io/openclaw/openclaw:2026.2.21"

# 1. Pull new image
docker pull $NEW_IMAGE

# 2. Stop and remove old container
docker stop $NAME && docker rm $NAME

# 3. Start with new image (PRESERVE ALL BIND-MOUNTS)
docker run -d --name $NAME --restart unless-stopped \
  --network host \
  -v /opt/mypa/agents/$NAME/data:/home/node/.openclaw \
  -v /opt/mypa/shared/bin/gog:/usr/local/bin/gog:ro \
  -v /opt/mypa/agents/$NAME/gogcli-config:/home/node/.config/gogcli \
  $NEW_IMAGE node openclaw.mjs gateway

# 4. Verify
sleep 30
PORT=$(python3 -c "import json; print(json.load(open('/opt/mypa/agents/$NAME/data/openclaw.json'))['gateway']['port'])")
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/
```

### 4GB Droplet Upgrade (3 containers)

**Must start containers sequentially.** Simultaneous initialization causes OOM on 4GB droplets.

```bash
NEW_IMAGE="ghcr.io/openclaw/openclaw:2026.2.21"
docker pull $NEW_IMAGE

# Stop all at once (safe)
for NAME in pa-first pa-second pa-team; do
  docker stop $NAME && docker rm $NAME
done

# Start ONE AT A TIME with 90-second gaps
for NAME in pa-first pa-second pa-team; do
  docker run -d --name $NAME --restart unless-stopped \
    --network host \
    -v /opt/mypa/agents/$NAME/data:/home/node/.openclaw \
    -v /opt/mypa/shared/bin/gog:/usr/local/bin/gog:ro \
    -v /opt/mypa/agents/$NAME/gogcli-config:/home/node/.config/gogcli \
    $NEW_IMAGE node openclaw.mjs gateway
  echo "Started $NAME, waiting 90s..."
  sleep 90
done
```

### 8GB Droplet Upgrade (7+ containers)

Simultaneous starts are fine on 8GB. Can start all at once.

### Recovery from OOM

If a 4GB droplet becomes unreachable after starting too many containers:

```bash
# Power-cycle via DO API
doctl compute droplet-action power-cycle <droplet-id>

# Wait for reboot
sleep 60

# SSH in and start containers one at a time
ssh root@<IP> 'docker start pa-first && sleep 90 && docker start pa-second && sleep 90 && docker start pa-team'
```

---

## Adding a New PA to an Existing Fleet

### 1. Create data directory

```bash
NAME="pa-newmember"
PORT=3036  # next available in 5-apart sequence
TOKEN=$(openssl rand -hex 16)

mkdir -p /opt/mypa/agents/$NAME/data
mkdir -p /opt/mypa/agents/$NAME/gogcli-config
```

### 2. Fix ownership

```bash
docker run --rm --user root \
  -v /opt/mypa/agents/$NAME/data:/data \
  ghcr.io/openclaw/openclaw:2026.2.21 chown -R 1000:1000 /data
```

### 3. Onboard

```bash
BOOTSTRAP_KEY="<from op CLI>"

docker run --rm \
  -v /opt/mypa/agents/$NAME/data:/home/node/.openclaw \
  ghcr.io/openclaw/openclaw:2026.2.21 node openclaw.mjs onboard \
  --non-interactive --accept-risk \
  --auth-choice apiKey --anthropic-api-key "$BOOTSTRAP_KEY" \
  --gateway-auth token --gateway-token "$TOKEN" \
  --gateway-port $PORT --gateway-bind loopback \
  --skip-channels --no-install-daemon --skip-skills --skip-ui
```

Note: The "gateway closed (1006)" error at the end is informational, not a failure.

### 4. Deploy workspace files

```bash
# Copy team SOUL.md + any knowledge base docs
cp /path/to/team/SOUL.md /opt/mypa/agents/$NAME/data/workspace/SOUL.md
cp /path/to/team/IDENTITY.md /opt/mypa/agents/$NAME/data/workspace/IDENTITY.md
# ... any team-specific knowledge files

chown -R 1000:1000 /opt/mypa/agents/$NAME/data/workspace/
```

### 5. Start container

```bash
docker run -d --name $NAME --restart unless-stopped \
  --network host \
  -v /opt/mypa/agents/$NAME/data:/home/node/.openclaw \
  -v /opt/mypa/shared/bin/gog:/usr/local/bin/gog:ro \
  -v /opt/mypa/agents/$NAME/gogcli-config:/home/node/.config/gogcli \
  ghcr.io/openclaw/openclaw:2026.2.21 node openclaw.mjs gateway
```

### 6. Configure gog (if PA has a Google Workspace account)

```bash
docker cp /tmp/sa.json $NAME:/tmp/sa.json
docker exec $NAME gog auth service-account set --key=/tmp/sa.json pa.name@domain.com
docker exec $NAME rm /tmp/sa.json
```

### 7. Add Caddy route + DNS

```bash
# Add to /etc/caddy/Caddyfile:
#   newmember.team.example.com {
#       reverse_proxy 127.0.0.1:$PORT
#   }

caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy

# Add DNS
vercel dns add team.example.com "newmember" A <DROPLET_IP>
```

---

## Port Assignment

Ports use a 5-apart sequence to avoid relay port collisions (gateway uses `port` and `port+3` internally):

```
3001, 3006, 3011, 3016, 3021, 3026, 3031, 3036, 3041, ...
```

Formula: `3001 + (index * 5)` where index starts at 0.

Twenty CRM always uses port 3100 (outside the PA port range).

---

## Team-Specific Knowledge Injection

Pattern for giving PAs deep domain knowledge:

### 1. Create knowledge files

- `[COMPANY]_KNOWLEDGE.md` — Products, services, competitors, key stats
- `[ROLE]_PLAYBOOK.md` — Methodology, scripts, workflows, objection handling
- Update `SOUL.md` to reference these: "Read [COMPANY]_KNOWLEDGE.md at the start of every session"

### 2. Deploy to all team PAs

```bash
for NAME in pa-member1 pa-member2 pa-team; do
  WS="/opt/mypa/agents/$NAME/data/workspace"
  cp COMPANY_KNOWLEDGE.md "$WS/"
  cp ROLE_PLAYBOOK.md "$WS/"
  cp SOUL.md "$WS/"
  chown -R 1000:1000 "$WS/"
done
```

### 3. Reindex memory (8GB droplets only)

```bash
for NAME in pa-member1 pa-member2 pa-team; do
  docker exec $NAME node openclaw.mjs memory index --force 2>&1 &
done
wait
```

No container restart needed — PAs read workspace files at session start.

---

## Deploying a New Fleet Droplet

### 1. Create droplet

```bash
doctl compute droplet create mypa-teamname-fleet \
  --image ubuntu-24-04-x64 \
  --size s-2vcpu-4gb \
  --region nyc1 \
  --ssh-keys <YOUR_KEY_ID> \
  --wait
```

Verify your SSH key fingerprint matches what's registered: `ssh-keygen -l -f ~/.ssh/id_ed25519.pub`

### 2. Wait for cloud-init

```bash
sleep 120  # apt upgrades take time on fresh Ubuntu
```

### 3. Run bootstrap

```bash
scp scripts/bootstrap-droplet.sh root@<IP>:/tmp/
ssh root@<IP> 'bash /tmp/bootstrap-droplet.sh'
```

### 4. Open HTTP/HTTPS in firewall

```bash
ssh root@<IP> 'ufw allow http && ufw allow https'
```

### 5. Install Caddy

Use Cloudsmith apt repo (not default Ubuntu caddy which is outdated):

```bash
ssh root@<IP> 'apt install -y debian-keyring debian-archive-keyring apt-transport-https curl && \
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list && \
  apt update && apt install -y caddy'
```

### 6. Write Caddyfile

Force Let's Encrypt (ZeroSSL EAB fails on new accounts):

```
{
    acme_ca https://acme-v02.api.letsencrypt.org/directory
    email admin@team.example.com
}

member1.team.example.com {
    reverse_proxy 127.0.0.1:3001
}
```

### 7. Install gog binary

```bash
# Copy from another fleet droplet or download
scp root@<OTHER_FLEET>:/opt/mypa/shared/bin/gog /tmp/gog
scp /tmp/gog root@<NEW_IP>:/opt/mypa/shared/bin/gog
ssh root@<NEW_IP> 'chmod +x /opt/mypa/shared/bin/gog'
```

### 8. Deploy PA containers

Follow "Adding a New PA" above for each team member.

---

## Troubleshooting

### Container crash-looping

**Symptom:** Container status shows `Restarting (1)` repeatedly.

**Common causes:**
- Invalid key in `openclaw.json` (e.g., `agents.defaults.tools`, `skills.gog`, or `gog` with non-empty value)
- Port conflict with another container (check for relay port `+3` collisions)

**Fix:** Edit config directly on host filesystem (can't `docker exec` into a restarting container):

```bash
# Edit the config file
vi /opt/mypa/agents/<name>/data/openclaw.json
# Remove the offending key, then:
docker restart <name>
```

### Gateway returns 502 through Caddy

**Check:** Is the container using `--network host`?

```bash
docker inspect <name> --format '{{.HostConfig.NetworkMode}}'
# Must say "host", not "default" or "bridge"
```

If it says "bridge" or "default", recreate with `--network host`.

### Memory index fails on first run

**Symptom:** "ENOENT: rename .gguf.ipull -> .gguf"

**Cause:** Race condition during embedding model download. The 328MB model file's temp-to-final rename conflicts with concurrent access.

**Fix:** Just retry:

```bash
docker exec <name> node openclaw.mjs memory index --force
```

### gog returns "invalid service account JSON"

**Cause:** The SA JSON file has encoding issues (CSV-escaped quotes from 1Password, or corrupted during transfer).

**Fix:** Validate the JSON before passing to gog:

```bash
python3 -c "import json; json.load(open('/tmp/sa.json')); print('Valid')"
```

If invalid, re-export from 1Password and clean:

```python
raw = open('/tmp/sa-raw.json').read().strip()
if raw.startswith('"') and raw.endswith('"'):
    raw = raw[1:-1]
raw = raw.replace('""', '"')
import json
data = json.loads(raw)
with open('/tmp/sa.json', 'w') as f:
    json.dump(data, f, indent=2)
```

### SSH banned by fail2ban

**Symptom:** SSH times out (not "permission denied" -- complete silence).

**Fix from another machine or DO console:**

```bash
fail2ban-client set sshd unbanip <YOUR_IP>
# Prevent future bans:
echo 'ignoreip = 127.0.0.1/8 ::1 <YOUR_IP>' >> /etc/fail2ban/jail.local
systemctl restart fail2ban
```

### Droplet unreachable (OOM)

Power-cycle via API, then start containers sequentially:

```bash
doctl compute droplet-action power-cycle <droplet-id>
sleep 60
ssh root@<IP> 'docker start <first-container>'
# Wait 90s between each on 4GB droplets
```

---

## Caddy Configuration Pattern

Writing Caddyfiles via SSH is error-prone (quoting issues). Use Python to write the file:

```bash
ssh root@<IP> "python3 -c \"
caddyfile = '''
{
    acme_ca https://acme-v02.api.letsencrypt.org/directory
    email admin@team.example.com
}

member.team.example.com {
    reverse_proxy 127.0.0.1:3001
}
'''
with open('/tmp/Caddyfile.new', 'w') as f:
    f.write(caddyfile.strip() + chr(10))
\"

cp /tmp/Caddyfile.new /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy"
```

---

## DNS Management

All DNS is managed via Vercel CLI:

```bash
# Add record
vercel dns add team.example.com "subdomain" A <IP>

# List records
vercel dns ls team.example.com

# Remove record
echo "y" | vercel dns rm <RECORD_ID>
```

Requires `vercel login` (browser-based, one-time).

---

## Monitoring

### Quick health check (all endpoints)

```bash
for URL in member1.team.example.com member2.team.example.com crm-team.team.example.com; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$URL/)
  echo "$URL: $CODE"
done
```

### Container resource usage

```bash
ssh root@<IP> 'docker stats --no-stream --format "{{.Name}}: CPU={{.CPUPerc}} MEM={{.MemUsage}}"'
```

### Disk usage

```bash
ssh root@<IP> 'df -h / && echo "---" && du -sh /opt/mypa/agents/*/data/ 2>/dev/null'
```

---

## RAG Memory (Semantic Search)

PAs have a built-in memory system that stores conversation context and workspace files in a searchable index. There are two modes:

### FTS-only mode (default, works on any droplet)

Full-text search across workspace files and conversation logs. No additional configuration needed. Works on 4GB droplets.

### Vector search mode (requires 8GB+ droplet)

Uses a local embedding model (embeddinggemma-300m, ~328MB GGUF file) for semantic similarity search. Each PA instance loads the model into memory (~700MB), so this is only viable on 8GB+ droplets.

**Why you might want a larger droplet:** If your team needs semantic search (finding context by meaning, not just keywords), upgrade to an 8GB droplet. On a 4GB droplet with 3 containers, there isn't enough RAM for the embedding model. On an 8GB droplet with 7 containers, each PA can run its own vector index.

### Enable vector search

```bash
# Set provider (requires container restart to take effect)
docker exec $NAME node openclaw.mjs config set agents.defaults.memorySearch.provider local

# Build the initial index (downloads 328MB model on first run)
docker exec $NAME node openclaw.mjs memory index --force
```

**First-run gotcha:** The initial `memory index` command downloads a 328MB embedding model. On the first attempt, it sometimes fails with a rename race condition ("ENOENT: rename .gguf.ipull"). Just retry -- the model is cached after download.

### Reindex after workspace changes

After adding knowledge files to a PA's workspace, rebuild the index:

```bash
docker exec $NAME node openclaw.mjs memory index --force
```

No container restart needed -- the index is updated in place.

### Droplet sizing guide

| Droplet size | PAs | Memory mode | Notes |
|---|---|---|---|
| 2vCPU / 4GB | 2-3 | FTS-only | Start containers sequentially (90s gaps) |
| 4vCPU / 8GB | 5-7 | Vector search | Can start containers in parallel |
| 8vCPU / 16GB | 10-15 | Vector search | Recommended for large teams |

**Formula:** Each PA gateway uses ~400-800MB RAM at steady state. The embedding model adds ~700MB per PA. Budget 1.5GB per PA on vector-enabled droplets, 800MB per PA on FTS-only.

### Alternative: Remote embedding provider

Instead of local vector search, you can use a remote embedding API (OpenAI, Google Gemini, Voyage AI). This avoids the RAM overhead but adds API costs and latency.

```bash
docker exec $NAME node openclaw.mjs config set agents.defaults.memorySearch.provider openai
docker exec $NAME node openclaw.mjs config set agents.defaults.memorySearch.apiKey "sk-..."
```
