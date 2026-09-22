# HANDOFF — estado vivo do projeto

> Atualize este arquivo ao fim de cada sessão de trabalho real (não a cada commit pequeno).
> Formato: mantenha a seção "Onde paramos" sempre no topo e mova o resto para "Histórico" quando
> deixar de ser o ponto ativo.

## Onde paramos (2026-09-21 ~22:30 UTC — drill completo de cluster do zero, ADR 0016 validado no cenário exato, passphrase do cofre GPG rotacionada)

Sessão longa, dois objetivos em sequência: (1) corrigir o hook `smartview-db-init` (follow-up do
ADR 0013), (2) a pedido do usuário, **executar de verdade** um `k3d cluster delete` completo pra
provar a correção no cenário exato que a motivou — bootstrap genuinamente do zero, sem nenhum
Secret pré-existente. Os dois fechados com sucesso. Detalhe completo, achados e evidências em
`docs/adr/0016-ordenacao-por-sync-waves-em-vez-de-hook-em-secret.md` e
`docs/adr/0013-cluster-bootstrap-do-zero.md` (seção "Segunda execução do drill").

### Parte 1 — correção do hook (detalhe no histórico logo abaixo)
`smartview-db-init-job` saiu de hook `PreSync` pra `Sync`/wave 1; SQL corrigido (`ON_ERROR_STOP=1`,
GRANTs em bloco `DO`); achado à parte, bug real do `dash` no heredoc (`$$` virava `$`), corrigido
trocando pra tag nomeada `$body$`. Validado com 2 syncs no cluster que já existia.

### Parte 2 — drill completo do zero (`k3d cluster delete` real, receita 00→04 do ADR 0013)
**Resultado do objetivo principal: sucesso total, sem NENHUMA intervenção manual.** Primeiro sync
completou `Synced`/`Healthy` sozinho — diferente das duas vezes anteriores que passaram por esse
caminho (drill de 18/09, precisou de bypass manual; correção do mesmo dia 21/09 na Parte 1, teve 8
falhas pelo bug do `dash`). Linha de base batida: 167 tabelas, hash do `tttm120.rpo`/`custom.rpo`
idênticos, os 4 `SealedSecret` decifrados corretamente.

**Cinco achados reais novos** (detalhe completo no ADR 0013 "Segunda execução"):
1. Node recriado por `01-fix-cgroupns.sh` pode ficar preso em `NotReady` por senha de registro
   desatualizada — `kubectl delete secret -n kube-system <node>.node-password.k3s` resolve.
2. `server-0` pode voltar `SchedulingDisabled` sem causa raiz (já documentado em
   `scripts/k3d-nodes/README.md`) — `kubectl uncordon` resolve.
3. Chart `minio/minio` pede `resources.requests.memory: 16Gi` por default — não cabe no cluster
   local, corrigido em `minio-persistence.yaml` (256Mi/512Mi).
4. Chart `vmware-tanzu/velero` tenta criar `VolumeSnapshotLocation` inválido quando
   `snapshotsEnabled` fica no default (`true`) — este projeto só usa File System Backup, corrigido
   em `velero-overrides.yaml` (`snapshotsEnabled: false`).
5. **Passphrase do cofre GPG (ADR 0011) genuinamente perdida** — usuário não conseguiu recuperar
   (tentativas malsucedidas). Rotacionada: passphrase nova gerada e entregue uma única vez.
   `kube-prometheus-stack.yaml.gpg`/`minio.yaml.gpg`/`velero.yaml.gpg` reconstruídos do zero
   (schema de cada chart via `helm show values`) e reencriptados; `sealed-secrets-keys-backup.
   yaml.gpg` reexportado **ao vivo** do cluster já restaurado e reencriptado também. Únicos achados
   3/4 (memória do MinIO, snapshot do Velero) só apareceram porque os `.gpg` antigos (que
   provavelmente já tinham isso ajustado) foram perdidos e reconstruídos do zero.

~~Não migrado pra passphrase nova~~ **Resolvido em 2026-09-22**: `base/postgres-secret.env.gpg`
recriado do valor documentado no `CLAUDE.md` (`ProtheusPwd2026`) e re-encriptado — cofre agora
sob uma única passphrase ativa. Achado real no processo (não no manifesto): a passphrase gerada
no fim desta sessão tinha sido substituída pelo usuário, fora de sessão registrada, por uma
própria memorável — causou confusão real (duas candidatas, sem saber qual valia), resolvida
testando contra um arquivo de baixo risco já migrado antes de agir. Detalhe completo no ADR 0011
("Follow-up fechado em 2026-09-22").

**Validação funcional real do Velero/MinIO/node-agent**, não só pods `Running`: backup sob demanda
(`velero backup create`) completou — 269/269 itens, 2 volumes via `kopia` (File System Backup),
hook do `pg_dump` sem falha, fase `Completed`.

**Documentação já corrigida nesta sessão** (não ficou como pendência): `scripts/cluster-bootstrap/
README.md` e o texto impresso por `03-install-argocd.sh` — ambos citavam o bypass manual do hook
como se ainda fosse necessário, atualizados pra refletir a correção do ADR 0016.

**Erro real cometido nesta sessão, sem consequência**: deletei o namespace `argocd` sem necessidade
(achando que precisava recriá-lo — `helm --create-namespace` já lida com namespace existente) logo
depois do usuário ter criado o `dockerhub-creds` nele — apagou o secret junto. Pedido pro usuário
recriar de novo, sem mais incidentes.

### Verificações rápidas ao retomar
- `kubectl get applications -n argocd protheus-devops-stack` → `Synced`/`Healthy`.
- `kubectl get pods -n protheus-devops` → 13 pods `1/1`.
- `kubectl get pods -n velero -n falco -n monitoring` → tudo `Running`/`Completed`.
- `kubectl exec deployment/postgres -n protheus-devops -- psql -U postgres -d protheus -tAc
  "select count(*) from information_schema.tables where table_schema='public'"` → `167`.
- `docker ps --filter name=protheus_` deve vir vazio.
- Nodes deste cluster são os RECRIADOS nesta sessão (`k3d-protheus-cluster-*`) — o cluster antigo
  foi destruído de verdade, não é mais o mesmo container Docker de sessões anteriores.

**Esta é uma instalação de dev/estudo** (sem ambiente de produção): ao ler "produção" nos ADRs
ou aqui, leia "o cluster de dev".

## Histórico condensado da sessão de 2026-09-21, parte 1 — correção do hook smartview-db-init

Sessão de continuação. Único item de manifesto conhecido em aberto (ADR 0013, achado 1):
`smartview-db-init-job` rodava como hook `PreSync` dependendo de `postgres-secret`, um
`SealedSecret` de fase `Sync` — trava qualquer bootstrap genuinamente do zero. Corrigido e
**validado com sync real via Argo CD, duas vezes seguidas** (não só render local). Detalhe
completo, achados e evidências em `docs/adr/0016-ordenacao-por-sync-waves-em-vez-de-hook-em-secret.md`.

### O que mudou
- `smartview-db-init-job` saiu de hook `PreSync` para hook `Sync`/`sync-wave: "1"` — os secrets
  que ele consome (`postgres-secret`, `smartview-secret`, `postgres-config`) ficam na wave 0
  normal, o Deployment `smartview` foi pra wave 2. `smartview-secret.sealed.yaml` perdeu as
  anotações de hook que tinha ganho em 20/09 (eram elas próprias defeituosas — ver achado abaixo).
- SQL do Job reescrito: `ON_ERROR_STOP=1` em toda chamada do `psql` (antes um erro no meio do
  arquivo saía com exit 0, mascarando falha), GRANTs movidos pra dentro de bloco `DO` (antes
  `EXECUTE format()` rodava solto, inválido), `\c postgres` removido, `POSTGRES_USER`/`POSTGRES_DB`
  trocados de literais desatualizados (`protheus`) pra `envFrom: postgres-config` (`postgres`,
  correto desde o ADR 0015 — e só o superusuário consegue `CREATE USER` de verdade).
- **Achado real só descoberto ao aplicar de verdade** (não estava na investigação inicial): o
  primeiro sync com a correção acima ainda falhou, 8 vezes seguidas, `syntax error` bem no
  `DO $$` que ninguém tinha tocado. Causa: `/bin/sh` desta imagem é `dash`, que tem um bug real de
  parsing de heredoc — mesmo citado (`<<'SQL'`), engole um dos dois `$` do par `$$` adjacente.
  Confirmado via `od -c` no arquivo gerado dentro do container. Corrigido trocando `$$` anônimo
  por tag nomeada `$body$` nos dois blocos `DO`. Registrado no ADR 0016 como risco pra qualquer
  script deste repo que gere SQL/config via heredoc num container Alpine.

### Validação ao vivo (não só render)
Dois syncs reais via `argocd`/`kubectl patch` no `Application`, ambos `Synced`/`Succeeded` na
primeira tentativa depois da correção do `dash`:
- `syncResult.resources` confirma o Job com `hookType: Sync` (não mais `PreSync`) e os secrets
  sem `hookType` nenhum.
- `datacl` de `postgres` saiu de `NULL` pra `{...,protheus=c/postgres}` — prova de que os GRANTs
  finalmente aplicam de verdade, e continuou **idêntico** no segundo sync (idempotência do
  ADR 0003 se sustentou, sem duplicar).
- `creationTimestamp` dos 4 `SealedSecret`/`Secret` **inalterado** nos dois syncs — confirma que
  nenhum é mais deletado/recriado por sync (o defeito que o achado 1 do ADR 0016 documentou).
- 13 pods `1/1 Running`, sem restart novo em nenhum; 167 tabelas intactas.
- Limpeza pós-depuração: dois artefatos de teste (`testuser999`/`testdb999`) criados durante a
  investigação manual foram removidos do banco antes de considerar a sessão fechada.

## Histórico condensado da sessão de 2026-09-20 (cliente SIGAACD)

