# ADR 0022 — N topologias por cluster: um namespace por topologia, overlay + ApplicationSet

## Status
**Proposto** em 2026-10-04 (decisão do usuário na discussão da frente B; **nada implementado**).
Antecede qualquer código de "criar topologia". Complementa os ADRs 0004/0012 (PVs), 0017 (portas),
0019 (manager) e 0023 (catálogo de releases).

## Contexto
Hoje o cluster tem **um ambiente fixo**: namespace `protheus-devops`, 1 `Application` (`base/`, branch
`develop`), 11 PVs com nomes e caminhos fixos em `/media/rodrigo/dados/k8s-volume/<x>`, banco
`protheus`, portas padrão do Protheus em `127.0.0.1` (ADR 0017), `SealedSecret` preso a nome +
namespace, sem overlays, e 1 alias do Image Updater por nome de imagem (L15: o override casa por
**nome**, então duas topologias com a mesma imagem colidem).

A release `12.1.2610` (rpo, system, systemload e binários novos) será liberada em breve. O usuário
quer, no **mesmo cluster**, poder **migrar** uma topologia para a nova release **ou criar** uma
topologia nova com ela (ADR 0023 cobre a migração e o catálogo; este cobre o isolamento).

Fatos verificados em 2026-10-04: Argo CD v3.5.3 com `applicationset-controller` ativo; Image Updater
v1.3.0 (CR `ImageUpdater` com `applicationRefs`); k3d v5.9.0; máquina com 15 GiB de RAM e 4 vCPU,
~6,6 GiB disponíveis e swap em uso; pods Protheus somam ~0,9 GiB (a plataforma — Argo, Falco,
monitoring, Velero — domina o consumo).

## Decisão
1. **Uma topologia = um namespace.** `protheus-devops` continua existindo e é a topologia da release
   `12.1.2510`. Um cluster, N topologias; **não** há segundo cluster (duplicaria a plataforma e não
   cabe em 15 GiB).
2. **Declaração no git: `base/` genérica + `topologies/<nome>/` (overlay Kustomize) + ApplicationSet**
   com gerador de **diretório git**: uma `Application` por pasta de topologia. O overlay fixa
   namespace, prefixo de PV/caminho, a release do catálogo (ADR 0023), o loopback e o bloco de
   NodePort, e traz o `RoleBinding` do manager nesse namespace.
3. **`protheus-devops` vira a primeira topologia com render IDÊNTICO ao de hoje.** Critério de corte:
   `kubectl kustomize` antes e depois **sem diferença** (`diff` vazio), e só então o Argo CD passa a
   usar o ApplicationSet. Os nomes de PV e os caminhos atuais **não mudam** (PV é cluster-scoped e
   imutável; ADR 0004/0012).
4. **Endereçamento:** `127.0.0.N` por topologia (`.1` = `protheus-devops`, `.2` = Compose, `.3+` =
   novas), com as **mesmas portas padrão** do ADR 0017. Cada topologia recebe um **bloco de
   NodePort** próprio (NodePort é único no cluster).
5. **Volumes:** PVs e caminhos novos com prefixo da topologia (`<topologia>-…`,
   `k8s-volume/<topologia>/…`), sempre `local`/`Retain` com `nodeAffinity` desde o primeiro commit
   (regra do ADR 0004).
6. **Banco:** base **vazia** por topologia, com a convenção `protheus`/`protheus`/`protheus` e a
   restrição de senha do `CLAUDE.md`. O **bootstrap manual do usuário** (regra dura) vale em toda
   topologia nova: nada de UPDDISTR/worker/compile antes dele.
7. **Segredos:** `SealedSecret` re-selado por namespace com o **certificado público** do
   sealed-secrets (a API não precisa da chave privada). O destino do texto puro (cofre GPG,
   ADR 0011) fica em aberto.
8. **Image Updater:** **um `applicationRef` por topologia**, com a tag da release daquela topologia,
   para que o mesmo nome de imagem em duas tags não colida (L15). Validar no spike s2.
9. **Velero:** a topologia nova entra no `Schedule` diário (ou ganha schedule próprio).
10. **Publicar as portas é ação de HOST**: `k3d cluster edit --port-add` recria o `serverlb` e está
    fora do alcance da API. "Criar topologia" **sempre termina com um passo do usuário**, cujo comando
    a API devolve pronto (e que não é destrutivo para os dados).
11. **Um manager por cluster** (ADR 0023, decisão D13): rotas `/api/v1/topologies/{t}/…`. As rotas
    atuais seguem valendo para `protheus-devops`, então o contrato e a régua não quebram. O poder do
    manager num namespace nasce do `RoleBinding` declarado no overlay da topologia.

## Spikes obrigatórios antes de implementar (namespace descartável, padrão do ADR 0015)
- **s1** — o ApplicationSet **adota** o `Application` existente `protheus-devops-stack` sem
  prune/recriação (um erro aqui apaga o ambiente vivo; `Retain` nos PVs é a rede de segurança, não o
  plano).
- **s2** — `ImageUpdater` com dois `applicationRefs` e tags diferentes do mesmo nome de imagem, sem
  colisão de override.

## Alternativas descartadas
- **Segundo cluster k3d**: isolamento total, mas duplica Argo/Falco/monitoring/Velero.
- **Um namespace só com prefixos**: mistura RBAC, PVC e Secrets; o `SealedSecret` já é preso a
  namespace.
- **Helm chart com values por topologia**: reescreve todos os manifestos validados e troca a
  ferramenta do projeto sem ganho que o Kustomize não dê aqui.
- **`Application` escrita à mão por topologia**: funciona, mas cada topologia vira passos manuais
  (Application + ImageUpdater); o ApplicationSet gera os dois a partir da pasta.

## Consequências
- Criar uma topologia passa a ser **adicionar uma pasta no git** (gerada pela API, ADR 0023),
  revisada e commitada pelo usuário.
- A refatoração `base/` → overlay é a **parte mais arriscada**: toca o ambiente vivo. Por isso o
  critério de `diff` vazio e o spike s1 vêm antes.
- **Memória:** uma segunda topologia custa ~1–1,5 GiB; na prática cabem ~2 de pé. ❓ Não medido sob
  carga; swap já está em uso.
- A topologia nova ainda **não existe** em lugar nenhum; este ADR só declara o desenho.

## Em aberto
- Destino do texto puro dos segredos por topologia (cofre GPG).
- Política de **remoção** de topologia (o `prune` do ApplicationSet e os PVs `Retain` pedem um
  procedimento próprio; comandos destrutivos são do usuário).
- Limite real de memória/CPU com duas topologias de pé (B-Q6).
