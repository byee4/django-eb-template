#!/usr/bin/env bash
# Definition of done for this repo. Run by the Stop hook, by CI, and by humans.
# Every command must pass before an agent may report a task complete.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
run() { echo "+ $*"; "$@" || { echo "FAILED: $*"; fail=1; }; }
export DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-agent-check-key}" DJANGO_DEBUG="${DJANGO_DEBUG:-True}"
PY=python3; [[ -x .venv/bin/python ]] && PY=.venv/bin/python
run "$PY" -m ruff check .
run "$PY" manage.py check
run "$PY" manage.py makemigrations --check --dry-run
run "$PY" -m pytest -q
"$PY" -m pytest -q -p no:cacheprovider tests/test_agent_kit.py >/dev/null 2>&1 || { echo 'FAILED: agent kit self-test (tests/test_agent_kit.py)'; fail=1; }
exit $fail
