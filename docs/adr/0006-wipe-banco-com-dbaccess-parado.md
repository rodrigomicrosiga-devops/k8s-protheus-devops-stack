# ADR 0006 — Nunca fazer wipe/DDL direto no banco com `dbaccess` ativo

## Status
Aceito, confirmado com um incidente real (2026-09-16).

## Contexto
Um `DROP DATABASE protheus_dev` foi executado direto no Postgres enquanto o `dbaccess` estava
ativo. O `dbaccess` mantém cache de metadados/DDL em memória por ambiente (nome do banco,
estrutura de tabelas já registradas) — não é notificado de mudanças feitas por fora dele. O
banco recriado ficou fisicamente vazio, mas o `dbaccess` continuou operando com o cache antigo,
causando falha real na criação de tabelas pelo AppServer:
`TOP Error -19 - Unable to Unregister Fields (ROP_CREATEFILE)` em `SYS_BCAST_KEYSTAGE` (e
provavelmente em qualquer outra tabela cujo estado anterior estivesse cacheado).

## Decisão
Qualquer wipe ou alteração estrutural do banco (`DROP DATABASE`, `DROP TABLE`, mudança de
schema por fora do fluxo normal do AppServer) segue esta ordem:

1. Parar todo appserver que possa estar conectado (`core`, `rest`, `telnet`, `worker`, etc.).
2. Parar `dbaccess`.
3. Fazer o wipe/alteração no Postgres diretamente.
4. Reiniciar o `postgres` (garante que nenhuma sessão órfã sobreviva à mudança).
5. Recriar o banco, se aplicável.
6. Subir `dbaccess` de novo (cache nasce limpo, sem estado residual).
7. Só então subir o `core`.

No Compose local, `dbaccess` não tem volume nenhum montado (confirmado: só logs em
`/opt/totvs/dbaccess/log/`) — reiniciar o container já é suficiente, não há cache em disco para
limpar manualmente.

## Consequências
- Qualquer wipe futuro (inclusive a Fase E, e o eventual MSSQL) segue esta sequência por padrão,
  não só o Postgres do Compose local.
- No cluster k8s, o equivalente é: `scale --replicas=0` do `dbaccess` antes de qualquer operação
  destrutiva no Postgres gerenciado, depois `scale --replicas=1` de novo.
