// SPDX-License-Identifier: GPL-3.0-or-later
package dynamic

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	proxyHTTP "github.com/sagernet/sing-box/protocol/http"
	"github.com/sagernet/sing-box/protocol/socks"
	M "github.com/sagernet/sing/common/metadata"
)

const Type = "domainproxy"

type Endpoint struct {
	Type     string `json:"type"`
	Server   string `json:"server"`
	Port     uint16 `json:"server_port"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
}

func (e Endpoint) validate() error {
	if e.Type != "http" && e.Type != "socks5" {
		return errors.New("type must be http or socks5")
	}
	ip, err := netip.ParseAddr(e.Server)
	if err != nil || !ip.Is4() || ip.IsUnspecified() || ip.As4()[0] >= 224 || (ip.IsLoopback() && e.Port == 9099) {
		return errors.New("server must be a unicast IPv4 address and cannot point to the control API")
	}
	if e.Port == 0 || len(e.Username) > 255 || len(e.Password) > 255 {
		return errors.New("invalid port or credentials longer than 255 bytes")
	}
	if e.Username == "" && e.Password != "" {
		return errors.New("password requires username")
	}
	if strings.ContainsAny(e.Username+e.Password, "\r\n\x00") {
		return errors.New("credentials contain control characters")
	}
	return nil
}

type Options struct {
	option.DialerOptions
	option.ServerOptions
	UpstreamType string `json:"upstream_type"`
	Username     string `json:"username,omitempty"`
	Password     string `json:"password,omitempty"`
	APIListen    string `json:"api_listen"`
	APISecret    string `json:"api_secret"`
	StatePath    string `json:"state_path,omitempty"`
}

func RegisterOutbound(registry *outbound.Registry) {
	outbound.Register[Options](registry, Type, NewOutbound)
}

type Outbound struct {
	outbound.Adapter
	mu          sync.Mutex
	endpoint    Endpoint
	current     adapter.Outbound
	generation  uint64
	connections map[*trackedConn]struct{}
	closed      bool
	options     Options
	build       func(Endpoint) (adapter.Outbound, error)
	server      *http.Server
}

func NewOutbound(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options Options) (adapter.Outbound, error) {
	initial := Endpoint{Type: options.UpstreamType, Server: options.Server, Port: options.ServerPort, Username: options.Username, Password: options.Password}
	if err := initial.validate(); err != nil {
		return nil, err
	}
	address, err := netip.ParseAddrPort(options.APIListen)
	if err != nil || !address.Addr().Is4() || address.Port() == 0 || len(options.APISecret) < 32 {
		return nil, errors.New("invalid API listen address or API secret shorter than 32 bytes")
	}
	o := &Outbound{
		Adapter: outbound.NewAdapterWithDialerOptions(Type, tag, []string{"tcp"}, options.DialerOptions),
		options: options, endpoint: initial, connections: make(map[*trackedConn]struct{}),
	}
	o.build = func(e Endpoint) (adapter.Outbound, error) {
		server := option.ServerOptions{Server: e.Server, ServerPort: e.Port}
		if e.Type == "http" {
			return proxyHTTP.NewOutbound(ctx, router, logger, tag, option.HTTPOutboundOptions{
				DialerOptions: options.DialerOptions, ServerOptions: server, Username: e.Username, Password: e.Password,
			})
		}
		return socks.NewOutbound(ctx, router, logger, tag, option.SOCKSOutboundOptions{
			DialerOptions: options.DialerOptions, ServerOptions: server, Version: "5", Username: e.Username, Password: e.Password,
		})
	}
	o.current, err = o.build(initial)
	if err != nil {
		return nil, err
	}
	return o, nil
}

func (o *Outbound) Start(stage adapter.StartStage) error {
	if stage != adapter.StartStateStarted {
		return nil
	}
	listener, err := net.Listen("tcp4", o.options.APIListen)
	if err != nil {
		return fmt.Errorf("control API listen: %w", err)
	}
	if err = o.persist(o.endpoint); err != nil {
		listener.Close()
		return err
	}
	o.server = &http.Server{Handler: http.HandlerFunc(o.serveHTTP), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192}
	go o.server.Serve(listener)
	return nil
}

func (o *Outbound) persist(e Endpoint) error {
	if o.options.StatePath == "" {
		return nil
	}
	data, err := json.Marshal(e)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(o.options.StatePath), ".upstream-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, o.options.StatePath)
}

func (o *Outbound) switchTo(e Endpoint, closeExisting bool) (int, error) {
	if err := e.validate(); err != nil {
		return 0, err
	}
	next, err := o.build(e)
	if err != nil {
		return 0, errors.New("cannot create upstream outbound")
	}
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return 0, net.ErrClosed
	}
	if err = o.persist(e); err != nil {
		o.mu.Unlock()
		return 0, errors.New("cannot save upstream; previous upstream retained")
	}
	o.current, o.endpoint = next, e
	o.generation++
	var closing []*trackedConn
	if closeExisting {
		for conn := range o.connections {
			closing = append(closing, conn)
		}
	}
	o.mu.Unlock()
	for _, conn := range closing {
		conn.Close()
	}
	return len(closing), nil
}

type trackedConn struct {
	net.Conn
	owner *Outbound
}

func (c *trackedConn) Close() error {
	c.owner.mu.Lock()
	delete(c.owner.connections, c)
	c.owner.mu.Unlock()
	return c.Conn.Close()
}

func (o *Outbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if network != "tcp" && network != "tcp4" && network != "tcp6" {
		return nil, errors.New("dynamic upstream supports TCP only")
	}
	o.mu.Lock()
	current, generation, closed := o.current, o.generation, o.closed
	o.mu.Unlock()
	if closed {
		return nil, net.ErrClosed
	}
	conn, err := current.DialContext(ctx, network, destination)
	if err != nil {
		return nil, err
	}
	tracked := &trackedConn{Conn: conn, owner: o}
	o.mu.Lock()
	if o.closed || o.generation != generation {
		o.mu.Unlock()
		conn.Close()
		return nil, errors.New("upstream changed during connection setup; retry connection")
	}
	o.connections[tracked] = struct{}{}
	o.mu.Unlock()
	return tracked, nil
}

func (o *Outbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("UDP remains disabled for proxied domains")
}

func (o *Outbound) Close() error {
	o.mu.Lock()
	o.closed = true
	var closing []*trackedConn
	for conn := range o.connections {
		closing = append(closing, conn)
	}
	o.mu.Unlock()
	for _, conn := range closing {
		conn.Close()
	}
	if o.server != nil {
		return o.server.Close()
	}
	return nil
}

func reply(w http.ResponseWriter, code int, body any) {
	data, _ := json.Marshal(body)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(code)
	w.Write(data)
}

func (o *Outbound) serveHTTP(w http.ResponseWriter, r *http.Request) {
	expected := sha256.Sum256([]byte("Bearer " + o.options.APISecret))
	provided := sha256.Sum256([]byte(r.Header.Get("Authorization")))
	if subtle.ConstantTimeCompare(expected[:], provided[:]) != 1 {
		reply(w, http.StatusUnauthorized, map[string]any{"ok": false, "message": "Bearer token required"})
		return
	}
	if r.URL.Path != "/v1/proxy" {
		reply(w, http.StatusNotFound, map[string]any{"ok": false, "message": "use /v1/proxy"})
		return
	}
	if r.Method == http.MethodGet {
		o.mu.Lock()
		e := o.endpoint
		generation := o.generation
		o.mu.Unlock()
		reply(w, http.StatusOK, map[string]any{"ok": true, "type": e.Type, "server": e.Server,
			"server_port": e.Port, "username": e.Username, "password_set": e.Password != "", "generation": generation, "pid": os.Getpid()})
		return
	}
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		w.Header().Set("Allow", "GET, POST, PUT")
		reply(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "message": "use GET or POST"})
		return
	}
	var request struct {
		Endpoint
		CloseExisting *bool `json:"close_existing,omitempty"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		reply(w, http.StatusBadRequest, map[string]any{"ok": false, "message": "invalid JSON body or unknown fields"})
		return
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		reply(w, http.StatusBadRequest, map[string]any{"ok": false, "message": "expected one JSON object"})
		return
	}
	if err := request.Endpoint.validate(); err != nil {
		reply(w, http.StatusBadRequest, map[string]any{"ok": false, "message": err.Error()})
		return
	}
	closeExisting := request.CloseExisting == nil || *request.CloseExisting
	count, err := o.switchTo(request.Endpoint, closeExisting)
	if err != nil {
		reply(w, http.StatusInternalServerError, map[string]any{"ok": false, "message": err.Error()})
		return
	}
	reply(w, http.StatusOK, map[string]any{"ok": true, "pid": os.Getpid(), "closed_connections": count,
		"message": "Upstream switched without restarting tunnel; new connections use the new upstream. Reachability is not verified."})
}
