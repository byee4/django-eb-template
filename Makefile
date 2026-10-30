.DEFAULT_GOAL := help

.PHONY: help setup run dev migrate test lint format typecheck verify lock agent-kit deploy-test deploy-prod

help:
	@printf '%s\n' 'Targets: setup run dev migrate test lint format typecheck verify lock agent-kit deploy-test deploy-prod'

setup:  ## install the locked runtime and dev dependencies into .venv
	uv sync --all-groups

run:  ## local dev server on SQLite
	uv run python manage.py migrate
	uv run python manage.py runserver

dev:  ## Docker Compose with Postgres
	scripts/bootstrap_docker.sh

migrate:
	uv run python manage.py migrate

test:
	uv run pytest

lint:
	uv run ruff check .

format:
	uv run ruff format .

typecheck:
	uv run mypy .

verify:  ## definition of done (same as CI and the agent Stop hook)
	bash .agent/done.sh

lock:  ## after dependency changes: refresh uv.lock and Docker's requirements.txt
	uv lock
	uv export --frozen --no-dev --no-hashes --no-emit-project --output-file requirements.txt

agent-kit:
	scripts/install_agent_kit.sh

deploy-test:
	scripts/deploy.sh test

deploy-prod:
	scripts/deploy.sh prod
