package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

func TestParsePortMappings(t *testing.T) {
	got, err := parsePortMappings([]string{"8080:80", "5432:5432"})
	if err != nil {
		t.Fatalf("parse ports: %v", err)
	}
	if len(got) != 2 || got[0].LocalPort != 8080 || got[0].RemotePort != 80 {
		t.Fatalf("unexpected mappings: %#v", got)
	}
}

func TestRunInitService(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := runInitCommands([]string{"service", "--addr", "0.0.0.0:9443", "--token", "secret"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("expected success, got %d: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "OKESTRA_SERVICE_ADDR=0.0.0.0:9443") {
		t.Fatalf("unexpected output: %s", stdout.String())
	}
}

func TestValidateEndpointURL(t *testing.T) {
	got, err := validateEndpointURL("https://server.example:8443/")
	if err != nil {
		t.Fatalf("validate endpoint: %v", err)
	}
	if got != "https://server.example:8443" {
		t.Fatalf("endpoint = %q", got)
	}
	for _, invalid := range []string{"server:8088", "ftp://server", "http://server/path", "http://user:pass@server"} {
		if _, err := validateEndpointURL(invalid); err == nil {
			t.Fatalf("expected %q to be rejected", invalid)
		}
	}
}

func TestParsePortMappingsRejectsOutOfRange(t *testing.T) {
	if _, err := parsePortMappings([]string{"70000:80"}); err == nil {
		t.Fatal("expected out-of-range port to be rejected")
	}
}

func TestRunChecksAllLocalPortsBeforeCreatingContainer(t *testing.T) {
	port := freeTCPPort(t)
	var runRequests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/containers/run" {
			runRequests++
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "dev", Agents: map[string]protocol.AgentProfile{"dev": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	portMapping := fmt.Sprintf("%d:8080", port)
	if code := runRun(context.Background(), cfg, []string{"-p", portMapping, "-p", portMapping, "demo:latest"}, &out, &errOut); code != 1 {
		t.Fatalf("expected local port conflict, got %d: %s", code, errOut.String())
	}
	if runRequests != 0 {
		t.Fatalf("container created despite local port conflict: %d requests", runRequests)
	}
}

func TestRunStartsAndCleansUpTwoForwards(t *testing.T) {
	first, second := freeTCPPort(t), freeTCPPort(t)
	for second == first {
		second = freeTCPPort(t)
	}
	created := make(chan struct{}, 2)
	deleted := make(chan struct{}, 2)
	var nextID atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/containers/run":
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(protocol.RunResult{ContainerID: "container-123"})
		case r.Method == http.MethodGet && r.URL.Path == "/v1/containers":
			_ = json.NewEncoder(w).Encode([]protocol.ContainerSummary{{ID: "container-123", Status: "Up 1 second"}})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/port-forwards":
			created <- struct{}{}
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]string{"id": fmt.Sprintf("forward-%d", nextID.Add(1))})
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/port-forwards/"):
			deleted <- struct{}{}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "dev", Agents: map[string]protocol.AgentProfile{"dev": {URL: server.URL}}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var out, errOut bytes.Buffer
	done := make(chan int, 1)
	go func() {
		done <- runRun(ctx, cfg, []string{
			"-p", fmt.Sprintf("%d:8080", first),
			"-p", fmt.Sprintf("%d:9090", second),
			"demo:latest",
		}, &out, &errOut)
	}()
	for i := 0; i < 2; i++ {
		select {
		case <-created:
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for port-forward registration")
		}
	}
	for _, port := range []int{first, second} {
		deadline := time.Now().Add(5 * time.Second)
		for {
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
			if err == nil {
				_ = conn.Close()
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("port %d never became ready: %v", port, err)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	cancel()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("run failed: %s", errOut.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run did not stop after cancellation")
	}
	for i := 0; i < 2; i++ {
		select {
		case <-deleted:
		case <-time.After(5 * time.Second):
			t.Fatal("forward reservation was not cleaned up")
		}
	}
}

func TestRunReportsContainerExit(t *testing.T) {
	envPath := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(envPath, []byte("MORGAN=dev\nDATABASE_URL=postgresql://db:5432/urbanman\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runRequests := make(chan protocol.RunRequest, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/containers/run":
			var request protocol.RunRequest
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode run request: %v", err)
			}
			runRequests <- request
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(protocol.RunResult{ContainerID: "container-123"})
		case r.Method == http.MethodGet && r.URL.Path == "/v1/containers":
			_ = json.NewEncoder(w).Encode([]protocol.ContainerSummary{{ID: "container-123", Name: "urbanman", Status: "Exited (1)"}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "dev", Agents: map[string]protocol.AgentProfile{"dev": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	if code := runRun(context.Background(), cfg, []string{"--name", "urbanman", "--env-file", envPath, "--env", "MORGAN=combined", "demo:latest"}, &out, &errOut); code != 1 {
		t.Fatalf("expected failed run, got %d: %s", code, errOut.String())
	}
	request := <-runRequests
	if request.Env["MORGAN"] != "combined" || request.Env["DATABASE_URL"] != "postgresql://db:5432/urbanman" {
		t.Fatalf("environment not sent correctly: %#v", request.Env)
	}
	if !strings.Contains(errOut.String(), "urbanman is not running (Exited (1))") || !strings.Contains(errOut.String(), "okestra logs urbanman") {
		t.Fatalf("missing actionable exit message: %s", errOut.String())
	}
}

func TestRunAcceptsSuccessfulShortLivedContainer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/containers/run":
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(protocol.RunResult{ContainerID: "container-123"})
		case r.Method == http.MethodGet && r.URL.Path == "/v1/containers":
			_ = json.NewEncoder(w).Encode([]protocol.ContainerSummary{{ID: "container-123", Name: "job", Status: "Exited (0)"}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "dev", Agents: map[string]protocol.AgentProfile{"dev": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	if code := runRun(context.Background(), cfg, []string{"--name", "job", "demo:latest"}, &out, &errOut); code != 0 {
		t.Fatalf("expected successful run, got %d: %s", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "job finished (Exited (0))") {
		t.Fatalf("missing completion message: %s", errOut.String())
	}
}

func TestRunReportsContainerExitWhileForwarding(t *testing.T) {
	port := freeTCPPort(t)
	var statusChecks atomic.Int32
	deleted := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/containers/run":
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(protocol.RunResult{ContainerID: "container-123"})
		case r.Method == http.MethodGet && r.URL.Path == "/v1/containers":
			status := "Up 1 second"
			if statusChecks.Add(1) > 1 {
				status = "Exited (1)"
			}
			_ = json.NewEncoder(w).Encode([]protocol.ContainerSummary{{ID: "container-123", Name: "urbanman", Status: status}})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/port-forwards":
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]string{"id": "forward-1"})
		case r.Method == http.MethodDelete && r.URL.Path == "/v1/port-forwards/forward-1":
			deleted <- struct{}{}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "dev", Agents: map[string]protocol.AgentProfile{"dev": {URL: server.URL}}}
	var out, errOut bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if code := runRun(ctx, cfg, []string{"--name", "urbanman", "-p", fmt.Sprintf("%d:2102", port), "demo:latest"}, &out, &errOut); code != 1 {
		t.Fatalf("expected failed run, got %d: %s", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "urbanman is not running (Exited (1))") {
		t.Fatalf("missing stopped-container message: %s", errOut.String())
	}
	select {
	case <-deleted:
	case <-time.After(time.Second):
		t.Fatal("port forward was not cleaned up")
	}
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}
