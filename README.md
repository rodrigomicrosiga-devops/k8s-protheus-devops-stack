# Protheus Devops Stack - Local Kubernetes Cluster

Ambiente de desenvolvimento Protheus em alta performance rodando localmente em cluster Kubernetes de nó único (**K3d/K3s**), focado em isolamento de pilha, automação de infraestrutura e portabilidade entre desenvolvedores.

## 🏗️ Arquitetura do Ambiente

A stack adota isolamento completo de rede via Namespace e injeção dinâmica de variáveis de ambiente locais ignoradas pelo Git (`.env`), garantindo a independência das credenciais de cada desenvolvedor.

```mermaid
graph TD
    subgraph M_FISICA["Máquina Física (Linux Mint)"]
        DBeaver[DBeaver / pgAdmin] -- "Túnel Local: 5432" --> K3D_LB
        DBMonitor[TOTVS DBMonitor] -- "Túnel Local: 7891" --> K3D_LB
    end

    subgraph CLUSTER["Cluster K3d (Namespace: protheus-devops)"]
        K3D_LB[K3d LoadBalancer / Port-Forward]
        
        subgraph DBA_LAYER["Camada de Conectividade"]
            DBA_SVC["Service: dbaccess-service <br> NodePort: 30890"] --> DBA_POD["Pod: DbAccess <br> v24.1.1.3"]
        end

        subgraph LIC_LAYER["Camada de Licenciamento"]
            LIC_SVC["Service: license-service <br> NodePort: 30555 / 30820"] --> LIC_POD["Pod: License Server <br> v3.7.1 (privileged)"]
        end

        subgraph PG_LAYER["Camada de Persistência"]
            PG_SVC["Service: postgres-service <br> Porta: 5432"] --> PG_POD["Pod: PostgreSQL"]
            PG_POD --> PVC[PersistentVolumeClaim] --> PV["PersistentVolume <br> local-path: /media/rodrigo/dados/"]
        end

        subgraph DELIVERY_LAYER["Camada de Entrega (Sidecars sem Service)"]
            WEBAPP_POD["Pod: WebApp <br> v10.2.1"] --> WEBAPP_PVC["PVC: webapp-shared-pvc"]
            PRINTER_POD["Pod: Printer <br> v3.0.5"] --> PRINTER_PVC["PVC: printer-shared-pvc"]
        end

        subgraph SV_LAYER["Camada de Relatórios"]
            SV_SVC["Service: smartview-service <br> NodePort: 30719 / 30717"] --> SV_POD["Pod: SmartView <br> v3.9.0 (privileged, systemd PID 1)"]
            SV_JOB["Job (hook PreSync): smartview-db-init"] -.provisiona.-> PG_SVC
        end

        %% Injeção de Variáveis
        CM["ConfigMap: postgres-config <br> postgres.env"] -. envFrom .-> DBA_POD
        CM -. envFrom .-> PG_POD
        SEC["Secret: postgres-secret <br> postgres-secret.env"] -. envFrom .-> DBA_POD
        SEC -. envFrom .-> PG_POD
        
        DBA_POD -- Conecta via TCP --> PG_SVC
    end
```

### 🛠️ Pré-requisitos & Armazenamento

O `cluster K3d` utiliza o `local-path provisioner` do K3s apontando para o volume físico montado em:

Caminho: `/media/rodrigo/dados/`

Os manifestos bases estão estruturados via Kustomize dentro do diretório `base/`.

### 🚀 Como Executar e Validar

1. Inicializar os recursos

```bash
kubectl apply -k base/
```
2. Validar o Banco de Dados (`PostgreSQL`)

Crie um redirecionamento de porta para acessar o banco externamente via `DBeaver` ou similar:

```bash
kubectl port-forward deployment/postgres 5432:5432 -n protheus-devops
```

`Host`: localhost | `Porta`: 5432 | `Banco`: Conforme configurado no `postgres.env`

