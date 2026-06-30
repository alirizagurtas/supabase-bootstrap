# Ajan araç yönlendirmesi

Bu belge Codex'in repository üzerinde hangi aracı hangi amaçla kullanacağını
tanımlar. Kuralların çalıştığı şu komutla doğrulanır:

```bash
./scripts/check-agent-routing.sh
```

## Karar sırası

1. Serena MCP varsayılan olarak kapalıdır. Yalnız kullanıcı açıkça Serena
   istediğinde etkinleştir ve fonksiyon, sembol, çağıran veya referans için kullan.
2. Serena kapalıyken veya soru kodun sözdizimsel yapısı hakkındaysa `ast-grep`
   kullan.
3. Soru düz metin, config, doküman veya hata mesajı hakkındaysa `rg` kullan.
4. Çalıştırılacak komut yaklaşık 10 satırdan uzun çıktı üretecekse uygun RTK
   filtresini kullan.
5. Hash, manifest, imza, tam diff veya release kanıtı gerekiyorsa ham ve
   eksiksiz çıktıyı kullan.

Serena açıkken karmaşık Bash ifadelerini parse edemezse `ast-grep`, ardından
dar kapsamlı `rg` kullanılır. Bu araçlar ShellCheck, Bats ve ShellSpec
doğrulamasının yerini almaz.

Serena kurulumu ve proje indeksi korunur; yalnız MCP ve Serena Codex hook'ları
kapalı tutulur. Böylece gerektiğinde yeniden kurulum yapmadan etkinleştirilebilir.

## RTK matrisi

| Amaç | Komut | Kural |
| --- | --- | --- |
| Test iterasyonu | `rtk test <command>` | Başarısızlık odaklıdır; nihai release kanıtını ham çalıştır. |
| Hata inceleme | `rtk err <command>` | Normal başarı çıktısını saklar; yalnız hata ve uyarı yeterliyse kullan. |
| Git | `rtk git status\|log\|diff\|show` | Ön incelemede kullan; exact patch gerekirse dar ham `git diff -- <path>` çalıştır. |
| GitHub | `rtk gh pr\|issue\|run` | PR, issue ve Actions çıktısında kullan. |
| Büyük metin arama | `rtk rg <pattern> <path>` | Küçük sonuçta doğrudan `rg` daha uygundur. |
| Dosya keşfi | `rtk find`, `rtk tree`, `rtk ls` | Büyük envanterde kullan. |
| Dosya okuma | `rtk read --max-lines N` | Keşif içindir; patch öncesi gerekli exact bağlamı oku. |
| Altyapı | `rtk docker`, `rtk psql` | Liste, log ve tablo çıktısını küçültür. |
| API/veri | `rtk curl`, `rtk json` | Exact response, hash veya imza kontrolünde ham çıktı kullan. |
| Log | `rtk log` | Tekrarlı logları gruplayıp küçültür. |
| Ölçüm/bakım | `rtk gain`, `rtk verify` | Faz sonunda ölç; RTK değişikliğinden sonra filtreleri doğrula. |

`rtk smart` ve `rtk summary` sezgiseldir; yalnız ilk keşifte kullanılabilir.
`rtk pipe` yalnız bilinen uygun bir filtre varsa kullanılır.
`--ultra-compact` yalnız büyük ara çıktılarda kullanılır.
Karmaşık `bash -c '...'` ifadelerini `rtk test` veya `rtk err` argümanı olarak
geçirme; RTK argüman birleştirmesi quoting'i bozabilir. Böyle bir akışı script
dosyası veya mevcut executable üzerinden çalıştır.

Şunlar token azaltmak için kullanılmaz:

- `rtk run`: ham çalıştırır, filtrelemez ve takip etmez.
- `rtk proxy`: filtrelemez, yalnız takip eder.
- `rtk diff`: repository diff'i değildir; iki dosyayı karşılaştırır.
- `rtk discover`, `rtk session`, `rtk learn`, `rtk cc-economics`: bu ortamda
  Codex geçmişini değil Claude Code geçmişini arar.
- `rtk hook-audit`: RTK shell hook'u olmayan Codex akışında uygulanmaz.

## Test ve drill disiplini

Token şişmesinin ana kaynağı uzun testlerin çıktısı değil, uzun süreçleri sık
poll etmektir. Bu yüzden doğrulama katmanları ayrı tutulur:

| Katman | Komut | Ne zaman |
| --- | --- | --- |
| Hızlı günlük kapı | `rtk test ./scripts/check.sh` | Shell veya test değişikliğinden sonra |
| Geniş kapı | `rtk test ./scripts/check.sh --strict` | Geniş refactor veya release hazırlığında |
| Ağır drill iterasyonu | `rtk err ./scripts/drills/integration-scenario.sh --scenario all` | Backup/restore/update kararları değiştiğinde |
| CLI update drill iterasyonu | `rtk err ./scripts/drills/cli-update-drill.sh --scenario all` | Update/recovery davranışı değiştiğinde |
| Final release kanıtı | Ham `./scripts/check.sh --strict` ve ham drill komutları | Sadece yayımlanacak kanıt gerektiğinde |

Uzun komutlar tek-shot çalıştırılır. Çalışan test veya drill en fazla 30 saniye
arayla poll edilir; başarılı uzun çıktı context'e basılmaz, özetlenir. Hata
incelemesinde `rtk err`, test iterasyonunda `rtk test` kullanılır. Exact release
kanıtı, hash, manifest veya tam çıktı gerekiyorsa ham komuta dönülür.

## Token/kota disiplini

