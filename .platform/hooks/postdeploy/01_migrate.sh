#!/usr/bin/env bash
# Post-deploy hook: run migrations inside the running app container.
# EB sets up the container; we re-exec migrate after each deploy.
set -euo pipefail

CONTAINER_ID="$(docker ps --filter "ancestor=$(awk -F'"' '/"Name"/ {print $4; exit}' /var/app/current/Dockerrun.aws.json)" --format '{{.ID}}' | head -n 1)"
if [[ -n "$CONTAINER_ID" ]]; then
  docker exec "$CONTAINER_ID" python manage.py migrate --noinput
fi
