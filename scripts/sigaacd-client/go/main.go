// Cliente telnet interativo minimo pro SIGAACD (console de administracao via
// TELNET do AppServer, monitor/SIGAACD).
//
// Mesma logica e motivacao da versao Python irma (../python/sigaacd_client.py):
// ver ../README.md pro diagnostico completo de por que clientes telnet
// genericos (PuTTY) nao funcionam. Resumo: o SIGAACD nao reconhece nenhuma
// sequencia VT100/ANSI de teclado (ESC sozinho e "abortar"; navegacao real e
// digitar o numero da posicao do item + ENTER), e o servidor nunca negocia a
// opcao telnet ECHO -- clientes com eco local automatico duplicam
// visualmente cada tecla digitada.
//
// Este cliente nao faz eco local nenhum (terminal em modo raw via
// golang.org/x/term) e repassa os codigos ANSI que o proprio SIGAACD manda
// direto pro terminal real do usuario, sem traducao.
//
// Uso:
//
//	kubectl port-forward deployment/appserver-telnet 2323:23 -n protheus-devops &
//	go run . [host] [porta]      # default 127.0.0.1:2323
//
// Pra sair do CLIENTE (nao do SIGAACD): Ctrl+].
package main

import (
	"fmt"
	"io"
	"net"
	"os"

	"golang.org/x/term"
)

// Comandos e opcoes do protocolo telnet (RFC 854/855) que este cliente
// precisa reconhecer. O SIGAACD so pede TERMINAL-TYPE e SUPPRESS-GO-AHEAD na
// pratica; qualquer outra opcao e recusada.
const (
	iac  = 255
	dont = 254
	do   = 253
	wont = 252
	will = 251
	sb   = 250
	se   = 240

	optEcho = 1
	optSGA  = 3
	optTerm = 24
)

const ctrlCloseBracket = 0x1d // Ctrl+] -- sai do cliente, nao do SIGAACD

func main() {
	host, port := "127.0.0.1", "2323"
	if len(os.Args) > 1 {
		host = os.Args[1]
	}
	if len(os.Args) > 2 {
		port = os.Args[2]
	}

	conn, err := net.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "erro ao conectar em %s:%s: %v\n", host, port, err)
		os.Exit(1)
	}
	defer conn.Close()

	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "erro ao colocar o terminal em modo raw: %v\n", err)
		os.Exit(1)
	}
	defer term.Restore(fd, oldState)

	os.Stdout.WriteString("\x1b[2J\x1b[H") // limpa a tela local

	// userQuit marca que a saida foi por Ctrl+] (voluntaria), pra
	// pumpServerToScreen nao imprimir "erro de leitura" quando o Close()
	// (chamado ao sair) derruba a leitura pendente do socket por baixo.
	userQuit := make(chan struct{})
	done := make(chan struct{})
	go pumpServerToScreen(conn, userQuit, done)
	pumpKeyboardToServer(conn, userQuit)
	<-done
}

// pumpServerToScreen le do socket, responde negociacao IAC e escreve os
// bytes de dados reais direto no stdout (o terminal do usuario desenha os
// codigos ANSI sozinho). Fecha `done` quando a conexao cai ou o usuario sai.
func pumpServerToScreen(conn net.Conn, userQuit <-chan struct{}, done chan<- struct{}) {
	defer close(done)
	n := negotiator{conn: conn}
	buf := make([]byte, 4096)
	for {
		nRead, err := conn.Read(buf)
		if nRead > 0 {
			os.Stdout.Write(n.strip(buf[:nRead]))
		}
		if err != nil {
			select {
			case <-userQuit:
				return // saida voluntaria: Close() derrubou a leitura, esperado
			default:
			}
			if err == io.EOF {
				os.Stdout.WriteString("\r\n[conexao encerrada pelo servidor]\r\n")
			} else {
				fmt.Fprintf(os.Stderr, "\r\n[erro de leitura: %v]\r\n", err)
			}
			return
		}
	}
}

// pumpKeyboardToServer le o teclado (stdin em modo raw, tecla a tecla) e
// manda cada byte direto pro socket, sem eco local nenhum. Ctrl+] encerra o
// cliente sem mandar nada ao servidor, fechando a conexao.
func pumpKeyboardToServer(conn net.Conn, userQuit chan<- struct{}) {
	buf := make([]byte, 16)
	for {
		nRead, err := os.Stdin.Read(buf)
		if err != nil {
			return
		}
		key := buf[:nRead]
		if len(key) == 1 && key[0] == ctrlCloseBracket {
			os.Stdout.WriteString("\r\n[saindo do cliente]\r\n")
			close(userQuit)
			conn.Close()
			return
		}
		if _, err := conn.Write(key); err != nil {
			return
		}
	}
}

// negotiator processa a negociacao IAC de uma sessao telnet, respondendo
// pelo socket conforme necessario, e separa os bytes de dados reais dos
// bytes de controle.
type negotiator struct {
	conn net.Conn
}

// strip consome bytes de negociacao IAC do buffer recebido, responde no
// socket o que for preciso, e devolve so os bytes de dados reais (texto/ANSI).
func (n *negotiator) strip(data []byte) []byte {
	out := make([]byte, 0, len(data))
	i, total := 0, len(data)
	for i < total {
		b := data[i]
		if b != iac {
			out = append(out, b)
			i++
			continue
		}
		if i+1 >= total {
			break
		}
		cmd := data[i+1]
		switch cmd {
		case do, dont, will, wont:
			i = n.handleOption(data, i, cmd)
		case sb:
			i = n.handleSubnegotiation(data, i)
		default:
			i += 2
		}
	}
	return out
}

// handleOption responde a um DO/DONT/WILL/WONT de opcao simples e devolve o
// indice logo apos essa negociacao no buffer original.
func (n *negotiator) handleOption(data []byte, i int, cmd byte) int {
	if i+2 >= len(data) {
		return len(data)
	}
	opt := data[i+2]
	switch cmd {
	case do:
		n.replyToDo(opt)
	case will:
		n.replyToWill(opt)
		// DONT/WONT recebidos nao exigem resposta deste cliente.
	}
	return i + 3
}

func (n *negotiator) replyToDo(opt byte) {
	switch opt {
	case optTerm:
		n.conn.Write([]byte{iac, will, optTerm})
	case optSGA:
		n.conn.Write([]byte{iac, will, optSGA})
	default:
		n.conn.Write([]byte{iac, wont, opt})
	}
}

func (n *negotiator) replyToWill(opt byte) {
	switch opt {
	case optEcho, optSGA:
		n.conn.Write([]byte{iac, do, opt})
	default:
		n.conn.Write([]byte{iac, dont, opt})
	}
}

// handleSubnegotiation trata IAC SB ... IAC SE. O unico caso relevante aqui
// e o pedido de TERMINAL-TYPE, respondido como VT100.
func (n *negotiator) handleSubnegotiation(data []byte, i int) int {
	j := i + 2
	for j+1 < len(data) && !(data[j] == iac && data[j+1] == se) {
		j++
	}
	sub := data[i+2 : min(j, len(data))]
	if len(sub) > 1 && sub[0] == optTerm && sub[1] == 1 {
		resp := append([]byte{iac, sb, optTerm, 0}, []byte("VT100")...)
		resp = append(resp, iac, se)
		n.conn.Write(resp)
	}
	return j + 2
}
