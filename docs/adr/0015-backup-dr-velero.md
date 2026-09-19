# ADR 0015 — Backup/DR com Velero: do componente inerte ao restore validado

## Status
Aceito, implementado e **validado com restore ao vivo** em 2026-09-19. O Velero estava instalado
desde 2026-07-26 mas nunca tinha feito um backup e, mesmo que fizesse, não teria capturado dado
algum. Um achado colateral (encoding do banco do cluster, UTF8 em vez de WIN1252) foi corrigido
na mesma sessão, ver "Achado fora do escopo" no fim.

## Contexto
Levantamento feito antes de mexer em qualquer coisa, e que mudou o escopo do que parecia ser
"criar um Schedule":

| Achado | Evidência |
|---|---|
| Nenhum backup jamais existiu | `kubectl get schedules,backups -n velero` vazio |
| Velero não lia dado de volume | `deployNodeAgent: false` no release |
| Mesmo com node-agent, não capturaria nada | os 10 PVs eram `hostPath`; doc do Velero: *"`hostPath` volumes are not supported. Local persistent volumes are supported."* |
| O destino do backup não sobrevivia ao desastre que ele cobre | o bucket do MinIO ficava em `/var/lib/rancher/k3s/storage`, que no `agent-0` é um **volume Docker anônimo**: um `k3d cluster delete` (o drill de 2026-09-18) o levaria junto |

Resultado: aparência de DR (2 pods `Running`, BackupStorageLocation `Available`) sem nenhuma
capacidade real de restaurar.

## Decisão

1. **Destino em bind mount real.** MinIO passa a gravar em `k8s-volume/minio-backup` (PV/PVC
   estáticos, `Retain`, `nodeAffinity` no `agent-0`), o único caminho que sobrevive a
   `k3d cluster delete` (ADR 0007/0008). `scripts/cluster-bootstrap/backup/minio-storage.yaml`.
2. **`node-agent` ligado** e memória do servidor do Velero de 256Mi para **1Gi**. O primeiro
   backup real falhou: servidor `OOMKilled` (exit 137) no meio da cópia do volume do RPO, e o
   Velero marcou o backup como `Failed` com *"found a backup with status InProgress during the
   server starting"* — a causa real não aparece em `velero backup describe`.
3. **Escopo de dados deliberadamente estreito: só o que nenhuma imagem reconstrói.**
   `protheus-apo` (RPO `tttm120.rpo` já com patch, `custom.rpo`) e o **dump lógico** do Postgres.
   Os outros volumes nascem das imagens seed.
4. **Postgres via dump, não via data dir.** `postgres-pv` continua `hostPath`. Um hook
   `pre.hook.backup.velero.io` roda `pg_dump -Fc` dos dois bancos num volume novo
   (`postgres-dumps-pv`, `local` desde o nascimento) e só esse volume entra no backup. O dump
   restaura com garantia; o data dir cru copiado a quente é só *crash-consistent*. Escreve em
   `.tmp` e renomeia (falha no meio nunca troca dump bom por dump pela metade); `on-error: Fail`.
5. **`protheus-apo` (`hostPath` → `local`).** A troca custou uma chave, porque os 10 PVs já
   tinham `nodeAffinity` (exigência do tipo `local`) desde o ADR 0004/0012. Foi feita com o
   roteiro do ADR 0012.
6. **Não converter `postgres-pv`.** Pausar o Postgres via git reabriria a dependência circular
   do hook `PreSync` `smartview-db-init` (ADR 0012/0013), e o dump já cobre o banco.
7. **Schedule `protheus-daily`** (`0 21 * * *` UTC, TTL 7 dias) sobre os namespaces
   `protheus-devops` e `argocd`. O `argocd` entra porque os overrides de digest do Image Updater
   (`writeBackConfig: argocd`) existem só no cluster, nunca no git. 21:00 UTC porque a máquina é
   desligada de madrugada. Config sem segredo vai em overlays de values
   (`minio-persistence.yaml`, `velero-overrides.yaml`) combinados com `--reuse-values`, sem tocar
   nos `.gpg` do ADR 0011.

## Validação — drill de restore ao vivo
Backup `manual-2`: 480/480 itens, 0 erros, hook de `pg_dump` confirmado, 2 volumes copiados
(`postgres-dumps` 59,9 MB, `protheus-apo` 754,7 MB), dado no bind mount do host.

Restore para um namespace descartável, comparado com o original:

- **RPO**: `tttm120.rpo`, `custom.rpo` e `tlpp.rpo` com hashes **idênticos** ao original
  (742.781.655 bytes, mtime preservado).
- **Dumps**: hashes idênticos aos do original.
- **Banco**: `pg_restore --exit-on-error` (exit 0) num Postgres descartável: 171 tabelas,
  contagem de linhas igual nas tabelas de dado. Só `tph_item` difere, por ser tabela interna de
  controle que o próprio sistema regrava (log/contador `NEXTLOG`) e continuou escrevendo depois
  do dump.
- Depois: 0 diferença nos PVs, dados e pods do cluster; tudo criado pro teste removido.

## Obstáculos reais (o motivo desta seção existir)

