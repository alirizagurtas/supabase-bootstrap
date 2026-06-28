# Supabase Bootstrap

Ubuntu sunucuyu Supabase self-host / local geliştirme ortamı için hazırlar.

Bu repo sadece sistem gereksinimlerini kurar ve gerekirse mevcut Supabase/Docker geliştirme ortamını temizlemeye yardımcı olur.

Proje SQL dosyaları, migration dosyaları, seed verileri, `.env` dosyaları ve secret bilgiler bu repoda tutulmaz.

## Dosyalar

```txt
supabase-bootstrap/
  README.md
  AGENTS.md
  scripts/check.sh
  scripts/integration-scenario.sh
  tests/backup-restore-contracts.bats
  tests/reset-safety.bats
  tests/scenario-matrix.bats
  tests/supabase-update.bats
  spec/supabase_update_spec.sh
  supabase-install.sh
  supabase-reset.sh
  supabase-update.sh
  supabase-backup.sh
  supabase-restore.sh
```

## Geliştirme kontrolleri

Shell script değişikliğinden sonra çalıştır:

```bash
./scripts/check.sh
```

Daha sıkı release/refactor kontrolü:

```bash
./scripts/check.sh --strict
```

## Backup / restore güvenliği

- Backup dosyaları private izinlerle oluşturulur.
- Manifest doğrulaması zorunlu SQL dump’larını ve tüm SHA-256 kayıtlarını kontrol eder.
- Fiziksel Docker volume snapshot’ı sırasında stack kısa süreliğine durdurulur ve işlem sonunda yeniden başlatılır.
- Non-interactive restore için güvenli varsayılan `sql` stratejisidir. Fiziksel volume restore açıkça `--strategy volume` ile seçilmelidir.
- `project_id`, dizin adından değil `supabase/config.toml` içinden okunur.
- Update, backup, restore ve reset aynı proje kilidini ve kalıcı işlem journal'ını kullanır. CLI update ayrıca host-global kilit alır.
- Update öncesi doğrulanmış backup ile stop/start zorunludur; `--no-backup` ve `--no-start` update akışında reddedilir.
- Update yarıda kalırsa `supabase-update.sh --recover --workdir <proje>` journal'daki backup ile recovery dener.
- İkinci failure-domain için `supabase-backup.sh --mirror <dir> --mirror-key-file <0600-key>` kullanılır. Eşdeğer ortam değişkenleri `SUPABASE_BACKUP_MIRROR` ve `SUPABASE_BACKUP_KEY_FILE` değerleridir.
- Physical volume arşivleri ownership, ACL ve Storage extended attribute metadata'sını korur.

Kanonik yaşam döngüsü ve kod uygunluk tablosu:
`docs/cli-managed-lifecycle-decision-tree.md`

`--strict`, tüm shell scriptlerde ShellCheck style seviyesini ve shfmt drift'ini bloklar.

Kullanılan araçlar:

```txt
shellcheck
shfmt
bats
shellspec
checkbashisms
```

Hızlı testler fake command ve fixture verilerle çalışır. Gerçek Supabase stack üzerinde hafif smoke:

```bash
./scripts/integration-scenario.sh
```

Ağır release/drill senaryoları manuel/scheduled çalıştırılmalıdır:

```bash
./scripts/integration-scenario.sh --scenario all
./scripts/cli-update-drill.sh --scenario all
```

Detaylar: `docs/integration-scenarios.md`

## Ne kurar?

`supabase-install.sh` Ubuntu üzerinde şunları kurar:

```txt
Docker Engine
Docker Compose Plugin
Git
Node.js
pnpm
Deno
PostgreSQL client / psql
Supabase CLI
Temel yardımcı paketler
```

## Ne yapmaz?

`supabase-install.sh` şunları yapmaz:

```txt
Supabase projesi init etmez
Private proje reposu clone etmez
.env dosyası oluşturmaz
DB URL veya secret yazmaz
Migration çalıştırmaz
Seed verisi yüklemez
```

Bu repo public kalabilir; gerçek proje kaynakları private repoda durmalıdır.

## Kurulum

### Repo clone ile kurulum

HTTPS ile:

```bash
git clone https://github.com/alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x supabase-install.sh
./supabase-install.sh
```

SSH ile:

```bash
git clone git@github.com:alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x supabase-install.sh
./supabase-install.sh
```

SSH kullanımı için sunucuda GitHub SSH key tanımlı olmalıdır.

### Tek dosya indirip kurulum

`curl` ile:

```bash
curl -fsSL https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-install.sh -o supabase-install.sh
chmod +x supabase-install.sh
./supabase-install.sh
```

`wget` ile:

```bash
wget https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-install.sh -O supabase-install.sh
chmod +x supabase-install.sh
./supabase-install.sh
```

