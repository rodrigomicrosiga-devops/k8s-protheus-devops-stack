# Recriar o cluster `protheus-cluster` do zero

Contexto completo em [`docs/adr/0013-cluster-bootstrap-do-zero.md`](../../docs/adr/0013-cluster-bootstrap-do-zero.md).
Resolve o item 3 do backlog ([`docs/HANDOFF.md`](../../docs/HANDOFF.md)).

## O que isto é (e o que não é)

Recria o cluster k3d inteiro — rede Docker, containers de node, volumes nomeados do k3s — do
zero. **Diferente de [`scripts/k3d-nodes/`](../k3d-nodes/)**, que recria o *container* de um node
já existente em cima de volumes que já existem (uso: bug de configuração, container removido por
engano). Use esta receita só quando o cluster inteiro foi perdido (rede + todos os volumes) ou
para validar o próprio procedimento de disaster recovery.

**O que sobrevive a esta receita, sem ação nenhuma**: os dados reais de aplicação
(`/media/rodrigo/dados/k8s-volume/`, hostPath do `agent-0`) — é um diretório físico do host,
nunca um volume Docker gerenciado pelo k3d, então `k3d cluster delete` nunca toca nele.

**O que não sobrevive, e por isso precisa de backup antes**: as chaves do `sealed-secrets`
(sem elas, os `SealedSecret` já commitados em `base/*.sealed.yaml` ficam permanentemente
indecifráveis) e os `values.yaml` dos componentes instalados via Helm fora do git (perdidos se
não extraídos antes).

## Pré-requisitos (fazer ANTES de destruir o cluster antigo)

1. **Backup das chaves do sealed-secrets** (crítico — sem isso, os segredos já commitados nunca
   mais decriptam):
   ```sh
   kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
     > scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml
   ./scripts/secrets/encrypt.sh scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml
   rm scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml   # plaintext, não deixar no disco
   ```
2. **Backup do Postgres** (seguro mesmo sem perda de dado esperada — o hostPath sobrevive, mas é
   seguro e barato):
   ```sh
   kubectl exec -n protheus-devops deploy/postgres -- pg_dump -U protheus -d protheus -F c \
     -f /tmp/protheus-pre-drill.dump
   kubectl cp protheus-devops/<pod>:/tmp/protheus-pre-drill.dump \
     /media/rodrigo/dados/backups/protheus-pre-cluster-drill-$(date +%Y%m%d-%H%M).dump
   ```
3. **`helm-values/*.yaml` já extraídos e versionados** (feito uma vez, 2026-09-18 — só repetir se
   algum release for reconfigurado). Os 3 com credencial
   (`kube-prometheus-stack`/`minio`/`velero`) ficam só como `.yaml.gpg` no git — decriptar antes
   de usar: `./scripts/secrets/decrypt.sh scripts/cluster-bootstrap/helm-values/<nome>.yaml.gpg`.

## Passo a passo

```sh
# 0. (se houver um cluster antigo pra substituir)
k3d cluster delete protheus-cluster

# 1. Cluster novo (rede + nodes + volumes, sem a porta 7890 desde o início)
./scripts/cluster-bootstrap/00-create-cluster.sh

# 2. Fix do bug de cgroup v2 -- rodar nos dois nodes, um de cada vez
./scripts/cluster-bootstrap/01-fix-cgroupns.sh k3d-protheus-cluster-server-0
./scripts/cluster-bootstrap/01-fix-cgroupns.sh k3d-protheus-cluster-agent-0

# 3. sealed-secrets com as chaves antigas restauradas (decriptar o backup primeiro)
./scripts/secrets/decrypt.sh scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml.gpg
./scripts/cluster-bootstrap/02-install-sealed-secrets.sh
rm scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml   # plaintext, apagar depois de usar

# 4. Argo CD + bootstrap deste repo -- a partir daqui o resto sobe via GitOps sozinho
./scripts/cluster-bootstrap/03-install-argocd.sh

# 5. Componentes fora do caminho crítico (falco/monitoring/velero) -- sem pressa
./scripts/secrets/decrypt.sh scripts/cluster-bootstrap/helm-values/kube-prometheus-stack.yaml.gpg
./scripts/secrets/decrypt.sh scripts/cluster-bootstrap/helm-values/minio.yaml.gpg
./scripts/secrets/decrypt.sh scripts/cluster-bootstrap/helm-values/velero.yaml.gpg
./scripts/cluster-bootstrap/04-install-extras.sh
rm scripts/cluster-bootstrap/helm-values/{kube-prometheus-stack,minio,velero}.yaml
```

## Validação depois de tudo no ar

```sh
kubectl get nodes                                                    # 2 Ready
kubectl get applications -n argocd protheus-devops-stack             # Synced/Healthy
kubectl get pods -n protheus-devops                                  # tudo 1/1 Running
kubectl exec -n protheus-devops deploy/postgres -- psql -U protheus -d protheus \
  -tAc "select count(*) from information_schema.tables where table_schema='public';"
  # deve bater com a contagem de antes do drill
sha256sum <caminho hostPath>/protheus-apo/tttm120.rpo                # deve bater com o hash de antes
```

## Achados reais, registrados pra não repetir a investigação

Ver ADR 0013 pro detalhe completo. Resumo:
- `k3d cluster create` **não tem flag nativa pra `--cgroupns host`** — por isso o passo 2 é
  obrigatório e separado, não algo que dá pra passar direto na criação.
- O `serverlb` nasce **sem** a porta 7890 desde o primeiro `k3d cluster create` desta receita
  (`00-create-cluster.sh` já não mapeia) — diferente do cluster original, que precisou de um
  `k3d cluster edit --port-delete` depois (item 4 do backlog, já fechado).
- O primeiro sync completo do Argo CD vai disparar o hook `PreSync` `smartview-db-init`, que
  espera o Postgres responder. Num bootstrap do zero isso deve resolver sozinho (Postgres sobe
  como parte do mesmo sync, sem pausa artificial) — mas se travar, ver ADR 0012 pros sintomas e
  a receita de recuperação (não é a mesma causa do item 3/PVs, mas o mecanismo de trava é
  idêntico).
- A primeira tentativa de instalar o Velero historicamente falhou
  (`VolumeSnapshotLocation` com `credential`/`provider` nulos) — o `helm upgrade --install` do
  script 04 já é idempotente e resolve na segunda passada sozinho.
