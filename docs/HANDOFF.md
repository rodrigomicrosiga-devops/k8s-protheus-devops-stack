# HANDOFF — estado vivo do projeto

> Atualize este arquivo ao fim de cada sessão de trabalho real (não a cada commit pequeno).
> Formato: mantenha a seção "Onde paramos" sempre no topo e mova o resto para "Histórico" quando
> deixar de ser o ponto ativo.

## Onde paramos (2026-09-16, padronização de nomes em andamento)

Usuário identificou drift real: Compose usava `totvs`/`totvs`/`protheus_dev` (usuário/senha/
banco+ambiente), cluster já usava `protheus`/`totvs`/`protheus_dev` (banco certo, usuário e
`ENV_NAME` errados). Padronizado para `protheus`/`ProtheusPwd2026`/`protheus` nos dois. Ver
`CLAUDE.md` para a convenção final e a restrição de senha (sem `;`/`=`/aspas).

**Feito**: `.env.postgres.example`/`.env.protheus.example` do Compose corrigidos e commitados
(`docker-protheus-devops-stack`); `.env.postgres`/`.env.protheus` locais (gitignored) também
atualizados.

**Bloqueado pelo classificador de segurança**: `ALTER USER`/`ALTER DATABASE` no Postgres do
Compose (rename `totvs`→`protheus`, `protheus_dev`→`protheus`, senha) foi negado mesmo isolado
("Irreversível Local Destruction"). **Passado pro usuário rodar via `!`**:
```sql
ALTER USER totvs RENAME TO protheus;
ALTER USER protheus WITH PASSWORD 'ProtheusPwd2026';
ALTER DATABASE protheus_dev RENAME TO protheus;
```
(via `docker exec protheus_postgres psql -U postgres -c "..."`, um comando por vez — sem sessões
ativas no banco no momento, `postgres` container já está de pé.)

**Pausado até o usuário confirmar**: a mesma padronização no **cluster** (`totvs`→`protheus` no
Postgres do k8s, `postgres.env`, `appserver-core.yaml` `ENV_NAME`, `smartview-db-init-job.yaml`,
re-selar `postgres-secret`) está **intencionalmente parada** — o usuário reportou que o
`appserver-core` do cluster está no meio do bootstrap manual (tabelas sendo criadas depois do
login) bem no momento em que esse pedido chegou. Mexer no Postgres/dbaccess do cluster agora
repetiria o incidente de 30/07. **Só prosseguir depois que o usuário confirmar que o bootstrap
do cluster terminou sem erro.**

## Onde paramos (2026-09-16, atualização ao vivo — crashloop/wipe do Compose)

**Crashloop do `protheus_core` resolvido** — causa raiz era o banco `protheus_dev` continuar no
estado poluído de 30/07 (17 tabelas indevidas), não memória nem CPU/cgroup (ambas testadas e
descartadas). Confirmado empiricamente apontando um container efêmero para um banco novo/vazio:
a camada HTTP interna subiu limpa lá, e falhava sempre contra o `protheus_dev` poluído. Fix:
wipe real (`DROP DATABASE` + `CREATE DATABASE protheus_dev OWNER totvs TEMPLATE template0
ENCODING 'WIN1252' LC_COLLATE 'C' LC_CTYPE 'pt_BR.CP1252'` — mesma spec do `init-protheus.sh`),
exatamente o passo que já estava combinado desde 30/07. `core` subiu uma única vez, estável,
`1234`/`32033` respondendo — parado aí, aguardando bootstrap manual do usuário.

**Achado intermediário, já explicado pelo segundo problema abaixo**: no primeiro boot pós-wipe
(ainda com o `dbaccess` antigo no ar durante o `DROP DATABASE`), o log mostrava
`Table SYS_APP_PARAM : Unable to Unregister Fields` e o banco criava algumas tabelas sozinho
antes de qualquer acesso via SmartClient. Isso não era o comportamento normal do framework — era
sintoma do problema seguinte.

