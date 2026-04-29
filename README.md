# Supabase Bootstrap

Ubuntu sunucuyu Supabase self-host / local geliştirme ortamı için hazırlar.

Bu repo sadece sistem gereksinimlerini kurar. Proje SQL dosyaları, migration dosyaları, seed verileri, `.env` dosyaları ve secret bilgiler bu repoda tutulmaz.

## Ne kurar?

Bu script Ubuntu üzerinde şunları kurar:

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

Bu script şunları yapmaz:

```txt
Supabase projesi init etmez
Private proje reposu clone etmez
.env dosyası oluşturmaz
DB URL veya secret yazmaz
Migration çalıştırmaz
Seed verisi yüklemez
```

Bu repo public kalabilir; gerçek proje kaynakları private repoda durmalıdır.

## Kullanım

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
Test VM        = latest kullanılabilir
Tekrarlanabilir kurulum = stable + exact version
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

## Sonraki adım

Bu bootstrap tamamlandıktan sonra private Supabase proje reposunu clone et:

```bash
git clone git@github.com:<your-user-or-org>/otonorm-supabase.git
cd otonorm-supabase
```

Sonra proje README dosyasındaki migration, seed ve deploy adımlarını takip et.

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

Asıl veritabanı kaynakları ayrı private repoda durur:

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

## Not

Script Docker grubuna mevcut kullanıcıyı ekler. Bu değişiklik genelde logout/login veya reboot sonrası aktif olur.

Bu yüzden kurulumdan sonra `sudo reboot` önerilir.
