#!/usr/bin/env bash
# Reaplica o estado de runtime que os nodes k3d perdem quando o Docker os
# reinicia, e CONVERGE até os nodes estabilizarem. Idempotente.
#
# Por que existe: o container de node nasce com o mount raiz em propagação
# `private`, e o Docker o recria assim a cada (re)start -- no boot da máquina
# e em qualquer restart posterior. Isso quebra qualquer workload que monte `/`
# do node (prometheus-node-exporter, node-agent do Velero). Erro típico:
#   path "/" is mounted on "/" but it is not a shared or slave mount
# ADR 0013 (a causa) e ADR 0025 (por que aplicar UMA vez não basta: no boot o
# agent-0 entra em loop de restart e cada restart nasce `private` de novo; e o
# serverlb ficou 5 dias parado depois de um upgrade do Docker).
#
# Comportamento:
#   1. descobre os nodes pelo label do k3d (sem hardcode de nome);
#   2. religa o serverlb se estiver parado;
#   3. aplica `rshared` e CONFIRMA lendo /proc/self/mountinfo do node;
#   4. só termina quando todos os nodes ficaram STABLE_SECONDS seguidos com
#      o mesmo StartedAt e `shared:` confirmado; senão sai com erro (a unit
#      aparece em `systemctl --failed` em vez de "sucesso" falso).
#
# Uso: scripts/k3d-nodes/post-boot.sh   (ou via k3d-node-rshared.service /
#      k3d-node-watch.service)
set -euo pipefail

DOCKER="${DOCKER:-docker}"                          # sobrescrevível p/ teste com docker falso
CLUSTER="${K3D_CLUSTER_NAME:-protheus-cluster}"
WAIT_SECONDS="${POST_BOOT_WAIT_SECONDS:-180}"       # teto total
STABLE_SECONDS="${POST_BOOT_STABLE_SECONDS:-30}"    # janela sem mudança
POLL_SECONDS="${POST_BOOT_POLL_SECONDS:-2}"

list_nodes() {
  "$DOCKER" ps --filter "label=k3d.cluster=${CLUSTER}" \
    --format '{{.Names}} {{.Label "k3d.role"}}' 2>/dev/null \
    | awk '$2=="server" || $2=="agent" {print $1}'
}

# `shared:` só aparece nos campos opcionais da linha do mount raiz.
is_shared() {
  "$DOCKER" exec "$1" sh -c 'grep -E "^[0-9]+ [0-9]+ [0-9:]+ / / " /proc/self/mountinfo' 2>/dev/null \
    | grep -q ' shared:'
}

start_serverlb() {
  local lb status
  lb="$("$DOCKER" ps -a --filter "label=k3d.cluster=${CLUSTER}" \
    --format '{{.Names}} {{.Label "k3d.role"}} {{.State}}' 2>/dev/null \
    | awk '$2=="loadbalancer" && $3!="running" {print $1}')"
  for c in $lb; do
    echo "  ${c}: parado -- religando"
    status=0
    "$DOCKER" start "$c" >/dev/null || status=$?
    [ "$status" -eq 0 ] || echo "  AVISO: não consegui religar ${c} (exit ${status})" >&2
  done
}

echo "Aguardando o Docker listar os nodes de '${CLUSTER}'..."
start=$SECONDS
deadline=$((start + WAIT_SECONDS))
last_sig=""
stable_since=$SECONDS

while [ "$SECONDS" -lt "$deadline" ]; do
  nodes="$(list_nodes || true)"
  if [ -z "$nodes" ]; then
    last_sig=""; stable_since=$SECONDS
    sleep "$POLL_SECONDS"; continue
  fi

  start_serverlb

  sig=""; all_shared=1
  for node in $nodes; do
    started="$("$DOCKER" inspect -f '{{.State.StartedAt}}' "$node" 2>/dev/null || echo '?')"
    sig="${sig}${node}=${started};"
    if ! is_shared "$node"; then
      "$DOCKER" exec "$node" mount --make-rshared / 2>/dev/null || true
      echo "  ${node}: aplicado rshared (StartedAt=${started})"
      is_shared "$node" || all_shared=0
    fi
  done

  # Mudou o conjunto/StartedAt (restart no meio) ou algum node sem shared:
  # recomeça a janela de estabilidade.
  if [ "$sig" != "$last_sig" ] || [ "$all_shared" -ne 1 ]; then
    last_sig="$sig"; stable_since=$SECONDS
  elif [ $((SECONDS - stable_since)) -ge "$STABLE_SECONDS" ]; then
    for node in $nodes; do echo "  ${node}: rshared confirmado e estável há ${STABLE_SECONDS}s"; done
    break
  fi
  sleep "$POLL_SECONDS"
done

if [ "$SECONDS" -ge "$deadline" ]; then
  echo "ERRO: nodes de '${CLUSTER}' não estabilizaram em ${WAIT_SECONDS}s (rshared + StartedAt estável por ${STABLE_SECONDS}s)." >&2
  exit 1
fi

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
