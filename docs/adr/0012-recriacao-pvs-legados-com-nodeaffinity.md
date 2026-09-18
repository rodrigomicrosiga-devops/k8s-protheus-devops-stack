# ADR 0012 — Recriação dos 3 PVs legados com `nodeAffinity`, e o que a operação ensinou sobre sync/hooks do Argo CD

## Status
Aceito, executado ao vivo em 2026-09-18. Fecha o item 3 do backlog e a dívida do ADR 0004.

## Contexto
`postgres-pv`, `webapp-shared-pv` e `printer-shared-pv` tinham nascido em 2026-07-28 sem
`nodeAffinity` — campo imutável em PV já existente, impossível de retrofit (ADR 0004). A única
correção real é recriar o PV do zero. Avaliado com o usuário antes de agir: não há dado de
produção em risco (ambiente pessoal de desenvolvimento), decisão de prosseguir com a recriação
real em vez de só documentar o procedimento manual.

## Decisão
Procedimento executado (mesmo padrão git-mediado já usado pros Jobs da Fase E, ADR 0009):

1. **Linha de base capturada antes de mexer**: contagem de tabelas do Postgres (171), hash
   SHA-256 de `webapp.so` e `printer` — pra provar depois que nada foi perdido.
2. **Pausa via git**: `replicas: 0` em `postgres`, `webapp`, `printer`, `appserver-core`,
   `appserver-rest`, `appserver-telnet` (os 6 consumidores das 3 PVCs) — commit, push, esperar
   os pods sumirem de fato.
3. **Delete direto do PVC + PV** (`kubectl delete`, fora do git — ação de cluster ao vivo, não
   uma mudança declarada). `persistentVolumeReclaimPolicy: Retain` nos 3 garante que o
   `hostPath` real no node **não é apagado** só porque o objeto PV foi deletado.
4. **Editar o git pra declarar `nodeAffinity`** nos 3 manifestos (mesmo formato de
   `protheus-seed.yaml`) — commit, push.
5. **Deletar de novo** os PVC/PV que o `selfHeal` já tinha recriado (a partir do manifesto
   antigo, sem `nodeAffinity`, porque o primeiro delete e o push do novo manifesto não foram
   atômicos — ver "obstáculos reais" abaixo) — garante que a recriação final usa o manifesto
   já corrigido.
6. Validado: os 3 PVs nasceram com `nodeAffinity` (`k3d-protheus-cluster-agent-0`), `Bound`.
7. **Restaurar réplicas via git** (`replicas: 1` nos 6) — commit, push.
8. **Validação final**: 171 tabelas no Postgres (idêntico à linha de base), hash de `webapp.so`
   e `printer` idênticos, imagens dos 3 de volta ao digest pinado (não tag solta), 0 restarts
   novos em qualquer outro componente do namespace.

## Obstáculos reais enfrentados (o motivo de existir uma seção própria pra isso)

Nenhum destes estava previsto — registrados porque o item 3 (recriar o cluster inteiro do zero)
vai bater exatamente nos mesmos problemas, numa escala maior.

1. **`kubectl annotate ... argocd.argoproj.io/refresh=hard` foi um erro** — forçou uma
   sincronização **completa**, que re-executa **todos** os hooks `PreSync` declarados no app
   (ADR 0003: hooks re-rodam a cada sync). O `selfHeal` "leve" (heal só do recurso que driftou)
   que tinha recriado os PVs em 16 segundos, sem tocar em hook nenhum, é um caminho totalmente
   diferente de uma sincronização completa disparada explicitamente. **Nunca forçar refresh/sync
   manual sem necessidade real** — o `selfHeal` passivo já resolve drift sem esse custo.
2. **Dependência circular real**: o hook `PreSync` `smartview-db-init` espera o Postgres
   responder — mas o Postgres (que estava pausado de propósito) só é aplicado na fase `Sync`,
   que só começa depois que **todos** os hooks `PreSync` terminam. Uma sincronização completa
   nunca destrava sozinha nesse cenário — o hook espera algo que está estruturalmente depois
   dele na mesma operação.
