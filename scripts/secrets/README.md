# Cofre local — segredos em texto plano criptografados em repouso

Contexto completo em [`docs/adr/0011-cofre-local-gpg-secrets-plaintext.md`](../../docs/adr/0011-cofre-local-gpg-secrets-plaintext.md).
Resolve o item 2 do backlog ([`docs/HANDOFF.md`](../../docs/HANDOFF.md)).

## O problema que isto resolve

`base/postgres-secret.env` é o insumo em texto plano usado pra gerar (via `kubeseal`)
`base/postgres-secret.sealed.yaml`, o `SealedSecret` de verdade aplicado no cluster. Esse `.env`
nunca vai pro git (`.gitignore`), mas até 2026-09-18 só existia como arquivo puro no disco — sem
backup nenhum fora dele. Perder o disco (ou o arquivo) significava perder a única cópia
recuperável da senha, sem forma de re-selar o segredo (ex. pra rotacionar, ou pra um cluster
novo) sem descobrir a senha de novo por outro canal.

## A solução: GPG simétrico (AES256)

`base/postgres-secret.env.gpg` é o arquivo real versionado no git — uma cópia cifrada do `.env`,
decriptável só com a passphrase (guardada fora do git, no gerenciador de senhas do usuário, nunca
neste repositório). O `.env` em texto puro volta a existir no disco só efemeramente, quando
alguém precisa mexer nele.

**Por que GPG simétrico, não `age` nem par de chaves assimétrico**: `gpg` já estava instalado
neste host (`age` não), e o caso de uso é single-user/single-máquina — não há necessidade de
distribuir uma chave pública pra múltiplos decriptadores. Uma passphrase única, forte (gerada com
`openssl rand -base64 32`), cobre o caso real.

## Como usar

```sh
# Decriptar (pede a passphrase, escreve base/postgres-secret.env em texto puro):
./scripts/secrets/decrypt.sh base/postgres-secret.env.gpg

# ... editar/consultar base/postgres-secret.env, re-selar com kubeseal se for o caso ...

# Re-criptografar depois de qualquer mudança:
./scripts/secrets/encrypt.sh base/postgres-secret.env

# Apagar o plaintext assim que terminar -- não deixar sobrando no disco:
rm base/postgres-secret.env
```

Os dois scripts pedem a passphrase interativamente (pinentry do GPG) — nunca aceitam a
passphrase como argumento ou variável de ambiente (ficaria no histórico do shell), e por isso não
são algo que uma sessão automatizada consegue rodar sozinha sem um humano digitando a senha.

## Reusável pra outros segredos

`encrypt.sh`/`decrypt.sh` são genéricos (recebem o caminho do arquivo como argumento) — não são
específicos do `postgres-secret.env`. Se `smartview-secret.env`/`appserver-upddistr-secret.env`
(ou qualquer outro insumo de `kubeseal`) precisarem do mesmo tratamento no futuro, é só rodar
`encrypt.sh` neles também, sem duplicar script.
