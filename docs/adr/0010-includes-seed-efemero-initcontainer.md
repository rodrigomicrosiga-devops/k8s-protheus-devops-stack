# ADR 0010 — Seed do `includes` (ADVPL/TLPP) como initContainer efêmero, não Deployment em standby

## Status
Aceito, implementado em 2026-09-18. Ainda não validado com um `compile` real (pendente rodar
`scripts/appserver-patch/run-job.sh compile` depois desta mudança).

## Contexto
O `compile` (Fase E, ADR 0009) precisa dos headers ADVPL (`.ch`) e TLPP (`.th`) da TOTVS pra
resolver `#include` durante a compilação. Até 2026-09-17 esses dois `includes.zip` eram
depositados manualmente no PV `protheus-includes-pv` (hostPath, `base/protheus-patch-storage.yaml`)
— sem repo, sem imagem, sem governança (item 1 do backlog, `docs/HANDOFF.md`).

Investigação em 2026-09-18, antes de decidir o desenho do novo repo
(`docker-protheus-includes`), revelou um detalhe que muda a resposta óbvia ("replicar o padrão
de `docker-protheus-rpo`/`-system`/`-systemload`"): `code_compiler.sh` (dentro de
`docker-protheus-appserver-worker`) já faz `rm -rf /tmp/includes_extracted` e re-extrai os dois
`includes.zip` **do zero, a cada execução do `compile`** — a extração real (que resolve um bug de
`#include` case-sensitive, só reproduzível em diretório real, não lendo direto do zip) já é
inteiramente efêmera, feita pelo próprio script, independente do que estiver no volume
`protheus-includes`. O volume só precisa entregar os dois arquivos `.zip` no lugar certo.

Isso muda a natureza do dado: diferente do RPO (acumula patches, nunca pode ser sobrescrito à
toa) e do fiscal/menus/dicionário de `system`/`systemload` (persistem porque `core`/`rest`/
`telnet` os consultam o tempo todo, sempre no ar), o `includes.zip` é conteúdo de referência
estático, consumido só pelo `compile` — que já é um `Job` efêmero por desenho (ADR 0009), fora de
`base/kustomization.yaml`, nunca tocado pelo sync automático do Argo CD.

## Decisão

1. **`docker-protheus-includes` não é um Deployment em standby.** Ao contrário dos outros três
   seeds, não entra em `base/protheus-seed.yaml`. É consumido como **initContainer** de
   `appserver-compile-job.yaml`, rodando só durante aquele Job específico.
2. **`protheus-includes` deixa de ser PVC/PV com hostPath — vira `emptyDir`.** Sem persistência
   entre execuções do Job: cada `compile` recebe sempre exatamente a revisão que a imagem carrega
   naquele momento, sem risco de drift entre o que está no host e o que a imagem publica.
   `protheus-includes-pv`/`protheus-includes-pvc` removidos de `base/protheus-patch-storage.yaml`.
3. **Sem marcador de idempotência.** Os outros seeds usam um arquivo-marcador pra decidir se
   reprovisionam (RPO: nunca, sem intervenção humana; system/systemload: sempre que a
   release+revisão mudar). Não se aplica aqui — não há volume persistente pra checar, o
   `emptyDir` nasce vazio a cada execução, o entrypoint só copia e termina.
4. **Sem rastreamento pelo Image Updater.** Mesma razão do `appserver-dev-worker`: a
   `compile-job.yaml` que consome a imagem fica fora do Kustomize, então uma entrada no Image
   Updater ficaria inerte (nenhum manifesto rastreado pra aplicar o patch). Tag bumpada
   manualmente em `appserver-compile-job.yaml`.
5. **Versionamento próprio (semver), não a release do Protheus.** `P12_INCLUDES.ZIP` é publicado
   à parte no portal TOTVS, sem relação com o calendário de release do ERP — a revisão em uso é
   de `2026-06-26` e já existe uma mais nova de `2026-08-07`, sem a release `12.1.2510` ter
   mudado. Tag `rodrigomicrosiga/protheus-includes-dev:0.0.1`, bump manual a cada atualização de
   qualquer um dos dois `.zip`.
6. **Zips não versionados no repo** (`.gitignore`), mesma trava de governança dos outros seeds —
   CI resgata do disco do runner self-hosted, a partir de
   `docker-protheus-devops-stack/protheus/includes/{advpl,tlpp}/`.

## Consequências
- Fecha a lacuna de governança do item 1 do backlog: `includes.zip` agora tem repo, CI e imagem
  versionada — só falta a decisão do usuário sobre aplicar a revisão nova do `advpl` (157
  arquivos) e sobre a origem do `tlpp` (ainda não identificada, ver README do repo novo).
- `custom/` fica de fora da imagem de propósito — é ponto de injeção do próprio dev (fora de
  governança TOTVS), não um artefato deste seed. O diretório de destino continua sendo criado
  pelo `initContainer` `prepare-volumes` já existente em `appserver-compile-job.yaml`.
- Diferente dos outros três seeds, este não precisa de `regcred` correndo 24/7 nem de espaço em
  disco reservado (PV) pra algo lido só quando um dev decide compilar — mais barato em recursos
  do node, sem nenhuma perda de robustez (o dado é estático, não há "estado" a proteger).
- Pendência real: esta mudança ainda não foi validada com um `compile` de ponta a ponta (o
  próximo teste real de `compile` vai confirmar se o initContainer novo entrega os zips
  corretamente pro `code_compiler.sh`).
