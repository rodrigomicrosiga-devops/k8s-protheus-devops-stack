#!/usr/bin/env bash
# Sela os segredos de UMA topologia para o namespace dado (ADR 0028, opcao A) e grava os SealedSecret no catalogo privado.
#
#   scripts/secrets/seal-topology.sh <namespace>                    -> CONFERE sem ler nenhum valor
#   scripts/secrets/seal-topology.sh --run <namespace>              -> sela de verdade (pede a passphrase do cofre)
#   scripts/secrets/seal-topology.sh --run --with-upddistr <ns>     -> inclui tambem o appserver-upddistr-secret
#
# Por padrao sela so o que a topologia precisa ANTES dos workloads: postgres-secret e smartview-secret. O
# appserver-upddistr-secret e opcional (so depois do bootstrap manual do AppServer; ADR 0028, pergunta 4).
# O regcred NAO e selado aqui: nao esta no cofre (e uma credencial de registro, opcional por topologia).
#
# Por que re-selar: o SealedSecret e escopo "strict" (nome + namespace); copiar o YAML para outro namespace nao abre.
#
# Garantias: o valor NUNCA vai para a tela, para argumento de comando, para variavel de ambiente nem para disco
# (so tmpfs, apagado ao sair). Prova a passphrase ANTES de ler. Recusa sobrescrever arquivo existente, recusa o
# namespace da producao e confere que as chaves seladas sao as mesmas do SealedSecret de topology/.
# Precisa de TTY (pinentry): rode com `! scripts/secrets/seal-topology.sh --run <namespace>`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="${CATALOG_DIR:-$ROOT/../protheus-catalog}"
PROOF="base/postgres-secret.env.gpg"          # arquivo do cofre que prova a passphrase
LIVE_NS="${LIVE_NAMESPACE:-protheus-devops}"  # nunca selar para a producao por aqui
CTRL_NAME="${SEALED_CONTROLLER_NAME:-sealed-secrets-controller}"
CTRL_NS="${SEALED_CONTROLLER_NAMESPACE:-kube-system}"
SECRETS=(postgres-secret smartview-secret)

MODE=check; NS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) MODE=run ;;
    --with-upddistr) SECRETS+=(appserver-upddistr-secret) ;;
    -*) echo "uso: $0 [--run] [--with-upddistr] <namespace>" >&2; exit 2 ;;
    *) [ -z "$NS" ] || { echo "uso: $0 [--run] [--with-upddistr] <namespace>" >&2; exit 2; }; NS="$1" ;;
  esac
  shift
done
[ -n "$NS" ] || { echo "uso: $0 [--run] [--with-upddistr] <namespace>" >&2; exit 2; }
cd "$ROOT"

fail() { echo "❌ $*" >&2; exit 1; }
# nomes de chave do SealedSecret de referencia em topology/ (so nomes, nunca valores)
ref_keys() { awk '/^  encryptedData:/{f=1;next} f&&/^    [A-Za-z0-9_.-]+:/{sub(/^    /,"");sub(/:.*/,"");print;next} f&&!/^    /{f=0}' "topology/$1.sealed.yaml" | sort; }

