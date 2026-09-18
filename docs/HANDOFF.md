# HANDOFF — estado vivo do projeto

> Atualize este arquivo ao fim de cada sessão de trabalho real (não a cada commit pequeno).
> Formato: mantenha a seção "Onde paramos" sempre no topo e mova o resto para "Histórico" quando
> deixar de ser o ponto ativo.

## Onde paramos (fim da sessão de 2026-09-18)

**Verificar ao retomar amanhã, antes de qualquer coisa nova** (os 4 passos desta sessão foram
aplicados e validados ao vivo antes do encerramento, mas dependem de estado externo — máquina
pode ter sido reiniciada, cluster pode ter driftado):

1. **Boot ficou higiênico?** `docker ps -a` não deve mostrar os 6 containers do Compose
   (`protheus_core`/`postgres`/`license`/`webapp`/`printer`/`dbaccess`) rodando sozinhos — eles
   devem estar `Exited`, não `Up`, a menos que o usuário os suba deliberadamente. Se algum
   estiver `Up` sem ter sido pedido, a policy `unless-stopped` pode não ter pego (checar
   `docker inspect <nome> --format '{{.HostConfig.RestartPolicy.Name}}'`).
2. **Bump do k8s se sustentou?** `kubectl get applications -n argocd protheus-devops-stack` deve
   seguir `Synced`/`Healthy`; `kubectl get pods -n protheus-devops -o
   custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'` deve mostrar
   `appserver-dev:24.3.1.9` (core/rest/telnet) e `license-dev:3.7.2` — não voltou pra
   24.3.1.5/3.7.1. Se tiver voltado, o Image Updater pode ter re-resolvido pra outra coisa;
   investigar antes de mexer em qualquer manifesto.
3. **Pendência do Compose segue em aberto** (não é bug, é trabalho não feito ainda): containers
   locais continuam nas imagens antigas (24.3.1.5/3.7.1) mesmo com o `docker-compose.yaml` já
   apontando pra 24.3.1.9/3.7.2 desde o commit `2cfd5d8`. Só relevante quando o usuário quiser
   validar o Compose ao vivo — rodar `docs/prompts/atualizar-tags-compose.md` (passos 8–9) então.
4. **Decisão do `includes.zip` segue pendente do usuário** — pergunta em aberto no backlog (item
   1): vale criar `docker-protheus-includes` como seed image? Não perguntar de novo sem o usuário
   trazer o assunto — já está registrado, é decisão dele, não follow-up automático.

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
recriar) + `docker stop` neles. Não mexido: a receita do `serverlb` (mapeamento da `7890`
continua lá, inerte — ver backlog).

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

0. **Validação ao vivo do Compose nas tags novas** (rebaixado de "Atualização de binários TOTVS"
   — o essencial, k8s, foi fechado em 2026-09-18): `appserver-dev`/`appserver-dev-worker`
   24.3.1.9 e `license-dev` 3.7.2 já estão no `docker-compose.yaml` (commit `2cfd5d8`), mas a
   stack local nunca foi recriada com elas. Rodar `docs/prompts/atualizar-tags-compose.md`
   (passos 8–9) quando fizer sentido — não bloqueia nada no cluster.
1. **`docker-protheus-includes` (seed image) — decisão pendente do usuário**: origem do
   `includes.zip` confirmada em 2026-09-18 (pacote `P12_INCLUDES.ZIP` do portal TOTVS pro
   `advpl`; `tlpp` ainda sem origem identificada). Falta decidir se vale criar o repo seguindo o
   padrão rpo/system/systemload — e, se sim, aplicar a revisão mais nova já disponível do
   `advpl` (157 arquivos vs. 155 em uso).
2. **Segurança**: `base/postgres-secret.env` tem a senha real em texto plano no disco (coberto
   pelo `.gitignore`, nunca commitado, mas é o plaintext exato do `postgres-secret` selado —
   vale avaliar rotação/cofre local).
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
5. `README.md` desatualizado: não menciona `protheus-seed.yaml` nem a Fase C concluída, nem a
   Fase D nem a Fase E (todas fechadas em 2026-09-17); ainda fala em finalizar
   `base/appserver.yaml` (removido, substituído por core/rest/telnet). Também não menciona
   `scripts/k3d-nodes/` nem `scripts/appserver-patch/` nem `docs/prompts/` ainda.
6. **Mapeamento inerte da porta `7890` no `serverlb`** (k3d) — não usado por nada (acesso real ao
   dbaccess do cluster é via `kubectl port-forward`), mas segue colidindo com a porta do
   `dbaccess` do Compose sempre que ambos tentam subir no boot. Resolvido operacionalmente em
   2026-09-18 (cluster tem prioridade, Compose não sobe sozinho) — remover da receita do LB
   quando ela for versionada.

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
