# sigaacd-client — cliente telnet mínimo pro SIGAACD

O `SIGAACD` é o console de administração do AppServer acessível via `appserver-telnet`
(`base/appserver-telnet.yaml`, porta `23`/`1236`). Clientes telnet genéricos — testado com
**PuTTY 0.81** — não conseguem navegar o menu dele. `sigaacd_client.py` é um cliente mínimo,
escrito especificamente pra contornar os dois problemas reais encontrados (não é achismo —
diagnosticado ao vivo com captura de bytes crus, ver "Como foi descoberto" abaixo).

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

## O que este script faz diferente

- **Não faz eco local nenhum**: o terminal do usuário entra em modo raw (`tty.setraw`), cada tecla
  vai direto pro socket, sem processamento.
- **Não traduz nada**: os códigos ANSI que o próprio `SIGAACD` manda (posicionamento de cursor
  `ESC[lin;colf`, vídeo reverso `ESC[7m`) são escritos direto no stdout — o terminal real do
  usuário (qualquer emulador ANSI padrão) já sabe desenhar isso sozinho.
- **Responde a negociação IAC** do telnet (`DO`/`WILL`/`SB`) automaticamente, incluindo
  `TERMINAL-TYPE` (responde `VT100` se o servidor pedir via subnegociação).

## Uso

```bash
kubectl port-forward deployment/appserver-telnet 2323:23 -n protheus-devops &
python3 scripts/sigaacd-client/sigaacd_client.py            # default 127.0.0.1:2323
python3 scripts/sigaacd-client/sigaacd_client.py <host> <porta>   # outro endereço
```

Dentro do SIGAACD: número da posição do item + `ENTER` abre; `ESC` aborta/sai da tela atual.
Pra sair do **cliente** (não do SIGAACD): `Ctrl+]`.

**Precisa de terminal de verdade** — roda num terminal interativo local (não faz sentido via
pipe/redirecionamento), o `tty.setraw` exige um TTY real em `stdin`.

## Como foi descoberto

Diagnosticado com um script Python à parte (não versionado — era só instrumentação de uma vez),
conectando via socket cru direto na porta, capturando os bytes exatos que o servidor devolvia
depois de cada tecla de teste. Sequência real: `ESC O B` (seta baixo, modo Application) →
servidor respondeu com a tela "Abortado pelo operador", confirmando que `ESC` sozinho é a tecla
de cancelar; digitar `2` no menu raiz (com o menu já assentado, sem nenhum envio pendente) moveu
o destaque de `Atualizações` (item 1) pra `Consulta` (item 2), confirmado no byte de vídeo
reverso (`\x1b[7m`) migrando de linha — sem envolver eco nenhum, já que a captura é só do que o
servidor manda, nunca do que o cliente "imprime" localmente.
