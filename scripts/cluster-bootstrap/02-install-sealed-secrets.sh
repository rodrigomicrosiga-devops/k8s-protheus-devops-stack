#!/usr/bin/env bash
# Instala o sealed-secrets controller e restaura as chaves de decriptação
# antigas ANTES dele processar qualquer coisa com uma chave nova gerada por
# conta própria -- essencial pra que os SealedSecret já commitados no git
# (base/*.sealed.yaml) continuem decriptáveis no cluster novo.
#
# Pré-requisito: scripts/cluster-bootstrap/sealed-secrets-keys-backup.yaml
# precisa existir (decriptar primeiro: ../secrets/decrypt.sh
# sealed-secrets-keys-backup.yaml.gpg).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_BACKUP="${SCRIPT_DIR}/sealed-secrets-keys-backup.yaml"
DEPLOY="sealed-secrets-controller"

if [ ! -f "$KEYS_BACKUP" ]; then
  echo "❌ $KEYS_BACKUP não encontrado." >&2
  echo "   Decriptar primeiro: ../secrets/decrypt.sh ${KEYS_BACKUP}.gpg" >&2
  exit 1
fi

helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets 2>/dev/null || true
helm repo update sealed-secrets >/dev/null

echo "=== Instalando sealed-secrets ==="
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  -f "${SCRIPT_DIR}/helm-values/sealed-secrets.yaml" \
  --wait --timeout 120s

echo "=== Pausando o controller antes que ele gere/use uma chave nova por conta própria ==="
kubectl scale deployment "$DEPLOY" -n kube-system --replicas=0
kubectl wait --for=delete pod -n kube-system -l app.kubernetes.io/name=sealed-secrets --timeout=60s 2>/dev/null || true

echo "=== Restaurando as chaves antigas ==="
kubectl apply -f "$KEYS_BACKUP"

echo "=== Religando o controller (agora com as chaves restauradas presentes) ==="
kubectl scale deployment "$DEPLOY" -n kube-system --replicas=1
kubectl rollout status deployment "$DEPLOY" -n kube-system --timeout=60s

echo
echo "✅ sealed-secrets pronto com as chaves antigas restauradas."
echo "👉 Validação real só é possível depois que argocd/application.yaml for aplicado e"
echo "   sincronizar os SealedSecret de base/ -- confira depois que os Secrets reais"
echo "   (regcred, postgres-secret, etc.) aparecem em protheus-devops sem erro."
