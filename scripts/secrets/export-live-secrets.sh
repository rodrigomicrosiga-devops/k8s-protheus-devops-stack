#!/usr/bin/env bash
# Exporta Secrets que SO existem dentro do cluster para o cofre GPG (ADR 0011 / ADR 0028): hoje `smartview-secret`
# (SV_PASS) e `appserver-upddistr-secret` (UPD_PASSWORD) nao tem backup cifrado no repo.
#
#   scripts/secrets/export-live-secrets.sh          -> CONFERE sem ler nenhum valor (so nomes de chave e caminhos)
#   scripts/secrets/export-live-secrets.sh --run    -> exporta de verdade (pede a passphrase do cofre varias vezes)
#
# Garantias: o valor NUNCA vai para a tela, para argumento de comando, para variavel de ambiente nem para disco
# (so tmpfs, apagado ao sair). Antes de ler qualquer coisa prova que a passphrase digitada abre um arquivo do cofre
# que ja existe; depois de cifrar, prova que o arquivo NOVO abre e e identico ao original (por hash). Recusa
# sobrescrever um .gpg existente. Precisa de TTY (pinentry): rode com `! scripts/secrets/export-live-secrets.sh --run`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${EXPORT_NAMESPACE:-protheus-devops}"
PROOF="base/postgres-secret.env.gpg"          # arquivo do cofre que prova a passphrase
SECRETS=(smartview-secret appserver-upddistr-secret)
MODE="${1:-check}"; [ "$MODE" = "--run" ] && MODE=run
[ "$MODE" = "check" ] || [ "$MODE" = "run" ] || { echo "uso: $0 [--run]" >&2; exit 2; }
cd "$ROOT"

fail() { echo "❌ $*" >&2; exit 1; }
keys_of() { kubectl -n "$NS" get secret "$1" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'; }

echo "== conferencia (nenhum valor lido)"
[ -f "$PROOF" ] || fail "$PROOF nao existe: sem ele nao ha como provar a passphrase do cofre"
for s in "${SECRETS[@]}"; do
  plain="base/${s}.env"; enc="${plain}.gpg"
  keys="$(keys_of "$s" 2>/dev/null)" || fail "Secret $s nao existe em $NS (ou o cluster nao responde)"
  [ -n "$keys" ] || fail "Secret $s existe mas esta vazio"
  git check-ignore -q "$plain" || fail "$plain NAO esta no .gitignore: o texto puro poderia ir para o git"
  [ ! -e "$enc" ] || fail "$enc ja existe: este script nao sobrescreve o cofre"
  [ ! -e "$plain" ] || fail "$plain ja existe em texto puro no disco: apague antes (rm $plain)"
  echo "ok  $s -> $enc   chaves: $(echo "$keys" | tr '\n' ' ')"
done
[ "$MODE" = run ] || { echo; echo "(conferencia ok; para exportar de verdade: $0 --run)"; exit 0; }

[ -t 0 ] || fail "sem TTY: o pinentry precisa de terminal (rode com '! $0 --run')"
TMP="$(mktemp -d -p "$([ -d /dev/shm ] && echo /dev/shm || echo "${TMPDIR:-/tmp}")" export-secrets.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
umask 077

echo; echo "== 1/3 prova da passphrase (decifra $PROOF e descarta a saida)"
gpg --quiet --decrypt "$PROOF" >/dev/null || fail "a passphrase NAO abriu $PROOF: nada foi lido nem gravado"

for s in "${SECRETS[@]}"; do
  plain="$TMP/${s}.env"; enc="base/${s}.env.gpg"
  echo; echo "== 2/3 $s: le do cluster (para tmpfs) e cifra -> $enc"
  kubectl -n "$NS" get secret "$s" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}' >"$plain"
  [ -s "$plain" ] || fail "leitura de $s devolveu vazio"
  n="$(grep -c '=' "$plain")"; [ "$n" -eq "$(keys_of "$s" | grep -c .)" ] || fail "$s: numero de chaves lidas ($n) difere do cluster"
  gpg --symmetric --cipher-algo AES256 --output "$enc" "$plain" || { rm -f "$enc"; fail "falha ao cifrar $s"; }
  echo "== 3/3 $s: prova que o arquivo NOVO abre com a passphrase do cofre e e identico ao original"
  want="$(sha256sum <"$plain" | cut -d' ' -f1)"
  got="$(gpg --quiet --decrypt "$enc" | sha256sum | cut -d' ' -f1)" || got=""
  if [ "$got" != "$want" ]; then rm -f "$enc"; fail "$enc NAO abriu/NAO bate: removido. Provavel passphrase digitada diferente da do cofre; nada foi perdido (o Secret segue no cluster)"; fi
  echo "ok  $s: $n chave(s), round-trip confere"
done
echo; echo "✅ cofre atualizado. Proximo passo (voce): git add base/smartview-secret.env.gpg base/appserver-upddistr-secret.env.gpg && commit."
