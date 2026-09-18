#!/usr/bin/env bash
# Instala os componentes fora do caminho crítico da aplicação: falco
# (segurança em runtime), kube-prometheus-stack (observabilidade), minio +
# velero (backup/DR do próprio cluster). Nenhum destes bloqueia
# appserver/postgres/etc. -- rodar depois de 03-install-argocd.sh, sem
# pressa.
#
# Pré-requisito: scripts/cluster-bootstrap/helm-values/{kube-prometheus-stack,minio,velero}.yaml
# precisam existir em texto plano (decriptar primeiro: ver
# ../secrets/decrypt.sh nos .gpg correspondentes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_DIR="${SCRIPT_DIR}/helm-values"

for f in kube-prometheus-stack minio velero; do
  if [ ! -f "${VALUES_DIR}/${f}.yaml" ]; then
    echo "❌ ${VALUES_DIR}/${f}.yaml não encontrado." >&2
    echo "   Decriptar primeiro: ../secrets/decrypt.sh ${VALUES_DIR}/${f}.yaml.gpg" >&2
    exit 1
  fi
done

helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add minio https://charts.min.io/ 2>/dev/null || true
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm repo update falcosecurity prometheus-community minio vmware-tanzu >/dev/null

echo "=== Instalando Falco ==="
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  -f "${VALUES_DIR}/falco.yaml" \
  --wait --timeout 180s

echo "=== Instalando kube-prometheus-stack ==="
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "${VALUES_DIR}/kube-prometheus-stack.yaml" \
  --wait --timeout 300s

echo "=== Instalando MinIO (backend do Velero) ==="
helm upgrade --install minio minio/minio \
  --namespace velero --create-namespace \
  -f "${VALUES_DIR}/minio.yaml" \
  --wait --timeout 180s

echo "=== Instalando Velero ==="
# Achado real de 2026-07-26: a primeira instalação falhou (VolumeSnapshotLocation
# com spec.credential/spec.provider nulos) -- o `helm upgrade --install` já
# resolve isso sozinho na segunda tentativa (idempotente), mas registrado
# aqui pra não assustar se o output mostrar um erro na primeira passada.
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  -f "${VALUES_DIR}/velero.yaml" \
  --wait --timeout 180s

echo
echo "✅ Componentes extras instalados. Validar:"
echo "   kubectl get pods -n falco; kubectl get pods -n monitoring; kubectl get pods -n velero"