echo "== conferencia (nenhum valor lido)"
[[ "$NS" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || fail "namespace invalido: '$NS'"
[ "$NS" != "$LIVE_NS" ] || fail "'$NS' e o namespace da producao: este script sela so para topologias NOVAS"
[ -f "$PROOF" ] || fail "$PROOF nao existe: sem ele nao ha como provar a passphrase do cofre"
[ -d "$CATALOG/.git" ] || fail "catalogo privado nao encontrado em $CATALOG (defina CATALOG_DIR)"
OUT="$CATALOG/topologies/$NS"
for s in "${SECRETS[@]}"; do
  [ -f "base/${s}.env.gpg" ] || fail "base/${s}.env.gpg nao existe no cofre"
  [ -f "topology/${s}.sealed.yaml" ] || fail "topology/${s}.sealed.yaml (referencia de chaves) nao existe"
  [ -n "$(ref_keys "$s")" ] || fail "nao consegui ler as chaves de topology/${s}.sealed.yaml"
  [ ! -e "$OUT/${s}.sealed.yaml" ] || fail "$OUT/${s}.sealed.yaml ja existe: este script nao sobrescreve"
  echo "ok  $s -> $OUT/${s}.sealed.yaml   chaves: $(ref_keys "$s" | tr '\n' ' ')"
done
KS=(kubeseal --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" --scope strict --format yaml)
[ -z "${SEALED_CERT:-}" ] || KS=(kubeseal --cert "$SEALED_CERT" --scope strict --format yaml)
[ "$MODE" = run ] || { echo; echo "(conferencia ok; para selar de verdade: $0 --run $NS)"; exit 0; }

[ -t 0 ] || fail "sem TTY: o pinentry precisa de terminal (rode com '! $0 --run $NS')"
TMP="$(mktemp -d -p "$([ -d /dev/shm ] && echo /dev/shm || echo "${TMPDIR:-/tmp}")" seal-topology.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
umask 077

echo; echo "== 1/3 prova da passphrase (decifra $PROOF e descarta a saida)"
gpg --quiet --decrypt "$PROOF" >/dev/null || fail "a passphrase NAO abriu $PROOF: nada foi lido nem gravado"

mkdir -p "$OUT"
written=()
cleanup_written() { for f in "${written[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
for s in "${SECRETS[@]}"; do
  plain="$TMP/${s}.env"; sealed="$TMP/${s}.sealed.yaml"; dest="$OUT/${s}.sealed.yaml"
  echo; echo "== 2/3 $s: decifra (para tmpfs) e sela para o namespace '$NS'"
  gpg --quiet --decrypt "base/${s}.env.gpg" >"$plain" || { cleanup_written; fail "falha ao decifrar $s"; }
  [ -s "$plain" ] || { cleanup_written; fail "$s decifrado veio vazio"; }
  # chaves do cofre == chaves do SealedSecret de referencia (so nomes)
  [ "$(cut -d= -f1 "$plain" | grep -v '^$' | sort)" = "$(ref_keys "$s")" ] || { cleanup_written; fail "$s: as chaves do cofre nao batem com topology/${s}.sealed.yaml"; }
  kubectl create secret generic "$s" --namespace "$NS" --from-env-file="$plain" --dry-run=client -o yaml \
    | "${KS[@]}" >"$sealed" || { cleanup_written; fail "falha ao selar $s (kubeseal alcanca o cluster/certificado?)"; }
  echo "== 3/3 $s: confere o resultado (so estrutura, nenhum valor)"
  grep -q '^kind: SealedSecret' "$sealed" || { cleanup_written; fail "$s: a saida nao e um SealedSecret"; }
  [ "$(awk '/^metadata:/{m=1;next} m&&/^  namespace:/{print $2;exit}' "$sealed")" = "$NS" ] || { cleanup_written; fail "$s: namespace da saida difere de '$NS'"; }
  [ "$(awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2;exit}' "$sealed")" = "$s" ] || { cleanup_written; fail "$s: nome da saida difere"; }
  [ "$(awk '/^  encryptedData:/{f=1;next} f&&/^    [A-Za-z0-9_.-]+:/{sub(/^    /,"");sub(/:.*/,"");print;next} f&&!/^    /{f=0}' "$sealed" | sort)" = "$(ref_keys "$s")" ] || { cleanup_written; fail "$s: chaves seladas diferem das de referencia"; }
  mv "$sealed" "$dest"; written+=("$dest")
  echo "ok  $s: $dest"
done
echo; echo "✅ ${#written[@]} SealedSecret(s) gravado(s) em $OUT (cifrados; seguros para o git do catalogo PRIVADO)."
echo "Proximo passo (voce): revisar, commitar no catalogo e aplicar em '$NS' -- nada foi aplicado no cluster."
