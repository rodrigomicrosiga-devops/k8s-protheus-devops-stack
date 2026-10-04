# ADR 0018 — Docker só sobe depois do disco de dados montar

## Status
Aceito em 2026-10-04. Arquivos versionados; instalação no host é manual (`sudo`).

## Contexto
Uma queda de energia em 2026-10-04 reiniciou o host. O `fstab` monta `/media/rodrigo/dados` com
`nofail`, o que diz ao systemd para **não** bloquear nem ordenar nada em relação a esse mount.
Resultado: o `docker.service` subiu, os containers de node do k3d voltaram por restart policy
(12:25:59) e o bind mount `-v /media/rodrigo/dados/k8s-volume:...@agent:0` foi resolvido contra a
pasta vazia do disco raiz, porque `/dev/sda1` ainda não estava montado. O disco montou depois, mas
um bind mount já resolvido não "enxerga" o mount novo por cima.

Sintomas observados: o node via só `minio-backup`, `printer-shared`, `webapp-shared` e afins
(diretórios que os próprios pods criaram na pasta sombra); `postgres-dumps-pv` falhou com `path ...
does not exist`; Postgres não subia, `dbaccess` ficou em loop esperando o banco, vários pods em
`Unknown`; e `k3d-node-rshared.service` falhou com `203/EXEC` porque o `ExecStart` mora no próprio
disco de dados (`scripts/k3d-nodes/post-boot.sh`), ainda inexistente no momento. Dado real nunca
foi tocado — só ficou invisível ao cluster.

O perigo maior não foi a indisponibilidade: foi o que poderia ter acontecido se o Postgres tivesse
subido contra um `postgres/` vazio na pasta sombra (um `initdb` novo, silencioso, num lugar errado).
Só não aconteceu porque o `postgres-dumps-pv` (tipo `local`, exige diretório existente) travou o
pod antes.

## Decisão
1. Drop-in `docker.service.d/wait-data-mount.conf` com `RequiresMountsFor=/media/rodrigo/dados`
   (versionado em `scripts/k3d-nodes/docker-wait-data-mount.conf`): o Docker só inicia depois
   do mount, e **não inicia** se ele falhar.
2. `k3d-node-rshared.service` ganha o mesmo `RequiresMountsFor=`, pelo mesmo motivo (o script mora
   no disco de dados).
3. `nofail` no `fstab` **permanece**: ele protege o boot da máquina (sem ele, disco ausente
   derrubaria o boot em emergency mode). Quem precisa do disco declara a dependência — é o
   papel do `RequiresMountsFor`, não do `fstab`.

## Alternativas descartadas
- **Remover `nofail`**: faz o disco ausente travar o boot inteiro do host, por causa de um
  ambiente de estudo. Desproporcional.
- **Script que reinicia os nodes se detectar mount tardio** (no `post-boot.sh`): cura o sintoma
  depois do dano — pods já rodaram contra a pasta errada. Ordenar o boot é a causa raiz.
- **Só reiniciar os nodes à mão** (o que foi feito hoje): funciona, mas depende de alguém notar.

## Consequências
- Disco de dados ausente ou defeituoso → Docker parado (visível e barulhento), em vez de cluster
  "saudável" apontando para diretórios vazios (silencioso e perigoso). Afeta também containers
  Docker sem relação com o projeto — aceito, máquina de dev dedicada a este trabalho.
- Reboots em que o disco montava rápido não mudam de comportamento.
- Sem `sudo` neste fluxo não dá para validar por reboot real daqui; validação documentada abaixo.

## Validação (depois de instalar)
- `systemctl show docker.service -p RequiresMountsFor -p After | grep -c dados` → `>0`.
- `systemd-analyze critical-chain docker.service` lista `media-rodrigo-dados.mount` antes do Docker.
- Reboot real: `docker exec k3d-protheus-cluster-agent-0 ls /media/rodrigo/dados/k8s-volume` deve
  listar `postgres`, `protheus-apo`..., e os 13 pods `1/1` sem intervenção manual.
- Sinal de alerta no futuro: node listando só `*-shared` e sem `postgres`/`protheus-apo` = mount
  tardio de novo; corrigir com `docker restart` nos dois nodes e `scripts/k3d-nodes/post-boot.sh`.