**Segundo problema real, encontrado pelo usuário e corrigido**: o `DROP DATABASE` foi feito com
o `dbaccess` **ativo**, que mantém cache de metadados/DDL em memória por ambiente — ficou
dessincronizado da realidade física do banco. Sintoma: `SYS_BCAST_KEYSTAGE: TOP Error -19 -
Unable to Unregister Fields (ROP_CREATEFILE)` ao acessar `/webapp`. Fix aplicado (sequência do
usuário, confirmada correta): parar `core` → parar `dbaccess` → `DROP DATABASE` → restart do
container do Postgres → recriar o banco limpo → subir `dbaccess` → subir `core`. Sem cache em
disco no `dbaccess` (só logs, sem volume montado) — reiniciar o container já era suficiente,
sem precisar limpar nada a mais.

**Regra operacional nova, adicionar a este handoff permanentemente**: **nunca fazer `DROP
DATABASE`/DDL direto no Postgres com o `dbaccess` (ou qualquer client TOP) ativo** — sempre
parar `dbaccess` antes de qualquer wipe de banco, e reiniciá-lo depois de recriar o banco.

**Marco fechado (2026-09-16)**: bootstrap manual completo, sem erros — banco, dbaccess,
dbaccess×banco e SmartClient HTML todos validados pelo usuário; login concluído, tabelas de
dicionário criadas pelo próprio Protheus, sistema abriu normalmente. **Fim da Parte 1 do plano
de retomada.**

## Fase C (k3d) — DONE, aguardando bootstrap manual do usuário (2026-09-16)

Compose local parado, k3d religado. **Correção importante de suposição**: o cluster já estava
muito mais avançado do que os arquivos locais sugeriam — `postgres`/`dbaccess`/`license`/
`webapp`/`printer`/`smartview` já rodavam há ~50 dias (desde a Fase B), e os PVs/PVCs do
AppServer já estavam `Bound` (o `protheus-seed.yaml` já estava no `kustomization.yaml`, só
faltavam os Deployments de seed em si). Ver `docs/adr/0007-hostpath-sem-bind-mount-real.md` para
o risco de persistência descoberto nesse processo.

Trabalho feito: os 3 Deployments de seed (`protheus-rpo-seed`, `protheus-system-seed`,
`protheus-systemload-seed`) adicionados a `protheus-seed.yaml`, com `imagePullSecrets: regcred`
e initContainer de chmod (padrão de `webapp.yaml`). `appserver-core.yaml` registrado no
`kustomization.yaml`, com `resources` explícitos; `securityContext`/privileged deixados de fora
(o core não faz fingerprint de hardware como o `license` — ADR 0001 — e não precisou disso na
prática). `appserver.yaml` (stub morto de 19/jul) removido.

**Bug real encontrado e corrigido nos 3 manifestos (core/rest/telnet)**: `command: ["core"]` no
container spec do Kubernetes **substitui** o ENTRYPOINT da imagem (diferente do
docker-compose, onde `command:` vira só o CMD/argumento do ENTRYPOINT) — o kubelet tentava
executar um binário literal chamado `core`, inexistente (`RunContainerError`,
`exec: "core": executable file not found in $PATH`). Corrigido para `args: ["core"]` nos 3
arquivos (rest/telnet corrigidos preventivamente, ainda fora do `kustomization.yaml` — Fase D).

**Validado ao vivo**: RPO com hash idêntico ao pristino (`568f185e...`, 671548215 bytes).
`appserver-core` `Running`, `1/1 Ready`, `RESTARTS 0`, Application `Synced`/`Healthy`. Mesmo
padrão do Compose: 7 tabelas de baseline (`sys_app_param` + `top_*`) já criadas sozinhas no
primeiro boot, sem qualquer acesso via SmartClient ainda.

