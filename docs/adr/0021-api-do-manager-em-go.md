# ADR 0021 — API do manager reescrita em Go (mesmo contrato, mesma régua)

## Status
Aceito e **implantado** em 2026-10-04. A API Python (`0.3.0`) foi substituída pela Go (`0.4.0`) em
produção, com o contrato `/api/v1` congelado. Complementa o ADR 0019 (desenho do manager).

## Contexto
A API nasceu em Python/FastAPI para validar o desenho rápido (ADR 0019). Com as Fases 0–2 validadas
ao vivo, o usuário perguntou se migrar para Go era viável. A resposta foi **sim, e antes da Fase 3**:
a Fase 3 (`worker`/`compile`/`upddistr`) é o código mais arriscado do projeto e vai exigir a auditoria
durável; escrevê-lo uma vez, na linguagem final, é melhor do que escrever em Python e portar depois.
Go também é a linguagem do ecossistema Kubernetes (`client-go` é o cliente de referência), o que pesa
no objetivo de carreira do projeto, e o usuário já mantém um cliente em Go (`sigaacd-client`).

## Decisão
1. **Go 1.25**, biblioteca padrão (`net/http` com o `ServeMux` de padrões do Go 1.22), `client-go`
   **v0.35** (a série do Kubernetes 1.35 do cluster), `pgx/v5` e o Swagger UI embutido (`swgui`).
2. **Spec-first com contrato congelado.** O `openapi.json` gerado pela versão Python validada foi
   salvo em `openapi/openapi.json`, embutido no binário e servido em `/openapi.json` (com a versão em
   execução). Um teste exige que as **rotas registradas sejam exatamente as do spec**: rota nova sem
   entrada no spec, ou o contrário, reprova. O frontend e o Swagger não percebem a troca.
3. **Uma régua caixa-preta**, `scripts/contract-check.sh`, contra uma instância *rodando*, vale para
   qualquer implementação: 46 checks de leitura e recusa, mais cenários mutantes (stop/idempotência,
   restart logo após stop, serviço continuar parado após 40 s **e** após um sync do Argo CD, sync
   simultâneo, start/restart, backup real). Mediu o Python primeiro, para provar que a régua mede certo
   e **sabe falhar** (com token errado ou sem API ela reprova quase tudo).
4. **Mesmo repositório, branch própria, prévia ao lado da produção.** A versão Go rodou no cluster
   como um segundo Deployment, com a **mesma `ServiceAccount`** (portanto o mesmo RBAC), antes da troca.
   Só depois de passar a régua completa a imagem de produção foi trocada.
5. **Testes com os fakes oficiais do `client-go`** (`kubernetes/fake`, `dynamic/fake`), não fakes
   escritos à mão — foi o que nos enganou duas vezes em Python (ADR 0019). Mais **teste de mutação**.
6. **Imagem distroless** (`gcr.io/distroless/static:nonroot`), multi-stage, sem shell. O `HEALTHCHECK`
   chama o próprio binário (`-healthcheck`).
7. **Retorno possível em dois níveis:** a imagem `0.3.0` (Python) continua publicada, e o último commit
   Python está na tag `python-final` do repo da API.

### Alternativas descartadas
- **Manter Python** e só portar a Fase 3 depois: duplica o trabalho da parte arriscada.
- **Gerar o OpenAPI do código Go** (`huma`, anotações `swag`): mais dependência e outro formato de erro
  (o frontend depende de `{"detail": "texto"}`); o spec congelado é a fonte e o teste de contrato o
  mantém honesto.
- **Reescrever sem régua**: confiar só em testes unitários é o que deixou passar bugs em Python.

## Resultado medido
| | Python 0.3.0 | Go 0.4.0 |
|---|---|---|
| Régua de contrato (somente leitura) | 46/46 | 46/46 (local e no cluster) |
| Régua completa no cluster (mutante + backup real) | — | **66/66** (após 1 correção, ver achado 5) |
| Memória do pod | 89 MiB | **5–7 MiB** |
| Imagem | ~150 MB, com shell | **52 MB**, sem shell |
| Testes | 63 | 82 (62 funções + subtestes), 14/14 mutantes pegos |

