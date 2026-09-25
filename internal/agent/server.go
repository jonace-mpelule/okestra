package agent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jonace-mpelule/okestra/internal/protocol"
	"github.com/jonace-mpelule/okestra/internal/version"
)

type Server struct {
	addr      string
	token     string
	workDir   string
	docker    Runtime
	version   string
	ops       *OperationBroker
	upgrader  websocket.Upgrader
	execMu    sync.RWMutex
	execReqs  map[string]execSession
	forwardMu sync.RWMutex
	forwards  map[string]tunnelSession
}

type execSession struct {
	ContainerID string
	Request     protocol.ExecRequest
}

type tunnelSession struct {
	Kind      string
	Target    string
	Request   protocol.PortForwardRequest
	CreatedAt time.Time
}

func NewServer(addr, token, workDir string, docker Runtime) *Server {
	return &Server{
		addr:    addr,
		token:   token,
		workDir: workDir,
		docker:  docker,
		version: version.Version,
		ops:     NewOperationBroker(),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				origin := r.Header.Get("Origin")
				if origin == "" {
					return true
				}
				u, err := url.Parse(origin)
				return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host == r.Host
			},
		},
		execReqs: make(map[string]execSession),
		forwards: make(map[string]tunnelSession),
	}
}

func (s *Server) ListenAndServe(ctx context.Context) error {
	if err := os.MkdirAll(s.workDir, 0o755); err != nil {
		return err
	}
	if err := s.cleanupStaleBuildContexts(); err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              s.addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("okestra-service listening on %s", s.addr)
	err := srv.ListenAndServe()
	if err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleReady)
	mux.HandleFunc("/v1/status", s.auth(s.handleStatus))
	mux.HandleFunc("/v1/build", s.auth(s.handleBuild))
	mux.HandleFunc("/v1/tunnels", s.auth(s.handleListTunnels))
	mux.HandleFunc("/v1/tunnels/self-test", s.auth(s.handleCreateSelfTestTunnel))
	mux.HandleFunc("/v1/tunnels/self-test/", s.auth(s.handleSelfTestTunnelStream))
	mux.HandleFunc("/v1/operations/", s.auth(s.handleOperationStream))
	mux.HandleFunc("/v1/containers", s.auth(s.handleContainers))
	mux.HandleFunc("/v1/containers/run", s.auth(s.handleRun))
	mux.HandleFunc("/v1/containers/", s.auth(s.handleContainerRoutes))
	mux.HandleFunc("/v1/images", s.auth(s.handleImages))
	mux.HandleFunc("/v1/images/", s.auth(s.handleImageRoutes))
	mux.HandleFunc("/v1/port-forwards", s.auth(s.handleCreatePortForward))
	mux.HandleFunc("/v1/port-forwards/", s.auth(s.handlePortForwardStream))

	return loggingMiddleware(mux)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.docker.Ping(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "docker_unavailable", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	status := protocol.ServiceStatus{
		ServiceHealthy:   true,
		DockerHealthy:    true,
		Version:          s.version,
		ProtocolVersion:  protocol.ProtocolVersion,
		ActiveOperations: s.ops.Snapshot(),
		ActiveTunnels:    s.snapshotTunnels(),
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.docker.Ping(ctx); err != nil {
		status.DockerHealthy = false
	}
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleBuild(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	req := protocol.BuildRequest{
		Tag:        r.URL.Query().Get("tag"),
		Dockerfile: r.URL.Query().Get("dockerfile"),
		BuildArgs:  make(map[string]string),
	}
	for _, raw := range r.URL.Query()["build-arg"] {
		key, value, ok := strings.Cut(raw, "=")
		if !ok || strings.TrimSpace(key) == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "build-arg must use KEY=VALUE")
			return
		}
		req.BuildArgs[key] = value
	}
	if err := req.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	body := http.MaxBytesReader(w, r.Body, 1<<30)
	defer body.Close()

	tmpFile := filepath.Join(s.workDir, fmt.Sprintf("%s-context.tar", newID()))
	f, err := os.OpenFile(tmpFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "workspace_error", err.Error())
		return
	}
	if _, err := io.Copy(f, body); err != nil {
		f.Close()
		_ = os.Remove(tmpFile)
		writeError(w, http.StatusBadRequest, "context_upload_failed", err.Error())
		return
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmpFile)
		writeError(w, http.StatusInternalServerError, "workspace_error", err.Error())
		return
	}

	opID := newID()
	s.ops.Start(opID, "build")
	go s.runBuild(opID, tmpFile, req)
	writeJSON(w, http.StatusAccepted, protocol.BuildAccepted{OperationID: opID})
}

