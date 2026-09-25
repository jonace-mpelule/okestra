package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

type Runtime interface {
	Ping(ctx context.Context) error
	BuildImage(ctx context.Context, buildContext io.Reader, req protocol.BuildRequest) (io.ReadCloser, error)
	RunContainer(ctx context.Context, req protocol.RunRequest) (string, error)
	ListContainers(ctx context.Context) ([]protocol.ContainerSummary, error)
	StopContainer(ctx context.Context, id string) error
	RemoveContainer(ctx context.Context, id string) error
	ListImages(ctx context.Context) ([]protocol.ImageSummary, error)
	RemoveImage(ctx context.Context, id string) error
	ContainerLogs(ctx context.Context, id string, follow bool) (io.ReadCloser, error)
	ExecStart(ctx context.Context, id string, req protocol.ExecRequest) (ExecStream, error)
	ResolveContainerPort(ctx context.Context, id string, port int) (string, error)
}

type ExecStream interface {
	io.ReadWriteCloser
	CloseInput() error
}

type DockerClient struct {
	bin  string
	host string
}

func NewDockerClient(host string) (*DockerClient, error) {
	return &DockerClient{
		bin:  "docker",
		host: host,
	}, nil
}

func (d *DockerClient) Ping(ctx context.Context) error {
	cmd := d.command(ctx, "version", "--format", "{{.Server.Version}}")
	return cmd.Run()
}

func (d *DockerClient) BuildImage(ctx context.Context, buildContext io.Reader, req protocol.BuildRequest) (io.ReadCloser, error) {
	args := []string{"build", "-t", req.Tag}
	if req.Dockerfile != "" {
		args = append(args, "-f", req.Dockerfile)
	}
	for k, v := range req.BuildArgs {
		args = append(args, "--build-arg", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, "-")

	cmd := d.command(ctx, args...)
	cmd.Stdin = buildContext
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	go func() {
		pw.CloseWithError(cmd.Run())
	}()
	return pr, nil
}

func (d *DockerClient) RunContainer(ctx context.Context, req protocol.RunRequest) (string, error) {
	args := []string{"run", "-d"}
	if req.Name != "" {
		args = append(args, "--name", req.Name)
	}
	if req.WorkingDir != "" {
		args = append(args, "--workdir", req.WorkingDir)
	}
	for k, v := range req.Env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, req.Image)
	args = append(args, req.Command...)
	out, err := d.command(ctx, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func (d *DockerClient) ListContainers(ctx context.Context) ([]protocol.ContainerSummary, error) {
	out, err := d.command(ctx, "ps", "-a", "--format", "{{json .}}").Output()
	if err != nil {
		return nil, err
	}
	type row struct {
		ID      string `json:"ID"`
		Image   string `json:"Image"`
		Command string `json:"Command"`
		Status  string `json:"Status"`
		Names   string `json:"Names"`
		Ports   string `json:"Ports"`
	}
	var items []protocol.ContainerSummary
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		var r row
		if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
			return nil, err
		}
		var ports []string
		if strings.TrimSpace(r.Ports) != "" {
			ports = strings.Split(r.Ports, ", ")
		}
		items = append(items, protocol.ContainerSummary{
			ID:      r.ID,
			Name:    r.Names,
			Image:   r.Image,
			Status:  r.Status,
			Command: r.Command,
			Ports:   ports,
		})
	}
	return items, scanner.Err()
}

func (d *DockerClient) StopContainer(ctx context.Context, id string) error {
	out, err := d.command(ctx, "stop", id).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (d *DockerClient) RemoveContainer(ctx context.Context, id string) error {
	out, err := d.command(ctx, "rm", "-f", id).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (d *DockerClient) ListImages(ctx context.Context) ([]protocol.ImageSummary, error) {
	out, err := d.command(ctx, "images", "--format", "{{json .}}").Output()
	if err != nil {
		return nil, err
	}
	type row struct {
		ID         string `json:"ID"`
		Repository string `json:"Repository"`
		Tag        string `json:"Tag"`
		Size       string `json:"Size"`
	}
	var items []protocol.ImageSummary
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		var r row
		if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
			return nil, err
		}
		items = append(items, protocol.ImageSummary{
			ID:   r.ID,
			Tags: []string{fmt.Sprintf("%s:%s", r.Repository, r.Tag)},
			Size: parseSizeBytes(r.Size),
		})
	}
	return items, scanner.Err()
}

