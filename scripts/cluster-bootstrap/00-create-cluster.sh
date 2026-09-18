#!/usr/bin/env bash
# Cria o cluster k3d "protheus-cluster" do zero (rede + nodes + volumes
# nomeados novos). NÃO recria a topologia de dados existente -- isso é
# reconstruído depois, pelos PVs com hostPath (ver base/*.yaml) apontando
# pro mesmo diretório físico do host, que sobrevive a este passo.
#
# Pré-requisito: nada do cluster antigo deve existir mais (rede, containers,
# volumes nomeados do k3s) -- rode `k3d cluster delete protheus-cluster`
# antes, se for uma recriação em cima de um cluster anterior.
#
# Nasce SEM a porta 7890 no serverlb (fix do item 4/backlog já aplicado
# desde a criação -- diferente do cluster original de 2026-07-18, que
# precisou de um `k3d cluster edit --port-delete` depois).
set -euo pipefail

CLUSTER_NAME="protheus-cluster"
K3D_IMAGE="rancher/k3s:v1.35.5-k3s1"
APP_DATA_HOSTPATH="/media/rodrigo/dados/k8s-volume"

echo "=== Criando cluster $CLUSTER_NAME ==="
k3d cluster create "$CLUSTER_NAME" \
  --image "$K3D_IMAGE" \
  --servers 1 \
  --agents 1 \
  --volume "${APP_DATA_HOSTPATH}:${APP_DATA_HOSTPATH}@agent:0" \
  --wait \
  --timeout 120s

echo
echo "✅ Cluster criado. Nodes:"
kubectl get nodes

echo
echo "⚠️  Os nodes provavelmente vão travar em NotReady/crashloop agora -- bug"
echo "   de cgroup v2 conhecido (ADR 0008), k3d não tem flag nativa pra"
echo "   '--cgroupns host'. Rode 01-fix-cgroupns.sh nos dois nodes a seguir,"
echo "   mesmo que pareçam saudáveis (o crashloop pode demorar a aparecer)."
