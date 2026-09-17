#!/usr/bin/env bash
# Recria o container Docker do node k3d-protheus-cluster-server-0 (control
# plane, datastore SQLite -- cluster single-server, sem etcd), preservando o
# estado do k3s via volumes nomeados já existentes. Ver
# scripts/k3d-nodes/README.md antes de rodar -- NÃO é o caminho normal para
# "religar" o node (isso é só `docker restart`); é só para quando o
# container precisa ser efetivamente removido e recriado.
#
# Recomenda-se tirar um backup do datastore antes (ele não é feito por este
# script):
#   docker run --rm -v <SERVER_0_VOL_K3S>:/data -v /media/rodrigo/dados/backups:/backup \
#     alpine tar czf /backup/k3s-server-db-$(date +%Y%m%d).tar.gz -C /data/server db

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

TOKEN="$(resolve_token "$AGENT_0_NAME")"

confirm_or_abort "$SERVER_0_NAME"
stop_and_remove_if_exists "$SERVER_0_NAME"

docker run -d \
  --name "$SERVER_0_NAME" \
  --hostname "$SERVER_0_NAME" \
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
  -e K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml \
  -v "${K3D_IMAGES_VOLUME}:/k3d/images" \
  -v "${SERVER_0_VOL_LOG}:/var/log" \
  -v "${SERVER_0_VOL_CNI}:/var/lib/cni" \
  -v "${SERVER_0_VOL_KUBELET}:/var/lib/kubelet" \
  -v "${SERVER_0_VOL_K3S}:/var/lib/rancher/k3s" \
  --label app=k3d \
  --label k3d.cluster=protheus-cluster \
  --label k3d.cluster.imageVolume="${K3D_IMAGES_VOLUME}" \
  --label k3d.cluster.network="${K3D_NETWORK}" \
  --label k3d.cluster.network.external=false \
  --label k3d.cluster.network.id="${K3D_CLUSTER_NETWORK_ID}" \
  --label k3d.cluster.network.iprange="${K3D_CLUSTER_IPRANGE}" \
  --label k3d.cluster.token="${TOKEN}" \
  --label k3d.cluster.url="https://${SERVER_0_NAME}:6443" \
  --label k3d.role=server \
  --label k3d.server.api.host=0.0.0.0 \
  --label k3d.server.api.hostIP=0.0.0.0 \
  --label k3d.server.api.port=45865 \
  --label k3d.server.loadbalancer="${K3D_LB_NAME}" \
  --label k3d.version="${K3D_VERSION_LABEL}" \
  "$K3D_IMAGE" \
  server --tls-san 0.0.0.0 --tls-san "${K3D_LB_NAME}"

echo "Container $SERVER_0_NAME recriado."
print_next_steps "$SERVER_0_NAME"
