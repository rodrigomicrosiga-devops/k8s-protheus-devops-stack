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
   **Resolvido em 2026-09-21** (ADR 0016): `postgres-secret` nunca virou hook — o
   `smartview-db-init-job` que saiu de `PreSync`, passando a hook `Sync`/wave 1 (depois de
   `postgres-secret`/`postgres-config`, que ficam na wave 0 normal). A prova de que essa
   correção resolve o cenário genuinamente do zero (sem nenhum Secret pré-existente) ainda
   depende de repetir este drill — não foi reexecutada na sessão que corrigiu o manifesto.
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

   **Acréscimo de 2026-09-19 — não era só na recriação do node.** O mesmo defeito voltou depois
   de um simples **reboot do host**: o Docker reinicia os containers de node e a propagação do
   mount raiz volta a `private`, derrubando os dois `node-exporter`
   (`CreateContainerError: path "/" is mounted on "/" but it is not a shared or slave mount`).
   O fix no `01-fix-cgroupns.sh` só rodava quando um node era *recriado*. Fechado por
   `scripts/k3d-nodes/post-boot.sh` (idempotente, descobre os nodes pelo label `k3d.role`) +
   `scripts/k3d-nodes/k3d-node-rshared.service` (unit systemd, `After=docker.service`). Vale
   também pro `node-agent` do Velero (ADR 0015), que precisa enxergar `/var/lib/kubelet/pods`.

## Segunda execução do drill (2026-09-21) — valida a correção do ADR 0016

Drill completo repetido ao vivo, `k3d cluster delete` real seguido da receita 00→04 inteira,
desta vez com objetivo duplo: (1) provar que a correção do ADR 0016 (`smartview-db-init-job`
saiu de hook `PreSync` para `Sync`/wave 1) resolve de verdade o achado 1 acima, no cenário exato
que o motivou — `postgres-secret` genuinamente inexistente até o próprio sync criá-lo; (2)
decisão do usuário de **não restaurar backups opcionais** (pulou o `pg_dump` de segurança —
manteve a restauração das chaves do sealed-secrets, que não é opcional, é pré-requisito pros 4
`SealedSecret` já commitados continuarem decifráveis).

**Resultado do objetivo principal: sucesso total, sem intervenção manual nenhuma.** Diferente da
primeira execução (que precisou do bypass manual documentado no achado 1) e da sessão que
corrigiu o manifesto no mesmo dia (que teve 8 falhas por um bug de heredoc do `dash`, ver ADR
0016), desta vez o primeiro sync completou `Synced`/`Healthy` de ponta a ponta sozinho. Validado
contra a linha de base capturada antes de destruir: 167 tabelas (idêntico), hash do
`tttm120.rpo`/`custom.rpo` idênticos, os 4 `SealedSecret` decifrados corretamente.

**Cinco achados reais novos**, nenhum coberto pelas duas execuções anteriores do drill:

1. **Node recriado pelo `01-fix-cgroupns.sh` pode falhar em se registrar** — `agent-0`, depois de
   `docker stop`/`docker rm`/`docker run`, gerou uma senha de registro nova
   (`/etc/rancher/node/password`), mas o server ainda tinha o hash antigo salvo no `Secret`
   `<node>.node-password.k3s` — erro real no log do server: `unable to verify password for node
   ...: hash does not match`, node preso em `NotReady`/`Kubelet stopped posting node status`. O
   próprio `01-fix-cgroupns.sh` já imprime a correção no fim ("Apagar o Secret de senha de
   registro do node, se existir") mas não a executa sozinho — rodar
   `kubectl delete secret -n kube-system <node>.node-password.k3s` resolve, o agent se registra
   de novo em segundos. Não aconteceu no drill de 18/09 (não documentado lá) — pode depender de
   timing entre quando o container antigo escreve a senha e quando é destruído.
2. **`server-0` pode voltar `SchedulingDisabled`/`Unschedulable: true` sem causa raiz** — já
   documentado como achado recorrente sem explicação em `scripts/k3d-nodes/README.md` (não era
   exclusivo desta receita). Correção conhecida: `kubectl uncordon <node>`.
3. **Chart `minio/minio` pede `resources.requests.memory: 16Gi` por default** (dimensionado pra
   modo distribuído) — nenhum dos 2 nodes deste cluster local comporta, pod MinIO ficava
   `Pending`/`Insufficient memory`. Não apareceu antes porque o `minio.yaml.gpg` original (agora
   perdido, ver ADR 0011) provavelmente já tinha esse limite ajustado — ao reconstruir do zero, o
   default agressivo do chart voltou a valer. Fixado em `minio-persistence.yaml` (overlay sem
   segredo, 256Mi/512Mi).
4. **Chart `vmware-tanzu/velero` tenta criar `VolumeSnapshotLocation` com `provider`/`credential`
   nulos quando `snapshotsEnabled` fica no default (`true`)** — instalação falha com
   `spec.provider ... must be of type string: null`. Este projeto só usa File System Backup via
   `node-agent`, nunca snapshot nativo de volume — mesma hipótese do achado 3 (o `velero.yaml.gpg`
   original devia já ter isso desligado). Fixado em `velero-overrides.yaml`
   (`snapshotsEnabled: false`).
5. **Passphrase do cofre GPG (ADR 0011) genuinamente perdida** — bloqueou a fase de extras até
   ser rotacionada. Detalhe completo no acréscimo do ADR 0011.

Achado 1 do ADR 0013 original (a dependência circular do `smartview-db-init-job`) confirmado
**resolvido de fato**, não só em teoria — ver ADR 0016 pro detalhe da correção.

**Follow-up real ainda aberto**: `scripts/cluster-bootstrap/README.md` e o texto impresso por
`03-install-argocd.sh` ainda descrevem o bypass manual do achado 1 como se fosse necessário —
desatualizados, não corrigidos nesta sessão (ver `docs/HANDOFF.md`).

## Consequências
- Fecha o item 3 do backlog — receita completa versionada, testada ao vivo (ver Validação).
- `scripts/cluster-bootstrap/01-fix-cgroupns.sh` generaliza a lógica do ADR 0008/`scripts/k3d-nodes/`
  — poderia substituir os scripts fixos por IDs se algum dia fizer sentido consolidar, mas
  decidido manter os dois (o antigo é mais simples de ler pra quem só quer recriar UM node já
  existente; o novo é necessário pro caso de zero nodes existirem ainda).
- Chave do sealed-secrets tem agora exatamente o mesmo tratamento do `postgres-secret.env` (ADR
  0011) — cofre GPG local, nunca plaintext no git, passphrase só no gerenciador de senhas do
  usuário.
