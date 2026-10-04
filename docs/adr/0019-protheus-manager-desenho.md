# ADR 0019 — Desenho do `protheus-manager` (API + web): ações diretas no cluster, GitOps só onde o Argo CD é dono

## Status
Proposto em 2026-10-04, decisões de desenho aceitas pelo usuário na mesma sessão. **Nada foi
implementado**: nenhum repositório criado, `argocd/application.yaml` ainda sem `ignoreDifferences`.
A implementação começa pela Fase 0 abaixo.

## Contexto
O usuário quer operar o ambiente Protheus do cluster sem ficar em terminal: consultar serviços,
parar/subir, atualizar artefatos, rodar `upddistr`/`compile`/`worker`, fazer deploy, entre outras
ações. Premissa dele: **tudo o que o manager opera já tem imagem publicada no Docker Hub** (a
TOTVS não é acessada direto), então o manager nunca baixa binário de portal.

Duas tensões reais já documentadas neste repo moldam o desenho:

1. **`selfHeal: true` desfaz ação direta** (`argocd/application.yaml`). `kubectl scale` ou `k9s`
   voltam ao valor do git em segundos. Hoje `scripts/appserver-patch/lib.sh` contorna isso
   **commitando `replicas: 0` e `replicas: N` no git** a cada `worker`/`compile`/`upddistr`
   (`stop_appservers`/`restore_appservers`, `set_replicas_in_git` + `git_commit_and_push`):
   dois commits de história por execução, pushes de um script local, e dependência de credencial de
   git na máquina.
2. **O gate do bootstrap manual é a regra mais cara do projeto** (`CLAUDE.md`, incidente de
   2026-07-30). O gate atual, `check_bootstrap_done`, só exige **ao menos uma** tabela `sys_%` —
   passa com dicionário parcial (o incidente de 20/09 teve 53 de 81 tabelas base e travou o login).

A alternativa de `ignoreDifferences` em `/spec/replicas` foi levantada na sessão de 2026-10-04
(dúvida sobre parar `rest`/`telnet` pelo k9s) e ficou registrada no HANDOFF sem decisão. Esta ADR a toma.

## Decisão

### 1. Estrutura: um backend, um frontend, repositórios separados
- **`protheus-manager-api`** — único backend, com todas as ações (infra e Protheus). Swagger/
  OpenAPI gerado do código (FastAPI é a proposta; a escolha de linguagem fica para a Fase 0).
- **`protheus-manager-web`** — só interface, consome a API. Sem lógica de cluster.
- Descartado: dois backends (`-services` para status/start/stop e `-api` para operações Protheus).
  `compile`/`upddistr`/`worker` já **dependem** de parar/subir serviço; dois backends obrigariam um
  a reimplementar o outro ou a chamá-lo por HTTP.

### 2. Regra de quem muda o quê: depende de quem é dono do campo
A premissa "tudo parte de uma imagem" diz de **onde vem o artefato**, não de **quem reconcilia o
estado**. O critério é: *o Argo CD vai reverter isso?*

| Ação | Caminho | Por quê |
|---|---|---|
| Parar/subir serviço existente (`replicas`) | **Direto no cluster** | `ignoreDifferences` em `/spec/replicas` (ver 3) tira o campo da reconciliação |
| `worker` / `compile` / `upddistr` (Jobs) | **Direto no cluster** | Jobs ficam **fora** do Kustomize de propósito (`base/kustomization.yaml`); o Argo CD não os possui nem reverte |
| Backup sob demanda (Velero), `rollout restart`, sync/refresh do Argo CD | **Direto no cluster** | Não alteram nada que o git declare |
| Ler status, logs, contagem de tabelas, health | **Direto no cluster (leitura)** | — |
| Trocar versão/tag de imagem de um componente | **Decisão adiada** (Fase 3) | Altera campo que o Argo CD possui; ver "Em aberto" |
| Criar recurso novo (Deployment, Service, PV...) | **GitOps (git → Argo CD)** | É declaração de infraestrutura, não operação |

Consequência prática: a primeira versão da API **não precisa de credencial de escrita no git**.
Só a Fase 3 pode vir a precisar.

### 3. `ignoreDifferences` em `/spec/replicas` — e `RespectIgnoreDifferences=true`
Em `argocd/application.yaml`, para os Deployments operáveis pelo manager (`appserver-core`,
`appserver-rest`, `appserver-telnet`, e os demais que a API listar):

- `ignoreDifferences` em `/spec/replicas` (`group: apps`, `kind: Deployment`);
- `syncOptions: RespectIgnoreDifferences=true`.

