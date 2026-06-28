# Repository map

Bu belge repository içindeki dosyaların canonical envanteridir. Yeni bir dosya
eklendiğinde, taşındığında veya sorumluluğu değiştiğinde aynı değişiklik içinde
güncellenir.

## Klasör sözleşmesi

| Yol | Sorumluluk |
| --- | --- |
| `bin/` | Kullanıcının doğrudan çalıştırdığı Supabase yaşam döngüsü komutları |
| `lib/` | `bin/` komutlarının source ettiği, doğrudan çalıştırılmayan ortak Bash kodu |
| `scripts/` | Repository geliştirme ve kalite otomasyonu |
| `scripts/drills/` | Gerçek ve disposable Supabase stack kullanan ağır doğrulamalar |
| `tests/` | Hızlı Bats davranış ve sözleşme testleri |
| `spec/` | ShellSpec testleri |
| `docs/` | Karar, işletim ve doğrulama dokümantasyonu |

## Dosya envanteri

### Kök

| Dosya | Görev |
| --- | --- |
| `README.md` | Kurulum, kullanım ve ana güvenlik sözleşmelerini açıklar. |
| `AGENTS.md` | Bu repository üzerinde çalışan ajanların kalite ve güvenlik kurallarını tanımlar. |
| `.gitignore` | Editör swap dosyaları, operation journal ve yerel Supabase proje verisini Git dışında tutar. |
| `.serena/project.yml` | Serena için Bash dilini, ignore kapsamını ve proje güvenlik başlangıç talimatını tanımlar. |
| `.serena/.gitignore` | Serena indeks cache'i ile makineye özel ayarları Git dışında tutar. |

### Kullanıcı komutları

| Dosya | Görev |
| --- | --- |
| `bin/supabase-install.sh` | Ubuntu host için Docker, CLI ve gerekli araçları kurar. |
| `bin/supabase-backup.sh` | SQL, fiziksel volume, config ve function içeren doğrulanmış backup üretir. |
| `bin/supabase-backup-maintenance.sh` | Encrypted mirror import ve local/mirror retention işlemlerini yönetir. |
| `bin/supabase-restore.sh` | Backup manifestini doğrular ve seçilen stratejiyle kontrollü restore yapar. |
| `bin/supabase-update.sh` | CLI-managed stack için backup, update, health check ve recovery akışını yönetir. |
| `bin/supabase-reset.sh` | Doğrulanmış backup şartıyla proje kapsamındaki temizleme/reset işlemlerini yürütür. |

### Ortak kütüphaneler

| Dosya | Görev |
| --- | --- |
| `lib/operation-state.sh` | Proje kilidi, host-global update kilidi ve kalıcı işlem journal'ı sağlar. |
| `lib/service-health.sh` | Auth, REST ve Storage gateway endpointlerini salt okunur olarak doğrular. |

### Geliştirme ve drill araçları

| Dosya | Görev |
| --- | --- |
| `scripts/check.sh` | Syntax, ShellCheck, shfmt, Bats ve ShellSpec kalite kapısını çalıştırır. |
| `scripts/check-agent-routing.sh` | RTK, Serena, ast-grep ve rg araç yönlendirme kurallarını kontrollü fixture ile doğrular. |
| `scripts/notify-on-failure.sh` | Sardığı komutun hatasını loglar ve yapılandırılmış executable hook'a bildirir. |
| `scripts/systemd-backup.sh` | systemd environment değerlerini güvenli backup argümanlarına dönüştürür. |
| `scripts/drills/integration-scenario.sh` | Gerçek disposable stack üzerinde smoke, SQL ve volume restore senaryolarını çalıştırır. |
| `scripts/drills/cli-update-drill.sh` | Gerçek CLI sürümleriyle update ve zorlanmış recovery senaryolarını çalıştırır. |

### Bats testleri

| Dosya | Görev |
| --- | --- |
| `tests/backup-restore-contracts.bats` | Backup/restore argüman, bütünlük, uyumluluk ve recovery sözleşmelerini test eder. |
| `tests/backup-maintenance.bats` | Encrypted mirror import ve birleşik retention sözleşmelerini test eder. |
| `tests/notification.bats` | Failure hook çağrısını ve exit status korumasını test eder. |
| `tests/operation-state.bats` | Kilit ve işlem journal davranışlarını test eder. |
| `tests/reset-safety.bats` | Reset/install source güvenliğini ve yıkıcı hedef kontrollerini test eder. |
| `tests/scenario-matrix.bats` | Disposable senaryo runner'ının fixture tabanlı dallarını test eder. |
| `tests/service-health.bats` | Gateway sağlık problarının başarı ve hata davranışlarını test eder. |
| `tests/supabase-update.bats` | Update, restore delegation, stop/start ve hata akışlarını fake komutlarla test eder. |

### ShellSpec

| Dosya | Görev |
| --- | --- |
| `spec/supabase_update_spec.sh` | Update scriptinin temel source edilebilirlik sözleşmesini ShellSpec ile doğrular. |

### Dokümantasyon

| Dosya | Görev |
| --- | --- |
| `docs/repository-map.md` | Klasör sözleşmesini ve tüm version-controlled dosyaların görevini listeler. |
| `docs/agent-tool-routing.md` | RTK, Serena, ast-grep, rg ve ham komut seçim kurallarını ve ölçüm kanıtını tanımlar. |
| `docs/lifecycle-decision-tree.md` | CLI-managed self-host yaşam döngüsünün canonical karar ağacını ve kod uygunluğunu tutar. |
| `docs/integration-scenarios.md` | Hızlı testler ile gerçek stack drill'lerinin kapsamını ve komutlarını açıklar. |
| `docs/operations-runbook.md` | Backup, retention, update, recovery, restore ve systemd işletim adımlarını tanımlar. |
| `docs/validation-report.md` | Gerçekleştirilen doğrulamalar ile Hetzner'a bırakılan host kontrollerini kaydeder. |

### Deployment şablonları

| Dosya | Görev |
| --- | --- |
| `deploy/systemd/supabase-backup@.service` | Proje bazlı, harden edilmiş systemd backup service şablonudur. |
| `deploy/systemd/supabase-backup@.timer` | Günlük persistent backup timer şablonudur. |
| `deploy/systemd/project.env.example` | Service için proje, hedef, mirror, key ve notification environment örneğidir. |

## Repository dışında kalan çalışma verileri

`supabase/`, backup hedefleri, `.supabase-ops/` journal dizini, encryption key
dosyaları ve geçici drill projeleri çalışma verisidir. Kaynak kod envanterine
ve Git commitlerine dahil edilmez.
