# ADR 0023 — Catálogo de releases, atualização de binário e migração de release

## Status
**Proposto** em 2026-10-04 (decisões do usuário nas frentes A e B; **nada implementado**). Depende
do ADR 0022 (topologias). Complementa o ADR 0019 (itens "Em aberto" 1 e 2) e o ADR 0021.

## Contexto
O usuário quer, pela API do manager, (A) **atualizar versões** de artefatos e (B) **migrar ou criar**
topologias por release. Premissa: tudo que se atualiza **já tem imagem publicada no Docker Hub**; o
portal da TOTVS nunca é acessado.

Fatos verificados em 2026-10-04:
- "Release" hoje é `12.1.2510`, a tag dos 3 seeds (`protheus-{rpo,system,systemload}-dev`). As versões
  dos binários são **independentes** (appserver `24.3.1.9`, dbaccess `24.1.1.3`, license `3.7.2`,
  webapp `10.2.1`, printer `3.0.5`, webagent `1.1.1`, smartview `3.9.0`). **A matriz release →
  versões não existia em lugar nenhum do repo.** Os binários de `12.1.2510` valem até essa release; a
  `12.1.2610` terá binários novos (ex.: appserver `26.x`).
- No Docker Hub há **uma tag por repositório** hoje (nada novo a descobrir).
- A release está **cravada em 4 lugares por seed**: `ENV PROTHEUS_RELEASE` + `LABEL` no Dockerfile
  (não é `ARG`), a tag no workflow de CI, `base/protheus-seed.yaml` e o alias do `ImageUpdater`.
- O seed do RPO **nunca sobrescreve** um RPO de release diferente (fica em standby);
  `system`/`systemload` reprovisionam quando o marcador `release:revisão` muda.
- A CI das imagens seed lê o artefato do **disco do runner**, com tag fixa.

## Decisão

### 1. Catálogo: um arquivo-receita por release, no git
`catalog/releases/<release>.yaml` neste repo. Chega à API como **ConfigMap gerado pelo Kustomize e
entregue pelo Argo CD** (a API não precisa de credencial de git para ler). Formato proposto:

```yaml
release: 12.1.2510
seeds:                       # sempre a mesma tag da release
  rpo:        {tag: 12.1.2510, digest: sha256:…}
  system:     {tag: 12.1.2510, digest: sha256:…}
  systemload: {tag: 12.1.2510, digest: sha256:…}
binaries:
  appserver: {pinned: 24.3.1.9, compatible: "24.3.1.*", digest: sha256:…}
  dbaccess:  {pinned: 24.1.1.3, compatible: "24.1.*",   digest: sha256:…}
  license:   {pinned: 3.7.2,    compatible: "3.7.*",    digest: sha256:…}
  # webapp, printer, webagent, smartview, postgres, includes …
gate:
  requiredTables: [SYS_GRP_…, …]   # a lista do portão DESTA release
```

- Os padrões `compatible` **são escritos pelo usuário**, uma vez por release; a API **não adivinha**
  compatibilidade TOTVS.
- O catálogo guarda o **digest**: com tag fixa, a tag não identifica conteúdo (o mesmo build gera
  digest novo).
- A lista de tabelas do portão passa a morar **por release** no catálogo (provavelmente muda entre
  releases); isso resolve a duplicação **L9**.
- O catálogo só **referencia** releases já publicadas; ele não "pede" uma imagem nova (item 3).

### 2. Descoberta (A2)
A API lista as tags de cada imagem no Hub, **filtra pelo `compatible` da release da topologia** e
compara com o que roda: "há `appserver 24.3.1.10` compatível; a topologia roda `24.3.1.9`". Só avisa
quando alguém pergunta (rota GET e tela); notificação ativa fica fora desta fase. O endpoint do
registro é **parâmetro** (hoje as imagens são públicas, decisão do usuário; se virarem privadas,
entra uma credencial do Hub como segredo novo ou reaproveita a do Image Updater).

### 3. Quem constrói a imagem (A3)
A API **só consome** imagens já publicadas. Não dispara CI: exigiria token do GitHub e, mesmo assim,
o artefato continua entrando pelo **disco do runner**, que é manual.

### 4. Atualizar um binário (frente A)
- Operação: "topologia `T`: componente `C` de `X` para `Y`". `Y` precisa casar com o `compatible` da
  release de `T`; senão a API **recusa com o motivo**.
- A API **gera a mudança** (arquivos do overlay e o alias do ImageUpdater, com o digest resolvido) e
  o **usuário commita** (fase 1). **Fase 2 (futura, decisão própria):** push de branch
  `topology/<nome>` com *deploy key* só deste repo; o merge em `develop` continua do usuário.
  **A API nunca escreve em `develop`.**
- Mudar de **tag** exige editar o manifesto **e** o alias do ImageUpdater; o override casa por nome
  de imagem (L15) e o cutover tem **dois rollouts** — conferir o `imageID` do pod depois (ADR 0021).
- **Travas (todas):** (i) a imagem existe no Hub e casa com o `compatible`, com o digest registrado
  no diff; (ii) **backup Velero `Completed` recente** da topologia, citado na mensagem de commit,
  para binário/seed/release; (iii) **portão do bootstrap** passando (nunca mexer numa base em
  bootstrap) — **não** vale para *criar* topologia; (iv) **confirmação digitada** do nome da
  topologia.
- "Atualizar o share" (webapp/printer/webagent) = o `restart` que já existe; os seeds já se
  atualizam por digest.

