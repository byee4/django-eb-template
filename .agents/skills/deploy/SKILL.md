---
name: deploy
description: Deploy this Django app to the Elastic Beanstalk test or prod environment with scripts/deploy.sh, with pre-flight checks and a recorded audit trail. Use when the user asks to deploy, ship, release to test or prod.
---

# Deploy (test → prod)

Deployment mutates AWS. The agent prepares and verifies; **the human runs the deploy command**
(the guard asks for approval on `scripts/deploy.sh`, `eb`, and `aws`).

1. **Pre-flight.** On a clean, merged `main`: `make verify` passes; `git status` clean;
   note the SHA (`git rev-parse --short HEAD`).
2. **Migrations.** `uv run python manage.py makemigrations --check --dry-run` must be clean. If a migration
   is destructive (drop/rename column), stop and ask the user for a rollout plan first.
3. **Allowlist sanity.** If `GLOBUS_ALLOWED_IDENTITIES`/`GLOBUS_ALLOWED_GROUP` changed, confirm the
   deployer's identity is still allowed (lock-out risk).
4. **Test env first.** If the environment doesn't exist yet, the user runs
   `scripts/one_time_setup.sh test` once. Then ask them to run `scripts/deploy.sh test` and smoke-test
   `/healthz/`, login, and one chat message on the HTTPS address it prints (CloudFront or custom
   domain, not the bare EB address).
5. **Prod.** Only after the user confirms test is good: they run `scripts/deploy.sh prod`
   (and `scripts/one_time_setup.sh prod` the first time). Prod has its own database.
6. **Record.** In the PR or release notes: EB environment, version label, git SHA, who approved,
   time, and the smoke-test result.
7. **Rollback.** Redeploy the previous version label from the EB console/CLI (human-run).

Never run `eb terminate`, delete RDS/ECR resources, or edit `.ebextensions`/`.platform` during a deploy.