Sessão de continuação, depois do bootstrap manual (ver histórico logo abaixo). Objetivo virou
validar o console `SIGAACD` via telnet (`appserver-telnet`) — o PuTTY (único cliente telnet do
usuário) não conseguia navegar o menu. Investigado a fundo, causa raiz real encontrada, e dois
clientes próprios criados e validados ao vivo. **Nenhuma mudança de infra ficou pendente** — o
único experimento de manifesto (`LANG=C` no `appserver-telnet`) foi testado e revertido.

### Estado exato ao pausar (conferido ao vivo)
- Argo CD `Synced`/`Healthy`, commits em `origin/develop` (último `e248c99`), árvore limpa.
- 13 pods `1/1 Running`. Banco `protheus`: `WIN1252`, **167 tabelas** (subiu de 166 pra 167
  durante a sessão — não investigado o porquê, provavelmente uma tabela criada ao abrir alguma
  rotina do SIGAACD durante os testes de navegação; não parece problema).
- **PuTTY foi desinstalado pelo usuário** — não é mais uma ferramenta disponível neste host pra
  telnet. Use os clientes novos (abaixo).
- 6 `kubectl port-forward` ativos em background desta sessão (`5433→postgres`, `7891→dbaccess`,
  `8020→license`, `1234→appserver-core`, `8400→appserver-rest`, `2323→appserver-telnet`) —
  **são processos da sessão do terminal, não sobrevivem a reboot nem a troca de sessão**, e
  morrem sempre que o pod alvo é recriado. Religar sob demanda, comando padrão:
  `kubectl port-forward deployment/<nome> <porta-local>:<porta-remota> -n protheus-devops &`.

### Novidade: `scripts/sigaacd-client/` — cliente telnet próprio pro SIGAACD
Criado porque nenhum cliente telnet genérico (testado: PuTTY 0.81) consegue navegar o menu do
`SIGAACD`. Duas implementações equivalentes, escolha qualquer uma:
- `scripts/sigaacd-client/python/sigaacd_client.py` — só stdlib, precisa de `python3`.
- `scripts/sigaacd-client/go/` — compila um binário único (`go build -o sigaacd-client .`), sem
  dependência de runtime.

Achados reais que motivaram o cliente (detalhe completo, incluindo como foi diagnosticado, em
`scripts/sigaacd-client/README.md`):
1. **Navegação não é por seta** — o `SIGAACD` é DOS/Clipper/Harbour genuíno, não reconhece
   nenhuma sequência VT100/ANSI de teclado. `ESC` sozinho é lido como **abortar/sair**. A
   navegação real é **digitar o número da posição do item** (`1`, `2`, `3`...) + `ENTER` pra
   abrir o destacado.
2. **O servidor nunca negocia a opção telnet `ECHO`** — clientes com eco local automático (PuTTY
   em modo "Auto") duplicam visualmente cada tecla, mascarando que a navegação já funciona por
   baixo (parecia "só imprimir o número na tela").

Os dois clientes não fazem eco local (terminal em modo raw) e não traduzem os códigos ANSI que o
próprio `SIGAACD` manda — só repassam pro terminal real do usuário. Validados ao vivo: login,
navegação por número, abertura de rotina, saída limpa via `Ctrl+]` — os dois, idêntico
comportamento.

### Achado sem correção: acentos comidos no título da tela de login do SIGAACD
`TOTVS Construção e Projetos POSTGRES Protheus` chega como `TOTVS Constru  o e Pojetos POSTGRES
Proteus` — `ç`/`ã` viram espaço, letras ASCII puras (`r`, `h`) somem sem deixar rastro. Investigado
a fundo (bytes corrompidos desde a captura mais crua possível, sem cliente nenhum envolvido;
`LANG=C` testado ao vivo no `appserver-telnet` e revertido, zero efeito; `CP1252.so` confirmado
presente no container; chave `Environment=` do `[TELNET]` confirmada sem relação com charset via
doc oficial TOTVS). Conclusão: bug interno do binário `appsrvlinux` (proprietário, sem acesso a
fonte) — fora do alcance de infra/k8s/cliente telnet. **Não bloqueia uso real** (login, navegação
e abertura de rotinas funcionam) — aceito como limitação conhecida, documentado em
`scripts/sigaacd-client/README.md`, sem pendência de correção.

### Pendências reais / não verificado (carregadas de sessões anteriores, ainda abertas)
- **Decisão em aberto do usuário**: reaplicar ou não o `UPDDISTR` do pacote `EXPEDICAO_CONTINUA`
  que a base antiga tinha (a atual, 167 tabelas, já é o dicionário padrão completo — não
  comparável 1:1 com a contagem antiga). RPO não foi tocado.
- `fiscal.zip` do `protheus-system-seed` não pode ser reextraído por cima do conteúdo existente
  (dono uid 1000 vs container uid 100). Não bloqueia nada hoje.
- **Restore *real* sobre o cluster principal não foi exercitado** (só o drill em namespace
  descartável, ADR 0015).
- ~~Follow-up antigo do ADR 0013: `smartview-db-init` (`PreSync`) depende de `postgres-secret`
  (recurso de `Sync`) e trava todo bootstrap do zero.~~ **Resolvido em 2026-09-21**, ver "Onde
  paramos" no topo e ADR 0016.
- `UPDDISTR`/`worker`/`compile` (`scripts/appserver-patch/run-job.sh`) podem rodar (gate do
  `CLAUDE.md` vencido) — ainda não executados nesta base nova.

### Verificações rápidas ao retomar
- `kubectl get applications -n argocd protheus-devops-stack`; `kubectl get pods -n protheus-devops`
  (13 pods `1/1`).
- Se for usar o `SIGAACD`: religar o `port-forward` de telnet
  (`kubectl port-forward deployment/appserver-telnet 2323:23 -n protheus-devops &`) e usar
  `scripts/sigaacd-client/` — **não tem mais PuTTY neste host**.
- `docker ps --filter name=protheus_` deve vir vazio.

**Esta é uma instalação de dev/estudo** (sem ambiente de produção): ao ler "produção" nos ADRs
ou aqui, leia "o cluster de dev".

## Histórico condensado da sessão de 2026-09-20 — bootstrap manual concluído

Sessão que atravessou o gate do bootstrap manual (regra dura do `CLAUDE.md`) que tinha pausado em
2026-09-19. **Duas tentativas de login falharam antes da terceira dar certo** — ambas com causas
reais, não ruído, detalhadas abaixo. Resultado final: dicionário completo (166 tabelas), `core`/
`rest`/`telnet` de pé, backup `pos-bootstrap` limpo (254/254 itens, 0 erros, 0 warnings).

### ⚠️ Estado exato ao pausar (conferido ao vivo)
- Argo CD `Synced`/`Healthy`, commits em `origin/develop` (último `ec83514`), árvore limpa.
- Todos os 13 pods `1/1 Running`, incluindo `appserver-core`/`-rest`/`-telnet`.
- Banco `protheus`: `WIN1252 | collate=C | ctype=pt_BR.CP1252`, dono `protheus`, **166 tabelas**
  (dicionário `SYS_*` completo, login inicial concluído pelo usuário via SmartClient).
- Backup `pos-bootstrap` (`velero`): `Completed`, 254/254, sem erros/warnings — linha de base
  confiável do estado pós-bootstrap. **Backups `manual-2`/`pre-reinit` continuam sendo do banco
  antigo em UTF8 — nunca restaurar sobre o atual.**
- 4 `kubectl port-forward` em background nesta sessão (`5433→postgres`, `7891→dbaccess`,
  `8020→license`, `1234→appserver-core`) — **morrem sempre que o pod alvo é recriado** (não é
  bug, é como `port-forward` funciona: aponta pro pod, não pro Service). Religar sob demanda.

### Achado 1 — menu do SmartClient "não disponível" no primeiro login
Erro `FWSYSTBLSTARTUP`: "Menu do configurador não disponível no startpath para importação".
Causa real: os `.xnu` (menus corporativos) **já tinham sido consumidos** por uma importação
anterior (quando o banco antigo ainda existia) — o próprio Protheus os move automaticamente para
`system/fwbackup/menu/` depois de importados (confirmado pelo usuário). Com o banco recriado
vazio, o `FWSYSTBLSTARTUP` precisava de `.xnu` na **raiz** de `system/` de novo, e não havia.
Corrigido reextraindo `menus.zip` direto de dentro da imagem seed
(`kubectl exec deploy/protheus-system-seed -- unzip -oq /opt/protheus-seed/menus.zip -d
/mnt/system`) sem tocar em `fwbackup/`. **Achado secundário sobre o seed**: o
`.system_seed_marker` (e outros arquivos herdados) pertencem a uid `1000`, mas a imagem atual do
`protheus-system-dev` roda como uid `100` (`protheus`, `adduser -S` no Alpine) — não consegue
sobrescrever esses arquivos existentes (só criar novos, porque o `fix-shared-volume-permissions`
só faz `chmod 0777` no diretório raiz, não recursivo). `unzip -o` funciona pra arquivos que ainda
não existem (caso dos `.xnu`); pra sobrescrever os já existentes (ex.: `fiscal.zip` em cima de
`dots/`/`estadual/`/`municipal/`) dá `Permission denied` — não chegou a ser necessário corrigir
(conteúdo original de 2023 intacto), mas é uma inconsistência de dono real no volume, não
corrigida no manifesto. Se precisar reprovisionar `fiscal.zip` de verdade no futuro, o
`fix-shared-volume-permissions` provavelmente precisa de `chmod -R` em vez de `chmod` plano.

### Achado 2 — dicionário incompleto após o 1º login bem-sucedido (28 tabelas SYS_* faltando)
Depois do menu corrigido, o primeiro login **pareceu** funcionar mas travou depois com "Não foram
encontradas as seguintes tabelas": 28 tabelas `SYS_GRP_*`/`SYS_RULES*`/`SYS_USR_ACCESS`/
`SYS_USR_OAUTH` etc. O banco tinha só 53 das 81 tabelas esperadas — criação de dicionário parcial,
mesma família do incidente do ADR 0006 (DDL incompleto/travado). Seguido o procedimento exato do
ADR 0006: `core`/`dbaccess`/`license` parados via git → conexões residuais (DBeaver do usuário)
encerradas com `pg_terminate_backend` → `DROP DATABASE protheus` + `CREATE DATABASE ... ENCODING
'WIN1252' LC_COLLATE 'C' LC_CTYPE 'pt_BR.CP1252' TEMPLATE template0` (rodado pelo usuário via `!`,
comando destrutivo) → `kubectl rollout restart deployment postgres` (cache do `dbaccess` limpo) →
`dbaccess`/`license` religados e revalidados → só então `core` de volta. **Terceira tentativa de
login: sucesso completo**, 166 tabelas.

