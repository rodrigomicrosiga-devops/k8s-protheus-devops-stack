# HANDOFF — estado vivo do projeto

> Atualize este arquivo ao fim de cada sessão de trabalho real (não a cada commit pequeno).
> Formato: mantenha a seção "Onde paramos" sempre no topo e mova o resto para "Histórico" quando
> deixar de ser o ponto ativo.

## Onde paramos (fim da sessão de 2026-09-18, parte 2)

**Verificar ao retomar, antes de qualquer coisa nova**:

1. **Boot ficou higiênico?** `docker ps -a` não deve mostrar os 6 containers do Compose
   (`protheus_core`/`postgres`/`license`/`webapp`/`printer`/`dbaccess`) rodando sozinhos — eles
   devem estar `Exited`, não `Up`, a menos que o usuário os suba deliberadamente. Se algum
   estiver `Up` sem ter sido pedido, ver a regra operacional nova abaixo sobre `docker stop` em
   container já parado por falha — não é mais a policy `unless-stopped` em si (já confirmada
   correta nos 6).
2. **Bump do k8s se sustentou?** `kubectl get applications -n argocd protheus-devops-stack` deve
   seguir `Synced`/`Healthy`; `kubectl get pods -n protheus-devops -o
   custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'` deve mostrar
   `appserver-dev:24.3.1.9` (core/rest/telnet) e `license-dev:3.7.2` — não voltou pra
   24.3.1.5/3.7.1. Se tiver voltado, o Image Updater pode ter re-resolvido pra outra coisa;
   investigar antes de mexer em qualquer manifesto.
3. **Itens 0 e 5 do backlog fechados nesta sessão** — Compose validado ao vivo nas tags novas e
   `README.md` atualizado (Fases C/D/E, scripts, prompts), ver abaixo. Nada pendente aqui.
4. **Item 1 do backlog (`includes.zip`) implementado E validado ao vivo** — repo
   `docker-protheus-includes` criado, publicado, CI rodou com sucesso
   (`protheus-includes-dev:0.0.1` no Docker Hub), e `run-job.sh compile` confirmou duas vezes
   que o `initContainer seed-includes` entrega os zips certos (`Precompilation... ok` nas duas).
   Nenhum `compile` terminou com sucesso total ainda (fonte de teste colidiu com função já
   existente no `custom.rpo` — não é falha do include), mas isso não bloqueia mais nada; próximo
   `compile` real com fonte sem colisão deve fechar limpo. Ver ADR 0010.

**Item 0 do backlog fechado** (validação ao vivo do Compose nas tags novas — passos 8–9 de
`docs/prompts/atualizar-tags-compose.md`, no repo `docker-protheus-devops-stack`). Antes disso,
corrigido o desvio da checklist herdado da sessão anterior: o `protheus_dbaccess` tinha voltado
sozinho no boot desta manhã, degradado (sem rede anexada, loop de `nc` sem resolver
`protheus_postgres`) — causa raiz real documentada na regra operacional nova abaixo, não era a
policy `unless-stopped`. `docker stop protheus_dbaccess` (com ele rodando) resolveu.