3. Validar a Conectividade (`DbAccess`)

Caso a porta nativa 7890 esteja ocupada por instâncias locais da máquina host, direcione para uma porta alternativa para abrir no `DBMonitor`:

```bash
kubectl port-forward deployment/dbaccess 7891:7890 -n protheus-devops
```

4. Validar o License Server

```bash
kubectl port-forward deployment/license 5555:5555 -n protheus-devops
```

**Nota de segurança**: o Pod do `license` roda com `securityContext.privileged: true` e monta `/dev/mem` do host (`hostPath`). Isso replica o `cap_add: SYS_RAWIO` + `devices: /dev/mem:/dev/mem` que o `docker-compose` original já usava — o binário da TOTVS (via `dmidecode`, empacotado na imagem) lê `/dev/mem` para gerar o fingerprint de hardware ao qual a licença é vinculada. Sem um device plugin dedicado, o Kubernetes só libera esse acesso via `privileged: true`. Como o node do K3d roda no mesmo host físico da máquina de desenvolvimento, o fingerprint resultante é o mesmo de quando a licença rodava via `docker-compose`.

5. `WebApp` e `Printer` (sidecars de entrega)

`webapp` e `printer` são binários com versionamento independente do AppServer — cada um roda numa imagem exclusiva justamente para poder ser atualizado sozinho (nova versão do WebApp ou do Printer) sem precisar rebuildar ou reiniciar o AppServer. Eles não expõem porta nenhuma: o único trabalho de cada um é extrair seu binário para um `PersistentVolumeClaim` dedicado (`webapp-shared-pvc`, `printer-shared-pvc`) e ficar em standby. Não há verificação via `port-forward` aqui — a validação é conferir que os arquivos foram extraídos:

```bash
kubectl exec deployment/webapp -n protheus-devops -- ls /mnt/webapp_shared
kubectl exec deployment/printer -n protheus-devops -- ls /mnt/printer_shared
```

Esses dois PVCs ainda não têm consumidor: `base/appserver.yaml` (ainda incompleto/WIP, fora do escopo de automação atual) precisará montá-los como somente-leitura quando for finalizado, do mesmo jeito que o `docker-compose` original montava `webapp_shared_module` e `protheus_printer_volume` em `/tmp/webapp_shared:ro` e `/tmp/printer_shared:ro` dentro do `appserver_core`.

6. Validar o TOTVS SmartView

O bootstrap do banco/usuário do SmartView (`smartview_dev`/`totvs`) roda automaticamente como um **hook `PreSync` do Argo CD** (`smartview-db-init-job.yaml`) — dispara antes da sincronização do restante da stack e se autolimpa (`hook-delete-policy: HookSucceeded`) depois de concluir, não fica pendurado como um Job "morto" no namespace.

```bash
kubectl port-forward deployment/smartview 7019:7019 -n protheus-devops
```

A interface fica disponível em `http://localhost:7019`. A partir daí, a configuração da conexão com o dicionário de dados do Protheus (e qualquer outro ajuste) é feita manualmente pelo usuário, exatamente como já era feito ao subir via `run.sh` localmente — não é algo automatizado por este repositório. Essa configuração fica persistida inteiramente no banco `smartview_dev`, então um restart do Pod não perde nada.

**Nota de segurança**: o Pod do `smartview` roda com `securityContext.privileged: true` e monta `/sys/fs/cgroup` do host (`hostPath`, `rw`) — escopo de acesso maior que o do `license` (que monta só o char device `/dev/mem`). Isso é necessário porque a imagem roda **systemd completo como PID 1** internamente (gerenciando o serviço `smart-view-agent`), e o systemd precisa administrar cgroups reais do host pra isso funcionar — o mesmo `--privileged` + `-v /sys/fs/cgroup:/sys/fs/cgroup:rw` que o próprio README da imagem Docker já documenta como pré-requisito. Não há endpoint HTTP de health documentado; a validação (liveness/readiness) é feita via probe `exec` rodando `systemctl is-active smart-view-agent.service` dentro do container, o mesmo comando usado manualmente pra validar a imagem antes desta automação.

