# Prompt reutilizável — atualizar versão de binário TOTVS num repo `docker-protheus-*`

Referente ao item "Atualização de binários TOTVS" do backlog (`docs/HANDOFF.md`). Use este
prompt (copie o bloco abaixo, sem editar nada) numa sessão do Claude Code **dentro de cada
repo** `docker-protheus-{appserver,appserver-worker,dbaccess,webapp,printer}` que precisar de
uma versão nova do binário TOTVS — depois de já ter colocado o artefato baixado na raiz do
repo. Repita uma vez por repo — não peça pra ele mexer em outro repo.

`webagent` fica **fora** deste prompt: não existe `docker-protheus-webagent` ainda, não é
atualização, é componente novo (Dockerfile/entrypoint do zero) — trate como tarefa separada.

`docker-protheus-appserver-worker` compartilha o **mesmo** `.tar.gz` do `docker-protheus-appserver`
(mesmo binário AppServer) — se o appserver mudou de versão, este repo também precisa do mesmo
tratamento, mas é um repo e um commit separados.

---

## O prompt

```
Preciso atualizar a versão do binário TOTVS empacotado neste repo. O artefato novo já foi
colocado na raiz deste repositório (pode estar junto do binário antigo, ou já substituindo ele
-- não presuma qual dos dois casos, descubra).

Siga esta sequência, parando pra eu confirmar antes do push final:

1. Leia o `Dockerfile` e ache o padrão exato do `COPY` que traz o binário pra imagem (glob
   case-insensitive, ex. `COPY ./*[aA][pP][pP]...` — o padrão muda de repo pra repo, não
   assuma).

2. Leia o `.github/workflows/docker-publish.yml` e ache a linha `tags:` — ela define o nome da
   imagem e a versão ATUAL (ex. `rodrigomicrosiga/appserver-dev:24.3.1.5`). Única fonte
   confiável disso, não assuma.

3. Liste, na raiz do repo, todos os arquivos que batem com o padrão do passo 1 (`ls -la`
   ordenado por data de modificação). Identifique qual é o artefato NOVO:
   - só um arquivo bate → é o novo;
   - mais de um bate → o de data de modificação mais recente é o novo, os outros são versões
     antigas a remover no passo 6;
   - nenhum bate → PARE e me pergunte onde está o artefato (o padrão do Dockerfile pode não
     bater com o nome do arquivo, ou ele ainda não foi colocado no repo).

4. A partir do artefato novo identificado, determine a versão NOVA de verdade. NÃO incremente
   às cegas nem assuma um padrão de nomenclatura fixo — repos diferentes deste fleet codificam a
   versão de formas diferentes: alguns embutem no nome do arquivo (ex. `..._24.3.1.5_...`),
   outros não têm versão nenhuma no nome (o pacote do printer, por exemplo, é só
   `PRINTER_LINUX_X64.TAR.GZ`). Investigue nesta ordem até achar um número confiável, e me diga
   qual fonte usou:
   a. o nome do arquivo;
   b. o conteúdo do pacote (descompacte e procure por um arquivo de versão/manifest/release
      notes dentro dele);
   c. se não achar nada confiável nas duas primeiras, PARE e me pergunte a versão nova
      diretamente -- não adivinhe.

5. Confirme comigo a versão nova antes de continuar (ex. "achei X, a tag vai ficar
   rodrigomicrosiga/<imagem>:X — confirma?").

6. Remova da raiz o(s) artefato(s) antigo(s) identificado(s) no passo 3 (confirme antes que não
   estão rastreados pelo git -- o `.gitignore` já deveria cobrir esse padrão). O artefato novo
   já está na raiz, só confira se o nome dele bate no glob do Dockerfile; renomeie só se
   necessário.

7. Edite a linha `tags:` do `.github/workflows/docker-publish.yml` pra nova versão, mantendo o
   mesmo nome de imagem (namespace/repo Docker Hub) -- só a versão muda.

8. Atualize o `README.md`: procure TODAS as ocorrências literais da versão antiga no arquivo
   inteiro (comandos de exemplo tipo `docker inspect`/`docker run`, texto descritivo, badges se
   houver) e troque pela versão nova. Não se limite à primeira ocorrência.

9. Faça uma varredura final: `grep -rn "<VERSAO_ANTIGA>" .` (excluindo `.git/`) no repo inteiro
   e revise cada ocorrência restante -- decida caso a caso se deve mudar (não mude changelog
   histórico nem texto que descreve uma versão antiga de propósito).

10. Rode `git status`/`git diff` e me mostre um resumo do que vai entrar no commit antes de
    commitar.

11. Faça o commit seguindo EXATAMENTE o estilo já usado neste repo (rode `git log --oneline -15`
    pra confirmar o padrão antes de escrever a mensagem, não assuma): Conventional Commits em
    português, tipo(escopo) quando fizer sentido, descrição no imperativo, sem acento em
    maiúsculas de código mas com acentuação normal do português no resto, sem trailer de
    atribuição de IA (Co-Authored-By ou similar) -- os commits deste fleet são sempre assinados
    como se fossem só do usuário. Prefira UM commit coeso (binário + tag do workflow + README),
    a menos que o diff fique genuinamente grande/confuso pra revisar junto -- nesse caso, separe
    em commits menores e me avise por quê.

12. PARE aqui. Me mostre a mensagem de commit e pergunte se pode dar `git push`. Só dê push
    depois que eu confirmar explicitamente -- o push dispara o pipeline de CI (self-hosted
    runner) que builda e publica a imagem nova no Docker Hub de verdade, não é reversível
    sozinho.

Depois do push: me lembre que o próximo passo (fora deste repo) é atualizar a tag no
docker-compose.yaml do docker-protheus-devops-stack e validar lá antes de portar a versão nova
pro k8s-protheus-devops-stack (base/*.yaml + argocd/image-updater.yaml) -- não faça isso aqui,
é responsabilidade de outra sessão/repo.
```

## Por que o prompt é assim

- **Autodescobre o artefato pela raiz do repo, não por um caminho colado no prompt** — seu fluxo
  real é sempre soltar o arquivo baixado na raiz do repo antes de pedir a atualização, então o
  prompt não devia depender de você editar um placeholder toda vez. Identifica o candidato certo
  cruzando o glob do `Dockerfile` com a data de modificação dos arquivos na raiz — funciona tanto
  se você já removeu o antigo quanto se ainda estão os dois lado a lado, e para e pergunta se
  não conseguir decidir sozinho.
- **Não assume um único padrão de nome de versão** porque já confirmei que não existe um: o
  `printer` não tem versão no nome do arquivo, os outros três têm. Um prompt genérico que
  assumisse regex único ia falhar silenciosamente ali.
- **Pede confirmação da versão antes de agir** porque errar a versão aqui contamina o resto do
  fleet (workflow, README, e depois o Compose e o k8s) com um número errado — mais barato
  confirmar uma vez no início.
- **README como passo explícito, não implícito** porque já existe precedente real de esquecer
  isso: `docker-protheus-dbaccess` teve um commit corretivo só pra isso
  (`docs: corrige tag da imagem desatualizada no README`).
- **Lê o `git log` do próprio repo antes de escrever a mensagem de commit**, em vez de eu
  prescrever um formato fixo aqui — cada repo do fleet já tem seu próprio histórico consistente
  (`tipo(escopo): descrição`), mais confiável pedir pra Claude conferir na hora do que eu copiar
  um exemplo que pode já estar desatualizado.
- **Para antes do push** porque é a única ação de verdade irreversível-o-suficiente da sequência
  (dispara CI real, publica imagem real no Docker Hub) — mesmo princípio de cautela usado no
  resto deste projeto.
