#!/usr/bin/env bash
# Local .venv setup. Creates .venv, installs deps, runs migrations, starts runserver.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "No .env found. Copying .env.example -> .env. Edit it, then rerun this script."
  cp .env.example .env
  exit 1
fi

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements-dev.txt

.venv/bin/python manage.py migrate
echo
echo "Starting dev server at http://localhost:8000/"
exec .venv/bin/python manage.py runserver