### 🔄 GitOps: Argo CD + Image Updater

Este repositório é o alvo de sincronização de um `Application` do Argo CD (sync automático + `selfHeal`), que por sua vez é observado por um `ImageUpdater` (Argo CD Image Updater) rastreando as imagens `dbaccess-dev`, `postgres-dev`, `license-dev`, `webapp-dev`, `printer-dev` e `smartview-dev` por **digest** — a cada novo build publicado no Docker Hub sob a mesma tag fixa, o Image Updater detecta o novo digest, faz o patch do `Application` (write-back method `argocd`) e o Argo CD sincroniza automaticamente.

Os manifestos desses dois recursos (`Application` e `ImageUpdater`) ficam versionados em [`argocd/`](argocd/), pois eles vivem no namespace `argocd` do cluster, fora do que o Kustomize em `base/` gerencia — sem isso, a integração entre o Argo CD e este repositório existiria apenas como estado vivo do cluster, sem nenhum registro em git.

**Bootstrap / Disaster Recovery** — se o cluster for recriado do zero, os únicos dois comandos necessários para reestabelecer toda a integração GitOps são:

```bash
kubectl apply -f argocd/application.yaml
kubectl apply -f argocd/image-updater.yaml
```

(pré-requisito: Argo CD e Argo CD Image Updater já instalados no cluster via Helm, namespace `argocd`). Depois disso, o `Application` puxa `base/` deste repositório e o `ImageUpdater` volta a rastrear os digests automaticamente — nenhum passo manual adicional.

### 🏷️ Estratégia de Tags do Fleet

Todos os repositórios `docker-*` que alimentam este cluster publicam suas imagens sob **tags fixas/estáticas** (ex.: `dbaccess-dev:24.1.1.3`, `postgres-dev:16`) — a tag só muda quando a TOTVS libera uma nova versão do binário, não a cada commit/build. Essa é uma decisão deliberada, não uma limitação:

* O Image Updater rastreia essas imagens por **digest** (`updateStrategy: digest`), então um novo build sob a mesma tag já é detectado e sincronizado automaticamente — não é necessário mudar a tag a cada release para o GitOps funcionar.
* Migrar para tags git-sha ou semver por build exigiria reconfigurar a strategy do Image Updater em todo componente já integrado (de `digest` para `latest`/semver-sorting) e geraria um volume de tags no Docker Hub desproporcional ao ritmo real de mudança do software (release da TOTVS, não commit).
* A lacuna real desse modelo — não dá pra olhar uma imagem rodando e saber de qual commit ela veio, já que a tag não muda — foi fechada sem tocar na tag: todo `pipeline` dos repos `docker-*` agora grava o label `org.opencontainers.image.revision` com o SHA do commit em cada imagem publicada (`docker inspect` revela a proveniência exata).

### 🔁 Estratégia de Rollout: `Recreate` nos componentes com volume `hostPath`

`postgres`, `license`, `webapp`, `printer` e `smartview` usam `strategy.type: Recreate` em vez do `RollingUpdate` padrão do Kubernetes. Motivo: todos montam um volume `hostPath` (via PVC) ou dispositivo de host (`/dev/mem`, no caso do `license`) — diferente de volumes de rede, o `hostPath` não impede dois pods de acessarem o mesmo caminho simultaneamente, então o `RollingUpdate` pode deixar o pod antigo e o novo rodando ao mesmo tempo sobre os mesmos dados por um instante. Foi exatamente isso que causou um restart transitório do Postgres (`postmaster.pid` inconsistente) durante uma troca de imagem — sem perda de dados, mas o `Recreate` elimina esse risco: derruba o pod antigo por completo antes de subir o novo. `dbaccess` não usa nenhum volume, então continua com `RollingUpdate` (não há dado compartilhado em risco).