### 5. Migrar release — endpoint **exclusivo**
`POST /api/v1/topologies/{t}/migrations` → `202` com o id; `GET …/operations/{id}` devolve etapa
atual, histórico e logs. A tela consulta periodicamente. O estado fica no **PV do manager**
(sobrevive a restart da API). Etapas:

```
pré-checagens → backup Velero → parar AppServers → gerar commit (seeds + binários do catálogo)
   ── pausa em "aguardando merge" (o usuário commita) ──▶
arquivar → seed provisiona a release nova → UPDDISTR (portão) → veredito por Result.json → religar
```

- O veredito do UPDDISTR é o conteúdo de `Result.json`, não o status do Job (ADR 0009); a
  restauração das réplicas roda **sempre**, também em falha. "Religar" respeita o que o usuário
  parou de propósito (rest/telnet): restaura o estado **anterior à operação**, não "tudo ligado".
- **Regra do RPO (decisão do usuário):** o `custom.rpo` **vale para todas as releases** e é
  **preservado no lugar**, com uma cópia arquivada. `tttm120.rpo`/`tlpp.rpo` são **únicos por
  release** (o da `12.1.2510` não serve na `12.1.2610`) e são substituídos. O seed continua **nunca
  sobrescrevendo sozinho**; quem tira o RPO antigo do caminho é a migração, **movendo** (não
  apagando) para `apo/archive/<release>-<data>/`, só com confirmação digitada + backup `Completed`.
  Voltar à release anterior = **restore do backup**. A operação termina avisando que as
  customizações precisam ser recompiladas (`compile`, Fase 3).
- O **portão do bootstrap** vale na entrada e antes do UPDDISTR; sem `force`.

### 6. Criar topologia (frente B3, fase 1)
A API **gera** a pasta `topologies/<nome>/` (ADR 0022) a partir de uma release do catálogo e devolve
o diff; o usuário commita e executa o passo de host (`k3d … --port-add`). Base vazia; o bootstrap
manual é do usuário.

### 7. Auditoria durável (A7) — pré-requisito de tudo acima
**JSONL append-only num PV próprio do manager** (`local`/`Retain`/`nodeAffinity`, incluído no backup
Velero), além do stdout, com rota `GET` de leitura. O manager tem 1 réplica (sem escrita
concorrente). Descartados: tabela no Postgres (qual Postgres, com N topologias? acopla o manager a uma
topologia) e Loki (peça nova e pesada; a auditoria dependeria dele estar de pé).

### 8. Contrato
Toda rota nova começa no `openapi/openapi.json` e passa na régua `scripts/contract-check.sh`, com e
sem `--mutating`, antes de trocar a imagem de produção. Testes com os fakes oficiais do `client-go`
e **teste de mutação** nas guardas.

## Spike obrigatório antes de implementar
- **s3** — a migração mover arquivos do PV `apo` por um **Job curto** (RBAC `jobs` da Fase 3), num
  namespace descartável.

## Ordem de implementação proposta (a confirmar com o usuário)
1. Auditoria durável + armazenamento de operações.
2. Catálogo da `12.1.2510` (digests e lista do portão).
3. Spikes s1/s2 e refatoração `base/` → `topologies/protheus-devops` (render idêntico) + ApplicationSet.
4. API: leitura do catálogo, descoberta (A2) e geração da troca de binário.
5. Fase 3 (Jobs worker/compile/upddistr) atrás do portão, sem `force`.
6. Criar topologia (geração + passo de host).
7. Operação de migração.
8. L5, F2 e F3 na ordem que o usuário priorizar.

## Achados que este ADR carrega (❓ = não verificado)
- **F2.** A CI do `docker-protheus-rpo` copia o RPO de `docker-protheus-devops-stack/protheus/apo/`,
  o diretório **vivo** do Compose, alterado por worker/compile. **Antes de publicar a `12.1.2610`, a
  fonte tem que ser um diretório de artefato pristino.** ❓ Não verifiquei se o digest publicado hoje
  é o pristino `568f185e…` (a publicação é de 29/07, anterior aos patches no cluster — indício, não
  prova; exigiria baixar ~670 MB).
- **F3.** O entrypoint do `systemload` não tem a checagem de "permission denied" que o do `system`
  ganhou em 22/09 (mesma classe de bug: extração parcial marcada como sucesso).
- **F4.** ❓ Não verifiquei se o Docker Hub mantém manifestos que perderam a tag; o rollback "para o
  digest anterior" depende disso. O catálogo guarda o digest, mas não garante que a imagem continue
  baixável.

## Alternativas descartadas
- **Catálogo só em ConfigMap no cluster**: sem histórico e some num rebuild.
- **Derivar a matriz de labels das imagens**: muda 16 Dockerfiles/CI e não expressa compatibilidade.
- **Tag da release em todos os binários**: perde a versão TOTVS na tag e muda a CI dos 16 repos.
- **Migração automática ponta a ponta sem pausa de merge**: contraria a decisão de o git registrar
  versões (e a regra de ouro do RPO).
- **Alterar o `ImageUpdater` direto no cluster, sem git**: sem histórico; conflita com overlay por
  topologia.

## Consequências
- O git volta a registrar **versões** (por topologia), que o ADR 0019 tinha deixado em aberto.
- A API ganha uma operação **longa e com estado**: é o código mais arriscado do projeto, então vem
  depois da auditoria durável e atrás do portão.
- Aceito: criar topologia e migrar exigem passos do usuário (merge, comando de host); é intencional.
