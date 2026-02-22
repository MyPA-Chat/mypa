#!/usr/bin/env node
//
// MyPA Provisioning API — Least-privilege host API for PA lifecycle management.
//
// Exposes pactl operations over HTTP so the admin PA can provision PAs
// without SSH access to the host. Runs as the mypa user with the same sudoers
// policy as interactive admin.
//
// Usage:
//   PROVISION_API_TOKEN=<token> node server.js
//   PROVISION_API_TOKEN=<token> node server.js --port 9100
//
// Security:
//   - Listens on 127.0.0.1 only (not reachable from public internet)
//   - Bearer token auth (1Password-managed)
//   - All PA names validated against strict pattern
//   - Template names allowlisted
//   - No shell injection: execFile with array args, not exec with string
//   - All requests logged with timestamp and parameters
//

const http = require("http");
const { execFile } = require("child_process");
const { promisify } = require("util");
const path = require("path");

const execFileAsync = promisify(execFile);

// --- Configuration ---

const PORT = parseInt(process.env.PROVISION_API_PORT || "9100", 10);
const HOST = "127.0.0.1";
const TOKEN = process.env.PROVISION_API_TOKEN;
const PACTL = process.env.PACTL_PATH || "/opt/mypa/scripts/pactl.sh";
const CADDY_CONFIG_DIR =
  process.env.CADDY_CONFIG_DIR || "/opt/mypa/caddy/sites";
const CADDY_BIN = process.env.CADDY_BIN || "/opt/mypa/caddy";
const CADDYFILE = process.env.CADDYFILE || "/opt/mypa/Caddyfile";

// Command timeout (30s for most ops, 120s for create which pulls images)
const DEFAULT_TIMEOUT = 30_000;
const CREATE_TIMEOUT = 120_000;

if (!TOKEN) {
  console.error(
    "FATAL: PROVISION_API_TOKEN not set. Generate with: openssl rand -hex 16"
  );
  process.exit(1);
}

// --- Validation ---

const PA_NAME_RE = /^[a-z][a-z0-9-]{1,30}$/;
const ALLOWED_TEMPLATES = ["pa-default", "pa-admin"];
const ALLOWED_DOMAINS_RE = /^[a-z0-9.-]+\.[a-z]{2,}$/;

function validatePaName(name) {
  if (!name || !PA_NAME_RE.test(name)) {
    return `Invalid PA name: must match ${PA_NAME_RE} (got: ${name})`;
  }
  return null;
}

function validateTemplate(tmpl) {
  if (!tmpl || !ALLOWED_TEMPLATES.includes(tmpl)) {
    return `Invalid template: must be one of ${ALLOWED_TEMPLATES.join(", ")} (got: ${tmpl})`;
  }
  return null;
}

function validateDomain(domain) {
  if (!domain || !ALLOWED_DOMAINS_RE.test(domain)) {
    return `Invalid domain: ${domain}`;
  }
  return null;
}

// --- Logging ---

function log(method, path, params, status) {
  const ts = new Date().toISOString();
  let paramStr = "";
  if (params) {
    const sanitized = { ...params };
    ["gateway_token", "api_key", "botToken", "token", "password"].forEach(
      (k) => { if (sanitized[k]) sanitized[k] = "***"; }
    );
    paramStr = JSON.stringify(sanitized);
  }
  console.log(`${ts} ${method} ${path} ${status} ${paramStr}`);
}

// --- Auth middleware ---

function authenticate(req) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return false;
  const provided = auth.slice(7);
  // Constant-time comparison
  if (provided.length !== TOKEN.length) return false;
  let result = 0;
  for (let i = 0; i < provided.length; i++) {
    result |= provided.charCodeAt(i) ^ TOKEN.charCodeAt(i);
  }
  return result === 0;
}

// --- pactl wrapper ---

async function runPactl(args, timeout = DEFAULT_TIMEOUT) {
  try {
    const { stdout, stderr } = await execFileAsync("bash", [PACTL, ...args], {
      timeout,
      env: { ...process.env, PATH: process.env.PATH },
    });
    return { ok: true, stdout: stdout.trim(), stderr: stderr.trim() };
  } catch (err) {
    return {
      ok: false,
      stdout: (err.stdout || "").trim(),
      stderr: (err.stderr || err.message || "").trim(),
      code: err.code,
    };
  }
}

// --- Request body parser ---

function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > 10_000) {
        reject(new Error("Body too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString();
      if (!raw) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("Invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

// --- Response helpers ---

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

// --- Route handlers ---

const routes = {};

// POST /pa/create — Create a new PA container
routes["POST /pa/create"] = async (body) => {
  const { name, member, team } = body;
  const err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const args = ["create", name];
  if (member) args.push("--member", String(member));
  if (team) args.push("--team", String(team));

  const result = await runPactl(args, CREATE_TIMEOUT);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 201, body: { message: `PA ${name} created`, output: result.stdout } };
};

// POST /pa/config — Configure a PA
routes["POST /pa/config"] = async (body) => {
  const { name, template, gateway_token } = body;
  let err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const args = ["config", name];
  if (template) {
    err = validateTemplate(template);
    if (err) return { status: 400, body: { error: err } };
    args.push("--template", template);
  }
  if (gateway_token) {
    args.push("--gateway-token", String(gateway_token));
  }

  const result = await runPactl(args);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { message: `PA ${name} configured`, output: result.stdout } };
};

// POST /pa/start — Start a PA
routes["POST /pa/start"] = async (body) => {
  const { name } = body;
  const err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const result = await runPactl(["start", name]);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { message: `PA ${name} started`, output: result.stdout } };
};

// POST /pa/stop — Stop a PA
routes["POST /pa/stop"] = async (body) => {
  const { name } = body;
  const err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const result = await runPactl(["stop", name]);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { message: `PA ${name} stopped`, output: result.stdout } };
};

