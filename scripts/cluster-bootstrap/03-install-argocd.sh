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
if ! kubectl get secret dockerhub-creds -n argocd >/dev/null 2>&1; then
  echo "⚠️  Secret 'dockerhub-creds' não existe no namespace 'argocd' -- o Image Updater vai"
  echo "   subir sem credencial e fazer pull anônimo do Docker Hub (rate limit real sob uso"
  echo "   intenso, achado de 2026-09-18). Criar antes de continuar, com usuário/Access Token"
  echo "   reais (nunca senha):"
  echo "     kubectl create secret generic dockerhub-creds -n argocd \\"
  echo "       --from-literal=creds='SEU_USUARIO_DOCKERHUB:SEU_ACCESS_TOKEN'"
  echo "   Prosseguindo mesmo assim -- corrigir depois com o mesmo comando + um restart do"
  echo "   deployment (kubectl rollout restart deployment argocd-image-updater -n argocd)."
fi
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
echo "   O hook smartview-db-init roda como Sync/wave 1 desde 2026-09-21 (ADR 0016) --"
echo "   depende de postgres-secret/postgres-config, que ficam na wave 0 normal, então"
echo "   já existem quando o hook precisa deles. Validado ao vivo num bootstrap"
echo "   genuinamente do zero (ADR 0013 'Segunda execução'): sync completo sem nenhuma"
echo "   intervenção manual. Se algo travar mesmo assim, não é mais este bug conhecido --"
echo "   investigar do zero."
