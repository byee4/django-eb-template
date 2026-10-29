#!/usr/bin/env python3
"""Create a new project from this template.

    python3 scripts/create_project.py ../my-portal --slug my-portal --name "My Portal"

Copies the template (without caches, local state, or this generator), renames it, writes a .env
with a fresh Django secret, installs the agent kit, and commits everything to a new `main` branch.
Optional: install dependencies, index the codebase-memory graph, initialize Beads, and create a
GitHub repository.
"""

from __future__ import annotations

import argparse
import json
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

TEMPLATE_ROOT = Path(__file__).resolve().parents[1]

# Never copied: version control, environments, caches, local data, installed agent config
# (reinstalled fresh from .agent/install/), and the generator itself.
EXCLUDED_NAMES = {
    ".git",
    ".venv",
    ".deploy-venv",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
    ".mypy_cache",
    ".DS_Store",
    ".env",
    ".claude",
    ".codex",
    ".codebase-memory",
    "db.sqlite3",
    "staticfiles",
    "media",
    "create_project.py",
    "test_create_project.py",
}
EXCLUDED_PATTERNS = (re.compile(r"\.pyc$"), re.compile(r"\.bak-\d+$"), re.compile(r"\.jsonl$"))

SECRET_PLACEHOLDER = "REPLACE_ME_GENERATE_LOCAL_KEY"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("target", type=Path, help="new project directory (must not exist)")
    parser.add_argument("--slug", required=True, help="lowercase slug, e.g. research-portal")
    parser.add_argument("--name", required=True, help='display name, e.g. "Research Portal"')
    parser.add_argument("--github", help="create OWNER/REPO on GitHub as origin and push")
    parser.add_argument("--visibility", choices=("private", "public"), default="private")
    parser.add_argument("--beads", action="store_true", help="initialize Beads issue tracking")
    parser.add_argument("--skip-sync", action="store_true", help="skip `uv sync --all-groups`")
    parser.add_argument(
        "--skip-index", action="store_true", help="skip indexing the codebase-memory graph"
    )
    return parser.parse_args(argv)


def validate(args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[a-z][a-z0-9-]*[a-z0-9]", args.slug):
        raise ValueError("--slug must be lowercase letters, digits and hyphens, starting with a letter")
    if args.github and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.github):
        raise ValueError("--github must be OWNER/REPO")
    if args.target.exists():
        raise ValueError(f"target already exists: {args.target}")


def copy_template(target: Path) -> None:
    def ignore(_directory: str, names: list[str]) -> set[str]:
        return {
            name
            for name in names
            if name in EXCLUDED_NAMES or any(p.search(name) for p in EXCLUDED_PATTERNS)
        }

    shutil.copytree(TEMPLATE_ROOT, target, ignore=ignore)


def rename(target: Path, slug: str, name: str) -> None:
    replacements = {
        "django-template": slug,
        "django_template": slug.replace("-", "_"),
        "Django Template": name,
    }
    for path in target.rglob("*"):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        new = text
        for old, value in replacements.items():
            new = new.replace(old, value)
        if new != text:
            path.write_text(new, encoding="utf-8")


def strip_template_only(target: Path) -> None:
    """Drop README sections that only make sense in the template (e.g. how to run this script)."""
    readme = target / "README.md"
    text = re.sub(
        r"<!-- template-only:start -->.*?<!-- template-only:end -->\n?",
        "",
        readme.read_text(encoding="utf-8"),
        flags=re.S,
    )
    readme.write_text(text, encoding="utf-8")


def write_env(target: Path) -> None:
    text = (target / ".env.example").read_text(encoding="utf-8")
    (target / ".env").write_text(
        text.replace(SECRET_PLACEHOLDER, secrets.token_urlsafe(50)), encoding="utf-8"
    )


def run(command: list[str], cwd: Path, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, check=True, **kwargs)


def commit(target: Path, message: str) -> None:
    run(["git", "add", "-A"], target)
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=target).returncode:
        run(["git", "commit", "-q", "-m", message], target)


def install_commit_hooks(target: Path) -> None:
    """Best effort: pre-commit refuses when a global core.hooksPath is set, for example."""
    for command in (["pre-commit"], ["uvx", "pre-commit"]):
        if shutil.which(command[0]):
            if subprocess.run([*command, "install"], cwd=target).returncode:
                print("warning: commit hooks not installed; run `pre-commit install` once fixed.")
            return
    print("pre-commit not found; run `uv tool install pre-commit && pre-commit install` later.")


def initialize_beads(target: Path, slug: str) -> None:
    if shutil.which("bd") is None:
        raise RuntimeError("--beads needs the `bd` CLI on PATH")
    prefix = slug.replace("-", "")[:8]
    run(["bd", "init", "--non-interactive", "--prefix", prefix, "--skip-agents"], target)
    commit(target, "Initialize Beads issue tracking")


def index_codebase(target: Path) -> None:
    payload = json.dumps({"repo_path": str(target), "persistence": True})
    if shutil.which("codebase-memory-mcp") is None:
        print(
            "codebase-memory-mcp not found; skipped the code graph. Later, run:\n"
            f"  echo '{payload}' | codebase-memory-mcp cli index_repository"
        )
        return
    run(["codebase-memory-mcp", "cli", "index_repository"], target, input=payload, text=True)
    commit(target, "Index codebase-memory graph")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    validate(args)
    target = args.target.resolve()

    copy_template(target)
    rename(target, args.slug, args.name)
    strip_template_only(target)
    write_env(target)
    run(["bash", "scripts/install_agent_kit.sh"], target, stdout=subprocess.DEVNULL)
    run(["git", "init", "-q", "-b", "main"], target)
    commit(target, f"Create {args.name} from django-eb-template")
    install_commit_hooks(target)
    if args.beads:
        initialize_beads(target, args.slug)
    if not args.skip_sync:
        run(["uv", "sync", "--all-groups"], target)
    if not args.skip_index:
        index_codebase(target)
    if args.github:
        run(
            ["gh", "repo", "create", args.github, f"--{args.visibility}",
             "--source", ".", "--remote", "origin", "--push"],
            target,
        )

    print(f"\nCreated {args.name} at {target}")
    print("Next: fill in .env (Globus, NRP), then `make run` locally or `make verify`.")
    print("AWS: scripts/one_time_setup.sh test, then scripts/deploy.sh test (see docs/deployment.md).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from error
