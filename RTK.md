# RTK.md

Repository içi RTK kural özeti. Detaylı karar matrisi:
`docs/agent-tool-routing.md`.

## Varsayılan

- Yaklaşık 10 satırdan uzun desteklenen çıktı bekleniyorsa RTK kullan.
- Komutun RTK karşılığı belirsizse önce `rtk rewrite "<komut>"` dene.
  RTK 0.43.0 üzerinde `rewrite` çıktı üretip non-zero exit döndürebildiği için
  automation içinde stdout'u esas al.
- Kısa/exact kanıt, hash, manifest, imza ve final release çıktısında ham komut
  kullanılabilir.
- Token tasarrufu için `rtk run` veya `rtk proxy` kullanma; bunlar filtreleme
  sağlamaz.
- Repo diff için `rtk git diff` kullan; `rtk diff` iki dosya/stdin diff
  filtresidir.
- Uzun test/drill komutlarını tek-shot çalıştır; en fazla 30 saniyede bir poll
  et.
- RTK kullanım kapsamı değişirse şu test çalışır:

```bash
rtk test ./scripts/check-rtk-command-matrix.sh
```

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
rtk find docs -type f
rtk read README.md --max-lines 80
rtk json --keys-only file.json
rtk log file.log
rtk rewrite "git status --short"
```

## Kullanım matrisi

| İş | Varsayılan |
| --- | --- |
| Test | `rtk test <command>` |
| Hata/warning inceleme | `rtk err <command>` |
| Git | `rtk git status\|log\|diff\|show` |
| GitHub | `rtk gh pr\|issue\|run` |
| Metin arama | `rtk rg`, gerekirse `rtk grep` |
| Dosya keşfi | `rtk find`, `rtk tree`, `rtk ls` |
| Dosya okuma | `rtk read --max-lines N`, `rtk read -l aggressive` |
| Log | `rtk log` |
| JSON | `rtk json --keys-only` |
| Docker/Postgres/API | `rtk docker`, `rtk psql`, `rtk curl` |
| Ölçüm | `rtk gain`, `rtk verify` |

`rtk discover`, `rtk session`, `rtk learn`, `rtk cc-economics` Claude Code
geçmişi/ekonomisi odaklıdır; bu Codex repo akışında varsayılan değildir.
`rtk learn --write-rules` açık istek olmadan çalıştırılmaz.
