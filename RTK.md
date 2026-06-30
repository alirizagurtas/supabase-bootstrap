# RTK.md

Repository içi RTK kural özeti. Detaylı karar matrisi:
`docs/agent-tool-routing.md`.

## Varsayılan

- Yaklaşık 10 satırdan uzun desteklenen çıktı bekleniyorsa RTK kullan.
- Kısa/exact kanıt, hash, manifest, imza ve final release çıktısında ham komut
  kullanılabilir.
- Token tasarrufu için `rtk run` veya `rtk proxy` kullanma; bunlar filtreleme
  sağlamaz.
- Uzun test/drill komutlarını tek-shot çalıştır; en fazla 30 saniyede bir poll
  et.
- Faz sonunda ölçüm için:

```bash
./scripts/agent-token-report.sh
```

## Sık kullanılanlar

```bash
rtk test ./scripts/check.sh
rtk test ./scripts/check.sh --strict
rtk err ./scripts/drills/integration-scenario.sh --scenario all
rtk git status --short
rtk gh pr view
rtk rg "pattern" path
```
