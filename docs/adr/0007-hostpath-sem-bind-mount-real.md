# ADR 0007 — hostPaths do cluster não têm bind mount real no disco físico

## Status
Aceito como dívida conhecida, com plano de correção (2026-09-16).

## Contexto
Descoberto ao retomar o cluster após 6 semanas parado: nenhum PV deste repo
(`postgres-pv`, os 5 do AppServer em `protheus-seed.yaml`, `webapp-shared-pv`, `printer-shared-pv`)
tem seus dados de fato no disco físico do host, apesar de `spec.hostPath.path` apontar para
`/media/rodrigo/dados/k8s-volume/<nome>`. O node `k3d-protheus-cluster-agent-0` não tem **nenhum**
bind mount de `/media/rodrigo/dados` — confirmado via `docker inspect` (mounts do node são só
volumes internos do k3d: `/k3d/images`, `/var/log`, `/var/lib/cni`, `/var/lib/kubelet`,
`/var/lib/rancher/k3s`). O caminho `/media/rodrigo/dados/k8s-volume/...` existe **dentro** do
node, mas é só a camada de container do próprio node — não está conectado ao host de forma
alguma. Isso já é assim desde a criação do cluster (Fase B, ~2026-07-28), não é uma regressão
desta sessão.

**Consequência real**: os ~50 dias de dados de `postgres`, `webapp-shared` e `printer-shared`
do cluster (não do Compose local, que é um ambiente inteiramente separado) só sobrevivem
enquanto o container `k3d-protheus-cluster-agent-0` existir. `docker restart` é seguro
(confirmado nesta sessão). `k3d cluster delete`, `docker rm` do node, ou qualquer recriação do
cluster **apaga tudo sem possibilidade de recuperação** — não é uma questão de backup ausente,
é ausência total de persistência fora do container.

## Decisão
Prosseguir com a Fase C (seeds do AppServer) no armazenamento atual — o risco não é introduzido
por essa fase, é pré-existente, e adiar a Fase C não o resolve. Migrar para bind mount real
(`k3d cluster create` com `--volume /media/rodrigo/dados/k8s-volume:/media/rodrigo/dados/k8s-volume@agent:0`
ou equivalente) fica registrado como item de alta prioridade no backlog (`docs/HANDOFF.md`), a
ser feito como tarefa dedicada: exportar/migrar os dados atuais de `postgres`/`webapp-shared`/
`printer-shared` antes de recriar o cluster, para não perder os 50 dias de estado já validado.

## Consequências
- Até a correção, **nunca rodar `k3d cluster delete` nem remover o container do node** sem
  antes fazer backup explícito (`docker cp` de dentro do node, ou `pg_dump` para o Postgres).
- Qualquer nova seed/dado gravado agora (RPO, system, systemload) está sob o mesmo risco e
  precisará ser re-extraído das imagens seed depois da migração (barato — são imagens já
  publicadas, idempotentes por marcador) ou migrado junto com o resto.
- A migração correta deve ser feita com o cluster inteiro parado, copiando o conteúdo atual de
  dentro do node para o host antes de recriar, não confiando em `docker cp` durante escrita ativa.
