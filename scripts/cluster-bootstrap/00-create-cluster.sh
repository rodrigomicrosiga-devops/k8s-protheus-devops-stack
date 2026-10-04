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
# Nasce SEM a porta 7890 "nua" no serverlb (fix do item 4/backlog antigo --
# diferente do cluster original de 2026-07-18, que precisou de um `k3d cluster
# edit --port-delete` depois). Em vez dela, nasce com as portas PADRÃO do
# Protheus (as mesmas do appserver.ini/dbaccess, ver tabela abaixo) publicadas
# em 127.0.0.1 via serverlb -- acesso fixo sem port-forward e sem depender do
# IP do node agent, que muda a cada recriação (ADR 0017). O Compose local usa
# as mesmas portas em 127.0.0.2 (HOST_BIND_IP), então as duas stacks convivem
# sem colisão -- cluster é quem tem prioridade sobre 127.0.0.1.
set -euo pipefail

CLUSTER_NAME="protheus-cluster"
K3D_IMAGE="rancher/k3s:v1.35.5-k3s1"
APP_DATA_HOSTPATH="/media/rodrigo/dados/k8s-volume"

# host:nodeport -- nodeport é o que os Services em base/*.yaml já fixam
# (appserver-core/-rest/-telnet, dbaccess, license, smartview, postgres).
# Porta de host == porta padrão do Protheus; só o NodePort intermediário
# (30000-32767) é invisível por trás do serverlb.
PORTS=(
  "127.0.0.1:1234:31234"   # core -- SmartClient/webapp multi-protocolo
  "127.0.0.1:32033:32033"  # core -- monitor
  "127.0.0.1:1235:31235"   # rest -- multi-protocolo
  "127.0.0.1:8400:30840"   # rest -- HTTP
  "127.0.0.1:1236:31236"   # telnet -- multi-protocolo
  "127.0.0.1:23:30023"     # telnet -- console SIGAACD
  "127.0.0.1:7890:30890"   # dbaccess -- DBMonitor
  "127.0.0.1:5555:30555"   # license
  "127.0.0.1:8020:30820"   # license -- monitor
  "127.0.0.1:7019:30719"   # smartview
  "127.0.0.1:7017:30717"   # smartview
  "127.0.0.1:5432:30432"   # postgres
  "127.0.0.1:8800:30880"   # protheus-manager-api (ADR 0019)
  "127.0.0.1:8801:30881"   # protheus-manager-web (ADR 0020)
)
PORT_ARGS=()
for p in "${PORTS[@]}"; do
  PORT_ARGS+=(--port "${p}@loadbalancer")
done

# PVs do tipo `local` (Velero não faz backup de hostPath, ADR 0015) exigem que o
# diretório já exista; num host novo o Argo CD sincroniza o Postgres antes de
# qualquer outro passo poder criá-lo. Ele guarda o pg_dump que o Velero copia.
mkdir -p -m 0700 "${APP_DATA_HOSTPATH}/postgres-dumps"

echo "=== Criando cluster $CLUSTER_NAME ==="
k3d cluster create "$CLUSTER_NAME" \
  --image "$K3D_IMAGE" \
  --servers 1 \
  --agents 1 \
  --volume "${APP_DATA_HOSTPATH}:${APP_DATA_HOSTPATH}@agent:0" \
  "${PORT_ARGS[@]}" \
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
