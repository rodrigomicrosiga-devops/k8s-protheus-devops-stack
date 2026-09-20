# sigaacd-client — cliente telnet mínimo pro SIGAACD

O `SIGAACD` é o console de administração do AppServer acessível via `appserver-telnet`
(`base/appserver-telnet.yaml`, porta `23`/`1236`). Clientes telnet genéricos — testado com
**PuTTY 0.81** — não conseguem navegar o menu dele. Duas implementações equivalentes deste
diretório contornam isso — [`python/`](python/) (a original, usada pro diagnóstico) e
[`go/`](go/) (binário único, sem depender de `python3` instalado). Mesma lógica, mesmo protocolo,
escolha a que for mais conveniente.

## Por que o PuTTY (e provavelmente qualquer terminal padrão) não funciona

1. **Navegação não é por seta.** O `SIGAACD` tem raiz genuinamente DOS/Clipper/Harbour — não
   interpreta nenhuma sequência VT100/ANSI de teclado (`ESC[A`/`ESC[B`, modo Application `ESC
   OA`/`ESC OB`, scan codes DOS `0x00`/`0xE0`, atalhos "WordStar" `Ctrl+E`/`Ctrl+X`, mnemônicos
   por letra apesar do `&` nos títulos dos `.xnu`). `ESC` sozinho é lido como **abortar/sair** —
   qualquer tecla de seta, que sempre começa com `ESC`, aborta a tela antes de mais nada.
   A navegação real é: **digitar o número da posição do item** (`1`, `2`, `3`...) pra mover o
   destaque, e `ENTER` pra abrir o item destacado.
2. **O servidor nunca negocia a opção telnet `ECHO`.** Sem essa negociação explícita, clientes
   como o PuTTY (modo "Auto" de eco local) decidem ecoar localmente por conta própria — cada
   tecla digitada aparece duplicada, sobreposta ao redesenho real que o servidor manda. Isso dá a
   impressão de que "só imprime o número na tela" (nada navega), quando na verdade o servidor já
   processou o comando corretamente por baixo — só a visualização que fica poluída.

## O que os dois clientes fazem diferente

- **Não fazem eco local nenhum**: o terminal do usuário entra em modo raw (`tty.setraw` em
  Python, `golang.org/x/term.MakeRaw` em Go), cada tecla vai direto pro socket, sem processamento.
- **Não traduzem nada**: os códigos ANSI que o próprio `SIGAACD` manda (posicionamento de cursor
  `ESC[lin;colf`, vídeo reverso `ESC[7m`) são escritos direto no stdout — o terminal real do
  usuário (qualquer emulador ANSI padrão) já sabe desenhar isso sozinho.
- **Respondem a negociação IAC** do telnet (`DO`/`WILL`/`SB`) automaticamente, incluindo
  `TERMINAL-TYPE` (respondem `VT100` se o servidor pedir via subnegociação).

## Uso

Primeiro, em qualquer um dos dois, o `port-forward` precisa estar de pé:

```bash
kubectl port-forward deployment/appserver-telnet 2323:23 -n protheus-devops &
```

**Python** (precisa só de `python3`, nada além da stdlib):

```bash
python3 scripts/sigaacd-client/python/sigaacd_client.py            # default 127.0.0.1:2323
python3 scripts/sigaacd-client/python/sigaacd_client.py <host> <porta>
```

**Go** (precisa do toolchain Go só pra compilar; o binário resultante não depende de nada):

```bash
cd scripts/sigaacd-client/go
go build -o sigaacd-client .
./sigaacd-client              # default 127.0.0.1:2323
./sigaacd-client <host> <porta>
```

Dentro do SIGAACD (nos dois clientes): número da posição do item + `ENTER` abre; `ESC` aborta/sai
da tela atual. Pra sair do **cliente** (não do SIGAACD): `Ctrl+]`.

**Precisa de terminal de verdade** — roda num terminal interativo local (não faz sentido via
pipe/redirecionamento), o modo raw exige um TTY real em `stdin`.

## Limitação conhecida: caracteres acentuados comidos no título da tela de login

A linha de título da tela de login (`TOTVS Construção e Projetos POSTGRES Protheus`) chega
truncada — `TOTVS Constru  o e Pojetos POSTGRES Proteus`: `ç`/`ã` viram espaço em branco, e as
letras `r` (de "Projetos") e `h` (de "Protheus") somem por completo, sem nem virar espaço.

**Investigado a fundo, não é bug dos clientes deste diretório nem de configuração do cluster**:

- Os bytes já chegam corrompidos assim na captura mais crua possível (socket direto, sem
  nenhum cliente envolvido) — Python e Go só reproduzem fielmente o que recebem.
- `LANG`/`LC_ALL=C` testado ao vivo no `appserver-telnet` (commit + redeploy + reteste): zero
  efeito nos bytes recebidos. Revertido.
- O módulo de conversão `CP1252.so` está presente em `/usr/lib/x86_64-linux-gnu/gconv/` dentro
  do container — não é ausência de suporte a codepage no SO.
- A chave `Environment=` da seção `[TELNET]` do `appserver.ini` é só o nome do ambiente
  multi-DB (documentação oficial TOTVS), sem relação com charset/encoding.
- Nenhum relato equivalente encontrado em documentação oficial (TDN) ou fóruns TOTVS/ADVPL.

**Hipótese mais provável** (não confirmável sem acesso ao código-fonte do `appsrvlinux`, binário
proprietário): o título provavelmente é montado concatenando um campo de descrição da empresa
demo gravado em UTF-8 com uma rotina de exibição de largura fixa que conta bytes como se fossem
caracteres — cada acento UTF-8 de 2 bytes (`ç`, `ã`) desalinha o resto do buffer, explicando tanto
os espaços em branco quanto letras ASCII puras somem mais adiante na mesma linha.

**Não bloqueia o uso real do console** — login, navegação por número e abertura de rotinas
funcionam normalmente; é só a linha de título da tela de login que fica cosmeticamente
incompleta. Aceito como limitação conhecida, sem correção de infraestrutura pendente.

## Como foi descoberto

Diagnosticado com um script Python à parte (não versionado — era só instrumentação de uma vez),
conectando via socket cru direto na porta, capturando os bytes exatos que o servidor devolvia
depois de cada tecla de teste. Sequência real: `ESC O B` (seta baixo, modo Application) →
servidor respondeu com a tela "Abortado pelo operador", confirmando que `ESC` sozinho é a tecla
de cancelar; digitar `2` no menu raiz (com o menu já assentado, sem nenhum envio pendente) moveu
o destaque de `Atualizações` (item 1) pra `Consulta` (item 2), confirmado no byte de vídeo
reverso (`\x1b[7m`) migrando de linha — sem envolver eco nenhum, já que a captura é só do que o
servidor manda, nunca do que o cliente "imprime" localmente. Os dois clientes (Python e Go, esse
último implementado depois) foram validados ao vivo com o mesmo teste — login, navegação por
número e saída via `Ctrl+]`.
