# AGENTS.md

## Supabase operations skill

For backup, restore, update, reset, Docker volume, journal, mirror, retention,
systemd, recovery drill, or Hetzner lifecycle work, load and follow the
`supabase-operations` skill. Its safety contracts are mandatory.

## Quality gate

This repository is Bash-first.

```bash
./scripts/check.sh
./scripts/check.sh --strict
```

- Run the normal gate after any shell or shell-test change.
- Run `--strict` for broad refactors and release changes.
- Release evidence also requires:

```bash
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

- Keep real-stack drills manual/scheduled, not in the daily gate.

## Repository structure

- User commands: `bin/`
- Shared sourced Bash: `lib/`
- Development automation: `scripts/`
- Real-stack drills: `scripts/drills/`
- Tests: `tests/` and `spec/`
- Decisions and runbooks: `docs/`
- Keep `docs/repository-map.md` synchronized with structural changes.

## RTK and context

- Check `rtk help`; use explicit RTK for supported output expected to exceed about 10 lines.
- Prefer `rtk test`, `rtk err`, `rtk git`, `rtk gh`, `rtk docker`, `rtk psql`, `rtk curl`, `rtk json`, and `rtk log`.
- Use raw commands only for short/exact evidence or after a filter proves incomplete.
- Use Serena for symbol-aware code discovery and edits; use `ast-grep` for structural syntax patterns; use `rg` for exact text.
- Poll long commands no more often than every 30 seconds.
- After a completed research, implementation, or validation phase, recommend `/compact` before an unrelated phase.

## Critical boundaries

- `-y` never bypasses integrity or compatibility failures.
- Resolve destructive scope from canonical `supabase/config.toml` and `project_id`, never basenames.
- Keep global Docker prune disabled.
- Physical volume snapshots require a stopped stack and guaranteed restart.
- A CLI update requires verified backup, stop/start, health verification, and recovery.
- Keep `supabase/`, `.supabase-ops/`, keys, logs, backups, and temporary drill state out of Git.

## Supabase MCP

- `supabase-local` is `http://127.0.0.1:54321/mcp`.
- MCP is read-only by default; mutations require explicit user authorization.
- MCP complements schema/query/debug work and never replaces lifecycle scripts.
- Hetzner MCP access requires VPN or SSH tunnel; never expose it publicly.
