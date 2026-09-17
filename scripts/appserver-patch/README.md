# Fase E — worker, compile e upddistr no cluster k8s

Porta a "esteira elástica síncrona" do `run.sh` do Compose
(`docker-protheus-devops-stack/run.sh`, linhas 148-215) para o cluster k8s: para
`appserver-core`/`-rest`/`-telnet`, roda o Job de patch (`worker`), compilação (`compile`) ou
atualização de dicionário (`upddistr`), religa o que estava ativo — mesmo se o Job falhar. Os
três papéis validados ao vivo com dados reais (ver `docs/HANDOFF.md` e ADR 0009 pro histórico
completo).

## Por que isto é um script, não um hook Argo CD

O texto original do backlog (`docs/HANDOFF.md`) cogitava "hooks Argo CD PreSync/PostSync fazendo
`scale`". Não funciona neste repo:

1. A `Application` tem `selfHeal: true` e `prune: true`, **sem `ignoreDifferences`**
   (`argocd/application.yaml`). Um `kubectl scale --replicas=0` feito de dentro de um hook seria
   revertido pelo próprio Argo CD no sync seguinte — exatamente o cenário de corrupção
   concorrente do `.rpo` que a parada existe pra evitar. O precedente real do repo (ADR 0006, e a
   pausa do `dbaccess` em 2026-09-16) é **`replicas: 0` commitado no git**, nunca `kubectl scale`
   direto — é isso que `lib.sh` faz.
2. Hooks re-rodam a cada sync (ADR 0003), inclusive syncs disparados pelo Image Updater — e a
   regra mais cara do projeto (`CLAUDE.md`) é que `worker`/`compile`/`upddistr` **nunca** rodam
   antes do bootstrap manual do AppServer estar completo. Um Job automático e recorrente é
   estruturalmente incompatível com essa regra. Por isso os três manifestos de Job
   (`base/appserver-worker-job.yaml`, `base/appserver-compile-job.yaml`,
   `base/appserver-upddistr-job.yaml`) ficam **fora** de `base/kustomization.yaml` — o Argo CD
   nunca os toca sozinho, só este script.

## Como usar

**1. Depositar o insumo** — manual, sempre trivial graças ao bind mount real do `agent-0`
(`docs/adr/0008-bind-mount-real-recriacao-isolada-dos-nodes.md`):

- **worker** — `.ptm` em `protheus-patches/`:
  ```sh
  cp arquivo.ptm /media/rodrigo/dados/k8s-volume/protheus-patches/
  ```
- **compile** — fonte (`.prw`/`.tlpp`) em `protheus-patches/`. Os `includes.zip` (advpl/tlpp)
  já foram depositados em `/media/rodrigo/dados/k8s-volume/protheus-includes/{advpl,tlpp}/` em
  2026-09-17 (cópia dos mesmos arquivos usados pelo Compose,
  `docker-protheus-devops-stack/protheus/includes/`) — não precisa repetir a menos que a TOTVS
  libere includes novos.
- **upddistr** — arquivos de atualização (SX*, *.mzp, sdf*) na **raiz** de
  `/media/rodrigo/dados/k8s-volume/protheus-systemload/`, **sem subdiretórios**. Se o insumo vier
  de um pacote TOTVS (`.zip` de "atualização contínua"), confira o `manifest.json` dele — o
  campo `adictional_path` diz onde cada artefato precisa cair; os arquivos de dicionário
  (tipicamente numa pasta `sdf/<localização>/`) vão achatados na raiz do `systemload`.

Validar por dentro do node antes de confiar no caminho físico do host (regra de hostPath
node-local, `docs/HANDOFF.md`):
```sh
docker exec k3d-protheus-cluster-agent-0 ls -la /totvs/protheus/patches_queue 2>/dev/null \
  || echo "confira o caminho hostPath real do PV correspondente"
```

**2. Rodar:**

```sh
./scripts/appserver-patch/run-job.sh worker
./scripts/appserver-patch/run-job.sh compile
./scripts/appserver-patch/run-job.sh upddistr
```

O script:
1. Confere que o bootstrap manual do AppServer já foi concluído (tabelas `SYS_*` existem) —
   recusa rodar se não. Regra dura, não é opcional.
2. Captura quantas réplicas `appserver-core`/`-rest`/`-telnet` têm agora, edita os três
   manifestos pra `replicas: 0` só nos que estavam ativos, commita, dá push, espera o Argo CD
   sincronizar e os pods sumirem de verdade (`scale` é assíncrono — só editar o git não basta).
3. Aplica o Job (`kubectl apply -f base/appserver-<role>-job.yaml`).
   - `worker`/`compile`: espera o Job terminar e usa `status.succeeded`/`status.failed` como
     veredito (o exit code do container reflete o resultado real nesses dois papéis).
   - `upddistr`: **não confia no status do Job** (confirmado ao vivo que um `upddistr` que
     falhou por autorização ainda terminou com o Job `succeeded` -- o `SIGTERM` do sidecar não
     garante exit code fiel). Em vez disso lê o CONTEÚDO de `Result.json`/`result.json` direto
     do bind mount do host (`docker exec` no `agent-0`), mesmo critério do `run.sh`:
     `grep -q "success"`. Ver ADR 0009.
4. Restaura as réplicas capturadas no passo 2 (mesmo em caso de falha ou `Ctrl-C` — via `trap`,
   diferente do `run.sh`, que perde o estado se o processo morrer no meio).
5. Sai com o resultado do veredito (Job ou arquivo, conforme o papel).

## Comportamento esperado dos papéis

- **worker sem `.ptm` na fila**: no-op, sai 0 — não é erro.
- **compile sem `.prw`/`.tlpp`**: **falha** — comportamento oposto ao worker. Não use como
  smoke test vazio.
- Patch aplicado com sucesso: o `.ptm` migra pra `patches_queue/applied/` (dentro do PVC
  `protheus-patches-pvc`). Patch com erro: `patch_deployer.sh` restaura o `.rpo` do backup
  (`apo/aporollback/`) automaticamente e move o pacote pra `patches_queue/error/`.
- **upddistr** nunca termina sozinho (sobe como AppServer com `[ONSTART] Jobs=UPDJOB`) -- o
  sidecar `result-watcher` (no mesmo Pod, `shareProcessNamespace: true`) mata o `appsrvlinux`
  assim que `Result.json`/`result.json` aparece. Credencial (`UPD_USER`/`UPD_PASSWORD`) definida
  no bootstrap manual do AppServer, sem default -- `UPD_PASSWORD` vem de
  `base/appserver-upddistr-secret.sealed.yaml` (`kubeseal`), nunca literal no YAML.

## Privilégios

Os Jobs não pedem `privileged`/`cap_add`/`/dev/mem`, ao contrário do `docker-compose.yaml`
(que dá `SYS_RAWIO` + `/dev/mem` a worker/compile/upddistr). Mesmo princípio já aplicado ao
`appserver-core.yaml`: só adiciona se um teste real provar necessidade — não decidir por
analogia com o Compose. Se um patch real falhar por permissão, é o primeiro lugar a investigar.
