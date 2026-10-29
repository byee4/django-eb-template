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
| `requirements.txt` | Runtime deps |
| `requirements-dev.txt` | Adds ruff + pytest |
| `pyproject.toml` | Ruff and pytest config |
| `.env.example` | All env vars with docstrings |
| `AGENTS.md`, `CLAUDE.md` | Agent instructions (CLAUDE.md imports AGENTS.md) |
| `.agents/skills/` | Agent runbooks (`ship-change`, `deploy`); mirrored to `.claude/skills/` |
| `.agent/` | Agent control plane: hooks, `policy.yaml`, `done.sh`, `install/` |
| `tests/test_agent_kit.py` | Verifies the agent control plane is wired and enforcing |

## Django config (`config/`)

- `settings.py` — env-driven config; `DEBUG` defaults True for local, False on EB.
- `urls.py` — wires `social_django`, `chat`, `main`; provides `logout/` that also ends the Globus web session.
- `wsgi.py`/`asgi.py` — standard.

## `main/` (hello world)

- `views.home` → renders `main/index.html` (public)
- `views.healthz` → `/healthz/` JSON 200 for EB ALB health checks
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

## Deployment

- `Dockerfile` — `python:3.12-slim`, gunicorn on :8000.
- `docker-compose.yml` — local dev with Postgres.
- `Dockerrun.aws.json` — EB single-container manifest. Image tag is rewritten by `scripts/deploy.sh`.
- `.ebextensions/01_docker_health.config` — `/healthz/` health check.
- `.elasticbeanstalk/config.yml` — application name + two-env default mapping.
- `.platform/hooks/postdeploy/01_migrate.sh` — runs `migrate` on each deploy.

## Scripts

- `scripts/bootstrap_local.sh` — `.venv` + migrate + runserver
- `scripts/bootstrap_docker.sh` — `docker compose up`
- `scripts/one_time_setup.sh` — GH repo, ECR, RDS, EB app, two EB envs, env vars (with confirmation prompts)
- `scripts/deploy.sh test|prod` — build + push image, migrate, package bundle, deploy
- `scripts/install_agent_kit.sh` — puts `.agent/install/` (Claude/Codex config, CI, Dependabot, pre-commit) in place
