# ADR 0004 — `nodeAffinity` de PV já existente é imutável; 3 PVs ficam sem o campo no git

## Status
**Dívida quitada em 2026-09-18** — os 3 PVs foram recriados do zero com `nodeAffinity` desde o
nascimento. Ver ADR 0012 para o procedimento real (e os obstáculos reais enfrentados). Este ADR
fica como registro histórico do problema original e da decisão de não fazer retrofit.

## Contexto
`spec.nodeAffinity` de um `PersistentVolume` já criado é imutável no Kubernetes — nem `kubectl
patch` nem sync do Argo CD conseguem adicionar/remover o campo depois, mesmo quando o valor
alvo já bate exatamente com o que o PV tem de fato. Tentativa de retrofit em `postgres-pv`,
`webapp-shared-pv` e `printer-shared-pv` (2026-07-28) causou falha perpétua de sync
(`field is immutable`) até ser revertida.

Um `kubectl apply -k` direto (bypassando o Argo CD) conseguiu forçar o valor uma vez via
three-way-merge tolerado pela API — mas o Argo CD tentando sincronizar a mesma mudança falhava
sempre. A correção foi reverter do git e editar manualmente a anotação
`kubectl.kubernetes.io/last-applied-configuration` desses 3 PVs (removendo `nodeAffinity` dela),
para parar de gerar diffs fantasmas.

## Decisão
Esses 3 PVs **não declaram `nodeAffinity` no git**, mesmo rodando com ela de fato aplicada no
cluster (fixados no mesmo node via edição direta, fora do fluxo GitOps). `protheus-seed.yaml`
(criado depois, do zero) já nasceu com `nodeAffinity` desde o primeiro apply — o problema é
exclusivo de PV que **já existia** antes da decisão de fixar o node.

## Consequências
- ~~**Dívida de disaster-recovery real**: recriar o cluster do zero a partir deste repo recria
  esses 3 PVs **sem** `nodeAffinity`.~~ Resolvido em 2026-09-18 (ADR 0012) — os 3 PVs foram
  recriados do zero e já declaram `nodeAffinity` no git desde então.
- Regra para qualquer PV novo: declarar `nodeAffinity` desde o primeiro commit (como
  `protheus-seed.yaml` já faz) evita este problema por completo. Nunca declarar retroativamente
  um campo imutável no git a menos que o valor já bata E a anotação `last-applied-configuration`
  já reflita isso.
