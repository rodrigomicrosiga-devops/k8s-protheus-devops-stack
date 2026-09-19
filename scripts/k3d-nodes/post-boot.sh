#!/usr/bin/env bash
# Reaplica, a cada boot do host, o estado de runtime que os nodes k3d perdem
# quando o Docker os reinicia. Idempotente -- pode rodar quantas vezes quiser.
#
# Por que existe: o container de node nasce com o mount raiz em propagação
# `private`, e o Docker o recria assim a cada boot da máquina (não só quando
# o node é recriado por script). Isso quebra qualquer workload que monte `/`
# do node -- prometheus-node-exporter e o node-agent do Velero. Erro típico:
#   path "/" is mounted on "/" but it is not a shared or slave mount
# `scripts/cluster-bootstrap/01-fix-cgroupns.sh` já aplicava o fix, mas só
# quando um node era RECRIADO; um simples reboot do host o desfazia (achado de
# 2026-09-19, ver ADR 0013).
#
# Descobre os nodes pelo label que o próprio k3d grava (`k3d.role`), sem
# hardcode de nome -- funciona também depois de um `k3d cluster create` novo.
#
# Uso: scripts/k3d-nodes/post-boot.sh   (ou via k3d-node-rshared.service)
set -euo pipefail

CLUSTER="${K3D_CLUSTER_NAME:-protheus-cluster}"
WAIT_SECONDS="${POST_BOOT_WAIT_SECONDS:-120}"

echo "Aguardando o Docker listar os nodes de '${CLUSTER}'..."
deadline=$((SECONDS + WAIT_SECONDS))
nodes=""
while [ "$SECONDS" -lt "$deadline" ]; do
  nodes="$(docker ps --filter "label=k3d.cluster=${CLUSTER}" \
    --format '{{.Names}} {{.Label "k3d.role"}}' 2>/dev/null \
    | awk '$2=="server" || $2=="agent" {print $1}')"
  [ -n "$nodes" ] && break
  sleep 3
done

if [ -z "$nodes" ]; then
  echo "ERRO: nenhum node k3d do cluster '${CLUSTER}' em execução após ${WAIT_SECONDS}s." >&2
  exit 1
fi

for node in $nodes; do
  docker exec "$node" mount --make-rshared /
  echo "  ${node}: mount raiz em rshared"
done

# Só recicla pods se o kubectl alcançar o cluster e algum node-exporter
# estiver preso -- num boot normal o API server ainda pode estar subindo, e
# não é motivo pra falhar o unit (o mount já foi corrigido acima).
if command -v kubectl >/dev/null 2>&1 && kubectl get ns monitoring >/dev/null 2>&1; then
  stuck="$(kubectl get pods -n monitoring \
    -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null \
    | awk '$3!="Running" {print $1}')"
  if [ -n "$stuck" ]; then
    echo "Reciclando node-exporter preso: ${stuck}"
    # shellcheck disable=SC2086
    kubectl delete pod -n monitoring $stuck
  fi
else
  echo "kubectl/cluster indisponível agora -- pulando a reciclagem de pods (o kubelet"
  echo "reagenda sozinho com o mount já corrigido)."
fi
