# AGENTS.md

## Shell script quality gate

This repository is Bash-first. After editing any `.sh` file or shell test, run:

```bash
./scripts/check.sh
```

For legacy cleanup work, run the stricter informational gate:

```bash
./scripts/check.sh --strict
```

Required local tools:

```txt
shellcheck
shfmt
bats
shellspec
checkbashisms
```

## Repository structure

- User-facing commands live in `bin/`.
- Shared sourced Bash code lives in `lib/`.
- Development automation lives in `scripts/`; real-stack drills live in `scripts/drills/`.
- Keep `docs/repository-map.md` synchronized when a version-controlled file is added, moved, removed, or changes responsibility.

`checkbashisms` is only for POSIX `/bin/sh` scripts. The Supabase scripts are Bash scripts, so Bash syntax is expected.

## Test policy

- `bash -n` must pass for all shell scripts.
- `shellcheck -x -S error` must pass for all shell scripts.
- `shfmt -d -i 2 -ci -sr` must pass for actively refactored scripts.
- `bats tests` must pass for behavior tests.
- `shellspec` runs when a `spec/` directory exists.

`--strict` must pass before broad refactors or release-style changes.

For normal agent work, `./scripts/check.sh` is the command that must run after changes.

## Agent-readable shell comments

Use comments to document intent and contracts, not obvious syntax. Critical shell functions should have a compact `Contract:` block when they cross a boundary, mutate state, call external systems, or can destroy data.

Required fields for destructive or high-risk functions:

```txt
Purpose
Inputs
Effects
Safety
Failure
```

Avoid line-by-line narration such as "increment counter" or "assign variable"; prefer documenting why the step exists, what state it reads/writes, and what guarantee callers can rely on.

## RTK usage

- Use explicit `rtk` for supported commands that read large files or produce meaningful diff/output.
- If an `rtk` command produces empty, misleading, or failed output, fall back to a targeted shell command and keep the scope small.
- Do not use `rtk diff fileA fileB` to inspect repo changes; it compares files. Use `git diff -- file` or a supported RTK repo diff command.

## Bash refactor guardrails

- In `set -e` scripts, helper functions must end with an explicit successful command such as `return 0` when their final operation may be a false `[[ ... ]]`, `grep`, or conditional probe.
- When passing associative arrays through `declare -n`, pass the original variable name string to nested helpers, not the local nameref variable name. Passing the nameref itself can create circular nameref failures.
- Add focused behavior tests for every extracted helper that mutates files, calls external commands, or controls destructive restore/update flow.
- For restore/update scripts, test stopped-stack and running-stack paths separately; stack state changes are common sources of hidden logic bugs.
- Keep heavy real Supabase stack drills separate from the normal quality gate. Prefer fast Bats scenario fixtures for daily regression coverage; run `scripts/drills/integration-scenario.sh` only as a manual/scheduled release drill.
- `-y` must never bypass integrity failures. Broken manifests or failed hash checks must stop non-interactive restore before destructive commands.
- Resolve destructive paths and Supabase `project_id` canonically before stop/remove/volume operations; never trust the raw input path or directory basename.
- Backup verification must compare every manifest SHA-256 and require the core SQL dumps. Format-only checks are not an integrity gate.
- Physical Docker volumes must be archived while the stack is stopped. Always restart the stack on both success and failure paths.
- Backup roots and dump files are sensitive; enforce a private umask instead of relying on the caller environment.
- Disposable stack port remapping must support both legacy `[inbucket]` and current `[local_smtp]` config sections, plus analytics and pooler ports.
- Full SQL dumps/restores must preserve ownership and ACL metadata. Restore Supabase-managed objects with `supabase_admin`; `postgres` is not superuser in current local stacks.
- Do not run `pg_restore --clean` over an initialized Supabase database. Restore into an empty temporary DB first, then swap database names only after restore succeeds.
- Recreated Docker volumes must retain both `com.docker.compose.project` and `com.supabase.cli.project` labels so Supabase cleanup can manage them.
- Update, backup, restore, and reset must share the project operation lock and persistent journal; nested helper calls reuse the parent operation context.
- CLI update is also a CLI-managed stack image update. It requires a running stack, verified backup, successful stop/start, and post-update health verification.
- A failed update after stack stop must attempt old-CLI plus physical-backup recovery; interrupted update journals remain recoverable through the explicit recovery path.
- Manifest integrity failures are never interactive overrides. Volume restore requires compatible CLI/PG state; SQL restore must reject downgrade and unavailable extensions.
- Backups are built in hidden staging directories and atomically published. Configured mirror targets must be independently verified before success.
- Reset requires a verified backup and must never run global `docker system prune -a --volumes`.
- CLI updates mutate a host-global binary, so they require both the host-global update lock and the project operation lock.
- Physical volume archives must use GNU tar with ownership, ACL, and all xattrs preserved; Storage object bytes depend on extended attributes.
- Configured mirror backups must be encrypted with a private 0600 key file, decrypt-tested, and SHA-256 verified after atomic publication.
- Mirror import must reject unsafe tar paths and non-regular special entries, then pass normal manifest verification before publication.
- Retention must handle local and encrypted mirror targets together and preserve a configurable minimum newest-backup count per target.
- Update must pass configurable backup-target and package-staging free-space checks before backup or stack stop.
- Release recovery validation must include a real SIGKILL interruption followed by the explicit `--recover` path.
- Automated jobs must preserve the wrapped command exit status; notification hook failure must not hide the original operation failure.
- Release validation must include both `scripts/drills/integration-scenario.sh --scenario all` and `scripts/drills/cli-update-drill.sh --scenario all`.
