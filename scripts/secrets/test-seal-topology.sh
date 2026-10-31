#!/usr/bin/env bash
# Teste do seal-topology.sh com kubectl/gpg/kubeseal FALSOS num repo descartavel (nenhum segredo real e tocado).
# Os falsos IMITAM o real: o kubectl le o --from-env-file de verdade (falha se faltar), o kubeseal recusa entrada
# vazia e so emite o que recebeu, o gpg so abre o que "cifrou".
# Uso: scripts/secrets/test-seal-topology.sh [caminho-do-script]  (o argumento serve ao teste de mutacao)
set -uo pipefail
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-topology.sh}"
fails=0; n=0
ok(){ n=$((n+1)); echo "  ok   - $1"; }; bad(){ n=$((n+1)); fails=$((fails+1)); echo "  FALHA - $1"; }
mk() { # cria repo + catalogo falsos novos
  W="$(mktemp -d)"; R="$W/repo"; C="$W/catalog"; mkdir -p "$R/scripts/secrets" "$R/base" "$R/topology" "$W/bin" "$C/.git"
  cp "$SRC" "$R/scripts/secrets/seal-topology.sh"
  echo "cofre" >"$R/base/postgres-secret.env.gpg"
  printf 'DB_PASS=valor-falso-pg\nDB_PASSWORD=valor-falso-pg\nPOSTGRES_PASSWORD=valor-falso-pg\n' >"$R/base/postgres-secret.env.gpg"
  printf 'SV_PASS=valor-falso-sv\n' >"$R/base/smartview-secret.env.gpg"
  printf 'UPD_PASSWORD=valor-falso-upd\n' >"$R/base/appserver-upddistr-secret.env.gpg"
  ref() { printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: %s\n  namespace: protheus-devops\nspec:\n  encryptedData:\n' "$1" >"$R/topology/$1.sealed.yaml"; shift; for k in "$@"; do echo "    $k: AgBxxxx" >>"$R/topology/${SN}.sealed.yaml"; done; }
  SN=postgres-secret; ref postgres-secret DB_PASS DB_PASSWORD POSTGRES_PASSWORD
  SN=smartview-secret; ref smartview-secret SV_PASS
  SN=appserver-upddistr-secret; ref appserver-upddistr-secret UPD_PASSWORD
  cat >"$W/bin/gpg" <<'EOF'
#!/usr/bin/env bash
echo "gpg $*" >>"$FAKE_LOG"
if [ "$1" = "--quiet" ] && [ "$2" = "--decrypt" ]; then
  case "$3" in *postgres-secret*) [ "${FAKE_GPG_FAIL_PROOF:-}" = 1 ] && exit 2 ;; esac
  [ "${FAKE_GPG_EMPTY:-}" = 1 ] && [ "$3" = "base/smartview-secret.env.gpg" ] && exit 0
  [ "${FAKE_GPG_WRONGKEYS:-}" = 1 ] && [ "$3" = "base/smartview-secret.env.gpg" ] && { echo "OUTRA=x"; exit 0; }
  cat "$3"; exit 0
fi
exit 9
EOF
  cat >"$W/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
[ "$1 $2 $3" = "create secret generic" ] || exit 9
name="$4"; ns=""; file=""
for a in "$@"; do case "$a" in --namespace=*) ns="${a#*=}";; --from-env-file=*) file="${a#*=}";; esac; done
shift 4; while [ $# -gt 0 ]; do case "$1" in --namespace) ns="$2"; shift;; --from-env-file) file="$2"; shift;; esac; shift; done
[ -f "$file" ] || { echo "error: open $file: no such file" >&2; exit 1; }
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n' "$name" "$ns"
while IFS='=' read -r k v; do [ -n "$k" ] && printf '  %s: %s\n' "$k" "$(printf %s "$v" | base64)"; done <"$file"
EOF
  cat >"$W/bin/kubeseal" <<'EOF'
#!/usr/bin/env bash
echo "kubeseal $*" >>"$FAKE_LOG"
[ "${FAKE_KUBESEAL_FAIL:-}" = 1 ] && { echo "error: cannot fetch certificate" >&2; exit 1; }
in="$(cat)"; [ -n "$in" ] || { echo "error: no input" >&2; exit 1; }
name="$(echo "$in" | awk '/^  name:/{print $2;exit}')"; ns="$(echo "$in" | awk '/^  namespace:/{print $2;exit}')"
[ "${FAKE_KUBESEAL_WRONGNS:-}" = 1 ] && ns=outro
KIND=SealedSecret; [ "${FAKE_KUBESEAL_WRONGKIND:-}" = 1 ] && KIND=Secret
printf 'apiVersion: bitnami.com/v1alpha1\nkind: %s\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  encryptedData:\n' "$KIND" "$name" "$ns"
echo "$in" | awk '/^data:/{f=1;next} f{sub(/^  /,"");sub(/:.*/,"");print "    "$0": AgCIFRADO"}'
EOF
  chmod +x "$W/bin/"*; : >"$W/log"; export FAKE_LOG="$W/log"
}
run() { ( cd "$R" && PATH="$W/bin:$PATH" CATALOG_DIR="$C" SEALED_CERT= script -qec "bash scripts/secrets/seal-topology.sh $*" /dev/null ) >"$W/out" 2>&1; echo $?; }
leftover() { ls -d /dev/shm/seal-topology.* 2>/dev/null | wc -l; }
nvals() { grep -c "base64decode\|valor-falso" "$W/log"; }

