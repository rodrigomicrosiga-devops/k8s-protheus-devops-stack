# Fase E (parte 1) — worker e compile no cluster k8s

Porta a "esteira elástica síncrona" do `run.sh` do Compose
(`docker-protheus-devops-stack/run.sh`, linhas 148-215) para o cluster k8s: para
`appserver-core`/`-rest`/`-telnet`, roda o Job de patch (`worker`) ou compilação
(`compile`), religa o que estava ativo — mesmo se o Job falhar.

`upddistr` **não está coberto ainda** — ele nunca termina sozinho (sobe como AppServer com
`[ONSTART] Jobs=UPDJOB`) e precisa de um mecanismo novo (sidecar com `shareProcessNamespace`
pra matar o processo quando o veredito aparecer). Fica pra depois desta fundação estar validada.

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
   estruturalmente incompatível com essa regra. Por isso os manifestos dos Jobs
   (`base/appserver-worker-job.yaml`, `base/appserver-compile-job.yaml`) ficam **fora** de
   `base/kustomization.yaml` — o Argo CD nunca os toca sozinho, só este script.

## Como usar

**1. Depositar o `.ptm` (worker) ou o fonte `.prw`/`.tlpp` (compile)** — manual, igual ao
Compose, agora trivial graças ao bind mount real do `agent-0`
(`docs/adr/0008-bind-mount-real-recriacao-isolada-dos-nodes.md`):

```sh
cp arquivo.ptm /media/rodrigo/dados/k8s-volume/protheus-patches/
# validar por dentro do node antes de confiar no caminho físico do host
# (regra de hostPath node-local, docs/HANDOFF.md):
docker exec k3d-protheus-cluster-agent-0 ls -la /totvs/protheus/patches_queue 2>/dev/null \
  || echo "confira o caminho hostPath real do PV protheus-patches-pv"
```

**2. Rodar:**

```sh
./scripts/appserver-patch/run-job.sh worker
./scripts/appserver-patch/run-job.sh compile
```

O script:
1. Confere que o bootstrap manual do AppServer já foi concluído (tabelas `SYS_*` existem) —
   recusa rodar se não. Regra dura, não é opcional.
2. Captura quantas réplicas `appserver-core`/`-rest`/`-telnet` têm agora, edita os três
   manifestos pra `replicas: 0` só nos que estavam ativos, commita, dá push, espera o Argo CD
   sincronizar e os pods sumirem de verdade (`scale` é assíncrono — só editar o git não basta).
3. Aplica o Job (`kubectl apply -f base/appserver-<role>-job.yaml`), espera terminar, mostra os
   logs.
4. Restaura as réplicas capturadas no passo 2 (mesmo em caso de falha ou `Ctrl-C` — via `trap`,
   diferente do `run.sh`, que perde o estado se o processo morrer no meio).
5. Sai com o código de saída do Job.

## Comportamento esperado dos papéis

- **worker sem `.ptm` na fila**: no-op, sai 0 — não é erro.
- **compile sem `.prw`/`.tlpp`**: **falha** — comportamento oposto ao worker. Não use como
  smoke test vazio.
- Patch aplicado com sucesso: o `.ptm` migra pra `patches_queue/applied/` (dentro do PVC
  `protheus-patches-pvc`). Patch com erro: `patch_deployer.sh` restaura o `.rpo` do backup
  (`apo/aporollback/`) automaticamente e move o pacote pra `patches_queue/error/`.

## Privilégios

Os Jobs não pedem `privileged`/`cap_add`/`/dev/mem`, ao contrário do `docker-compose.yaml`
(que dá `SYS_RAWIO` + `/dev/mem` a worker/compile/upddistr). Mesmo princípio já aplicado ao
`appserver-core.yaml`: só adiciona se um teste real provar necessidade — não decidir por
analogia com o Compose. Se um patch real falhar por permissão, é o primeiro lugar a investigar.
