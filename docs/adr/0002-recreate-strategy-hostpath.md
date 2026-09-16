# ADR 0002 — `strategy: Recreate` em todo Deployment singleton sobre hostPath

## Status
Aceito, validado com um incidente real (2026-07-27).

## Contexto
O primeiro rollout do postgres usando a estratégia default (`RollingUpdate`) causou um restart
transiente: `could not open file "postmaster.pid"` / `data directory lock file is invalid`, no
instante de handoff entre a geração antiga e a nova do pod. Causa: `RollingUpdate` pode manter
as duas gerações de pod vivas por uma fração de segundo, e ambas apontam para o mesmo diretório
via hostPath singleton — sem exclusão mútua real entre elas.

## Decisão
Todo Deployment que é logicamente um singleton com estado sobre hostPath usa
`strategy: type: Recreate`: `postgres`, `license`, `webapp`, `printer`, `smartview`,
`appserver-core`. Aplica-se também aos futuros `appserver-rest`/`appserver-telnet`.

## Consequências
- Cada rollout tem uma janela de indisponibilidade real (o pod antigo termina antes do novo
  subir) — aceitável neste contexto de dev/homolog, não seria para um serviço de produção HA.
- Sem essa estratégia, qualquer singleton com hostPath está sujeito ao mesmo tipo de corrupção
  transiente — não é específico do Postgres.