O **segundo** item é o que costuma ficar de fora: sem ele, o `selfHeal` deixa de reverter, mas
qualquer *sync* disparado por outro motivo (um digest novo do Image Updater, um commit qualquer)
reaplica o `replicas` do git por cima e religa o que o manager parou. Aplicar as duas coisas
juntas é parte da decisão, não detalhe.

Efeito colateral aceito: `replicas` em `base/*.yaml` passa a ser **valor inicial**, não estado
desejado vivo. O git deixa de ser fonte única da verdade para esse campo (e só esse).

O `scripts/appserver-patch/lib.sh` deve ser migrado para o mesmo mecanismo (ver Fase 1): o manager
passa a pausar/restaurar via API do Kubernetes, e o script deixa de gerar commits.

### 4. Reuso, não reescrita
A lógica de `scripts/appserver-patch/run-job.sh`/`lib.sh` (pausar core/rest/telnet → aplicar Job →
veredito por arquivo → restaurar, mesmo em falha) é a especificação da esteira. A API a reimplementa
na linguagem escolhida **mantendo as decisões já provadas**: `upddistr` nunca termina sozinho e o
status do Job não é confiável (ADR 0009, o veredito é o conteúdo de `Result.json`), e a restauração
roda sempre, também em falha. As consultas de saúde seguem as já padronizadas no HANDOFF
(`Synced`/`Healthy`, 13 pods `1/1`, contagem de tabelas).

### 5. O gate do bootstrap é imposto pela API, e mais forte que o atual
- `worker`/`compile`/`upddistr` **nunca** são disparados por evento (ex.: "core subiu"): só por
  chamada explícita de uma pessoa autenticada.
- O gate da API não repete o `>= 1`. Exige a **presença de cada tabela** de uma lista de
  obrigatórias (famílias `SYS_GRP_*`, `SYS_RULES*`, `SYS_USR*`, `SYS_COMPANY*`, as que faltaram no
  incidente de 20/09). Se faltar qualquer uma, ou se a própria lista estiver ausente/vazia (falha
  fechada), a API **recusa** a ação, com a razão no corpo da resposta; não há parâmetro `force`.
  (A proposta inicial era um piso numérico de `sys_%`; a Fase 1 mostrou que seria um chute — ver
  "Fase 1 — achados".)
- O mesmo gate vale para quem rodar `run-job.sh` à mão: a Fase 1 alinha `check_bootstrap_done` ao
  novo critério, para script e API não divergirem.
- A API **não** executa o bootstrap manual nem sinaliza "pronto": validar banco, dbaccess e
  definir o usuário inicial seguem sendo passos do usuário (`CLAUDE.md`).

### 6. Segurança: mínimo viável proporcional ao ambiente
Ambiente de dev, usuário único, mas uma API que derruba o AppServer é um nível de poder diferente
de um script manual:
- **Autenticação por token** guardado como `SealedSecret` (mesmo padrão do `postgres-secret`,
  ADR 0011). OIDC/SSO fica fora da v1.
- **ServiceAccount dedicada com Role no namespace `protheus-devops`**, nunca `cluster-admin`.
  Direitos mínimos por fase (leitura; `deployments/scale`; `jobs` create/delete; `pods/exec` só se a
  leitura de tabelas exigir). Acesso ao Velero e ao Argo CD, em namespaces próprios, por Roles
  separadas e só quando a fase precisar.
- Escuta apenas em `127.0.0.1` do host, pela mesma via do ADR 0017; nada exposto na rede.
- Toda ação mutável gera um registro auditável (quem, o quê, quando, resultado). Sem trilha de
  commits no git para as ações diretas, o log da API é a única trilha — precisa persistir.
- Ações destrutivas ou de maior risco (`upddistr`, `compile`, `worker`) exigem confirmação
  explícita na requisição e pedem ao frontend um passo de confirmação na interface.

### 7. Faseamento
- **Fase 0** — decisões de implementação (linguagem, onde roda: Deployment no cluster com Image
  Updater, como o resto da frota, ou processo local), esqueleto dos dois repositórios, ADR curto
  se a escolha divergir daqui.
- **Fase 1** — **somente leitura**: status, saúde, logs (o log do AppServer vem com padding `\0`,
  descartar com `tr -d '\000'` ou equivalente antes de devolver), contagem de tabelas. Em paralelo:
  `ignoreDifferences` + `RespectIgnoreDifferences` no `Application` e migração de `lib.sh`.
