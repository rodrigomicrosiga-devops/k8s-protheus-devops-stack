#!/usr/bin/env bash
# Constantes e helpers compartilhados pelos scripts de recriação de node do
# cluster k3d "protheus-cluster". Ver scripts/k3d-nodes/README.md.
#
# Os IDs de volume abaixo são fixos: são os volumes Docker nomeados que já
# existem (criados quando o cluster nasceu, 2026-07-18) e guardam o estado
# real do k3s de cada node (/var/lib/rancher/k3s, /var/lib/kubelet, etc).
# Recriar o CONTAINER do node preserva esse estado; recriar o CLUSTER inteiro
# (k3d cluster delete) não usaria esses IDs -- geraria volumes novos, vazios.
# Não são reutilizáveis para um cluster diferente deste.

set -euo pipefail

K3D_NETWORK="k3d-protheus-cluster"
K3D_IMAGE="docker.io/rancher/k3s:v1.35.5-k3s1"
K3D_IMAGES_VOLUME="k3d-protheus-cluster-images"
K3D_CLUSTER_NETWORK_ID="bda5c8cc0ada476d86ab144fd6aef90fbe3dcc3f639f73616c19fa02cb4b76c9"
K3D_CLUSTER_IPRANGE="172.18.0.0/16"
K3D_LB_NAME="k3d-protheus-cluster-serverlb"
K3D_VERSION_LABEL="v5.9.0"

AGENT_0_NAME="k3d-protheus-cluster-agent-0"
AGENT_0_VOL_LOG="e17194e2433d43a67617d9dd73a2df994e83933814edb1925e799a860c766310"
AGENT_0_VOL_CNI="515ea3e0e54b6b6b73cbfc3c32f09257ad7e5aad934e2d4cf6971b9cbb12389b"
AGENT_0_VOL_KUBELET="3371265ee215d7af3d6d2fe740c2fa9c762ab979fbcab18ed311123b72d60b55"
AGENT_0_VOL_K3S="2937ac004803dcd90a9981e435ed6c152b8e0480c224bb8a0978ae119e510309"

SERVER_0_NAME="k3d-protheus-cluster-server-0"
SERVER_0_VOL_LOG="9514299cd543c1b2c95b9ee9faf98e895af1291d44ead083fe8535cdd856c7bd"
SERVER_0_VOL_CNI="bd1804fbf65bbe01dba248783c6139b603f98079e68920e4def4f0e2bb4d2b40"
SERVER_0_VOL_KUBELET="8733751dc2871492bb6dfcb96b83cdd5b071e2a4175516f710d56add37d0eac1"
SERVER_0_VOL_K3S="214aa5c5e15bb4a7378b807a326e9e5ed3504cf1dde57a0186175c8d68190f9f"

# hostPath real dos dados de aplicação (Postgres, RPO, system/systemload,
# webapp/printer shared) -- só o agent-0 precisa, é onde os PVs com
# nodeAffinity estão fixados. Ver ADR 0007/0008.
APP_DATA_HOSTPATH="/media/rodrigo/dados/k8s-volume"

# Resolve o token do cluster: usa $K3D_CLUSTER_TOKEN se definido, senão tenta
# ler do node irmão (se ele ainda existir e estiver rodando). Se nenhum dos
# dois nodes existir mais, não há como recuperar o token por aqui -- teria
# que vir de onde o dev guardou (não é um segredo forte, só a chave de
# handshake interna do cluster, mas também não fica hardcoded no git).
resolve_token() {
  local sibling="$1"
  if [ -n "${K3D_CLUSTER_TOKEN:-}" ]; then
    printf '%s' "$K3D_CLUSTER_TOKEN"
    return 0
  fi
  if docker inspect "$sibling" >/dev/null 2>&1; then
    docker inspect "$sibling" --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep '^K3S_TOKEN=' | head -1 | cut -d= -f2-
    return 0
  fi
  echo "ERRO: não consegui resolver o token do cluster." >&2
  echo "Defina \$K3D_CLUSTER_TOKEN ou garanta que o node irmão ($sibling) ainda existe." >&2
  return 1
}

confirm_or_abort() {
  local container="$1"
  echo "Isto vai PARAR e REMOVER o container '$container' (se existir) e recriá-lo."
  echo "O estado do k3s (volumes nomeados) e os dados de aplicação (bind mount) são"
  echo "preservados -- mas confirme que não há backup pendente antes de continuar."
  read -r -p "Digite RECRIAR para confirmar: " resp
  if [ "$resp" != "RECRIAR" ]; then
    echo "Abortado." >&2
    exit 1
  fi
}

stop_and_remove_if_exists() {
  local container="$1"
  if docker inspect "$container" >/dev/null 2>&1; then
    echo "Parando e removendo $container..."
    docker stop "$container" >/dev/null
    docker rm "$container" >/dev/null
  else
    echo "$container não existe -- seguindo direto para a criação."
  fi
}

print_next_steps() {
  local node_name="$1"
  cat <<EOF

Próximos passos manuais (não automatizados por este script):
1. Apagar o Secret de senha de registro do node, se ele ainda existir:
     kubectl delete secret -n kube-system ${node_name}.node-password.k3s
   (Necessário sempre que o container é recriado -- a senha local é gerada
   de novo a cada 'docker run' e o server rejeita como "duplicate hostname"
   até o Secret antigo ser removido. Ver ADR 0008.)
2. Reiniciar o loadbalancer (ele pode não resolver o hostname do node novo
   até ser religado, e em alguns casos perde a própria rede -- reconecte
   antes de reiniciar):
     docker network connect ${K3D_NETWORK} ${K3D_LB_NAME} 2>/dev/null || true
     docker restart ${K3D_LB_NAME}
3. Validar:
     kubectl get nodes
     kubectl get pods -n protheus-devops
   Se o node ficar NotReady preso em "Node password rejected", volte ao
   passo 1. Se o kubelet crashloopar com erro de cgroup, confirme que este
   script usou --cgroupns host (deveria, já está no script).
4. Se for o server-0 e ele voltar com 'SchedulingDisabled' sem motivo aparente
   (aconteceu uma vez em 2026-09-17, causa não identificada):
     kubectl uncordon ${node_name}
EOF
}