1. **Um restore com mapeamento de namespace pode escrever no volume vivo.** A doc do Velero diz
   que, com o PV já existente e o namespace remapeado, ele cria um `velero-clone-<uuid>`; um PV
   `local`/`hostPath` carrega o caminho fixo, então o clone apontaria pro **mesmo diretório**.
   Por isso o drill não foi feito às cegas: foi ensaiado antes num PV descartável com as mesmas
   condições (estático, `Retain`, `local`, existente e `Bound`, namespace remapeado). Resultado
   medido: o Velero **não clonou**; provisionou um volume novo e o original ficou intacto (`diff`
   vazio). A receita do drill real só rodou depois disso.
2. **`--include-resources` e `--exclude-resources persistentvolumes` suprimem os
   `PodVolumeRestore` em silêncio**: o restore termina `Completed`, os pods ficam em `Init`
   esperando o `restore-wait` para sempre. Bisseccionado num backup de 5 MB: o Velero só cria os
   PVRs quando os PVs participam do restore. Não passar esses dois filtros.
3. **PVC sem backup de dado mantém `volumeName`.** O `postgres-pvc` do backup apontava para o
   `postgres-pv` real e ficou `Pending` (protegido, mas trava o pod, e a PVR do outro volume do
   mesmo pod espera todos os PVCs ligarem). Solução no drill: recriar esse PVC sem `volumeName`.
4. **`kubectl logs deploy/velero` pode ler o log do `node-agent`** (mesmo label): "Found 3 pods,
   using pod/node-agent-…". Pode enganar um diagnóstico; usar o nome do pod.
5. **`velero backup describe` no host falha com erro de DNS**
   (`minio.velero.svc.cluster.local`): o CLI busca URLs pré-assinadas do MinIO direto do host.
   Não é falha do backup; usar `kubectl get backup -o jsonpath`.
6. **PVs `local-path` deste k3s são do tipo `local`**, não `hostPath` — vale para qualquer
   modifier/JSONPath que aponte `/spec/hostPath/path`.
7. O restore deixa PVs `Released` com política `Retain` e os diretórios em
   `/var/lib/rancher/k3s/storage`; `local-path` não os apaga.
8. O backup inclui **Secrets em texto** no bucket, protegido só pelas credenciais do MinIO em
   disco local. Aceitável neste escopo (dev/estudo, single-dev).

## Como restaurar (receita validada)
```
velero restore create <nome> --from-backup <backup> \
  --include-namespaces protheus-devops \
  --namespace-mappings protheus-devops:<ns-descartavel> \
  --selector 'app in (postgres,protheus-rpo-seed)' \
  --exclude-resources replicasets.apps,deployments.apps
```
Se o pod do Postgres ficar `Pending`, recriar o `postgres-pvc` do namespace descartável sem
`volumeName`. Nunca usar `--include-resources`. Para restaurar de verdade sobre o cluster
principal (não um drill), o caminho é outro e **não foi exercitado aqui**.

## Achado fora do escopo — encoding do banco do cluster
O banco `protheus` do cluster está **UTF8** (`en_US.utf8`). O Protheus exige **WIN1252**, e é o
que o init da imagem `docker-postgres-protheus` cria (`ENCODING='WIN1252' LC_COLLATE='C'`
`LC_CTYPE='pt_BR.CP1252'`) — mas só **se o banco ainda não existir**. `base/postgres.env` define
`POSTGRES_DB=protheus`/`POSTGRES_USER=protheus`, então o entrypoint oficial já cria o banco
(UTF8, default) antes do init da imagem, que pula a criação. O Compose usa `POSTGRES_DB=postgres`
e não sofre isso.

**Corrigido na mesma sessão (2026-09-19), a pedido do usuário**: `base/postgres.env` passou a
`POSTGRES_DB=postgres`/`POSTGRES_USER=postgres` (bootstrap, como no Compose; `DB_*` seguem
`protheus`, e `dbaccess`/`appserver` logam por `DB_*`, então não foram afetados). Em vez de
`DROP/CREATE DATABASE` no lugar — que deixaria o cluster inicializado com a config errada —, o
Postgres foi **reinicializado do zero** pelos manifestos do cluster (sem resíduo de
Compose/legado): `license`, `dbaccess` e `core`/`rest`/`telnet` pausados via git (ADR 0006), wipe
do data dir feito pelo usuário (o classificador de segurança negou a remoção ao assistente), o
container reiniciou sozinho e rodou `initdb` + init da imagem. Resultado medido: `protheus`
`WIN1252 | collate=C | ctype=pt_BR.CP1252`, dono `protheus` (sem superuser), 0 tabelas.
`license` e `dbaccess` religados; `core`/`rest`/`telnet` ficam parados até o bootstrap manual do
`CLAUDE.md` (banco vazio). O hook de backup passou a dumpar só bancos que existem. A convenção de
2026-09-16 vale para `DB_*` e `ENV_NAME`; o superusuário de bootstrap do Postgres é `postgres`.

## Consequências
- O backup passa a existir, ser diário e ter sido restaurado de verdade.
- Um restore *real* sobre o cluster principal continua sem drill próprio.
- O backup depende de o node-agent enxergar `/var/lib/kubelet/pods`, que exige propagação de
  mount `shared` nos nodes: ver o acréscimo no ADR 0013 e `scripts/k3d-nodes/post-boot.sh`.
- Comportamento não verificado: o Velero deve executar um backup vencido ao voltar de um
  desligamento; confirmar no primeiro ciclo real depois de uma noite desligada.
