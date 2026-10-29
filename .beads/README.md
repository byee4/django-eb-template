# .beads (optional)

Issue tracking for agents via the [Beads](https://github.com/steveyegge/beads) `bd` CLI.
Status (Oct 2026): popular but early-stage — the storage backend has shifted (SQLite/JSONL ↔ Dolt),
and agents still need reminding to use it. Treat it as optional. If you don't use it, delete
`.beads/` and the Beads lines in `AGENTS.md`; GitHub Issues + `docs/specs/` cover the same need.

## First time

```bash
bd init        # creates the local DB; DB files and logs are gitignored
```

Check `bd --help` for your installed version: commit only what that version documents as
shareable (config, and its export file if you want issues in git).

## Day-to-day

```bash
bd ready                         # what's unblocked
bd create "Title" --body "Details"
bd update <id> --status in_progress
bd close <id>
```

Tie issues to specs in `docs/specs/`.
