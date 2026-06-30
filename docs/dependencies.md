# Dependency manifest

Bu dosya repository'nin `package.json` benzeri insan-okunur dependency
manifestidir. Repo Bash-first olduğu için Node `package.json` ana kaynak
değildir; required/optional sistem araçları burada tutulur ve `scripts/doctor.sh`
ile kontrol edilir.

## Kurallar

- Yeni araç eklenirse aynı değişiklik içinde bu dosya güncellenir.
- Paket adı, komut adı ve hangi kapıda kullanıldığı birlikte yazılır.
- Runtime araçları ile geliştirme/test araçları ayrılır.
- Secrets, host-local path ve makineye özel config bu dosyaya yazılmaz.
- Otomatik kurulum script'i eklenirse önce bu manifesti okuyan veya bu
  manifestle birebir hizalı çalışan bir yapı olmalıdır.

## Required araçlar

| Komut | Ubuntu/Debian paketi veya kaynak | Kullanım |
| --- | --- | --- |
| `bash` | `bash` | Tüm Bash scriptleri ve test fixture'ları |
| `git` | `git` | `git diff --check`, commit/push ve repo kökü tespiti |
| `shellcheck` | `shellcheck` | Shell static analysis |
| `shfmt` | `shfmt` | Shell formatting drift kontrolü |
| `bats` | `bats` | `tests/` davranış ve sözleşme testleri |
| `checkbashisms` | `devscripts` | POSIX `sh` dosyalarında bashism kontrolü |
| `shellspec` | ShellSpec upstream install | `spec/` source edilebilirlik testleri |
| `systemd-analyze` | `systemd` | systemd unit template doğrulaması |
| `gitleaks` | `gitleaks` | Hafif worktree secret scan |
| `rg` | `ripgrep` | Hızlı text arama ve routing testleri |
| `rtk` | RTK kurulumu | Düşük-token test, git, rg ve ölçüm wrapper'ları |
| `ast-grep` | ast-grep kurulumu | Serena kapalıyken yapısal Bash arama fixture'ı |

## Runtime / host araçları

| Komut | Ubuntu/Debian paketi veya kaynak | Kullanım |
| --- | --- | --- |
| `docker` | Docker Engine | Supabase self-host container yaşam döngüsü |
| `supabase` | Supabase CLI | CLI-managed self-host stack yönetimi |
| `psql` | `postgresql-client` | SQL backup/restore ve doğrulama işleri |
| `curl` | `curl` | Sağlık kontrolü ve API smoke kontrolleri |
| `jq` | `jq` | JSON manifest ve API çıktısı işleme |
| `sha256sum` | `coreutils` | Backup manifest bütünlük doğrulaması |
| `tar` | `tar` | Physical volume/config arşivleme |
| `gzip` | `gzip` | SQL dump ve arşiv sıkıştırma |
| `systemctl` | `systemd` | systemd timer/service kurulumu |

## Optional araçlar

| Komut | Kullanım |
| --- | --- |
| `gh` | GitHub PR/check/issue işlemleri; `git` yerine geçmez. |
| `serena` | Kullanıcı açıkça isterse MCP/semantic code navigation. Varsayılan kapalıdır. |
| `codex` | Codex runtime backup/restore kanıtlarında environment kaydı. |
| `uv` | Serena/Codex runtime restore kapsamındaki Python toolchain. |

## Kontrol

Eksik araçları production davranışını değiştirmeden raporlamak için:

```bash
./scripts/doctor.sh
```

Yalnız zorunlu geliştirme/test araçlarını kontrol etmek için:

```bash
./scripts/doctor.sh --required-only
```

## Otomatik kurulum

Ubuntu/Debian üzerinde apt ile yönetilen geliştirme araçlarını kurmak için önce
planı gör:

```bash
./scripts/bootstrap-dev-tools.sh --dry-run
```

Kurulumu çalıştır:

```bash
./scripts/bootstrap-dev-tools.sh --yes
```

Runtime helper paketlerini de dahil etmek için:

```bash
./scripts/bootstrap-dev-tools.sh --yes --include-runtime
```

Opsiyonel yardımcıları da dahil etmek için:

```bash
./scripts/bootstrap-dev-tools.sh --yes --include-optional
```

Bu script yalnız apt-managed paketleri kurar. `rtk`, `ast-grep` ve `shellspec`
gibi apt dışı araçların durumu kurulum sonunda `./scripts/doctor.sh
--required-only` ile raporlanır.
