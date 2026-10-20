// SPDX-License-Identifier: GPL-3.0-or-later
package dynamic

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	proxyHTTP "github.com/sagernet/sing-box/protocol/http"
	"github.com/sagernet/sing-box/protocol/socks"
	M "github.com/sagernet/sing/common/metadata"
)

const token = "0123456789abcdef0123456789abcdef"

type echoOutbound struct {
	outbound.Adapter
	id string
}

func (e *echoOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		server.Write([]byte(e.id))
		io.Copy(server, server)
	}()
	return client, nil
}

func (e *echoOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, net.ErrClosed
}

func testOutbound(t *testing.T) *Outbound {
	t.Helper()
	o := &Outbound{endpoint: Endpoint{Type: "http", Server: "192.0.2.1", Port: 8080},
		options:     Options{APISecret: token, StatePath: filepath.Join(t.TempDir(), "upstream.json")},
		connections: make(map[*trackedConn]struct{})}
	o.build = func(e Endpoint) (adapter.Outbound, error) { return &echoOutbound{id: e.Type}, nil }
	o.current, _ = o.build(o.endpoint)
	t.Cleanup(func() { o.Close() })
	return o
}

func request(o *Outbound, method, authorization, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "/v1/proxy", strings.NewReader(body))
	r.Header.Set("Authorization", authorization)
	w := httptest.NewRecorder()
	o.serveHTTP(w, r)
	return w
}

func dialID(t *testing.T, o *Outbound, expected string) net.Conn {
	t.Helper()
	c, err := o.DialContext(context.Background(), "tcp", M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, len(expected))
	if _, err = io.ReadFull(c, buf); err != nil || string(buf) != expected {
		t.Fatalf("dial reached %q, expected %q: %v", buf, expected, err)
	}
	return c
}

func TestSwitchClosesOldConnectionsAndPersists(t *testing.T) {
	o := testOutbound(t)
	old := dialID(t, o, "http")
	beforePID := os.Getpid()
	w := request(o, "POST", "Bearer "+token, `{"type":"socks5","ip":"198.51.100.2","port":1080,"username":"alice","password":"secret"}`)
	if w.Code != http.StatusOK {
		t.Fatal(w.Code, w.Body.String())
	}
	var result map[string]any
	json.Unmarshal(w.Body.Bytes(), &result)
	if int(result["pid"].(float64)) != beforePID || result["closed_connections"] != float64(1) {
		t.Fatal(result)
	}
	if _, err := old.Read(make([]byte, 1)); err == nil {
		t.Fatal("old upstream connection stayed open")
	}
	dialID(t, o, "socks5").Close()
	data, err := os.ReadFile(o.options.StatePath)
	if err != nil {
		t.Fatal(err)
	}
	var saved Endpoint
	if json.Unmarshal(data, &saved) != nil || saved.Type != "socks5" || saved.Username != "alice" || saved.Password != "secret" {
		t.Fatal(string(data))
	}
	info, _ := os.Stat(o.options.StatePath)
	if info.Mode().Perm()&0077 != 0 && os.Getenv("OS") != "Windows_NT" {
		t.Fatal("upstream credentials not private")
	}
	status := request(o, "GET", "Bearer "+token, "")
	if strings.Contains(status.Body.String(), "secret") || strings.Contains(status.Body.String(), token) {
		t.Fatal("status leaked secret")
	}
}

