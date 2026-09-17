#!/usr/bin/env bash
# Constantes e helpers compartilhados por run-job.sh. Ver
# scripts/appserver-patch/README.md.
set -euo pipefail

NAMESPACE="protheus-devops"
ARGOCD_NAMESPACE="argocd"
ARGOCD_APP="protheus-devops-stack"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Deployments que disputam o .rpo com worker/compile -- precisam estar a 0
# réplicas antes do Job rodar. Ordem importa na restauração (core primeiro,
# igual ao run.sh do Compose).
APPSERVER_DEPLOYS=(appserver-core appserver-rest appserver-telnet)
declare -A APPSERVER_FILES=(
  [appserver-core]="$REPO_ROOT/base/appserver-core.yaml"
  [appserver-rest]="$REPO_ROOT/base/appserver-rest.yaml"
  [appserver-telnet]="$REPO_ROOT/base/appserver-telnet.yaml"
)

# Portão de segurança: a regra mais cara do projeto (CLAUDE.md) é que
# worker/compile/upddistr NUNCA rodam antes do bootstrap manual do AppServer
# estar completo. Em vez de confiar só em documentação, checa de verdade se
# as tabelas SYS_* já existem -- é o mesmo sinal usado nesta sessão pra
# confirmar que o bootstrap não foi reaberto.
check_bootstrap_done() {
  local count
  count=$(kubectl exec -n "$NAMESPACE" deploy/postgres -- \
    psql -U protheus -d protheus -tAc \
    "SELECT count(*) FROM pg_tables WHERE tablename ILIKE 'sys_%';" 2>/dev/null || echo "0")
  if [ "${count:-0}" -lt 1 ] 2>/dev/null; then
    echo "ERRO: nenhuma tabela SYS_* encontrada no banco 'protheus'." >&2
    echo "Isso significa que o bootstrap manual do AppServer (ver CLAUDE.md) ainda" >&2
    echo "não foi concluído. worker/compile/upddistr NUNCA rodam antes disso --" >&2
    echo "violar essa regra já poluiu o banco uma vez (2026-07-30, ver docs/HANDOFF.md)." >&2
    return 1
  fi
  echo "Bootstrap confirmado: $count tabelas SYS_* presentes."
}

get_replicas() {
  kubectl get deploy "$1" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
}

set_replicas_in_git() {
  local deploy="$1" n="$2"
  local file="${APPSERVER_FILES[$deploy]}"
  sed -i "s/^  replicas: [0-9]\+/  replicas: $n/" "$file"
}

git_commit_and_push() {
  local msg="$1"
  cd "$REPO_ROOT"
  if git diff --quiet -- base/; then
    echo "Nada mudou em base/ -- pulando commit."
    return 0
  fi
  git add base/appserver-core.yaml base/appserver-rest.yaml base/appserver-telnet.yaml
  git commit -m "$msg"
  git push origin "$(git rev-parse --abbrev-ref HEAD)"
}

# Acelera o polling padrão do Argo CD (pode levar minutos) -- mesma técnica
# usada ao vivo nesta sessão para a Fase D e o image-updater.
refresh_argocd() {
  kubectl patch application "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null
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

# Para os appservers que estavam ativos (replicas > 0), commitando e
# empurrando pro git -- nunca `kubectl scale` direto (o Argo CD selfHeal
# desfaria no sync seguinte, ver comentário em base/appserver-worker-job.yaml).
stop_appservers() {
  declare -gA ORIGINAL_REPLICAS=()
  local any_changed=0
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    local current
    current="$(get_replicas "$d")"
    ORIGINAL_REPLICAS[$d]="$current"
    if [ "$current" != "0" ]; then
      echo "Parando $d (estava com $current réplica(s))..."
      set_replicas_in_git "$d" 0
      any_changed=1
    fi
  done
  if [ "$any_changed" -eq 1 ]; then
    git_commit_and_push "chore: Fase E -- pausa appserver-core/rest/telnet pra patch/compile"
    refresh_argocd
    for d in "${APPSERVER_DEPLOYS[@]}"; do
      [ "${ORIGINAL_REPLICAS[$d]}" != "0" ] && wait_for_pods_gone "$d"
    done
  fi
  echo "Isolamento do .rpo confirmado -- nenhum appserver-core/rest/telnet ativo."
}

# Restaura exatamente o que estava ativo antes -- roda mesmo se o Job falhou
# (mesma ordem do run.sh: restaura antes de propagar o erro).
restore_appservers() {
  local any_changed=0
  for d in "${APPSERVER_DEPLOYS[@]}"; do
    local want="${ORIGINAL_REPLICAS[$d]:-1}"
    if [ "$want" != "0" ]; then
      echo "Restaurando $d pra $want réplica(s)..."
      set_replicas_in_git "$d" "$want"
      any_changed=1
    fi
  done
  if [ "$any_changed" -eq 1 ]; then
    git_commit_and_push "chore: Fase E -- restaura appserver-core/rest/telnet pós patch/compile"
    refresh_argocd
    for d in "${APPSERVER_DEPLOYS[@]}"; do
      [ "${ORIGINAL_REPLICAS[$d]:-1}" != "0" ] && wait_for_pods_ready "$d"
    done
  fi
}
