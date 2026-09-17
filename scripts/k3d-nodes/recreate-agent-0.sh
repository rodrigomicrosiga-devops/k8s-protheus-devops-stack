#!/usr/bin/env bash
# Recria o container Docker do node k3d-protheus-cluster-agent-0, preservando
# o estado do k3s (volumes nomeados já existentes) e o bind mount real dos
# dados de aplicação. Ver scripts/k3d-nodes/README.md antes de rodar --
# NÃO é o caminho normal para "religar" o node (isso é só `docker restart`);
# é só para quando o container precisa ser efetivamente removido e recriado.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

TOKEN="$(resolve_token "$SERVER_0_NAME")"

confirm_or_abort "$AGENT_0_NAME"
stop_and_remove_if_exists "$AGENT_0_NAME"

docker run -d \
  --name "$AGENT_0_NAME" \
  --hostname "$AGENT_0_NAME" \
  --privileged \
  --init \
  --restart unless-stopped \
  --network "$K3D_NETWORK" \
  --security-opt label=disable \
  --cgroupns host \
  --userns host \
  --tmpfs /run \
  --tmpfs /var/run \
  -e "K3S_TOKEN=${TOKEN}" \
  -e "K3S_URL=https://${SERVER_0_NAME}:6443" \
  -e K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml \
  -v "${K3D_IMAGES_VOLUME}:/k3d/images" \
  -v "${AGENT_0_VOL_LOG}:/var/log" \
  -v "${AGENT_0_VOL_CNI}:/var/lib/cni" \
  -v "${AGENT_0_VOL_KUBELET}:/var/lib/kubelet" \
  -v "${AGENT_0_VOL_K3S}:/var/lib/rancher/k3s" \
  -v "${APP_DATA_HOSTPATH}:${APP_DATA_HOSTPATH}" \
  --label app=k3d \
  --label k3d.cluster=protheus-cluster \
  --label k3d.cluster.imageVolume="${K3D_IMAGES_VOLUME}" \
  --label k3d.cluster.network="${K3D_NETWORK}" \
  --label k3d.cluster.network.external=false \
  --label k3d.cluster.network.id="${K3D_CLUSTER_NETWORK_ID}" \
  --label k3d.cluster.network.iprange="${K3D_CLUSTER_IPRANGE}" \
  --label k3d.cluster.token="${TOKEN}" \
  --label k3d.cluster.url="https://${SERVER_0_NAME}:6443" \
  --label k3d.role=agent \
  --label k3d.server.loadbalancer="${K3D_LB_NAME}" \
  --label k3d.version="${K3D_VERSION_LABEL}" \
  "$K3D_IMAGE" \
  agent

echo "Container $AGENT_0_NAME recriado."
print_next_steps "$AGENT_0_NAME"
