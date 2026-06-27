# Supabase Script Integration Scenarios

Bu dokuman backup/restore/update scriptleri icin tekrar calistirilabilir saglik senaryolarini tanimlar.

## Test katmanlari

Endustri pratigi tek bir test turune guvenmez:

```txt
static checks     shellcheck, shfmt, bash -n
unit/contract     fake command Bats testleri
scenario matrix   fixture veri + fake Docker/Supabase ile hizli acceptance testleri
integration       disposable Supabase stack ile gercek backup/restore drill
recovery drill    manuel veya scheduled disaster-recovery provasi
```

Bu repo icin gunluk hizli kontrol:

```bash
./scripts/check.sh
```

Buyuk refactor/release kontrolu:

```bash
./scripts/check.sh --strict
```

Hizli scenario matrix `./scripts/check.sh` icinde calisir. Kapsadigi durumlar:

- stopped stack SQL restore
- functions/config/.env restore
- DB volume restore komut yolu
- bozuk manifest ile destructive isleme gecmeme

Gercek stack smoke:

```bash
./scripts/integration-scenario.sh
```

Bu varsayilan smoke senaryosu stack baslatir, fake veri yazar, backup alir, manifest'i dogrular ve restore'u `--dry-run` plan seviyesinde dener. Full restore yapmaz.

Gercek stack drill:

```bash
./scripts/integration-scenario.sh --scenario all
```

Debug icin gecici proje ve backup dosyalarini tut:

```bash
./scripts/integration-scenario.sh --scenario sql --keep
```

## Scenario 1: Smoke backup + restore plan

Komut:

```bash
./scripts/integration-scenario.sh
```

Kapsam:

- `/tmp` altinda disposable Supabase projesi olusturur.
- Local Supabase stack baslatir.
- Legacy `[inbucket]` veya guncel `[local_smtp]` dahil tum servis portlarini izole araliga tasir.
- `public.integration_notes` tablosuna fake veri yazar.
- `supabase-backup.sh` ile backup alir.
- Manifest hash bilgisini dogrular.
- `supabase-restore.sh --dry-run` ile restore planinin kurulabildigini dogrular.

Bu senaryo gunluk/manual hizli smoke icindir; full restore yapmaz.

## Scenario 2: SQL restore, stopped stack

Komut:

```bash
./scripts/integration-scenario.sh --scenario sql
```

Kapsam:

- `/tmp` altinda disposable Supabase projesi olusturur.
- Local Supabase stack baslatir.
- `public.integration_notes` tablosuna fake veri yazar.
- Edge Function ve `.env` dosyasi olusturur.
- `supabase-backup.sh` ile backup alir.
- Canli state'i bilerek bozar.
- Stack'i durdurur.
- `supabase-restore.sh --strategy sql --components sql,functions,config` calistirir.
- Dump'i once bos gecici DB'ye restore eder; basarili restore sonrasinda DB isimlerini degistirir.
- Restore sonrasi DB satirlari, function dosyasi ve `.env` icerigini dogrular.

Bu senaryo su bug siniflarini yakalar:

- Stack kapaliyken SQL restore'un DB hazir degil hatasina dusmesi.
- `full-cluster.dump.zst` restore edilememesi.
- Initialized Supabase DB uzerinde ownership, ACL, event trigger veya partition cleanup hatalari.
- Function/config restore path hatalari.
- Manifest/hash uyumsuzlugu.

## Scenario 3: Volume restore

Komut:

```bash
./scripts/integration-scenario.sh --scenario volume
```

Kapsam:

- Disposable stack ve fake DB verisi olusturur.
- Backup alir.
- Canli DB state'ini bozar.
- `supabase-restore.sh --strategy volume --components db` calistirir.
- DB volume restore sonrasi baseline satirlarin geri geldigini dogrular.

Bu senaryo su bug siniflarini yakalar:

- Docker volume archive/extract hatalari.
- Stack stop/start sirasi hatalari.
- Proje id -> volume name esleme hatalari.

## Scenario 4: Full release drill

Komut:

```bash
./scripts/check.sh --strict
./scripts/integration-scenario.sh --scenario all
```

Ne zaman calisir:

- Backup/restore/update scriptlerinde genis refactor sonrasi.
- Supabase CLI major/minor update sonrasi.
- Docker image veya Postgres version degisikligi sonrasi.
- Release oncesi.

## CI onerisi

Hizli CI:

```bash
./scripts/check.sh
```

Scheduled veya manuel release CI:

```bash
./scripts/check.sh --strict
./scripts/integration-scenario.sh --scenario all
```

Integration senaryosu Docker ve Supabase image indirme, container health check ve port binding beklemeleri gerektirebilir. Bu yuzden her commit'te degil, scheduled/manual job olarak calistirmak daha dogrudur. Gunluk guven icin `tests/scenario-matrix.bats` daha hizli ve daha deterministiktir.

## Basari kriterleri

Product-ready kabul icin minimum:

- Static checks pass.
- Bats contract tests pass.
- ShellSpec source guard tests pass.
- SQL stopped-stack integration scenario pass.
- Volume integration scenario pass.
- SQL restore logu hata halinde son 100 satiriyla raporlanmali.
- En az bir kez `--keep` ile uretilen backup manifest elle incelenmis olmali.