### Tek komutla kurulum

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-install.sh?$(date +%s)")
```

> Not: Script interaktif çalışır. Devam etmek isteyip istemediğini sorar.

## Sürüm seçimi

Varsayılan kurulum sabit Supabase CLI sürümü kullanır.

Varsayılanlar:

```txt
NODE_VERSION=24
SUPABASE_CHANNEL=stable
SUPABASE_VERSION=2.95.5
FNM_TAG=latest
DENO_TAG=latest
```

`fnm`, Deno ve Supabase CLI arşivleri doğrudan GitHub release asset olarak indirilir.
Kurulumdan önce GitHub release metadata içindeki SHA-256 digest ile doğrulanır.

Normal kullanım:

```bash
./supabase-install.sh
```

Belirli Supabase CLI sürümü kurmak için:

```bash
SUPABASE_VERSION=2.96.0 ./supabase-install.sh
```

En güncel Supabase CLI release sürümünü kurmak için:

```bash
SUPABASE_CHANNEL=latest ./supabase-install.sh
```

Node.js sürümünü değiştirmek için:

```bash
NODE_VERSION=24 ./supabase-install.sh
```

`fnm` veya Deno sürümünü sabitlemek için:

```bash
FNM_TAG=v1.39.0 DENO_TAG=v2.6.9 ./supabase-install.sh
```

Tek komutla latest kurmak için:

```bash
SUPABASE_CHANNEL=latest bash <(curl -fsSL https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-install.sh)
```

## Stable ve latest farkı

```txt
stable = SUPABASE_VERSION değerini kullanır
latest = GitHub latest release bilgisinden son Supabase CLI sürümünü çözer
```

Önerilen kullanım:

```txt
Test VM / geçici kurulum = latest kullanılabilir
Tekrarlanabilir kurulum  = stable + exact version
```

## Kurulum sonrası

Script bittikten sonra reboot önerilir:

```bash
sudo reboot
```

Reboot sonrası kontrol:

```bash
docker run hello-world
supabase --version
docker compose version
node -v
pnpm -v
deno --version
psql --version
```

## Private proje reposu

Bootstrap tamamlandıktan sonra private Supabase proje reposunu clone et:

```bash
git clone git@github.com:alirizagurtas/supabase-autonorm.git
cd otonorm-supabase
```

Sonra proje README dosyasındaki migration, seed ve deploy adımlarını takip et.

Örnek proje yapısı:

```txt
supabase-otonorm/
  supabase/
    schemas/
    migrations/
    seeds/
  scripts/
  docs/
  AGENTS.md
```

## Reset / temizlik scripti

`supabase-reset.sh`, mevcut local Supabase/Docker ortamını temizlemek için yardımcı script’tir.

Script önce hedef klasörü sorar. Varsayılan hedef:

```txt
~/supabase
```

Sonra ne yapmak istediğini sorar.

## Reset scriptini çalıştırma seçenekleri

### Repo clone ile çalıştırma

HTTPS ile:

```bash
git clone https://github.com/alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x supabase-reset.sh
./supabase-reset.sh
```

SSH ile:

```bash
git clone git@github.com:alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x supabase-reset.sh
./supabase-reset.sh
```

### Tek dosya indirip çalıştırma

`curl` ile:

```bash
curl -fsSL https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-reset.sh -o supabase-reset.sh
chmod +x supabase-reset.sh
./supabase-reset.sh
```

`wget` ile:

```bash
wget https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-reset.sh -O supabase-reset.sh
chmod +x supabase-reset.sh
./supabase-reset.sh
```

### Tek komutla çalıştırma

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/alirizagurtas/supabase-bootstrap/main/supabase-reset.sh?$(date +%s)")
```

> Not: Reset scripti interaktif çalışır. Hedef klasörü ve yapmak istediğin işlemi sorar.

## Reset seçenekleri

### 1. Sadece Supabase local DB reset

```txt
Proje klasörü kalır.
supabase db reset çalışır.
Local DB verileri silinir.
Migration dosyaları baştan uygulanır.
config.toml içindeki seed dosyaları tekrar yüklenir.
```

Bu seçenek local geliştirme için uygundur.

### 2. Supabase projesini durdur ve proje klasörünü sil

```txt
supabase stop --no-backup çalışır.
Hedef proje klasörü silinir.
Docker genel temizliği yapılmaz.
```

Bu seçenek projeyi yeniden clone etmek istediğinde kullanılır.

### 3. Supabase proje ve kullanıcı verilerini temizle

```txt
supabase stop --no-backup çalışır.
Hedef proje klasörü silinir.
İstenirse ~/.supabase klasörü silinir.
Global Docker prune çalıştırılmaz.
```

Bu seçenek yıkıcıdır; işlem öncesinde doğrulanmış backup zorunludur.

### 4. Çıkış

Hiçbir işlem yapmadan çıkar.

## Reset uyarısı

`supabase db reset` veritabanını sıfırlar. Elle eklenen veriler silinir ve
migration/seed dosyaları yeniden uygulanır. Reset scripti başlamadan önce tam
backup alır ve bütünlüğünü doğrular.

## Güvenlik

Bu repo public olabilir çünkü içinde secret bilgi olmamalıdır.

Kesinlikle ekleme:

```txt
.env
DB URL
JWT secret
service role key
anon key
GitHub token
SSH private key
production password
```

## Repo amacı

Bu repo sadece şunu sağlar:

```txt
Yeni Ubuntu VM → Supabase çalıştırmaya hazır sistem
```

ve gerekirse:

```txt
Test/local Supabase ortamını temizleme
```

Asıl veritabanı kaynakları ayrı private repoda durur.

## Not

`supabase-install.sh`, Docker grubuna mevcut kullanıcıyı ekler. Bu değişiklik genelde logout/login veya reboot sonrası aktif olur.

Bu yüzden kurulumdan sonra `sudo reboot` önerilir.
