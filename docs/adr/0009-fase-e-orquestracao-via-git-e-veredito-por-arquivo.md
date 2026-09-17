# ADR 0009 — Fase E: orquestração git-mediada + veredito por arquivo (não por status do Job)

## Status
Aceito, validado em produção com dados reais (2026-09-17).

## Contexto
A Fase E porta os papéis efêmeros `worker`/`compile`/`upddistr` do AppServer (Compose:
`run.sh` linhas 148-215) para o cluster. O texto original do backlog cogitava "Job com hooks
Argo CD PreSync/PostSync fazendo `scale`". Duas descobertas invalidaram essa ideia:

1. A `Application` (`argocd/application.yaml`) tem `syncPolicy.automated.selfHeal: true` e
   `prune: true`, sem `ignoreDifferences`. Um hook fazendo `kubectl scale --replicas=0` seria
   revertido pelo próprio Argo CD no sync seguinte — o precedente real do repo (ADR 0006, pausa
   do `dbaccess` em 2026-09-16) já é `replicas: 0` **commitado no git**, nunca `kubectl scale`
   direto.
2. Hooks PreSync re-rodam a cada sync (ADR 0003), inclusive syncs disparados pelo Image Updater
   — incompatível com a regra mais cara do projeto (`CLAUDE.md`): `worker`/`compile`/`upddistr`
   nunca rodam antes do bootstrap manual do AppServer.

`upddistr` trouxe uma terceira descoberta, só visível ao testar com dados reais: ele nunca
termina sozinho (sobe como AppServer com `[ONSTART] Jobs=UPDJOB`) e o **status do próprio Job
não é confiável** como veredito. Um teste real confirmou isso ao vivo: um `upddistr` que falhou
por autorização (`"error.Usuário sem autorização para executar o UPDDISTR"`) ainda assim
terminou com os dois containers do Pod em `Completed` e o Job em `status.succeeded: 1` — porque
o `SIGTERM` que encerra o `appsrvlinux` não garante um exit code que reflita o resultado real da
operação.

## Decisão

1. **Orquestração sempre via git, nunca hooks automáticos.** `scripts/appserver-patch/run-job.sh`
   captura o estado de réplicas de `appserver-core`/`-rest`/`-telnet`, edita `replicas: 0` nos
   manifestos, commita, dá push, espera o Argo CD sincronizar e os pods sumirem de fato
   (`kubectl wait`-equivalente por polling) antes de aplicar o Job — e restaura depois, mesmo em
   falha (via `trap` no `EXIT` do script, mais robusto que o `run.sh`, que perde o estado se o
   processo morrer no meio).
2. **Jobs deliberadamente fora de `base/kustomization.yaml`.** `appserver-worker-job.yaml`,
   `appserver-compile-job.yaml`, `appserver-upddistr-job.yaml` são versionados mas nunca
   aplicados pelo sync automático do Argo CD — só via `kubectl apply -f` disparado pelo script.
   Isso também evita conflito de `envFrom: configMapRef` (o nome real do ConfigMap sai com hash
   do `configMapGenerator`, só reescrito pra recursos dentro do Kustomize) — mesma solução já
   usada em `smartview-db-init-job.yaml`: env vars literais (`DB_NAME`, `DB_TYPE`).
3. **`upddistr`: `shareProcessNamespace: true` + sidecar, não wrapper.** Não dá pra injetar um
   wrapper de polling no container principal — o `entrypoint.sh` da imagem `appserver-dev` faz
   `exec appsrvlinux`, substituindo o processo inteiro, e usar `command:` pra contornar isso
   descartaria o entrypoint (regra já documentada). Solução: um sidecar (`result-watcher`,
   `busybox:1.36`) no mesmo Pod com `shareProcessNamespace: true`, que faz o mesmo polling de
   `systemload/Result.json`/`result.json` que o `run.sh` fazia do lado de fora, e manda
   `SIGTERM` no `appsrvlinux` (localizado via `ps` no namespace de PID compartilhado) assim que
   o veredito aparece.
4. **O veredito de sucesso/falha do `upddistr` é sempre o CONTEÚDO do arquivo, nunca o status do
   Job.** `run-job.sh` lê `Result.json`/`result.json` diretamente do bind mount do host via
   `docker exec` no `agent-0` (mesmo critério do `run.sh`: `grep -q "success"`), depois de
   confirmar que o arquivo existe. O status do Job (`succeeded`/`failed`) só é usado como sinal
   de progresso para `worker`/`compile` (onde o container realmente reflete o resultado no exit
   code) — nunca para `upddistr`.
5. **Credencial do UPDDISTR via Secret selado, não literal.** `UPD_PASSWORD` vem de
   `appserver-upddistr-secret.sealed.yaml` (`kubeseal`, mesmo padrão de
   `postgres-secret.sealed.yaml`/`smartview-secret.sealed.yaml`) — nunca em texto puro no
   manifesto do Job, que é versionado no git. A senha do administrador é definida no bootstrap
   manual do AppServer (não tem default; confirmado pelo usuário) e foi fornecida diretamente
   para selar, nunca commitada em claro.

## Consequências
- Validado ao vivo com pacote real da TOTVS (`ATUALIZACAO_12.1.2510_BACKOFFICE_EXPEDICAO_
  CONTINUA`, arquivos `sdf/bra/*` depositados na raiz de `protheus-systemload`, sem
  subdiretórios): `upddistr` completou com `{"result":"success"}`, 54 tabelas `SYS_*` (uma a
  mais que antes — confirma que o dicionário foi de fato atualizado), hash do RPO base
  inalterado, `appserver-core`/`rest`/`telnet` religados sem erro.
- O padrão sidecar + `shareProcessNamespace` + veredito por arquivo é reaproveitável pra
  qualquer papel futuro do AppServer que tenha o mesmo formato "sobe, nunca termina sozinho,
  escreve um arquivo de veredito em algum lugar" — não é específico do `upddistr`.
- `scripts/appserver-patch/run-job.sh` agora tem dois caminhos de validação de resultado
  (status do Job pra `worker`/`compile`; conteúdo de arquivo pra `upddistr`) — documentado
  inline no script pra não ser confundido com inconsistência.
