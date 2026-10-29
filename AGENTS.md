# AGENTS.md — django-template

Instructions for coding agents (Claude Code, Codex, Cursor, …) and humans. Procedures live in
`.agents/skills/`, facts in `docs/`, enforcement in `.agent/` (hooks + policy + done.sh).

## Project shape

```
config/       Django project (settings, urls, wsgi)
main/         Hello-world app — public landing page + /healthz/
chat/         NRP Nautilus LLM streaming chat (login required)
accounts/     Globus auth glue: identity/group allowlist + audit middleware
scripts/      one_time_setup.sh, deploy.sh, bootstrap_{local,docker}.sh, install_agent_kit.sh
.ebextensions/ .elasticbeanstalk/ .platform/   Elastic Beanstalk Docker deployment
docs/         codemap.md, globus_setup.md, deployment.md, specs/
.agents/skills/  ship-change, deploy (canonical; mirrored to .claude/skills)
.agent/       hooks, policy.yaml, done.sh — the agent control plane
.beads/       Optional issue tracking (bd CLI) — see .beads/README.md
```

## Before every change
1. Read `docs/codemap.md` and relevant `docs/specs/*.md`. Don't guess at structure.
2. Branch: `<agent-or-user>/<desc>` or `fix/<desc>`. Never commit to or push `main`.
3. Multi-step work: numbered plan with verify steps. Non-trivial features: write
   `docs/specs/YYYY-MM-DD-<topic>.md` first (goals, non-goals, checklist, failure modes).

## While changing
- Surgical edits; no speculative abstractions; match existing style.
- Every new write endpoint uses `@login_required` + `@require_POST` so it lands in the audit log
  (`accounts/middleware.py`). Destructive actions also log their *intent* (what + why) at INFO.
- Secrets stay in `.env` (agents never read it). Use `os.environ.get(...)`/`settings.X`;
  document new variables in `.env.example`.
- LLM chat: per-session cache salt stays (prevents cross-user prompt-cache leakage); never log
  prompt/response bodies; never retry NRP 503s server-side.

## Definition of done
`bash .agent/done.sh` passes (ruff, `manage.py check`, no missing migrations, pytest, agent-kit
self-test) and the change has a regression test. User-visible changes: smoke test with
`scripts/bootstrap_local.sh`. Deployment changes: dry-run and note the diff in the PR.
Update `docs/codemap.md` when a module or public surface changes.

## Guard rails (enforced)
The guard (`.agent/hooks/pre_tool_guard.py` + `.agent/policy.yaml`) blocks force-push, push to
`main`, `--no-verify`, `.env` access, `eb terminate`, RDS/ECR deletion and `manage.py flush`; it
asks a human before `scripts/deploy.sh`, `scripts/one_time_setup.sh`, any `eb`/`aws` command,
`docker push`, dependency installs, and edits to settings, auth/allowlist, audit middleware,
deployment config, and the agent control plane. Claude Code auto mode does not bypass it.
Deploys follow the `deploy` skill: the agent prepares and verifies; a human runs the command and
records EB env, version label, and git SHA in the PR.

## Failure modes to know about
- **Globus callback URL drift** when the EB CNAME changes — update the app's redirect URI (`docs/globus_setup.md`).
- **`docker-compose.yml` in the EB bundle** switches EB to Compose mode — `.ebignore` excludes it.
- **Allowlist lock-out** if `GLOBUS_ALLOWED_IDENTITIES` drops your own identity — test locally first.
- **NRP gateway 503** — chat shows a friendly error; users retry.

## Commits and PRs
Subject `<area>: <imperative summary>`; one change per PR; use the PR template (states which
agent/model wrote the change, pastes `done.sh` output, flags auth/deploy risk).
