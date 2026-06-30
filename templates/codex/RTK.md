# RTK - Codex kullanımı

RTK uzun komut çıktılarını context'e girmeden filtreler.

## Varsayılanlar

```bash
rtk test ./scripts/check.sh --strict
rtk err ./scripts/drills/integration-scenario.sh --scenario all
rtk git diff --stat
rtk gh pr checks
rtk rg "pattern" .
rtk read --max-lines 200 AGENTS.md
```

## Kurallar

- Test iterasyonunda `rtk test`, hata incelemede `rtk err` kullan.
- Git/GitHub ön incelemede `rtk git` ve `rtk gh` kullan.
- Exact patch, hash, manifest, imza, API body veya final release kanıtında ham
  komuta dön.
- Serena veya `ast-grep` çıktısını RTK ile sarmalama.
- `rtk run` ve `rtk proxy` token tasarrufu sağlamaz.
