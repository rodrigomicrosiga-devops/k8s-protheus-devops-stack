# ADR 0001 — `license` e `smartview` rodam como pods privilegiados

## Status
Aceito, validado em produção (2026-07-27).

## Contexto
Duas exceções à migração non-root do fleet (Fase 3.4 item 3):

- **`license`**: o License Server Virtual da TOTVS faz fingerprint de hardware (serial/MAC/DMI
  da placa-mãe) lendo `/dev/mem` via `dmidecode`, para amarrar a licença à máquina. O kernel
  Linux nega esse acesso a qualquer UID ≠ 0, mesmo com o processo no grupo `kmem` — testado e
  confirmado, não é possível contornar com capabilities granulares (`CAP_SYS_RAWIO` sozinho não
  basta na prática desse binário).
- **`smartview`**: a imagem roda systemd como PID 1 (o agente SmartView é um `.service`
  systemd), o que exige `privileged: true` e acesso de escrita a `/sys/fs/cgroup`.

## Decisão
Manter `privileged: true` nos dois Deployments (`base/license.yaml`, `base/smartview.yaml`),
com o hostPath `/dev/mem` (`type: CharDevice`) montado explicitamente no `license`. Ambos ficam
fixados no mesmo node via `nodeAffinity` dos PVs relacionados — o fingerprint de hardware muda
entre nodes, então mover o pod de node invalidaria a licença.

## Consequências
- Nenhum dos dois pods pode ter HPA nem rolling update seguro (ver ADR 0002).
- `smartview` exige um orçamento de `fs.inotify.max_user_instances`/`max_user_watches` a nível
  de **host** (não namespaced por container neste setup) — default do Linux (128 instâncias) é
  insuficiente para um systemd completo; ajustado via `/etc/sysctl.d/99-inotify-smartview.conf`
  fora do cluster, é pré-requisito de infraestrutura do node, não do Kustomize.
- Estado da licença não é persistido em volume nenhum — recriar o pod `license` reativa a
  licença (comportamento herdado do Compose original, aceito como está).