### Achado 3 — acesso ao SmartClient não é pela URL do `CLAUDE.md`
`http://<host>:<CORE_PORT_MULTI>/` (forma antiga documentada) não funciona mais: o `serverlb` do
k3d só publica `6443` no host desde a remoção da porta `7890` (sessão de 18/09). Funciona por
`kubectl port-forward deployment/appserver-core 1234:1234 -n protheus-devops` →
`http://127.0.0.1:1234/` (já documentado no `README.md:138`, só não estava no fluxo do
`CLAUDE.md`/handoff antigo) ou pelo IP do node agent (`docker inspect`) + NodePort `31234`.

### Achado 4 — `appserver-rest` levou 2 restarts pra estabilizar
Depois de religado, `appserver-rest` reiniciou 2x por falha do `livenessProbe` (porta `8400`
"connection refused") antes de ficar `1/1 Running`. Log interno mostrou `Totvs Application Server
is running` em ~15.7s, mas a porta REST (`8400`) só abre depois de mais um estágio do framework
REST — nesta sessão, logo após a criação de um dicionário de 166 tabelas do zero (custo extra de
indexação, provável causa, não confirmada). `initialDelaySeconds` de `readinessProbe`/
`livenessProbe` em `base/appserver-rest.yaml` (15s/30s) pode estar just no limite pra esse
cenário. Não corrigido — estabilizou sozinho, mas vale considerar aumentar o delay se voltar a
acontecer fora de um bootstrap.

### Pendências reais / não verificado
- **Decisão em aberto do usuário**: a base nova (166 tabelas) não tem o dicionário que o
  `UPDDISTR` do pacote `EXPEDICAO_CONTINUA` tinha aplicado na base antiga (chegou a 54 tabelas
  `SYS_*` numa contagem diferente/antiga — não comparável 1:1 com as 166 de hoje, que já são o
  dicionário padrão completo). Reaplicar ou não esse UPDDISTR específico é escolha dele. RPO não
  foi tocado: `tttm120.rpo` (patch "onça pintada") e `custom.rpo` seguem no volume `protheus-apo`.
- `fiscal.zip` do `protheus-system-seed` não pode ser reextraído por cima do conteúdo existente
  (dono uid 1000 vs container uid 100) — ver Achado 1. Não bloqueia nada hoje.
- **Restore *real* sobre o cluster principal não foi exercitado** (só o drill em namespace
  descartável, ADR 0015).
- Follow-up antigo do ADR 0013 segue aberto: `smartview-db-init` (`PreSync`) depende de
  `postgres-secret` (recurso de `Sync`) e trava todo bootstrap do zero.
- `UPDDISTR`/`worker`/`compile` (`scripts/appserver-patch/run-job.sh`) agora **podem** rodar —
  gate do `CLAUDE.md` vencido. Ainda não executados nesta base nova.

### Verificações rápidas ao retomar
- `kubectl get applications -n argocd protheus-devops-stack`; `kubectl get pods -n protheus-devops`
  (13 pods `1/1`).
- `kubectl exec deployment/postgres -n protheus-devops -- psql -U postgres -d protheus -tAc
  "select count(*) from information_schema.tables where table_schema='public'"` → deve ser `166`.
- `kubectl get backup pos-bootstrap -n velero -o jsonpath='{.status.phase}'` → `Completed`.
- `docker ps --filter name=protheus_` deve vir vazio.
- Se for acessar algo via `port-forward`, religar primeiro (morrem quando o pod é recriado — ver
  Achado 3 acima).

**Esta é uma instalação de dev/estudo** (sem ambiente de produção): ao ler "produção" nos ADRs
ou aqui, leia "o cluster de dev".

## Histórico condensado da sessão de 2026-09-19

Backup/DR com Velero fechado e restore validado por hash (ADR 0015); achado e correção do
encoding do banco (UTF8 → WIN1252) com reinicialização do Postgres do zero. Sessão pausou no gate
do bootstrap manual — retomada e concluída na sessão de 2026-09-20 (ver "Onde paramos" acima).

**O que mudou (detalhe em `docs/adr/0015-backup-dr-velero.md`)**:
- **Backup/DR**: MinIO em `k8s-volume/minio-backup` (bind mount real, sobrevive a `k3d cluster
  delete`); `node-agent` ligado; servidor do Velero de 256Mi→1Gi (foi `OOMKilled` no 1º backup);
  `Schedule protheus-daily` (21:00 UTC, TTL 7d, namespaces `protheus-devops`+`argocd` — confirmado
  na sessão seguinte que o Velero recupera sozinho um schedule vencido se a máquina estava
  desligada no horário); `protheus-apo-pv` virou `local` (Velero não faz backup de `hostPath`);
  dump lógico do Postgres via hook `pre.hook.backup.velero.io` (só dumpa bancos que existem).
  Restore validado por hash: RPO e dumps idênticos.
- **Rshared**: `scripts/k3d-nodes/post-boot.sh` + `k3d-node-rshared.service` (o fix se perdia em
  reboot do host, derrubando `node-exporter`/`node-agent`; ADR 0013, acréscimo).
- **Encoding**: `base/postgres.env` agora `POSTGRES_DB/USER=postgres` (**nunca voltar pra
  `protheus`**: o entrypoint oficial cria o banco em UTF8 antes do init da imagem). Postgres
  reinicializado do zero; `DB_*`/`ENV_NAME` seguem `protheus`.
- **Limpeza**: RPOs de backup (~1,4 GB) e a pasta órfã `protheus-includes` removidos pelo usuário
  (o classificador de segurança bloqueia `rm` destrutivo do assistente, mesmo com autorização: o
  caminho é preparar o comando e pedir pro usuário rodar via `!`).
- `bootstrap` (`00`/`04`) passou a preparar `postgres-dumps`, MinIO em bind mount, overlays de
  values e o Schedule.

## Histórico condensado da sessão de 2026-09-18, parte 4 — backlog original zerado

**Verificar ao retomar, antes de qualquer coisa nova**:

1. **Cluster ainda saudável?**
   ```
   kubectl get applications -n argocd protheus-devops-stack   # Synced / Healthy
   kubectl get pods -n protheus-devops                         # todos Running, sem restart novo
   kubectl exec deployment/postgres -n protheus-devops -- \
     psql -U protheus -d protheus -tAc \
     "select count(*) from information_schema.tables where table_schema='public';"  # 171
   ```
2. **Image Updater segue autenticado?** `kubectl logs -n argocd deployment/argocd-image-updater-controller
   --tail=50 | grep -i toomanyrequests` não deve retornar nada. Se voltar a aparecer, o Secret
   `dockerhub-creds` (namespace `argocd`) pode ter expirado/sido revogado no Docker Hub — Access
   Tokens não expiram por padrão, mas vale checar Account Settings → Security se isso acontecer.
3. **WebAgent multi-SO segue completo?** `kubectl exec deploy/appserver-core -n protheus-devops --
   grep -A8 WEBAGENT appserver.ini` deve mostrar as 5 chaves
   (`Windows_x86`/`Windows_x64`/`Darwin_universal`/`Linux_x64_deb`/`Linux_x64_rpm`). Se algum pod
   de AppServer for recriado antes do `webagent` (ex.: reinício simultâneo do zero) e vier
   faltando chave, é a corrida sidecar-vs-core já conhecida (ADR 0014) — `kubectl rollout restart
   deployment appserver-core appserver-rest appserver-telnet` resolve.

**Não há item de backlog aberto conhecido neste momento** — os 4 itens do ciclo mais recente
(`includes`, segurança/GPG, `webagent` incluindo multi-SO, auth do Image Updater) estão todos
fechados e validados ao vivo (ver seção "Backlog aberto, por prioridade" abaixo — mantida com o
histórico de cada item fechado, não porque algo ainda esteja pendente). Próxima sessão começa
sem pendência herdada: definir com o usuário qual a próxima frente de trabalho (overlays do
Kustomize? staging/produção? outro componente da stack?) antes de qualquer implementação.

## Histórico condensado da sessão de 2026-09-18, parte 3

**Verificar ao retomar, antes de qualquer coisa nova**:

1. **WebAgent multi-SO — Compose validado, k8s ainda não propagou**. A pedido do usuário,
   `docker-protheus-webagent` ganhou Windows (x86/x64) e macOS (Universal/x64) além do Linux já
   existente — commits `f20d454` (Linux) e `5439a20` (multi-SO) no repo, `docker-protheus-appserver`
   commits `050ac72`/`a953e2a` (detecção dinâmica das 5 chaves `[WEBAGENT]`). CI publicou os dois
   sob as MESMAS tags (`webagent-dev:1.1.1`, `appserver-dev:24.3.1.9`) com digests novos.
   **Validado ao vivo só via Compose**, com as imagens reais publicadas no Docker Hub — `.ini`
   com as 5 chaves corretas, `.msi` disponível no volume mas de propósito fora do `.ini` (sem
   chave documentada, fluxo GPO é outro). **k8s ainda está rodando os digests antigos** — ver
   item abaixo, achado novo que bloqueia a propagação, não é falha do trabalho do webagent em si.
