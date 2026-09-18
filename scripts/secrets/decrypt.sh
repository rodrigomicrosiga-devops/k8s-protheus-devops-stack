#!/usr/bin/env bash
# Decripta um arquivo .gpg gerado por encrypt.sh.
#
# Uso: scripts/secrets/decrypt.sh <arquivo.gpg>
#   ex.: scripts/secrets/decrypt.sh base/postgres-secret.env.gpg
#
# Escreve o resultado em <arquivo> (sem o .gpg) -- CUIDADO: fica em texto
# puro no disco até você apagar de novo. Sempre rode encrypt.sh de novo
# depois de qualquer edição e apague o plaintext assim que terminar de usar.
#
# Pede a passphrase interativamente (pinentry do GPG).
set -euo pipefail

FILE="${1:?Uso: $0 <arquivo.gpg>}"

if [ ! -f "$FILE" ]; then
  echo "❌ Arquivo não encontrado: $FILE" >&2
  exit 1
fi

case "$FILE" in
  *.gpg) OUT="${FILE%.gpg}" ;;
  *) echo "❌ Esperado um arquivo .gpg" >&2; exit 1 ;;
esac

gpg --decrypt --output "$OUT" "$FILE"

echo "⚠️  $OUT está em texto puro no disco agora."
echo "👉 Depois de usar: se editou, rode encrypt.sh de novo; sempre 'rm $OUT' ao terminar."
