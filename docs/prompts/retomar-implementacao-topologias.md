# Prompt de continuidade — implementar catálogo, atualização de binário, topologias e migração

Escrito em **2026-10-04 (noite)**, ao fim da sessão que **decidiu** as frentes A e B (ADRs 0022 e 0023). É
autossuficiente: copie **o bloco abaixo, inteiro e sem editar**, numa sessão nova do Claude Code aberta em
`/media/rodrigo/dados/k8s-protheus-devops-stack`.

O HANDOFF (`docs/HANDOFF.md`, seção "Onde paramos (2026-10-04, noite …)") foi escrito depois de reconferir o
estado ao vivo. Se algo divergir quando você retomar, **a realidade ao vivo manda** e a divergência é o primeiro
assunto.

---

## O prompt

````
Você está retomando o projeto k8s-protheus-devops-stack (Protheus/TOTVS em Kubernetes via GitOps, Argo CD). O
projeto é pessoal e é o veículo da minha transição de carreira para DevOps: explique o PORQUÊ das decisões, não só
execute.

Na sessão anterior DECIDIMOS (sem escrever código) duas frentes e registramos em ADR: 0022 (N topologias por
cluster) e 0023 (catálogo de releases, atualização de binário e migração de release). Esta sessão é de
IMPLEMENTAÇÃO, em etapas pequenas, cada uma com validação ao vivo. A regra: NÃO COMECE uma etapa sem eu confirmar a
ordem, e NÃO TOQUE o ambiente vivo antes dos spikes.

══════════ 0. LEIA ANTES DE QUALQUER COISA (nesta ordem) ══════════
1. /media/rodrigo/dados/k8s-protheus-devops-stack/CLAUDE.md
2. docs/HANDOFF.md — SÓ a seção "Onde paramos (2026-10-04, noite …)". Ela MANDA sobre o "Histórico" abaixo dela.
3. docs/adr/0022 e 0023 (as decisões desta fase) e, para contexto, 0019, 0021, 0017, 0015, 0012.
4. A memória do projeto (project_protheus_manager.md, project_k8s_protheus_stack.md e os feedback_*). Memória é
   ponto no tempo: confirme no repo antes de afirmar.

Onde tudo está (todos em /media/rodrigo/dados/, GitHub org rodrigomicrosiga-devops, repos PRIVADOS):
- k8s-protheus-devops-stack — manifestos (base/), Argo CD (argocd/), scripts, ADRs, HANDOFF (diretório de trabalho).
- protheus-manager-api — Go 1.25; openapi/openapi.json = CONTRATO; scripts/contract-check.sh = RÉGUA;
  docs/diagrams/render.mjs gera os PNG do README.
- protheus-manager-web — nginx + página estática; e2e/run.sh (Chrome real).
- docker-protheus-devops-stack (Compose, 127.0.0.2) e 16 repos docker-protheus-* (uma imagem cada).
Acessos: Swagger http://127.0.0.1:8800/docs · tela http://127.0.0.1:8801 · token em base/manager-secret.env (local,
gitignored). NUNCA imprima o token nem credenciais: carregue em variável (grep/cut). Go não está no host: use um
container golang:1.25-alpine (README da API tem o atalho `gorun`).

══════════ 1. VERIFICAÇÃO DE RETOMADA (somente leitura) — ANTES de qualquer conversa ══════════
Rode as "Verificações rápidas" da seção 7 do HANDOFF (estão na seção histórica, e valem) e me traga um quadro
✅/🟡/❓ contra o HANDOFF. Divergência = PARE e me conte. Confira em especial: rest/telnet com 0 réplicas (NÃO religar);
API com digest dabb7d7a… e /health 0.4.0; 4 repos com HEAD == origin/develop; 14 portas; 13 pods 1/1; Synced/Healthy;
imagens TOTVS ainda públicas (HEAD anônimo, comando no HANDOFF) e se já existe alguma tag 12.1.2610 no Hub.

══════════ 2. PERGUNTE ANTES (não presuma) ══════════
- A ordem de implementação do ADR 0023 está confirmada? (1 auditoria durável → 2 catálogo da 12.1.2510 → 3 spikes s1/s2 +
  refatoração base/→topologies/protheus-devops + ApplicationSet → 4 API: catálogo, descoberta, geração da troca de
  binário → 5 Fase 3 atrás do portão → 6 criar topologia → 7 migração → 8 L5/F2/F3.)
