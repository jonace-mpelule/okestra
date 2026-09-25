package okestra_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jonace-mpelule/okestra/internal/agent"
	"github.com/jonace-mpelule/okestra/internal/client"
	"github.com/jonace-mpelule/okestra/internal/protocol"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type integrationRuntime struct{}

type blockingLogsRuntime struct {
	integrationRuntime
	opened chan struct{}
	closed chan struct{}
}

func (r *blockingLogsRuntime) ContainerLogs(ctx context.Context, _ string, _ bool) (io.ReadCloser, error) {
	reader, writer := io.Pipe()
	close(r.opened)
	go func() {
		<-ctx.Done()
		_ = writer.Close()
		close(r.closed)
	}()
	return reader, nil
}

func (integrationRuntime) Ping(context.Context) error { return nil }
func (integrationRuntime) BuildImage(_ context.Context, _ io.Reader, _ protocol.BuildRequest) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader("remote build complete\n")), nil
}
func (integrationRuntime) RunContainer(context.Context, protocol.RunRequest) (string, error) {
	return "container-123", nil
}
func (integrationRuntime) ListContainers(context.Context) ([]protocol.ContainerSummary, error) {
	return []protocol.ContainerSummary{{ID: "container-123", Name: "demo", Image: "demo:latest", Status: "Up"}}, nil
}
func (integrationRuntime) StopContainer(context.Context, string) error   { return nil }
func (integrationRuntime) RemoveContainer(context.Context, string) error { return nil }
func (integrationRuntime) ListImages(context.Context) ([]protocol.ImageSummary, error) {
	return []protocol.ImageSummary{{ID: "image-123", Tags: []string{"demo:latest"}}}, nil
}
func (integrationRuntime) RemoveImage(context.Context, string) error { return nil }
func (integrationRuntime) ContainerLogs(context.Context, string, bool) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader("hello from remote container\n")), nil
}
func (integrationRuntime) ExecStart(_ context.Context, _ string, req protocol.ExecRequest) (agent.ExecStream, error) {
	if len(req.Command) > 0 && req.Command[0] == "fail" {
		return &testReadWriteCloser{Reader: errorReader{}, Writer: io.Discard}, nil
	}
	if req.Stdin {
		reader, writer := io.Pipe()
		return &stdinTestStream{reader: reader, writer: writer}, nil
	}
	return &testReadWriteCloser{Reader: strings.NewReader("exec complete\n"), Writer: io.Discard}, nil
}
func (integrationRuntime) ResolveContainerPort(context.Context, string, int) (string, error) {
	return "127.0.0.1:1", nil
}

type testReadWriteCloser struct {
	io.Reader
	io.Writer
}

func (*testReadWriteCloser) Close() error      { return nil }
func (*testReadWriteCloser) CloseInput() error { return nil }

type errorReader struct{}

func (errorReader) Read([]byte) (int, error) { return 0, errors.New("exit status 7") }

type stdinTestStream struct {
	reader *io.PipeReader
	writer *io.PipeWriter
	input  bytes.Buffer
}

func (s *stdinTestStream) Read(p []byte) (int, error)  { return s.reader.Read(p) }
func (s *stdinTestStream) Write(p []byte) (int, error) { return s.input.Write(p) }
func (s *stdinTestStream) CloseInput() error {
	_, _ = s.writer.Write(s.input.Bytes())
	return s.writer.Close()
}
func (s *stdinTestStream) Close() error {
	_ = s.reader.Close()
	return s.writer.Close()
}

