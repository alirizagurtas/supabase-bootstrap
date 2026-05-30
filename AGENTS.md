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
- Keep heavy real Supabase stack drills separate from the normal quality gate. Prefer fast Bats scenario fixtures for daily regression coverage; run `scripts/integration-scenario.sh` only as a manual/scheduled release drill.
- `-y` must never bypass integrity failures. Broken manifests or failed hash checks must stop non-interactive restore before destructive commands.