- **Fase 2** — escrita de baixo risco e idempotente: scale (start/stop), `rollout restart`,
  sync/refresh do Argo CD, backup sob demanda do Velero.
- **Fase 3** — Jobs de risco (`worker`/`compile`/`upddistr`) com o gate do item 5, e a decisão da
  troca de versão de imagem.
- Cada fase termina com **validação ao vivo**, não só testes: padrão do projeto desde as ADRs 0015
  e 0016.

## Fase 0 — decisões tomadas (2026-10-04)
Esqueleto criado localmente em `/media/rodrigo/dados/protheus-manager-api` e
`/media/rodrigo/dados/protheus-manager-web` (branch `develop`, sem remoto ainda).
- **Linguagem: Python 3.12 + FastAPI.** O Swagger sai do código; não há contrato para manter à mão.
- **Roda dentro do cluster**, como Deployment, coerente com a ServiceAccount do item 6 e com o
  rastreio por Image Updater. Porta `8800` no container.
- **Imagem** `rodrigomicrosiga/protheus-manager-api-dev:0.1.0`, tag fixa como o resto da frota, com
  o label `org.opencontainers.image.revision`. CI no runner self-hosted, testes antes do build.
- **Frontend**: só placeholder. A interface começa depois da Fase 1 da API.
- Validado ao vivo: `pytest` (2 testes), servidor real respondendo `/health` e `/docs`, imagem
  construída e rodando como uid 10001. **Não publicado**: sem remoto no GitHub e sem secrets do
  Docker Hub nos repos novos.
- Ainda dependem de decisão na Fase 1: como o Deployment lê o veredito do `upddistr` (hoje
  `lib.sh` usa `docker exec` no node, que um pod não tem — provável montagem do PVC
  `protheus-systemload` somente leitura), e a porta/NodePort de exposição em `127.0.0.1`.

## Fase 1 — achados (2026-10-04, parte neste repo)
Feito e validado ao vivo: `ignoreDifferences` + `RespectIgnoreDifferences=true` no `Application`
(aplicado), `scripts/appserver-patch/lib.sh` migrado, gate novo. As rotas de leitura da API ainda
não existem.

1. **`RespectIgnoreDifferences` só vale no sync automático, ou no manual que o declare.** Testado
   no `appserver-telnet` com `replicas` fora do valor do git:
   - `selfHeal`/auto-sync (drift provocado em `strategy.type`, campo presente no git): `replicas`
     **mantido**. É o caminho do Image Updater, o que importa.
   - sync manual criado por `operation.sync` **sem** `syncOptions`: `replicas` **revertido** para o
     valor do git (`deployment.apps/... configured`), com `replicas=0` e também com `2`.
   - o mesmo sync manual **com** `syncOptions: ["RespectIgnoreDifferences=true"]` na operação:
     `replicas` mantido.
   Um sync manual não herda os `syncOptions` do `syncPolicy`. **Consequência para a Fase 2**: a
   ação "sync" da API tem que mandar `RespectIgnoreDifferences=true` em toda operação; sem isso um
   clique em "sincronizar" religa tudo o que foi parado. O mesmo vale para quem sincronizar pelo
   CLI/UI do Argo CD (a UI pré-marca a opção; confira).
2. **Gate: lista de presença em vez de piso numérico.** O `sys_%` de uma base saudável hoje tem 52
   tabelas (total 168); o "53 de 81" do incidente era outra métrica (tabelas do dicionário base),
   então um piso de `sys_%` não teria base. `scripts/appserver-patch/required-sys-tables.txt`
   (36 tabelas das famílias acima, geradas da base que funciona) é a fonte única; a API deve
   embarcar a mesma lista (ConfigMap ou cópia versionada). Se o Protheus mudar o dicionário num
   patch, a lista precisa ser regenerada conscientemente — é o custo de não ter `force`.
3. **Bug achado e corrigido na hora, antes de qualquer commit**: a primeira versão do gate
   **falhava aberta** — com a lista ilegível, `missing` ficava vazio e o gate passava. Descoberto
   pelo teste negativo; agora recusa se a lista estiver ausente ou vazia. Testados 4 casos
   (saudável, tabela faltando, lista vazia, lista inexistente) e os códigos de saída.
4. `stop_appservers`/`restore_appservers` via `kubectl scale`, testados ao vivo só no `telnet`
   (para não derrubar o core). `run-job.sh` completo **não** foi executado: rodar um Job real
   (`worker`/`compile`/`upddistr`) fica para uma execução deliberada do usuário.
