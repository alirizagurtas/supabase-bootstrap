# Validation report

Son güncelleme: 2026-06-28

## Kapsam

Bu rapor CLI-managed self-host Supabase otomasyonunun local disposable stack
üzerindeki doğrulamasını kaydeder. Hetzner host doğrulaması sonraki deployment
aşamasındadır.

## Otomatik kalite kapısı

```bash
./scripts/check.sh --strict
```

Kontrol edilenler:

- Bash syntax
- ShellCheck style seviyesi
- shfmt
- 67 Bats davranış testi: PASS
- 2 ShellSpec örneği: PASS
- systemd service/timer syntax doğrulaması: PASS

## Gerçek stack drill

```bash
./scripts/drills/integration-scenario.sh --scenario all
```

Beklenen kanıtlar:

- SQL backup/restore sonrası satır ve config/function verisi korunur: PASS
- Physical DB volume restore sonrası satırlar geri gelir: PASS
- Storage object içeriği byte seviyesinde geri gelir: PASS
- Encrypted mirror arşivi maintenance import ve manifest kontrolünden geçer: PASS

## Gerçek CLI update ve recovery drill

```bash
./scripts/drills/cli-update-drill.sh --scenario all
```

Beklenen kanıtlar:

- CLI `2.107.0 -> 2.108.0` update sonrası veri korunur: PASS
- Injected target `start` hatası eski CLI ve physical backup'a döner: PASS
- `SIGKILL` ile kesilen update, kalıcı journal üzerinden açık `--recover`
  çağrısıyla eski CLI ve physical backup'a döner: PASS

## Production öncesi host doğrulamaları

Hetzner aşamasında tamamlanacaklar:

- Firewall, DNS, TLS ve reverse proxy
- Production secret rotasyonu
- Off-host mirror failure-domain testi
- Temiz host restore
- Reboot ve güç kesintisi recovery
- Disk ve backup alarm teslimi
- Gerçek host CLI update/rollback

## 2026-06-28 operator-stack regression

- `bin/` içinden proje keşfi, `project_id=otonorm` config ile doğrulandı: PASS
- Gerçek stack üzerinde `supabase-update.sh --force -y`; verified backup,
  reinstall, stop/start ve health zinciri: PASS
- Eksik `config.toml` durumunun container adından tahmin edilmeden durması: PASS
- Disposable drill HOME ve pre-restore backup output izolasyonu: PASS
- `supabase start` status JSON çıktısının otomasyon loglarından bastırılması: PASS
- Strict kalite kapısı: 67 Bats + 2 ShellSpec: PASS
