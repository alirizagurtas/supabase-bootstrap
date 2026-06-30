# Bilinen hatalar ve fallback kayıtları

Bu dosya lazy-load edilir. Varsayılan olarak tamamı okunmaz. Komut hata verirse
veya bilinen riskli bir komut tekrar çalıştırılacaksa ilgili hata metniyle
hedefli `rg` yapılır.

Örnek:

```bash
rg -n "projectCards|gh pr edit|GraphQL" docs/failures/known-failures.md
```

## `gh pr edit` GraphQL `projectCards` hatası

### Belirti

PR başlığı veya gövdesi güncellenirken `gh pr edit` şu hatayla düşebilir:

```text
GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience ... (repository.pullRequest.projectCards)
```

### Sınıflandırma

Yazılım/API davranışı. Komut niyeti normaldir; hata GitHub CLI'ın PR edit
akışındaki GraphQL alanına takılmasından kaynaklanabilir.

### Fallback

PR başlığı veya gövdesi için REST API PATCH kullan:

```bash
gh api repos/OWNER/REPO/pulls/NUM -X PATCH \
  --raw-field title='[codex] Türkçe başlık' \
  --raw-field body='Türkçe PR gövdesi'
```

### Kural

`gh pr edit` aynı `projectCards` hatasıyla düşerse aynı fazda `gh api` fallback
kullanılır. Fallback sonucu PR üzerinden doğrulanır:

```bash
gh pr view NUM --json title,body,isDraft,state,url
```

## `check-agent-routing.sh` `missing command: rg` hatası

### Belirti

Routing doğrulaması şu hatayla durabilir:

```text
[FAIL] missing command: rg
```

### Sınıflandırma

Ortam eksikliği. Codex kendi runtime path'i içinde `rg` sağlayabilir; ancak
kullanıcının normal shell PATH'inde `rg` yoksa repository scripti doğrudan
çalıştırıldığında komut bulunamaz.

### Fallback / çözüm

Ubuntu üzerinde sistem paketini kur:

```bash
sudo apt-get update
sudo apt-get install -y ripgrep
```

Sonra doğrula:

```bash
command -v rg
rg --version
rtk test ./scripts/check-agent-routing.sh
```

### Kural

`rg` repository doğrulama aracıdır; Codex'in bundled path'ine güvenilmez. Yeni
makine bootstrap'inde `ripgrep` sistem paketi olarak kurulu olmalıdır.
