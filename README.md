# django-template

Django web-app starter with Globus login, an NRP Nautilus chat app, Elastic Beanstalk test and
prod environments, and guard rails for AI coding agents.

- Django 5 + globus-portal-framework + social-auth-app-django, with an identity/group allowlist
- LLM chat via NRP Nautilus (OpenAI-compatible streaming API)
- uv-locked dependencies, `make verify` (ruff, mypy, Django checks, pytest), CI on every PR
- Local dev with uv + SQLite, or Docker Compose + Postgres
- AWS Elastic Beanstalk (Docker, Amazon Linux 2023): separate test and prod environments, each with
  its own database and image repository, HTTPS by default (CloudFront, or ACM with your domain)
- Agent kit: hooks, policy, definition of done, skills (`.agent/`, `.agents/skills/`)

<!-- template-only:start -->
## Create a project

From this template's folder:

```bash
python3 scripts/create_project.py ~/Documents/work/01_active/my-portal \
  --slug my-portal --name "My Portal"
```

This copies the template without caches or local state, renames it, writes `.env` with a fresh
Django secret, installs the agent kit, commits to a new `main` branch, installs dependencies, and
indexes the codebase-memory graph. Options:

| Option | Effect |
|---|---|
| `--github OWNER/REPO` | also create the GitHub repo (`--visibility private` by default) and push |
| `--beads` | initialize Beads issue tracking (optional; see `.beads/README.md`) |
| `--skip-sync` / `--skip-index` | skip `uv sync` / the code graph |

Then, in the new project:

```bash
# fill in GLOBUS_CLIENT_ID/SECRET and NRP_API_KEY in .env (see below)
make run                 # http://localhost:8000/  (or: make dev for Docker + Postgres)
make verify              # the definition of done; same as CI
```
<!-- template-only:end -->

## Deploy to AWS

```bash
scripts/one_time_setup.sh test     # once: ECR, RDS, EB environment, HTTPS, env vars (prompts first)
scripts/deploy.sh test             # every release: build, push, migrate, deploy
scripts/one_time_setup.sh prod     # when ready, then: scripts/deploy.sh prod
```

Without a domain you get HTTPS on a default `https://dXXXX.cloudfront.net` address, because AWS
won't issue certificates for `*.elasticbeanstalk.com`. Setup prints the Globus redirect URI to
register. Details, costs and failure modes: [`docs/deployment.md`](docs/deployment.md).

## Environment variables

All sensitive config lives in `.env` (git-ignored, never baked into the Docker image). `.env.example`
documents every variable.

| Variable | Required for | Where to get it |
|---|---|---|
| `DJANGO_SECRET_KEY` | All | Generated when the project is created; or `python -c "import secrets; print(secrets.token_urlsafe(50))"` |
| `DJANGO_DEBUG` | All | `True` locally; setup sets `False` on EB (production refuses to start on the dev key or `*` hosts) |
| `DJANGO_ALLOWED_HOSTS` | All | `localhost,127.0.0.1` locally; setup sets the public address on EB |
| `DATABASE_URL` | Docker/EB | Blank for local SQLite; setup sets it per environment |
| `GLOBUS_CLIENT_ID` / `GLOBUS_CLIENT_SECRET` | Login | https://app.globus.org/settings/developers → register a Portal app |
| `SOCIAL_AUTH_GLOBUS_REDIRECT_URI` | Login | `http://localhost:8000/complete/globus/` locally; setup sets it on EB |
| `GLOBUS_ALLOWED_IDENTITIES` | Access | Comma-separated identity UUIDs; yours is at https://app.globus.org/account/identities. Empty by default: nobody can log in until you set this or the group |
| `GLOBUS_ALLOWED_GROUP` | Access | Group UUID from https://app.globus.org/groups; any member may log in. Empty by default |
| `NRP_API_KEY` | Chat | https://nrp.ai — request access; copy your token |
| `NRP_GATEWAY_BASE_URL`, `NRP_DEFAULT_MODEL` | Chat | Defaults work |
| `PROJECT_SLUG`, `AWS_REGION`, `EB_APP_NAME`, `EB_ENV_TEST`, `EB_ENV_PROD` | Deploy | Set when the project is created |
| `CUSTOM_DOMAIN_TEST` / `_PROD`, `ROUTE53_ZONE_NAME` | HTTPS (optional) | Your domain; blank = CloudFront address |
| `EB_SINGLE_INSTANCE_TEST` / `_PROD` | Deploy | `true` = no load balancer (cheaper). Defaults: test true, prod false |
| `RDS_MASTER_PASSWORD_TEST` / `_PROD` | Deploy | Leave blank; setup generates and saves them |

## Setting up Globus auth

See [`docs/globus_setup.md`](docs/globus_setup.md). Short version: register a Portal app, add a
redirect URI per environment (local, plus the one `one_time_setup.sh` prints), copy the client ID
and secret to `.env`. Access is limited to `GLOBUS_ALLOWED_*`.

## Setting up the NRP chat

The `chat/` app calls an OpenAI-compatible streaming API at NRP Nautilus. Put a token from
https://nrp.ai in `NRP_API_KEY` and `/chat/` works. Calls are server-to-server; the token never
reaches the browser.

## Project layout

See [`docs/codemap.md`](docs/codemap.md). High level:

```
config/       Django settings, URLs, WSGI
main/         Hello-world app + /healthz/
chat/         NRP streaming chat (login required)
accounts/     Globus allowlist, audit-log and OAuth-recovery middleware
scripts/      one_time_setup.sh, deploy.sh, bootstrap_*.sh, install_agent_kit.sh
docs/         codemap.md, globus_setup.md, deployment.md, specs/
.ebextensions/ .elasticbeanstalk/ .platform/   Elastic Beanstalk config
AGENTS.md     Instructions for AI agents and humans (CLAUDE.md imports it)
.agent/       Agent guard rails: hooks, policy, definition of done
.agents/skills/  Agent runbooks: ship-change, deploy
```

## Verification before commit

```bash
make verify        # = bash .agent/done.sh: ruff, mypy, manage.py check, migrations check, pytest
```

CI runs the same command on every PR. After changing dependencies, run `make lock` and commit
`uv.lock` and `requirements.txt` (the Docker image installs the latter).

## Failure modes (the short list)

- **Locked out of your own app**: you removed your identity from `GLOBUS_ALLOWED_IDENTITIES` and
  aren't in the group. Fix `.env`, rerun `one_time_setup.sh <env>` (last step only).
- **`one_time_setup.sh` stopped partway**: it's idempotent; rerun it.
- **Redirect loop or "Login session was lost"** on EB: use the CloudFront or custom-domain address,
  not the bare EB one; see `docs/deployment.md`.
- **Chat returns 503**: NRP gateway is loading or unreachable. Retry in a minute.
- **Globus redirect mismatch**: the URI on the Globus app must match exactly, including `https`.

## Required tools

```bash
uv --version         # https://docs.astral.sh/uv/
docker --version     # Docker Compose and EB image builds
aws --version        # signed in: aws sts get-caller-identity
eb --version         # EB CLI, used by one_time_setup.sh to create environments
gh --version         # only for --github
```

## Template

Created from `byee4/django-eb-template` (local copy in `~/Documents/work/03_templates/`). Its
`CHANGELOG.md` lists what the template provides. Internal use only unless stated otherwise.
