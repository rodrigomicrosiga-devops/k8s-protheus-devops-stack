# Prompt de continuidade — Protheus Manager (atualização de artefatos e topologia por release)

Escrito em **2026-10-04**, no fim da sessão em que o Protheus Manager (API em Go + frontend) foi colocado no ar. É
autossuficiente: copie **o bloco abaixo, inteiro e sem editar**, numa sessão nova do Claude Code aberta em
`/media/rodrigo/dados/k8s-protheus-devops-stack`.

Estado de referência para quem for conferir: o HANDOFF (`docs/HANDOFF.md`, seção "Onde paramos") foi escrito
**depois de reconferir tudo ao vivo** e marca cada item como ✅ conferido, 🟡 validado antes, ❓ nunca verificado.
Se algo divergir quando você retomar, **a realidade ao vivo manda** e a divergência é o primeiro assunto.

---

## O prompt

````
Você está retomando o projeto k8s-protheus-devops-stack (Protheus/TOTVS rodando em Kubernetes via GitOps, Argo CD),
no ponto em que o "Protheus Manager" (uma API em Go + um frontend) acabou de ser colocado no ar. O projeto é pessoal
e serve de veículo da minha transição de carreira para DevOps: explique o PORQUÊ das decisões, não só execute.

Siga a ordem abaixo. A regra mais importante: NÃO IMPLEMENTE NADA das frentes A e B antes de eu decidir. O objetivo
desta sessão é DISCUTIR e DECIDIR com rigor; só depois registrar em ADR; só depois codar.

══════════ 0. LEIA ANTES DE QUALQUER COISA (nesta ordem) ══════════
1. /media/rodrigo/dados/k8s-protheus-devops-stack/CLAUDE.md
2. docs/HANDOFF.md — SÓ a seção "Onde paramos (2026-10-04, fim do dia …)". Ela foi escrita depois de reconferir tudo ao
   vivo e MANDA sobre o "Histórico" abaixo dela (que tem afirmações vencidas de propósito, marcadas como tal).
3. docs/adr/0017 a 0021 (portas, boot, manager, frontend, API em Go). O 0019 e o 0021 são os mais importantes.
4. A memória do projeto (project_protheus_manager.md, project_k8s_protheus_stack.md e os feedback_*). Memória é
   ponto no tempo: confirme no repo antes de afirmar.

Onde tudo está (todos em /media/rodrigo/dados/, GitHub org rodrigomicrosiga-devops, repos PRIVADOS):
- k8s-protheus-devops-stack  — manifestos (base/), Argo CD (argocd/), scripts, ADRs, HANDOFF. Este é o diretório de trabalho.
- protheus-manager-api       — Go 1.25. openapi/openapi.json é o CONTRATO congelado; scripts/contract-check.sh é a RÉGUA
                               de contrato; docs/diagrams/render.mjs gera os PNG dos diagramas do README.
- protheus-manager-web       — nginx + página estática, proxy /api na mesma origem; e2e/run.sh (Chrome real).
- docker-protheus-devops-stack — Compose de referência (publica em 127.0.0.2). docker-protheus-* — 16 repos, um por imagem.
Acessos: Swagger http://127.0.0.1:8800/docs · tela http://127.0.0.1:8801 · token em base/manager-secret.env (local,
gitignored). NUNCA imprima o token nem credenciais: carregue em variável (grep/cut) e use sem exibir.
Go não está instalado no host: compile/teste num container (golang:1.25-alpine); o README da API tem o atalho `gorun`.

══════════ 1. VERIFICAÇÃO DE RETOMADA (somente leitura) — ANTES de qualquer conversa ══════════
Rode as "Verificações rápidas" da seção 7 do HANDOFF e me entregue um quadro ✅/🟡/❓ comparando o ao-vivo com o HANDOFF.
Divergência = PARE e me conte antes de seguir. Confira em especial:
 a) rest e telnet continuam com 0 réplicas? (eu os parei de propósito pela tela. NÃO os religue sem eu pedir.)
 b) digest da API em produção termina em dabb7d7a… e /health diz 0.4.0; os 4 repos com HEAD == origin/develop.
 c) as 14 portas em 127.0.0.1 do serverlb; 13 pods 1/1; Argo CD Synced/Healthy.
 d) As imagens com conteúdo TOTVS ainda estão PÚBLICAS no Docker Hub? (HANDOFF 0.1 / L1 — há um comando de HEAD anônimo,
    que não baixa camada.) Se eu já tiver mudado isso, mapeie o impacto (14 manifestos sem imagePullSecrets: 10 pods rodando hoje + rest/telnet parados + 2 Jobs).

