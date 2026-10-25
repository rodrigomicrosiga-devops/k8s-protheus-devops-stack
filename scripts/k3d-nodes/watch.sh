#!/usr/bin/env bash
# Reaplica o runtime dos nodes k3d a cada START de container do cluster
# (restart depois do boot: OOM, `docker restart`, upgrade do Docker).
# ADR 0025. Roda como serviço (k3d-node-watch.service, Restart=always).
set -euo pipefail

DOCKER="${DOCKER:-docker}"
CLUSTER="${K3D_CLUSTER_NAME:-protheus-cluster}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Observando starts de containers do cluster '${CLUSTER}'..."
"$DOCKER" events --filter type=container --filter event=start \
  --filter "label=k3d.cluster=${CLUSTER}" --format '{{.Actor.Attributes.name}}' |
while read -r name; do
  echo "start de ${name} -- convergindo"
  # post-boot.sh falhar não derruba o watch: o próximo start tenta de novo.
  "$HERE/post-boot.sh" || echo "post-boot.sh falhou (exit $?); aguardando o próximo start" >&2
done
