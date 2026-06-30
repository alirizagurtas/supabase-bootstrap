# Codex runtime backup ve restore

Bu doküman, makine formatlanırsa veya kaybolursa Codex çalışma ortamının nasıl
geri getirileceğini tanımlar. Amaç yalnız script çalıştırmak değil; sıfır
hafızalı biri bu dosyayı okuyunca hangi riski aldığımızı, neyi yedeklediğimizi
ve restore sonrası neyi doğrulayacağını anlayabilmesidir.

## Kapsam

Varsayılan backup modu `full` olur. Bu mod şu Codex runtime yüzeylerini alır:

| Yol | Neden alınır |
| --- | --- |
| `~/.codex/AGENTS.md` | Global ajan davranışı ve kalıcı kişisel kurallar |
| `~/.codex/RTK.md` | RTK kullanım disiplini |
| `~/.codex/config.toml.sanitized` | Secretsız Codex config geri kurulum referansı |
| `~/.codex/docs/` | Global runbook, paket ve failure dokümanları |
| `~/.codex/skills/` | Kişisel/custom skill tanımları |
| `~/.codex/memories/` | Öğrenilmiş hafıza, kullanıcı tercihleri ve özetler |
| `~/.codex/sessions/` | Ham konuşma geçmişi, resume/fork ve audit kaydı |
| `~/.codex/plugins/` | Cache hariç plugin metadata ve yerel plugin kaynakları |

`essential` modu `sessions/` dizinini almaz. Bu mod daha küçük artifact üretir
ama tam konuşma geçmişi ve forensic kayıtlar geri gelmez.

## Bilerek dışarıda bırakılanlar

Backup whitelist mantığıyla çalışır. Yani `~/.codex` içindeki her şey alınmaz;
yalnız bilinen gerekli yüzeyler toplanır.

Şunlar backup'a girmez:

- `auth.json`
- token, OAuth veya credential state
- `cache/`
- `log/`
- `tmp/` ve `.tmp/`
- `sqlite/`
- `shell_snapshots/`
- `plugins/cache/`

`config.toml` doğrudan alınmaz; `config.toml.sanitized` olarak kaydedilir.
Sanitize adımı `projects`, `hooks.state` ve token/password/secret/credential/auth
anahtarlarını dışarıda bırakır.

## Riskler

- `memories/` kullanıcı tercihleri, proje kararları ve öğrenilmiş hatalar
  içerir. Kaybolursa yeni makinede davranış kalitesi düşer.
- `sessions/` ham konuşma geçmişidir ve hassas bilgi içerebilir. Full backup
  için önemlidir ama Git'e commitlenmez.
- Backup artifact repository içine yazılmaz. Hedef dizin Git dışı olmalıdır.
- Artifact mümkünse şifreli/off-host saklanmalıdır. Bu script güvenli kapsam
  üretir; storage encryption politikasını backup hedefi sağlar.

## Backup alma

Full backup:

```bash
./scripts/backup-codex-runtime.sh --target /mnt/backup/codex
```

Essential backup:

```bash
./scripts/backup-codex-runtime.sh --target /mnt/backup/codex --mode essential
```

Sıkıştırılmamış test çıktısı:

```bash
./scripts/backup-codex-runtime.sh --target /tmp/codex-backup --no-compress
```

Backup içinde `manifest.json` bulunur. Manifest şunları kaydeder:

- oluşturma zamanı
- host adı
- backup modu
- Codex home yolu
- `codex`, `rtk`, `serena`, `ast-grep` version bilgileri
- dahil edilen/dışlanan yüzeyler
- dosya checksum listesi

## Restore

Önce dry-run:

```bash
./scripts/restore-codex-runtime.sh \
  --archive /mnt/backup/codex/codex-runtime-YYYYMMDDTHHMMSSZ-full.tar.gz \
  --dry-run
```

Gerçek restore:

```bash
./scripts/restore-codex-runtime.sh \
  --archive /mnt/backup/codex/codex-runtime-YYYYMMDDTHHMMSSZ-full.tar.gz \
  --yes
```

Restore mevcut `~/.codex` dizinini silmez. Önce aynı dizinin yanında
timestamp'li `.pre-restore` safety copy oluşturur, sonra backup içeriğini geri
yazar. Backup içinden `auth.json` geri yüklenmez.

## Restore sonrası doğrulama

Restore bittikten sonra şu komutlar çalıştırılır veya manuel doğrulanır:

```bash
codex doctor
codex mcp list
rtk verify --require-all
./scripts/check-agent-routing.sh
```

Beklenen önemli durumlar:

- Serena MCP varsayılan olarak disabled kalır.
- `supabase-local` MCP kaydı local endpoint olarak korunur:
  `http://127.0.0.1:54321/mcp`
- `memories/` ve full modda `sessions/` geri gelmiştir.
- `auth.json` geri gelmediği için gerekirse `codex login` yeniden yapılır.

## Sandbox felaket drill'i

Gerçek `$HOME/.codex` dizinine dokunmadan uçan makine senaryosu test edilir:

```bash
./scripts/drills/codex-runtime-restore-drill.sh
```

Bu drill `/tmp` altında fake Codex home oluşturur, full backup alır, kaynak
Codex home'u kaybolmuş gibi taşır ve yeni bir Codex home'a restore eder. Sonra
şunları doğrular:

- `memories/` geri geldi.
- `sessions/` geri geldi.
- `AGENTS.md`, `RTK.md`, `docs/`, `skills/` geri geldi.
- `config.toml` secretsız sanitized içerikten üretildi.
- `auth.json`, `cache/` ve `plugins/cache/` geri gelmedi.
- Backup manifestinde `mode=full`, `sessions/` ve checksum bilgisi var.

## Sıfır makine felaket akışı

1. Yeni Linux/Hetzner makinede repo clone edilir.
2. Backup artifact off-host storage'dan indirilir.
3. `scripts/restore-codex-runtime.sh --archive ... --dry-run` çalıştırılır.
4. Eksik tool'lar kurulur: `codex`, `rtk`, `uv`, `serena`, `ast-grep`, `rg`, `gh`.
   Ubuntu üzerinde `rg` için paket adı `ripgrep` olur:

   ```bash
   sudo apt-get install -y ripgrep
   ```
5. `scripts/restore-codex-runtime.sh --archive ... --yes` çalıştırılır.
6. Restore sonrası doğrulama komutları çalıştırılır.
7. Gerekirse `codex login` ve GitHub auth tekrar yapılır.