══════════ 2. TRÊS ITENS QUE PODEM MUDAR O QUE FAZER (pergunte, não presuma) ══════════
 - L1 (🔴): imagens TOTVS públicas apesar de os READMEs dizerem "privado". Decisão minha. Se eu decidir tornar privado,
   a ordem segura está no HANDOFF 0.1 (validar regcred → pôr imagePullSecrets em TODOS → só então privado).
 - rest/telnet parados: pergunte se continuam assim.
 - L2: o run-job.sh completo nunca rodou com um Job real (worker/compile/upddistr). É disparo MEU, de propósito. Não o execute.

══════════ 3. DISCUSSÃO A — serviço/API para ATUALIZAR ARTEFATOS ══════════
Minha premissa: tudo que for atualizado já precisa ter IMAGEM criada e publicada no Docker Hub (o portal da TOTVS não é
acessado diretamente). Fatos já verificados (HANDOFF seção 6.A): classes de artefato (binários em imagem; os 3 seeds da
release 12.1.2510; o RPO patcheado em protheus-apo, que NENHUMA imagem reconstrói e muda por Job worker/compile/upddistr;
includes); como a imagem nasce hoje (CI no runner self-hosted lê o artefato do DISCO do runner, tag fixa); como o cluster
adota (Image Updater por digest; trocar de TAG exige editar base/*.yaml + o alias do ImageUpdater + kubectl apply; o
override casa por NOME de imagem; o cutover tem DOIS rollouts); o seed do RPO NUNCA sobrescreve uma release diferente.
Discuta comigo, em blocos pequenos e com opções + recomendação, as perguntas A1–A7 do HANDOFF:
 A1 escopo ("artefato" = só imagens? também RPO/patch/dicionário? o que significa "atualizar o share"?)
 A2 descoberta de versões novas (listar tags/digests no Hub × o que roda; quem avisa?)
 A3 quem constrói a imagem (só consumir o publicado, ou a API dispara a CI → token do GitHub = segredo novo?)
 A4 troca de versão: alterar o ImageUpdater direto no cluster (sem histórico no git) OU commitar nos 2 arquivos
    (credencial de escrita no git = segredo novo)
 A5 segurança da atualização (parar AppServers? backup antes? portão do bootstrap? confirmação digitada? rollback?)
 A6 onde mora a matriz de compatibilidade entre componentes · A7 auditoria durável antes de qualquer troca de binário

══════════ 4. DISCUSSÃO B — serviço/API para CRIAR UMA TOPOLOGIA por versão/release ══════════
Minha ideia: criar uma topologia com base na versão/release desejada — "praticamente o protheus-systemload-seed".
Fatos já verificados (HANDOFF seção 6.B): o systemload-seed NÃO é a topologia (entrega 3 pacotes ao volume
protheus-systemload; é um eixo da release, ao lado de rpo e system); "release" hoje = 12.1.2510 e as versões dos binários
são independentes (a matriz release→versões NÃO existe no repo); o ambiente é ÚNICO e fixo (namespace protheus-devops,
11 PVs com nomes e caminhos fixos, banco "protheus", portas padrão em 127.0.0.1, SealedSecret preso a nome+namespace, sem
overlays, Image Updater com override por nome de imagem ⇒ duas topologias com a mesma imagem colidem).
Regras duras: base nova ⇒ bootstrap manual meu antes de UPDDISTR/worker/compile; o seed do RPO nunca sobrescreve outra
release; trocar release com dados existentes é migração deliberada (README de docker-protheus-rpo) + upddistr + backup.
Discuta comigo as opções B1 (trocar a release do ambiente único), B2 (ambiente paralelo por namespace) e B3 (só GERAR o
diff/commit GitOps para revisão) e as perguntas B-Q1…B-Q6. Minha inclinação (a confirmar): B3 + descoberta (A2) primeiro,
e um ADR de isolamento multi-ambiente ANTES de B2. A e B dependem do MESMO catálogo de releases: decidir o formato UMA vez.
Antes de recomendar qualquer coisa sobre topologia, leia de verdade: base/protheus-seed.yaml, os entrypoints e READMEs de
docker-protheus-rpo / -system / -systemload, argocd/image-updater.yaml e docs/adr/0002, 0004, 0012, 0013, 0015, 0017.

MÉTODO da discussão: uma pergunta de decisão por vez quando a resposta muda o desenho; mostre o trade-off e DÊ uma
recomendação (não um catálogo de opções); aponte o que você NÃO sabe e verifique em vez de supor; registre cada decisão
fechada. Ao fim, escreva o(s) ADR(s) (próximo número: 0022) e me peça aprovação ANTES de qualquer código.

══════════ 5. DEPOIS DAS DECISÕES — ordem sugerida (confirme comigo) ══════════
 1) ADR(s) das frentes A e B.  2) Auditoria DURÁVEL (hoje só stdout do pod; pré-requisito da Fase 3 e de qualquer troca de
 versão de binário).  3) Catálogo de releases (formato decidido em A/B).  4) Implementação em Go, na API.
 5) Fase 3 da API (Jobs worker/compile/upddistr) atrás do portão do bootstrap, sem force.  6) L5 (risco do namespace
 velero no bootstrap do zero) e demais lacunas do HANDOFF seção 4, na ordem que eu priorizar.

══════════ 6. MÉTODO DE TRABALHO (obrigatório — cada item nasceu de um erro real) ══════════
 - ADR ANTES de código. Mudança de contrato começa no openapi/openapi.json e passa na RÉGUA (scripts/contract-check.sh,
   com e sem --mutating) antes de trocar a imagem de produção.
 - Testes com os fakes OFICIAIS do client-go (não fakes escritos à mão) + TESTE DE MUTAÇÃO nas guardas de segurança:
   quebre o código de propósito e veja os testes reprovarem (um mutante já sobreviveu uma vez).
 - Validar uma versão nova AO LADO da atual (Deployment de prévia, MESMA ServiceAccount) e com imagem de OUTRO NOME (o Image
   Updater casa o override por nome e já trocou uma prévia pela imagem de produção).
 - Depois de QUALQUER rollout: confira o imageID (digest) do pod e a versão no /health — não só "Running". O cutover tem dois
   rollouts. Ambiente local e fakes já mentiram 5 vezes; teste sempre no cluster real.
 - README completo (como usar, exemplos, fluxo mermaid, segurança, troubleshooting). O visualizador do GitHub às vezes falha
   ao renderizar Mermaid: diagramas viram PNG gerados do bloco do README (docs/diagrams/render.mjs); depois de editar um
   diagrama, rode o render e OLHE a imagem.
 - Comandos destrutivos (rm, wipe, DROP) quem roda sou EU, via "! comando" — prepare o comando e me peça.
 - Commits SEM trailer de IA (nenhum Co-Authored-By). Use [skip ci] em commits só de documentação nos repos com CI.
 - Nunca religar rest/telnet, nunca mudar a visibilidade de imagens, nunca rodar worker/compile/upddistr sem eu pedir.
 - Bootstrap manual do AppServer é regra dura (CLAUDE.md): UPDDISTR/worker/compile nunca antes de eu concluir o bootstrap.

══════════ 7. CHECKLIST ANTI-FALSO-POSITIVO (antes de dizer "feito") ══════════
 [ ] Vi o resultado de verdade (log, digest, resposta, imagem), não só "o comando rodou sem erro"?
 [ ] O artefato testado é o que vai para produção (digest conferido)?
 [ ] Testei o CAMINHO DE FALHA (token errado, serviço parado, banco fora, lista vazia), não só o feliz?
 [ ] Disse o que NÃO verifiquei, em vez de omitir? (marque ❓ no HANDOFF)
 [ ] Contei os testes de verdade (não de cabeça) e rodei a régua no alvo certo (porta/URL certos)?
 [ ] Nenhum segredo apareceu na conversa, em log ou em arquivo versionado?

══════════ 8. AO TERMINAR A SESSÃO ══════════
Reconfira o estado ao vivo; reescreva a seção "Onde paramos" do HANDOFF como UMA seção consolidada e atual (não empilhe
cronologia; rebaixe a antiga para histórico e risque o que ficou vencido); atualize a memória; e me entregue um NOVO
prompt de continuidade no mesmo padrão deste. Não deixe lacuna sem registro.

COMECE pela seção 1 (verificação de retomada) e me traga o quadro antes de qualquer pergunta de design.
````