func TestPreserveExistingConnections(t *testing.T) {
	o := testOutbound(t)
	old := dialID(t, o, "http")
	w := request(o, "POST", "Bearer "+token, `{"type":"socks5","ip":"198.51.100.3","port":1080,"close_existing":false}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	go old.Write([]byte("x"))
	buf := make([]byte, 1)
	if _, err := io.ReadFull(old, buf); err != nil || string(buf) != "x" {
		t.Fatal("existing connection not preserved", err)
	}
	dialID(t, o, "socks5").Close()
	old.Close()
}

func TestRejectedRequestsLeaveCurrentProxyUntouched(t *testing.T) {
	o := testOutbound(t)
	tests := []struct {
		auth, body string
		code       int
	}{
		{"", `{"type":"http","ip":"192.0.2.3","port":80}`, 401},
		{"Bearer wrong", `{}`, 401},
		{"Bearer " + token, `{"type":"direct","ip":"192.0.2.3","port":80}`, 400},
		{"Bearer " + token, `{"type":"http","ip":"127.0.0.1","port":9099}`, 400},
		{"Bearer " + token, `{"type":"http","ip":"192.0.2.3","port":65536}`, 400},
		{"Bearer " + token, `{"type":"http","ip":"192.0.2.3","port":80,"unknown":true}`, 400},
		{"Bearer " + token, `{"type":"http","ip":"192.0.2.3","port":80} {}`, 400},
		{"Bearer " + token, strings.Repeat(" ", 9000), 400},
	}
	for _, test := range tests {
		w := request(o, "POST", test.auth, test.body)
		if w.Code != test.code {
			t.Fatalf("code=%d expected=%d body=%s", w.Code, test.code, w.Body.String())
		}
		if o.endpoint.Server != "192.0.2.1" || o.generation != 0 {
			t.Fatal("rejected request changed upstream")
		}
	}
	// A persistence failure must also preserve the old live outbound.
	o.options.StatePath = filepath.Join(t.TempDir(), "missing", "upstream.json")
	w := request(o, "POST", "Bearer "+token, `{"type":"socks5","ip":"192.0.2.4","port":1080}`)
	if w.Code != 500 || o.generation != 0 {
		t.Fatal(w.Code, o.generation)
	}
	dialID(t, o, "http").Close()
}

func TestConcurrentSwitchAndStatus(t *testing.T) {
	o := testOutbound(t)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				request(o, "GET", "Bearer "+token, "")
				w := request(o, "POST", "Bearer "+token, `{"type":"socks5","ip":"192.0.2.5","port":1080}`)
				if w.Code != 200 {
					t.Error(w.Code)
				}
			}
		}()
	}
	wg.Wait()
	if o.generation != 120 {
		t.Fatal(o.generation)
	}
}

func TestRealHTTPAndSOCKSFactory(t *testing.T) {
	base, err := NewOutbound(context.Background(), nil, log.NewNOPFactory().Logger(), "proxy", Options{
		ServerOptions: option.ServerOptions{Server: "192.0.2.1", ServerPort: 8080},
		UpstreamType:  "http", APIListen: "127.0.0.1:9099", APISecret: token,
	})
	if err != nil {
		t.Fatal(err)
	}
	o := base.(*Outbound)
	defer o.Close()
	if _, ok := o.current.(*proxyHTTP.Outbound); !ok {
		t.Fatal("HTTP factory not used")
	}
	if _, err := o.switchTo(Endpoint{Type: "socks5", Server: "192.0.2.2", Port: 1080, Username: "u", Password: "p"}, true); err != nil {
		t.Fatal(err)
	}
	if _, ok := o.current.(*socks.Outbound); !ok {
		t.Fatal("SOCKS factory not used")
	}
}

func TestHTTPToSOCKS5WithRealAuthentication(t *testing.T) {
	// Both upstreams and all echoed traffic stay on loopback; no external API is contacted.
	httpProxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		want := "Basic " + base64.StdEncoding.EncodeToString([]byte("alice:secret"))
		if r.Method != "CONNECT" || r.Header.Get("Proxy-Authorization") != want {
			w.WriteHeader(407)
			return
		}
		c, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer c.Close()
		rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		rw.Flush()
		io.Copy(c, rw)
	}))
	defer httpProxy.Close()
	host, portText, _ := net.SplitHostPort(strings.TrimPrefix(httpProxy.URL, "http://"))
	port, _ := strconv.Atoi(portText)
	base, err := NewOutbound(context.Background(), nil, log.NewNOPFactory().Logger(), "proxy", Options{
		ServerOptions: option.ServerOptions{Server: host, ServerPort: uint16(port)},
		UpstreamType:  "http", Username: "alice", Password: "secret", APIListen: "127.0.0.1:9099", APISecret: token,
	})
	if err != nil {
		t.Fatal(err)
	}
	o := base.(*Outbound)
	defer o.Close()
	dialEcho := func() net.Conn {
		c, err := o.DialContext(context.Background(), "tcp", M.ParseSocksaddr("target.example:443"))
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err = c.Write([]byte("hello")); err != nil {
			t.Fatal(err)
		}
		b := make([]byte, 5)
		if _, err = io.ReadFull(c, b); err != nil || string(b) != "hello" {
			t.Fatal("proxy echo", string(b), err)
		}
		return c
	}
	old := dialEcho()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		c, err := listener.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(3 * time.Second))
		header := make([]byte, 2)
		if _, err = io.ReadFull(c, header); err != nil || header[0] != 5 {
			return
		}
		methods := make([]byte, int(header[1]))
		if _, err = io.ReadFull(c, methods); err != nil {
			return
		}
		c.Write([]byte{5, 2})
		if _, err = io.ReadFull(c, header); err != nil || header[0] != 1 {
			return
		}
		user := make([]byte, int(header[1]))
		if _, err = io.ReadFull(c, user); err != nil {
			return
		}
		length := make([]byte, 1)
		if _, err = io.ReadFull(c, length); err != nil {
			return
		}
		password := make([]byte, int(length[0]))
		if _, err = io.ReadFull(c, password); err != nil || string(user) != "alice" || string(password) != "secret" {
			return
		}
		c.Write([]byte{1, 0})
		connect := make([]byte, 4)
		if _, err = io.ReadFull(c, connect); err != nil || connect[0] != 5 || connect[1] != 1 || connect[3] != 3 {
			return
		}
		if _, err = io.ReadFull(c, length); err != nil {
			return
		}
		destination := make([]byte, int(length[0])+2)
		if _, err = io.ReadFull(c, destination); err != nil {
			return
		}
		c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
		io.Copy(c, c)
	}()
	body, _ := json.Marshal(Endpoint{Type: "socks5", Server: "127.0.0.1", Port: uint16(listener.Addr().(*net.TCPAddr).Port), Username: "alice", Password: "secret"})
	w := request(o, "POST", "Bearer "+token, string(body))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if _, err = old.Read(make([]byte, 1)); err == nil {
		t.Fatal("old real HTTP connection was not closed")
	}
	dialEcho().Close()
}
