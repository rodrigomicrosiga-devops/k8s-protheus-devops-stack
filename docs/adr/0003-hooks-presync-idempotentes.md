# ADR 0003 — Hooks Argo CD (`PreSync`) devem ser idempotentes por padrão

## Status
Aceito, confirmado empiricamente (2026-07-27).

## Contexto
O `smartview-db-init-job` roda como hook `PreSync`. Hooks Argo CD **re-executam a cada operação
de sync**, não apenas quando o spec do próprio recurso do hook muda — incluindo syncs
automáticos disparados por mudança em qualquer outro recurso da Application. Isso já foi
observado na prática: o Job de init do SmartView voltou a rodar sozinho depois de um drill de
disaster-recovery do Postgres que não tinha relação direta com ele.

## Decisão
Todo hook deste repo é escrito para ser seguro rodar múltiplas vezes: o SQL do
`smartview-db-init-job` usa `CREATE ROLE/DATABASE ... IF NOT EXISTS`-equivalente (idempotente
por construção). Qualquer hook novo (ex.: futuro seed/migração da Fase E) segue a mesma regra.

## Consequências
- Nunca assumir "hook já rodou, não vai rodar de novo" ao raciocinar sobre estado do cluster.
- `env:` literais em vez de `envFrom: configMapRef` nesse Job especificamente — não é sobre
  idempotência, é sobre ordenação de fase (ver histórico em `docs/HANDOFF.md`: ConfigMaps
  normais só existem a partir da fase Sync, e o hook `PreSync` roda antes dela).
