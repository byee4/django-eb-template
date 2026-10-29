#!/usr/bin/env bash
# Install the agent kit's protected config into place (run once after creating a project from
# this template, and again after updating .agent/install/). Idempotent. (The config is stored
# without leading dots because some file-sync tools refuse to write .claude/.github paths.)
#   .agent/install/claude/                 -> .claude/                 (Claude Code permissions/sandbox/hooks)
#   .agent/install/codex/                  -> .codex/                  (Codex hooks)
#   .agent/install/github/                 -> .github/                 (CI, Dependabot, CODEOWNERS, PR template)
#   .agent/install/pre-commit-config.yaml  -> .pre-commit-config.yaml
#   .agents/skills/  (canonical)           -> .claude/skills/          (mirror for Claude Code)
# Existing files that differ are backed up to <file>.bak-<date> before being replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
stamp=$(date +%Y%m%d%H%M%S)
src=.agent/install
dest_for() {
  case "$1" in
    claude/*) echo ".claude/${1#claude/}" ;;
    codex/*) echo ".codex/${1#codex/}" ;;
    github/*) echo ".github/${1#github/}" ;;
    pre-commit-config.yaml) echo ".pre-commit-config.yaml" ;;
    *) echo "$1" ;;
  esac
}
while IFS= read -r -d '' f; do
  rel=$(dest_for "${f#"$src"/}")
  if [[ -f "$rel" ]] && ! cmp -s "$f" "$rel"; then cp "$rel" "$rel.bak-$stamp"; echo "backed up $rel -> $rel.bak-$stamp"; fi
  mkdir -p "$(dirname "$rel")"; cp "$f" "$rel"; echo "installed $rel"
done < <(find "$src" -type f -print0)
if [[ -d .agents/skills ]]; then
  rm -rf .claude/skills && mkdir -p .claude && cp -R .agents/skills .claude/skills && echo "synced .claude/skills"
fi
chmod +x .agent/hooks/* .agent/done.sh 2>/dev/null || true
mkdir -p logs/agent
if command -v pre-commit >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1; then
  PC="pre-commit"; command -v pre-commit >/dev/null 2>&1 || PC="uvx pre-commit"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    $PC autoupdate >/dev/null 2>&1 && echo "pre-commit revs updated" || echo "pre-commit autoupdate skipped (offline?)"
    $PC install && echo "pre-commit hook installed"
  fi
else
  echo "Install pre-commit (uv tool install pre-commit) and re-run to enable commit-time checks."
fi
cat <<'MSG'

Agent kit installed. Next:
  - Codex: open the repo and trust the project hooks with /hooks.
  - Claude Code: hooks load from .claude/settings.json; check with /hooks.
  - GitHub: protect main (require PRs, CI, and CODEOWNERS review).
  - Workflow actions are pinned to commit SHAs (version in a comment); Dependabot updates them
    weekly after a 7-day cooldown. Re-pin any action you add (e.g. `pinact run`).
MSG
