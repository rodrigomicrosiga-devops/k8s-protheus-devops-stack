#!/usr/bin/env bash
# Recria um container de node k3d QUALQUER (nome passado como argumento) com
# --cgroupns host --userns host, preservando volumes/env/labels/rede
# exatamente como estavam -- só adiciona os flags que corrigem o bug de
# cgroup v2 (ADR 0008: `--cgroupns private`, usado por padrão pelo k3d
# neste host, trava o kubelet em crashloop contra o driver systemd do
# Docker).
#
# Diferente de scripts/k3d-nodes/ (IDs de volume fixos, específicos do
# cluster de 2026-07-18): este descobre tudo dinamicamente via `docker
# inspect` -- funciona em qualquer cluster k3d recém-criado, não só neste.
#
# Uso: ./01-fix-cgroupns.sh k3d-protheus-cluster-server-0
#      ./01-fix-cgroupns.sh k3d-protheus-cluster-agent-0
# Rodar nos dois nodes, um de cada vez -- não em paralelo (o agent depende
# do server já estar respondendo em alguns casos).
set -euo pipefail

NODE="${1:?Uso: $0 <nome-do-container>}"

if ! docker inspect "$NODE" >/dev/null 2>&1; then
  echo "❌ Container $NODE não existe." >&2
  exit 1
fi

CURRENT_CGROUPNS=$(docker inspect "$NODE" --format '{{.HostConfig.CgroupnsMode}}')
if [ "$CURRENT_CGROUPNS" = "host" ]; then
  echo "✅ $NODE já está com --cgroupns host. Nada a fazer."
  exit 0
fi

echo "=== Descobrindo config atual de $NODE (cgroupns atual: $CURRENT_CGROUPNS) ==="

IMAGE=$(docker inspect "$NODE" --format '{{.Config.Image}}')
NETWORK=$(docker inspect "$NODE" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
HOSTNAME=$(docker inspect "$NODE" --format '{{.Config.Hostname}}')

VOLUME_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && VOLUME_ARGS+=(-v "$line")
done < <(docker inspect "$NODE" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}}
{{end}}{{end}}')
while IFS= read -r line; do
  [ -n "$line" ] && VOLUME_ARGS+=(-v "$line")
done < <(docker inspect "$NODE" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}:{{.Destination}}
{{end}}{{end}}')

ENV_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && ENV_ARGS+=(-e "$line")
done < <(docker inspect "$NODE" --format '{{range .Config.Env}}{{.}}
{{end}}')

LABEL_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && LABEL_ARGS+=(--label "$line")
done < <(docker inspect "$NODE" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}
{{end}}')

CMD_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && CMD_ARGS+=("$line")
done < <(docker inspect "$NODE" --format '{{range .Config.Cmd}}{{.}}
{{end}}')

echo "Imagem: $IMAGE | Rede: $NETWORK | Volumes: ${#VOLUME_ARGS[@]} entradas | Cmd: ${CMD_ARGS[*]}"

echo "Isto vai PARAR e REMOVER o container '$NODE' e recriá-lo com --cgroupns host."
read -r -p "Digite RECRIAR para confirmar: " resp
[ "$resp" = "RECRIAR" ] || { echo "Abortado." >&2; exit 1; }

docker stop "$NODE" >/dev/null
docker rm "$NODE" >/dev/null

docker run -d \
  --name "$NODE" \
  --hostname "$HOSTNAME" \
  --privileged \
  --init \
  --restart unless-stopped \
  --network "$NETWORK" \
  --security-opt label=disable \
  --cgroupns host \
  --userns host \
  --tmpfs /run \
  --tmpfs /var/run \
  "${ENV_ARGS[@]}" \
  "${VOLUME_ARGS[@]}" \
  "${LABEL_ARGS[@]}" \
  "$IMAGE" \
  "${CMD_ARGS[@]}"

echo "✅ $NODE recriado com --cgroupns host."

# Achado real (drill de 2026-09-18, ADR 0013): containers recriados via
# `docker run` puro nascem com o mount raiz em propagação `private`, não
# `shared`/`slave` -- diferente de como o k3d cria os nodes internamente
# via SDK do Docker. Sem isso, qualquer coisa que monte `/` do node
# (ex.: prometheus-node-exporter) falha com "path / is mounted on / but
# it is not a shared or slave mount". Não é algo capturável via
# `docker inspect` (não é volume/env/label), por isso não dava pra
# descobrir só olhando o container antigo -- só apareceu ao testar um
# workload real que precisa disso.
echo "=== Corrigindo propagação do mount raiz (achado real do drill, ver ADR 0013) ==="
docker exec "$NODE" mount --make-rshared /

echo
echo "Próximos passos manuais (mesma lógica de scripts/k3d-nodes/README.md):"
echo "1. Apagar o Secret de senha de registro do node, se existir:"
echo "     kubectl delete secret -n kube-system ${NODE}.node-password.k3s"
echo "2. Religar o serverlb (pode ter perdido a rede/resolução):"
echo "     docker network connect \"$NETWORK\" k3d-protheus-cluster-serverlb 2>/dev/null || true"
echo "     docker restart k3d-protheus-cluster-serverlb"
echo "3. Validar: kubectl get nodes"
