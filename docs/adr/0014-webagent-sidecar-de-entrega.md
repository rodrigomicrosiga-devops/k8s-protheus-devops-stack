# ADR 0014 — WebAgent como sidecar de entrega, não embutido no `appserver-core`

## Status
Aceito e implementado em 2026-09-18 — Compose primeiro, depois k8s. Estendido pra multi-SO
(Windows x86/x64, macOS Universal/x64) na mesma data. Validado ao vivo nos dois ambientes na
versão Linux-only; a extensão multi-SO está validada ao vivo só no Compose — a propagação pro
k8s está bloqueada por um achado novo, não relacionado ao desenho deste ADR (ver seção
"Propagação pro k8s" abaixo).

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
   `systemload`/`includes`). Builder multi-estágio genérico por formato de arquivo (`.tar.gz`
   via `tar`, `.zip` via `unzip`, `.dmg` copiado direto — `find -iname`, nunca nome fixo), pra
   suportar as 5 variantes que a Central de Downloads TOTVS distribui: Linux x64 (`.deb`+`.rpm`
   no mesmo `.tar.gz`), Windows x86/x64 (`.zip`, um instalador `.exe` cada) e macOS
   Universal/x64 (`.dmg` direto). `.msi` (Windows, fluxo de distribuição via GPO/Active
   Directory — canal separado do botão de download do navegador) também é entregue no volume,
   mas de propósito não referenciado no `.ini` (ver item 2 abaixo).
2. **`docker-protheus-appserver`/`entrypoint.sh`** ganha um bloco novo, espelhando exatamente o
   já existente pro `webapp.so`: copia os arquivos de `/tmp/webagent_shared` (montado
   somente-leitura) pra uma subpasta local `webagent/` relativa ao diretório de trabalho do
   AppServer, e gera a seção `[WEBAGENT]` do `.ini` **detectando dinamicamente** os arquivos
   presentes em vez de fixar o nome — evita editar o script a cada bump de versão (o nome do
   arquivo já embute a versão). Detecção cobre as 5 chaves documentadas: `Linux_x64_deb`/
   `Linux_x64_rpm` (`find -iname '*.deb'`/`'*.rpm'`), `Windows_x86`/`Windows_x64` (`find -iname
   '*x86*.exe'`/`'*x64*.exe'` — distinção só é possível pelo nome do arquivo, a extensão sozinha
   é ambígua entre os dois), `Darwin_universal` (`find -iname '*universal*.dmg'`, com fallback
   pra qualquer `.dmg` se não houver um explicitamente `universal` — prioriza o build universal
   quando os dois `.dmg` estão presentes, é o único com chave documentada em `[WEBAGENT]`).
   `.msi` não tem chave no `.ini` (não é o fluxo de auto-download, é distribuição via GPO) —
   fica disponível no volume compartilhado pra um admin usar manualmente, mas o entrypoint não
   o referencia. Seção `[WEBAGENT]` inteira omitida se nenhum instalador foi encontrado (sidecar
   não implantado ou volume vazio) — sem quebrar nada em ambiente sem WebAgent configurado.
3. **Compose**: novo serviço `protheus_webagent`, volume nomeado `webagent_shared_module`,
   montado somente-leitura nos três `appserver_*`. `run.sh` ganha suporte a `webagent` nos
   mesmos pontos que já tem pra `webapp`/`printer` (`update`, serviço contínuo isolado, lista
   padrão de `./run.sh postgres`).
4. **k8s**: `base/webagent.yaml` segue o template exato de `webapp.yaml`/`printer.yaml` — PV/PVC
   com `nodeAffinity` **desde o nascimento** (sem a dívida de retrofit do ADR 0004/0012, porque
   nasce correto desde o primeiro commit). Registrado em `argocd/image-updater.yaml`
   (`webagent-dev` é público, sem `regcred` necessário).

## Validação

Sequência confirmada em produção real, nos dois ambientes — primeiro só Linux, depois estendida:

- **Compose (Linux-only)**: build local do `docker-protheus-appserver` modificado, `./run.sh
  postgres` com o `webagent` novo, `appserver.ini` gerado com `[WEBAGENT]` correto, os dois
  arquivos (`.deb`/`.rpm`) no lugar certo, boot limpo (`Totvs Application Server is running`),
  nenhum outro componente afetado.
