#!/usr/bin/env python3
"""Cliente telnet interativo minimo pro SIGAACD (console de administracao
via TELNET do AppServer, monitor/SIGAACD).

Por que existe: clientes telnet genericos (testado: PuTTY 0.81) nao dao pra
usar aqui. Dois problemas reais, achados na pratica (ver
scripts/sigaacd-client/README.md para o diagnostico completo):

1. O SIGAACD nao usa setas/WordStar/mnemonic pra navegar o menu -- digita-se
   o NUMERO da posicao do item (1, 2, 3...) pra mover o destaque, ENTER abre
   o item destacado, ESC aborta/sai. Nenhuma sequencia VT100/ANSI de teclado
   e reconhecida como tecla especial (ESC sozinho ja e lido como "abortar").
2. O servidor nunca negocia a opcao telnet ECHO -- clientes como o PuTTY,
   sem essa negociacao explicita, ligam eco local por conta propria (modo
   "Auto"), duplicando visualmente cada tecla digitada por cima do redesenho
   real do servidor. Isso mascara a navegacao por numero, dando a impressao
   de que "so imprime o numero na tela" quando na verdade o servidor ja
   processou o comando corretamente.

Este cliente evita os dois: nao faz eco local nenhum (terminal em modo raw,
cada tecla vai direto pro socket) e deixa os codigos ANSI que o proprio
SIGAACD manda (posicionamento de cursor `ESC[lin;colf`, video reverso
`ESC[7m`) serem desenhados pelo terminal real do usuario, sem traducao.

Uso:
    kubectl port-forward deployment/appserver-telnet 2323:23 -n protheus-devops &
    python3 scripts/sigaacd-client/sigaacd_client.py [host] [porta]
    # default: 127.0.0.1 2323

Navegacao dentro do SIGAACD: numero da posicao do item + ENTER abre; ESC
aborta/sai da tela atual. Pra sair do CLIENTE (nao do SIGAACD): Ctrl+].
"""
import socket, sys, select, tty, termios, os

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2323

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
TTYPE, ECHO, SGA = 24, 1, 3

def handle_iac(sock, data):
    """Responde negociacao IAC (telnet options) e devolve so os bytes de
    dados reais (texto/ANSI) pra exibir."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        b = data[i]
        if b != IAC:
            out.append(b)
            i += 1
            continue
        if i + 1 >= n:
            break
        cmd = data[i + 1]
        if cmd in (DO, DONT, WILL, WONT):
            opt = data[i + 2] if i + 2 < n else None
            i += 3
            if cmd == DO:
                if opt == TTYPE:
                    sock.sendall(bytes([IAC, WILL, TTYPE]))
                elif opt == SGA:
                    sock.sendall(bytes([IAC, WILL, SGA]))
                else:
                    sock.sendall(bytes([IAC, WONT, opt]))
            elif cmd == WILL:
                if opt in (ECHO, SGA):
                    sock.sendall(bytes([IAC, DO, opt]))
                else:
                    sock.sendall(bytes([IAC, DONT, opt]))
        elif cmd == SB:
            j = i + 2
            while j + 1 < n and not (data[j] == IAC and data[j + 1] == SE):
                j += 1
            sub = data[i + 2:j]
            if sub and sub[0] == TTYPE and len(sub) > 1 and sub[1] == 1:
                # servidor pede o tipo de terminal via subnegociacao -- responde VT100
                sock.sendall(bytes([IAC, SB, TTYPE, 0]) + b"VT100" + bytes([IAC, SE]))
            i = j + 2
        else:
            i += 2
    return bytes(out)

def main():
    sock = socket.create_connection((HOST, PORT), timeout=10)
    sock.setblocking(False)
    stdin_fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)
    try:
        sys.stdout.write("\x1b[2J\x1b[H")  # limpa a tela local
        sys.stdout.flush()
        while True:
            r, _, _ = select.select([sock, stdin_fd], [], [], 0.2)
            if sock in r:
                try:
                    data = sock.recv(4096)
                except BlockingIOError:
                    data = b""
                if not data:
                    sys.stdout.write("\r\n[conexao encerrada pelo servidor]\r\n")
                    sys.stdout.flush()
                    break
                text = handle_iac(sock, data)
                if text:
                    os.write(sys.stdout.fileno(), text)
            if stdin_fd in r:
                key = os.read(stdin_fd, 16)
                if key == b"\x1d":  # Ctrl+]
                    sys.stdout.write("\r\n[saindo do cliente]\r\n")
                    sys.stdout.flush()
                    break
                sock.sendall(key)
    finally:
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_settings)
        sock.close()

if __name__ == "__main__":
    main()
