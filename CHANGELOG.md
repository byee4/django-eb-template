# Changelog

## 2026-11-17 — no built-in Globus allowlist

The Globus identity and group IDs that shipped as defaults in `config/settings.py` and
`.env.example` are removed. A new project now lets nobody log in until its owner sets
`GLOBUS_ALLOWED_IDENTITIES` or `GLOBUS_ALLOWED_GROUP`. Projects already made from the template
are unaffected: they keep their own `.env` and EB environment variables.

## 2026-10-29 — merged django-eb-template

The earlier `django-eb-template` (formerly `01_active/django-eb-template`, now archived) was merged
into this template, which is now published as `byee4/django-eb-template`.

- **Tooling:** dependencies in `pyproject.toml` + `uv.lock` (uv), `Makefile` (`setup`, `run`,
  `verify`, `lock`, `deploy-*`), mypy added to the definition of done. CI and Dependabot use uv.
  `requirements.txt` is exported from the lock for the Docker image; `requirements-dev.txt` removed.
- **Generator:** `scripts/create_project.py` creates a renamed project with a fresh secret, the agent
  kit installed, a first commit on `main`, dependencies installed and the code graph indexed;
  optional `--github` and `--beads`.
- **Per-environment AWS:** `one_time_setup.sh` and `deploy.sh` take `test` or `prod` explicitly. Each
  environment gets its own ECR repository and RDS instance (previously one database was shared).
  Test defaults to a single instance, prod to load-balanced.
- **HTTPS:** CloudFront by default (works without a domain); ACM certificate on the load balancer
  when `CUSTOM_DOMAIN_<ENV>` is set, with optional Route 53 validation.
- **Hardening:** production refuses the development secret key and wildcard hosts; clickjacking
  middleware; Globus OAuth callback recovery middleware; `.dockerignore` keeps `.env` out of the
  image (it was previously copied in); default file storage configured; `/healthz/` answers load
  balancer checks whatever the Host header; EB environment variables are pushed as JSON so values
  containing commas aren't split.