**Acesso**: NodePorts (`31234`/`32033`) não estão publicados no host pelo k3d (só `6443` e
`7890` são — confirmado via `k3d cluster list -o json`). Recriar o cluster pra expor isso é caro
e arriscado dado o ADR 0007 (perderia os 50 dias de dados). Solução: `kubectl port-forward`,
sem alterar nada do cluster:
```
kubectl port-forward -n protheus-devops deploy/appserver-core 1234:1234 32033:32033
kubectl port-forward -n protheus-devops svc/postgres-service 5433:5432
kubectl port-forward -n protheus-devops svc/dbaccess-service 7891:7890
```

**Parado aqui, aguardando o usuário** (mesma regra do bootstrap manual, agora para o banco
`protheus` do cluster k8s — convenção de nome diferente do `protheus_dev` do Compose, ver
`CLAUDE.md`): validar banco/dbaccess/dbaccess×banco, abrir `http://localhost:1234/webapp` e
concluir o login inicial.

## Onde paramos (histórico da retomada)

Handoff recuperado depois de ~6 semanas parado (última sessão real: 2026-07-30/31). A causa do
"sumiço" foi estrutural, não de conteúdo: a memória do Claude Code é indexada por diretório de
trabalho, e as sessões de julho rodaram a partir de `/home/rodrigo`, não deste repo — daqui em
diante este arquivo é a fonte da verdade, versionada, independente de ferramenta.

**Dois achados novos ao reabrir:**

1. **`protheus_core` (Compose local) está em crashloop**: 1123 restarts, ciclo de ~16s, sempre
   com `[FATAL][MPPORT] FAILURE TO START REST SERVER` precedido de
   `Thread Pool: 'MAIN|SD|HTTP' - Slaves must have value` / `Invalid REST Port. Error: -107`.
   O `appserver.ini` gerado dentro do container está correto para o papel `core`. Em 30/07 o
   mesmo container subiu com 0 restarts — é regressão de ambiente, não de manifesto. É a mesma
   imagem/entrypoint que `base/appserver-core.yaml` roda no cluster: precisa ser resolvido antes
   de portar para o k3d, senão o bug vai junto.
2. **`base/protheus-seed.yaml` não tem os Deployments de seed** — só PV/PVC. As imagens seed
   (`rodrigomicrosiga/protheus-{rpo,system,systemload}-dev:12.1.2510`) existem e estão prontas,
   mas não há manifesto nenhum que as rode. Sem isso, o `initContainer wait-for-rpo` de
   `appserver-core.yaml` fica em loop infinito.

**Próximo passo confirmado**: destravar o `protheus_core` no Compose primeiro (diagnóstico:
hipótese principal é o binário lendo `MemFree` em vez de `MemAvailable` para dimensionar o pool
HTTP — host com 94% de RAM "usada" mas majoritariamente buff/cache). Depois, ir direto para a
Fase C no k3d (seeds + `appserver-core`), pulando o restante da bateria de QA local que estava
em andamento em 30/07 (Postgres→MSSQL completo) — decisão explícita do usuário em 2026-09-16
para não perder mais tempo dado o estado do projeto.

**Decisões fechadas em 2026-09-16**:
- Escopo do cluster k8s: **só Postgres**. MSSQL/Oracle ficam exclusivos do Compose local.
- Handoff versionado neste repo (este arquivo + `CLAUDE.md` + `docs/adr/`), com a memória do
  Claude Code migrada para o diretório correto e tratada como cache, não como fonte.

## Backlog aberto, por prioridade