2. **Achado novo, fleet-wide: `argocd-image-updater` sem autenticação no Docker Hub.**
   Descoberto ao tentar confirmar a propagação do item 1: `kubectl set image` manual foi revertido
   pelo `selfHeal` do Argo CD (esperado — o override cacheado em
   `Application.spec.source.kustomize.images` ainda apontava pro digest antigo). Investigando por
   que o Image Updater não tinha atualizado o override sozinho, os logs do
   `argocd-image-updater-controller` mostram `toomanyrequests: You have reached your
   unauthenticated pull rate limit` em `docker.io` há vários ciclos de poll seguidos — afeta
   TODAS as ~11 imagens rastreadas, não só `webagent`/`appserver`. `scripts/cluster-bootstrap/
   helm-values/argocd-image-updater.yaml` não tem seção de credenciais de registry (só
   `resources.requests`). Decisão tomada: **não forcei o override do Application diretamente**
   (cheguei a ver um terceiro valor de digest, `e87ee71e...`, inconsistente com os dois que eu
   mesmo confirmei via `docker manifest inspect` — risco real de aplicar o digest errado).
   Cluster confirmado estável do jeito que está (`Synced`/`Healthy`, 171 tabelas, todos os pods
   `Running`) rodando a versão anterior do webagent/appserver (funcional, só sem o multi-SO
   ainda). Ver item novo no backlog abaixo — precisa de credencial real
   (`DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`, já usada em todo o resto da frota) que só o usuário
   pode fornecer.
3. **Quando isso resolver** (rate limit expira sozinho em horas, ou a autenticação for
   configurada), confirmar: `kubectl get pods -n protheus-devops -o
   custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'` deve mostrar os appservers
   em `appserver-dev:24.3.1.9@sha256:8a7ed2af...` e `webagent` em
   `webagent-dev:1.1.1@sha256:dcf39033...` (digests confirmados via `docker manifest inspect` no
   Docker Hub); só então repetir o teste `kubectl exec deploy/appserver-core -- grep -A8 WEBAGENT
   appserver.ini` esperando as 5 chaves (antes só tinha 2, `Linux_x64_deb`/`Linux_x64_rpm`).

## Histórico condensado da sessão de 2026-09-18, parte 2

**Verificar ao retomar, antes de qualquer coisa nova**:

1. **Boot ficou higiênico?** `docker ps -a` não deve mostrar os 6 containers do Compose
   (`protheus_core`/`postgres`/`license`/`webapp`/`printer`/`dbaccess`) rodando sozinhos — eles
   devem estar `Exited`, não `Up`, a menos que o usuário os suba deliberadamente. Se algum
   estiver `Up` sem ter sido pedido, ver a regra operacional nova abaixo sobre `docker stop` em
   container já parado por falha — não é mais a policy `unless-stopped` em si (já confirmada
   correta nos 6).
2. **Bump do k8s se sustentou?** `kubectl get applications -n argocd protheus-devops-stack` deve
   seguir `Synced`/`Healthy`; `kubectl get pods -n protheus-devops -o
   custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'` deve mostrar
   `appserver-dev:24.3.1.9` (core/rest/telnet) e `license-dev:3.7.2` — não voltou pra
   24.3.1.5/3.7.1. Se tiver voltado, o Image Updater pode ter re-resolvido pra outra coisa;
   investigar antes de mexer em qualquer manifesto.
3. **Itens 0 e 5 do backlog fechados nesta sessão** — Compose validado ao vivo nas tags novas e
   `README.md` atualizado (Fases C/D/E, scripts, prompts), ver abaixo. Nada pendente aqui.
4. **Item 1 do backlog (`includes.zip`) implementado E validado ao vivo** — repo
   `docker-protheus-includes` criado, publicado, CI rodou com sucesso
   (`protheus-includes-dev:0.0.1` no Docker Hub), e `run-job.sh compile` confirmou duas vezes
   que o `initContainer seed-includes` entrega os zips certos (`Precompilation... ok` nas duas).
   Nenhum `compile` terminou com sucesso total ainda (fonte de teste colidiu com função já
   existente no `custom.rpo` — não é falha do include), mas isso não bloqueia mais nada; próximo
   `compile` real com fonte sem colisão deve fechar limpo. Ver ADR 0010.
5. **Itens 2 e 3 (antigo) do backlog fechados nesta sessão** — cofre GPG pro
   `postgres-secret.env` (ADR 0011) e recriação dos 3 PVs legados com `nodeAffinity` (ADR 0012).
   Verificar: `kubectl get pv postgres-pv webapp-shared-pv printer-shared-pv` deve mostrar os 3
   com `nodeAffinity` preenchida (não vazia) e `Bound`; os 6 consumidores (`postgres`, `webapp`,
   `printer`, `appserver-core`/`-rest`/`-telnet`) `Running`, `1/1`, sem restart novo.
6. **Item 4 (antigo) do backlog fechado — porta `7890` removida do `serverlb`**: `k3d cluster
   edit protheus-cluster --port-delete 7890:7890@loadbalancer` recriou o `serverlb` sem o
   mapeamento. Verificar: `docker ps` do `serverlb` deve mostrar só `80/tcp, ...->6443/tcp` (sem
   `7890`); isso **não é persistido em nenhum manifesto deste repo** — é estado do container
   Docker do k3d, fora do git (mesma natureza de `scripts/k3d-nodes/`, que não recria o
   `serverlb`). Se o `serverlb` for recriado do zero por outro caminho no futuro (ex.: `k3d
   cluster delete` + `create`), essa remoção não se propaga sozinha — teria que rodar o mesmo
   `--port-delete` de novo, ou já criar sem a porta desde o início.
7. **Item 3 (antigo, "cluster do zero") fechado — DRILL AO VIVO EXECUTADO, não só receita
   documentada**: `k3d cluster delete protheus-cluster` real, cluster inteiro recriado do zero
   (rede/nodes/volumes k3s) via `scripts/cluster-bootstrap/` (ADR 0013), sucesso total. Verificar
   ao retomar: `kubectl get nodes` (2 `Ready`), `kubectl get applications -n argocd
   protheus-devops-stack` (`Synced`/`Healthy`), os 12 pods de `protheus-devops` mais
   Falco/monitoring/Velero-MinIO no ar. Dois achados reais novos, registrados no ADR 0013 (não
   eram conhecidos antes de executar de verdade): hook `smartview-db-init` também trava contra
   `postgres-secret` num bootstrap do zero (mesma família de bug do ADR 0012, causa diferente,
   correção manual documentada, **não corrigida no manifesto ainda**); nodes recriados nascem com
   mount raiz em propagação `private` (quebra `node-exporter`) — **esse já corrigido dentro do
   próprio `01-fix-cgroupns.sh`**, não precisa de passo manual no próximo drill.
8. **Item 3 (`webagent`) fechado — último item do backlog original** (ADR 0014): sidecar de
   entrega implementado e validado nos dois ambientes (Compose e k8s), mesmo padrão de
   `webapp`/`printer`. Verificar: `docker ps` deve mostrar `protheus_webagent` saudável no
   Compose; `kubectl get pods -n protheus-devops -l app=webagent` deve mostrar `1/1 Running` no
   k8s; `kubectl exec deploy/appserver-core -- grep -A3 WEBAGENT appserver.ini` deve mostrar a
   seção preenchida. Se aparecer vazia logo após uma recriação simultânea do zero, é a condição
   de corrida já documentada — um `kubectl rollout restart deployment appserver-core` resolve
   (não afeta uso normal, só a janela entre a criação inicial do sidecar e do core). Nota: o
   `docker-protheus-appserver` republicou sob a mesma tag `24.3.1.9` com esta mudança — digest
   novo (`ddea2ad5...`), o Image Updater já propagou pro cluster sozinho.

**Item 0 do backlog fechado** (validação ao vivo do Compose nas tags novas — passos 8–9 de
`docs/prompts/atualizar-tags-compose.md`, no repo `docker-protheus-devops-stack`). Antes disso,
corrigido o desvio da checklist herdado da sessão anterior: o `protheus_dbaccess` tinha voltado
sozinho no boot desta manhã, degradado (sem rede anexada, loop de `nc` sem resolver
`protheus_postgres`) — causa raiz real documentada na regra operacional nova abaixo, não era a
policy `unless-stopped`. `docker stop protheus_dbaccess` (com ele rodando) resolveu.

