# Deployment

The app runs on Elastic Beanstalk (single-container Docker on Amazon Linux 2023). One EB application
holds two environments, and **each environment has its own** ECR repository and RDS PostgreSQL
instance, so a test deploy or migration can never touch production data.

| | Test | Prod |
|---|---|---|
| EB environment | `EB_ENV_TEST` | `EB_ENV_PROD` |
| ECR repository | `<PROJECT_SLUG>-test` | `<PROJECT_SLUG>-prod` |
| RDS instance / database | `<PROJECT_SLUG>-test-db` / `<slug>_test` | `<PROJECT_SLUG>-prod-db` / `<slug>_prod` |
| Default shape | one instance, no load balancer | load-balanced |
| HTTPS | CloudFront unless `CUSTOM_DOMAIN_TEST` | CloudFront unless `CUSTOM_DOMAIN_PROD` |

Names are derived in `scripts/lib/aws_env.sh`. Every script takes `test` or `prod` explicitly;
there is no default.

## Initial setup (once per environment)

```bash
scripts/one_time_setup.sh test
scripts/one_time_setup.sh prod     # when you're ready
```

It prompts before each AWS change and is safe to rerun. Steps:

1. **ECR repository** for the environment.
2. **RDS PostgreSQL** (db.t3.micro, 20 GB, 7-day backups) with its own security group
   (`<instance>-sg`) admitting port 5432 only from the default VPC (the EB instances) and the public
   IP you ran setup from. A generated password is saved to `.env` as `RDS_MASTER_PASSWORD_<ENV>`.
3. **EB application and environment** via `eb create` (t3.small; single instance or load-balanced per
   `EB_SINGLE_INSTANCE_<ENV>`). `.elasticbeanstalk/config.yml` is rewritten from `.env` first,
   because `eb create` reads the application name from it.
4. **HTTPS**, one of:
   - **No domain (default): CloudFront.** AWS will not issue certificates for
     `*.elasticbeanstalk.com`, so setup puts a CloudFront distribution (caching off) in front of the
     environment. You get `https://dXXXX.cloudfront.net` with an AWS certificate. Django is told to
     trust CloudFront's `CloudFront-Forwarded-Proto` header (`SECURE_PROXY_SSL_HEADER_NAME`).
   - **`CUSTOM_DOMAIN_<ENV>` set: ACM on the load balancer.** Setup requests a certificate and, with
     `ROUTE53_ZONE_NAME`, adds the DNS validation record; otherwise it prints the record for you to
     add. Rerun once the certificate is `ISSUED` to attach it to port 443, then point the domain
     (CNAME or Route 53 alias) at the EB address. Needs a load-balanced environment.
5. **Environment variables**: `DATABASE_URL`, a secret key (kept across reruns), `DJANGO_DEBUG=False`,
   allowed hosts and CSRF origins for the public address, the Globus redirect URI, and the Globus,
   allowlist and NRP values from `.env`.

At the end it prints the Globus redirect URI to register (`docs/globus_setup.md`).

## Deploy

```bash
scripts/deploy.sh test     # or: make deploy-test
scripts/deploy.sh prod
```

1. Logs in to the environment's ECR repository.
2. Builds a `linux/amd64` image (also on Apple Silicon) with a unique tag and pushes it.
3. Runs `manage.py migrate` from your machine against the environment's RDS. If your public IP
   isn't in the RDS security group (new network, VPN), it asks to add it first.
4. Packages only `Dockerrun.aws.json` (pinned to that exact tag) + `.ebextensions/` + `.platform/`.
5. Creates an EB application version and waits for the environment update, then prints the
   `/healthz/` URL to smoke-test.

Roll back by redeploying an earlier application version label from the EB console.

## CI

`.github/workflows/ci.yml` runs `uv sync --locked` and `.agent/done.sh` (ruff, mypy, `manage.py
check`, missing-migration check, pytest) on every push and PR, plus pre-commit and zizmor. CI never
deploys; deploys are operator-initiated.

## Costs and teardown

Roughly per environment: t3.small (~$15/month), db.t3.micro + storage (~$15/month), a public IPv4
address (~$4/month), plus ~$16/month for a load balancer if the environment has one. CloudFront at
test traffic is close to free. To remove an environment: disable then delete its CloudFront
distribution, terminate the EB environment, and delete its RDS instance, ECR repository and RDS
security group (the agent guard blocks these deletions; a human runs them).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| EB starts in "Compose mode" | `docker-compose.yml` ended up in the EB bundle | `.ebignore` lists it; `deploy.sh` builds a minimal bundle |
| Container exits with `exec format error` | Image built for arm64 | `deploy.sh` builds `linux/amd64`; don't push hand-built images |
| `docker info` fails in `deploy.sh` | Docker Desktop not running | Start Docker Desktop |
| `deploy.sh` asks to allow your IP | Deploying from a network you didn't run setup from | Answer `y`. Remove stale entries later with `aws ec2 revoke-security-group-ingress` |
| `migrate` fails with auth error | `DATABASE_URL` not pushed yet, or password missing from `.env` | Rerun `one_time_setup.sh <env>` |
| Endless redirect loop on the CloudFront address | `SECURE_PROXY_SSL_HEADER_NAME` not set on the environment | Rerun `one_time_setup.sh <env>` (step 6) |
| Bare EB address redirects to an HTTPS page that won't load | Expected: the EB address has no certificate | Use the CloudFront or custom-domain address |
| Load-balanced environment shows unhealthy | Health check hitting the wrong path | `.ebextensions` sets `/healthz/`; `main.middleware.HealthCheckMiddleware` answers it whatever the Host header |
| EB env update times out (waiter) | Often still succeeds | Check `aws elasticbeanstalk describe-events --environment-name <env> --max-records 20` |
| Globus `redirect_uri` mismatch | Public address changed | Add the URI printed by `one_time_setup.sh` to the Globus app |
| `Login session was lost before the Globus callback completed` | Cookies lost between login and callback (host or scheme mismatch) | Use one address consistently; clear cookies; see `accounts.middleware.GlobusOAuthRecoveryMiddleware` |
| Uploaded files vanish after a deploy | EB container storage is not persistent | Use S3 (django-storages) before storing user uploads |

## Logs

```bash
eb logs <environment-name>
aws elasticbeanstalk describe-events --region "$AWS_REGION" --environment-name <environment-name> --max-records 20
```
