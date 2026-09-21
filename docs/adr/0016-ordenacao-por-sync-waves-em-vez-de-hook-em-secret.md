# ADR 0016 — Ordenação entre recursos via sync-waves, não promovendo Secret a hook

## Status
Aceito, implementado e validado ao vivo (2026-09-21).

## Contexto
O ADR 0013 (drill de cluster do zero, 2026-09-19) descobriu que o hook `PreSync`
`smartview-db-init-job` depende de `postgres-secret` (via `envFrom.secretRef`), mas
`postgres-secret` é um `SealedSecret` comum de fase `Sync` — nunca existe a tempo num bootstrap
genuinamente do zero, porque toda a fase `PreSync` roda antes de `Sync` começar. No drill isso só
foi destravado com `kubectl apply -f` manual (bypass pontual do Argo CD), registrado como
follow-up real não corrigido na época.

O padrão já usado nesse mesmo Job para o *outro* secret que ele consome
(`smartview-secret`) era anotá-lo como hook `PreSync` + `sync-wave: "-1"`, para forçá-lo a existir
antes do Job. Ao investigar replicar esse padrão para `postgres-secret`, três problemas reais
apareceram, os dois primeiros confirmados ao vivo nesta sessão:

1. **Hook sem `hook-delete-policy` usa o default `BeforeHookCreation`**: o Argo CD deleta o
   recurso e cria um novo a cada operação de sync (não é um "apply" idempotente). Evidência
   medida: `smartview-secret` (SealedSecret e o Secret gerado, via `ownerReferences`) tinham
   `creationTimestamp: 2026-09-20T21:50:10Z`, dentro da janela da última operação de sync
   (`operationState.finishedAt: 21:50:19Z`), enquanto `postgres-secret`, `regcred` e
   `appserver-upddistr-secret` seguiam com o `creationTimestamp` de 2026-09-18 — nunca tocados
   desde então. Replicar isso em `postgres-secret` propagaria o delete/recreate por sync para o
   secret mais crítico do cluster (consumido por `postgres`, `dbaccess` e o próprio Job).
2. **Recursos hook saem da reconciliação normal do Argo CD** — sem diff contínuo, sem
   `selfHeal`. Um secret tratado como hook fica, na prática, fora da malha de GitOps que o resto
   do repo depende (`syncPolicy.automated.selfHeal: true` no `argocd/application.yaml`).
3. **O próprio SQL do Job estava quebrado**, achado incidental à mesma investigação: os GRANTs
   usavam `EXECUTE format(...)` fora de bloco PL/pgSQL (inválido em SQL puro — reproduzido ao
   vivo: `ERROR: prepared statement "format" does not exist`); o `\c postgres` do script
   reconectava e descartava os `SET custom.*` da sessão anterior; e sem `ON_ERROR_STOP=1` o
   `psql -f` retorna exit 0 mesmo com erro no meio do arquivo (reproduzido ao vivo). Prova de que
   os GRANTs nunca tinham sido aplicados de fato: `datacl` de `postgres` e `smartview_dev` era
   `NULL`. Os literais `POSTGRES_USER=protheus`/`POSTGRES_DB=protheus` do Job também estavam
   desatualizados desde o ADR 0015 (`postgres.env` mudou pra `postgres`/`postgres` em
   2026-09-19) — e conectando como `protheus` (que é `rolcreaterole=false`) o `CREATE USER`
   nunca teria funcionado de verdade; só não quebrava porque `SV_USER` já existia e o
   `IF NOT EXISTS` pulava a criação.

## Decisão
A dependência entre `smartview-db-init-job` e os secrets que ele consome passou a ser resolvida
pelo mecanismo idiomático do Argo CD para isso — sync-waves dentro da fase `Sync` — em vez de
promover mais um Secret a hook `PreSync`:

```
Fase Sync:
  wave 0  postgres-secret, smartview-secret, postgres-config, postgres, dbaccess, ...
          (recursos normais, reconciliados, com selfHeal; Argo CD espera Healthy)
  wave 1  smartview-db-init-job (hook Sync, hook-delete-policy: HookSucceeded)
  wave 2  Deployment smartview
```

`smartview-secret.sealed.yaml` teve as anotações de hook **removidas** — voltou a ser recurso
normal de wave 0, como `postgres-secret` sempre foi. `postgres-secret.sealed.yaml` não foi tocado
(nunca chegou a virar hook). O Job trocou `POSTGRES_USER`/`POSTGRES_DB` literais por
`envFrom: configMapRef: postgres-config` (agora possível — o ConfigMap já existe na wave 1) e o
SQL foi corrigido: `ON_ERROR_STOP=1` em toda invocação do `psql`, GRANTs dentro de bloco
`DO $$ ... END $$`, e o `\c postgres` removido (o Job já conecta como `postgres` via
`envFrom`/`current_database()`).

## Consequências
- Nenhum SealedSecret deste repo é hook — todos ficam sob reconciliação normal e `selfHeal`.
- O hook agora falha de verdade quando falha (`ON_ERROR_STOP=1`), em vez de reportar sucesso com
  SQL quebrado — reforça a regra de idempotência do ADR 0003 (idempotência importa mais ainda
  quando o hook não mente sobre erro).
- Mudança de comportamento real: a wave 1 só avança depois que **toda** a wave 0 estiver
  `Healthy`, não só o Postgres — inclui `appserver-core`/`-rest`/`-telnet` e os seeds. Antes
  (`PreSync`), o Job rodava antes de qualquer coisa da wave 0. Se algum recurso da wave 0 ficar
  degradado, o Job (e o `smartview`) atrasam junto — é a dependência real que o Job sempre teve,
  só que agora declarada em vez de escondida atrás de `PreSync`.
- **Limite desta correção**: ela resolve o defeito de manifesto (verificável num sync normal,
  com todos os secrets já existentes) mas não foi validada no cenário exato que a motivou — um
  drill de `k3d cluster delete` genuinamente do zero. Essa prova fica para a próxima vez que o
  drill do ADR 0013 for repetido.
