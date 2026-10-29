"""The generator produces a clean, renamed, committed project without leaking local state."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.org",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.org",
}


@pytest.fixture(scope="module")
def project(tmp_path_factory):
    target = tmp_path_factory.mktemp("generated") / "lab-portal"
    subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "create_project.py"),
            str(target),
            "--slug",
            "lab-portal",
            "--name",
            "Lab Portal",
            "--skip-sync",
            "--skip-index",
        ],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, **GIT_IDENTITY},
    )
    return target


def git(project, *args):
    return subprocess.run(
        ["git", *args], cwd=project, check=True, capture_output=True, text=True
    ).stdout


def test_template_names_are_replaced(project):
    assert "EB_APP_NAME=lab-portal" in (project / ".env.example").read_text()
    assert 'name = "lab-portal"' in (project / "pyproject.toml").read_text()
    leftovers = subprocess.run(
        ["git", "grep", "-l", "-i", "-e", "django-template", "-e", "django_template"],
        cwd=project,
        capture_output=True,
        text=True,
    )
    assert leftovers.returncode == 1, leftovers.stdout  # 1 = no matches


def test_env_has_a_real_secret_and_is_not_committed(project):
    env = (project / ".env").read_text()
    assert "REPLACE_ME_GENERATE_LOCAL_KEY" not in env
    assert ".env" not in git(project, "ls-files").split()


def test_local_state_and_generator_are_not_copied(project):
    assert not (project / ".venv").exists()
    assert not (project / "tests" / "test_create_project.py").exists()
    assert not (project / "scripts" / "create_project.py").exists()
    assert not list(project.rglob(".DS_Store"))
    assert not list(project.rglob("__pycache__"))


def test_agent_kit_installed_and_committed_on_main(project):
    assert (project / ".claude" / "settings.json").is_file()
    assert git(project, "branch", "--show-current").strip() == "main"
    assert git(project, "status", "--porcelain") == ""
    assert ".claude/settings.json" in git(project, "ls-files").split()


def test_existing_target_is_refused(project):
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "create_project.py"), str(project),
         "--slug", "x-y", "--name", "X"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2
    assert "already exists" in result.stderr
