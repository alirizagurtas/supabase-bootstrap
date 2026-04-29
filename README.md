# Supabase Bootstrap

Ubuntu sunucuyu Supabase self-host / local geliştirme ortamı için hazırlar.

Bu repo sadece sistem gereksinimlerini kurar ve gerekirse mevcut Supabase/Docker geliştirme ortamını temizlemeye yardımcı olur.

Proje SQL dosyaları, migration dosyaları, seed verileri, `.env` dosyaları ve secret bilgiler bu repoda tutulmaz.

## Dosyalar

```txt
supabase-bootstrap/
  README.md
  install_supabase.sh
  reset_supabase.sh
```

## Ne kurar?

`install_supabase.sh` Ubuntu üzerinde şunları kurar:

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

`install_supabase.sh` şunları yapmaz:

```txt
Supabase projesi init etmez
Private proje reposu clone etmez
.env dosyası oluşturmaz
DB URL veya secret yazmaz
Migration çalıştırmaz
Seed verisi yüklemez
```

Bu ayrım bilinçlidir. Bu repo public kalabilir; gerçek proje kaynakları private repoda durmalıdır.

## Kurulum

Ubuntu sunucuda çalıştır:

```bash
git clone https://github.com/alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x install_supabase.sh
./install_supabase.sh
```

SSH ile clone etmek istersen:

```bash
git clone git@github.com:alirizagurtas/supabase-bootstrap.git
cd supabase-bootstrap
chmod +x install_supabase.sh
./install_supabase.sh
```

SSH kullanımı için sunucuda GitHub SSH key tanımlı olmalıdır.

## Sürüm seçimi

Varsayılan kurulum sabit Supabase CLI sürümü kullanır.

Varsayılanlar:

```txt
NODE_VERSION=24
SUPABASE_CHANNEL=stable
SUPABASE_VERSION=2.95.5
```

Normal kullanım:

```bash
./install_supabase.sh
```

Belirli Supabase CLI sürümü kurmak için:

```bash
SUPABASE_VERSION=2.96.0 ./install_supabase.sh
```

En güncel Supabase CLI release sürümünü kurmak için:

```bash
SUPABASE_CHANNEL=latest ./install_supabase.sh
```

Node.js sürümünü değiştirmek için:

```bash
NODE_VERSION=24 ./install_supabase.sh
```

## Stable ve latest farkı

```txt
stable = SUPABASE_VERSION değerini kullanır
latest = GitHub latest release bilgisinden son Supabase CLI sürümünü çözer
```

Önerilen kullanım:

```txt
Test VM / geçici kurulum       = latest kullanılabilir
Tekrarlanabilir kurulum        = stable + exact version
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
git clone git@github.com:<your-user-or-org>/otonorm-supabase.git
cd otonorm-supabase
```

Sonra proje README dosyasındaki migration, seed ve deploy adımlarını takip et.

Örnek proje yapısı:

```txt
otonorm-supabase/
  supabase/
    schemas/
    migrations/
    seeds/
  scripts/
  docs/
  AGENTS.md
```

## Reset / temizlik scripti

`reset_supabase.sh`, mevcut local Supabase/Docker ortamını temizlemek için yardımcı script’tir.

Çalıştır:

```bash
chmod +x reset_supabase.sh
./reset_supabase.sh
```

Script önce hedef klasörü sorar. Varsayılan hedef:

```txt
~/supabase
```

Sonra ne yapmak istediğini sorar.

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

### 3. Tam Docker temizliği + proje klasörünü sil

```txt
supabase stop --no-backup çalışır.
Hedef proje klasörü silinir.
docker system prune -a --volumes çalışır.
Kullanılmayan Docker image/container/network/volume verileri silinir.
```

Bu seçenek yıkıcıdır. Docker volume içindeki veriler silinebilir.

### 4. Çıkış

Hiçbir işlem yapmadan çıkar.

## Reset uyarısı

`supabase db reset` local veritabanını sıfırlar. Elle eklediğin local veriler silinir. Sadece seed dosyalarında olan veriler geri gelir.

Canlı / production veritabanında reset kullanılmaz.

Canlı ortamda doğru yöntem:

```txt
migration üret
local/staging test et
db push ile canlıya uygula
```

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

`install_supabase.sh`, Docker grubuna mevcut kullanıcıyı ekler. Bu değişiklik genelde logout/login veya reboot sonrası aktif olur.

Bu yüzden kurulumdan sonra `sudo reboot` önerilir.
