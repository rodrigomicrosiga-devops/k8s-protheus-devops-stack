# ADR 0017 — Portas padrão do Protheus fixas em 127.0.0.1 via serverlb, Compose em 127.0.0.2

## Status
Aceito e implementado em 2026-10-04.

## Contexto
O acesso externo à stack do cluster dependia de duas alternativas, nenhuma estável:
- `kubectl port-forward`, que morre a cada reboot do host e a cada recriação do pod alvo
  (documentado em várias sessões — ver `docs/HANDOFF.md`, achados de 2026-09-18/20);
- o IP do node agent (`docker inspect k3d-protheus-cluster-agent-0`), que **muda** toda vez que o
  cluster é recriado ou os containers Docker são reordenados (era `172.18.0.3` em 22/09, passou a
  `172.18.0.2` em 04/10 sem nenhuma ação deliberada).

O `serverlb` do k3d (único container que publica porta no host) só expunha a API do Kubernetes
(`6443`). A porta `7890` tinha sido removida dele em 2026-09-18 porque colidia com o `dbaccess`
do Compose local, que também roda nesta máquina (mesma 7890, nos dois ambientes).

O usuário pediu explicitamente que o acesso fixo usasse as **portas padronizadas do Protheus**
(as mesmas do `appserver.ini`/`dbaccess.ini`: `1234` SmartClient, `8400` REST, `23` telnet, `7890`
dbaccess, `5555`/`8020` license, `7019`/`7017` smartview, `5432` Postgres) — não um NodePort
arbitrário tipo `31234`. E que, com o cluster virando o ambiente de referência do projeto (vitrine
Kubernetes), ele tivesse prioridade sobre o Compose local em caso de disputa de porta.

## Decisão
1. **`serverlb` publica as portas padrão do Protheus diretamente em `127.0.0.1`**, via
   `k3d cluster edit --port-add "127.0.0.1:<porta>:<nodeport>@loadbalancer"` (cluster vivo) e via
   `--port` no `k3d cluster create` de `00-create-cluster.sh` (próximos drills do zero). A porta
   externa é idêntica à do `.ini`; o NodePort (30000-32767, exigido pelo Kubernetes) fica invisível
   atrás do serverlb.
2. **`postgres-service` deixa de ser `ClusterIP` e passa a `NodePort`** (`base/postgres.yaml`,
   `nodePort: 30432`), para poder entrar nesse mesmo esquema em `5432`. Revê a decisão original do
   ADR 0005 (só Postgres no escopo de banco) só no tipo de Service — o escopo "só Postgres" não
   muda, é o mesmo e único banco exposto, só que agora também por fora do cluster sem
   port-forward.
3. **Compose local passa a publicar explicitamente em `127.0.0.2`** (`HOST_BIND_IP` no
   `docker-protheus-devops-stack`), em vez de `0.0.0.0`. Isso libera as portas padrão para o
   cluster em `127.0.0.1` sem as duas stacks colidirem — podem rodar ao mesmo tempo. `dbaccess`
   volta ao padrão `7890` no host (`DBACCESS_HOST_PORT`, que tinha ido para `7891` em 18/09
   especificamente por causa dessa mesma colisão — a causa raiz mudou, a porta volta).
4. **Cluster é prioridade**: em qualquer disputa futura de porta entre os dois ambientes, quem
   cede é o Compose (mesmo princípio já aplicado à 7890 em 18/09, "cluster é prioridade").

### Alternativas descartadas
- **NodePort cru exposto (`31234` etc.) sem tradução**: funciona, mas não atende ao pedido
  explícito de manter a padronização de portas do lado Protheus — forçaria o usuário a lembrar de
  um número diferente por ambiente.
- **Mesmas portas padrão, só uma stack no ar por vez**: simples, mas trava o objetivo de usar o
  cluster como ambiente principal sem desligar o Compose (que continua evoluindo em paralelo).
- **Compose com offset de porta (`11234`, `18400`...)**: inverte a prioridade — o cluster ficaria
  com a porta "estranha" em algum ambiente. Descartado porque o cluster é quem deve ficar com o
  padrão.
- **Ingress/Traefik** (já presente no cluster, ADR implícito do k3s): resolve HTTP, mas metade do
  tráfego aqui é TCP puro sem HTTP por cima (dbaccess, telnet, SmartClient multi-protocolo,
  Postgres) — Ingress não serve.

## Consequências
- Acesso fixo e permanente, sem `port-forward` e sem depender do IP do node: `http://127.0.0.1:1234/webapp`,
  DBMonitor em `127.0.0.1:7890`, `psql -h 127.0.0.1 -p 5432`, etc. — sobrevive a reboot do host e a
  recriação de pod (não a recriação do `serverlb` em si, que é rara e documentada no bootstrap).
- `postgres-service` perde o isolamento de rede do `ClusterIP` puro — passa a ser alcançável do
  host via `127.0.0.1:5432`, mas nada muda para quem já acessa de dentro do cluster
  (`postgres-service:5432` continua igual).
- Compose local só é alcançável de `localhost` (perde o acesso de outra máquina da rede, que
  `0.0.0.0` permitia) — aceito porque o Compose aqui é ambiente de desenvolvimento single-user,
  não um serviço de rede.
- Qualquer script/doc futuro que assuma `172.18.0.x` ou "precisa de port-forward" como único
  caminho está desatualizado — ver `docs/HANDOFF.md` e `README.md` para as referências corrigidas.
