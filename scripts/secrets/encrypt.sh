#!/usr/bin/env bash
# Criptografa um arquivo de segredo em texto plano com GPG simétrico (AES256).
#
# Uso: scripts/secrets/encrypt.sh <arquivo-plaintext>
#   ex.: scripts/secrets/encrypt.sh base/postgres-secret.env
#
# Gera <arquivo-plaintext>.gpg -- esse SIM pode ir pro git (conteúdo cifrado).
# O arquivo original em texto puro NUNCA deve ser commitado -- confira que
# está no .gitignore antes de continuar.
#
# Pede a passphrase interativamente (pinentry do GPG) -- nunca em arquivo,
# nunca em variável de ambiente, nunca passada como argumento (ficaria no
# histórico do shell).
set -euo pipefail

FILE="${1:?Uso: $0 <arquivo-plaintext>}"

if [ ! -f "$FILE" ]; then
  echo "❌ Arquivo não encontrado: $FILE" >&2
  exit 1
fi

if ! git -C "$(dirname "$FILE")" check-ignore -q "$FILE" 2>/dev/null; then
  echo "⚠️  AVISO: $FILE não está coberto pelo .gitignore -- confirme isso antes de prosseguir." >&2
  read -r -p "Continuar mesmo assim? [s/N] " RESP
  [ "$RESP" = "s" ] || [ "$RESP" = "S" ] || exit 1
fi

gpg --symmetric --cipher-algo AES256 --output "${FILE}.gpg" "$FILE"

echo "✅ ${FILE}.gpg gerado."
echo "👉 Pode 'git add ${FILE}.gpg' e commitar -- NUNCA o $FILE em texto puro."