Como o próximo passo ia subir a stack Compose de propósito, e ela disputa a porta `7890` do host
com o `serverlb` do k3d (mesma colisão do boot de 17/09), a decisão do usuário ("cluster é
prioridade") foi aplicada de forma permanente: `dbaccess` do Compose agora publica em `7891` no
host (`DBACCESS_HOST_PORT`, default `7891` em `docker-compose.yaml`), mantendo `DBACCESS_PORT`
(7890) intacto como porta interna — nenhum appserver percebe diferença, todos falam com
`protheus_dbaccess:7890` pela rede `protheus_network`. Commit `18bb275` no
`docker-protheus-devops-stack`. Isso tirou a urgência do mapeamento inerte da 7890 no `serverlb`
— e o mapeamento em si foi removido de vez em 2026-09-18 (ver "Onde paramos" no topo).

Gate de bootstrap respeitado: antes de subir o `core`, banco contado isoladamente (53 tabelas
`SYS_*` — base já populada, não era base nova) via `postgres_db` sozinho, só então `./run.sh
postgres`. Validado ao vivo: os 6 containers subiram limpos nas tags novas (confirmado via
`docker ps` — `appserver-dev:24.3.1.9`, `license-dev:3.7.2`), `protheus_dbaccess` e
`protheus_license` `healthy`, `protheus_core` log interno
(`/totvs/protheus/log/appserver_core.log`) confirmou `Totvs Application Server is running` em
13.36s sem erro fatal e sem pedido de bootstrap (o único warning, `OPEN EMPTY RPO`, é esperado —
`custom.rpo` do Compose começa vazio até um compile local, ambiente separado do cluster). Cluster
k3d conferido depois, sem impacto: `Synced`/`Healthy`, sem restarts novos. Stack local parada de
volta (`docker compose stop`, todos os 6, incluindo `postgres_db` que tinha sido subido à parte)
ao encerrar a validação — não fica no ar.

**Achado sobre o log do appserver**: `appserver_core.log` (e provavelmente os outros do
AppServer) é um arquivo pré-alocado — o conteúdo real fica intercalado com bytes nulos de
padding, não é texto puro sequencial. `tail`/`grep` direto no arquivo retorna majoritariamente
padding (`\0`) e pode estourar limite de output em ferramentas que capturam texto. Ler com
`tr -d '\000' < arquivo | tail -c N` (descarta os nulos antes de cortar) — `docker logs` do
container não serve aqui, o entrypoint não propaga o log do `appsrvlinux` pro stdout do
container além do banner inicial.

**Item 5 do backlog fechado**: `README.md` estava parado na Fase B — não mencionava
`protheus-seed.yaml` (Fase C), `appserver-core`/`-rest`/`-telnet` (Fase D) nem os Jobs
`worker`/`compile`/`upddistr` (Fase E), e ainda citava `base/appserver.yaml` como
"incompleto/WIP" (removido em 2026-09-17, substituído pelos três manifestos reais, que já
montam `webapp-shared`/`printer-shared` read-only — a lacuna que o texto antigo apontava já
estava fechada, só não registrada). Diagrama Mermaid ganhou as camadas de seeds e AppServer;
seção de GitOps atualizada com a lista real de imagens rastreadas pelo Image Updater
(`appserver-dev` e os 3 seeds faltavam) e o achado do `writeBackConfig`; nova seção linkando
`docs/HANDOFF.md`, `docs/adr/`, `scripts/k3d-nodes/`, `scripts/appserver-patch/` e
`docs/prompts/` — nenhum tinha menção no README antes. Commit `fded313`.

**Item 1 do backlog aprofundado (nomes exatos dos zips de `includes`)**: busca no disco (não só
no handoff) achou o zip real da revisão nova do `advpl` já baixado
(`~/Downloads/26-08-07-P12_INCLUDES.ZIP`, 157 arquivos) — a revisão em uso não existe mais sob o
nome original, só extraída. Pro `tlpp`, achado novo que não fecha a questão mas avança: os 6
`tlpp-*.th` em uso são idênticos byte-a-byte aos de
`/media/rodrigo/dados/totvs/protheus/2410/includes/` (instalação local antiga do Protheus 24.10),
mas isso é só de onde foram copiados — não é o pacote TOTVS de origem, e não é o mesmo
`P12_INCLUDES.ZIP` do advpl (que tem `.th` só que prefixados `fw-tlpp-*`, schema diferente).
Origem do `tlpp` continua aberta. Detalhe completo no item 1 do backlog abaixo.

**`webagent` adicionado ao backlog (item 3)** a pedido do usuário — componente novo
(`docker-protheus-webagent` não existe ainda), artefato já baixado desde 02/07
(`~/Downloads/26-07-02-P12_SMARTCLIENT_WEB-AGENT_1.1.1_LINUX_X64.TAR.GZ`) mas sem nenhum
trabalho de containerização começado.

**Item 1 do backlog implementado (`docker-protheus-includes`)**: decisão tomada com o usuário —
seed **efêmero**, não Deployment em standby como rpo/system/systemload. Achado que motivou o
desenho: `code_compiler.sh` (dentro do `appserver-dev-worker`) já re-extrai os dois
`includes.zip` do zero a cada `compile`, então o volume nunca precisou ser persistente — só
entregar os dois `.zip` no lugar certo, uma vez por execução do Job. Detalhe completo e
alternativas descartadas em `docs/adr/0010-includes-seed-efemero-initcontainer.md`.

Implementado: repo `docker-protheus-includes` criado do zero
(Dockerfile/entrypoint/CI/.gitignore, seguindo o padrão dos outros seeds) e publicado —
`github.com/rodrigomicrosiga-devops/docker-protheus-includes` (privado, branch `develop`,
commit `1d4b8d0`). Versionamento **próprio** (semver `0.0.1`), não a
release do Protheus — o `P12_INCLUDES.ZIP` é publicado à parte no portal TOTVS, sem relação com o
calendário de release (a revisão em uso é de 26/06 e já existe uma mais nova de 07/08, sem a
release `12.1.2510` ter mudado). Zips não versionados no repo (`.gitignore`), CI resgata do disco
do runner self-hosted a partir de `docker-protheus-devops-stack/protheus/includes/`.

No cluster: `appserver-compile-job.yaml` ganhou um `initContainer` novo (`seed-includes`, roda
depois do `prepare-volumes` já existente) que copia os dois zips pra dentro do volume
`protheus-includes` — que deixou de ser PVC/PV com hostPath e virou `emptyDir`.
`protheus-includes-pv`/`-pvc` removidos de `base/protheus-patch-storage.yaml` (diretório antigo
no host, `/media/rodrigo/dados/k8s-volume/protheus-includes/`, fica órfão, não foi limpo). Sem
marcador de idempotência (não se aplica — conteúdo estático) e sem rastreamento pelo Image
Updater (mesma razão do `appserver-dev-worker`: a `compile-job` fica fora do Kustomize, tag
bumpada manualmente). `scripts/appserver-patch/README.md` atualizado — o passo de depósito
manual dos includes não existe mais.

**Validado de ponta a ponta, mesmo dia**. Usuário configurou `DOCKERHUB_USERNAME`/
`DOCKERHUB_TOKEN` no repo novo (token do Docker Hub recriado — o original tinha sido perdido,
nunca é recuperável, nem em secrets do GitHub nem em tokens do Docker Hub, por design). Esclarecido
de passagem: repo privado + Actions secrets sempre funcionaram normalmente em qualquer plano —
não existe restrição alguma aí; o único limite real do plano gratuito (minutos de runner
*hospedado pelo GitHub* em repo privado) nunca chegou a se aplicar, porque todo o fleet usa
`runs-on: self-hosted` (a própria máquina do usuário, já registrada como runner desde antes deste
repo, confirmado com um run antigo de sucesso em `docker-protheus-rpo`).

O run inicial (do push do commit `1d4b8d0`) tinha falhado no login do Docker Hub, como esperado
sem secrets — `gh run rerun` depois de configurados os secrets, sucesso em 41s.
`rodrigomicrosiga/protheus-includes-dev:0.0.1` confirmada publicada via `docker manifest
inspect`.

`run-job.sh compile` rodado duas vezes com fonte real (fornecido pelo usuário,
`teste-devops.prw`, usa `#include 'totvs.ch'`) — nas duas, `Extraindo includes [advpl]`/
`[tlpp]` e `ADVPL Preprocessor: Precompilation... ok`, confirmando que o `initContainer
seed-includes` funciona. Nenhuma das duas terminou com sucesso total: a primeira tentativa
tinha um `teste.prw` antigo (de 17/09) ainda na fila junto, colidindo por nome de função
(`U_TESTE`) com o fonte novo — removido, segunda tentativa rodou só com `teste-devops.prw`, mas
a mesma função já estava gravada no `custom.rpo` desde a compilação de 17/09, então o compilador
rejeitou de novo (`Duplicated function`, correto — o RPO customizado é incremental, não é bug).
Rollback automático confirmado nas duas vezes: hash do `custom.rpo` inalterado
(`b390e7ce...`), `appserver-core`/`rest`/`telnet` religados sozinhos pelo `run-job.sh`,
`Synced`/`Healthy` depois. Decisão registrada com o usuário: dar a infra por validada sem
insistir num `compile` 100% verde agora — a parte que importava (entrega dos includes) já está
provada; um `compile` limpo fica pro próximo fonte real sem colisão de nome. Detalhe completo em
`docs/adr/0010-includes-seed-efemero-initcontainer.md` (status atualizado).

**Item 2 do backlog fechado (cofre local pro `postgres-secret.env`)**: avaliado o risco real
antes de agir (cluster local, single-dev, senha já documentada como default no `CLAUDE.md`) —
usuário escolheu criptografia em repouso, não rotação nem aceitar-e-documentar sem mudança.
`base/postgres-secret.env` (plaintext, sem backup até então) criptografado com GPG simétrico
AES256, round-trip verificado por hash (nunca exibindo o conteúdo), plaintext removido do disco
depois. `base/postgres-secret.env.gpg` é o novo backup versionado; `scripts/secrets/`
(`encrypt.sh`/`decrypt.sh`, genéricos) documentam o fluxo — os dois pedem a passphrase
interativamente, nunca por argumento/env, então não são algo que uma sessão automatizada roda
sozinha. Passphrase gerada (`openssl rand -base64 32`) e entregue uma única vez ao usuário nesta
sessão — não fica retida em lugar nenhum além do gerenciador de senhas dele. Confirmado que os
outros 3 segredos selados (`smartview`, `appserver-upddistr`, `regcred`) não têm cópia plaintext
no disco — só o Postgres tinha esse problema. Detalhe completo em
`docs/adr/0011-cofre-local-gpg-secrets-plaintext.md`.

**Item 3 (antigo) do backlog fechado — recriação de `postgres-pv`/`webapp-shared-pv`/
`printer-shared-pv` com `nodeAffinity`** (ADR 0004 quitado, procedimento completo no ADR 0012).
Usuário confirmou que não há dado de produção em risco — decisão de recriar de verdade, não só
documentar. Linha de base capturada antes de mexer (171 tabelas no Postgres, hash de
`webapp.so`/`printer`); pausa via git dos 6 consumidores; `kubectl delete` do PVC+PV (dado no
hostPath preservado por `persistentVolumeReclaimPolicy: Retain`); `nodeAffinity` declarada no
git; delete de novo (o `selfHeal` já tinha recriado do manifesto antigo antes do push — corrigido
deletando outra vez); réplicas restauradas via git. Validação final idêntica à linha de base:
171 tabelas, hashes de `webapp.so`/`printer` inalterados, 0 restart novo em qualquer outro
componente do namespace.

**Sessão real, não sem atrito** — um `kubectl annotate ... refresh=hard` desnecessário forçou uma
sincronização completa do Argo CD, que reativa **todos** os hooks `PreSync` (ADR 0003), e criou
uma dependência circular real: o hook `smartview-db-init` esperava o Postgres, que só seria
aplicado depois do hook — e o Postgres estava pausado de propósito. Destravado com uma sequência
de recuperação (terminar a operação travada, remover finalizer preso no Job do hook, aplicar
`postgres.yaml` diretamente pra tirar o Postgres do zero-réplicas, corrigir o `envFrom` do
ConfigMap com hash que o apply direto não reescreve) até o hook conseguir completar sozinho e o
Argo CD terminar a sincronização normalmente. Nada disso afetou os outros componentes do cluster
(dbaccess/license/smartview/seeds com os mesmos restarts de antes) nem os dados reais (Retain
protegeu os 3 hostPaths pelos dois ciclos de delete+recreate). Tudo documentado em detalhe no ADR
0012 ("Obstáculos reais enfrentados") — previsão confirmada na prática, mesmo dia: o drill do
cluster do zero (item 3 de então, fechado nesta mesma sessão — ver ADR 0013) bateu exatamente
nesse tipo de problema, só que com `postgres-secret` no lugar do Postgres em si.

**Item 4 (antigo) do backlog fechado — porta `7890` removida do `serverlb`**: k3d tem suporte
nativo (experimental) pra editar port mappings de um cluster já existente sem recriar
server/agent — `k3d cluster edit protheus-cluster --port-delete 7890:7890@loadbalancer` (o
`@loadbalancer` como nodefilter é obrigatório, senão falha com "No nodefilters specified"). Sob
o capô, o k3d renomeia o `serverlb` antigo, cria um novo sem o mapeamento, para o antigo e apaga
— tudo automatizado pela própria ferramenta, ~17s, zero downtime pros nodes `server-0`/`agent-0`
(não tocados) e zero restart nos pods do namespace `protheus-devops` (confirmado depois:
`appserver-core`/`rest`/`telnet`/`postgres`/`webapp`/`printer` seguiram com os mesmos 0 restarts
de antes da operação). Único porto aberto no `serverlb` agora: `6443` (API do k8s). **Não é uma
mudança persistida no git** — é estado do container Docker do k3d, fora do que `base/`/
`scripts/k3d-nodes/` gerenciam (o próprio `scripts/k3d-nodes/README.md` já registrava que o
`serverlb` não é recriado por aqueles scripts). Confirmado no drill do cluster do zero (mesma
sessão, ver abaixo): a receita nova (`scripts/cluster-bootstrap/00-create-cluster.sh`) já nasce
sem a porta 7890 desde o primeiro `k3d cluster create`, então essa remoção não precisou ser
repetida manualmente.

**Item 3 (antigo) do backlog fechado — drill completo de recriar o cluster do zero, executado ao
vivo** (ADR 0013). Usuário optou por fazer o drill de verdade, não só documentar a receita.
Inventário prévio: `helm list -A` + `helm get values` recuperaram os `values.yaml` reais dos 7
componentes instalados fora do Kustomize direto do storage do Helm — não precisou reconstruir de
memória. Dois com credencial em texto plano (`kube-prometheus-stack`: senha do Grafana;
`minio`/`velero`: credenciais do MinIO) foram pro cofre GPG do ADR 0011, os outros 4 sem segredo
foram versionados direto. A chave do `sealed-secrets` (2 chaves ativas por rotação) foi
backupeada e criptografada da mesma forma — sem ela, os 4 `SealedSecret` já commitados
(`postgres-secret`, `smartview-secret`, `regcred`, `appserver-upddistr-secret`) nunca mais
decriptariam num cluster novo. `pg_dump` de segurança feito antes, por barato, mesmo o hostPath
de dados reais (`/media/rodrigo/dados/k8s-volume/`) sendo físico do host e sobrevivendo a
`k3d cluster delete` por natureza (confirmado na prática).

Achado real antes de escrever qualquer script: `k3d cluster create` **não tem flag nativa pra
`--cgroupns host`** — a receita precisou de duas fases (criar cluster normal, depois recriar os
2 containers de node com o fix, generalizando a lógica de `scripts/k3d-nodes/`/ADR 0008 pra
descobrir volumes/env/labels dinamicamente via `docker inspect`, já que uma receita "do zero" não
pode depender de IDs de volume fixos de um cluster que já não existe mais).

Drill executado: `k3d cluster delete protheus-cluster` de verdade, seguido da receita completa
(`scripts/cluster-bootstrap/00` a `04`). **Sucesso total**, validado contra a linha de base
capturada antes de destruir: 171 tabelas no Postgres (idêntico — o Postgres achou o data
directory existente no hostPath sobrevivente e fez recovery automático de WAL, não precisou do
`pg_dump`), hash do `tttm120.rpo`/`custom.rpo` idênticos, os 4 `SealedSecret` decriptados
corretamente com as chaves restauradas, 2 nodes `Ready` com `cgroupns=host`, `serverlb` sem a
7890 desde o nascimento, e todos os 12 pods de `protheus-devops` + Falco + monitoring + Velero/
MinIO no ar, `Synced`/`Healthy`.

Dois achados reais **só descobertos ao executar de verdade** (motivo de valer a pena ter feito o
drill ao vivo, não só a receita em teoria):
1. **Dependência circular nova**: o hook `PreSync` `smartview-db-init` depende de
   `postgres-secret`, que é `SealedSecret` comum de `Sync`, não hook — nunca existe a tempo num
   bootstrap genuinamente do zero (no cluster antigo nunca apareceu porque `postgres-secret` já
   existia desde 26/07). Desbloqueado com o mesmo padrão do ADR 0012 (`kubectl apply -f` direto
   nos recursos que faltavam). **Não corrigido no manifesto** — fica como follow-up real (mover a
   dependência do hook, ou remover), registrado no ADR 0013.
2. **Nodes recriados nascem com o mount raiz em propagação `private`**, quebrando o
   `prometheus-node-exporter` (que monta `/` do node). Não é algo visível via `docker inspect` —
   é como o k3d cria containers internamente, não replicável 1:1 por `docker run` puro. Corrigido
   ao vivo (`mount --make-rshared /`) e **já incorporado no `01-fix-cgroupns.sh`** — o próximo
   drill não precisa mais do passo manual.

Detalhe completo (passo a passo real, achados, follow-ups) em
`docs/adr/0013-cluster-bootstrap-do-zero.md` e `scripts/cluster-bootstrap/README.md`.

**Item 3 (`webagent`) fechado — último item do backlog original, implementado de ponta a ponta**
(ADR 0014). Usuário explicou o requisito: WebAgent é utilitário client-side (dá ao SmartClient
HTML acesso a disco/arquivo local do usuário), e recusou de propósito a opção de auto-download
via `appserver.ini` que exigiria embutir o instalador de cada SO dentro da imagem do AppServer
("não gostaria de fazer" — imagem ficaria pesada). Pedido de sugestão levou a uma investigação
completa: PDF oficial da TOTVS (25 páginas, lido integralmente) confirmou que `[WEBAGENT]` aceita
caminho relativo ao diretório do AppServer, não URL — abrindo espaço pra reusar exatamente o
mecanismo que `webapp.so` já usa (sidecar + volume compartilhado + cópia local pelo entrypoint),
sem tocar na imagem principal.

Implementado: repo novo `docker-protheus-webagent` (público, só Linux x64 por enquanto — o
`.tar.gz` oficial já traz `.deb`+`.rpm`, verificado direto no arquivo antes de perguntar ao
usuário); `docker-protheus-appserver/entrypoint.sh` ganhou detecção dinâmica de arquivo (não fixa
nome/versão) pra gerar `[WEBAGENT]`; Compose (`protheus_webagent`, `run.sh` atualizado) e k8s
(`base/webagent.yaml`, PV com `nodeAffinity` desde o nascimento, registrado no Image Updater) —
sequência deliberada, Compose primeiro (confirmado com o usuário, segue o padrão já usado pro
AppServer nas Fases A-E), só depois k8s.

Validado ao vivo nos dois: `appserver.ini` com a seção `[WEBAGENT]` correta e os dois instaladores
no lugar certo, boot limpo, nenhum outro componente afetado, 171 tabelas intactas. Achado real no
k8s (não hipótese): numa subida simultânea do zero, `appserver-core` pode gerar o `.ini` antes do
sidecar `webagent` terminar de provisionar — mesma condição de corrida que já existe
silenciosamente pra `webapp`/`printer` (o entrypoint só roda uma vez, não observa o volume depois
do boot), não é regressão nova. Resolvido com `kubectl rollout restart`, e na prática irrelevante
fora de um teste imediato pós-subida.

Usuário perguntou se valeria já baixar os instaladores de Windows/macOS enquanto estava nisso —
recomendação dada foi não fazer sem um artefato real pra testar (o `Dockerfile` só extrai
`.tar.gz`, Windows/macOS vêm como `.zip`, e as chaves `Windows_x86`/`Windows_x64` são ambíguas
por extensão, só distinguíveis pelo nome do arquivo — escrever essa lógica sem um arquivo real
pra validar seria repetir o tipo de suposição não-testada que este projeto tem evitado o tempo
todo). Arquitetura já preparada pra crescer sem redesenho quando houver necessidade real — ver
README do `docker-protheus-webagent`.

**WebAgent estendido pra multi-SO** (mesmo dia, rodada seguinte): usuário já tinha baixado os
pacotes de Windows (x86/x64) e macOS (Universal + x64) e colocado no diretório do repo
`docker-protheus-webagent`. `Dockerfile` reescrito pra extrair `.zip`/`.dmg` além de `.tar.gz`
(builder multi-estágio com `find -iname` por padrão, não nome fixo); `.gitignore` corrigido
**antes** do primeiro `git add` pra cobrir `*.ZIP`/`*.DMG` além de `*.TAR.GZ` (só cobria
`.tar.gz` até então — pego a tempo, ~165MB de binário proprietário não chegou a ir pro git);
workflow de CI reescrito pra resgatar todos os formatos de até 3 diretórios candidatos.
`docker-protheus-appserver/entrypoint.sh` ganhou detecção das 5 chaves (`Windows_x86`,
`Windows_x64`, `Darwin_universal`, `Linux_x64_deb`, `Linux_x64_rpm`) via `find -maxdepth 1
-iname`, preferindo o `.dmg` com `universal` no nome quando mais de um está presente. Os
`.msi` (fluxo de distribuição via GPO/Active Directory, documentado na Central de Downloads como
pacote separado) são entregues no volume mas de propósito **não** entram no `.ini` — não existe
chave documentada pra eles, e o fluxo de auto-download do WebApp não usa MSI.

Validado ao vivo só no Compose, com as imagens reais publicadas (`webagent-dev:1.1.1`
`sha256:dcf39033...`, `appserver-dev:24.3.1.9` `sha256:8a7ed2af...`): `.ini` gerado com as 5
chaves corretas, todos os arquivos no volume compartilhado, boot limpo. Tentativa de confirmar a
mesma coisa no k8s esbarrou num achado novo e maior — ver "Onde paramos" no topo (item 2): o
`argocd-image-updater` está sem autenticação no Docker Hub e sendo rate-limited como cliente
anônimo, afetando a frota inteira, não só este componente. Cluster permanece estável rodando os
digests anteriores (funcionais, só sem o multi-SO) até esse achado ser resolvido.

## Histórico condensado da sessão de 2026-09-18, parte 1

Retomada do handoff de 17/09. Item 0 do backlog (atualização de binários TOTVS) fechado no lado
k8s — era o que faltava de fato; os passos 1 (repos irmãos) e 2 (Compose) já tinham sido
adiantados na sessão anterior sem o handoff ter sido atualizado antes do reboot.

**Higiene do boot**: os 6 containers do Compose (`protheus_core`/`postgres`/`license`/`webapp`/
`printer`/`dbaccess`) voltaram sozinhos neste boot apesar do fix `unless-stopped` já commitado
(`2c674b9`, sessão anterior) — a policy de restart fica gravada no container no momento em que
ele é criado, não é relida do `docker-compose.yaml` a cada boot; nenhum dos 6 tinha sido
recriado desde o commit. Efeito real: o `serverlb` do k3d venceu a corrida pela porta `7890` (já
prevista como risco no handoff anterior) e o `protheus_dbaccess` morreu (`Bind for :::7890
failed: port is already allocated`); o `protheus_core` ficou desde então girando em loop de
`nc` esperando o dbaccess, sem nunca subir o `appsrvlinux` (não chegou a haver risco de
bootstrap). Decisão do usuário: **no boot, o cluster é a prioridade** — a stack Compose não deve
subir sozinha. Fix aplicado: `docker update --restart unless-stopped` nos 6 containers vivos (sem
recriar) + `docker stop` neles.

**Correção registrada em 2026-09-18 (parte 2)**: o fix acima não foi suficiente — no boot
seguinte (mesmo dia, de manhã) o `protheus_dbaccess` voltou sozinho de novo, apesar de
`unless-stopped` confirmado gravado nele. Causa raiz real, diferente do que se supôs aqui: o
`docker stop` da sessão anterior foi um no-op nele, porque ele **já estava parado por falha**
(a colisão de porta descrita acima) — `unless-stopped` só pula um container que foi **parado
manualmente**, e um container que morre por falha não conta como isso. Ver regra operacional
nova abaixo. A colisão de porta em si foi resolvida de vez na mesma sessão (não mais "inerte,
ver backlog"): `dbaccess` do Compose passou a publicar em `7891` no host — ver item 0 do backlog
fechado, seção "Onde paramos" no topo.

**Binários TOTVS — item 0 fechado no k8s**: confirmado que a `Application` usa `writeBackConfig:
argocd` — o Image Updater grava o digest resolvido como override em
`spec.source.kustomize.images`, e esse override **vence o que está no git**. Um bump só em
`base/*.yaml` não teria efeito nenhum sozinho; era preciso editar também
`argocd/image-updater.yaml` e reaplicá-lo. Achado novo, registrado nas regras operacionais
abaixo. Editado (tags confirmadas publicadas via `docker manifest inspect` antes de escrever):
`appserver-dev` 24.3.1.5→**24.3.1.9** (core/rest/telnet/upddistr), `appserver-dev-worker`
24.3.1.5→**24.3.1.9** (worker/compile), `license-dev` 3.7.1→**3.7.2** — nos manifestos do
Kustomize e nos 3 Jobs deliberadamente fora dele (ADR 0009), mais os aliases `appserver`/
`license` do `image-updater.yaml`. Commit `6f54252`, push, `kubectl apply -f
argocd/image-updater.yaml`, ciclo do Image Updater reescreveu os overrides
(`images_updated=2`), Argo CD sincronizou sozinho: `Synced`/`Healthy`, `appserver-core`/`rest`/
`telnet`/`license` com pods novos, 0 restarts. Confirmado depois: hash do RPO inalterado
(`9e8d81d8…`, mesmo do patch "onça pintada"), 54 tabelas `SYS_*` intactas.

**Pendência que fica registrada, não esquecida**: o Compose nunca foi de fato recriado com as
tags novas (`appserver-dev`/`appserver-dev-worker` 24.3.1.9, `license-dev` 3.7.2) — o commit
`2cfd5d8` da sessão anterior só editou o `docker-compose.yaml`, "a pedido, sem subir a stack".
Os containers locais pararados nesta sessão continuam nas imagens antigas. Rodar
`docs/prompts/atualizar-tags-compose.md` (passos 8–9, validação ao vivo) quando fizer sentido —
não é bloqueante pra nada no cluster.

**Item 1 do backlog (`includes.zip` sem repo/governança) — investigado, não implementado**:
consumidor real é `docker-protheus-appserver-worker/code_compiler.sh:26-49` — cada zip
(`advpl`/`tlpp`/`custom`) é extraído pra um diretório real antes do compile, porque a resolução
de `#include` aninhado dentro do próprio zip é case-sensitive e falha (`File not found
PRTOPDEF.CH`) se lido direto do zip. Origem confirmada do `advpl`: é um pacote `P12_INCLUDES.ZIP`
do portal TOTVS, mesmo padrão de nomenclatura dos demais binários — o que está em uso hoje (155
arquivos, jun/29) é uma revisão anterior à disponível em downloads (`26-08-07-P12_INCLUDES.ZIP`,
157 arquivos). Origem do `tlpp` (`.th` de 2025-06-02) segue não identificada. `custom` é ponto de
injeção do próprio dev, vazio por design, não é artefato TOTVS. Decisão de criar (ou não) um
`docker-protheus-includes` seguindo o padrão de seed image (rpo/system/systemload) fica em aberto
pro usuário — ver backlog.

**Estado ao encerrar a sessão de 2026-09-18**:
- **Compose**: todos os 6 containers `Exited` (parados nesta sessão, passo A). Não devem voltar
  sozinhos no próximo boot (`unless-stopped` já aplicado nos containers vivos, não só no
  arquivo).
- **Cluster k3d**: no ar, `Synced`/`Healthy`, appserver-core/rest/telnet e license confirmados em
  24.3.1.9/3.7.2 com 0 restarts.
- **Nada em voo**: os 2 commits desta sessão (`6f54252` bump de imagens, `31644bb` este handoff)
  já têm `push` pra `origin/develop`. Sem trabalho local não commitado.

## Histórico condensado da sessão de 2026-09-17

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

**Atualização de binários TOTVS — em andamento** (mesmo dia, depois da Fase E fechada). Dois
prompts reutilizáveis criados em `docs/prompts/`, pensados pra colar sem editar (autodescobrem
o artefato pela raiz do repo via mtime + glob do Dockerfile, não por um caminho digitado):
- `atualizar-versao-binario-totvs.md` — roda dentro de cada `docker-protheus-*`.
- `atualizar-tags-compose.md` — roda depois, dentro do `docker-protheus-devops-stack`, sincroniza
  o `docker-compose.yaml` com o que os repos irmãos já publicaram.

**3 de 5 repos já atualizados e publicados no Docker Hub** (confirmado via
`docker manifest inspect`): `license-dev` 3.7.1→**3.7.2**, `appserver-dev` 24.3.1.5→**24.3.1.9**,
`appserver-dev-worker` 24.3.1.5→**24.3.1.9**. Faltam `dbaccess-dev` e `webapp-dev`/`printer-dev`
(usuário ainda não rodou o prompt nesses). `docker-compose.yaml` **ainda não foi atualizado** —
continua nas versões antigas em todas as ocorrências (confirmado, `grep -n
"image: rodrigomicrosiga"`). `webagent` segue fora de escopo (componente novo, sem repo).

**Achado novo**: o pacote de `includes.zip` (advpl/tlpp, necessário pro `compile`) **não tem
repo nenhum e não tem seed image** — diferente de RPO/system/systemload (que têm
`docker-protheus-{rpo,system,systemload}` dedicados). É `*.zip` no `.gitignore` do
`docker-protheus-devops-stack` sob "TRAVA DE GOVERNANÇA" (mesmo tratamento de `.rpo`/`.ptm`,
nunca vai pro git), e os arquivos que existem em `protheus/includes/{advpl,tlpp}/` datam de
jun/jul de 2026 — nunca foram versionados nem re-obtidos desde então, e a origem exata (SDK do
TDN? instalador do AppServer? outro pacote?) não está documentada em lugar nenhum. Registrado
como item novo do backlog (ver abaixo) — pergunta em aberto pro usuário.

**Próximo passo definido no fim desta sessão (17/09)**: retomar o item 0 pelo lado k8s depois de
resolver o boot — executado e fechado na sessão seguinte (18/09, ver "Onde paramos" no topo).

## Backlog aberto, por prioridade

1. **`docker-protheus-includes` — implementado E validado em 2026-09-18**: repo criado
   (`github.com/rodrigomicrosiga-devops/docker-protheus-includes`, privado), CI publicou
   `protheus-includes-dev:0.0.1` no Docker Hub, cluster alterado (`appserver-compile-job.yaml`)
   e validado ao vivo com `run-job.sh compile` (duas execuções, `initContainer seed-includes`
   entregou os zips corretamente nas duas, `code_compiler.sh` extraiu e resolveu `#include`
   sem erro). Ver "Onde paramos" no topo e ADR 0010 pro desenho completo (seed efêmero via
   `initContainer` + `emptyDir`, não Deployment em standby). Pendências residuais, menores:
   - Nenhum `compile` real terminou com `Errors(0)` ainda — o fonte de teste usado colidia com
     uma função já existente no `custom.rpo` (`U_TESTE`, de uma compilação de 17/09), rejeição
     correta do compilador, não falha do include. Resolve sozinho no próximo `compile` com fonte
     sem colisão de nome — não é uma pendência de infraestrutura.
   - **Governança de atualização fechada com o usuário em 2026-09-18**: `advpl` — o usuário
     mesmo baixa a revisão nova via portal TOTVS sempre que houver uma; `tlpp` — atualizado
     sempre que a TOTVS liberar algum binário com versão nova do TLPP pra extrair (não existe um
     pacote standalone pra ele, ao contrário do `advpl` — confirma por que a origem nunca foi
     encontrada como zip separado: não é um download direto, é extraído de dentro de outro
     artefato); `custom` — só existe quando o usuário estiver desenvolvendo algo exclusivo, fica
     vazio o resto do tempo (já era o desenho do repo, agora confirmado como política, não só
     placeholder). Fluxo de aplicação (bump de versão) documentado no README do
     `docker-protheus-includes`. Revisão nova do `advpl` já baixada
     (`~/Downloads/26-08-07-P12_INCLUDES.ZIP`, 157 arquivos) fica disponível pro usuário aplicar
     quando ele decidir — não é mais uma pendência de investigação, é rotina normal do processo.
2. **Segurança — fechado em 2026-09-18**: `base/postgres-secret.env` (plaintext do
   `postgres-secret` selado) passou a ter backup cifrado com GPG simétrico
   (`base/postgres-secret.env.gpg`, versionado) em vez de existir só como arquivo puro sem
   backup no disco. `scripts/secrets/encrypt.sh`/`decrypt.sh` (genéricos, reusáveis pra outros
   segredos), passphrase gerada e entregue só ao usuário (guardada no gerenciador de senhas
   dele, nunca no repositório). Rotação de senha descartada como escopo deste item — mudaria
   Compose e k8s juntos (mesma senha nos dois, por decisão deliberada), reabrindo a
   padronização de 16/09 sem motivo novo. Detalhe completo em
   `docs/adr/0011-cofre-local-gpg-secrets-plaintext.md`.
3. ~~**`webagent` (SmartClient Web-Agent)**~~ — **fechado em 2026-09-18** (ADR 0014). Implementado
   e validado ao vivo nos dois ambientes:
   - Repo novo `docker-protheus-webagent` (público, `webagent-dev:1.1.1`, hoje só Linux x64 —
     o `.tar.gz` oficial já traz `.deb`+`.rpm`).
   - `docker-protheus-appserver/entrypoint.sh` ganhou o mesmo tratamento já dado ao `webapp.so`:
     copia os arquivos do volume compartilhado e gera `[WEBAGENT]` no `appserver.ini` com
     detecção dinâmica de arquivo (sem fixar nome/versão).
   - **Compose**: `protheus_webagent` novo, montado em `core`/`rest`/`telnet`, `run.sh` com
     suporte nos mesmos pontos de `webapp`/`printer`. Validado: `.ini` correto, boot limpo.
   - **k8s**: `base/webagent.yaml` (PV com `nodeAffinity` desde o nascimento), montado nos 3
     appservers, registrado no Image Updater. Validado: `Synced`/`Healthy`, 171 tabelas
     intactas.
   - **Achado real**: numa subida simultânea do zero, `appserver-core` pode gerar o `.ini` antes
     do sidecar terminar de provisionar (mesma condição de corrida silenciosa que já existe pra
     `webapp`/`printer`, não é bug novo) — resolve com um restart, irrelevante em uso real.
   - **Windows/macOS — implementado e validado em rodada seguinte, mesmo dia, agora incluindo
     k8s**: usuário forneceu os artefatos reais (Windows x86/x64 `.zip`, macOS Universal/x64
     `.dmg`). `Dockerfile` estendido pra extrair `.zip`/`.dmg`, `entrypoint.sh` do `appserver`
     detecta as 5 chaves dinamicamente (`Windows_x86`/`Windows_x64`/`Darwin_universal`/
     `Linux_x64_deb`/`Linux_x64_rpm`), `.msi` entregue no volume mas de propósito fora do `.ini`
     (fluxo GPO separado, sem chave documentada). Validado ao vivo em Compose e k8s com imagens
     reais publicadas — cluster mostrou as 5 chaves corretas em `appserver.ini` depois de um
     `kubectl rollout restart` (ver item 4 abaixo, mesma corrida sidecar-vs-core já conhecida).
4. **`argocd-image-updater` sem autenticação no Docker Hub — fechado de ponta a ponta em
   2026-09-18** (código no commit `fe6e83d`, ação do usuário concluída na sessão seguinte):
   `scripts/cluster-bootstrap/helm-values/argocd-image-updater.yaml` referencia
   `credentials: secret:argocd/dockerhub-creds#creds`; usuário criou o Secret com credencial real
   e rodou `helm upgrade`. Confirmado ao vivo: `argocd-image-updater-controller` (revision 2 do
   release) processou cache warm-up limpo (`images_considered=11 images_skipped=0 errors=0`),
   zero `toomanyrequests` nos logs. O digest `e87ee71e...` do `webagent-dev:1.1.1`, que eu tinha
   marcado como suspeito/inconsistente na rodada anterior, era na verdade correto — validado
   direto contra a API do Docker Hub (`docker-content-digest` bate exato); não era bug do Image
   Updater, só não tinha revalidado depois de outro rebuild. Efeito colateral confirmado: os
   pods já estavam rodando os digests multi-SO certos, mas `appserver-core` tinha subido ~90s
   antes do sidecar `webagent` terminar de extrair os 8 arquivos — resolvido com `kubectl
   rollout restart deployment appserver-core appserver-rest appserver-telnet`. `Application`
   `Synced`/`Healthy`, 171 tabelas intactas, `[WEBAGENT]` com as 5 chaves confirmado via `kubectl
   exec deploy/appserver-core -- grep -A8 WEBAGENT appserver.ini`.

## Regras operacionais já validadas (não reabrir sem motivo novo)

- **`base/postgres.env`: `POSTGRES_DB`/`POSTGRES_USER` têm que ser `postgres`, nunca `protheus`.** O init da imagem (`docker-postgres-protheus`) só cria o banco em WIN1252 (exigência do Protheus) se ele ainda não existir; com `POSTGRES_DB=protheus` o entrypoint oficial o criava antes, em UTF8. `DB_USER`/`DB_NAME` seguem `protheus`. Achado e correção de 2026-09-19 (ADR 0015).
- **O classificador de segurança bloqueia `rm`/wipe destrutivo do assistente mesmo com autorização explícita do usuário** — não contornar; preparar o comando exato e pedir pro usuário rodar via `!`. Pausar serviços via git (`replicas: 0`) e reinicializar o Postgres (o container se recupera sozinho depois de o data dir ser apagado, sem precisar de `replicas: 0` no próprio Postgres, o que evita a dependência circular do hook `PreSync`) continua sendo o caminho.
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
- **Bump de versão de imagem: editar `base/*.yaml` sozinho não move nada no cluster** — a
  `Application` usa `writeBackConfig: method: argocd`, então o Image Updater grava o digest
  resolvido como override em `spec.source.kustomize.images`, e esse override vence o manifesto
  do git enquanto a tag nova não for resolvida de novo. Fluxo correto (confirmado em
  2026-09-18): editar `base/*.yaml` **e** o alias correspondente em `argocd/image-updater.yaml`,
  commit+push, depois `kubectl apply -f argocd/image-updater.yaml` pra forçar o Image Updater a
  reconciliar contra a tag nova — só aí o override é reescrito e o Argo CD sincroniza de fato.
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
- **`docker stop` só grava a flag de parada manual (que faz `unless-stopped` respeitar) se o
  container estiver `Up` no momento** — num container já parado por falha, é no-op silencioso: a
  policy segue correta no `docker inspect`, mas ele volta sozinho no próximo boot do daemon
  mesmo assim. Achado real em 2026-09-18 (parte 2): o `protheus_dbaccess` tinha morrido por uma
  colisão de porta (17/09) antes do `docker stop` da sessão de 17/09 rodar nele — o stop não teve
  efeito porque ele já estava `Exited`, e ele voltou sozinho no boot seguinte. Fix: `docker stop`
  precisa rodar com o container **rodando** para valer; se ele já está parado, não há nada a
  fazer (já está no estado desejado, só a flag interna é que não foi gravada).
- **Log do AppServer (`appserver_core.log` etc.) é pré-alocado com padding de bytes nulos** — o
  conteúdo real fica intercalado com `\0`, não é texto sequencial puro. `tail`/`grep` direto no
  arquivo retorna majoritariamente padding e pode estourar limites de captura de output. Ler com
  `tr -d '\000' < arquivo | tail -c N` (descarta os nulos antes de cortar pelo fim). `docker logs`
  do container não ajuda aqui — o entrypoint não propaga a saída do `appsrvlinux` pro stdout do
  container além do banner inicial (OS/memory/container info); o log real está sempre no arquivo.
- **Hooks `PreSync` que dependem de recursos comuns de `Sync` travam num bootstrap do zero** —
  achado real duas vezes (ADR 0012, ADR 0013): `smartview-db-init` (hook `PreSync`) depende do
  Postgres/`postgres-secret` (recursos de `Sync`, aplicados só depois que todos os hooks `PreSync`
  terminam). Num cluster já rodando isso nunca aparece (os recursos já existiam de antes); só
  aparece num cluster genuinamente novo ou quando o recurso dependente é pausado/removido de
  propósito. Desbloqueio sempre pelo mesmo padrão: `kubectl apply -f` direto no recurso que falta
  (bypass pontual do Argo CD), deixar o hook completar, deixar o resto do sync corrigir sozinho
  depois (inclusive digests de imagem revertidos pelo apply direto). Nunca forçar
  `argocd.argoproj.io/refresh=hard` sem necessidade — recria essa trava mesmo quando o `selfHeal`
  passivo já teria resolvido o drift sem re-rodar hook nenhum.
- **Um container de node k3d recriado via `docker run` puro nasce com o mount raiz em propagação
  `private`**, não `shared`/`slave` como o k3d cria internamente via SDK do Docker — não é algo
  visível em `docker inspect` (não é volume/env/label). Quebra qualquer workload que monte `/` do
  node (ex.: `prometheus-node-exporter`, erro "not a shared or slave mount"). Fix:
  `docker exec <node> mount --make-rshared /` depois de recriar — já incorporado em
  `scripts/cluster-bootstrap/01-fix-cgroupns.sh`. Achado do drill de 2026-09-18 (ADR 0013).

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
