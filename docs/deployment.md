# Deployment

This project runs on Elastic Beanstalk (single-container Docker) with two
environments under one EB application:

- `EB_ENV_TEST` — staging
- `EB_ENV_PROD` — production

A single RDS PostgreSQL instance is shared between both environments by default.
For production separation, override `RDS_INSTANCE_ID` and run `one_time_setup.sh`
a second time for the prod RDS.

## Initial setup

```bash
cp .env.example .env
# Fill in: GLOBUS_*, NRP_API_KEY, GH_REPO_NAME, AWS region, etc.

scripts/one_time_setup.sh
```

The script confirms each AWS-mutating step. It creates (in order):

1. GitHub repo (private, via `gh`)
2. ECR repository
3. RDS PostgreSQL instance, with the database `RDS_DB_NAME` and its own security group
   (`<RDS_INSTANCE_ID>-sg`) that admits port 5432 only from the default VPC (the EB
   instances) and from the public IP you ran setup from
4. Elastic Beanstalk application
5. EB environments: test, prod (Docker on Amazon Linux 2023). `.elasticbeanstalk/config.yml`
   is rewritten from `.env`'s `EB_APP_NAME` and `AWS_REGION` first, because `eb create`
   reads the application name from it
6. EB environment variables (pushed to both envs)

## One-click deploy

```bash
scripts/deploy.sh test     # deploy current commit to test
scripts/deploy.sh prod     # deploy current commit to prod
```

The script:

1. Logs in to ECR
2. Builds (`linux/amd64`, also on Apple Silicon) + pushes a uniquely tagged image
3. Runs `manage.py migrate` from your machine against the target RDS. If your public IP
   isn't in the RDS security group yet (new network, VPN), it asks to add it first
4. Packages `Dockerrun.aws.json` + `.ebextensions/` + `.platform/` (intentionally
   does NOT include `docker-compose.yml` — see failure modes below)
5. Uploads as a new EB application version and waits for the env update

## CI

`.github/workflows/ci.yml` runs `ruff` + `python manage.py check` + `pytest` on
every push/PR. CI does not deploy — deploys are operator-initiated via `deploy.sh`.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| EB starts in "Compose mode" | `docker-compose.yml` ended up in the EB bundle | `.ebignore` lists it; `deploy.sh` builds a minimal bundle |
| `docker info` fails in `deploy.sh` | Docker Desktop not running | Start Docker Desktop |
| `deploy.sh` asks to allow your IP | You're deploying from a network you didn't run setup from | Answer `y`. Remove stale entries later: `aws ec2 revoke-security-group-ingress --group-id <sg> --protocol tcp --port 5432 --cidr <old-ip>/32` |
| `migrate` fails with auth error | EB env var `DATABASE_URL` not yet pushed | Re-run `one_time_setup.sh` step 6 |
| EB env update times out (waiter) | Sometimes still succeeds | Check EB events: `aws elasticbeanstalk describe-events --environment-name "$EB_ENV_PROD" --max-records 20` |
| Globus redirect mismatch | EB CNAME changed | Update the Globus app redirect URIs (see `docs/globus_setup.md`) |
| Health check unhealthy after HTTPS redirect | `SECURE_SSL_REDIRECT=True` redirects `/healthz/` | `settings.SECURE_REDIRECT_EXEMPT` already exempts it |

## Logs

```bash
eb logs "$EB_ENV_TEST"
aws elasticbeanstalk describe-events --region "$AWS_REGION" --environment-name "$EB_ENV_TEST" --max-records 20
```
