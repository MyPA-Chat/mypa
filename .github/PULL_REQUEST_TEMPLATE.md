## MyPA pre-deployment required checks

- [ ] Ran `bash scripts/validate-week1.sh`
- [ ] Ran `bash scripts/validate-antfarm-workflow.sh`
- [ ] CI passes (predeployment gate)
- [ ] Ran `./scripts/setup-github-gates.sh` if this PR changes branch policy-critical files (`templates/`, `scripts/`, `.github/`, `docs/`)
- [ ] If any OpenClaw config changed, reviewed output from:
  - `bash scripts/provision-pa.sh ... --dry-run` for `member` template
  - `bash scripts/provision-pa.sh ... --dry-run` for `admin` template
- [ ] Added/updated evidence for:
  - `agent config format` resolution
  - `agent schema checks` pass
- [ ] Checked OpenClaw docs/changelog for breaking changes in `/schema/openclaw.json` or relevant parser/runtime behavior.

## Deployment notes
- Environment-safe changes only (no secrets in repo)
- If this PR changes any runtime behavior, include runtime validation commands and outcomes in PR description.
- If both agent formats fail in live canary, provide OpenClaw changelog links and migration rationale.
