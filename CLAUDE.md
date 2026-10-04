# k8s-protheus-devops-stack — orientação para trabalhar neste repo

Objetivo do projeto: rodar toda a stack Protheus (TOTVS) em Kubernetes via GitOps (Argo CD),
partindo de uma stack Docker Compose já validada. É um projeto pessoal usado como veículo da
transição de carreira do usuário para DevOps — favoreça explicar o *porquê* das decisões, não só
executar.

**Estado vivo do trabalho**: [`docs/HANDOFF.md`](docs/HANDOFF.md) — leia antes de continuar
qualquer coisa. Decisões arquiteturais validadas estão em [`docs/adr/`](docs/adr/).

## Mapa do ecossistema

- **Este repo** (`k8s-protheus-devops-stack`): destino Kubernetes/Kustomize/Argo CD. Kustomize
  em `base/` (sem `overlays/` ainda), Argo CD Application em `argocd/`.
- **`/media/rodrigo/dados/docker-protheus-devops-stack`**: stack Docker Compose de referência —
  é a **fonte da verdade funcional**, já validada. `run.sh` orquestra; `docker-compose.yaml` tem
  a topologia completa (Postgres/MSSQL/Oracle, dbaccess, license, appserver core/rest/telnet/
  worker/compiler/upddistr, webapp, printer, smartview).
- **`/media/rodrigo/dados/docker-protheus-*`** (~14 repos): um repo por imagem publicada no
  Docker Hub (`rodrigomicrosiga/<nome>-dev`), cada um com seu próprio CI.
- **`/media/rodrigo/dados/totvs-protheus-modern-devops`**: predecessor monolítico, histórico,
  desatualizado — não usar como referência de estado atual.
- **`/media/rodrigo/dados/protheus-manager-api`** (Go) e **`/media/rodrigo/dados/protheus-manager-web`**
  (nginx + página estática): o *Protheus Manager*, repos próprios (privados no GitHub, org
  `rodrigomicrosiga-devops`). A API opera o cluster (ver ADRs 0019/0020/0021 aqui); manifestos ficam
  **neste** repo (`base/protheus-manager*.yaml`). Swagger `http://127.0.0.1:8800/docs`, tela
  `http://127.0.0.1:8801`. O token da API fica em `base/manager-secret.env` (local, gitignored,
  `chmod 600`) — **nunca imprimir**; carregar com `grep`/`cut` direto numa variável.

## Caminhos de dados — não confundir

- **`/media/rodrigo/dados/k8s-volume/`** — hostPath real usado pelos PVs deste repo no cluster
  k3d. É node-local: sempre valide o conteúdo por dentro do node
  (`docker exec k3d-protheus-cluster-agent-0 ls -la <path>`), nunca pelo caminho físico do host.
- **`/media/rodrigo/dados/volume/`** — **legado**, do repo antigo `docker_protheus`. Não usar.
- **`docker-protheus-devops-stack/protheus/`** — binds do Compose local (`apo/`, `system/`,
  `systemload/`, `patches/`, `includes/`). `apo/tttm120.rpo` é o único artefato sem regeneração
  automática no Compose — se corrompido, reprovisionar da imagem seed
  `rodrigomicrosiga/protheus-rpo-dev:12.1.2510` (hash pristino conhecido: `568f185e...`,
  671548215 bytes).
- **`/media/rodrigo/dados/protheus-artifacts/`** — `.ptm` (patches) reais do ambiente, fora do
  git e fora dos volumes Docker.

## Regra dura: bootstrap manual do AppServer

Numa base genuinamente nova (banco vazio), `UPDDISTR`/`worker`/`compile` **nunca** rodam antes
do usuário concluir o bootstrap manual. Violar isso já poluiu o banco com 17 tabelas indevidas
em 2026-07-30 (detalhe completo em `docs/HANDOFF.md`). Sequência obrigatória:

1. Assim que o `core` sobe pela primeira vez contra um banco vazio, **avisar o usuário
   imediatamente** — não prosseguir sozinho.
2. Usuário valida banco, dbaccess, dbaccess×banco (cada validação é dele, não substituível).
3. Usuário abre a URL do SmartClient (`http://127.0.0.1:<CORE_PORT_MULTI>/` no cluster k8s desde
   o ADR 0017; `http://<host>:<CORE_PORT_MULTI>/` no Compose local) e define usuário/senha inicial.
4. Só então o próprio Protheus cria as tabelas `SYS_*`, e só então UPDDISTR/worker/compile podem
   rodar.

Não deixe `core` passar por múltiplos ciclos de boot/restart antes do passo 4 — isso é o que
causou a poluição de 30/07.

## Convenções padronizadas (2026-09-16)

- **Nome do banco, usuário e ambiente**: `protheus`/`protheus`/`protheus` por default, nos dois
  ambientes (Compose local e cluster k8s). Isso **não era o caso antes** — o Compose usava
  `totvs`/`totvs`/`protheus_dev` (drift acidental, não decisão deliberada) enquanto o cluster já
  usava `protheus`/`totvs`/`protheus_dev` (banco certo, usuário e `ENV_NAME` errados). Corrigido
  para ficar idêntico nos dois. Senha default: `ProtheusPwd2026`. Só muda se o dev realmente
  configurar diferente — não reabrir essa padronização sem motivo novo.
- **Restrição de senha**: não usar `;`, `=` nem aspas — o entrypoint do `dbaccess` injeta a
  senha sem escaping numa `ConnectionString` delimitada por `;` (via `sed`) no `dbaccess.ini`.
- Escopo de banco no cluster: **só Postgres**. MSSQL/Oracle ficam exclusivos do Compose local
  (decisão registrada em `docs/adr/`).

## Regras que valem sempre ao mexer no manager e no cluster

- **Confira o artefato real, não o status.** Depois de subir ou trocar um workload, olhe o `imageID`
  (digest) do pod e a versão no `/health`; o Image Updater casa o override pelo **nome** da imagem e já
  trocou uma prévia pela imagem de produção. Fakes e ambiente local já mentiram 5 vezes (ver os ADRs 0019, 0020 e 0021).
- **Não religue o que o usuário parou.** `appserver-rest`/`appserver-telnet` podem estar com 0 réplicas
  de propósito (a auditoria da API diz quem e quando). Pergunte antes de `start`.
- **Mudança de contrato da API começa no `openapi/openapi.json`** (repo da API) e passa na régua
  `scripts/contract-check.sh` antes de trocar a imagem de produção.

## Commits

Sem trailer `Co-Authored-By`/atribuição de IA — commits devem parecer inteiramente do usuário.
