# Codemap

Where things live in this project. Keep this current as the code changes.

## Top-level

| Path | Purpose |
|---|---|
| `manage.py` | Django CLI entrypoint |
| `config/` | Django project package (settings, urls, wsgi, asgi) |
| `main/` | Hello-world app, public home page + `/healthz/` |
| `chat/` | LLM chat (NRP Nautilus, OpenAI-compatible SSE streaming) |
| `accounts/` | Globus identity/group allowlist + audit middleware |
| `templates/base.html` | Shared layout (nav, content block) |
| `static/css/base.css` | Minimal styles |
| `scripts/` | Setup + deploy automation |
| `pyproject.toml`, `uv.lock` | Dependencies (uv) and ruff/pytest/mypy config |
| `requirements.txt` | Runtime deps exported from `uv.lock` for the Docker image (`make lock`) |
| `Makefile` | `setup`, `run`, `verify`, `lock`, `deploy-test`/`deploy-prod` |
| `.env.example` | All env vars with docstrings |
| `AGENTS.md`, `CLAUDE.md` | Agent instructions (CLAUDE.md imports AGENTS.md) |
| `.agents/skills/` | Agent runbooks (`ship-change`, `deploy`); mirrored to `.claude/skills/` |
| `.agent/` | Agent control plane: hooks, `policy.yaml`, `done.sh`, `install/` |
| `tests/` | Agent-kit self-test, production settings checks, generator test |
| `.mcp.json` | Declares the codebase-memory MCP server (opt-in per project) |

## Django config (`config/`)

- `settings.py` — env-driven config; `DEBUG` defaults True for local, False on EB. With
  `DEBUG=False` it refuses to start on the development secret key or wildcard hosts.
  `SECURE_PROXY_SSL_HEADER_NAME` switches HTTPS detection to CloudFront's header.
- `urls.py` — wires `social_django`, `chat`, `main`; provides `logout/` that also ends the Globus web session.
- `wsgi.py`/`asgi.py` — standard.

## `main/` (hello world)

- `views.home` → renders `main/index.html` (public)
- `views.healthz` → `/healthz/` JSON 200 (runs `SELECT 1`) for EB health checks
- `middleware.HealthCheckMiddleware` → answers `/healthz/` before Host validation (load balancers
  send the instance IP as Host)
- `tests.py` — smoke tests for both

## `chat/`

- `services.py` — `stream_chat(...)` yields SSE frames from the NRP OpenAI-compatible endpoint.
  Per-session cache salt is required (prevents cross-user prompt-cache leakage).
- `views.index` — chat page (login required)
- `views.message` — POST handler returning `text/event-stream`
- `templates/chat/chat.html` — minimal JS client that reads SSE chunks

## `accounts/`

- `permissions.enforce_globus_allowlist` — social-auth pipeline step that rejects
  logins not on `GLOBUS_ALLOWED_IDENTITIES` or in `GLOBUS_ALLOWED_GROUP`.
  Every accept/reject is logged.
- `middleware.AuditLogMiddleware` — logs every authenticated POST/PUT/PATCH/DELETE.
- `middleware.GlobusOAuthRecoveryMiddleware` — turns lost OAuth state and Globus 5xx on the
  callback into a clean retry instead of a 500.

## Deployment

- `Dockerfile` — `python:3.12-slim`, gunicorn on :8000.
- `docker-compose.yml` — local dev with Postgres.
- `Dockerrun.aws.json` — EB single-container manifest. Image tag is rewritten by `scripts/deploy.sh`.
- `.ebextensions/01_docker_health.config` — `/healthz/` health check.
- `.elasticbeanstalk/config.yml` — application name for `eb create` (rewritten by `one_time_setup.sh`).
- `.dockerignore` — keeps `.env` and local state out of the image.
- `.platform/hooks/postdeploy/01_migrate.sh` — runs `migrate` on each deploy.

## Scripts

- `scripts/create_project.py` — template only: creates a renamed, committed project (not copied into projects)
- `scripts/bootstrap_local.sh` — `uv sync` + migrate + runserver
- `scripts/bootstrap_docker.sh` — `docker compose up`
- `scripts/lib/aws_env.sh` — picks test/prod and derives that environment's AWS names
- `scripts/one_time_setup.sh test|prod` — ECR, RDS, EB app + env, HTTPS (CloudFront or ACM), env vars (with prompts)
- `scripts/deploy.sh test|prod` — build + push exact image tag, migrate, package bundle, deploy
- `scripts/install_agent_kit.sh` — puts `.agent/install/` (Claude/Codex config, CI, Dependabot, pre-commit) in place