3. **`syncStrategy: apply` não pula hooks** — muda só como recursos normais são aplicados
   (`apply` vs `create`/`replace`); hooks continuam rodando como hooks de qualquer forma. Não
   existe uma opção simples de "pular hooks nesta sincronização" via patch direto na
   `Application`.
4. **Argo CD se recusa a repetir automaticamente uma sincronização que falhou pra mesma
   revisão** (`"Skipping auto-sync: failed previous sync attempt to [rev]"`) — trava até uma
   revisão nova (novo commit) ou uma operação manual explícita. Interromper uma sincronização no
   meio (como aconteceu aqui, indiretamente) deixa esse estado que **nem o `selfHeal` passivo
   contorna sozinho**.
5. **Job de hook travado em `Terminating`** (finalizer `argocd.argoproj.io/hook-finalizer`) não
   solta sozinho quando a operação que o criou foi interrompida no meio. Destravado com
   `kubectl patch job ... --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'` —
   técnica de último recurso pra finalizer preso, usar só quando o controller dono realmente não
   está cooperando (confirmado aqui: `argocd-application-controller` saudável, só não reconciliou
   o recurso deletado fora de banda a tempo).
6. **`kubectl apply -f` direto num arquivo que é parte do Kustomize tem dois efeitos colaterais
   reais**, ambos confirmados ao vivo neste procedimento:
   - **Reverte o digest do Image Updater pra tag solta** — a resolução tag→digest só existe no
     `spec.source.kustomize.images` da `Application` (aplicada pelo Argo CD via kustomize build
     próprio), nunca no git. Um apply direto não passa por isso. Efeito observado: `postgres`
     voltou a rodar `postgres-dev:16` sem `@sha256`, por alguns segundos, até o `selfHeal`
     corrigir sozinho depois. Sem dano real aqui porque era só esse um recurso, isolado — mas é
     exatamente o mecanismo do incidente de 2026-07-28 já documentado (mass restart).
   - **Não reescreve o nome do ConfigMap gerado por `configMapGenerator`** — o hash-suffix
     (`postgres-config-b7k44b4dt8`) só é resolvido pelo build completo do Kustomize. Apply direto
     deixa o `envFrom` apontando pro nome-base (`postgres-config`), que não existe de verdade —
     `CreateContainerConfigError`. Corrigido com `kubectl patch` pontual no `envFrom`, sem tocar
     em mais nada.
   - **Uso justificado aqui mesmo assim**: era o único jeito de tirar o Postgres do
     zero-réplicas sem esperar uma sincronização completa (bloqueada pelo hook, ver item 2
     acima). Uma vez que o Postgres respondeu, o hook terminou sozinho e o Argo CD completou o
     resto da sincronização normalmente, corrigindo os efeitos colaterais do apply direto sem
     intervenção adicional.

## Consequências
- Item 3 do backlog fechado de vez — sem mais dívida de DR pra esses 3 PVs.
- **Relevante pro item 3** (receita de cluster do zero): qualquer drill de DR completo vai
  recriar `postgres`/`webapp`/`printer` do zero, e o hook `smartview-db-init` vai correr atrás
  do Postgres do mesmo jeito. Duas soluções possíveis a avaliar quando o item 3 for feito: (a)
  seguir a receita "pausa → apply direto pontual → deixa o selfHeal completar" documentada aqui,
  ou (b) reordenar a dependência do hook (torná-lo tolerante a rodar mais tarde, ou remover do
  caminho crítico de um bootstrap do zero). Não decidido agora — fica registrado pro item 3.
- Nenhum dado real perdido: `persistentVolumeReclaimPolicy: Retain` se provou na prática, não só
  na teoria — os 3 hostPaths sobreviveram a dois ciclos de delete+recreate do objeto PV.
