# Receita de recriação dos nodes do cluster k3d `protheus-cluster`

Contexto completo em [`docs/adr/0008-bind-mount-real-recriacao-isolada-dos-nodes.md`](../../docs/adr/0008-bind-mount-real-recriacao-isolada-dos-nodes.md).
Resolve o backlog item 0 do [`docs/HANDOFF.md`](../../docs/HANDOFF.md).

## O que isto é (e o que não é)

O cluster `protheus-cluster` foi criado uma vez com `k3d cluster create` (fora deste repo,
2026-07-18) e desde então os dois nodes (`agent-0`, `server-0`) existem só como containers
Docker soltos. Este diretório versiona os comandos `docker run` completos para **recriar o
container de um node existente**, preservando o estado real dele (volumes Docker nomeados que
já existem desde a criação do cluster).

**Não é** um `k3d cluster create` do zero. Não recria o cluster, não recria a rede Docker, não
recria os volumes nomeados (eles precisam já existir — são referenciados por ID fixo em
`lib.sh`). Se o cluster inteiro for perdido (rede + todos os volumes), esta receita não serve —
seria necessário reconstruir do zero, o que também reconstruiria a chave do `sealed-secrets` e
perderia os namespaces `argocd`/`falco`/`monitoring`/`velero` (instalados fora do git — ver ADR
0008). Isso continua sendo um risco não coberto; ver item 5 do backlog.

## Quando usar

Só quando o container do node precisa ser efetivamente **removido e recriado** — por exemplo:
- o container foi removido por engano (`docker rm`);
- uma configuração de baixo nível do container mudou (como `--cgroupns host`, que foi o motivo
  de recriar os dois nodes em 2026-09-17 — ver ADR 0008) e precisa ser aplicada de novo.

**Não use para religar o cluster depois de um reboot ou parada normal** — isso é só
`docker start <node>` ou `docker restart <node>` (ambos preservam o container e são seguros,
sem nenhum dos problemas abaixo).

## Como usar

```sh
# recriar o agent-0 (onde vivem os pods com PV hostPath -- postgres, appserver, etc)
./scripts/k3d-nodes/recreate-agent-0.sh

# recriar o server-0 (control plane, datastore SQLite -- faça backup antes, ver
# o comentário no topo do script)
./scripts/k3d-nodes/recreate-server-0.sh
```

Cada script:
1. resolve o token do cluster automaticamente (lê do node irmão, se ele ainda existir; senão
   requer `$K3D_CLUSTER_TOKEN` no ambiente — o token não fica hardcoded no git);
2. pede confirmação explícita (`digite RECRIAR`) antes de parar/remover o container;
3. recria com a configuração validada em produção em 2026-09-17: `--cgroupns host` (não
   `private` — ver "Bug de cgroup" abaixo), volumes nomeados corretos, e no caso do `agent-0`,
   o bind mount real de `/media/rodrigo/dados/k8s-volume`;
4. imprime os passos manuais que faltam (não automatizados de propósito — ver abaixo).

## Duas pegadinhas reais, ambas já resolvidas nos scripts

- **Secret de senha do node.** Cada `docker run` novo gera uma senha aleatória local
  (`/etc/rancher/node/password`, efêmero). O server só aceita o registro se o Secret
  `kube-system/<node>.node-password.k3s` (da vez anterior) não existir mais. Os scripts
  lembram disso no output final, mas não apagam o Secret sozinhos (é uma ação de escrita em
  Secret do cluster — feita deliberadamente fora do script, ver a nota sobre classificador de
  segurança em `docs/HANDOFF.md`).
- **Bug de cgroup v2.** `--cgroupns private` (o que os nodes originais usavam desde julho)
  trava o kubelet num crashloop neste host (`cannot enter cgroupv2 "kubepods" with domain
  controllers -- it is in an invalid state`), por incompatibilidade com o driver `systemd` de
  cgroup do Docker. Os dois scripts já usam `--cgroupns host`. Se algum dia isso for
  reinvestigado e a causa raiz mudar, atualizar os dois scripts junto.

## Pendências conhecidas (não cobertas aqui)

- O `serverlb` (loadbalancer do k3d) não é recriado por estes scripts — só é reconectado à rede
  e reiniciado (passo 2 do output). Ele publica a porta `7890` no host, que colide com o
  `dbaccess` do Compose local se os dois subirem juntos (aconteceu no boot de 2026-09-17). Uma
  correção futura seria recriar o `serverlb` sem esse mapeamento — não feito ainda porque exige
  recriar o LB de fato (não só reiniciar), e não foi validado em produção nesta sessão.
- `server-0` voltou uma vez com `Unschedulable: true` (cordoned) sem causa raiz identificada
  depois de recriado. Os scripts não corrigem isso sozinhos — `print_next_steps` lembra o
  comando (`kubectl uncordon`), mas fique atento na validação.
