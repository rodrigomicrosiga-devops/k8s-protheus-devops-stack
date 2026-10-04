#!/usr/bin/env bash
# Constantes e helpers compartilhados por run-job.sh. Ver
# scripts/appserver-patch/README.md.
set -euo pipefail

NAMESPACE="protheus-devops"
ARGOCD_NAMESPACE="argocd"
ARGOCD_APP="protheus-devops-stack"

SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR_LIB}/../.." && pwd)"

# Node k3d onde os PVs hostPath estão fixados (nodeAffinity) -- usado pro
# upddistr, cujo veredito de sucesso/falha vem do CONTEÚDO de um arquivo no
# bind mount real (ADR 0008), não do status do Job (ver
# base/appserver-upddistr-job.yaml pro raciocínio completo).
K3D_AGENT_NODE="k3d-protheus-cluster-agent-0"
SYSTEMLOAD_HOSTPATH="/media/rodrigo/dados/k8s-volume/protheus-systemload"

# Deployments que disputam o .rpo com worker/compile -- precisam estar a 0
# réplicas antes do Job rodar. Ordem importa na restauração (core primeiro,
# igual ao run.sh do Compose).
APPSERVER_DEPLOYS=(appserver-core appserver-rest appserver-telnet)

# Portão de segurança: a regra mais cara do projeto (CLAUDE.md) é que
# worker/compile/upddistr NUNCA rodam antes do bootstrap manual do AppServer
# estar completo. Em vez de confiar só em documentação, checa de verdade o banco.
# Antes (até 2026-10-04) bastava UMA tabela SYS_* -- passava com o dicionário
# parcial de 20/09 (28 tabelas faltando, login travado). Agora exige a PRESENÇA
# de cada tabela listada em required-sys-tables.txt (ADR 0019, item 5). Sem
# --force: se faltar, o bootstrap não está completo.
REQUIRED_TABLES_FILE="${SCRIPT_DIR_LIB}/required-sys-tables.txt"

check_bootstrap_done() {
  local present missing required
  # Falha FECHADA: sem a lista de tabelas obrigatórias legível e não vazia, o gate
  # não tem como validar nada -- recusar, nunca deixar passar por "nada faltando".
  required=$(grep -vE '^(#|$)' "$REQUIRED_TABLES_FILE" 2>/dev/null || true)
  if [ -z "$required" ]; then
    echo "ERRO: lista de tabelas obrigatórias ausente ou vazia: $REQUIRED_TABLES_FILE" >&2
    echo "Sem ela o portão do bootstrap não consegue validar o dicionário -- recusando." >&2
    return 1
  fi
  present=$(kubectl exec -n "$NAMESPACE" deploy/postgres -- \
    psql -U protheus -d protheus -tAc \
    "SELECT lower(tablename) FROM pg_tables WHERE tablename ILIKE 'sys\\_%';" 2>/dev/null || true)
  if [ -z "$present" ]; then
    echo "ERRO: nenhuma tabela SYS_* encontrada no banco 'protheus' (ou o banco não respondeu)." >&2
    echo "O bootstrap manual do AppServer (ver CLAUDE.md) ainda não foi concluído." >&2
    echo "worker/compile/upddistr NUNCA rodam antes disso -- violar essa regra já poluiu" >&2
    echo "o banco uma vez (2026-07-30, ver docs/HANDOFF.md)." >&2
    return 1
  fi
  missing=$(grep -vxFf <(printf '%s\n' "$present") <<<"$required" || true)
  if [ -n "$missing" ]; then
    echo "ERRO: dicionário incompleto -- faltam $(wc -l <<<"$missing") tabela(s) obrigatória(s):" >&2
    sed 's/^/  - /' <<<"$missing" >&2
    echo "Bootstrap manual não concluído (ou dicionário criado pela metade, ADR 0006)." >&2
    return 1
  fi
  echo "Bootstrap confirmado: $(wc -l <<<"$required") tabelas obrigatórias presentes."
}

