# ADR 0014 — WebAgent como sidecar de entrega, não embutido no `appserver-core`

## Status
Aceito, implementado e validado ao vivo em 2026-09-18 — Compose primeiro, depois k8s.

## Contexto
O WebAgent é um utilitário **client-side** do TOTVS SmartClient — instalado na estação do
usuário final, nunca no servidor. Dá ao SmartClient HTML (rodando em navegador, sandboxed)
acesso a coisas que o navegador sozinho não permite: leitura/gravação de arquivo local,
integração com Microsoft Office, DLLs/SOs/Dylibs locais. Documentação oficial:
[TDN — WebApp/WebAgent](https://tdn.totvs.com/display/tec/2.+WebApp+-+WebAgent).

Restrição levantada pelo usuário antes de decidir o desenho: existe uma opção de
auto-download configurável no `appserver.ini`, mas isso exigiria embutir o instalador de
**cada sistema operacional** (Windows x86/x64, macOS, Linux deb/rpm) dentro da imagem do
AppServer — deixando-a desproporcionalmente pesada pra algo que o servidor nem executa, só
entrega. Decisão explícita de não fazer isso.

Confirmado na documentação oficial (PDF completo, 25 páginas, lido integralmente antes de
desenhar qualquer coisa) que `[WEBAGENT]` no `appserver.ini` aceita **caminho relativo ao
diretório de trabalho do AppServer** — não é URL, é caminho de arquivo que o próprio AppServer
lê e serve pro navegador:

```ini
[WEBAGENT]
VERSION=1.x.x
Windows_x86=webagent/web-agent-1.x.x-windows-x86.setup.exe
Windows_x64=webagent/web-agent-1.x.x-windows-x64.setup.exe
Darwin_universal=webagent/web-agent-1.x.x-darwin-universal.dmg
Linux_x64_deb=webagent/web-agent-1.x.x-linux-x64.deb
Linux_x64_rpm=webagent/web-agent-1.x.x-linux-x64.rpm
```

## Decisão

**Mesmo padrão já usado pro `webapp`/`printer`**: sidecar de entrega separado
(`docker-protheus-webagent`, imagem mínima, standby permanente), montado somente-leitura em
`appserver-core`/`-rest`/`-telnet`, sem tocar na imagem principal do AppServer.

1. **`docker-protheus-webagent`** — repo novo, público (binário redistribuível genérico, mesma
   categoria de `webapp`/`printer`/`dbaccess`, não dado de cliente como `rpo`/`system`/
   `systemload`/`includes`). Hoje só a build Linux x64 (o pacote oficial já traz `.deb` e `.rpm`
   no mesmo `.tar.gz`); estrutura pronta pra crescer pra Windows/macOS sem redesenho (ver README
   do repo).
2. **`docker-protheus-appserver`/`entrypoint.sh`** ganha um bloco novo, espelhando exatamente o
   já existente pro `webapp.so`: copia os arquivos de `/tmp/webagent_shared` (montado
   somente-leitura) pra uma subpasta local `webagent/` relativa ao diretório de trabalho do
   AppServer, e gera a seção `[WEBAGENT]` do `.ini` **detectando dinamicamente** os arquivos
   presentes (`ls *.deb`/`*.rpm`) em vez de fixar o nome — evita editar o script a cada bump de
   versão (o nome do arquivo já embute a versão) e já fica pronto pra outros SOs quando esses
   instaladores forem adicionados ao sidecar. Seção inteira omitida se nenhum instalador foi
   provisionado (sidecar não implantado ou volume vazio) — sem quebrar nada em ambiente sem
   WebAgent configurado.
3. **Compose**: novo serviço `protheus_webagent`, volume nomeado `webagent_shared_module`,
   montado somente-leitura nos três `appserver_*`. `run.sh` ganha suporte a `webagent` nos
   mesmos pontos que já tem pra `webapp`/`printer` (`update`, serviço contínuo isolado, lista
   padrão de `./run.sh postgres`).
4. **k8s**: `base/webagent.yaml` segue o template exato de `webapp.yaml`/`printer.yaml` — PV/PVC
   com `nodeAffinity` **desde o nascimento** (sem a dívida de retrofit do ADR 0004/0012, porque
   nasce correto desde o primeiro commit). Registrado em `argocd/image-updater.yaml`
   (`webagent-dev` é público, sem `regcred` necessário).

## Validação

Sequência confirmada em produção real, nos dois ambientes:

- **Compose**: build local do `docker-protheus-appserver` modificado, `./run.sh postgres` com o
  `webagent` novo, `appserver.ini` gerado com `[WEBAGENT]` correto, os dois arquivos
  (`.deb`/`.rpm`) no lugar certo, boot limpo (`Totvs Application Server is running`), nenhum
  outro componente afetado.
- **k8s**: `kubectl kustomize base/` e `dry-run=server` de todos os manifestos alterados sem
  erro; sync do Argo CD `Synced`/`Healthy`; PV com `nodeAffinity` correta; **achado real**: numa
  subida simultânea do zero, `appserver-core` pode gerar o `.ini` antes do sidecar `webagent`
  terminar de provisionar o volume (mesma condição de corrida que já existe silenciosamente pra
  `webapp`/`printer` — o `entrypoint.sh` só roda uma vez, não fica observando o volume). Não é
  bug novo introduzido aqui, é o mesmo comportamento tolerante já aceito pros outros dois
  sidecars (`if [ -f ... ]` com aviso, não falha). Resolvido com um `kubectl rollout restart`;
  na prática irrelevante fora de um teste imediatamente após a primeira subida (o usuário real só
  acessa o WebApp bem depois do pod estabilizar). 171 tabelas confirmadas intactas depois de
  tudo.

## Consequências
- Fecha o último item do backlog (`webagent`) — implementado, validado, documentado nos dois
  ambientes.
- Imagem do `appserver-core`/`-rest`/`-telnet` continua exatamente do mesmo tamanho — nenhum
  instalador de SO foi embutido nela, resolvendo a restrição original do usuário.
- Reusa 100% o mecanismo já existente (`webapp.so`) em vez de inventar um novo — menos código
  pra manter, mesmo padrão mental pra quem for ler o `entrypoint.sh` depois.
- Extensível: adicionar Windows/macOS mais tarde é só (a) baixar o pacote, (b) colocar no repo
  `docker-protheus-webagent` (descoberto dinamicamente pelo CI), (c) adicionar a chave
  correspondente na lógica de detecção do `entrypoint.sh` (`Windows_x86`/`Windows_x64`/
  `Darwin_universal`) — sem mudança de arquitetura.
