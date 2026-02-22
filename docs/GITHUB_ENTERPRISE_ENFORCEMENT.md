# GitHub Enforcement for MyPA

This guide is for making CI gates sticky in GitHub Enterprise.

## 1) Required CI gate

Keep the gate mandatory before merging:
- Pulls must satisfy `predeployment-gate` status.
- The check includes:
  - Week 1 template and config checks
  - Antfarm workflow contract checks
  - Required docs presence assertions

## 2) Apply branch protection from CLI

Run once (requires repository admin and GitHub token/CLI auth):

```bash
./scripts/setup-github-gates.sh <owner/repo> <default-branch>
```

Example:

```bash
./scripts/setup-github-gates.sh MyPA-Chat/mypa main
```

What it configures:
- 1 required approving review
- required status checks: `predeployment-gate`
- admin enforcement enabled

## 3) Recommended enterprise controls

- Require CODEOWNERS review for `templates/`, `scripts/`, `.github/`, and workflow files.
- Restrict token/secret write access to a minimal admin set.
- Enable Dependabot security updates.
- Enable secret scanning alerts and code scanning.
- Enforce signed commits for production-facing branches (if your enterprise policy supports it).
- Use protected environments for deployment workflows with explicit approvers.
- Use branch rulesets (Enterprise/Organization level) to apply consistent protection across repos.
- Use merge queues to reduce race-condition risk in repeated deployment merges.
- Add Required reviewer counts + review dismissals + stale-review invalidation for sensitive paths.
- Consider artifact attestation and dependency graph visibility for release confidence.
- Add codeowner approvals on policy-sensitive files via CODEOWNERS and protected branch rules.

If this repo is on GitHub Enterprise:

- [ ] Convert the single-repo branch protection in `.github/workflows` into org-level rulesets for consistent enforcement.
- [ ] Enable the dependency graph and secret scanning webhooks for instant policy alerts.
- [ ] Route deployment workflows through environments with required approvers and minimum required reviewers.

## 4) Optional runbook alignment

- During onboarding and deployment PRs, include link to:
  - `docs/ONBOARDING_RUNBOOK.md`
  - `docs/WEEK1_VALIDATION.md`
  - `docs/ANTFARM_INTEGRATION.md`
