# ADR 0011 — Cofre local com GPG simétrico pro insumo plaintext dos SealedSecrets

## Status
Aceito, implementado em 2026-09-18.

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
