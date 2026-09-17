# Prompt reutilizável — atualizar versão de binário TOTVS num repo `docker-protheus-*`

Referente ao item "Atualização de binários TOTVS" do backlog (`docs/HANDOFF.md`). Use este
prompt (copie o bloco abaixo) numa sessão do Claude Code **dentro de cada repo**
`docker-protheus-{appserver,appserver-worker,dbaccess,webapp,printer}` que precisar de uma
versão nova do binário TOTVS. Repita uma vez por repo — não peça pra ele mexer em outro repo.

`webagent` fica **fora** deste prompt: não existe `docker-protheus-webagent` ainda, não é
atualização, é componente novo (Dockerfile/entrypoint do zero) — trate como tarefa separada.

`docker-protheus-appserver-worker` compartilha o **mesmo** `.tar.gz` do `docker-protheus-appserver`
(mesmo binário AppServer) — se o appserver mudou de versão, este repo também precisa do mesmo
tratamento, mas é um repo e um commit separados.

---

## O prompt

```
Preciso atualizar a versão do binário TOTVS empacotado neste repo. O artefato novo já está
baixado em: <CAMINHO_DO_ARQUIVO_BAIXADO>

Siga esta sequência, parando pra eu confirmar antes do push final:

1. Leia o `.github/workflows/docker-publish.yml` deste repo e encontre a linha `tags:` — ela
   define o padrão exato de nome/tag da imagem publicada (ex.
   `rodrigomicrosiga/appserver-dev:24.3.1.5`). Essa é a ÚNICA fonte confiável do nome da imagem
   e da versão atual — não assuma, leia o arquivo.

2. Determine a versão NOVA de verdade. NÃO incremente às cegas nem assuma um padrão de
   nomenclatura fixo — repos diferentes deste fleet codificam a versão de formas diferentes:
   alguns embutem no nome do arquivo baixado (ex. `..._24.3.1.5_...`), outros não têm versão
   nenhuma no nome (o pacote do printer, por exemplo, é só `PRINTER_LINUX_X64.TAR.GZ`). Investigue
   nesta ordem até achar um número de versão confiável, e me diga qual fonte usou:
   a. o nome do arquivo baixado;
   b. o conteúdo do pacote (descompacte e procure por um arquivo de versão/manifest/release
      notes dentro dele);
   c. se não achar nada confiável nas duas primeiras, PARE e me pergunte a versão nova
      diretamente -- não adivinhe.

3. Confirme comigo a versão nova antes de continuar (ex. "achei X, a tag vai ficar
   rodrigomicrosiga/<imagem>:X — confirma?").

4. Troque o binário na raiz do repo:
   - Ache o padrão de nome que o `Dockerfile` espera (ele usa um `COPY` com glob
     case-insensitive, ex. `COPY ./*[aA][pP][pP]...` — leia o Dockerfile pra confirmar o padrão
     exato deste repo, não assuma).
   - Remova o(s) `.tar.gz`/`.TAR.GZ` antigo(s) da raiz (o `.gitignore` já cobre esse padrão —
     confirme que o arquivo não está rastreado pelo git antes de mexer).
   - Copie o artefato novo pra raiz do repo, com um nome que bata no mesmo padrão glob do
     Dockerfile.

5. Edite a linha `tags:` do `.github/workflows/docker-publish.yml` pra nova versão, mantendo o
   mesmo nome de imagem (namespace/repo Docker Hub) -- só a versão muda.

6. Atualize o `README.md`: procure TODAS as ocorrências literais da versão antiga no arquivo
   inteiro (comandos de exemplo tipo `docker inspect`/`docker run`, texto descritivo, badges se
   houver) e troque pela versão nova. Não se limite à primeira ocorrência.

7. Faça uma varredura final: `grep -rn "<VERSAO_ANTIGA>" .` (excluindo `.git/`) no repo inteiro
   e revise cada ocorrência restante -- decida caso a caso se deve mudar (não mude changelog
   histórico nem texto que descreve uma versão antiga de propósito).

8. Rode `git status`/`git diff` e me mostre um resumo do que vai entrar no commit antes de
   commitar.

9. Faça o commit seguindo EXATAMENTE o estilo já usado neste repo (rode `git log --oneline -15`
   pra confirmar o padrão antes de escrever a mensagem, não assuma): Conventional Commits em
   português, tipo(escopo) quando fizer sentido, descrição no imperativo, sem acento em
   maiúsculas de código mas com acentuação normal do português no resto, sem trailer de
   atribuição de IA (Co-Authored-By ou similar) -- os commits deste fleet são sempre assinados
   como se fossem só do usuário. Prefira UM commit coeso (binário + tag do workflow + README),
   a menos que o diff fique genuinamente grande/confuso pra revisar junto -- nesse caso, separe
   em commits menores e me avise por quê.

10. PARE aqui. Me mostre a mensagem de commit e pergunte se pode dar `git push`. Só dê push
    depois que eu confirmar explicitamente -- o push dispara o pipeline de CI (self-hosted
    runner) que builda e publica a imagem nova no Docker Hub de verdade, não é reversível
    sozinho.

Depois do push: me lembre que o próximo passo (fora deste repo) é atualizar a tag no
docker-compose.yaml do docker-protheus-devops-stack e validar lá antes de portar a versão nova
pro k8s-protheus-devops-stack (base/*.yaml + argocd/image-updater.yaml) -- não faça isso aqui,
é responsabilidade de outra sessão/repo.
```

## Por que o prompt é assim

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
