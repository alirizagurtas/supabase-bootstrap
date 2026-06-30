# AGENTS.md

## Supabase operasyon skill'i

Backup, restore, update, reset, Docker volume, journal, mirror, retention,
systemd, recovery drill veya Hetzner yaşam döngüsü işi için
`supabase-operations` skill'i yüklenir ve takip edilir. Güvenlik sözleşmeleri
zorunludur.

## Kalite kapısı

Bu repository Bash-first çalışır.

```bash
./scripts/check.sh
./scripts/check.sh --strict
```

- Her shell veya shell-test değişikliğinden sonra normal kapıyı çalıştır.
- Geniş refactor ve release değişikliklerinde `--strict` çalıştır.
- İterasyon sırasında RTK ile sarılmış kapıları kullan; ham komutları final
  release kanıtına sakla.
- Release kanıtı ayrıca şunları gerektirir:

```bash
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

- Gerçek stack drill'lerini günlük kapıya koyma; manuel veya scheduled tut.
- Uzun test ve drill komutlarını tek-shot çalıştır. En fazla 30 saniyede bir
  poll et.

## Repository yapısı

- Kullanıcı komutları: `bin/`
- Ortak sourced Bash kodu: `lib/`
- Geliştirme otomasyonu: `scripts/`
- Gerçek stack drill'leri: `scripts/drills/`
- Testler: `tests/` ve `spec/`
- Kararlar ve runbook'lar: `docs/`
- Yapısal değişikliklerde `docs/repository-map.md` güncel tutulur.

## RTK ve context

- Shell işi öncesinde `RTK.md` oku; token disiplini için kısa repository
  giriş noktasıdır.
- `docs/agent-tool-routing.md` takip edilir; routing şu komutla doğrulanır:
  `./scripts/check-agent-routing.sh`.
- Serena MCP varsayılan olarak kapalıdır; yalnız açık kullanıcı isteğiyle
  etkinleştirilir. Aksi halde sözdizimsel yapı için `ast-grep`, tam metin için
  `rg`, yaklaşık 10 satırdan uzun desteklenen çıktı için açık RTK kullanılır.
- Kısa çıktı, exact bütünlük kanıtı veya eksik filtre durumunda ham komut
  kullanılır. Token tasarrufu için asla `rtk run` veya `rtk proxy` kullanılmaz.
- Uzun komutlar en fazla 30 saniyede bir poll edilir.
- Araştırma, implementasyon veya doğrulama fazı bitince alakasız yeni fazdan
  önce `/compact` önerilir.
- "status", "son durum" veya yalnız özet isteyen sorularda önce mevcut kanıt
  incelenir; kanıt eksik/eski değilse veya kullanıcı açıkça istemediyse strict
  gate ya da drill tekrar çalıştırılmaz.
- Token hassas işlerde kullanıcı hızı kotaya tercih ettiğini açıkça söylemedikçe
  Fast mode kapalı tutulur. Trivial işte low, varsayılan olarak medium, yalnız
  karmaşık recovery/security/ambiguous production kararlarında high reasoning
  kullanılır.
- Token disiplini değişikliklerinden sonra `./scripts/agent-token-report.sh`,
  tekrar edilebilir yerel eşik gerektiğinde
  `./scripts/agent-token-report.sh --check` çalıştırılır.

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

## Kritik sınırlar

- `-y`, bütünlük veya uyumluluk hatalarını asla bypass etmez.
- Yıkıcı kapsam basename'den değil, kanonik `supabase/config.toml` ve
  `project_id` değerinden çözülür.
- Global Docker prune kapalı tutulur.
- Fiziksel volume snapshot için stack durdurulmuş olmalı ve yeniden başlatma
  garanti edilmelidir.
- CLI update; doğrulanmış backup, stop/start, health doğrulaması ve recovery
  gerektirir.
- `supabase/`, `.supabase-ops/`, key dosyaları, loglar, backup'lar ve geçici
  drill state Git dışında tutulur.

## Supabase MCP

- `supabase-local`: `http://127.0.0.1:54321/mcp`.
- MCP varsayılan olarak read-only kullanılır; mutasyon için açık kullanıcı
  onayı gerekir.
- MCP, schema/query/debug işlerini tamamlar; lifecycle scriptlerinin yerini
  almaz.
- Hetzner MCP erişimi VPN veya SSH tunnel gerektirir; endpoint public internete
  açılmaz.
