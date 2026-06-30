# Dokümantasyon modeli

Bu repo docs-as-code modeliyle çalışır: dokümantasyon kodla aynı branch,
aynı review ve aynı kalite kapısı içinde güncellenir. Amaç, sohbet geçmişine
veya tek kişinin hafızasına ihtiyaç bırakmadan production operasyon kararlarını
repo içinde izlenebilir tutmaktır.

## Sınıflandırma

Dokümanlar Diátaxis yaklaşımına göre dört tipe ayrılır:

| Tip | Amaç | Bu repodaki karşılık |
| --- | --- | --- |
| Tutorial | Yeni kullanıcıya adım adım öğretir | Şimdilik ayrı tutulmuyor; ihtiyaç olursa `docs/tutorials/` açılır. |
| How-to / runbook | Bilinen işi güvenli şekilde yaptırır | `docs/operations-runbook.md`, `docs/integration-scenarios.md` |
| Reference | Dosya, komut, dependency ve sözleşme envanteri verir | `docs/repository-map.md`, `docs/dependencies.md`, `docs/agent-tool-routing.md` |
| Explanation / decision | Neden böyle tasarlandığını açıklar | `docs/lifecycle-decision-tree.md`, `docs/codex-runtime-backup.md` |

## Tek kaynak kuralları

- Dosya ve klasör sahipliği için tek kaynak: `docs/repository-map.md`.
- Paket ve araç önkoşulları için tek kaynak: `docs/dependencies.md`.
- Supabase yaşam döngüsü kararları için tek kaynak:
  `docs/lifecycle-decision-tree.md`.
- Operatör komutları için tek kaynak: `docs/operations-runbook.md`.
- Ajan/RTK routing kuralları için tek kaynak: `docs/agent-tool-routing.md`.
- Doğrulanmış test ve drill kanıtı için tek kaynak:
  `docs/validation-report.md`.

Aynı bilgi birden fazla dosyada gerekiyorsa ikinci dosya kısa özet ve link
tutar; ayrıntıyı tekrar etmez.

## Güncelleme tetikleyicileri

| Değişiklik | Güncellenecek dosya |
| --- | --- |
| Yeni dosya, taşınan dosya veya görev değişimi | `docs/repository-map.md` |
| Yeni required/optional komut, paket veya kurulum kaynağı | `docs/dependencies.md` |
| Apt-managed paket kurulum davranışı | `scripts/bootstrap-dev-tools.sh`, `docs/dependencies.md` |
| Backup, restore, update, reset veya recovery davranışı | `docs/lifecycle-decision-tree.md`, `docs/operations-runbook.md` |
| Test/drill kapsamı veya kanıtı | `docs/validation-report.md` |
| RTK, Serena, ast-grep, rg, Git/GitHub komut seçimi | `docs/agent-tool-routing.md` |
| Tekrarlanabilir komut hatası ve çalışan fallback | `docs/failures/known-failures.md` |

## Kalite kapısı

Dokümantasyon değişikliği yalnız yazı değişikliği gibi ele alınmaz. Değişiklik
bir komut, dependency, dosya adı veya operasyon davranışı anlatıyorsa ilgili
script/test de aynı PR içinde güncellenir.

Mevcut zorunlu kapı:

```bash
./scripts/check.sh
```

Geniş refactor, release veya production güvenliği etkileyen değişiklik:

```bash
./scripts/check.sh --strict
```

İleride dokümantasyon kapısı büyütülecekse sırayla eklenir:

1. Markdown biçim denetimi.
2. İç link denetimi.
3. Türkçe teknik yazım için düşük gürültülü prose lint.

Bu üçlü, faydası ölçülmeden zorunlu kapıya eklenmez.
