# Agent tool routing

Bu belge Codex'in repository üzerinde hangi aracı hangi amaçla kullanacağını
tanımlar. Kuralların çalıştığı şu komutla doğrulanır:

```bash
./scripts/check-agent-routing.sh
```

## Karar sırası

1. Serena MCP varsayılan olarak kapalıdır. Yalnız kullanıcı açıkça Serena
   istediğinde etkinleştir ve fonksiyon, symbol, çağıran veya referans için kullan.
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

## Doğrulama kanıtı

2026-06-28 tarihinde aynı repository üzerinde:

| Senaryo | Ham | Optimize | Sonuç |
| --- | ---: | ---: | ---: |
| `./scripts/check.sh --strict` | yaklaşık 1140 token | yaklaşık 42 token | `%96,3` azalma |
| 555 satırlık `supabase` araması | yaklaşık 12709 token | yaklaşık 4728 token | `%62,8` azalma |

Serena etkinleştirildiği testte `resolve_helpers` fonksiyonunu ve `main` içindeki
çağrısını doğru buldu.
`ast-grep` kontrollü fixture içinde gerçek `rm` komutunu bulurken yorum ve
`sudo rm` wrapper metnini eşleştirmedi. `rg` aynı fixture içindeki üç metinsel
geçişi de buldu; bu fark araç seçiminin neden niyete göre yapılması gerektiğini
gösterir.