Como o próximo passo ia subir a stack Compose de propósito, e ela disputa a porta `7890` do host
com o `serverlb` do k3d (mesma colisão do boot de 17/09), a decisão do usuário ("cluster é
prioridade") foi aplicada de forma permanente: `dbaccess` do Compose agora publica em `7891` no
host (`DBACCESS_HOST_PORT`, default `7891` em `docker-compose.yaml`), mantendo `DBACCESS_PORT`
(7890) intacto como porta interna — nenhum appserver percebe diferença, todos falam com
`protheus_dbaccess:7890` pela rede `protheus_network`. Commit `18bb275` no
`docker-protheus-devops-stack`. Isso também tira urgência do item 5 do backlog deste repo (limpar
o mapeamento inerte da 7890 no `serverlb`) — segue desejável, mas deixou de causar colisão prática.

Gate de bootstrap respeitado: antes de subir o `core`, banco contado isoladamente (53 tabelas
`SYS_*` — base já populada, não era base nova) via `postgres_db` sozinho, só então `./run.sh
postgres`. Validado ao vivo: os 6 containers subiram limpos nas tags novas (confirmado via
`docker ps` — `appserver-dev:24.3.1.9`, `license-dev:3.7.2`), `protheus_dbaccess` e
`protheus_license` `healthy`, `protheus_core` log interno
(`/totvs/protheus/log/appserver_core.log`) confirmou `Totvs Application Server is running` em
13.36s sem erro fatal e sem pedido de bootstrap (o único warning, `OPEN EMPTY RPO`, é esperado —
`custom.rpo` do Compose começa vazio até um compile local, ambiente separado do cluster). Cluster
k3d conferido depois, sem impacto: `Synced`/`Healthy`, sem restarts novos. Stack local parada de
volta (`docker compose stop`, todos os 6, incluindo `postgres_db` que tinha sido subido à parte)
ao encerrar a validação — não fica no ar.

**Achado sobre o log do appserver**: `appserver_core.log` (e provavelmente os outros do
AppServer) é um arquivo pré-alocado — o conteúdo real fica intercalado com bytes nulos de
padding, não é texto puro sequencial. `tail`/`grep` direto no arquivo retorna majoritariamente
padding (`\0`) e pode estourar limite de output em ferramentas que capturam texto. Ler com
`tr -d '\000' < arquivo | tail -c N` (descarta os nulos antes de cortar) — `docker logs` do
container não serve aqui, o entrypoint não propaga o log do `appsrvlinux` pro stdout do
container além do banner inicial.

**Item 5 do backlog fechado**: `README.md` estava parado na Fase B — não mencionava
`protheus-seed.yaml` (Fase C), `appserver-core`/`-rest`/`-telnet` (Fase D) nem os Jobs
`worker`/`compile`/`upddistr` (Fase E), e ainda citava `base/appserver.yaml` como
"incompleto/WIP" (removido em 2026-09-17, substituído pelos três manifestos reais, que já
montam `webapp-shared`/`printer-shared` read-only — a lacuna que o texto antigo apontava já
estava fechada, só não registrada). Diagrama Mermaid ganhou as camadas de seeds e AppServer;
seção de GitOps atualizada com a lista real de imagens rastreadas pelo Image Updater
(`appserver-dev` e os 3 seeds faltavam) e o achado do `writeBackConfig`; nova seção linkando
`docs/HANDOFF.md`, `docs/adr/`, `scripts/k3d-nodes/`, `scripts/appserver-patch/` e
`docs/prompts/` — nenhum tinha menção no README antes. Commit `fded313`.

**Item 1 do backlog aprofundado (nomes exatos dos zips de `includes`)**: busca no disco (não só
no handoff) achou o zip real da revisão nova do `advpl` já baixado
(`~/Downloads/26-08-07-P12_INCLUDES.ZIP`, 157 arquivos) — a revisão em uso não existe mais sob o
nome original, só extraída. Pro `tlpp`, achado novo que não fecha a questão mas avança: os 6
`tlpp-*.th` em uso são idênticos byte-a-byte aos de
`/media/rodrigo/dados/totvs/protheus/2410/includes/` (instalação local antiga do Protheus 24.10),
mas isso é só de onde foram copiados — não é o pacote TOTVS de origem, e não é o mesmo
`P12_INCLUDES.ZIP` do advpl (que tem `.th` só que prefixados `fw-tlpp-*`, schema diferente).
Origem do `tlpp` continua aberta. Detalhe completo no item 1 do backlog abaixo.

**`webagent` adicionado ao backlog (item 6)** a pedido do usuário — componente novo
(`docker-protheus-webagent` não existe ainda), artefato já baixado desde 02/07
(`~/Downloads/26-07-02-P12_SMARTCLIENT_WEB-AGENT_1.1.1_LINUX_X64.TAR.GZ`) mas sem nenhum
trabalho de containerização começado.

**Item 1 do backlog implementado (`docker-protheus-includes`)**: decisão tomada com o usuário —
seed **efêmero**, não Deployment em standby como rpo/system/systemload. Achado que motivou o
desenho: `code_compiler.sh` (dentro do `appserver-dev-worker`) já re-extrai os dois
`includes.zip` do zero a cada `compile`, então o volume nunca precisou ser persistente — só
entregar os dois `.zip` no lugar certo, uma vez por execução do Job. Detalhe completo e
alternativas descartadas em `docs/adr/0010-includes-seed-efemero-initcontainer.md`.

Implementado: repo `docker-protheus-includes` criado do zero
(Dockerfile/entrypoint/CI/.gitignore, seguindo o padrão dos outros seeds) e publicado —
`github.com/rodrigomicrosiga-devops/docker-protheus-includes` (privado, branch `develop`,
commit `1d4b8d0`). Versionamento **próprio** (semver `0.0.1`), não a
release do Protheus — o `P12_INCLUDES.ZIP` é publicado à parte no portal TOTVS, sem relação com o
calendário de release (a revisão em uso é de 26/06 e já existe uma mais nova de 07/08, sem a
release `12.1.2510` ter mudado). Zips não versionados no repo (`.gitignore`), CI resgata do disco
do runner self-hosted a partir de `docker-protheus-devops-stack/protheus/includes/`.

No cluster: `appserver-compile-job.yaml` ganhou um `initContainer` novo (`seed-includes`, roda
depois do `prepare-volumes` já existente) que copia os dois zips pra dentro do volume
`protheus-includes` — que deixou de ser PVC/PV com hostPath e virou `emptyDir`.
`protheus-includes-pv`/`-pvc` removidos de `base/protheus-patch-storage.yaml` (diretório antigo
no host, `/media/rodrigo/dados/k8s-volume/protheus-includes/`, fica órfão, não foi limpo). Sem
marcador de idempotência (não se aplica — conteúdo estático) e sem rastreamento pelo Image
Updater (mesma razão do `appserver-dev-worker`: a `compile-job` fica fora do Kustomize, tag
bumpada manualmente). `scripts/appserver-patch/README.md` atualizado — o passo de depósito
manual dos includes não existe mais.

**Validado de ponta a ponta, mesmo dia**. Usuário configurou `DOCKERHUB_USERNAME`/
`DOCKERHUB_TOKEN` no repo novo (token do Docker Hub recriado — o original tinha sido perdido,
nunca é recuperável, nem em secrets do GitHub nem em tokens do Docker Hub, por design). Esclarecido
de passagem: repo privado + Actions secrets sempre funcionaram normalmente em qualquer plano —
não existe restrição alguma aí; o único limite real do plano gratuito (minutos de runner
*hospedado pelo GitHub* em repo privado) nunca chegou a se aplicar, porque todo o fleet usa
`runs-on: self-hosted` (a própria máquina do usuário, já registrada como runner desde antes deste
repo, confirmado com um run antigo de sucesso em `docker-protheus-rpo`).

O run inicial (do push do commit `1d4b8d0`) tinha falhado no login do Docker Hub, como esperado
sem secrets — `gh run rerun` depois de configurados os secrets, sucesso em 41s.
`rodrigomicrosiga/protheus-includes-dev:0.0.1` confirmada publicada via `docker manifest
inspect`.

`run-job.sh compile` rodado duas vezes com fonte real (fornecido pelo usuário,
`teste-devops.prw`, usa `#include 'totvs.ch'`) — nas duas, `Extraindo includes [advpl]`/
`[tlpp]` e `ADVPL Preprocessor: Precompilation... ok`, confirmando que o `initContainer
seed-includes` funciona. Nenhuma das duas terminou com sucesso total: a primeira tentativa
tinha um `teste.prw` antigo (de 17/09) ainda na fila junto, colidindo por nome de função
(`U_TESTE`) com o fonte novo — removido, segunda tentativa rodou só com `teste-devops.prw`, mas
a mesma função já estava gravada no `custom.rpo` desde a compilação de 17/09, então o compilador
rejeitou de novo (`Duplicated function`, correto — o RPO customizado é incremental, não é bug).
Rollback automático confirmado nas duas vezes: hash do `custom.rpo` inalterado
(`b390e7ce...`), `appserver-core`/`rest`/`telnet` religados sozinhos pelo `run-job.sh`,
`Synced`/`Healthy` depois. Decisão registrada com o usuário: dar a infra por validada sem
insistir num `compile` 100% verde agora — a parte que importava (entrega dos includes) já está
provada; um `compile` limpo fica pro próximo fonte real sem colisão de nome. Detalhe completo em
`docs/adr/0010-includes-seed-efemero-initcontainer.md` (status atualizado).

**Item 2 do backlog fechado (cofre local pro `postgres-secret.env`)**: avaliado o risco real
antes de agir (cluster local, single-dev, senha já documentada como default no `CLAUDE.md`) —
usuário escolheu criptografia em repouso, não rotação nem aceitar-e-documentar sem mudança.
`base/postgres-secret.env` (plaintext, sem backup até então) criptografado com GPG simétrico
AES256, round-trip verificado por hash (nunca exibindo o conteúdo), plaintext removido do disco
depois. `base/postgres-secret.env.gpg` é o novo backup versionado; `scripts/secrets/`
(`encrypt.sh`/`decrypt.sh`, genéricos) documentam o fluxo — os dois pedem a passphrase
interativamente, nunca por argumento/env, então não são algo que uma sessão automatizada roda
sozinha. Passphrase gerada (`openssl rand -base64 32`) e entregue uma única vez ao usuário nesta
sessão — não fica retida em lugar nenhum além do gerenciador de senhas dele. Confirmado que os
outros 3 segredos selados (`smartview`, `appserver-upddistr`, `regcred`) não têm cópia plaintext
no disco — só o Postgres tinha esse problema. Detalhe completo em
`docs/adr/0011-cofre-local-gpg-secrets-plaintext.md`.

## Histórico condensado da sessão de 2026-09-18, parte 1

Retomada do handoff de 17/09. Item 0 do backlog (atualização de binários TOTVS) fechado no lado
k8s — era o que faltava de fato; os passos 1 (repos irmãos) e 2 (Compose) já tinham sido
adiantados na sessão anterior sem o handoff ter sido atualizado antes do reboot.

**Higiene do boot**: os 6 containers do Compose (`protheus_core`/`postgres`/`license`/`webapp`/
`printer`/`dbaccess`) voltaram sozinhos neste boot apesar do fix `unless-stopped` já commitado
(`2c674b9`, sessão anterior) — a policy de restart fica gravada no container no momento em que
ele é criado, não é relida do `docker-compose.yaml` a cada boot; nenhum dos 6 tinha sido
recriado desde o commit. Efeito real: o `serverlb` do k3d venceu a corrida pela porta `7890` (já
prevista como risco no handoff anterior) e o `protheus_dbaccess` morreu (`Bind for :::7890
failed: port is already allocated`); o `protheus_core` ficou desde então girando em loop de
`nc` esperando o dbaccess, sem nunca subir o `appsrvlinux` (não chegou a haver risco de
bootstrap). Decisão do usuário: **no boot, o cluster é a prioridade** — a stack Compose não deve
subir sozinha. Fix aplicado: `docker update --restart unless-stopped` nos 6 containers vivos (sem
recriar) + `docker stop` neles.

**Correção registrada em 2026-09-18 (parte 2)**: o fix acima não foi suficiente — no boot
seguinte (mesmo dia, de manhã) o `protheus_dbaccess` voltou sozinho de novo, apesar de
`unless-stopped` confirmado gravado nele. Causa raiz real, diferente do que se supôs aqui: o
`docker stop` da sessão anterior foi um no-op nele, porque ele **já estava parado por falha**
(a colisão de porta descrita acima) — `unless-stopped` só pula um container que foi **parado
manualmente**, e um container que morre por falha não conta como isso. Ver regra operacional
nova abaixo. A colisão de porta em si foi resolvida de vez na mesma sessão (não mais "inerte,
ver backlog"): `dbaccess` do Compose passou a publicar em `7891` no host — ver item 0 do backlog
fechado, seção "Onde paramos" no topo.

**Binários TOTVS — item 0 fechado no k8s**: confirmado que a `Application` usa `writeBackConfig:
argocd` — o Image Updater grava o digest resolvido como override em
`spec.source.kustomize.images`, e esse override **vence o que está no git**. Um bump só em
`base/*.yaml` não teria efeito nenhum sozinho; era preciso editar também
`argocd/image-updater.yaml` e reaplicá-lo. Achado novo, registrado nas regras operacionais
abaixo. Editado (tags confirmadas publicadas via `docker manifest inspect` antes de escrever):
`appserver-dev` 24.3.1.5→**24.3.1.9** (core/rest/telnet/upddistr), `appserver-dev-worker`
24.3.1.5→**24.3.1.9** (worker/compile), `license-dev` 3.7.1→**3.7.2** — nos manifestos do
Kustomize e nos 3 Jobs deliberadamente fora dele (ADR 0009), mais os aliases `appserver`/
`license` do `image-updater.yaml`. Commit `6f54252`, push, `kubectl apply -f
argocd/image-updater.yaml`, ciclo do Image Updater reescreveu os overrides
(`images_updated=2`), Argo CD sincronizou sozinho: `Synced`/`Healthy`, `appserver-core`/`rest`/
`telnet`/`license` com pods novos, 0 restarts. Confirmado depois: hash do RPO inalterado
(`9e8d81d8…`, mesmo do patch "onça pintada"), 54 tabelas `SYS_*` intactas.

**Pendência que fica registrada, não esquecida**: o Compose nunca foi de fato recriado com as
tags novas (`appserver-dev`/`appserver-dev-worker` 24.3.1.9, `license-dev` 3.7.2) — o commit
`2cfd5d8` da sessão anterior só editou o `docker-compose.yaml`, "a pedido, sem subir a stack".
Os containers locais pararados nesta sessão continuam nas imagens antigas. Rodar
`docs/prompts/atualizar-tags-compose.md` (passos 8–9, validação ao vivo) quando fizer sentido —
não é bloqueante pra nada no cluster.

**Item 1 do backlog (`includes.zip` sem repo/governança) — investigado, não implementado**:
consumidor real é `docker-protheus-appserver-worker/code_compiler.sh:26-49` — cada zip
(`advpl`/`tlpp`/`custom`) é extraído pra um diretório real antes do compile, porque a resolução
de `#include` aninhado dentro do próprio zip é case-sensitive e falha (`File not found
PRTOPDEF.CH`) se lido direto do zip. Origem confirmada do `advpl`: é um pacote `P12_INCLUDES.ZIP`
do portal TOTVS, mesmo padrão de nomenclatura dos demais binários — o que está em uso hoje (155
arquivos, jun/29) é uma revisão anterior à disponível em downloads (`26-08-07-P12_INCLUDES.ZIP`,
157 arquivos). Origem do `tlpp` (`.th` de 2025-06-02) segue não identificada. `custom` é ponto de
injeção do próprio dev, vazio por design, não é artefato TOTVS. Decisão de criar (ou não) um
`docker-protheus-includes` seguindo o padrão de seed image (rpo/system/systemload) fica em aberto
pro usuário — ver backlog.

**Estado ao encerrar a sessão de 2026-09-18**:
- **Compose**: todos os 6 containers `Exited` (parados nesta sessão, passo A). Não devem voltar
  sozinhos no próximo boot (`unless-stopped` já aplicado nos containers vivos, não só no
  arquivo).
- **Cluster k3d**: no ar, `Synced`/`Healthy`, appserver-core/rest/telnet e license confirmados em
  24.3.1.9/3.7.2 com 0 restarts.
- **Nada em voo**: os 2 commits desta sessão (`6f54252` bump de imagens, `31644bb` este handoff)
  já têm `push` pra `origin/develop`. Sem trabalho local não commitado.

## Histórico condensado da sessão de 2026-09-17

Sessão de retomada pós-reboot da máquina. Dois problemas de boot resolvidos e o item 0 do
backlog (persistência real dos hostPaths, alta prioridade) fechado. Detalhe completo em
`docs/adr/0008-bind-mount-real-recriacao-isolada-dos-nodes.md`.

**Boot da máquina**:
1. Compose local religou sozinho porque os 11 serviços tinham `restart: always` (religa mesmo
   depois de um `docker stop` manual, ao contrário de `unless-stopped`) — corrigido para
   `unless-stopped` em `docker-protheus-devops-stack/docker-compose.yaml`.
2. O `serverlb` do k3d morreu no boot: colisão de porta `7890` com o `protheus_dbaccess` do
   Compose (os dois publicam essa porta no host). Esse mapeamento do LB não é usado por nada (o
   acesso real ao dbaccess do cluster é via `kubectl port-forward`) — considerar removê-lo da
   receita do LB quando ela for versionada (ver backlog).

**Item 0 fechado**: `agent-0` recriado com bind mount real de `/media/rodrigo/dados/k8s-volume`
(sem tocar no `server-0`, sem `k3d cluster delete`). Dois problemas reais não previstos no meio
do caminho, ambos documentados no ADR 0008 com o fix exato: Secret de senha de registro do node
(`kube-system/<node>.node-password.k3s`) precisa ser apagado a cada recriação de container; e um
bug de cgroup v2 (`--cgroupns private` incompatível com o driver `systemd` do Docker neste host)
resolvido trocando para `--cgroupns host` nos dois nodes. Backups tirados antes de mexer:
`pg_dump` do Postgres e `tar` do datastore SQLite do `server-0`, ambos em
`/media/rodrigo/dados/backups/` (fora do git). Nenhum dado perdido — validado ao vivo.

**Receita dos nodes versionada** (mesmo dia): `scripts/k3d-nodes/` — `docker run` completo e
parametrizado para recriar `agent-0`/`server-0` preservando o estado (volumes nomeados +
bind mount), com token do cluster auto-detectado do node irmão em vez de hardcoded. Ver
`scripts/k3d-nodes/README.md`. Fecha o item que tinha nascido como novo item 0 mais cedo na
mesma sessão — não ficou órfão no backlog.

**Fase D fechada** (mesmo dia): `appserver-rest.yaml` e `appserver-telnet.yaml` registrados em
`base/kustomization.yaml`, push pra `origin/develop`, Argo CD sincronizou sozinho (`selfHeal`).
Bug real encontrado na revisão antes de aplicar: os dois manifestos ainda tinham
`ENV_NAME=protheus_dev`, resíduo de antes da padronização de nomenclatura de 2026-09-16 (nunca
tinha sido sincronizado com o `core`, que já usava `protheus`) — corrigido antes do commit.
Pods `appserver-rest`/`appserver-telnet` `1/1 Running`, sem restarts, probes TCP (8400/23)
passando.

**`image-updater.yaml` fechado** (mesmo dia): passou a rastrear `appserver-dev` (uma entrada
só cobre core/rest/telnet — mesma imagem) e as 3 imagens de seed (RPO, system, systemload).
Decisão registrada inline no arquivo: RPO tem uma única imagem por release (nunca muda de
digest sob a mesma tag — diferente de system/systemload, que recebem várias atualizações
dentro do mesmo release), então rastrear via digest é seguro nos três, ao contrário do que eu
tinha suposto inicialmente. `appserver-dev-worker` (Fase E) ficou de fora de propósito — ver
seção da Fase E abaixo pro motivo atualizado. Aplicado via
`kubectl apply -f argocd/image-updater.yaml` (README já documenta esse fluxo, fora do
Kustomize/Argo CD self-managed). Efeito colateral esperado e confirmado seguro: a primeira
resolução tag→digest causou um restart único em `appserver-core`/`rest`/`telnet` e nos 3 seeds
— todos subiram limpos, hash do RPO (`568f185e...`) e as 53 tabelas `SYS_*` confirmados
intactos depois. O seed do RPO já é idempotente por design ("Seed em standby — governança do
volume via Image Updater").

**Fase E, parte 1 fechada** (mesmo dia): `worker` e `compile` no cluster k8s, validado ao vivo
de ponta a ponta. Achado que corrigiu a suposição original do backlog ("hooks Argo CD
PreSync/PostSync fazendo `scale`"): a `Application` tem `selfHeal: true` + `prune: true` sem
`ignoreDifferences` — um hook automatizado fazendo `kubectl scale` seria revertido pelo próprio
Argo CD no sync seguinte. Desenho final: `replicas: 0` **commitado no git** (precedente do ADR
0006), Jobs (`base/appserver-worker-job.yaml`, `-compile-job.yaml`) deliberadamente **fora**
de `kustomization.yaml` (nunca tocados pelo sync automático — hooks PreSync re-rodam a cada
sync por ADR 0003, incompatível com a regra do `CLAUDE.md` de nunca rodar antes do bootstrap
manual), disparados só via `scripts/appserver-patch/run-job.sh`. Dois bugs reais achados e
corrigidos no primeiro teste ao vivo: (1) `appserver-dev-worker` nunca tinha sido puxada neste
node, pull anônimo esbarrou no rate limit do Docker Hub (429) — fix `imagePullSecrets: regcred`;
(2) `envFrom: configMapRef: postgres-config` nunca resolvia, porque o nome real do ConfigMap
sai com hash do `configMapGenerator` e só é reescrito pra recursos dentro do
`kustomization.yaml` — fix: `DB_NAME`/`DB_TYPE` como env literais (mesmo padrão já usado em
`smartview-db-init-job.yaml`, mesmo motivo raiz). Dois ciclos completos rodaram via
`run-job.sh` de ponta a ponta sem intervenção manual, cada um pausando core/rest/telnet
(commit+push+sync+espera) e restaurando depois:
- **`worker`** com fila vazia (no-op esperado, `"Nenhum patch encontrado... Finalizando
  Job."`) — hash do RPO (`568f185e...`) inalterado depois.
- **`compile` com fonte real** (`teste.prw`, fornecido pelo usuário) — sucesso completo:
  `Total sources(1) Success(1) Errors(0)`, `custom.rpo` criado do zero (21.190 bytes) com o
  fonte integrado, `tttm120.rpo` (RPO base) inalterado — confirma a separação esperada entre
  RPO base e RPO customizado. Os `includes.zip` (advpl/tlpp) precisaram ser depositados manualmente
  no volume do cluster antes (`/media/rodrigo/dados/k8s-volume/protheus-includes/`, copiados
  dos mesmos arquivos já usados pelo Compose) — primeira vez que esse volume era usado.

Confirmado depois dos dois: 53 tabelas `SYS_*` intactas, sem erro nos logs, Argo CD
`Synced`/`Healthy`.

**Fase E fechada por completo** (mesmo dia): `upddistr` validado ao vivo com pacote real da
TOTVS (fornecido pelo usuário —
`26-08-21_ATUALIZACAO_12.1.2510_BACKOFFICE_EXPEDICAO_CONTINUA.ZIP`). Mecanismo novo pro repo,
detalhado no ADR 0009: `shareProcessNamespace: true` + sidecar `result-watcher` (`busybox`) que
mata o `appsrvlinux` via PID namespace compartilhado assim que `Result.json`/`result.json`
aparece — não dá pra injetar wrapper no container principal (`entrypoint.sh` faz
`exec appsrvlinux`). Achado importante confirmado ao vivo: **o status do Job não é confiável**
pra `upddistr` — um teste que falhou por autorização (`UPD_PASSWORD` errado) ainda assim
terminou com o Job `succeeded` (o `SIGTERM` não garante exit code refletindo o resultado real).
`run-job.sh` lê o `Result.json` direto do bind mount do host (`docker exec` no `agent-0`),
nunca confia no status do Job pra esse papel. Credencial do UPDDISTR (`UPD_PASSWORD`) selada
via `kubeseal` (`appserver-upddistr-secret.sealed.yaml`), nunca literal no YAML — senha real do
administrador fornecida pelo usuário (definida no bootstrap manual, sem default). Teste real:
arquivos `sdf/bra/*` do pacote depositados na raiz de `protheus-systemload` (sem subdiretórios,
conforme o `manifest.json` do próprio pacote pede), `upddistr` completou com
`{"result":"success"}`, 54 tabelas `SYS_*` (uma a mais — dicionário de fato atualizado), hash do
RPO base inalterado, `appserver-core`/`rest`/`telnet` religados sem erro.

**`worker` também validado em escala real** (mesmo dia, pacote menor fornecido pelo usuário —
`26-08-17-LIB_LABEL_17082026_P12_ONCA.ZIP`, um `.ptm` de 80 MB, "onça pintada"). Backup extra do
`tttm120.rpo` tirado no host antes (`/media/rodrigo/dados/backups/tttm120-pre-worker-patch-
20260917.rpo`, além do backup interno que o próprio `patch_deployer.sh` já faz em
`aporollback/`). Patch aplicado com sucesso (`ApplyPatch: 190.681s`) — primeira vez que o RPO da
produção do cluster foi de fato modificado por um patch real (antes só o `custom.rpo` tinha sido
tocado, pelo teste de `compile`): hash mudou de `568f185e...` pra `9e8d81d8...`, `.ptm` migrou
pra `patches_queue/applied/`, `appserver-core` subiu limpo com o RPO novo, sem erro. O `.ptm` de
203 MB do pacote `EXPEDICAO_CONTINUA` (mencionado acima) continua disponível sem uso, se algum
dia servir de teste em escala ainda maior.

**Atualização de binários TOTVS — em andamento** (mesmo dia, depois da Fase E fechada). Dois
prompts reutilizáveis criados em `docs/prompts/`, pensados pra colar sem editar (autodescobrem
o artefato pela raiz do repo via mtime + glob do Dockerfile, não por um caminho digitado):
- `atualizar-versao-binario-totvs.md` — roda dentro de cada `docker-protheus-*`.
- `atualizar-tags-compose.md` — roda depois, dentro do `docker-protheus-devops-stack`, sincroniza
  o `docker-compose.yaml` com o que os repos irmãos já publicaram.

**3 de 5 repos já atualizados e publicados no Docker Hub** (confirmado via
`docker manifest inspect`): `license-dev` 3.7.1→**3.7.2**, `appserver-dev` 24.3.1.5→**24.3.1.9**,
`appserver-dev-worker` 24.3.1.5→**24.3.1.9**. Faltam `dbaccess-dev` e `webapp-dev`/`printer-dev`
(usuário ainda não rodou o prompt nesses). `docker-compose.yaml` **ainda não foi atualizado** —
continua nas versões antigas em todas as ocorrências (confirmado, `grep -n
"image: rodrigomicrosiga"`). `webagent` segue fora de escopo (componente novo, sem repo).

**Achado novo**: o pacote de `includes.zip` (advpl/tlpp, necessário pro `compile`) **não tem
repo nenhum e não tem seed image** — diferente de RPO/system/systemload (que têm
`docker-protheus-{rpo,system,systemload}` dedicados). É `*.zip` no `.gitignore` do
`docker-protheus-devops-stack` sob "TRAVA DE GOVERNANÇA" (mesmo tratamento de `.rpo`/`.ptm`,
nunca vai pro git), e os arquivos que existem em `protheus/includes/{advpl,tlpp}/` datam de
jun/jul de 2026 — nunca foram versionados nem re-obtidos desde então, e a origem exata (SDK do
TDN? instalador do AppServer? outro pacote?) não está documentada em lugar nenhum. Registrado
como item novo do backlog (ver abaixo) — pergunta em aberto pro usuário.

**Próximo passo definido no fim desta sessão (17/09)**: retomar o item 0 pelo lado k8s depois de
resolver o boot — executado e fechado na sessão seguinte (18/09, ver "Onde paramos" no topo).

## Backlog aberto, por prioridade

1. **`docker-protheus-includes` — implementado E validado em 2026-09-18**: repo criado
   (`github.com/rodrigomicrosiga-devops/docker-protheus-includes`, privado), CI publicou
   `protheus-includes-dev:0.0.1` no Docker Hub, cluster alterado (`appserver-compile-job.yaml`)
   e validado ao vivo com `run-job.sh compile` (duas execuções, `initContainer seed-includes`
   entregou os zips corretamente nas duas, `code_compiler.sh` extraiu e resolveu `#include`
   sem erro). Ver "Onde paramos" no topo e ADR 0010 pro desenho completo (seed efêmero via
   `initContainer` + `emptyDir`, não Deployment em standby). Pendências residuais, menores:
   - Nenhum `compile` real terminou com `Errors(0)` ainda — o fonte de teste usado colidia com
     uma função já existente no `custom.rpo` (`U_TESTE`, de uma compilação de 17/09), rejeição
     correta do compilador, não falha do include. Resolve sozinho no próximo `compile` com fonte
     sem colisão de nome — não é uma pendência de infraestrutura.
   - **`advpl`**: revisão nova já identificada e baixada (`~/Downloads/26-08-07-P12_INCLUDES.ZIP`,
     157 arquivos vs. 155 em uso) — decisão de aplicar ou não fica pro usuário, procedimento
     documentado no README do repo novo.
   - **`tlpp`**: origem do pacote TOTVS **continua não identificada** — os 6 `tlpp-*.th` em uso
     são idênticos byte-a-byte aos de `/media/rodrigo/dados/totvs/protheus/2410/includes/`
     (instalação local antiga do Protheus 24.10, não um zip baixável), mas isso é só de onde
     foram copiados, não a origem TOTVS. Não é o mesmo pacote do `advpl` (que tem `.th` também,
     só que prefixados `fw-tlpp-*`, schema diferente). Busca por zip/pacote com "TLPP"/"SDK" no
     nome em `~/Downloads`, `documentos/` e nas extensões do VS Code (TDS) não achou nada.
2. **Segurança — fechado em 2026-09-18**: `base/postgres-secret.env` (plaintext do
   `postgres-secret` selado) passou a ter backup cifrado com GPG simétrico
   (`base/postgres-secret.env.gpg`, versionado) em vez de existir só como arquivo puro sem
   backup no disco. `scripts/secrets/encrypt.sh`/`decrypt.sh` (genéricos, reusáveis pra outros
   segredos), passphrase gerada e entregue só ao usuário (guardada no gerenciador de senhas
   dele, nunca no repositório). Rotação de senha descartada como escopo deste item — mudaria
   Compose e k8s juntos (mesma senha nos dois, por decisão deliberada), reabrindo a
   padronização de 16/09 sem motivo novo. Detalhe completo em
   `docs/adr/0011-cofre-local-gpg-secrets-plaintext.md`.
3. **DR incompleto**: 3 PVs (`postgres-pv`, `webapp-shared-pv`, `printer-shared-pv`) têm
   `nodeAffinity` aplicada fora do git (campo imutável em PV já existente) — um cluster
   recriado do zero a partir deste repo perde essa afinidade. Ver
   `docs/adr/0004-pv-nodeaffinity-imutavel.md`. Ligado ao item 4: mesmo se a receita de
   `docker run` dos nodes for usada, ela não recria PV/PVC do zero.
4. **Ainda sem receita para recriar o cluster do zero** (rede Docker + volumes nomeados
   novos) — só existe receita para recriar o *container* de um node já existente em cima de
   volumes que já existem (`scripts/k3d-nodes/`, fechado em 2026-09-17, ver ADR 0008). Um
   cluster perdido por inteiro (rede + todos os volumes) ainda exigiria reconstrução manual,
   perdendo a chave do `sealed-secrets` e os namespaces fora do git (`argocd`, `falco`,
   `monitoring`, `velero`). README documenta um DR que hoje não cobre esse caso.
5. **Mapeamento inerte da porta `7890` no `serverlb`** (k3d) — não usado por nada (acesso real ao
   dbaccess do cluster é via `kubectl port-forward`). Deixou de colidir na prática desde
   2026-09-18 (parte 2): o `dbaccess` do Compose passou a publicar em `7891` no host, então os
   dois lados nunca mais disputam a mesma porta. Sem urgência agora — segue desejável remover o
   mapeamento morto da receita do LB quando ela for versionada, só por limpeza.
6. **`webagent` (SmartClient Web-Agent) — componente novo, sem repo `docker-protheus-webagent`**:
   fora de escopo tanto do Compose quanto deste cluster até hoje — é o componente que faltaria
   pra expor o SmartClient via navegador (HTML5) sem instalação local, hoje só validado via
   SmartClient desktop nativo (`CORE_PORT_MULTI`). Artefato já baixado
   (`~/Downloads/26-07-02-P12_SMARTCLIENT_WEB-AGENT_1.1.1_LINUX_X64.TAR.GZ`) desde 02/07, sem
   nenhum trabalho de containerização começado — diferente dos outros itens do backlog, este não
   é atualização de um repo existente: precisa de `docker-protheus-webagent` do zero
   (Dockerfile/entrypoint novos, decisão de porta/exposição, CI própria, mesmo padrão dos outros
   ~13 repos `docker-protheus-*`), só depois integração no `docker-compose.yaml` e em
   `base/`/`argocd/image-updater.yaml` deste repo. Não bloqueia nada hoje. Prioridade e decisão
   de fazer ficam com o usuário.

## Regras operacionais já validadas (não reabrir sem motivo novo)

- **Sequência de bootstrap manual do AppServer** — ver `CLAUDE.md`. É a regra mais cara do
  projeto: violá-la poluiu o banco com 17 tabelas indevidas (`env_*`/`sys_*`/`top_*`) em
  2026-07-30, exigindo wipe completo. Vale tanto para o Compose quanto pro cluster k8s.
- **Nunca fazer DDL/wipe/rename de banco com o `dbaccess` (ou qualquer client TOP) ativo** —
  ele mantém cache de metadados em memória, fica dessincronizado da realidade física do banco.
  Sintoma real já visto: `TOP Error -19 - Unable to Unregister Fields`. Sequência correta:
  parar `core` → parar `dbaccess` → alterar o banco → religar `dbaccess` → religar `core`. Ver
  `docs/adr/0006-wipe-banco-com-dbaccess-parado.md`. No cluster, "parar" = `replicas: 0` via git
  (não `kubectl scale` direto — o Argo CD tem `selfHeal: true` e desfaz sozinho; editar o
  manifesto e deixar sincronizar é o caminho que não briga com o controller).
- **`ALTER USER ... RENAME` não funciona na própria sessão** (`session user cannot be renamed`)
  — precisa de uma segunda role (mesmo que temporária, criada só pra isso e derrubada depois)
  conectada para renomear a role em uso.
- **`command:` no container spec do Kubernetes substitui o ENTRYPOINT da imagem inteiro** —
  diferente do `docker-compose`, onde `command:` vira só o CMD (argumento do ENTRYPOINT). Usar
  `args:` para passar o papel (`core`/`rest`/`telnet`) sem descartar o `entrypoint.sh`. Bug real
  encontrado e corrigido nos 3 manifestos do AppServer em 2026-09-16.
- **hostPath é node-local** — sempre validar por dentro do node k3d
  (`docker exec k3d-protheus-cluster-agent-0 ...`). Desde 2026-09-17 (ADR 0008) o `agent-0` tem
  bind mount real de `/media/rodrigo/dados/k8s-volume` — o caminho físico do host agora reflete
  o node, mas siga validando por dentro do container por hábito (o `server-0` continua sem
  nenhum bind mount desse caminho).
- **Recriar um container de node k3d (`docker rm` + `docker run`) exige apagar o Secret de senha
  do node antes** — `kubectl delete secret -n kube-system <nome-do-node>.node-password.k3s`. A
  senha de registro é gerada aleatoriamente a cada `docker run` e só é aceita se esse Secret não
  existir ainda; sem apagar, o node trava em `NotReady` com "Node password rejected, duplicate
  hostname" para sempre. `docker restart`/`docker stop`+`docker start` do **mesmo** container não
  precisa disso (reaproveita a mesma senha). Ver ADR 0008.
- **Nodes k3d neste host precisam de `--cgroupns host`, não `--cgroupns private`** — com
  `private` (usado pelos nodes originais desde julho) o kubelet trava num crashloop
  (`cannot enter cgroupv2 "kubepods" with domain controllers -- it is in an invalid state`)
  contra o driver `systemd` de cgroup do Docker deste host. Os dois nodes (`agent-0`, `server-0`)
  foram recriados com `--cgroupns host` em 2026-09-17 — manter esse valor em qualquer recriação
  futura. Ver ADR 0008.
- **Preferir sync do Argo CD a `kubectl apply -k` direto** em recursos já geridos pela
  Application — em 2026-07-28 um apply direto reverteu digests do Image Updater para tags
  flutuantes do git e causou restart em massa (autocorrigido depois, mas evitável).
- **Bump de versão de imagem: editar `base/*.yaml` sozinho não move nada no cluster** — a
  `Application` usa `writeBackConfig: method: argocd`, então o Image Updater grava o digest
  resolvido como override em `spec.source.kustomize.images`, e esse override vence o manifesto
  do git enquanto a tag nova não for resolvida de novo. Fluxo correto (confirmado em
  2026-09-18): editar `base/*.yaml` **e** o alias correspondente em `argocd/image-updater.yaml`,
  commit+push, depois `kubectl apply -f argocd/image-updater.yaml` pra forçar o Image Updater a
  reconciliar contra a tag nova — só aí o override é reescrito e o Argo CD sincroniza de fato.
- **Hooks Argo CD (`PreSync` etc.) re-rodam a cada sync**, não só quando o spec do hook muda —
  desenhar hooks idempotentes (já é o caso do `smartview-db-init-job`, confirmado de novo hoje:
  rodou uma segunda vez sozinho após a mudança de credencial, sem efeito colateral).
- **`nodeAffinity` de PV já existente é imutável** — nunca tentar retrofit via patch; se o valor
  já bate e a anotação `last-applied-configuration` já reflete isso, não redeclarar no git.
- **O classificador de segurança do Claude Code bloqueia, mesmo isolados**: qualquer
  `ALTER USER`/`ALTER DATABASE` ("Irreversível Local Destruction"), criação de credencial/role
  (`CREATE USER ... PASSWORD`, "Secret-Store Writes"), leitura do valor de um Secret já aplicado
  (`kubectl get secret -o jsonpath=... | base64 -d`, "Credential Materialization"), e patch que
  remove `syncPolicy.automated` de uma Application ("Modify Shared Resources"). Nada disso é
  contornável nem deveria ser — o caminho é sempre preparar o comando exato e pedir pro usuário
  rodar via `!`.
- **`docker stop` só grava a flag de parada manual (que faz `unless-stopped` respeitar) se o
  container estiver `Up` no momento** — num container já parado por falha, é no-op silencioso: a
  policy segue correta no `docker inspect`, mas ele volta sozinho no próximo boot do daemon
  mesmo assim. Achado real em 2026-09-18 (parte 2): o `protheus_dbaccess` tinha morrido por uma
  colisão de porta (17/09) antes do `docker stop` da sessão de 17/09 rodar nele — o stop não teve
  efeito porque ele já estava `Exited`, e ele voltou sozinho no boot seguinte. Fix: `docker stop`
  precisa rodar com o container **rodando** para valer; se ele já está parado, não há nada a
  fazer (já está no estado desejado, só a flag interna é que não foi gravada).
- **Log do AppServer (`appserver_core.log` etc.) é pré-alocado com padding de bytes nulos** — o
  conteúdo real fica intercalado com `\0`, não é texto sequencial puro. `tail`/`grep` direto no
  arquivo retorna majoritariamente padding e pode estourar limites de captura de output. Ler com
  `tr -d '\000' < arquivo | tail -c N` (descarta os nulos antes de cortar pelo fim). `docker logs`
  do container não ajuda aqui — o entrypoint não propaga a saída do `appsrvlinux` pro stdout do
  container além do banner inicial (OS/memory/container info); o log real está sempre no arquivo.

## Convenção de nomenclatura (fechada em 2026-09-16)

Banco, usuário e `ENV_NAME` = **`protheus`** por default, idêntico no Compose e no cluster k8s.
Senha default `ProtheusPwd2026` (sem `;`, `=` ou aspas — vai sem escaping pra `ConnectionString`
do `dbaccess.ini`). Antes disso havia drift real (não intencional): Compose usava
`totvs`/`totvs`/`protheus_dev`, cluster usava `protheus`/`totvs`/`protheus_dev`. Corrigido nos
dois via `ALTER USER ... RENAME` + `ALTER DATABASE ... RENAME` (preserva dados, não foi wipe) e
atualização de `.env.postgres`/`.env.protheus` (Compose) e `postgres.env`/`appserver-core.yaml`/
`smartview-db-init-job.yaml` (cluster). Só muda se o dev realmente configurar diferente — não
reabrir sem motivo novo.

## Histórico condensado da sessão de 2026-09-16 (retomada após 6 semanas)

**Handoff recuperado** (ver acima) e blindado: `CLAUDE.md` + `docs/HANDOFF.md` + `docs/adr/`
versionados no repo; memória do Claude Code migrada para o diretório correto do projeto
(`~/.claude/projects/-media-rodrigo-dados-k8s-protheus-devops-stack/memory/`), tratada como
cache/ponteiro, não como fonte.

**Crashloop do `protheus_core` (Compose)**: 1123 restarts, `[FATAL][MPPORT] FAILURE TO START
REST SERVER` / `Thread Pool: 'MAIN|SD|HTTP' - Slaves must have value`. Memória e CPU/cgroup
testadas e descartadas como causa. Causa raiz real: banco `protheus_dev` ainda no estado
poluído de 30/07 (17 tabelas indevidas, wipe planejado nunca tinha acontecido). Confirmado
apontando um container efêmero pra um banco vazio (HTTP subiu limpo lá). Fix: wipe real
(`DROP`/`CREATE DATABASE`). Um segundo bug real apareceu no caminho: o `DROP DATABASE` foi feito
com `dbaccess` ativo, cache dele dessincronizou (`TOP Error -19`) — motivou o ADR 0006.

**Fase C no k3d**: corrigida uma suposição errada (o cluster já tinha 50 dias de componentes
rodando, não estava do zero). Adicionados os 3 Deployments de seed em `protheus-seed.yaml`,
`appserver-core.yaml` registrado no `kustomization.yaml`, stub morto `appserver.yaml` removido.
Dois bugs reais encontrados e corrigidos: `command:` vs `args:` nos manifestos do AppServer
(Kubernetes substitui o ENTRYPOINT inteiro, diferente do compose); e o risco de persistência do
ADR 0007 (hostPaths sem bind mount real, descoberto ao investigar por que os diretórios do seed
"não existiam" — na verdade eu estava olhando o caminho físico errado, a regra do próprio
`CLAUDE.md`). RPO seedado com hash idêntico ao pristino conhecido.

**Padronização de nomenclatura** (ver seção dedicada acima): drift `totvs`/`protheus_dev`
identificado pelo usuário e corrigido nos dois ambientes, com uma dança de "parar dbaccess
antes" em ambos (no cluster, via `replicas: 0` temporário no git — não `kubectl scale`, porque
o Argo CD `selfHeal` desfaz).

Dois fixes de 30/07 que estavam pendentes há 6 semanas também foram commitados
(`docker-protheus-devops-stack`): `UPD_EMPRESAS` com aspas duplicadas gerando JSON inválido;
`run.sh` com `stop ... rm -f` sem `&&` (container nunca era removido de verdade).

## Histórico condensado (sessões 2026-07-26 a 2026-07-31)

Fleet-wide (Fases 3.1–3.5, `/media/rodrigo/dados/docker-protheus-*` + este repo): GitOps
control-plane fechado, CI padronizada em 9 repos, tradeoffs de privilégio decididos e testados
(`license`/`/dev/mem`, `smartview`/systemd), rename `postgres`→`postgres-dev`, `Recreate`
strategy em singletons hostPath, migração non-root (exceto `license`/`smartview`, motivo
documentado), probes/healthchecks completos, fix real de `init-protheus.sh` validado com drill
de disaster-recovery ao vivo. CI da frota inteira ficou silenciosamente quebrada por dias
(credential store do Docker Desktop) — encontrado e corrigido, runner hardenizado.

SmartView onboardado (2 bugs reais corrigidos: deadlock de ordenação do hook PreSync;
`totvs`/`protheus` inexistentes no Postgres pré-existente) e validado com drill de DR real.

AppServer (Fases A/B/C, a partir de 2026-07-28): 3 imagens seed decididas (RPO como semente
única nunca reprovisionada; system/systemload reprovisionam por release+revisão). Fase A/B
(seeds + PVs/regcred) fechadas — `regcred.sealed.yaml` versionado desde commit `89cea9e`. Fase C
rascunhada e validada localmente contra o Compose em julho, mas só aplicada de fato ao cluster
em 2026-09-16 (ver acima).

2026-07-29: rede de segurança real do worker portada e validada com patch real (671MB de RPO,
`sha256sum` idêntico após rollback de falha simulada). Bug real corrigido: `compile` nunca teve
caminho de sucesso funcional. Código morto removido de `docker-protheus-appserver`.

Detalhe fase a fase, mais extenso, ainda disponível na memória do Claude Code
(transcripts antigos em `~/.claude/projects/-home-rodrigo/`) caso precise do contexto fino de
uma decisão específica — não deveria ser necessário pro fluxo normal de trabalho.
