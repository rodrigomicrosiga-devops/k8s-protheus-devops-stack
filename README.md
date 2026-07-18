# Protheus Devops Stack - Local Kubernetes Cluster

Ambiente de desenvolvimento Protheus em alta performance rodando localmente em cluster Kubernetes de nó único (**K3d/K3s**), focado em isolamento de pilha, automação de infraestrutura e portabilidade entre desenvolvedores.

## 🏗️ Arquitetura do Ambiente

A stack adota isolamento completo de rede via Namespace e injeção dinâmica de variáveis de ambiente locais ignoradas pelo Git (`.env`), garantindo a independência das credenciais de cada desenvolvedor.

```mermaid
graph TD
    subgraph Máquina Física (Linux Mint)
        DBeaver[DBeaver / pgAdmin] -- Túnel Local: 5432 --> K3D_LB
        DBMonitor[TOTVS DBMonitor] -- Túnel Local: 7891 --> K3D_LB
    end

    subgraph Cluster K3d (Namespace: protheus-devops)
        K3D_LB[K3d LoadBalancer / Port-Forward]
        
        subgraph Camada de Conectividade
            DBA_SVC[Service: dbaccess-service <br> NodePort: 30890] --> DBA_POD[Pod: DbAccess <br> v24.1.1.3]
        end

        subgraph Camada de Persistência
            PG_SVC[Service: postgres-service <br> Porta: 5432] --> PG_POD[Pod: PostgreSQL]
            PG_POD --> PVC[PersistentVolumeClaim] --> PV[PersistentVolume <br> local-path: /media/rodrigo/dados/]
        end

        %% Injeção de Variáveis
        CM[ConfigMap: postgres-config <br> postgres.env] -. envFrom .-> DBA_POD
        CM -. envFrom .-> PG_POD
        SEC[Secret: postgres-secret <br> postgres-secret.env] -. envFrom .-> DBA_POD
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


