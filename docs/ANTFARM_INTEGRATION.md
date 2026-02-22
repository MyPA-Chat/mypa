# Antfarm Integration Guide

This repository now includes Antfarm-ready automation for provisioning and verification.

## 1) Install Antfarm on the host

Use the project helper script:

```bash
./scripts/install-antfarm.sh
```

What it does:
- Installs Antfarm from the official upstream release.
- Installs the local `pa-provision` workflow into the local Antfarm DB.
- Lists available workflows for quick verification.

## 2) Run Antfarm workflows

### Provision a new PA

```bash
antfarm workflow run pa-provision "Alice Smith for Team Alpha, email alicepa@yourdomain.com"
```

Antfarm will execute:
- provisioning actions via `scripts/provision-pa.sh`
- post-provision checks (template match, SOUL, model-router, env vars, skill presence)
- final provisioning report in workflow output

### Security audit workflow (recommended during Phase 5)

Once you add it locally:

```bash
antfarm workflow run security-audit "Audit MyPA config and deployment posture"
```

## 3) What now has CI enforcement

`predeployment-gate` (GitHub Actions) already requires:
- `bash scripts/validate-week1.sh`
- `bash scripts/validate-antfarm-workflow.sh`
- `docs/WEEK1_VALIDATION.md` existence + runbook pointer

If this gate fails, merge is blocked.

## 4) Validation fallback policy

- If Antfarm validation passes but runtime behavior still looks wrong, run the live canary path in `docs/WEEK1_VALIDATION.md`.
- If both object-keyed and `agents.list` formats fail on live host, follow changelog/API review before changing deployment assumptions.
