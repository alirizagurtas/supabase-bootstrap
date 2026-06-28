# Supabase operations runbook

Bu runbook tek bir Supabase CLI-managed self-host stack'in local Linux veya
Hetzner host üzerinde işletilmesi içindir. Ayrı bir Compose backend varsaymaz.

## Değişmez kurallar

- Her mutasyon `supabase/config.toml` içindeki `project_id` ile sınırlandırılır.
- Update başlamadan stack çalışıyor, backup doğrulanmış ve disk preflight geçmiş olmalıdır.
- Volume backup stack durdurulurken alınır; işlem sonunda stack yeniden başlatılır.
- `-y` manifest veya hash hatasını geçersiz kılamaz.
- Mirror anahtarı repository dışında ve yalnız sahibi okuyabilecek izinle tutulur.
- Restore provası yapılmamış backup, production recovery planı sayılmaz.

## Yerleşim

Önerilen production yolları:

```text
/usr/local/lib/supabase-automation   bu repository
/srv/supabase/<project>             Supabase proje dizini
/var/backups/supabase/local         local backup hedefi
/mnt/offsite/supabase               ayrı failure-domain mirror
/etc/supabase-backup/<name>.env     systemd environment
/etc/supabase-backup/mirror.key     chmod 600 encryption key
```

`supabase` servis kullanıcısının Docker erişimi, proje journal dizinine ve
backup hedeflerine yazma izni olmalıdır.

## Manuel backup

```bash
bin/supabase-backup.sh \
  --workdir /srv/supabase/project \
  --output /var/backups/supabase/local \
  --mirror /mnt/offsite/supabase \
  --mirror-key-file /etc/supabase-backup/mirror.key
```

Son backup'ı tekrar doğrulama:

```bash
bin/supabase-backup.sh \
  --verify /var/backups/supabase/local/<backup-id>
```

## Şifreli mirror import

Mirror arşivi doğrudan restore edilmez. Önce private staging ile decrypt edilir,
tar yolları ve dosya türleri kontrol edilir, ardından manifest doğrulanır:

```bash
bin/supabase-backup-maintenance.sh import-mirror \
  --archive /mnt/offsite/supabase/<backup-id>.tar.gpg \
  --key-file /etc/supabase-backup/mirror.key \
  --output /var/backups/supabase/local
```

Komut yalnız başarı durumunda `BACKUP_PATH=...` üretir. Bu yol normal
`bin/supabase-restore.sh` komutuna verilir.

## Retention

Local ve mirror retention aynı planla çalıştırılır. `--keep-min`, yaşından
bağımsız olarak her hedefte en yeni backup sayısını korur:

```bash
bin/supabase-backup-maintenance.sh prune \
  --output /var/backups/supabase/local \
  --mirror /mnt/offsite/supabase \
  --older-than 30d \
  --keep-min 3
```

Otomasyonda ancak hedef yollar doğrulandıktan sonra `--yes` kullanılmalıdır.

## CLI ve stack update

Komut proje kökü dışında çalıştırılıyorsa proje yolu açıkça verilmelidir:

```bash
export SUPABASE_PROJECT_DIR=/srv/supabase/project
```

`supabase/.temp` bulunduğu halde `supabase/config.toml` yoksa update durur.
Çalışan container adından config veya proje yolu tahmin edilmez; config önce
version control ya da güvenilir proje yedeğinden geri yüklenir.

```bash
SUPABASE_UPDATE_MIN_BACKUP_FREE_BYTES=10737418240 \
SUPABASE_UPDATE_MIN_TMP_FREE_BYTES=1073741824 \
bin/supabase-update.sh \
  --workdir /srv/supabase/project \
  --tag vX.Y.Z
```

Update; backup hedefi ve `/tmp` için boş alanı kontrol eder, backup alıp ayrıca
doğrular, stack'i durdurur, CLI paketini doğrular, stack'i başlatır ve servis
health kontrollerini çalıştırır.

Kesinti sonrası journal `running` veya `recovery_required` ise:

```bash
bin/supabase-update.sh --recover --workdir /srv/supabase/project -y
```

Yeni bir update başlatmadan önce recovery tamamlanmalıdır.

## Restore

Önce planı doğrula:

```bash
bin/supabase-restore.sh /var/backups/supabase/local/<backup-id> \
  --workdir /srv/supabase/project \
  --dry-run
```

Portable SQL restore:

```bash
bin/supabase-restore.sh /var/backups/supabase/local/<backup-id> \
  --workdir /srv/supabase/project \
  --strategy sql
```

Fiziksel volume restore yalnız uyumlu CLI ve PostgreSQL durumu doğrulandıktan
sonra seçilir:

```bash
bin/supabase-restore.sh /var/backups/supabase/local/<backup-id> \
  --workdir /srv/supabase/project \
  --strategy volume
```

## systemd backup timer

Repository'yi sabit production yoluna kur:

```bash
sudo install -d /usr/local/lib/supabase-automation
sudo cp -a bin lib scripts /usr/local/lib/supabase-automation/
sudo install -D -m 0644 deploy/systemd/supabase-backup@.service \
  /etc/systemd/system/supabase-backup@.service
sudo install -D -m 0644 deploy/systemd/supabase-backup@.timer \
  /etc/systemd/system/supabase-backup@.timer
sudo install -D -m 0600 deploy/systemd/project.env.example \
  /etc/supabase-backup/project.env
sudo systemctl daemon-reload
sudo systemctl enable --now supabase-backup@project.timer
```

İlk otomatik çalışmayı beklemeden doğrula:

```bash
sudo systemctl start supabase-backup@project.service
sudo systemctl status supabase-backup@project.service
sudo journalctl -u supabase-backup@project.service
```

## Failure notification hook

`SUPABASE_FAILURE_HOOK`, executable bir dosya olmalıdır. Argümanlar:

```text
<operation> <exit-status> <log-file>
```

Ayrıca `SUPABASE_NOTIFY_OPERATION`, `SUPABASE_NOTIFY_STATUS`,
`SUPABASE_NOTIFY_LOG`, `SUPABASE_NOTIFY_HOST` ve `SUPABASE_NOTIFY_TIME`
environment değerleri verilir. Hook hatası asıl komutun exit status değerini
değiştirmez.

Her yüksek riskli komut manuel olarak da sarılabilir:

```bash
SUPABASE_FAILURE_HOOK=/usr/local/libexec/supabase-failed \
scripts/notify-on-failure.sh --operation update -- \
  bin/supabase-update.sh --workdir /srv/supabase/project
```

## Periyodik doğrulama

Her release öncesi:

```bash
./scripts/check.sh --strict
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

## Supabase MCP

Local CLI-managed stack MCP endpoint'i:

```text
http://127.0.0.1:54321/mcp
```

Codex bağlantısı:

```bash
codex mcp add supabase-local --url http://127.0.0.1:54321/mcp
codex mcp get supabase-local
```

MCP yalnız schema/query/debug yardımcısıdır. Backup, restore, update, reset,
Docker volume veya recovery journal yönetimi lifecycle scriptlerinde kalır.
SQL/migration/schema mutasyonu açık kullanıcı talebi olmadan yapılmaz.

Self-hosted Hetzner MCP endpoint'i OAuth 2.1 sağlamaz ve internete açılmaz.
Erişim VPN ya da SSH tunnel üzerinden ayrı bir MCP client kaydıyla yapılır.

Hetzner host devreye alındığında ayrıca temiz-host restore, reboot/power-loss,
off-host mirror erişimi ve gerçek host update/rollback provası yapılmalıdır.
