# Supabase entegrasyon senaryoları

Bu doküman backup, restore ve update scriptleri için tekrar çalıştırılabilir
sağlık senaryolarını tanımlar.

## Test katmanları

Endüstri pratiği tek bir test türüne güvenmez:

```txt
static checks     shellcheck, shfmt, bash -n
unit/contract     fake command Bats testleri
scenario matrix   fixture veri + fake Docker/Supabase ile hızlı acceptance testleri
integration       disposable Supabase stack ile gerçek backup/restore drill
recovery drill    manuel veya scheduled disaster-recovery provası
CLI update drill  iki gerçek CLI sürümü ile update ve zorlanmış rollback
```

Bu repo için günlük hızlı kontrol:

```bash
./scripts/check.sh
```

Büyük refactor veya release kontrolü:

```bash
./scripts/check.sh --strict
```

Hızlı scenario matrix `./scripts/check.sh` içinde çalışır. Kapsadığı durumlar:

- stopped stack SQL restore
- functions/config/.env restore
- DB volume restore komut yolu
- bozuk manifest ile destructive işleme geçmeme

Gerçek stack smoke:

```bash
./scripts/drills/integration-scenario.sh
```

Varsayılan smoke senaryosu stack başlatır, fake veri yazar, backup alır,
manifest'i doğrular ve restore'u `--dry-run` plan seviyesinde dener. Full
restore yapmaz.

Gerçek stack drill:

```bash
./scripts/drills/integration-scenario.sh --scenario all
```

Gerçek CLI update ve recovery drill:

```bash
./scripts/drills/cli-update-drill.sh --scenario all
```

Debug için geçici proje ve backup dosyalarını tut:

```bash
./scripts/drills/integration-scenario.sh --scenario sql --keep
```

## Senaryo 1: Smoke backup ve restore planı

Komut:

```bash
./scripts/drills/integration-scenario.sh
```

Kapsam:

- `/tmp` altında disposable Supabase projesi oluşturur.
- Local Supabase stack başlatır.
- Legacy `[inbucket]` veya güncel `[local_smtp]` dahil tüm servis portlarını
  izole aralığa taşır.
- `public.integration_notes` tablosuna fake veri yazar.
- `bin/supabase-backup.sh` ile backup alır.
- Manifest hash bilgisini doğrular.
- `bin/supabase-restore.sh --dry-run` ile restore planının kurulabildiğini
  doğrular.

Bu senaryo günlük/manual hızlı smoke içindir; full restore yapmaz.

## Senaryo 2: SQL restore, stopped stack

Komut:

```bash
./scripts/drills/integration-scenario.sh --scenario sql
```

Kapsam:

- `/tmp` altında disposable Supabase projesi oluşturur.
- Local Supabase stack başlatır.
- `public.integration_notes` tablosuna fake veri yazar.
- Edge Function ve `.env` dosyası oluşturur.
- `bin/supabase-backup.sh` ile backup alır.
- Canlı state'i bilerek bozar.
- Stack'i durdurur.
- `bin/supabase-restore.sh --strategy sql --components sql,functions,config`
  çalıştırır.
- Dump'ı önce boş geçici DB'ye restore eder; başarılı restore sonrasında DB
  isimlerini değiştirir.
- Restore sonrası DB satırları, function dosyası ve `.env` içeriğini doğrular.

Bu senaryo şu bug sınıflarını yakalar:

- Stack kapalıyken SQL restore'un DB hazır değil hatasına düşmesi.
- `full-cluster.dump.zst` restore edilememesi.
- Initialized Supabase DB üzerinde ownership, ACL, event trigger veya partition
  cleanup hataları.
- Function/config restore path hataları.
- Manifest/hash uyumsuzluğu.

## Senaryo 3: Volume restore

Komut:

```bash
./scripts/drills/integration-scenario.sh --scenario volume
```

Kapsam:

- Disposable stack ve fake DB verisi oluşturur.
- Backup alır.
- Canlı DB state'ini bozar.
- `bin/supabase-restore.sh --strategy volume --components db,storage`
  çalıştırır.
- DB volume restore sonrası baseline satırların geri geldiğini doğrular.
- Storage canary nesnesinin byte içeriğini geri okur.
- Ownership, ACL ve extended attribute metadata'sını physical volume arşivinde
  korur.
- Backup mirror'ını geçici 0600 anahtarla şifreler ve decrypt/tar testiyle
  doğrular.

Bu senaryo şu bug sınıflarını yakalar:

- Docker volume archive/extract hataları.
- Storage extended attribute kaybı (`ENODATA`) ve object byte uyuşmazlığı.
- Stack stop/start sırası hataları.
- Proje id -> volume name eşleme hataları.

## Senaryo 4: Gerçek CLI update, recovery ve interruption

Komut:

```bash
./scripts/drills/cli-update-drill.sh --scenario all
```

Kapsam:

- Resmi CLI 2.107.0 ve 2.108.0 `.deb` paketlerini GitHub digest bilgisiyle
  doğrular.
- Host `/usr/bin` kurulumuna dokunmadan gerçek binary'lerle disposable stack
  başlatır.
- Backup, stop, CLI değişimi, start ve health zincirini çalıştırır.
- Başarılı update sonrasında CLI sürümünü ve DB test satırını doğrular.
- İkinci senaryoda hedef CLI'nin ilk `start` çağrısını bilerek bozar.
- Eski CLI, physical backup, `rolled_back` journal ve korunmuş DB satırını
  doğrular.
- Üçüncü senaryoda update'i `stack_stopped` journal aşamasında SIGKILL ile
  keser.
- Açık `--recover` çağrısının eski CLI, physical backup ve DB satırını geri
  getirdiğini doğrular.

## Senaryo 5: Full release drill

Komut:

```bash
./scripts/check.sh --strict
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

Ne zaman çalışır:

- Backup/restore/update scriptlerinde geniş refactor sonrası.
- Supabase CLI major/minor update sonrası.
- Docker image veya Postgres version değişikliği sonrası.
- Release öncesi.

## CI önerisi

Hızlı CI:

```bash
./scripts/check.sh
```

Scheduled veya manuel release CI:

```bash
./scripts/check.sh --strict
./scripts/drills/integration-scenario.sh --scenario all
./scripts/drills/cli-update-drill.sh --scenario all
```

Integration senaryosu Docker ve Supabase image indirme, container health check
ve port binding beklemeleri gerektirebilir. Bu yüzden her commit'te değil,
scheduled/manual job olarak çalıştırmak daha doğrudur. Günlük güven için
`tests/scenario-matrix.bats` daha hızlı ve daha deterministiktir.

## Başarı kriterleri

Product-ready kabul için minimum:

- Static checks pass.
- Bats contract tests pass.
- ShellSpec source guard tests pass.
- SQL stopped-stack integration scenario pass.
- Volume integration scenario pass.
- Storage object byte round-trip pass.
- Şifreli mirror decrypt/tar kontrolü pass.
- Gerçek CLI update ve injected-failure recovery drill pass.
- SQL restore logu hata halinde son 100 satırıyla raporlanmalı.
- En az bir kez `--keep` ile üretilen backup manifest elle incelenmiş olmalı.
