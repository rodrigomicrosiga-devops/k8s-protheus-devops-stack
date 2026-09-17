#!/usr/bin/env bash
# Orquestra um ciclo completo de worker/compile no cluster k8s, replicando a
# "esteira elástica síncrona" do run.sh do Compose (ver
# docker-protheus-devops-stack/run.sh linhas 148-215): para core/rest/telnet,
# roda o Job, religa o que estava ativo -- mesmo se o Job falhar.
#
# Uso: ./scripts/appserver-patch/run-job.sh worker|compile
#
# Pré-requisito pra worker: pelo menos um .ptm em
#   /media/rodrigo/dados/k8s-volume/protheus-patches/
# (deposite com `cp arquivo.ptm /media/rodrigo/dados/k8s-volume/protheus-patches/`
# -- sem isso o worker roda como no-op, exit 0, sem erro).
# Pré-requisito pra compile: .prw/.tlpp reais em
#   /media/rodrigo/dados/k8s-volume/protheus-patches/ -- compile FALHA se não
# achar nenhum fonte (ao contrário do worker).
#
# Ver README.md deste diretório para mais contexto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

ROLE="${1:-}"
if [ "$ROLE" != "worker" ] && [ "$ROLE" != "compile" ]; then
  echo "Uso: $0 worker|compile" >&2
  exit 1
fi

JOB_NAME="appserver-${ROLE}"
JOB_FILE="${REPO_ROOT}/base/appserver-${ROLE}-job.yaml"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-900}"

echo "=== Portão de segurança: bootstrap já concluído? ==="
check_bootstrap_done

# Garante que o ecossistema volta ao estado original mesmo se o script for
# interrompido (Ctrl-C, falha de rede, o que for) -- diferente do run.sh, que
# perde o estado (variáveis de shell) se o processo morrer no meio.
STARTED=0
cleanup() {
  if [ "$STARTED" -eq 1 ]; then
    echo "=== Restaurando appserver-core/rest/telnet ==="
    restore_appservers
  fi
}
trap cleanup EXIT

echo "=== Isolando o .rpo: parando appserver-core/rest/telnet ativos ==="
stop_appservers
STARTED=1

echo "=== Rodando Job $JOB_NAME ==="
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl apply -f "$JOB_FILE"

waited=0
STATUS=""
while [ "$waited" -lt "$JOB_TIMEOUT_SECONDS" ]; do
  SUCCEEDED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
  FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")
  if [ "$SUCCEEDED" = "1" ]; then
    STATUS="succeeded"
    break
  fi
  if [ -n "$FAILED" ] && [ "$FAILED" -ge 1 ] 2>/dev/null; then
    STATUS="failed"
    break
  fi
  sleep 5
  waited=$((waited + 5))
done

if [ -z "$STATUS" ]; then
  echo "ERRO: Job $JOB_NAME não terminou em ${JOB_TIMEOUT_SECONDS}s (timeout)." >&2
  STATUS="timeout"
fi

echo "=== Logs de $JOB_NAME ==="
kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" --tail=200 || true

if [ "$STATUS" != "succeeded" ]; then
  echo "Job $JOB_NAME terminou com status: $STATUS" >&2
  exit 1
fi

echo "Job $JOB_NAME concluído com sucesso."
