# ADR 0008 — bind mount real corrigido via recriação isolada dos nodes k3d (não do cluster)

## Status
Aceito, aplicado em produção (2026-09-17). Emenda o ADR 0007.

## Contexto
O ADR 0007 registrou a dívida (hostPaths do `agent-0` sem bind mount real de
`/media/rodrigo/dados`) e propôs como correção `k3d cluster delete` + `k3d cluster create
--volume`. Ao planejar essa correção, o custo real dessa receita apareceu: o cluster carrega
estado que não está versionado em lugar nenhum — namespaces `argocd`, `falco`, `monitoring`,
`velero` (instalados manualmente, 52 dias de idade) e a chave privada do `sealed-secrets`
(`kube-system`). Um `k3d cluster delete` teria invalidado os três `*.sealed.yaml` do git
(`postgres-secret`, `smartview-secret`, `regcred`) e exigido reinstalar 4 componentes fora do
fluxo GitOps.

## Decisão
Recriar **apenas os containers Docker dos nodes** (`agent-0`, depois também `server-0`),
preservando os 4 volumes Docker nomeados que já guardavam o estado do k3s de cada node
(`/var/lib/rancher/k3s`, `/var/lib/kubelet`, `/var/lib/cni`, `/var/log`) e acrescentando o bind
mount real (`-v /media/rodrigo/dados/k8s-volume:/media/rodrigo/dados/k8s-volume`, só no
`agent-0`, onde os PVs hostPath têm `nodeAffinity`). O `server-0` (control-plane, datastore
SQLite — cluster single-server, não usa etcd) nunca teve seu volume `/var/lib/rancher/k3s`
tocado, preservando os 4 namespaces extras e a chave do `sealed-secrets` sem qualquer ação de
migração.

Antes de qualquer `docker rm`, os dados do `k8s-volume` foram copiados do node parado
(`docker cp`) para `/media/rodrigo/dados/k8s-volume/` no host, e validados por um portão de
verificação (tamanho por diretório, ownership, `sha256sum` do RPO contra o hash pristino
conhecido) antes de prosseguir. Também foram tirados backups lógicos como rede de segurança
adicional: `pg_dump` do Postgres (693 MB) e um `tar` do datastore SQLite do `server-0` (11 MB),
ambos em `/media/rodrigo/dados/backups/` (fora do git).

## Dois problemas reais, não previstos no plano original

1. **Senha de registro do node rejeitada ("duplicate hostname").** O k3s guarda a senha de
   handshake de cada node não em arquivo (`/etc/rancher/node/password` é efêmero, vive na
   camada de container), mas como Secret do Kubernetes:
   `kube-system/<nome-do-node>.node-password.k3s` (tipo `k3s.cattle.io/node-password`). Todo
   `docker run` novo gera uma senha local aleatória; o registro só é aceito se esse Secret não
   existir ainda (registro novo) ou já bater com a senha atual (mesmo container). Recriar o
   container sem apagar o Secret antigo trava o node em `NotReady` permanentemente com esse erro.
   **Fix**: `kubectl delete secret -n kube-system <node>.node-password.k3s` antes de cada
   `docker run` de recriação — precisa ser repetido a cada recriação real do container (não a
   cada `docker restart`).
2. **`cannot enter cgroupv2 "/sys/fs/cgroup/kubepods" with domain controllers -- it is in an
   invalid state`.** Crashloop do kubelet ao tentar criar o cgroup `kubepods`, reproduzível de
   forma consistente (não uma race pontual) com `--cgroupns private` neste host (Docker
   `CgroupDriver=systemd`, `CgroupVersion=2`). Diagnóstico descartou lixo residual (nenhum
   diretório de cgroup órfão no host, nenhum estado suspeito nos volumes de `containerd`/
   `kubelet`) — é um conflito conhecido entre kubelet rodando dentro de um container privilegiado
   com cgroupns próprio e o driver systemd do Docker gerenciando o mesmo cgroup v2. Os nodes
   originais (criados em 2026-07-18) usavam `private` e funcionaram 60 dias — a causa provável é
   mudança de ambiente (driver do Docker) entre julho e setembro, não algo introduzido nesta
   sessão. **Fix**: recriar com `--cgroupns host` em vez de `--cgroupns private`. Aplicado nos
   dois nodes (`agent-0` e, na sequência, `server-0`) para não deixar o cluster com um node em
   cada modo.

## Consequências
- **`agent-0`**: bind mount real confirmado nos dois sentidos (escrita pelo host visível dentro
  do node e vice-versa). A dívida do ADR 0007 está fechada para este node — `docker restart`
  *e* `docker rm`/recriação agora preservam os dados de aplicação.
- **`server-0`**: ao recriar, o node voltou com `Unschedulable: true` (cordoned) sem causa raiz
  identificada — corrigido com `kubectl uncordon`. Vale observar se acontece de novo numa
  próxima recriação.
- **Receita de recriação de node não está versionada** — os comandos `docker run` completos
  (com bind mount + `--cgroupns host`) só existem nesta sessão e no `docker inspect` ao vivo dos
  containers. Item de backlog novo: versionar isso em `scripts/` (ver `docs/HANDOFF.md`).
- **`server-0` continua sem bind mount de `/media/rodrigo/dados`** — não precisa: nenhum pod ali
  tem PV hostPath dependente desse caminho. Só o `agent-0` precisava.
- Nenhum dado perdido: 53 tabelas `SYS_*` confirmadas no Postgres pós-migração, hash do RPO
  (`568f185e...`) confirmado dentro do node novo, os 4 namespaces fora do git (`argocd`,
  `falco`, `monitoring`, `velero`) preservados com a idade original.
