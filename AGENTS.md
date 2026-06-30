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
- During iteration, use RTK-wrapped gates; reserve raw commands for final
  release evidence.
- Release evidence also requires:

```bash
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

- Keep real-stack drills manual/scheduled, not in the daily gate.
- Treat long-running tests and drills as single-shot commands. Poll them no
  more often than every 30 seconds.

## Repository structure

- User commands: `bin/`
- Shared sourced Bash: `lib/`
- Development automation: `scripts/`
- Real-stack drills: `scripts/drills/`
- Tests: `tests/` and `spec/`
- Decisions and runbooks: `docs/`
- Keep `docs/repository-map.md` synchronized with structural changes.

## RTK and context

- Read `RTK.md` before shell work; it is the short repo entrypoint for token
  discipline.
- Follow `docs/agent-tool-routing.md`; validate routing with
  `./scripts/check-agent-routing.sh`.
- Serena MCP is disabled by default; enable it only on explicit user request.
  Otherwise use `ast-grep` for syntax structure, `rg` for exact text, and
  explicit RTK for supported output expected to exceed about 10 lines.
- Use raw commands for short output, exact integrity evidence, or incomplete
  filters. Never use `rtk run` or `rtk proxy` for token savings.
- Poll long commands no more often than every 30 seconds.
- After a completed research, implementation, or validation phase, recommend `/compact` before an unrelated phase.
- For "status", "son durum", or summary-only questions, inspect existing
  evidence first; do not rerun strict gates or drills unless the evidence is
  missing, stale, or the user explicitly asks.
- For token-sensitive work, keep Fast mode off unless the user explicitly
  chooses speed over quota. Use low reasoning for trivial work, medium by
  default, and high only for complex recovery, security, or ambiguous
  production decisions.
- Use `./scripts/agent-token-report.sh` after token-discipline changes and
  `./scripts/agent-token-report.sh --check` when a repeatable local threshold
  gate is needed.

## GitHub ve kayıt dili

- Yeni commit mesajları, PR başlıkları, PR gövdeleri ve GitHub'a yazılan
  özetler varsayılan olarak Türkçe olmalıdır.
- Komut adları, path'ler, paket adları, branch adları, hata metinleri ve API
  terimleri aynen korunur.
- Pushlanan her kapsam değişikliği, sohbet geçmişine ihtiyaç kalmadan GitHub
  history üzerinden anlaşılmalıdır.
- Pushlanan değişiklik kapsamı genişletirse aynı fazda PR gövdesi Türkçe
  `Ne değişti`, `Neden`, `Doğrulama` ve `Kalan işler` bölümleriyle güncellenir.

## Hata öğrenme döngüsü

- Tekrarlanabilir komut hataları aynı fazda sınıflandırılır ve çalışan fallback
  bulunduysa `docs/failures/known-failures.md` içine kısa kayıt eklenir.
- Failure log lazy-load edilir: tüm dosya varsayılan olarak okunmaz; yalnız hata
  olduğunda veya bilinen riskli komut öncesinde hedefli `rg` ile aranır.

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
