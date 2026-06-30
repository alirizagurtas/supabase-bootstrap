# AGENTS.md

Global Codex defaults. Keep detailed workflows in skills and docs.

## Dil

- Varsayılan cevap dili Türkçedir.
- Komut, path, paket, hata metni ve API terimleri aynen korunur.

## RTK

- Shell işi öncesinde `RTK.md` okunur.
- Yaklaşık 10 satırdan uzun desteklenen çıktılarda explicit `rtk` kullanılır.
- `rtk run` ve `rtk proxy` token tasarrufu için kullanılmaz.

## Context

- AGENTS dosyaları kısa tutulur; detaylar skill ve dokümanlara taşınır.
- Serena MCP varsayılan olarak kapalıdır; yalnız açık istekle etkinleştirilir.
- Uzun komutlar 30 saniyeden sık poll edilmez.

@RTK.md