func (s *Server) cleanupStaleBuildContexts() error {
	matches, err := filepath.Glob(filepath.Join(s.workDir, "*-context.tar"))
	if err != nil {
		return err
	}
	for _, path := range matches {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func (s *Server) runBuild(opID, contextPath string, req protocol.BuildRequest) {
	defer os.Remove(contextPath)
	file, err := os.Open(contextPath)
	if err != nil {
		s.failOp(opID, err)
		return
	}
	defer file.Close()
	stream, err := s.docker.BuildImage(context.Background(), file, req)
	if err != nil {
		s.failOp(opID, err)
		return
	}
	defer stream.Close()
	buf := make([]byte, 32*1024)
	for {
		n, err := stream.Read(buf)
		if n > 0 {
			s.ops.Publish(opID, protocol.StreamEnvelope{
				OperationID: opID,
				Stream:      "build",
				Type:        "chunk",
				Data:        append([]byte(nil), buf[:n]...),
				Timestamp:   time.Now().UTC(),
			})
		}
		if err == io.EOF {
			s.ops.Update(opID, "completed", "")
			s.ops.Publish(opID, protocol.StreamEnvelope{
				OperationID: opID,
				Stream:      "build",
				Type:        "eof",
				Timestamp:   time.Now().UTC(),
			})
			return
		}
		if err != nil {
			s.failOp(opID, err)
			return
		}
	}
}

func (s *Server) handleOperationStream(w http.ResponseWriter, r *http.Request) {
	if !strings.HasSuffix(r.URL.Path, "/ws") {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/operations/"), "/ws")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "operation id is required")
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	ch, cancel := s.ops.Subscribe(id)
	defer cancel()
	for msg := range ch {
		if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			return
		}
	}
}

func (s *Server) handleContainers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	items, err := s.docker.ListContainers(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) handleRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	var req protocol.RunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	id, err := s.docker.RunContainer(r.Context(), req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, protocol.RunResult{ContainerID: id, Forwards: req.AutoForward})
}

func (s *Server) handleContainerRoutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/containers/")
	switch {
	case strings.HasSuffix(path, "/stop"):
		s.handleStop(w, r, strings.TrimSuffix(path, "/stop"))
	case strings.HasSuffix(path, "/logs/ws"):
		s.handleLogsWS(w, r, strings.TrimSuffix(path, "/logs/ws"))
	case strings.HasSuffix(path, "/exec"):
		s.handleExecCreate(w, r, strings.TrimSuffix(path, "/exec"))
	case strings.Contains(path, "/exec/") && strings.HasSuffix(path, "/ws"):
		prefix := strings.TrimSuffix(path, "/ws")
		idx := strings.LastIndex(prefix, "/exec/")
		if idx < 0 {
			writeError(w, http.StatusNotFound, "not_found", "not found")
			return
		}
		containerID := prefix[:idx]
		execID := strings.TrimPrefix(prefix[idx:], "/exec/")
		s.handleExecWS(w, r, containerID, execID)
	case r.Method == http.MethodDelete:
		s.handleRemove(w, r, path)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (s *Server) handleStop(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if err := s.docker.StopContainer(r.Context(), id); err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (s *Server) handleRemove(w http.ResponseWriter, r *http.Request, id string) {
	if err := s.docker.RemoveContainer(r.Context(), id); err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleLogsWS(w http.ResponseWriter, r *http.Request, id string) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	reader, err := s.docker.ContainerLogs(r.Context(), id, r.URL.Query().Get("follow") == "1")
	if err != nil {
		writeWSError(conn, "docker_error", err.Error())
		return
	}
	defer reader.Close()

	wsWriter := &streamWriter{conn: conn, stream: "stdout"}
	if _, err := io.Copy(wsWriter, reader); err != nil {
		writeWSError(conn, "stream_error", err.Error())
		return
	}
	_ = conn.WriteJSON(protocol.StreamEnvelope{Stream: "logs", Type: "eof", Timestamp: time.Now().UTC()})
}

func (s *Server) handleExecCreate(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	var req protocol.ExecRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	execID := newID()
	s.execMu.Lock()
	s.execReqs[execID] = execSession{ContainerID: id, Request: req}
	s.execMu.Unlock()
	writeJSON(w, http.StatusCreated, protocol.ExecCreated{ExecID: execID})
}

func (s *Server) handleExecWS(w http.ResponseWriter, r *http.Request, containerID string, execID string) {
	s.execMu.Lock()
	session, ok := s.execReqs[execID]
	if ok && session.ContainerID == containerID {
		delete(s.execReqs, execID)
	} else {
		ok = false
	}
	s.execMu.Unlock()
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "exec request not found")
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	attach, err := s.docker.ExecStart(r.Context(), session.ContainerID, session.Request)
	if err != nil {
		closeExecWebSocket(conn, protocol.ExecFailureCloseCode, err.Error())
		return
	}
	defer attach.Close()
	if !session.Request.Stdin {
		_ = attach.CloseInput()
	}

	readDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := attach.Read(buf)
			if n > 0 {
				if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					readDone <- werr
					return
				}
			}
			if err != nil {
				readDone <- err
				return
			}
		}
	}()
	var inputDone <-chan error
	if session.Request.Stdin {
		ch := make(chan error, 1)
		inputDone = ch
		go func() {
			for {
				msgType, data, err := conn.ReadMessage()
				if err != nil {
					ch <- err
					return
				}
				if msgType == websocket.TextMessage && string(data) == protocol.ExecStdinClosedMarker {
					_ = attach.CloseInput()
					ch <- nil
					return
				}
				if msgType == websocket.BinaryMessage {
					if _, err := attach.Write(data); err != nil {
						ch <- nil
						return
					}
				}
			}
		}()
	}
	select {
	case err = <-readDone:
	case err = <-inputDone:
		if err == nil {
			err = <-readDone
		}
	}
	if err == nil || err == io.EOF {
		closeExecWebSocket(conn, websocket.CloseNormalClosure, "exec complete")
	} else {
		closeExecWebSocket(conn, protocol.ExecFailureCloseCode, err.Error())
	}
}

