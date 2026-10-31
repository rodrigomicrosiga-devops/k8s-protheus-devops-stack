#!/usr/bin/env bash
# Teste do export-live-secrets.sh com kubectl/gpg FALSOS num repo descartavel (nenhum segredo real e tocado).
# Uso: scripts/secrets/test-export-live-secrets.sh [caminho-do-script]  (o argumento serve ao teste de mutacao)
set -uo pipefail
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/export-live-secrets.sh}"
fails=0; n=0
ok(){ n=$((n+1)); echo "  ok   - $1"; }; bad(){ n=$((n+1)); fails=$((fails+1)); echo "  FALHA - $1"; }
mk() { # cria um repo falso novo em $W e devolve o caminho
  W="$(mktemp -d)"; R="$W/repo"; mkdir -p "$R/scripts/secrets" "$R/base" "$W/bin"
  cp "$SRC" "$R/scripts/secrets/"; git -C "$R" init -q
  printf 'base/smartview-secret.env\nbase/appserver-upddistr-secret.env\n' >"$R/.gitignore"
  echo "cofre-existente" >"$R/base/postgres-secret.env.gpg"
  cat >"$W/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
case "$*" in
  *base64decode*) case "$*" in *smartview-secret*) echo "SV_PASS=valor-falso-sv";; *) echo "UPD_PASSWORD=valor-falso-upd";; esac ;;
  *smartview-secret*) echo "SV_PASS" ;;
  *) echo "UPD_PASSWORD" ;;
esac
EOF
  cat >"$W/bin/gpg" <<'EOF'
#!/usr/bin/env bash
echo "gpg $*" >>"$FAKE_LOG"
if [ "$1" = "--quiet" ] && [ "$2" = "--decrypt" ]; then
  f="$3"
  case "$f" in *postgres-secret*) [ "${FAKE_GPG_FAIL_PROOF:-}" = 1 ] && exit 2 ;; esac
  if [ "${FAKE_GPG_CORRUPT:-}" = 1 ] && [ "$f" != "base/postgres-secret.env.gpg" ]; then echo "conteudo-diferente"; exit 0; fi
  cat "$f"; exit 0
fi
if [ "$1" = "--symmetric" ]; then out=""; in=""; while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift;; --symmetric|--cipher-algo) [ "$1" = "--cipher-algo" ] && shift;; *) in="$1";; esac; shift; done; cp "$in" "$out"; exit 0; fi
exit 9
EOF
  chmod +x "$W/bin/"*; : >"$W/log"; export FAKE_LOG="$W/log"
}
runpty() { ( cd "$R" && PATH="$W/bin:$PATH" EXPORT_NAMESPACE=ns script -qec "bash scripts/secrets/export-live-secrets.sh $*" /dev/null ) >"$W/out" 2>&1; echo $?; }
leftover() { ls -d /dev/shm/export-secrets.* 2>/dev/null | wc -l; }

mk; rc=$(runpty --run)
[ "$rc" = 0 ] && ok "sucesso: exit 0" || { bad "sucesso: exit $rc"; cat "$W/out"; }
[ -f "$R/base/smartview-secret.env.gpg" ] && [ -f "$R/base/appserver-upddistr-secret.env.gpg" ] && ok "sucesso: os 2 .gpg foram criados" || bad "sucesso: .gpg ausentes"
ls "$R/base" | grep -qE '\.env$' && bad "sobrou texto puro em base/" || ok "nenhum texto puro em base/"
grep -q "valor-falso" "$W/out" && bad "O VALOR APARECEU NA SAIDA" || ok "o valor nao aparece na saida do script"
[ "$(leftover)" = 0 ] && ok "o diretorio temporario (tmpfs) foi apagado" || bad "sobrou diretorio temporario em /dev/shm"
grep -n "gpg --quiet --decrypt base/postgres-secret.env.gpg" "$W/log" >/dev/null && ok "a passphrase foi provada no arquivo do cofre" || bad "sem prova de passphrase"
first_dec=$(grep -n "gpg --quiet --decrypt" "$W/log" | head -1 | cut -d: -f1); first_read=$(grep -n "base64decode" "$W/log" | head -1 | cut -d: -f1)
[ "$first_dec" -lt "$first_read" ] && ok "a prova da passphrase vem ANTES da leitura dos valores" || bad "ordem errada"

mk; rc=$(FAKE_GPG_FAIL_PROOF=1 runpty --run)
[ "$rc" != 0 ] && ok "passphrase errada: exit != 0" || bad "passphrase errada passou"
grep -q base64decode "$W/log" && bad "passphrase errada: os valores FORAM lidos" || ok "passphrase errada: nenhum valor foi lido do cluster"
ls "$R/base" | grep -qE 'smartview|upddistr' && bad "passphrase errada: criou arquivo" || ok "passphrase errada: nada gravado"

mk; rc=$(FAKE_GPG_CORRUPT=1 runpty --run)
[ "$rc" != 0 ] && ok "arquivo novo nao bate: exit != 0" || bad "arquivo corrompido passou"
[ -e "$R/base/smartview-secret.env.gpg" ] && bad "arquivo que nao bate NAO foi removido" || ok "arquivo que nao bate foi removido"

mk; echo "NAO-MEXER" >"$R/base/smartview-secret.env.gpg"; rc=$(runpty --run)
[ "$rc" != 0 ] && [ "$(cat "$R/base/smartview-secret.env.gpg")" = "NAO-MEXER" ] && ok "recusa sobrescrever .gpg existente (conteudo intacto)" || bad "sobrescreveu o cofre"

mk; echo x >"$R/base/appserver-upddistr-secret.env"; rc=$(runpty --run)
[ "$rc" != 0 ] && grep -q base64decode "$W/log" && bad "texto puro pre-existente: leu valores" || { [ "$rc" != 0 ] && ok "recusa quando ja ha texto puro no disco"; }

mk; : >"$R/.gitignore"; rc=$(runpty --run)
[ "$rc" != 0 ] && ok "recusa quando o texto puro nao esta no .gitignore" || bad ".gitignore ignorado"

mk; rc=$( cd "$R" && PATH="$W/bin:$PATH" EXPORT_NAMESPACE=ns bash scripts/secrets/export-live-secrets.sh --run </dev/null >"$W/out" 2>&1; echo $? )
[ "$rc" != 0 ] && grep -q "sem TTY" "$W/out" && ok "sem TTY: recusa antes de qualquer leitura" || bad "sem TTY nao recusou"
grep -q base64decode "$W/log" && bad "sem TTY: leu valores" || ok "sem TTY: nenhum valor lido"

mk; rc=$(runpty); [ "$rc" = 0 ] && ! grep -q base64decode "$W/log" && ok "modo conferencia: exit 0 e nunca le valor" || bad "modo conferencia leu valor ou falhou"
mk; rc=$(runpty --bogus); [ "$rc" != 0 ] && ok "argumento invalido recusado" || bad "argumento invalido aceito"
echo "== $((n-fails))/$n ok"; [ "$fails" -eq 0 ]