// POST /pa/restart — Restart a PA
routes["POST /pa/restart"] = async (body) => {
  const { name } = body;
  const err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const result = await runPactl(["restart", name]);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { message: `PA ${name} restarted`, output: result.stdout } };
};

// GET /pa/list — List all PAs
routes["GET /pa/list"] = async () => {
  const result = await runPactl(["list"]);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { output: result.stdout } };
};

// GET /pa/status/:name — Get PA status
routes["GET /pa/status"] = async (_body, name) => {
  const err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };

  const result = await runPactl(["status", name]);
  if (!result.ok) return { status: 500, body: { error: result.stderr } };
  return { status: 200, body: { output: result.stdout } };
};

// POST /caddy/add-route — Add a Caddy route for a PA
routes["POST /caddy/add-route"] = async (body) => {
  const { name, domain, gateway_port } = body;
  let err = validatePaName(name);
  if (err) return { status: 400, body: { error: err } };
  err = validateDomain(domain);
  if (err) return { status: 400, body: { error: err } };

  const port = parseInt(gateway_port || "0", 10);
  if (!port || port < 3001 || port > 3100) {
    return {
      status: 400,
      body: { error: `Invalid gateway_port: must be 3001-3100 (got: ${gateway_port})` },
    };
  }

  // Write site config from template
  const siteConfig = `${domain} {
  reverse_proxy 127.0.0.1:${port}

  # Strip Tailscale identity headers from public internet requests
  @not_tailscale not remote_ip 100.64.0.0/10 127.0.0.1
  request_header @not_tailscale -Tailscale-User-Login
  request_header @not_tailscale -Tailscale-User-Name
  request_header @not_tailscale -Tailscale-User-Profile-Pic
}
`;

  const siteFile = path.join(CADDY_CONFIG_DIR, `${name}.caddy`);

  try {
    const fs = require("fs");
    fs.mkdirSync(CADDY_CONFIG_DIR, { recursive: true });
    fs.writeFileSync(siteFile, siteConfig, { mode: 0o644 });
  } catch (writeErr) {
    return {
      status: 500,
      body: { error: `Failed to write Caddy config: ${writeErr.message}` },
    };
  }

  // Reload Caddy
  try {
    await execFileAsync(CADDY_BIN, ["reload", "--config", CADDYFILE], {
      timeout: DEFAULT_TIMEOUT,
    });
  } catch (reloadErr) {
    return {
      status: 500,
      body: {
        error: `Caddy config written but reload failed: ${reloadErr.message}`,
      },
    };
  }

  return {
    status: 200,
    body: { message: `Route added: ${domain} → 127.0.0.1:${port}`, file: siteFile },
  };
};

// GET /health — API health check
routes["GET /health"] = async () => {
  return {
    status: 200,
    body: {
      status: "ok",
      service: "mypa-provisioning-api",
      timestamp: new Date().toISOString(),
    },
  };
};

// --- Server ---

const server = http.createServer(async (req, res) => {
  const method = req.method;
  const url = new URL(req.url, `http://${HOST}:${PORT}`);
  const pathname = url.pathname;

  // Health check doesn't require auth
  if (method === "GET" && pathname === "/health") {
    const result = await routes["GET /health"]();
    log(method, pathname, null, result.status);
    return json(res, result.status, result.body);
  }

  // Auth check for all other routes
  if (!authenticate(req)) {
    log(method, pathname, null, 401);
    return json(res, 401, { error: "Unauthorized" });
  }

  try {
    let body = {};
    if (method === "POST") {
      body = await parseBody(req);
    }

    // Route matching
    let handler;
    let routeParam;

    // Check for parameterized routes (e.g., /pa/status/:name)
    const statusMatch = pathname.match(/^\/pa\/status\/([a-z][a-z0-9-]{1,30})$/);
    if (statusMatch && method === "GET") {
      handler = routes["GET /pa/status"];
      routeParam = statusMatch[1];
    } else {
      const routeKey = `${method} ${pathname}`;
      handler = routes[routeKey];
    }

    if (!handler) {
      log(method, pathname, null, 404);
      return json(res, 404, { error: "Not found" });
    }

    const result = await handler(body, routeParam);
    log(method, pathname, body, result.status);
    return json(res, result.status, result.body);
  } catch (err) {
    log(method, pathname, null, 500);
    return json(res, 500, { error: err.message });
  }
});

server.listen(PORT, HOST, () => {
  console.log(
    `MyPA Provisioning API listening on ${HOST}:${PORT} (PID ${process.pid})`
  );
  console.log(`  pactl: ${PACTL}`);
  console.log(`  caddy: ${CADDY_BIN}`);
  console.log(`  auth: bearer token (${TOKEN.length} chars)`);
});