func closeExecWebSocket(conn *websocket.Conn, code int, reason string) {
	// WebSocket close reasons have a 123-byte UTF-8 payload limit.
	if len(reason) > 120 {
		reason = reason[:120]
	}
	_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(code, reason), time.Now().Add(time.Second))
}

func (s *Server) handleImages(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		id := r.URL.Query().Get("id")
		if strings.TrimSpace(id) == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "image id or name is required")
			return
		}
		if err := s.docker.RemoveImage(r.Context(), id); err != nil {
			writeError(w, http.StatusBadGateway, "docker_error", err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	items, err := s.docker.ListImages(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) handleImageRoutes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/images/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found", "image not found")
		return
	}
	if err := s.docker.RemoveImage(r.Context(), id); err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreatePortForward(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	var req protocol.PortForwardRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	id := newID()
	s.forwardMu.Lock()
	s.forwards[id] = tunnelSession{
		Kind:      "port-forward",
		Target:    fmt.Sprintf("%s:%d", req.ContainerID, req.RemotePort),
		Request:   req,
		CreatedAt: time.Now().UTC(),
	}
	s.forwardMu.Unlock()
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handlePortForwardStream(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		id := strings.TrimPrefix(r.URL.Path, "/v1/port-forwards/")
		if id == "" || strings.Contains(id, "/") {
			writeError(w, http.StatusNotFound, "not_found", "port forward not found")
			return
		}
		s.forwardMu.Lock()
		_, ok := s.forwards[id]
		delete(s.forwards, id)
		s.forwardMu.Unlock()
		if !ok {
			writeError(w, http.StatusNotFound, "not_found", "port forward not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !strings.HasSuffix(r.URL.Path, "/ws") {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/port-forwards/"), "/ws")
	s.forwardMu.RLock()
	session, ok := s.forwards[id]
	s.forwardMu.RUnlock()
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "port forward not found")
		return
	}
	addr, err := s.docker.ResolveContainerPort(r.Context(), session.Request.ContainerID, session.Request.RemotePort)
	if err != nil {
		writeError(w, http.StatusBadGateway, "docker_error", err.Error())
		return
	}
	tcpConn, err := net.Dial("tcp", addr)
	if err != nil {
		writeError(w, http.StatusBadGateway, "remote_port_unreachable", err.Error())
		return
	}
	defer tcpConn.Close()

	wsConn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer wsConn.Close()

	errCh := make(chan error, 2)
	go pumpNetToWS(wsConn, tcpConn, errCh)
	go pumpWSToNet(wsConn, tcpConn, errCh)
	<-errCh
}