func (d *DockerClient) RemoveImage(ctx context.Context, id string) error {
	out, err := d.command(ctx, "image", "rm", "-f", id).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (d *DockerClient) ContainerLogs(ctx context.Context, id string, follow bool) (io.ReadCloser, error) {
	args := []string{"logs"}
	if follow {
		args = append(args, "--follow")
	}
	args = append(args, id)
	cmd := d.command(ctx, args...)
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	go func() {
		pw.CloseWithError(cmd.Run())
	}()
	return pr, nil
}

func (d *DockerClient) ExecStart(ctx context.Context, id string, req protocol.ExecRequest) (ExecStream, error) {
	args := []string{"exec"}
	if req.Stdin {
		args = append(args, "-i")
	}
	if req.TTY {
		args = append(args, "-t")
	}
	args = append(args, id)
	args = append(args, req.Command...)
	cmd := d.command(ctx, args...)
	if req.TTY {
		return newTTYCommandConn(cmd)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go func() {
		pw.CloseWithError(cmd.Wait())
	}()
	return &commandConn{r: pr, w: stdin}, nil
}

func (d *DockerClient) ResolveContainerPort(ctx context.Context, id string, port int) (string, error) {
	out, err := d.command(ctx, "inspect", "-f", "{{json .NetworkSettings.Networks}}", id).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	var networks map[string]struct {
		IPAddress string `json:"IPAddress"`
	}
	if err := json.Unmarshal(out, &networks); err != nil {
		return "", fmt.Errorf("inspect container networks: %w", err)
	}
	names := make([]string, 0, len(networks))
	for name := range networks {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		ip := net.ParseIP(networks[name].IPAddress)
		if ip != nil {
			return net.JoinHostPort(ip.String(), strconv.Itoa(port)), nil
		}
	}
	return "", fmt.Errorf("container %s has no reachable IP address", id)
}

func (d *DockerClient) command(ctx context.Context, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, d.bin, args...)
	if d.host != "" {
		cmd.Env = append(cmd.Environ(), "DOCKER_HOST="+d.host)
	}
	return cmd
}

type commandConn struct {
	r io.ReadCloser
	w io.WriteCloser
}

func (c *commandConn) Read(p []byte) (int, error)  { return c.r.Read(p) }
func (c *commandConn) Write(p []byte) (int, error) { return c.w.Write(p) }
func (c *commandConn) Close() error {
	_ = c.r.Close()
	return c.w.Close()
}

func (c *commandConn) CloseInput() error { return c.w.Close() }

func parseSizeBytes(raw string) int64 {
	raw = strings.TrimSpace(raw)
	index := 0
	for index < len(raw) && ((raw[index] >= '0' && raw[index] <= '9') || raw[index] == '.') {
		index++
	}
	if index == 0 {
		return 0
	}
	value, err := strconv.ParseFloat(raw[:index], 64)
	if err != nil {
		return 0
	}
	unit := strings.ToUpper(strings.TrimSpace(raw[index:]))
	multiplier := float64(1)
	switch unit {
	case "KB":
		multiplier = 1000
	case "MB":
		multiplier = 1000 * 1000
	case "GB":
		multiplier = 1000 * 1000 * 1000
	case "KIB":
		multiplier = 1024
	case "MIB":
		multiplier = 1024 * 1024
	case "GIB":
		multiplier = 1024 * 1024 * 1024
	}
	return int64(value * multiplier)
}
