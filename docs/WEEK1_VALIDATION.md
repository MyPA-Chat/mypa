# Week 1 Pre-Deployment Validation

This is the required validation gate before production rollout of a new PA config format, template change, or deployment script update.

## Required automated gate (`scripts/validate-week1.sh`)

Run:

```bash
bash scripts/validate-week1.sh
```

This gate performs:
- OpenClaw JSON template parse checks for `templates/pa-default/openclaw.json` and `templates/pa-admin/openclaw.json`
- Agent contract checks:
  - admin template has `agents.defaults`, `agents.list[]`, and top-level `bindings[]`
  - agents object only contains `defaults`, `list`, and optional `_comment`
- Static rejection check for legacy object-keyed format (`"agents": {"admin": {...}}`)
- Dry-run provisioning checks with `scripts/provision-pa.sh --dry-run` for both `member` and `admin`

## Manual Week 1 live-instance matrix (must be completed before go-live)

For each format candidate:

1. Apply candidate config to a non-critical OpenClaw instance.
2. Restart/start the instance.
3. Send:
   - "What model are you running?"
   - "Check my email"
4. Record:
   - startup status
   - startup logs for schema parse errors
   - user-visible behavior in chat

### Matrix outcomes

- `agents` as object-keyed map (legacy proposal): expected to fail parse/boot
- `agents.list[]` + top-level `bindings[]` (current proposal): expected to boot and route correctly

If neither boots, capture exact startup errors and check OpenClaw changelog for schema/API changes before changing format.

## Changelog check procedure

Before accepting any format-related fallback:

1. Check OpenClaw changelog and schema docs for parser changes.
2. Compare version diff against the pinned version used in `DEPLOYMENT_PLAN.md`.
3. Document the decision in `docs/PLAN_RESPONSE.md` with date and evidence snippet.