func (s *Server) handleListTunnels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, s.snapshotTunnels())
}

func (s *Server) handleCreateSelfTestTunnel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	id := newID()
	s.forwardMu.Lock()
	s.forwards[id] = tunnelSession{
		Kind:      "self-test",
		Target:    "internal-echo",
		CreatedAt: time.Now().UTC(),
	}
	s.forwardMu.Unlock()
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleSelfTestTunnelStream(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		id := strings.TrimPrefix(r.URL.Path, "/v1/tunnels/self-test/")
		if id == "" || strings.Contains(id, "/") {
			writeError(w, http.StatusNotFound, "not_found", "tunnel not found")
			return
		}
		s.forwardMu.Lock()
		session, ok := s.forwards[id]
		if ok && session.Kind == "self-test" {
			delete(s.forwards, id)
		} else {
			ok = false
		}
		s.forwardMu.Unlock()
		if !ok {
			writeError(w, http.StatusNotFound, "not_found", "tunnel not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !strings.HasSuffix(r.URL.Path, "/ws") {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/tunnels/self-test/"), "/ws")
	s.forwardMu.RLock()
	_, ok := s.forwards[id]
	s.forwardMu.RUnlock()
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "tunnel not found")
		return
	}
	echoAddr, cleanup, err := startEchoServer()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "self_test_unavailable", err.Error())
		return
	}
	defer cleanup()
	tcpConn, err := net.Dial("tcp", echoAddr)
	if err != nil {
		writeError(w, http.StatusBadGateway, "self_test_unavailable", err.Error())
		return
	}
	defer tcpConn.Close()

	wsConn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer wsConn.Close()

	errCh := make(chan error, 2)
	go pumpNetToWS(wsConn, tcpConn, errCh)
	go pumpWSToNet(wsConn, tcpConn, errCh)
	<-errCh
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.token == "" {
			next(w, r)
			return
		}
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "auth_failed", "missing bearer token")
			return
		}
		tokenHash := sha256.Sum256([]byte(strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))))
		expectedHash := sha256.Sum256([]byte(s.token))
		if subtle.ConstantTimeCompare(tokenHash[:], expectedHash[:]) != 1 {
			writeError(w, http.StatusUnauthorized, "auth_failed", "invalid agent token")
			return
		}
		next(w, r)
	}
}

func (s *Server) failOp(id string, err error) {
	s.ops.Update(id, "failed", err.Error())
	s.ops.Publish(id, protocol.StreamEnvelope{
		OperationID: id,
		Stream:      "build",
		Type:        "error",
		Message:     err.Error(),
		Timestamp:   time.Now().UTC(),
	})
}

func (s *Server) snapshotTunnels() []protocol.TunnelSession {
	s.forwardMu.RLock()
	defer s.forwardMu.RUnlock()
	out := make([]protocol.TunnelSession, 0, len(s.forwards))
	for id, session := range s.forwards {
		out = append(out, protocol.TunnelSession{
			ID:        id,
			Kind:      session.Kind,
			Target:    session.Target,
			State:     "ready",
			CreatedAt: session.CreatedAt,
		})
	}
	return out
}

func newID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, protocol.APIError{Code: code, Message: msg})
}

func writeWSError(conn *websocket.Conn, code, msg string) {
	_ = conn.WriteJSON(protocol.APIError{Code: code, Message: msg})
}

type streamWriter struct {
	conn   *websocket.Conn
	stream string
}

func (w *streamWriter) Write(p []byte) (int, error) {
	err := w.conn.WriteJSON(protocol.StreamEnvelope{
		Stream:    w.stream,
		Type:      "chunk",
		Data:      append([]byte(nil), p...),
		Timestamp: time.Now().UTC(),
	})
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

func pumpNetToWS(ws *websocket.Conn, src net.Conn, errCh chan<- error) {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
				errCh <- werr
				return
			}
		}
		if err != nil {
			errCh <- err
			return
		}
	}
}

func pumpWSToNet(ws *websocket.Conn, dst net.Conn, errCh chan<- error) {
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			errCh <- err
			return
		}
		if _, err := dst.Write(data); err != nil {
			errCh <- err
			return
		}
	}
}

func startEchoServer() (string, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if _, werr := conn.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return ln.Addr().String(), func() { _ = ln.Close() }, nil
}