Correção de uma estimativa minha: eu havia dito ~15 MB para a imagem; o binário tem 47,5 MB porque o
`client-go` é grande. O ganho real está na memória e na ausência de shell, não no tamanho.

## Achados (todos pegos por verificação, não por leitura de código)
1. **O `client-go` mais novo (v0.37) exige Go 1.26.** Fixado em v0.35, que também é a série que respeita
   a compatibilidade de versão com o servidor 1.35.
2. **Um mutante sobreviveu.** Remover a checagem `replicas == 0` do `restart` não reprovava nenhum
   teste: nos testes ela era redundante com o filtro de pods em término. Ela é a única guarda da janela
   entre o `scale` e o controlador marcar o pod para exclusão (réplicas 0, pod ainda vivo). Entrou um
   teste; o mutante passou a ser pego.
3. **Bug no `-healthcheck`**: com `MANAGER_LISTEN` contendo host, a URL virava
   `127.0.0.1127.0.0.1:18801`; o Docker marcava `unhealthy`. Extraído para `config.HealthURL` com teste.
4. **O Image Updater casa o override pelo *nome* da imagem.** A prévia (`…-dev:go-preview`) foi
   trocada pelo digest da `0.3.0` Python: o pod subiu rodando **Python** e os logs mostravam Uvicorn.
   Só o log denunciou; validar sem olhar o digest teria "aprovado" o Go medindo o Python. Corrigido
   publicando a prévia sob **outro nome de imagem** (`protheus-manager-api-go-dev`) e **conferindo o
   digest do pod antes de medir**. É uma armadilha para qualquer Deployment/Job futuro que reuse o
   nome da imagem da API.
5. **Janela no guard do sync** (`409 "já existe um sync em andamento"`). A régua completa deu 65/66: o
   segundo `POST` simultâneo respondeu 202. O guard olhava só `status.operationState.phase == Running`,
   e logo após o primeiro `POST` o controlador ainda não iniciou a operação — medido: em `t+1s` a fase
   ainda é `Succeeded` com `.operation` já preenchido. O sinal confiável é **`.operation` presente
   (que o Argo CD só limpa ao terminar) ou fase `Running`**. Corrigido no Go, com 2 testes de regressão e
   verificação por mutação. **A versão Python tinha a mesma janela** (só não aparecia porque eu esperava
   segundos entre as chamadas manuais); foi removida no cutover.
6. **O cutover tem dois rollouts, não um.** Mudar a tag no manifesto dispara o primeiro rollout, que
   ainda usa o override antigo (Python); depois o Image Updater move o override para o digest novo e o
   Argo CD faz o segundo (Go). Durante a janela o Argo CD fica `OutOfSync`. **Confirmar pelo digest do
   pod**, não pelo "Running". Documentado no README ("Ao subir a versão").

## Diferenças deliberadas em relação ao Python
- **422**: o corpo agora é `{"detail": "texto"}` (o FastAPI devolvia uma lista estruturada). O código
  HTTP é o mesmo. Melhora a tela, que só entende `detail` em texto.
- **Guard do sync** mais estrito (achado 5).
- **405** (método não permitido): o `ServeMux` do Go responde texto simples, não JSON. Não afeta o
  frontend (que nunca usa método errado); aceito.
- A versão sai de `internal/config` (`0.4.0`) e o spec embutido acompanha.

## Consequências
- Memória e superfície de ataque menores; sem shell na imagem. A Fase 3 será escrita já em Go.
- O contrato passou a ser **o `openapi.json` + a régua**: qualquer mudança de rota começa no spec.
- O repositório da API não tem mais Python; o histórico e a tag `python-final` guardam a versão antiga.
- A lista `required-sys-tables.txt` continua duplicada (repo do cluster para o shell, `internal/gate`
  para a API); regenerar nos dois lugares se o dicionário mudar.

## Em aberto
- **Auditoria durável**: continua só no stdout do pod. Pré-requisito da Fase 3.
- Leitura do Argo CD e demais Roles da Fase 3 (`jobs` create/delete).