5. Os `README`s e o comentário do `appserver-worker-job.yaml` que diziam "commitar `replicas: 0`"
   foram atualizados; o ADR 0009 descreve a orquestração original e fica como registro histórico.

## Fase 1 — API de leitura implantada (2026-10-04)
Rotas `GET /api/v1/services[/{name}[/logs]]` e `GET /api/v1/database/dictionary`, token Bearer, no
repo `protheus-manager-api` `0.2.0`; manifesto em `base/protheus-manager.yaml`.
Validado ao vivo, dentro do cluster (túnel temporário, token não impresso):
- pod `1/1` sem restart, uid `10001`, 14 serviços listados, `bootstrap_complete: true`
  (36/36 tabelas), logs reais, 401 sem token e com token errado;
- **RBAC verificado com `kubectl auth can-i --as=` nos dois sentidos**: lê `deployments`, `pods` e
  `pods/log` no namespace; **nega** `patch deployments`, `deployments/scale`, `delete pods`,
  `create jobs`, `get secrets`, `create pods/exec` e qualquer coisa em `kube-system`/`argocd`.
- O Image Updater já resolveu o digest da imagem da API (entrada nova em `argocd/image-updater.yaml`).

Achados desta etapa:
1. **O cliente `kubernetes` 36 devolve `str(bytes)` literal nos logs** (`"b'...\\n'"`). Os testes
   com fakes passaram; só rodar contra o cluster real expôs. Corrigido com `_preload_content=False`
   e o fake passou a imitar o cliente real. Regra: fake que diverge da biblioteca dá confiança
   falsa — validar sempre também no ambiente real.
2. **Banco fora do ar viraria 500 com a mensagem do driver**, que pode ecoar o DSN com a senha.
   Agora é `503` com só o tipo do erro, com teste.
3. A leitura de logs cobre só **stdout**. O arquivo de log do AppServer (padding `\0`) exigiria
   `pods/exec`, fora da Role mínima; fica para quando houver motivo para ampliá-la.
4. **Leitura do Argo CD (Application) ficou de fora**: exigiria Role em outro namespace (`argocd`).
   Decidir junto com a Fase 2, que precisa dele para o sync.

Ainda **não** feito: publicação em `127.0.0.1:8800` pelo `serverlb` (depende de um
`k3d cluster edit --port-add` do usuário) e o token no cofre GPG (`encrypt.sh` pede a passphrase).

## Em aberto (não decidido aqui, de propósito)
1. **Troca de versão de imagem** (Fase 3). Hoje o Image Updater rastreia por **digest** sob tag
   fixa, e a troca de tag exige editar `base/*.yaml` **e** `argocd/image-updater.yaml` e reaplicar
   (README, seção GitOps). Duas rotas: a API altera o `ImageUpdater` direto no cluster (sem git,
   sem estado versionado) **ou** commita nos dois arquivos (exige credencial de git na API, o novo
   segredo que a v1 evita). A escolha depende de quanto o usuário quer que o git continue
   registrando versões. Decidir antes de começar a Fase 3.
2. **"Atualizar o share"** (volumes de `webapp`/`printer`/`webagent`). Hoje os três seeds já se
   atualizam por digest via Image Updater. Falta saber se a ação desejada é *forçar* o ciclo
   (rollout restart do seed e do consumidor) ou algo além disso — a corrida conhecida do
   `webagent` (ADR 0014) já se resolve com `rollout restart` de core/rest/telnet.
3. **Linguagem e local de execução** (Fase 0).
4. ~~Piso exato do gate de tabelas~~ — resolvido na Fase 1: o gate virou lista de presença.

## Consequências
- Operar o ambiente deixa de gerar commits de `replicas` (hoje dois por execução de Job); o
  histórico do git volta a conter só mudanças de infraestrutura.
- O git deixa de ser a fonte única da verdade para `replicas`. Quem olhar só `base/*.yaml` para
  saber quantas réplicas rodam estará errado; a fonte passa a ser o cluster (e o log da API).
- A v1 da API não guarda segredo de git; a superfície de segredo nova é só o token da própria API.
- O gate de bootstrap passa a ser código testável, não só convenção — e mais rígido que o do
  script atual. É custo deliberado: o incidente de 30/07 e o dicionário parcial de 20/09 mostraram
  que o gate fraco não protege.
- Dois repositórios novos para manter (API e web), cada um com CI e imagem próprios no Docker
  Hub, no mesmo padrão dos `docker-protheus-*`.
