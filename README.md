# django-template

Frictionless Django web-app starter with Globus auth and an NRP Nautilus chat app.

- Django 5 + globus-portal-framework + social-auth-app-django
- Local dev: `.venv` or Docker Compose
- Production: AWS Elastic Beanstalk (single-container Docker) — two environments (test + prod)
- LLM chat via NRP Nautilus (OpenAI-compatible API)
- One-command setup: GitHub repo, ECR, RDS, EB app + envs, env vars
- One-command deploy: `scripts/deploy.sh test|prod`

## Quick start (5 minutes)

```bash
# 1. Copy this template
cp -R ~/Documents/work/03_templates/django-template ~/Documents/work/01_active/my-project
cd ~/Documents/work/01_active/my-project

# 2. Configure secrets
cp .env.example .env
# Edit .env — see "Environment variables" below for each one

# 3. Install agent guard rails (Claude Code / Codex settings, CI, pre-commit)
scripts/install_agent_kit.sh

# 4. Run locally
scripts/bootstrap_local.sh         # .venv + SQLite
# OR
scripts/bootstrap_docker.sh        # Docker Compose + Postgres

# 5. Visit http://localhost:8000/
```

When you're ready to deploy:

```bash
scripts/one_time_setup.sh          # creates GitHub repo, AWS infra (with prompts)
scripts/deploy.sh test             # deploy to test env
scripts/deploy.sh prod             # deploy to production
```

## Environment variables

All sensitive config lives in `.env` (gitignored). `.env.example` is the template.

| Variable | Required for | Where to get it |
|---|---|---|
| `DJANGO_SECRET_KEY` | All | Generate: `python -c "import secrets; print(secrets.token_urlsafe(50))"` |
| `DJANGO_DEBUG` | All | `True` locally, `False` on EB (set automatically by `one_time_setup.sh`) |
| `DJANGO_ALLOWED_HOSTS` | All | `localhost,127.0.0.1` locally; EB CNAME in prod |
| `DATABASE_URL` | Docker/EB | Leave blank for local SQLite; `one_time_setup.sh` sets it from RDS |
| `GLOBUS_CLIENT_ID` | Login | https://app.globus.org/settings/developers → register a Portal app |
| `GLOBUS_CLIENT_SECRET` | Login | Same place, "New client secret" |
| `SOCIAL_AUTH_GLOBUS_REDIRECT_URI` | Login | `http://localhost:8000/complete/globus/` locally; per-env URL in prod |
| `GLOBUS_ALLOWED_IDENTITIES` | Access | Comma-separated identity UUIDs. Default: `0ab2be39-35fe-432b-a620-2ed86db7999d` |
| `GLOBUS_ALLOWED_GROUP` | Access | Group UUID. Default: `f0c3d900-18af-11f1-8e43-0affecd7d007` |
| `NRP_API_KEY` | Chat | https://nrp.ai — request access; copy your token |
| `NRP_GATEWAY_BASE_URL` | Chat | Default: `https://llm.nrp-nautilus.io/` |
| `NRP_DEFAULT_MODEL` | Chat | Any model NRP exposes (e.g. `meta-llama/Meta-Llama-3.1-70B-Instruct`) |
| `GH_REPO_NAME` | Deploy | Just the repo name; owner inferred from `gh auth status` |
| `AWS_REGION` | Deploy | e.g. `us-west-2` |
| `EB_APP_NAME` | Deploy | EB application name (becomes the parent of both envs) |
| `EB_ENV_TEST` | Deploy | EB test environment name |
| `EB_ENV_PROD` | Deploy | EB prod environment name |
| `RDS_*` | Deploy | RDS instance config. Password auto-generated if blank |

## Setting up Globus auth

See [`docs/globus_setup.md`](docs/globus_setup.md). Short version:

1. Register a Portal app at https://app.globus.org/settings/developers
2. Add redirect URIs for each environment (local + EB test CNAME + EB prod CNAME)
3. Copy client ID + secret to `.env`
4. The template restricts access to the default identity/group; expand via `GLOBUS_ALLOWED_*`

## Setting up the NRP chat

The `chat/` app uses an OpenAI-compatible streaming API pointed at NRP Nautilus.
Get a token from https://nrp.ai (request access if you don't have one), put it in
`NRP_API_KEY` in `.env`, and the chat at `/chat/` will work.

The chat is login-required and rate-limited by the gateway. The template does NOT
expose the token to the browser — all calls are server-to-server.

## Project layout

See [`docs/codemap.md`](docs/codemap.md). High level:

```
config/       Django settings, URLs, WSGI
main/         Hello-world app + /healthz/
chat/         NRP streaming chat (login required)
accounts/     Globus identity/group allowlist + audit middleware
scripts/      bootstrap_local.sh, bootstrap_docker.sh, one_time_setup.sh, deploy.sh
docs/         codemap.md, globus_setup.md, deployment.md, specs/
.ebextensions/.elasticbeanstalk/.platform/   Elastic Beanstalk config
.github/workflows/ci.yml                     Lint + test on PR
.beads/       Issue tracking (bd CLI)
AGENTS.md     Operating guidelines for AI agents and humans (CLAUDE.md imports it)
.agent/       Enforced agent guard rails: hooks, policy, definition of done
.agents/skills/  Agent runbooks: ship-change, deploy
```

## Verification before commit

```bash
.venv/bin/ruff check .
.venv/bin/python manage.py check
.venv/bin/pytest
```

These also run in CI on every PR (`.github/workflows/ci.yml`).

## Failure modes (the short list)

- **Locked out of your own app**: you removed your identity from `GLOBUS_ALLOWED_IDENTITIES`
  and aren't in the group. Fix: edit the EB env var via console, or revert in `.env` and redeploy.
- **`docker info` fails in deploy**: Docker Desktop not running. Start it, rerun.
- **`one_time_setup.sh` partway through**: it's idempotent — rerun. Each step checks
  whether the resource already exists.
- **EB env stuck "Updating"**: the AWS waiter sometimes times out before the env
  actually settles. Check `aws elasticbeanstalk describe-events` before assuming failure.
- **`.env` placeholder values blocking setup**: `one_time_setup.sh` refuses to run if
  `.env` still contains `REPLACE_ME_GENERATE_LOCAL_KEY`. Fill it in.
- **Chat returns 503**: NRP gateway is loading or unreachable. Retry in a minute.
- **Globus redirect mismatch**: the URL on the Globus app must match the EB CNAME
  exactly (including scheme). See `docs/globus_setup.md`.

## Required tools

```bash
python3 --version    # 3.12+
docker --version     # for Docker Compose + EB deploys
aws --version
eb --version
gh --version         # GitHub CLI, signed in
psql --version       # for RDS bootstrap
```

## Generating this template

This project was generated from `~/Documents/work/03_templates/django-template`.
To regenerate or modify the template itself, see that directory.

## License

Internal use only unless stated otherwise.
