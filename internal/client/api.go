package client

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jonace-mpelule/okestra/internal/protocol"
)

type API struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

func NewAPI(profile protocol.AgentProfile) *API {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	if profile.InsecureSkipVerify {
		transport.TLSClientConfig.InsecureSkipVerify = true // Explicit opt-in for a self-signed private endpoint.
	}
	return &API{
		baseURL: strings.TrimRight(profile.URL, "/"),
		token:   profile.Token,
		httpClient: &http.Client{
			Transport: transport,
			Timeout:   0,
		},
	}
}

func (a *API) Health(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.baseURL+"/healthz", nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}

func (a *API) Status(ctx context.Context) (*protocol.ServiceStatus, error) {
	var out protocol.ServiceStatus
	if err := a.getJSON(ctx, "/v1/status", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (a *API) Build(ctx context.Context, req protocol.BuildRequest, tarData io.Reader) (string, error) {
	q := url.Values{}
	q.Set("tag", req.Tag)
	if req.Dockerfile != "" {
		q.Set("dockerfile", req.Dockerfile)
	}
	for key, value := range req.BuildArgs {
		q.Add("build-arg", key+"="+value)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+"/v1/build?"+q.Encode(), tarData)
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Content-Type", "application/x-tar")
	resp, err := a.do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return "", decodeAPIError(resp)
	}
	var accepted protocol.BuildAccepted
	if err := json.NewDecoder(resp.Body).Decode(&accepted); err != nil {
		return "", err
	}
	return accepted.OperationID, nil
}

func (a *API) StreamOperation(ctx context.Context, operationID string, fn func(protocol.StreamEnvelope) error) error {
	return a.readJSONStream(ctx, wsURL(a.baseURL, "/v1/operations/"+operationID+"/ws"), fn)
}

func (a *API) ListContainers(ctx context.Context) ([]protocol.ContainerSummary, error) {
	var out []protocol.ContainerSummary
	if err := a.getJSON(ctx, "/v1/containers", &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (a *API) RunContainer(ctx context.Context, req protocol.RunRequest) (*protocol.RunResult, error) {
	var out protocol.RunResult
	if err := a.postJSON(ctx, "/v1/containers/run", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (a *API) StreamLogs(ctx context.Context, containerID string, follow bool, fn func(protocol.StreamEnvelope) error) error {
	path := fmt.Sprintf("/v1/containers/%s/logs/ws?follow=%d", url.PathEscape(containerID), boolToInt(follow))
	return a.readJSONStream(ctx, wsURL(a.baseURL, path), fn)
}

func (a *API) CreateExec(ctx context.Context, containerID string, req protocol.ExecRequest) (string, error) {
	var out protocol.ExecCreated
	err := a.postJSON(ctx, "/v1/containers/"+url.PathEscape(containerID)+"/exec", req, &out)
	return out.ExecID, err
}

func (a *API) AttachExec(ctx context.Context, containerID, execID string, stdio *ExecIO) error {
	u := wsURL(a.baseURL, "/v1/containers/"+url.PathEscape(containerID)+"/exec/"+url.PathEscape(execID)+"/ws")
	header := http.Header{}
	if a.token != "" {
		header.Set("Authorization", "Bearer "+a.token)
	}
	conn, _, err := a.webSocketDialer().DialContext(ctx, u, header)
	if err != nil {
		return err
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go closeWebSocketOnCancel(ctx, conn, done)

	if stdio.Stdin != nil {
		go func() {
			buf := make([]byte, 32*1024)
			for {
				n, err := stdio.Stdin.Read(buf)
				if n > 0 {
					if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
						return
					}
				}
				if err != nil {
					if err == io.EOF {
						_ = conn.WriteMessage(websocket.TextMessage, []byte(protocol.ExecStdinClosedMarker))
					}
					return
				}
			}
		}()
	}
	for {
		msgType, data, err := conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			var closeErr *websocket.CloseError
			if errors.As(err, &closeErr) && closeErr.Code == protocol.ExecFailureCloseCode {
				return fmt.Errorf("remote exec: %s", closeErr.Text)
			}
			if err == io.EOF || websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				return nil
			}
			return err
		}
		if msgType == websocket.TextMessage || msgType == websocket.BinaryMessage {
			if _, err := stdio.Stdout.Write(data); err != nil {
				return err
			}
		}
	}
}

func (a *API) StopContainer(ctx context.Context, id string) error {
	_, err := a.emptyPost(ctx, "/v1/containers/"+url.PathEscape(id)+"/stop")
	return err
}

func (a *API) RemoveContainer(ctx context.Context, id string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, a.baseURL+"/v1/containers/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}

func (a *API) ListImages(ctx context.Context) ([]protocol.ImageSummary, error) {
	var out []protocol.ImageSummary
	if err := a.getJSON(ctx, "/v1/images", &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (a *API) RemoveImage(ctx context.Context, id string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, a.baseURL+"/v1/images?id="+url.QueryEscape(id), nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}

func (a *API) CreatePortForward(ctx context.Context, req protocol.PortForwardRequest) (string, error) {
	var out struct {
		ID string `json:"id"`
	}
	if err := a.postJSON(ctx, "/v1/port-forwards", req, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

func (a *API) DialPortForward(ctx context.Context, id string) (*websocket.Conn, error) {
	header := http.Header{}
	if a.token != "" {
		header.Set("Authorization", "Bearer "+a.token)
	}
	conn, _, err := a.webSocketDialer().DialContext(ctx, wsURL(a.baseURL, "/v1/port-forwards/"+id+"/ws"), header)
	return conn, err
}

func (a *API) DeletePortForward(ctx context.Context, id string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, a.baseURL+"/v1/port-forwards/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}

func (a *API) CreateSelfTestTunnel(ctx context.Context) (string, error) {
	var out struct {
		ID string `json:"id"`
	}
	if err := a.postJSON(ctx, "/v1/tunnels/self-test", struct{}{}, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

func (a *API) DialSelfTestTunnel(ctx context.Context, id string) (*websocket.Conn, error) {
	header := http.Header{}
	if a.token != "" {
		header.Set("Authorization", "Bearer "+a.token)
	}
	conn, _, err := a.webSocketDialer().DialContext(ctx, wsURL(a.baseURL, "/v1/tunnels/self-test/"+id+"/ws"), header)
	return conn, err
}

func (a *API) DeleteSelfTestTunnel(ctx context.Context, id string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, a.baseURL+"/v1/tunnels/self-test/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}

func CreateBuildContextTar(root string, dockerfile string) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeBuildContextTar(&buf, root, dockerfile); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func OpenBuildContext(root string, dockerfile string) (io.ReadCloser, error) {
	if err := validateBuildContext(root, dockerfile); err != nil {
		return nil, err
	}
	reader, writer := io.Pipe()
	go func() {
		writer.CloseWithError(writeBuildContextTar(writer, root, dockerfile))
	}()
	return reader, nil
}

func writeBuildContextTar(dst io.Writer, root string, dockerfile string) error {
	if err := validateBuildContext(root, dockerfile); err != nil {
		return err
	}
	ignore, err := LoadDockerignore(root)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}
	dockerfile = filepath.ToSlash(filepath.Clean(dockerfile))
	tw := tar.NewWriter(dst)

	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		relSlash := filepath.ToSlash(rel)
		mustInclude := relSlash == dockerfile || relSlash == ".dockerignore"
		if !mustInclude && ignore.ShouldIgnore(rel, info.IsDir()) {
			if info.IsDir() && ignore.CanSkipIgnoredDir() {
				return filepath.SkipDir
			}
			return nil
		}
		linkTarget := ""
		if info.Mode()&os.ModeSymlink != 0 {
			linkTarget, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}
		header, err := tar.FileInfoHeader(info, linkTarget)
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(rel)
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			if _, err := io.Copy(tw, f); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		_ = tw.Close()
		return err
	}
	return tw.Close()
}

func validateBuildContext(root string, dockerfile string) error {
	info, err := os.Stat(root)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("build context is not a directory: %s", root)
	}
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}
	clean := filepath.Clean(dockerfile)
	if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return errors.New("dockerfile must be inside the build context")
	}
	dfInfo, err := os.Stat(filepath.Join(root, clean))
	if err != nil {
		return fmt.Errorf("dockerfile: %w", err)
	}
	if !dfInfo.Mode().IsRegular() {
		return errors.New("dockerfile must be a regular file")
	}
	return nil
}

type ExecIO struct {
	Stdin  io.Reader
	Stdout io.Writer
}

func StartPortForward(ctx context.Context, api *API, req protocol.PortForwardRequest) error {
	listeners, err := listenLoopbackPort(req.LocalPort)
	if err != nil {
		return err
	}
	forward, err := OpenPortForward(ctx, api, req, listeners...)
	if err != nil {
		closeListeners(listeners)
		return err
	}
	defer forward.Close()
	return forward.Serve(ctx)
}

type PortForward struct {
	api       *API
	id        string
	listeners []net.Listener
	once      sync.Once
}

func OpenPortForward(ctx context.Context, api *API, req protocol.PortForwardRequest, listeners ...net.Listener) (*PortForward, error) {
	if err := req.Validate(); err != nil {
		return nil, err
	}
	if len(listeners) == 0 {
		return nil, errors.New("at least one local listener is required")
	}
	id, err := api.CreatePortForward(ctx, req)
	if err != nil {
		return nil, err
	}
	return &PortForward{api: api, id: id, listeners: listeners}, nil
}

func (f *PortForward) Close() {
	f.once.Do(func() {
		closeListeners(f.listeners)
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = f.api.DeletePortForward(cleanupCtx, f.id)
	})
}

func (f *PortForward) Serve(ctx context.Context) error {
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			closeListeners(f.listeners)
		case <-done:
		}
	}()
	errors := make(chan error, len(f.listeners))
	for _, listener := range f.listeners {
		go func(listener net.Listener) {
			for {
				conn, err := listener.Accept()
				if err != nil {
					if ctx.Err() != nil {
						errors <- nil
					} else {
						errors <- err
					}
					return
				}
				go handleForwardConn(ctx, f.api, f.id, conn)
			}
		}(listener)
	}
	err := <-errors
	closeListeners(f.listeners)
	return err
}

func listenLoopbackPort(port int) ([]net.Listener, error) {
	address4 := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	listener4, err := net.Listen("tcp4", address4)
	if err != nil {
		return nil, fmt.Errorf("IPv4 localhost %s: %w", address4, err)
	}
	address6 := net.JoinHostPort("::1", strconv.Itoa(port))
	listener6, err := net.Listen("tcp6", address6)
	if err != nil {
		if errors.Is(err, syscall.EAFNOSUPPORT) || errors.Is(err, syscall.EPROTONOSUPPORT) || errors.Is(err, syscall.EADDRNOTAVAIL) {
			return []net.Listener{listener4}, nil
		}
		_ = listener4.Close()
		return nil, fmt.Errorf("IPv6 localhost %s: %w", address6, err)
	}
	return []net.Listener{listener4, listener6}, nil
}

func closeListeners(listeners []net.Listener) {
	for _, listener := range listeners {
		_ = listener.Close()
	}
}

func handleForwardConn(ctx context.Context, api *API, id string, conn net.Conn) {
	defer conn.Close()
	ws, err := api.DialPortForward(ctx, id)
	if err != nil {
		return
	}
	defer ws.Close()
	bridgeConnToWebsocket(conn, ws)
}

func bridgeConnToWebsocket(conn net.Conn, ws *websocket.Conn) {
	errCh := make(chan error, 2)
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
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
	}()
	go func() {
		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				errCh <- err
				return
			}
			if _, err := conn.Write(data); err != nil {
				errCh <- err
				return
			}
		}
	}()
	<-errCh
}

func VerifySelfTestTunnel(ctx context.Context, api *API) error {
	id, err := api.CreateSelfTestTunnel(ctx)
	if err != nil {
		return err
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = api.DeleteSelfTestTunnel(cleanupCtx, id)
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ln.Close()

	go func() {
		accepted, err := ln.Accept()
		if err != nil {
			return
		}
		defer accepted.Close()
		ws, err := api.DialSelfTestTunnel(ctx, id)
		if err != nil {
			return
		}
		defer ws.Close()
		bridgeConnToWebsocket(accepted, ws)
	}()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		return err
	}
	defer conn.Close()
	payload := []byte("okestra-self-test")
	if _, err := conn.Write(payload); err != nil {
		return err
	}
	buf := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, buf); err != nil {
		return err
	}
	if !bytes.Equal(buf, payload) {
		return fmt.Errorf("tunnel echo mismatch")
	}
	return nil
}

func (a *API) do(req *http.Request) (*http.Response, error) {
	if a.token != "" {
		req.Header.Set("Authorization", "Bearer "+a.token)
	}
	return a.httpClient.Do(req)
}

func (a *API) getJSON(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.baseURL+path, nil)
	if err != nil {
		return err
	}
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (a *API) postJSON(ctx context.Context, path string, body any, out any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (a *API) emptyPost(ctx context.Context, path string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := a.do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		defer resp.Body.Close()
		return nil, decodeAPIError(resp)
	}
	return resp, nil
}

func (a *API) readJSONStream(ctx context.Context, wsURL string, fn func(protocol.StreamEnvelope) error) error {
	header := http.Header{}
	if a.token != "" {
		header.Set("Authorization", "Bearer "+a.token)
	}
	conn, _, err := a.webSocketDialer().DialContext(ctx, wsURL, header)
	if err != nil {
		return err
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go closeWebSocketOnCancel(ctx, conn, done)
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		var env protocol.StreamEnvelope
		if err := json.Unmarshal(data, &env); err != nil {
			var apiErr protocol.APIError
			if jerr := json.Unmarshal(data, &apiErr); jerr == nil && apiErr.Code != "" {
				return fmt.Errorf("%s: %s", apiErr.Code, apiErr.Message)
			}
			return err
		}
		if err := fn(env); err != nil {
			return err
		}
		if env.Type == "eof" {
			return nil
		}
	}
}

func closeWebSocketOnCancel(ctx context.Context, conn *websocket.Conn, done <-chan struct{}) {
	select {
	case <-ctx.Done():
		_ = conn.Close()
	case <-done:
	}
}

func (a *API) webSocketDialer() *websocket.Dialer {
	dialer := *websocket.DefaultDialer
	if transport, ok := a.httpClient.Transport.(*http.Transport); ok && transport.TLSClientConfig != nil {
		dialer.TLSClientConfig = transport.TLSClientConfig.Clone()
	}
	return &dialer
}

func wsURL(base, path string) string {
	u, _ := url.Parse(base)
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	default:
		u.Scheme = "ws"
	}
	u.Path, u.RawQuery, _ = strings.Cut(path, "?")
	return u.String()
}

func decodeAPIError(resp *http.Response) error {
	var apiErr protocol.APIError
	if err := json.NewDecoder(resp.Body).Decode(&apiErr); err == nil && apiErr.Code != "" {
		return fmt.Errorf("%s: %s", apiErr.Code, apiErr.Message)
	}
	return fmt.Errorf("unexpected status %d", resp.StatusCode)
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
