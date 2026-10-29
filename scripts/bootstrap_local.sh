#!/usr/bin/env bash
# Local setup with uv: installs the locked dependencies into .venv, runs migrations, starts runserver.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "No .env found. Copying .env.example -> .env. Edit it, then rerun this script."
  cp .env.example .env
  exit 1
fi

command -v uv >/dev/null 2>&1 || { echo "Install uv first: https://docs.astral.sh/uv/" >&2; exit 2; }
uv sync --all-groups
uv run python manage.py migrate
echo
echo "Starting dev server at http://localhost:8000/"
exec uv run python manage.py runserver
