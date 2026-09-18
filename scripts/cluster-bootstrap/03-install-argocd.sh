#!/usr/bin/env bash
# Instala Argo CD + Argo CD Image Updater, depois aplica os dois manifestos
# de bootstrap deste repo (argocd/application.yaml, argocd/image-updater.yaml)
# -- mesmo par de comandos já documentado na seção "Bootstrap / Disaster
# Recovery" do README.md principal.
#
# Pré-requisito: sealed-secrets já restaurado (02-install-sealed-secrets.sh)
# -- sem isso, o primeiro sync do Argo CD falha ao tentar decriptar os
# SealedSecret de base/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo >/dev/null

echo "=== Instalando Argo CD ==="
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  -f "${SCRIPT_DIR}/helm-values/argocd.yaml" \
  --wait --timeout 300s

echo "=== Instalando Argo CD Image Updater ==="
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  -f "${SCRIPT_DIR}/helm-values/argocd-image-updater.yaml" \
  --wait --timeout 120s

echo "=== Aplicando bootstrap deste repo (Application + ImageUpdater) ==="
kubectl apply -f "${REPO_ROOT}/argocd/application.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/image-updater.yaml"

echo
echo "✅ Argo CD no ar. A Application 'protheus-devops-stack' deve começar a sincronizar"
echo "   base/ sozinha (syncPolicy.automated). Acompanhar:"
echo "   kubectl get applications -n argocd protheus-devops-stack -w"
echo
echo "⚠️  O primeiro sync completo vai bater no hook PreSync smartview-db-init --"
echo "   isso é esperado e deve resolver sozinho desta vez (Postgres não está sendo"
echo "   pausado artificialmente como no drill do item 3/PVs -- replicas:1 já está"
echo "   no git). Se travar mesmo assim, ver ADR 0012 'Obstáculos reais enfrentados'."
