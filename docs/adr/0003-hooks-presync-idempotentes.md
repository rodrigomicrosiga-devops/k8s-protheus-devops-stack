# ADR 0003 — Hooks Argo CD devem ser idempotentes por padrão

## Status
Aceito, confirmado empiricamente (2026-07-27). Título e consequências atualizados em 2026-09-21
(ADR 0016): o `smartview-db-init-job` deixou de ser hook `PreSync` e passou a ser hook `Sync`
(wave 1) — a regra de idempotência em si não mudou, só deixou de ser específica de `PreSync`.

## Contexto
O `smartview-db-init-job` roda como hook Argo CD (`PreSync` até 2026-09-21, `Sync`/wave 1 desde
então — ver ADR 0016). Hooks Argo CD **re-executam a cada operação de sync**, não apenas quando o
spec do próprio recurso do hook muda — incluindo syncs automáticos disparados por mudança em
qualquer outro recurso da Application. Isso já foi observado na prática: o Job de init do
SmartView voltou a rodar sozinho depois de um drill de disaster-recovery do Postgres que não
tinha relação direta com ele.

## Decisão
Todo hook deste repo é escrito para ser seguro rodar múltiplas vezes: o SQL do
`smartview-db-init-job` usa `CREATE ROLE/DATABASE ... IF NOT EXISTS`-equivalente (idempotente
por construção). Qualquer hook novo (ex.: futuro seed/migração da Fase E) segue a mesma regra.

## Consequências
- Nunca assumir "hook já rodou, não vai rodar de novo" ao raciocinar sobre estado do cluster.
- Desde 2026-09-21 (ADR 0016) o Job roda com `psql -v ON_ERROR_STOP=1` — um hook que falha
  silenciosamente e ainda assim sai com exit 0 é pior que um que não é idempotente, porque
  mascara a quebra da própria regra desta ADR numa reexecução. Idempotência deixou de ser só uma
  convenção de estilo do SQL e passou a ser exigida pelo comportamento real do Job.
- A restrição antiga de usar `env:` literais em vez de `envFrom: configMapRef` nesse Job (porque
  hooks `PreSync` rodam antes da fase `Sync`, quando `ConfigMap`s "normais" são criados) não se
  aplica mais — o Job é hook `Sync` agora, então `postgres-config` já existe quando ele roda.
  Ver ADR 0016.