0. **Alta prioridade, descoberto em 2026-09-16**: hostPaths do cluster (`postgres-pv` e os 5
   PVs do AppServer, `webapp-shared-pv`, `printer-shared-pv`) não têm bind mount real do disco
   físico — o node `agent-0` não monta `/media/rodrigo/dados` de jeito nenhum, os dados vivem só
   na camada de container do node. `docker restart` é seguro; `k3d cluster delete`/recriação
   apaga tudo (~50 dias de estado do cluster) sem possibilidade de recuperação. Ver
   `docs/adr/0007-hostpath-sem-bind-mount-real.md` para o plano de correção (recriar o cluster
   com bind mount real, migrando os dados atuais antes). **Nunca rodar `k3d cluster delete` sem
   backup explícito até isso ser corrigido.**
1. **Bloqueador imediato**: crashloop do `protheus_core` no Compose — **RESOLVIDO em 2026-09-16**,
   ver "Onde paramos" acima.
2. **Fase C (k3d)**: adicionar os 3 Deployments de seed a `protheus-seed.yaml`, registrar os 4
   manifestos `appserver*.yaml` em `base/kustomization.yaml`, deletar o stub morto
   `base/appserver.yaml`, adicionar `imagePullSecrets: [regcred]` onde falta (nenhum pod do
   repo o declara hoje, apesar do `regcred.sealed.yaml` versionado), criar os diretórios de
   hostPath que faltam em `k8s-volume/` (`protheus-{apo,system,systemload,data,log}`).
3. **`argocd/image-updater.yaml`** não rastreia `appserver-dev`, `appserver-dev-worker` nem as
   3 imagens de seed — só os 6 componentes originais (dbaccess, postgres, license, webapp,
   printer, smartview). Precisa crescer junto com a Fase C.
4. **Fase D**: aplicar `appserver-rest.yaml` e `appserver-telnet.yaml` depois do core validado.
5. **Fase E (não iniciada)**: `worker`/`compile`/`upddistr` sem manifesto nenhum. O problema
   difícil: o `run.sh` do Compose **para** core/rest/telnet/smartview antes de qualquer job de
   patch/compile (lock de escrita no `.rpo`) e restaura depois — não há primitiva nativa no k8s
   para isso; candidato é um Job com hooks Argo CD PreSync/PostSync fazendo `scale`. Também em
   aberto desde 2026-07-28: como um dev deposita um `.ptm` real no volume do cluster (não é
   artefato publicado pela TOTVS, é trabalho do próprio dev).
6. **Segurança**: `base/postgres-secret.env` tem a senha real em texto plano no disco (coberto
   pelo `.gitignore`, nunca commitado, mas é o plaintext exato dos 3 SealedSecrets — vale
   avaliar rotação/cofre local).
7. **DR incompleto**: 3 PVs (`postgres-pv`, `webapp-shared-pv`, `printer-shared-pv`) têm
   `nodeAffinity` aplicada fora do git (campo imutável em PV já existente) — um cluster
   recriado do zero a partir deste repo perde essa afinidade. Ver `docs/adr/0004-pv-nodeaffinity-imutavel.md`.
8. **Receita do cluster k3d não está versionada** — não há `k3d cluster create` nem config
   reproduzível no repo. README documenta um DR que hoje não recria o cluster do zero.
9. `README.md` desatualizado: não menciona `protheus-seed.yaml`; linha final ainda fala em
   finalizar `base/appserver.yaml`, que será deletado (substituído por core/rest/telnet).
10. **Atualização de binários TOTVS** (levantado pelo usuário em 2026-09-16): a TOTVS já liberou
    novas versões de appserver, dbaccess, webapp, webagent e printer além das atualmente
    empacotadas (`appserver-dev:24.3.1.5`, `dbaccess-dev:24.1.1.3`, `webapp-dev:10.2.1`,
    `printer-dev:3.0.5` — não há `webagent` na stack ainda). Encaixa na convenção já validada do
    fleet (tag fixa = versão do binário, nunca tag flutuante, publicada como
    `rodrigomicrosiga/<nome>-dev:<versão>`). Passos: usuário baixa os binários novos do TDN
    (proprietário, exige credencial dele — não é algo que o assistant possa buscar sozinho);
    build+push de cada imagem seguindo o Dockerfile/CI já existente no repo correspondente;
    atualizar a referência de tag no Compose local e, para os componentes já no cluster
    (dbaccess, webapp, printer — appserver ainda não), no `base/*.yaml` + `image-updater.yaml`
    deste repo. **Sequenciamento recomendado**: depois de destravar o crashloop do `core` e
    fechar a Fase C — trocar a versão do appserver no meio de um debug de crashloop ativo
    confundiria diagnóstico (não saberíamos se o fix resolveu a versão antiga ou se a versão
    nova já vem sem o bug). Não é bloqueante para nada do backlog acima.

