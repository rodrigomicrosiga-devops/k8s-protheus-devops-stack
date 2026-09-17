# Prompt reutilizável — sincronizar tags no `docker-protheus-devops-stack` (Compose)

Referente ao item "Atualização de binários TOTVS" do backlog (`docs/HANDOFF.md`) — é o passo
**depois** de já ter rodado `docs/prompts/atualizar-versao-binario-totvs.md` em um ou mais repos
`docker-protheus-*` e confirmado a imagem nova publicada no Docker Hub. Roda uma vez só, mesmo
que vários componentes tenham sido atualizados na mesma leva — o prompt descobre sozinho quais
mudaram, não precisa listar.

Use numa sessão do Claude Code **dentro do repo `docker-protheus-devops-stack`**.

---

## O prompt

```
Preciso sincronizar o docker-compose.yaml deste repo com as versões mais recentes das imagens
rodrigomicrosiga/* já publicadas no Docker Hub, e validar que a stack sobe de verdade com elas.

Siga esta sequência, parando pra eu confirmar antes de rodar a stack e antes do push final:

1. Liste todas as linhas `image: rodrigomicrosiga/...` do `docker-compose.yaml` (várias imagens
   aparecem em mais de um serviço -- ex. appserver-dev em core/rest/telnet/upddistr,
   appserver-dev-worker em worker/compiler -- pegue TODAS as ocorrências de cada uma).

2. Para cada imagem distinta, descubra a versão de referência de verdade: no diretório irmão
   `/media/rodrigo/dados/docker-protheus-<nome-da-imagem-sem-sufixo-dev>/` (ex.
   `docker-protheus-appserver` pra `appserver-dev`, `docker-protheus-license` pra
   `license-dev`), leia a linha `tags:` do `.github/workflows/docker-publish.yml`. Essa é a
   fonte de verdade da versão mais recente já publicada -- não confie no que já está no
   docker-compose.yaml pra decidir o que é "atual".

3. Compare com o que está no `docker-compose.yaml` hoje. Pra cada imagem onde a versão do repo
   irmão for diferente da que está no compose, confirme que a tag nova existe de fato no Docker
   Hub (`docker manifest inspect rodrigomicrosiga/<imagem>:<tag>`) antes de editar qualquer
   coisa -- nunca escreva uma tag no compose sem confirmar que ela existe publicada.

4. Me mostre a lista de mudanças propostas (imagem: versão antiga → versão nova, com quantas
   ocorrências cada uma tem no arquivo) antes de editar.

5. Edite TODAS as ocorrências de cada imagem que mudou (use busca global, não só a primeira
   linha que aparecer).

6. Faça uma varredura final: `grep -n "rodrigomicrosiga/" docker-compose.yaml` e confira que não
   sobrou nenhuma tag desalinhada com o que os repos irmãos publicaram.

7. PARE aqui e me pergunte se pode rodar a stack pra validar. Só prossiga depois que eu
   confirmar -- isso derruba/recria containers locais de verdade.

8. Com a confirmação: `./run.sh postgres` (sobe a stack com Postgres, que é o SGBD validado
   neste projeto -- não tente validar MSSQL/Oracle a menos que eu peça). Acompanhe os logs do
   `protheus_core` até ele estabilizar. Se ele entrar em crashloop ou pedir bootstrap manual
   (login/criação de dicionário) -- PARE IMEDIATAMENTE e me avise, não prossiga sozinho, essa é
   a regra mais cara deste projeto (ver `CLAUDE.md` do repo irmão
   `k8s-protheus-devops-stack` se existir localmente, ou me pergunte).

9. Se subir limpo: valide que os serviços que mudaram de versão respondem como esperado (ex.
   `appserver-core`/`rest`/`telnet` up, `license` healthy) e me mostre o resultado.

10. Rode `git status`/`git diff` e me mostre um resumo do que vai entrar no commit.

11. Faça o commit seguindo o estilo já usado neste repo (rode `git log --oneline -15` pra
    confirmar o padrão antes de escrever a mensagem -- é Conventional Commits em português,
    tipo(escopo) quando fizer sentido, sem trailer de atribuição de IA).

12. PARE aqui. Me mostre a mensagem de commit e pergunte se pode dar `git push`.

Depois do push: me lembre que o próximo passo (fora deste repo) é portar as mesmas versões pro
k8s-protheus-devops-stack (base/*.yaml + argocd/image-updater.yaml) -- não faça isso aqui.
```

## Por que o prompt é assim

- **Descobre sozinho quais imagens mudaram** (comparando com a tag publicada em cada repo
  irmão) em vez de eu listar manualmente — numa leva de atualização com vários componentes de
  uma vez (foi o caso real de 2026-09-17: license, appserver e appserver-worker juntos), listar
  à mão é exatamente o tipo de passo que se esquece.
- **Confirma no Docker Hub antes de editar** — evita o compose apontar pra uma tag que ainda não
  existe (CI ainda rodando, ou falhou silenciosamente).
- **Para antes de rodar a stack** — `./run.sh postgres` derruba/recria containers locais de
  verdade; mesmo não sendo tão irreversível quanto um push de CI, ainda merece confirmação.
- **Gate explícito do bootstrap** — mesmo bumping de versão em ambiente já rodando não deveria
  disparar bootstrap, mas o prompt reforça a regra dura do projeto (nunca deixar rodar sozinho
  worker/compile/upddistr ou aceitar um novo bootstrap sem confirmação) por segurança, já que é
  a regra mais cara já violada uma vez neste projeto (30/07, poluição do banco).