get_replicas() {
  kubectl get deploy "$1" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
}

wait_for_pods_gone() {
  local app_label="$1" timeout="${2:-180}" waited=0
  while [ -n "$(kubectl get pods -n "$NAMESPACE" -l "app=$app_label" --no-headers 2>/dev/null)" ]; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "ERRO: pods de '$app_label' não sumiram em ${timeout}s." >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

wait_for_pods_ready() {
  local app_label="$1" timeout="${2:-180}" waited=0
  while true; do
    local ready
    ready=$(kubectl get pods -n "$NAMESPACE" -l "app=$app_label" \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)
    if [ -n "$ready" ] && ! grep -qv "true" <<<"$ready"; then
      return 0
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "ERRO: pod de '$app_label' não ficou Ready em ${timeout}s." >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

# Para os appservers que estavam ativos (replicas > 0) com `kubectl scale`
# direto. Funciona porque o Application ignora /spec/replicas de Deployments
# (ignoreDifferences + RespectIgnoreDifferences, ADR 0019 e argocd/application.yaml)
# -- até 2026-10-04 isto commitava `replicas: 0` e `replicas: N` no git (dois
# commits por execução) porque o selfHeal revertia qualquer scale direto.
stop_appservers() {
  declare -gA ORIGINAL_REPLICAS=()
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    local current
    current="$(get_replicas "$d")"
    ORIGINAL_REPLICAS[$d]="$current"
    if [ "$current" != "0" ]; then
      echo "Parando $d (estava com $current réplica(s))..."
      kubectl scale deploy "$d" -n "$NAMESPACE" --replicas=0 >/dev/null
    fi
  done
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    [ "${ORIGINAL_REPLICAS[$d]}" != "0" ] && wait_for_pods_gone "$d"
  done
  echo "Isolamento do .rpo confirmado -- nenhum appserver-core/rest/telnet ativo."
}

# Restaura exatamente o que estava ativo antes -- roda mesmo se o Job falhou
# (mesma ordem do run.sh: restaura antes de propagar o erro).
restore_appservers() {
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    local want="${ORIGINAL_REPLICAS[$d]:-1}"
    if [ "$want" != "0" ]; then
      echo "Restaurando $d pra $want réplica(s)..."
      kubectl scale deploy "$d" -n "$NAMESPACE" --replicas="$want" >/dev/null
    fi
  done
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    [ "${ORIGINAL_REPLICAS[$d]:-1}" != "0" ] && wait_for_pods_ready "$d"
  done
}

# --- upddistr: veredito lido direto do bind mount do host, não do Job ---

remove_old_result_files() {
  docker exec "$K3D_AGENT_NODE" sh -c \
    "rm -f '$SYSTEMLOAD_HOSTPATH/Result.json' '$SYSTEMLOAD_HOSTPATH/result.json'"
}

# Eco o caminho do arquivo encontrado (Result.json ou result.json) em stdout.
# Retorna 1 se estourar o timeout.
wait_for_result_file() {
  local timeout="${1:-900}" waited=0 found=""
  while [ "$waited" -lt "$timeout" ]; do
    if docker exec "$K3D_AGENT_NODE" test -f "$SYSTEMLOAD_HOSTPATH/Result.json" 2>/dev/null; then
      found="$SYSTEMLOAD_HOSTPATH/Result.json"
    elif docker exec "$K3D_AGENT_NODE" test -f "$SYSTEMLOAD_HOSTPATH/result.json" 2>/dev/null; then
      found="$SYSTEMLOAD_HOSTPATH/result.json"
    fi
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# Sai 0 se o arquivo contiver "success" (mesmo critério do run.sh:
# `grep -q "success"`), imprime o conteúdo em stderr pra visibilidade.
check_result_success() {
  local path="$1"
  docker exec "$K3D_AGENT_NODE" cat "$path" >&2
  docker exec "$K3D_AGENT_NODE" grep -q "success" "$path"
}
