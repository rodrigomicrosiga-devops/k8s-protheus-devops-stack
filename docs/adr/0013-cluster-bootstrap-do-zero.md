# ADR 0013 — Receita de recriação do cluster `protheus-cluster` do zero

## Status
Aceito. Executado ao vivo em 2026-09-18 — ver "Validação" abaixo pro resultado real.

## Contexto
O cluster nasceu uma vez (2026-07-18, fora deste repo) e desde então só existia receita pra
recriar o *container* de um node já existente (`scripts/k3d-nodes/`, ADR 0008) — nunca pra
recriar o cluster inteiro (rede + volumes nomeados do k3s + os 7 componentes instalados via Helm
fora do Kustomize: Argo CD, Image Updater, sealed-secrets, Falco, kube-prometheus-stack, MinIO,
Velero). Item 3 do backlog (`docs/HANDOFF.md`).

Avaliado com o usuário: sem dado de produção em risco, decisão de executar o drill completo
(destruir e recriar de verdade), não só documentar a receita.

## Decisão

1. **Inventário completo antes de escrever qualquer script.** `helm list -A` + `helm get values
   <release> -n <ns>` recuperam os `values.yaml` reais de cada release direto do storage do
   Helm — não precisou reconstruir de memória. Capturados em
   `scripts/cluster-bootstrap/helm-values/`. Dois têm credencial em texto plano
   (`kube-prometheus-stack`: `grafana.adminPassword`; `minio`/`velero`: credenciais do MinIO) —
   vão como `.yaml.gpg` (mesmo cofre do ADR 0011), os outros 4
   (`argocd`/`argocd-image-updater`/`falco`/`sealed-secrets`) sem segredo, versionados direto.
2. **Chave do sealed-secrets é a única coisa realmente irrecuperável.** Backup via `kubectl get
   secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`, criptografado com o cofre
   GPG do ADR 0011 antes de ir pro git. Sem isso, os 4 `SealedSecret` já commitados
   (`postgres-secret`, `smartview-secret`, `regcred`, `appserver-upddistr-secret`) nunca mais
   decriptam num cluster novo — teriam que ser re-selados do zero, e não há plaintext guardado
   de 3 dos 4 (só o do Postgres, via ADR 0011).
3. **`/media/rodrigo/dados/k8s-volume/` (dados reais de aplicação) não precisa de backup pra
   este drill** — é hostPath físico do host, nunca um volume Docker gerenciado pelo k3d, então
   `k3d cluster delete` nunca toca nele. `pg_dump` feito mesmo assim, por segurança barata (não
   custa nada, e cobre o cenário de algo dar errado na recriação dos PVs).
4. **`k3d cluster create` não tem flag nativa pra `--cgroupns host`** — achado real, confirmado
   com `k3d cluster create --help` antes de tentar. A receita é necessariamente em duas fases:
   criar o cluster normal (nodes provavelmente instáveis, mesmo bug do ADR 0008) → recriar os
   dois containers de node com `--cgroupns host`, usando uma versão **generalizada** da lógica
   de `scripts/k3d-nodes/` (descobre volumes/env/labels dinamicamente via `docker inspect`, não
   assume IDs fixos como a receita original, que é específica do cluster de 2026-07-18).
5. **Porta 7890 nunca é mapeada** — `00-create-cluster.sh` já nasce sem ela (fix do item 4 já
   incorporado na receita, não precisa do `k3d cluster edit --port-delete` de depois).
6. **Ordem de instalação Helm importa**: sealed-secrets antes de Argo CD (a `Application` precisa
   decriptar `SealedSecret` no primeiro sync), Falco/monitoring/Velero por último (fora do
   caminho crítico, não bloqueiam nada da aplicação).

## Validação

<!-- Preencher depois de executar o drill ao vivo -->

## Consequências
- Fecha o item 3 do backlog — receita completa versionada, testada ao vivo (ver Validação).
- `scripts/cluster-bootstrap/01-fix-cgroupns.sh` generaliza a lógica do ADR 0008/`scripts/k3d-nodes/`
  — poderia substituir os scripts fixos por IDs se algum dia fizer sentido consolidar, mas
  decidido manter os dois (o antigo é mais simples de ler pra quem só quer recriar UM node já
  existente; o novo é necessário pro caso de zero nodes existirem ainda).
- Chave do sealed-secrets tem agora exatamente o mesmo tratamento do `postgres-secret.env` (ADR
  0011) — cofre GPG local, nunca plaintext no git, passphrase só no gerenciador de senhas do
  usuário.