func TestAuthenticatedClientServiceWorkflow(t *testing.T) {
	svc := agent.NewServer("127.0.0.1:0", testToken, t.TempDir(), integrationRuntime{})
	httpServer := httptest.NewServer(svc.Handler())
	defer httpServer.Close()

	api := client.NewAPI(protocol.AgentProfile{URL: httpServer.URL, Token: testToken})
	ctx := context.Background()
	if err := api.Health(ctx); err != nil {
		t.Fatalf("health: %v", err)
	}
	status, err := api.Status(ctx)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !status.ServiceHealthy || !status.DockerHealthy {
		t.Fatalf("unexpected status: %+v", status)
	}

	opID, err := api.Build(ctx, protocol.BuildRequest{Tag: "demo:latest", Dockerfile: "Dockerfile"}, bytes.NewBufferString("tar payload"))
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	var output bytes.Buffer
	if err := api.StreamOperation(ctx, opID, func(env protocol.StreamEnvelope) error {
		output.Write(env.Data)
		return nil
	}); err != nil {
		t.Fatalf("stream build: %v", err)
	}
	if !strings.Contains(output.String(), "remote build complete") {
		t.Fatalf("missing build output: %q", output.String())
	}
	var logs bytes.Buffer
	if err := api.StreamLogs(ctx, "container-123", true, func(env protocol.StreamEnvelope) error {
		_, _ = logs.Write(env.Data)
		return nil
	}); err != nil {
		t.Fatalf("stream logs: %v", err)
	}
	if !strings.Contains(logs.String(), "hello from remote container") {
		t.Fatalf("missing container logs: %q", logs.String())
	}

	execID, err := api.CreateExec(ctx, "container-123", protocol.ExecRequest{Command: []string{"true"}, Stdout: true})
	if err != nil {
		t.Fatalf("create exec: %v", err)
	}
	var execOutput bytes.Buffer
	if err := api.AttachExec(ctx, "container-123", execID, &client.ExecIO{Stdout: &execOutput}); err != nil {
		t.Fatalf("attach non-interactive exec: %v", err)
	}
	if !strings.Contains(execOutput.String(), "exec complete") {
		t.Fatalf("missing exec output: %q", execOutput.String())
	}
	stdinID, err := api.CreateExec(ctx, "container-123", protocol.ExecRequest{Command: []string{"consume"}, Stdin: true, Stdout: true})
	if err != nil {
		t.Fatalf("create stdin exec: %v", err)
	}
	var stdinOutput bytes.Buffer
	if err := api.AttachExec(ctx, "container-123", stdinID, &client.ExecIO{Stdin: strings.NewReader("input accepted"), Stdout: &stdinOutput}); err != nil {
		t.Fatalf("stdin exec: %v", err)
	}
	if stdinOutput.String() != "input accepted" {
		t.Fatalf("stdin output = %q", stdinOutput.String())
	}
	failID, err := api.CreateExec(ctx, "container-123", protocol.ExecRequest{Command: []string{"fail"}, Stdout: true})
	if err != nil {
		t.Fatalf("create failing exec: %v", err)
	}
	if err := api.AttachExec(ctx, "container-123", failID, &client.ExecIO{Stdout: io.Discard}); err == nil || !strings.Contains(err.Error(), "exit status 7") {
		t.Fatalf("expected remote exit error, got %v", err)
	}

	if err := client.VerifySelfTestTunnel(ctx, api); err != nil {
		t.Fatalf("tunnel self-test: %v", err)
	}
}

func TestFollowLogsStopsOnCancellation(t *testing.T) {
	runtime := &blockingLogsRuntime{opened: make(chan struct{}), closed: make(chan struct{})}
	svc := agent.NewServer("127.0.0.1:0", testToken, t.TempDir(), runtime)
	httpServer := httptest.NewServer(svc.Handler())
	defer httpServer.Close()
	api := client.NewAPI(protocol.AgentProfile{URL: httpServer.URL, Token: testToken})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- api.StreamLogs(ctx, "container-123", true, func(protocol.StreamEnvelope) error { return nil })
	}()
	select {
	case <-runtime.opened:
	case <-time.After(3 * time.Second):
		t.Fatal("log stream did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context cancellation, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("client log stream stayed blocked after cancellation")
	}
	select {
	case <-runtime.closed:
	case <-time.After(3 * time.Second):
		t.Fatal("server log process was not cancelled after client disconnect")
	}
}
