# HANDOFF — estado vivo do projeto

> Atualize este arquivo ao fim de cada sessão de trabalho real (não a cada commit pequeno).
> Formato: mantenha a seção "Onde paramos" sempre no topo e mova o resto para "Histórico" quando
> deixar de ser o ponto ativo.

## Onde paramos (fim da sessão de 2026-09-17)

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

## Sessão de 2026-09-16

Handoff recuperado depois de ~6 semanas parado (última sessão real: 2026-07-30/31). A causa do
"sumiço" foi estrutural, não de conteúdo: a memória do Claude Code é indexada por diretório de
trabalho, e as sessões de julho rodaram a partir de `/home/rodrigo`, não deste repo — daqui em
diante este arquivo é a fonte da verdade, versionada, independente de ferramenta e de máquina.
Ver `CLAUDE.md` (carrega automaticamente nesta sessão) e `docs/adr/` para decisões arquiteturais.

**Estado final, tudo validado ao vivo hoje:**

1. **Compose local**: `protheus_core` destravado (estava em crashloop há dias). Banco recriado
   limpo, bootstrap manual completo (login + criação de dicionário) sem erro, sistema abrindo
   normalmente. Nomenclatura padronizada: banco `protheus`, role `protheus`, senha
   `ProtheusPwd2026`, `ENV_NAME=protheus`.
2. **Cluster k3d**: Fase C fechada — seeds do AppServer (RPO/system/systemload) provisionados,
   `appserver-core` rodando (`1/1 Ready`), bootstrap manual completo (login + criação de
   dicionário) sem erro, sistema abrindo normalmente. Mesma padronização de nomenclatura
   aplicada: banco `protheus`, role `protheus`, senha `ProtheusPwd2026`, `ENV_NAME=protheus`.
   `Synced`/`Healthy` no Argo CD.
3. Compose está **parado** agora (containers down, exceto quando reaberto para validação) — o
   cluster k3d é o ambiente ativo. Túneis abertos via `kubectl port-forward` (não persistem entre
   sessões, precisa reabrir): `appserver-core` (1234/32033), `postgres-service` (5433→5432),
   `dbaccess-service` (7891→7890).

**Próximo passo, em ordem** (nada bloqueado, pronto pra retomar amanhã): nenhum item de Fase
restante — a stack inteira (core/rest/telnet/worker/compile/upddistr) está no ar e validada.
Backlog agora é só dívida técnica menor (item 0 do backlog).

## Backlog aberto, por prioridade

0. **Segurança**: `base/postgres-secret.env` tem a senha real em texto plano no disco (coberto
   pelo `.gitignore`, nunca commitado, mas é o plaintext exato do `postgres-secret` selado —
   vale avaliar rotação/cofre local).
1. **DR incompleto**: 3 PVs (`postgres-pv`, `webapp-shared-pv`, `printer-shared-pv`) têm
   `nodeAffinity` aplicada fora do git (campo imutável em PV já existente) — um cluster
   recriado do zero a partir deste repo perde essa afinidade. Ver
   `docs/adr/0004-pv-nodeaffinity-imutavel.md`. Ligado ao item 2: mesmo se a receita de
   `docker run` dos nodes for usada, ela não recria PV/PVC do zero.
2. **Ainda sem receita para recriar o cluster do zero** (rede Docker + volumes nomeados
   novos) — só existe receita para recriar o *container* de um node já existente em cima de
   volumes que já existem (`scripts/k3d-nodes/`, fechado em 2026-09-17, ver ADR 0008). Um
   cluster perdido por inteiro (rede + todos os volumes) ainda exigiria reconstrução manual,
   perdendo a chave do `sealed-secrets` e os namespaces fora do git (`argocd`, `falco`,
   `monitoring`, `velero`). README documenta um DR que hoje não cobre esse caso.
3. `README.md` desatualizado: não menciona `protheus-seed.yaml` nem a Fase C concluída, nem a
   Fase D nem a Fase E (todas fechadas em 2026-09-17); ainda fala em finalizar
   `base/appserver.yaml` (removido, substituído por core/rest/telnet). Também não menciona
   `scripts/k3d-nodes/` nem `scripts/appserver-patch/` ainda.
4. **Atualização de binários TOTVS** (pedido do usuário, 2026-09-16; artefatos já baixados em
   2026-09-17): a TOTVS já liberou novas versões de appserver, dbaccess, webapp, webagent e
   printer além das atualmente empacotadas (`appserver-dev:24.3.1.5`, `dbaccess-dev:24.1.1.3`,
   `webapp-dev:10.2.1`, `printer-dev:3.0.5` — não há `webagent` na stack ainda, é componente
   novo, não atualização). Encaixa na convenção já validada do fleet (tag fixa = versão do
   binário, nunca tag flutuante). **Duas etapas, só a primeira é automática**: (a) push num
   repo `docker-protheus-*` dispara o CI (self-hosted, `on: push` em `main`/`develop`) sozinho,
   builda e publica no Docker Hub — mas a tag publicada é hardcoded no próprio
   `.github/workflows/docker-publish.yml`, precisa ser editada antes do push; (b) o Image
   Updater deste repo (`argocd/image-updater.yaml`) só rastreia digest de uma tag **fixa e já
   conhecida** — uma versão nova não chega no cluster sozinha, precisa editar `imageName:` ali
   e `image:` em `base/*.yaml` manualmente, e só daí o rastreio automático volta a valer.
   Sequência completa (por repo, depois Compose, depois k8s) e um prompt reutilizável pronto
   pra rodar em cada `docker-protheus-*`:
   `docs/prompts/atualizar-versao-binario-totvs.md`. `docker-protheus-appserver-worker`
   compartilha o mesmo `.tar.gz` do `docker-protheus-appserver` — repo e commit separados, mas
   precisa do mesmo tratamento junto. Não é bloqueante para o resto do backlog.

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
