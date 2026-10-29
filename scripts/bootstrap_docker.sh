#!/usr/bin/env bash
# Docker Compose dev setup. Builds image, starts web + postgres, runs migrations.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "No .env found. Copying .env.example -> .env. Edit it, then rerun this script."
  cp .env.example .env
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker Desktop and rerun." >&2
  exit 2
fi

docker compose up --build -d
echo
echo "Waiting for web container to be healthy..."
sleep 3
docker compose exec web python manage.py migrate --noinput || true
echo
docker compose ps
echo
echo "App: http://localhost:8000/"
echo "Logs: docker compose logs -f web"
