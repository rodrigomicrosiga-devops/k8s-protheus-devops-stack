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

**Drill completo executado ao vivo em 2026-09-18 — sucesso total.** `k3d cluster delete` real,
seguido da receita completa (00→04), sem atalhos. Validação final idêntica à linha de base
capturada antes de destruir: 171 tabelas no Postgres (recovery automático de WAL — o
`k3d cluster delete` não faz shutdown limpo do Postgres, o container simplesmente some; o
`pg_dump` de segurança feito antes acabou não sendo necessário, mas foi o certo a fazer), hash
do `tttm120.rpo`/`custom.rpo` idênticos, os 4 `SealedSecret` (`postgres-secret`,
`smartview-secret`, `regcred`, `appserver-upddistr-secret`) decriptados corretamente com as
chaves restauradas, os 2 nodes `Ready` com `cgroupns=host`, `serverlb` sem a porta 7890 desde o
nascimento, e todos os 7 componentes Helm + os 12 pods de `protheus-devops` + Falco + monitoring
+ Velero/MinIO no ar, `Synced`/`Healthy`.

**Dois achados reais, não previstos, encontrados só ao executar de verdade** (motivo de existir
uma seção de validação, não só a decisão em teoria):

1. **Dependência circular nova, diferente da do ADR 0012**: o hook `PreSync` `smartview-db-init`
   depende de `postgres-secret` (`envFrom.secretRef`) — mas `postgres-secret` é um `SealedSecret`
   comum de `Sync`, não um hook, então **nunca existe a tempo** num bootstrap genuinamente do
   zero (no cluster antigo isso nunca apareceu porque `postgres-secret` já existia desde
   2026-07-26). Mesmo mecanismo de trava do ADR 0012 (hook `PreSync` esperando algo que só existe
   depois dele na mesma operação), causa raiz diferente (desta vez é o `Secret`, não o Postgres
   em si — mas o Postgres também trava atrás, pela mesma razão de sempre). Desbloqueado com o
   mesmo padrão já validado: aplicar `postgres-secret.sealed.yaml` e depois `postgres.yaml`
   diretamente (`kubectl apply -f`, bypass pontual do Argo CD), extraindo o `ConfigMap`
   `postgres-config-<hash>` via `kubectl kustomize base/` primeiro (mesmo problema de hash do
   `configMapGenerator` do ADR 0012). **Ação de follow-up real**: mover `postgres-secret` (e
   possivelmente `postgres-config`) pra dentro do próprio hook `PreSync` do `smartview-db-init`
   como dependência declarada, ou remover a dependência do hook em `postgres-secret` — não
   corrigido nesta sessão, seria mudança de manifesto fora do escopo do drill de validação.
2. **Nodes recriados nascem com o mount raiz em propagação `private`, não `shared`** —
   quebra o `prometheus-node-exporter` (monta `/` do node, exige `shared`/`slave`,
   erro: `"path / is mounted on / but it is not a shared or slave mount"`). Não é algo visível
   via `docker inspect` (não é um volume/env/label capturável pelo `01-fix-cgroupns.sh`) — é
   como o `k3d` cria os containers internamente via SDK do Docker, não replicável 1:1 por
   `docker run` puro. Corrigido ao vivo, sem precisar recriar o container:
   `docker exec <node> mount --make-rshared /` nos dois nodes, depois `kubectl delete pod` nos
   `node-exporter` pra remontar com a propagação corrigida. **Já incorporado no
   `01-fix-cgroupns.sh`** (rodado automaticamente no fim do script, mesmo dia) — o próximo drill
   não precisa do passo manual.

## Consequências
- Fecha o item 3 do backlog — receita completa versionada, testada ao vivo (ver Validação).
- `scripts/cluster-bootstrap/01-fix-cgroupns.sh` generaliza a lógica do ADR 0008/`scripts/k3d-nodes/`
  — poderia substituir os scripts fixos por IDs se algum dia fizer sentido consolidar, mas
  decidido manter os dois (o antigo é mais simples de ler pra quem só quer recriar UM node já
  existente; o novo é necessário pro caso de zero nodes existirem ainda).
- Chave do sealed-secrets tem agora exatamente o mesmo tratamento do `postgres-secret.env` (ADR
  0011) — cofre GPG local, nunca plaintext no git, passphrase só no gerenciador de senhas do
  usuário.
