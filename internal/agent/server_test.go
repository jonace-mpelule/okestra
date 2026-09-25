package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

type fakeDocker struct{}

func (fakeDocker) Ping(ctx context.Context) error { return nil }
func (fakeDocker) BuildImage(ctx context.Context, buildContext io.Reader, req protocol.BuildRequest) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader("{\"stream\":\"ok\"}\n")), nil
}
func (fakeDocker) RunContainer(ctx context.Context, req protocol.RunRequest) (string, error) {
	return "abc123", nil
}
func (fakeDocker) ListContainers(ctx context.Context) ([]protocol.ContainerSummary, error) {
	return []protocol.ContainerSummary{{ID: "abc123", Image: "nginx", Status: "Up", Name: "web"}}, nil
}
func (fakeDocker) StopContainer(ctx context.Context, containerID string) error {
	return nil
}
func (fakeDocker) RemoveContainer(ctx context.Context, containerID string) error {
	return nil
}
func (fakeDocker) ContainerLogs(ctx context.Context, containerID string, follow bool) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader("")), nil
}
func (fakeDocker) ExecStart(ctx context.Context, id string, req protocol.ExecRequest) (ExecStream, error) {
	return nopReadWriteCloser{Reader: strings.NewReader(""), Writer: io.Discard}, nil
}
func (fakeDocker) ResolveContainerPort(ctx context.Context, containerID string, port int) (string, error) {
	return "127.0.0.1:8080", nil
}
func (fakeDocker) ListImages(ctx context.Context) ([]protocol.ImageSummary, error) {
	return []protocol.ImageSummary{{ID: "img1", Tags: []string{"nginx:latest"}, Size: 10}}, nil
}
func (fakeDocker) RemoveImage(context.Context, string) error { return nil }

func TestAuthMiddleware(t *testing.T) {
	srv := NewServer("127.0.0.1:0", "secret", t.TempDir(), fakeDocker{})
	handler := srv.auth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"ok": "yes"})
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/containers", nil)
	rec := httptest.NewRecorder()
	handler(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", rec.Code)
	}
}

func TestRunHandler(t *testing.T) {
	srv := NewServer("127.0.0.1:0", "", t.TempDir(), fakeDocker{})
	body, _ := json.Marshal(protocol.RunRequest{Image: "nginx"})
	req := httptest.NewRequest(http.MethodPost, "/v1/containers/run", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	srv.handleRun(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestStatusHandler(t *testing.T) {
	srv := NewServer("127.0.0.1:0", "", t.TempDir(), fakeDocker{})
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rec := httptest.NewRecorder()
	srv.handleStatus(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var status protocol.ServiceStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("unmarshal status: %v", err)
	}
	if !status.ServiceHealthy || !status.DockerHealthy {
		t.Fatalf("unexpected status: %+v", status)
	}
}

type nopReadWriteCloser struct {
	io.Reader
	io.Writer
}

func (nopReadWriteCloser) Close() error      { return nil }
func (nopReadWriteCloser) CloseInput() error { return nil }