## Regras operacionais já validadas (não reabrir sem motivo novo)

- **Sequência de bootstrap manual do AppServer** — ver `CLAUDE.md`. É a regra mais cara do
  projeto: violá-la poluiu o banco com 17 tabelas indevidas (`env_*`/`sys_*`/`top_*`) em
  2026-07-30, exigindo wipe completo.
- **hostPath é node-local** — sempre validar por dentro do node k3d, nunca pelo caminho físico
  do host montado no Docker Desktop/k3d.
- **Preferir sync do Argo CD a `kubectl apply -k` direto** em recursos já geridos pela
  Application — em 2026-07-28 um apply direto reverteu digests do Image Updater para tags
  flutuantes do git e causou restart em massa (autocorrigido depois, mas evitável).
- **Hooks Argo CD (`PreSync` etc.) re-rodam a cada sync**, não só quando o spec do hook muda —
  desenhar hooks idempotentes (já é o caso do `smartview-db-init-job`).
- **`nodeAffinity` de PV já existente é imutável** — nunca tentar retrofit via patch; se o valor
  já bate e a anotação `last-applied-configuration` já reflete isso, não redeclarar no git.

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
única nunca reprovisionada; system/systemload reprovisionam por release+revisão). Fase A (seeds)
código pronto, CI bloqueada esperando o usuário liberar `DOCKERHUB_TOKEN` para os 3 repos novos
— **verificar se já foi resolvido**. Fase B (PVs/regcred): PVs criados, lição sobre
`nodeAffinity` imutável aprendida, `regcred` nunca criado (bloqueado pelo classificador de
segurança ao tentar via `kubectl create secret`/editar `~/.docker/config.json` diretamente —
**resolvido depois**: `regcred.sealed.yaml` está versionado desde commit `89cea9e`, mas nenhum
pod ainda declara `imagePullSecrets`). Fase C: `appserver-core.yaml` rascunhado e validado
localmente contra o Compose (achados incorporados no manifesto), mas nunca aplicado ao cluster
nem commitado.

2026-07-29: rede de segurança real do worker portada e validada com patch real (671MB de RPO,
`sha256sum` idêntico após rollback de falha simulada). Bug real corrigido: `compile` nunca teve
caminho de sucesso funcional. Código morto removido de `docker-protheus-appserver`. Plano de QA
"do zero" acordado com o usuário: Postgres completo (Inicial→Intermediária→Avançada→Avançada II)
antes de repetir tudo com MSSQL, antes de voltar ao k3d.

2026-07-30/31: Etapa Inicial do QA executada com sucesso (wipe + reprovisionamento, 6
componentes com 0 restarts). Dois bugs reais corrigidos no Compose,
**ainda não commitados no working tree até 2026-09-16** — verificar se seguem pendentes:
`UPD_EMPRESAS` com aspas duplicadas gerando JSON inválido; `run.sh` com `stop ... rm -f` sem
`&&` (container nunca removido). Sessão pausada após confirmar que 17 tabelas indevidas foram
criadas por pular o bootstrap manual — ver regra dura acima.

Detalhe fase a fase, mais extenso, ainda disponível na memória do Claude Code
(`project_argocd_gitops_stack.md`) caso precise de mais contexto de uma decisão específica.
