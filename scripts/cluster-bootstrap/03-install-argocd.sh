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
echo "⚠️  O primeiro sync VAI travar no hook PreSync smartview-db-init num bootstrap"
echo "   genuinamente do zero -- confirmado ao vivo (ADR 0013): o hook depende do"
echo "   Secret 'postgres-secret', que é recurso comum de Sync (não hook), então nunca"
echo "   existe a tempo. Se 'kubectl get pods -n protheus-devops' mostrar"
echo "   smartview-db-init em CreateContainerConfigError esperando 'postgres-secret',"
echo "   desbloquear manualmente (bypass pontual do Argo CD, mesmo padrão do ADR 0012):"
echo "     kubectl apply -f base/postgres-secret.sealed.yaml"
echo "     kubectl kustomize base/ | ... extrair o ConfigMap postgres-config-<hash> e aplicar"
echo "     kubectl apply -f base/postgres.yaml   # cria PV/PVC/Deployment direto"
echo "     kubectl patch deployment postgres -n protheus-devops --type json -p '...'  # fixar envFrom"
echo "   Depois disso o resto do sync completa sozinho. Ver ADR 0013 'Validação' pro"
echo "   passo a passo exato que funcionou."
