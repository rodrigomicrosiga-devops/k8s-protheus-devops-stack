#!/usr/bin/env bash
# Orquestra um ciclo completo de worker/compile/upddistr no cluster k8s,
# replicando a "esteira elástica síncrona" do run.sh do Compose (ver
# docker-protheus-devops-stack/run.sh linhas 148-215): para core/rest/telnet,
# roda o Job, religa o que estava ativo -- mesmo se o Job falhar.
#
# Uso: ./scripts/appserver-patch/run-job.sh worker|compile|upddistr
#
# Pré-requisito pra worker: pelo menos um .ptm em
#   /media/rodrigo/dados/k8s-volume/protheus-patches/
# (deposite com `cp arquivo.ptm /media/rodrigo/dados/k8s-volume/protheus-patches/`
# -- sem isso o worker roda como no-op, exit 0, sem erro).
# Pré-requisito pra compile: .prw/.tlpp reais em
#   /media/rodrigo/dados/k8s-volume/protheus-patches/ -- compile FALHA se não
# achar nenhum fonte (ao contrário do worker).
# Pré-requisito pra upddistr: arquivos de atualização (SX*, *.mzp, sdf*) já
#   depositados na RAIZ de /media/rodrigo/dados/k8s-volume/protheus-systemload/
#   (sem subdiretórios).
#
# Ver README.md deste diretório para mais contexto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

ROLE="${1:-}"
if [ "$ROLE" != "worker" ] && [ "$ROLE" != "compile" ] && [ "$ROLE" != "upddistr" ]; then
  echo "Uso: $0 worker|compile|upddistr" >&2
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

kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null

if [ "$ROLE" = "upddistr" ]; then
  # upddistr nunca termina sozinho e o exit code do Pod não é confiável
  # (o sidecar manda SIGTERM no appsrvlinux, não é um shutdown limpo
  # garantido) -- o veredito real é o CONTEÚDO de Result.json/result.json,
  # lido direto do bind mount do host, mesmo critério do run.sh. Ver
  # comentário completo em base/appserver-upddistr-job.yaml.
  echo "=== Limpando veredito anterior (Result.json/result.json) ==="
  remove_old_result_files

  echo "=== Rodando Job $JOB_NAME ==="
  kubectl apply -f "$JOB_FILE"

  echo "=== Aguardando veredito (até ${JOB_TIMEOUT_SECONDS}s) ==="
  if RESULT_FILE=$(wait_for_result_file "$JOB_TIMEOUT_SECONDS"); then
    echo "Veredito em: $RESULT_FILE"
    if check_result_success "$RESULT_FILE"; then
      STATUS="succeeded"
    else
      STATUS="failed"
    fi
  else
    echo "ERRO: nenhum veredito apareceu em ${JOB_TIMEOUT_SECONDS}s (timeout)." >&2
    STATUS="timeout"
  fi

  echo "=== Logs de $JOB_NAME (appserver-upddistr + result-watcher) ==="
  kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" -c appserver-upddistr --tail=100 || true
  kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" -c result-watcher --tail=20 || true
else
  echo "=== Rodando Job $JOB_NAME ==="
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
fi

if [ "$STATUS" != "succeeded" ]; then
  echo "Job $JOB_NAME terminou com status: $STATUS" >&2
  exit 1
fi

echo "Job $JOB_NAME concluído com sucesso."