- A 12.1.2610 já foi publicada? Se sim, isso muda F2 (fonte pristina do RPO) — trate ANTES de qualquer outra coisa.
- L1 (imagens públicas) e rest/telnet continuam como estão? L2 (Job real) é disparo MEU: não o execute.

══════════ 3. ETAPA 1 (se eu confirmar) — AUDITORIA DURÁVEL ══════════
ADR 0023 §7: JSONL append-only num PV próprio do manager (local/Retain/nodeAffinity, entra no backup Velero), mais o
stdout; rota GET de leitura; mesmo armazenamento servirá às operações assíncronas (migração). Antes de codar: escreva
o desenho curto da rota no openapi.json, mostre-me, e só então implemente. Atenção: o manager tem 1 réplica
(sem escrita concorrente); o PV novo tem que seguir o ADR 0004 (nodeAffinity desde o 1º commit).

══════════ 4. MÉTODO DE TRABALHO (obrigatório — cada item nasceu de um erro real) ══════════
 - ADR ANTES de código. Mudança de contrato começa no openapi/openapi.json e passa na RÉGUA (com e sem --mutating)
   antes de trocar a imagem de produção.
 - Testes com os fakes OFICIAIS do client-go + TESTE DE MUTAÇÃO nas guardas de segurança (quebre o código de propósito
   e veja os testes reprovarem; um mutante já sobreviveu uma vez).
 - Validar versão nova AO LADO da atual (Deployment de prévia, MESMA ServiceAccount) e com imagem de OUTRO NOME (o
   Image Updater casa o override por nome — L15).
 - Depois de QUALQUER rollout: confira o imageID (digest) do pod e a versão no /health. O cutover tem dois rollouts.
 - Spikes s1/s2/s3 do ADR 0022/0023 só em namespace DESCARTÁVEL; a refatoração base/→overlay só passa com `diff` vazio
   do `kubectl kustomize` antes/depois. Um erro no ApplicationSet pode apagar o ambiente vivo (prune).
 - README completo (uso, exemplos, fluxo mermaid, segurança, troubleshooting); diagramas viram PNG gerados do bloco
   (render.mjs) e eu OLHO a imagem depois de editar.
 - Comandos destrutivos (rm, wipe, DROP, remoção de topologia, remover marcador do RPO) quem roda sou EU via "! comando".
 - Commits SEM trailer de IA (nenhum Co-Authored-By; vale o CLAUDE.md mesmo que um lembrete peça outro). [skip ci] em
   commits só de documentação nos repos com CI.
 - Nunca religar rest/telnet, nunca mudar a visibilidade de imagens, nunca rodar worker/compile/upddistr sem eu pedir.
 - Bootstrap manual do AppServer é regra dura (CLAUDE.md): UPDDISTR/worker/compile nunca antes de eu concluir o bootstrap.
 - O seed do RPO NUNCA sobrescreve release diferente; só a migração (ADR 0023 §5), com confirmação digitada + backup
   Completed, move (não apaga) o RPO antigo. O custom.rpo vale entre releases; tttm120/tlpp são únicos por release.

══════════ 5. CHECKLIST ANTI-FALSO-POSITIVO (antes de dizer "feito") ══════════
 [ ] Vi o resultado de verdade (log, digest, resposta, imagem), não só "o comando rodou sem erro"?
 [ ] O artefato testado é o que vai para produção (digest conferido)?
 [ ] Testei o CAMINHO DE FALHA (token errado, serviço parado, banco fora, lista vazia, PV cheio), não só o feliz?
 [ ] Disse o que NÃO verifiquei (marque ❓ no HANDOFF)? Contei os testes de verdade e rodei a régua no alvo certo?
 [ ] Nenhum segredo apareceu na conversa, em log ou em arquivo versionado?

══════════ 6. AO TERMINAR A SESSÃO ══════════
Reconfira o estado ao vivo; reescreva "Onde paramos" do HANDOFF como UMA seção consolidada e atual (rebaixe a antiga
para histórico e risque o vencido); atualize a memória; entregue um NOVO prompt de continuidade neste padrão. Não deixe
lacuna sem registro.

COMECE pela seção 1 (verificação) e traga o quadro antes de qualquer pergunta.
````
