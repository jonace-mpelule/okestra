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

type fakeProjectDocker struct {
	fakeDocker
	network string
	volume  string
}

func (f *fakeProjectDocker) EnsureNetwork(_ context.Context, name string) error {
	f.network = name
	return nil
}
func (f *fakeProjectDocker) RemoveNetwork(_ context.Context, name string) error {
	f.network = "removed:" + name
	return nil
}
func (f *fakeProjectDocker) EnsureVolume(_ context.Context, name string) error {
	f.volume = name
	return nil
}
func (f *fakeProjectDocker) StartContainer(context.Context, string) error { return nil }
func (f *fakeProjectDocker) InspectContainer(_ context.Context, id string) (protocol.ContainerDetails, error) {
	return protocol.ContainerDetails{Name: id, Running: true, Health: "healthy"}, nil
}

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

func TestProjectResourcesRequireAuthAndSafeNames(t *testing.T) {
	docker := &fakeProjectDocker{}
	srv := NewServer("127.0.0.1:0", "test-token", t.TempDir(), docker)
	request := func(method, path, token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}
	if got := request(http.MethodPut, "/v1/projects/networks/okestra-demo", ""); got.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d", got.Code)
	}
	if got := request(http.MethodPut, "/v1/projects/networks/bridge", "test-token"); got.Code != http.StatusBadRequest {
		t.Fatalf("unsafe name status = %d", got.Code)
	}
	if got := request(http.MethodPut, "/v1/projects/networks/okestra-demo", "test-token"); got.Code != http.StatusNoContent || docker.network != "okestra-demo" {
		t.Fatalf("network status = %d, name = %s", got.Code, docker.network)
	}
	if got := request(http.MethodPut, "/v1/projects/volumes/okestra-demo-data", "test-token"); got.Code != http.StatusNoContent || docker.volume != "okestra-demo-data" {
		t.Fatalf("volume status = %d, name = %s", got.Code, docker.volume)
	}
	if got := request(http.MethodGet, "/v1/containers/okestra-demo-app/inspect", "test-token"); got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"health":"healthy"`) {
		t.Fatalf("inspect status = %d, body = %s", got.Code, got.Body.String())
	}
}

type nopReadWriteCloser struct {
	io.Reader
	io.Writer
}

func (nopReadWriteCloser) Close() error      { return nil }
func (nopReadWriteCloser) CloseInput() error { return nil }
