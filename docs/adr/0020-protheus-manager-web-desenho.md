# ADR 0020 — Frontend do manager: página estática, proxy de mesma origem, token só no navegador

## Status
Aceito e implementado em 2026-10-04. Fecha as decisões em aberto do README do
`protheus-manager-web` (CORS/proxy, stack, onde guardar o token, como roda, polling, cliente da API),
exceto a geração de cliente a partir do OpenAPI (ver "Em aberto").

## Contexto
A API do manager (ADR 0019) já tinha leitura e escrita de baixo risco validadas, mas só se usava por
`curl` ou Swagger. O frontend precisava chegar a ela sem abrir brecha: a tela comanda ações que
param serviços, e roda no navegador do usuário, que abre outras páginas.

## Decisão
1. **Página estática sem build** (HTML + JS em módulos + CSS), servida por **nginx-unprivileged**.
   Zero dependência de runtime no navegador e nada a compilar: o objetivo é operar o ambiente, não
   manter uma cadeia de build. A lógica pura (`lib.js`) é separada do DOM e testada com `node --test`.
2. **Proxy de mesma origem**: o nginx serve a tela e encaminha `/api/` para
   `protheus-manager-api-service`. Mesma origem, **sem CORS**; a API continua sem CORS habilitado.
3. **O proxy repassa o `Authorization` do navegador e nunca o cria.** Esta decisão **reverte a
   inclinação original** do README do frontend (proxy injetando o token, para o navegador nunca vê-lo).
   Motivo: se o proxy injetasse o token, qualquer página aberta no navegador poderia disparar
   `POST http://127.0.0.1:8801/api/v1/services/.../stop` e o proxy a autenticaria sozinho (CSRF; CORS
   não impede o *envio*, só a leitura da resposta). Com o token vindo do navegador num header
   customizado, a requisição cross-site exige preflight de CORS e é barrada.
4. **Token no `sessionStorage`** (some ao fechar a aba), digitado pelo usuário. Nunca `localStorage`,
   nunca em URL. Risco aceito: um XSS na própria origem leria o token — por isso a decisão 5.
5. **CSP estrita**: `default-src 'self'` (script, estilo e conexão só da própria origem), sem
   inline, `frame-ancestors 'none'`; mais `nosniff`, `X-Frame-Options: DENY`,
   `Referrer-Policy: no-referrer`. Todo dado da API entra no DOM por `textContent`/`createElement`,
   **nunca** `innerHTML` — log de AppServer é texto não confiável.
6. **Nginx só aceita GET e POST** em `/api/`, limita o corpo a 1 KB e esconde o `Server` do upstream.
   Resolve o upstream **a cada requisição** (`resolver` + variável), para subir mesmo com a API fora.
7. **Roda no cluster**, sem `ServiceAccount` (`automountServiceAccountToken: false`): só fala HTTP
   com a API, então não precisa de nenhuma permissão no Kubernetes. Não-root, rootfs somente leitura
   (`emptyDir` só em `/tmp`, `/var/cache/nginx` e `/etc/nginx/conf.d`). Exposto em
   `127.0.0.1:8801 -> NodePort 30881` (ADR 0017).
8. **Polling**: serviços a cada 5 s, Argo CD/backups/bootstrap a cada 15 s, **pausado com a aba
   oculta**. Eventos do servidor só se o polling incomodar.
9. **A tela não é fronteira de segurança.** Ela esconde Parar/Reiniciar da própria API e desabilita
   Reiniciar em serviço parado, mas a API recusa por conta própria; botão escondido é conforto.
   Toda ação mutável pede confirmação dizendo o efeito antes do clique.

### Alternativas descartadas
- **Proxy injetando o token**: CSRF, ver item 3.
- **API com CORS aberto para uma origem separada**: mais superfície, e CORS mal configurado é falha por
  si só; o proxy de mesma origem dispensa.
- **Framework com build (React/Vue)**: custo de manter dependências e cadeia de build, sem ganho para
  uma tela de operação com 4 cartões.
- **Cookie `HttpOnly` com sessão no servidor**: exigiria estado e login no proxy, para um ambiente de
  usuário único em loopback.

## Validação (feita antes de publicar)
- 10 testes de lógica pura (`node --test`), verificados no Node 18 (local) **e no Node 26** (runner).
- **E2E no Chrome real contra a imagem nginx real** e uma API falsa com o contrato real, 25 checks:
  login com token errado/certo; token só em `sessionStorage` e nada em `localStorage`; tabela,
  indicador do bootstrap, Argo CD e backups; Parar abre confirmação com o efeito, cancelar **não**
  chama a API, confirmar chama e atualiza a tabela; a própria API sem botões de ação; **um log com
  `<img src=x onerror=alert(1)>` aparece como texto e não executa**; Sincronizar e Criar backup;
  Sair limpa o token; **zero violações de CSP e zero erros no console**.
- No nginx: cabeçalhos de segurança presentes, `PUT` bloqueado (403), `401` da API repassado,
  `Server` do upstream escondido.

## Achados
1. **A CI falhou na primeira execução**: o runner usa **Node 26** e o teste local era Node 18.
   `node --test tests/` passou a tratar `tests/` como arquivo. Corrigido com o padrão explícito
   `tests/*.test.js`, verificado nas duas versões. Mesma classe de lição das fases anteriores: o
   ambiente local não é o ambiente de CI.
2. O `README` do frontend previa o proxy injetando token; a análise de CSRF mostrou que seria um
   erro. Registrado aqui como reversão deliberada.

## Consequências
- Sem estado no frontend e sem segredo na imagem: o token nunca está no bundle nem no nginx.
- Cada abertura da tela pede o token (a aba não persiste sessão). Custo aceito.
- O frontend herda qualquer mudança de contrato da API: rota nova começa na API.
- Dois pods e duas imagens a mais para manter (API e web), no mesmo padrão da frota.

## Em aberto
- **Cliente gerado do `/openapi.json`**: hoje a tela usa `fetch` direto; gerar tipos evitaria drift
  de contrato. Não valeu o custo de uma etapa de build para esta primeira entrega.
- A API pode migrar para Go (conversa de 2026-10-04); o contrato `/api/v1` é o que o frontend usa,
  então a troca não deve afetá-lo.