mk; rc=$(run --run ns-teste)
[ "$rc" = 0 ] && ok "sucesso: exit 0" || { bad "sucesso: exit $rc"; cat "$W/out"; }
[ -f "$C/topologies/ns-teste/postgres-secret.sealed.yaml" ] && [ -f "$C/topologies/ns-teste/smartview-secret.sealed.yaml" ] && ok "sucesso: 2 SealedSecret gravados no catalogo" || bad "arquivos ausentes"
[ ! -e "$C/topologies/ns-teste/appserver-upddistr-secret.sealed.yaml" ] && ok "sem --with-upddistr o upddistr NAO e selado" || bad "upddistr selado sem pedir"
grep -q "namespace: ns-teste" "$C/topologies/ns-teste/postgres-secret.sealed.yaml" && ok "namespace da topologia nova no arquivo" || bad "namespace errado"
grep -rq "valor-falso\|dmFsb3It" "$C" "$W/out" && bad "O VALOR (ou base64) APARECEU em arquivo/saida" || ok "o valor nao aparece na saida nem no catalogo"
grep -q "valor-falso" "$W/log" && bad "o VALOR apareceu em ARGUMENTO de comando" || ok "o valor nao aparece em argumento de nenhum comando"
[ "$(leftover)" = 0 ] && ok "tmpfs apagado" || bad "sobrou diretorio em /dev/shm"
[ -z "$(find "$R" -name '*.env' -not -name '*.gpg')" ] && ok "nenhum texto puro no repo" || bad "texto puro no repo"
first_dec=$(grep -n "gpg --quiet --decrypt base/postgres" "$W/log" | head -1 | cut -d: -f1); first_k=$(grep -n "^kubectl create" "$W/log" | head -1 | cut -d: -f1)
[ "$first_dec" -lt "$first_k" ] && ok "a prova da passphrase vem ANTES da leitura/selagem" || bad "ordem errada"

mk; rc=$(run --run --with-upddistr ns-teste)
[ "$rc" = 0 ] && [ -f "$C/topologies/ns-teste/appserver-upddistr-secret.sealed.yaml" ] && ok "--with-upddistr sela tambem o upddistr" || bad "--with-upddistr nao selou"

mk; rc=$(FAKE_GPG_FAIL_PROOF=1 run --run ns-teste)
[ "$rc" != 0 ] && ok "passphrase errada: exit != 0" || bad "passphrase errada passou"
grep -q "^kubectl\|^kubeseal" "$W/log" && bad "passphrase errada: chegou a ler/selar" || ok "passphrase errada: nada lido nem selado"
[ ! -e "$C/topologies" ] && ok "passphrase errada: nada gravado" || bad "passphrase errada: gravou"

