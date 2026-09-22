# ADR 0011 — Cofre local com GPG simétrico pro insumo plaintext dos SealedSecrets

## Status
Aceito, implementado em 2026-09-18. Passphrase rotacionada em 2026-09-21 (ver "Acréscimo" no
fim) — a original não foi recuperada.

## Contexto
`base/postgres-secret.env` é o insumo em texto plano usado (via `kubeseal`) pra gerar
`base/postgres-secret.sealed.yaml`, o `SealedSecret` real aplicado no cluster. Está no
`.gitignore` desde sempre — nunca foi commitado —, mas até esta sessão só existia como arquivo
puro no disco, sem nenhum backup. Item 2 do backlog (`docs/HANDOFF.md`) registrava isso como
risco em aberto.

Avaliado o risco real antes de agir: cluster k3d local, single-developer, senha já é um *default*
documentado publicamente no `CLAUDE.md` (`ProtheusPwd2026`, convenção de 2026-09-16) — não é um
segredo de produção exposto a terceiros. Rotacionar a senha foi descartado como solução do item 2
isoladamente: mudaria também o Compose (mesma senha nos dois ambientes, por decisão deliberada),
reabrindo a padronização de nomenclatura que o handoff pede pra não reabrir sem motivo novo — só
faria sentido como projeto à parte, não como resposta a "falta backup do plaintext".

## Decisão

**Criptografia em repouso com GPG simétrico (AES256)**, não `age` nem par de chaves assimétrico:

- `age` não estava instalado neste host, `gpg` já estava — zero instalação nova.
- Caso de uso é single-user/single-máquina: não há necessidade de distribuir chave pública pra
  múltiplos decriptadores, então par assimétrico seria complexidade sem benefício real aqui.
- Passphrase única, forte (`openssl rand -base64 32`, 256 bits de entropia), guardada só no
  gerenciador de senhas do usuário — nunca em arquivo neste repositório, nunca em variável de
  ambiente, nunca como argumento de CLI (ficaria no histórico do shell).

`base/postgres-secret.env.gpg` é o arquivo real versionado no git (cifrado, seguro de commitar).
`scripts/secrets/encrypt.sh`/`decrypt.sh` (genéricos, recebem o caminho do arquivo como
argumento — reusáveis pra qualquer outro segredo que precise do mesmo tratamento, não hardcoded
pro Postgres) pedem a passphrase interativamente via pinentry do GPG — nunca aceitam por
argumento/env, e por isso **não são algo que uma sessão automatizada consegue rodar sozinha**
sem um humano digitando a senha. Propriedade desejada: nem um agente com acesso total ao
repositório decripta o segredo sem intervenção humana direta no terminal.

O `base/postgres-secret.env` em texto puro foi removido do disco depois de:
1. Criptografado (`gpg --symmetric --cipher-algo AES256`).
2. Round-trip verificado via comparação de hash SHA-256 entre o original e o resultado
   decriptado — nunca exibindo o conteúdo em nenhum momento do processo.

## Consequências
- Fecha o item 2 do backlog: a única cópia recuperável da senha não depende mais de um único
  arquivo plaintext sem backup no disco de uma máquina.
- Custo: qualquer edição futura do segredo (rotação, correção) exige o ciclo manual
  `decrypt.sh` → editar → `encrypt.sh` → `rm` do plaintext → re-selar com `kubeseal` → commitar o
  `.gpg` novo — um passo a mais que antes, deliberado (é o preço da criptografia em repouso).
- Reusável: os dois scripts servem pra `smartview-secret`/`appserver-upddistr-secret` também, se
  algum dia deixarem um `.env` plaintext no disco (hoje não deixam — só o Postgres tinha esse
  problema, confirmado ao investigar antes de implementar).
- Risco residual aceito conscientemente: a passphrase em si não tem backup automatizado (fica só
  no gerenciador de senhas do usuário) — decisão deliberada, consistente com o escopo "cofre
  local" pedido, não um sistema de gestão de segredos multi-usuário.

## Acréscimo de 2026-09-21 — passphrase original perdida, rotacionada

O risco residual documentado acima se materializou: no meio do drill de "cluster do zero" (ADR
0013, segunda execução), a passphrase original não foi reconhecida por nenhuma tentativa do
usuário. Causa provável, não confirmada: o `gpg-agent` provavelmente tinha cacheado a passphrase
de uma sessão anterior (explicando por que `sealed-secrets-keys-backup.yaml.gpg` decriptou sem
digitação manual mais cedo na mesma sessão) e o cache expirou antes da tentativa seguinte
(`kube-prometheus-stack.yaml.gpg`), forçando digitação manual que não teve êxito. Decisão do
usuário: gerar passphrase nova (`openssl rand -base64 32`, mesmo método) em vez de continuar
tentando recuperar a antiga.

**Escopo da rotação — nem todo o cofre foi migrado, de propósito**:
- Migrados pra passphrase nova: os 3 `helm-values/*.yaml.gpg` com credencial
  (`kube-prometheus-stack`, `minio`, `velero` — reconstruídos do zero, valor antigo perdido de
  verdade) e `scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml.gpg` (reexportado **ao
  vivo** do cluster já restaurado, não precisou reconstruir — as chaves em si não mudaram, só a
  cifra do backup).
- A passphrase nova foi exibida ao usuário uma única vez (mesmo tratamento do ADR original) —
  não fica retida em nenhum lugar deste repositório ou sessão.

### Follow-up fechado em 2026-09-22 — `postgres-secret.env.gpg` migrado, cofre unificado

O item "não migrado" acima foi resolvido. Achado no processo, não no manifesto: a passphrase
gerada por `openssl rand -base64 32` e entregue ao usuário no fim da sessão anterior **não é
mais a que está em vigor** — o usuário a substituiu por uma própria, memorável, depois do fim
daquela sessão, sem isso ficar registrado em lugar nenhum (natural, já que passphrase nunca é
documentada em texto). Isso causou confusão real na sessão seguinte: duas candidatas em mãos
(a gerada, anotada pelo usuário; e a memorável, definida depois), sem forma de saber qual valia
sem testar. Resolvido testando contra um dos arquivos já migrados
(`scripts/cluster-bootstrap/helm-values/minio.yaml.gpg`, baixo risco) antes de mexer em
qualquer coisa — a memorável autenticou.

Com isso confirmado, `base/postgres-secret.env` foi recriado direto do valor documentado no
`CLAUDE.md` (`ProtheusPwd2026` — não havia necessidade de decriptar o `.gpg` antigo, cuja
passphrase original já era irrecuperável desde antes da rotação) e re-encriptado com a
passphrase em vigor. O cofre inteiro agora está sob uma única passphrase ativa.

**Lição pro processo, não só pro manifesto**: se a passphrase de um cofre single-user for
trocada fora de uma sessão registrada, não há como a próxima sessão saber — o teste empírico
contra um arquivo de baixo risco (não o mais sensível) é o jeito seguro de confirmar antes de
agir, em vez de assumir qual candidata está certa.