RTK yalnız shell/tool çıktısını küçültür. Model reasoning, konuşma geçmişi,
AGENTS/skill metadata, web araştırması ve manuel `/compact` etkisini ölçmez.
Bu yüzden token kontrolü iki katmanlıdır:

| Katman | Araç | Kural |
| --- | --- | --- |
| Tool çıktısı | `rtk ...` | Desteklenen uzun çıktıda varsayılan. |
| Thread context'i | `/compact` | Araştırma, implementasyon, validation veya PR fazı bittikten sonra öner. |
| Reasoning | model ayarı | Trivial işte low, normalde medium, yalnız recovery/security/ambiguous production için high. |
| Hız/kredi | `/fast status`, `/fast off` | Kota hassas işlerde Fast mode kapalı varsayılır. |
| Ölçüm | `./scripts/agent-token-report.sh` | Faz sonunda düşük-token RTK etki raporu üretir. |
| Eşik kapısı | `./scripts/agent-token-report.sh --check` | RTK tasarrufu ve fallback sayısı eşiklerini doğrular. |

`status`, `son durum`, `değerlendir` veya summary-only sorularında önce mevcut
kanıtlar okunur: git durumu, validation raporu, son commit/PR durumu ve önceki
test çıktısı. Strict gate veya ağır drill tekrar çalıştırılmaz; yalnız kanıt
eksik, stale veya kullanıcı açıkça tekrar doğrulama istiyorsa çalıştırılır.

Subagent ana thread kirliliğini azaltabilir, ancak her subagent kendi model ve
tool işini yaptığı için toplam token tüketimini artırabilir. Bu repository'de
subagent yalnız kullanıcı açıkça isterse kullanılır.

Token etkisi ölçüm komutu:

```bash
./scripts/agent-token-report.sh
./scripts/agent-token-report.sh --check
```

Bu rapor RTK'nin etkisini ölçer; `/compact` sonrası model quota etkisi için
Codex `/status` çıktısı ayrıca yorumlanır.

## GitHub kayıt disiplini

GitHub üzerindeki kayıtlar kullanıcı tarafından sohbet geçmişi olmadan
okunabilmelidir. Bu yüzden yeni commit mesajları, PR başlıkları, PR gövdeleri ve
GitHub'a yazılan özetler Türkçe yazılır. Teknik isimler çevrilmez: komutlar,
path'ler, branch adları, paket isimleri, hata metinleri ve API terimleri olduğu
gibi korunur.

| Durum | Kural |
| --- | --- |
| Küçük fix | Türkçe, niyet odaklı commit mesajı yeterlidir. |
| Yeni davranış veya test kuralı | Commit mesajı Türkçe olur; açık PR varsa gövde aynı fazda güncellenir. |
| Production veya safety değişikliği | PR gövdesinde `Ne değişti`, `Neden`, `Doğrulama`, `Kalan işler` bölümleri güncellenir. |
| GitHub/PR/CI işi | Official GitHub skill okunur; gerekirse `gh` yalnız yerel checkout veya Actions boşlukları için kullanılır. |

Eski commit geçmişi rebase edilerek yeniden yazılmaz. Yeni kayıtlar Türkçe
tutulur; açık PR'ın başlığı ve gövdesi güncel kapsamı Türkçe anlatacak şekilde
yenilenir.

## Hata öğrenme ve fallback disiplini

Tekrarlanabilir komut hataları öğrenme sinyalidir. Önce hata sınıflandırılır:
ajan komut hatası, bilgi eskimesi, yazılım/API davranışı, ortam eksikliği,
permission/sandbox veya geçici dış hata. Çalışan çözüm bulunduysa kısa kayıt
`docs/failures/known-failures.md` içine yazılır.

Failure log token tasarrufu için lazy-load edilir. Dosya her oturumda tamamen
okunmaz. Hata olduğunda veya bilinen riskli komut tekrar çalıştırılacaksa
yalnız ilgili metin hedefli aranır:

```bash
rg -n "projectCards|gh pr edit|GraphQL" docs/failures/known-failures.md
```

| Durum | Varsayılan | Hata olursa |
| --- | --- | --- |
| PR başlığı/gövdesi güncelleme | `gh pr edit` | `gh api repos/OWNER/REPO/pulls/NUM -X PATCH` |
| PR/CI okuma | `rtk gh ...` | Exact JSON gerekiyorsa ham `gh ... --json ...` |
| Exact API body | Ham `gh api` | Hata metniyle failure log içinde hedefli `rg` ara |
| Bilinen riskli komut | Önce hedefli failure log araması | Kayıtlı fallback'i uygula ve sonucu güncelle |

## Doğrulama kanıtı

2026-06-28 tarihinde aynı repository üzerinde:

| Senaryo | Ham | Optimize | Sonuç |
| --- | ---: | ---: | ---: |
| `./scripts/check.sh --strict` | yaklaşık 1140 token | yaklaşık 42 token | `%96,3` azalma |
| 555 satırlık `supabase` araması | yaklaşık 12709 token | yaklaşık 4728 token | `%62,8` azalma |
| 2026-06-30 proje RTK toplamı | 152046 token input | 106381 token output | `46363 token / %30,5` azalma |
| 2026-06-30 günlük RTK ölçümü | 37337 token input | 21264 token output | `16073 token / %43,0` azalma |

Serena etkinleştirildiği testte `resolve_helpers` fonksiyonunu ve `main` içindeki
çağrısını doğru buldu.
`ast-grep` kontrollü fixture içinde gerçek `rm` komutunu bulurken yorum ve
`sudo rm` wrapper metnini eşleştirmedi. `rg` aynı fixture içindeki üç metinsel
geçişi de buldu; bu fark araç seçiminin neden niyete göre yapılması gerektiğini
gösterir.
