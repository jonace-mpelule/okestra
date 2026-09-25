package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/jonace-mpelule/okestra/internal/protocol"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestProjectUpOrdersServicesOnPrivateNetwork(t *testing.T) {
	var ran []protocol.RunRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/status":
			_ = json.NewEncoder(w).Encode(protocol.ServiceStatus{ProtocolVersion: protocol.ProtocolVersion})
		case r.URL.Path == "/v1/containers":
			_ = json.NewEncoder(w).Encode([]protocol.ContainerSummary{})
		case r.URL.Path == "/v1/projects/networks/okestra-demo":
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/v1/containers/run":
			var req protocol.RunRequest
			_ = json.NewDecoder(r.Body).Decode(&req)
			ran = append(ran, req)
			_ = json.NewEncoder(w).Encode(protocol.RunResult{ContainerID: req.Name})
		case strings.HasSuffix(r.URL.Path, "/inspect"):
			_ = json.NewEncoder(w).Encode(protocol.ContainerDetails{Running: true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	file := filepath.Join(dir, "okestra.json")
	data := []byte(`{"name":"demo","services":{"db":{"image":"postgres:16-alpine"},"app":{"image":"nginx:alpine","depends_on":["db"]}}}`)
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{ActiveAgent: "test", Agents: map[string]protocol.AgentProfile{"test": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	if code := runProjectUp(context.Background(), cfg, []string{"-f", file}, &out, &errOut); code != 0 {
		t.Fatalf("up failed: %s", errOut.String())
	}
	if len(ran) != 2 || ran[0].NetworkAlias != "db" || ran[1].NetworkAlias != "app" || ran[1].Network != "okestra-demo" {
		t.Fatalf("run order/requests: %#v", ran)
	}
}

func TestProjectUpChecksLocalPortBeforeRemoteMutation(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	mutations := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			mutations++
		}
		if r.URL.Path == "/v1/status" {
			_ = json.NewEncoder(w).Encode(protocol.ServiceStatus{ProtocolVersion: protocol.ProtocolVersion})
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	file := filepath.Join(dir, "okestra.json")
	data := []byte(fmt.Sprintf(`{"name":"demo","services":{"app":{"image":"nginx:alpine","ports":["%d:80"]}}}`, port))
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{ActiveAgent: "test", Agents: map[string]protocol.AgentProfile{"test": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	if code := runProjectUp(context.Background(), cfg, []string{"-f", file}, &out, &errOut); code == 0 || !strings.Contains(errOut.String(), "occupied") {
		t.Fatalf("expected port conflict: %s", errOut.String())
	}
	if mutations != 0 {
		t.Fatalf("remote mutations before port check: %d", mutations)
	}
}

func TestProjectOrdersDependenciesAndNamespacesResources(t *testing.T) {
	p := Project{Name: "my-app", Services: map[string]ProjectService{
		"app":   {Build: &ProjectBuild{Context: "."}, DependsOn: []string{"db", "cache"}, Ports: []string{"2102:8080"}, Volumes: []string{"uploads:/data:ro"}},
		"db":    {Image: "postgres:16-alpine", Volumes: []string{"db-data:/var/lib/postgresql/data"}},
		"cache": {Image: "redis:7-alpine"},
	}}
	order, err := p.validate()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(order, []string{"db", "cache", "app"}) {
		t.Fatalf("order = %v", order)
	}
	req, err := p.runRequest("app", p.Services["app"], "")
	if err != nil {
		t.Fatal(err)
	}
	if req.Name != "okestra-my-app-app" || req.Network != "okestra-my-app" || req.Restart != "unless-stopped" {
		t.Fatalf("request = %#v", req)
	}
	if len(req.Mounts) != 1 || req.Mounts[0].Source != "okestra-my-app-uploads" || !req.Mounts[0].ReadOnly {
		t.Fatalf("mounts = %#v", req.Mounts)
	}
}

func TestProjectForwardMappingChangeIsDetected(t *testing.T) {
	p := Project{Name: "demo", Services: map[string]ProjectService{"app": {Image: "nginx", Ports: []string{"8080:80", "8443:443"}}}}
	order, err := p.validate()
	if err != nil {
		t.Fatal(err)
	}
	want := projectForwardPorts(p, order)
	if !sameForwardPorts(want, []string{"localhost:8443 -> app:443", "localhost:8080 -> app:80"}) {
		t.Fatalf("forward mappings differ: %v", want)
	}
	if sameForwardPorts(want, []string{"localhost:8080 -> app:8080", "localhost:8443 -> app:443"}) {
		t.Fatal("changed remote port not detected")
	}
}

func TestProjectRejectsCyclesAndUnsafePaths(t *testing.T) {
	p := Project{Name: "demo", Services: map[string]ProjectService{"a": {Image: "alpine", DependsOn: []string{"b"}}, "b": {Image: "alpine", DependsOn: []string{"a"}}}}
	if _, err := p.validate(); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("wanted cycle error, got %v", err)
	}
	if _, err := localProjectPath(t.TempDir(), "../secret"); err == nil {
		t.Fatal("path escaped project directory")
	}
	p = Project{Name: "demo", Services: map[string]ProjectService{"a": {Image: "alpine", Ports: []string{"8080:80"}}, "b": {Image: "alpine", Ports: []string{"8080:8080"}}}}
	if _, err := p.validate(); err == nil || !strings.Contains(err.Error(), "local port") {
		t.Fatalf("wanted duplicate port error, got %v", err)
	}
}

func TestProjectEnvFileAndContextDigest(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("SECRET=test-value\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".dockerignore"), []byte("ignored.txt\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := Project{Name: "demo", Services: map[string]ProjectService{"app": {Image: "alpine", EnvFile: ".env"}}}
	req, err := p.runRequest("app", p.Services["app"], dir)
	if err != nil {
		t.Fatal(err)
	}
	if req.Env["SECRET"] != "test-value" {
		t.Fatalf("env = %#v", req.Env)
	}
	first, err := contextDigest(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("ignored"), 0o600); err != nil {
		t.Fatal(err)
	}
	second, err := contextDigest(dir)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("ignored file changed watch digest")
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("two"), 0o600); err != nil {
		t.Fatal(err)
	}
	third, err := contextDigest(dir)
	if err != nil {
		t.Fatal(err)
	}
	if third == first {
		t.Fatal("source edit not detected")
	}
}