- **k8s (Linux-only)**: `kubectl kustomize base/` e `dry-run=server` de todos os manifestos
  alterados sem erro; sync do Argo CD `Synced`/`Healthy`; PV com `nodeAffinity` correta;
  **achado real**: numa subida simultânea do zero, `appserver-core` pode gerar o `.ini` antes do
  sidecar `webagent` terminar de provisionar o volume (mesma condição de corrida que já existe
  silenciosamente pra `webapp`/`printer` — o `entrypoint.sh` só roda uma vez, não fica observando
  o volume). Não é bug novo introduzido aqui, é o mesmo comportamento tolerante já aceito pros
  outros dois sidecars (`if [ -f ... ]` com aviso, não falha). Resolvido com um `kubectl rollout
  restart`; na prática irrelevante fora de um teste imediatamente após a primeira subida (o
  usuário real só acessa o WebApp bem depois do pod estabilizar). 171 tabelas confirmadas
  intactas depois de tudo.
- **Compose (multi-SO, rodada seguinte)**: mesmo dia, com os artefatos reais de Windows/macOS já
  baixados pelo usuário. Imagens republicadas sob as MESMAS tags (`webagent-dev:1.1.1`,
  `appserver-dev:24.3.1.9`) com digest novo em cada uma; `.ini` gerado com as 5 chaves corretas,
  todos os instaladores no volume compartilhado, boot limpo, nenhuma regressão na parte Linux já
  validada.
- **k8s (multi-SO)**: **não validado ainda** — ver seção seguinte.

## Propagação pro k8s (multi-SO) — bloqueada, achado novo e maior

Tentando confirmar a extensão multi-SO no cluster, um `kubectl set image` manual nos
deployments (`appserver-core`/`-rest`/`-telnet`/`webagent`) foi revertido automaticamente pelo
`selfHeal` do Argo CD — comportamento correto: `Application.spec.source.kustomize.images` ainda
tinha o override cacheado apontando pro digest antigo. Investigando por que o
`argocd-image-updater` não tinha resolvido o digest novo sozinho (o mecanismo normal, descrito
na seção "Decisão" acima), os logs do `argocd-image-updater-controller` mostraram
`toomanyrequests: You have reached your unauthenticated pull rate limit` contra `docker.io`, em
vários ciclos de poll seguidos.

Causa raiz: `scripts/cluster-bootstrap/helm-values/argocd-image-updater.yaml` nunca teve seção
de credenciais de registry — o controller sempre resolveu digest como cliente anônimo do Docker
Hub. Isso não é um problema introduzido pelo webagent; é uma lacuna pré-existente na frota
inteira (as ~11 imagens em `argocd/image-updater.yaml`), só exposta agora pelo volume de
pulls/testes desta sessão batendo no limite anônimo.

Decisão tomada: **não forçar o override do `Application` diretamente**. Motivo: no meio da
investigação, o valor cacheado no override mostrou um TERCEIRO digest (`e87ee71e...`)
inconsistente com os dois valores que eu mesmo confirmei de forma independente via `docker
manifest inspect` (`appserver-dev:24.3.1.9` → `8a7ed2af...`, `webagent-dev:1.1.1` →
`dcf39033...`) — sinal de que algo na cadeia de resolução está inconsistente o bastante pra não
confiar num patch manual. Cluster verificado estável do jeito que está: `Synced`/`Healthy`, 171
tabelas intactas, todos os pods `Running`, rodando a versão anterior (funcional, só sem as 3
chaves novas do `[WEBAGENT]`). Registrado como item novo de backlog em `docs/HANDOFF.md`, com
correção recomendada (credenciais Docker Hub no Helm values do Image Updater) pendente de
execução real numa sessão futura — depende de credencial que só o usuário tem.

## Consequências
- Fecha o último item do backlog original (`webagent`) — implementado, validado (Compose e k8s
  na versão Linux; Compose na versão multi-SO), documentado.
- Imagem do `appserver-core`/`-rest`/`-telnet` continua exatamente do mesmo tamanho — nenhum
  instalador de SO foi embutido nela, resolvendo a restrição original do usuário, mesmo agora com
  5 formatos de instalador cobertos.
- Reusa 100% o mecanismo já existente (`webapp.so`) em vez de inventar um novo — menos código
  pra manter, mesmo padrão mental pra quem for ler o `entrypoint.sh` depois.
- Extensão pra Windows/macOS confirmou a extensibilidade prevista: foi só (a) baixar o pacote,
  (b) colocar no repo `docker-protheus-webagent`, (c) adicionar a chave correspondente na lógica
  de detecção do `entrypoint.sh` — sem mudança de arquitetura, exatamente como esperado.
- **Achado colateral, fora do escopo original deste ADR**: expôs uma lacuna de autenticação no
  `argocd-image-updater` (rate limit anônimo do Docker Hub) que afeta toda a frota de imagens
  rastreadas, não só o webagent — novo item de backlog em `docs/HANDOFF.md`, correção pendente
  de credencial do usuário.