mk; rc=$(run --run protheus-devops)
[ "$rc" != 0 ] && ! grep -q "^gpg" "$W/log" && ok "recusa o namespace da producao antes de tocar no cofre" || bad "aceitou o namespace da producao"
mk; rc=$(run --run 'Ns_Ruim'); [ "$rc" != 0 ] && ok "namespace invalido recusado" || bad "namespace invalido aceito"

mk; mkdir -p "$C/topologies/ns-teste"; echo NAO-MEXER >"$C/topologies/ns-teste/smartview-secret.sealed.yaml"; rc=$(run --run ns-teste)
[ "$rc" != 0 ] && [ "$(cat "$C/topologies/ns-teste/smartview-secret.sealed.yaml")" = NAO-MEXER ] && [ ! -e "$C/topologies/ns-teste/postgres-secret.sealed.yaml" ] && ok "recusa sobrescrever (conteudo intacto, nada parcial gravado)" || bad "sobrescreveu ou gravou parcial"

mk; rc=$(FAKE_KUBESEAL_FAIL=1 run --run ns-teste)
[ "$rc" != 0 ] && [ -z "$(ls "$C/topologies/ns-teste" 2>/dev/null)" ] && ok "kubeseal falha: exit != 0 e nada gravado" || bad "kubeseal falhou mas gravou/passou"

mk; rc=$(FAKE_GPG_EMPTY=1 run --run ns-teste)
[ "$rc" != 0 ] && [ -z "$(ls "$C/topologies/ns-teste" 2>/dev/null)" ] && ok "segredo vazio no cofre: recusa e remove o parcial (o 1o ja tinha sido selado)" || bad "vazio passou ou deixou parcial"

mk; rc=$(FAKE_GPG_WRONGKEYS=1 run --run ns-teste)
[ "$rc" != 0 ] && [ -z "$(ls "$C/topologies/ns-teste" 2>/dev/null)" ] && ok "chaves do cofre diferentes da referencia: recusa, sem parcial" || bad "chaves erradas passaram"

mk; rc=$(FAKE_KUBESEAL_WRONGKIND=1 run --run ns-teste)
[ "$rc" != 0 ] && [ -z "$(ls "$C/topologies/ns-teste" 2>/dev/null)" ] && ok "saida que nao e SealedSecret: recusa, sem parcial" || bad "saida de kind errado passou"

mk; rc=$(run --run ns-teste)
[ "$(grep -c '^kubeseal .*--scope strict' "$W/log")" = 2 ] && ! grep '^kubeseal' "$W/log" | grep -q 'cluster-wide\|namespace-wide' && ok "kubeseal sempre com --scope strict (nunca cluster-wide)" || bad "escopo do kubeseal nao e strict"

mk; rc=$(FAKE_KUBESEAL_WRONGNS=1 run --run ns-teste)
[ "$rc" != 0 ] && [ -z "$(ls "$C/topologies/ns-teste" 2>/dev/null)" ] && ok "saida com namespace errado: recusa, sem parcial" || bad "namespace errado na saida passou"

mk; rc=$( cd "$R" && PATH="$W/bin:$PATH" CATALOG_DIR="$C" bash scripts/secrets/seal-topology.sh --run ns-teste </dev/null >"$W/out" 2>&1; echo $? )
[ "$rc" != 0 ] && grep -q "sem TTY" "$W/out" && ! grep -q "^kubectl" "$W/log" && ok "sem TTY: recusa antes de qualquer leitura" || bad "sem TTY nao recusou"

mk; rc=$(run ns-teste); [ "$rc" = 0 ] && ! grep -q "^gpg\|^kubectl\|^kubeseal" "$W/log" && [ ! -e "$C/topologies" ] && ok "modo conferencia: exit 0, nao decifra, nao sela, nao grava" || bad "conferencia tocou em algo"
mk; rm -rf "$C/.git"; rc=$(run ns-teste); [ "$rc" != 0 ] && ok "catalogo ausente recusado" || bad "catalogo ausente aceito"
mk; rc=$(run --bogus ns-teste); [ "$rc" != 0 ] && ok "flag invalida recusada" || bad "flag invalida aceita"
mk; rc=$(run); [ "$rc" != 0 ] && ok "sem namespace recusado" || bad "sem namespace aceito"
echo "== $((n-fails))/$n ok"; [ "$fails" -eq 0 ]
