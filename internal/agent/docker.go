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

// ProjectRuntime is optional so older in-memory runtimes can still serve the
// basic API. Production uses DockerClient, which implements all methods.
type ProjectRuntime interface {
	EnsureNetwork(context.Context, string) error
	RemoveNetwork(context.Context, string) error
	EnsureVolume(context.Context, string) error
	InspectContainer(context.Context, string) (protocol.ContainerDetails, error)
	StartContainer(context.Context, string) error
}

func (d *DockerClient) StartContainer(ctx context.Context, id string) error {
	out, err := d.command(ctx, "start", id).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start container: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
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
	args := runContainerArgs(req)
	out, err := d.command(ctx, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func runContainerArgs(req protocol.RunRequest) []string {
	args := []string{"run", "-d"}
	if req.Name != "" {
		args = append(args, "--name", req.Name)
	}
	if req.WorkingDir != "" {
		args = append(args, "--workdir", req.WorkingDir)
	}
	if req.Network != "" {
		args = append(args, "--network", req.Network)
	}
	if req.NetworkAlias != "" {
		args = append(args, "--network-alias", req.NetworkAlias)
	}
	if req.Restart != "" {
		args = append(args, "--restart", req.Restart)
	}
	if req.Health != nil {
		args = append(args, "--health-cmd", req.Health.Command)
		if req.Health.IntervalSeconds > 0 {
			args = append(args, "--health-interval", strconv.Itoa(req.Health.IntervalSeconds)+"s")
		}
		if req.Health.Retries > 0 {
			args = append(args, "--health-retries", strconv.Itoa(req.Health.Retries))
		}
	}
	for _, mount := range req.Mounts {
		spec := "type=volume,source=" + mount.Source + ",target=" + mount.Target
		if mount.ReadOnly {
			spec += ",readonly"
		}
		args = append(args, "--mount", spec)
	}
	labelKeys := make([]string, 0, len(req.Labels))
	for key := range req.Labels {
		labelKeys = append(labelKeys, key)
	}
	sort.Strings(labelKeys)
	for _, key := range labelKeys {
		args = append(args, "--label", key+"="+req.Labels[key])
	}
	for k, v := range req.Env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, req.Image)
	args = append(args, req.Command...)
	return args
}

func (d *DockerClient) EnsureNetwork(ctx context.Context, name string) error {
	if out, err := d.command(ctx, "network", "inspect", "-f", "{{ index .Labels \"dev.okestra.managed\" }}", name).CombinedOutput(); err == nil {
		if strings.TrimSpace(string(out)) != "true" {
			return fmt.Errorf("network %s already exists but is not managed by Okestra", name)
		}
		return nil
	}
	out, err := d.command(ctx, "network", "create", "--driver", "bridge", "--label", "dev.okestra.managed=true", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create network: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (d *DockerClient) RemoveNetwork(ctx context.Context, name string) error {
	if out, err := d.command(ctx, "network", "inspect", "-f", "{{ index .Labels \"dev.okestra.managed\" }}", name).CombinedOutput(); err != nil {
		if strings.Contains(string(out), "No such network") {
			return nil
		}
		return fmt.Errorf("inspect network: %w: %s", err, strings.TrimSpace(string(out)))
	} else if strings.TrimSpace(string(out)) != "true" {
		return fmt.Errorf("network %s is not managed by Okestra", name)
	}
	out, err := d.command(ctx, "network", "rm", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("remove network: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (d *DockerClient) EnsureVolume(ctx context.Context, name string) error {
	if out, err := d.command(ctx, "volume", "inspect", "-f", "{{ index .Labels \"dev.okestra.managed\" }}", name).CombinedOutput(); err == nil {
		if strings.TrimSpace(string(out)) != "true" {
			return fmt.Errorf("volume %s already exists but is not managed by Okestra", name)
		}
		return nil
	}
	out, err := d.command(ctx, "volume", "create", "--label", "dev.okestra.managed=true", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create volume: %w: %s", err, strings.TrimSpace(string(out)))
	}
	label, err := d.command(ctx, "volume", "inspect", "-f", "{{ index .Labels \"dev.okestra.managed\" }}", name).CombinedOutput()
	if err != nil || strings.TrimSpace(string(label)) != "true" {
		return fmt.Errorf("volume %s could not be verified as Okestra-managed", name)
	}
	return nil
}

func (d *DockerClient) InspectContainer(ctx context.Context, id string) (protocol.ContainerDetails, error) {
	return d.inspectContainer(ctx, id, false)
}

func (d *DockerClient) InspectContainerWithLogs(ctx context.Context, id string) (protocol.ContainerDetails, error) {
	return d.inspectContainer(ctx, id, true)
}

func (d *DockerClient) inspectContainer(ctx context.Context, id string, includeLogs bool) (protocol.ContainerDetails, error) {
	out, err := d.command(ctx, "inspect", "--type", "container", id).CombinedOutput()
	if err != nil {
		return protocol.ContainerDetails{}, fmt.Errorf("inspect container: %w: %s", err, strings.TrimSpace(string(out)))
	}
	var rows []struct {
		ID     string `json:"Id"`
		Name   string `json:"Name"`
		Config struct {
			Image  string            `json:"Image"`
			Labels map[string]string `json:"Labels"`
		} `json:"Config"`
		State struct {
			Status    string `json:"Status"`
			Running   bool   `json:"Running"`
			ExitCode  int    `json:"ExitCode"`
			OOMKilled bool   `json:"OOMKilled"`
			Error     string `json:"Error"`
			Health    *struct {
				Status string `json:"Status"`
			} `json:"Health"`
		} `json:"State"`
		RestartCount    int `json:"RestartCount"`
		NetworkSettings struct {
			Networks map[string]json.RawMessage `json:"Networks"`
			Ports    map[string]json.RawMessage `json:"Ports"`
		} `json:"NetworkSettings"`
		Mounts []struct {
			Name        string `json:"Name"`
			Destination string `json:"Destination"`
			RW          bool   `json:"RW"`
		} `json:"Mounts"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return protocol.ContainerDetails{}, err
	}
	if len(rows) != 1 {
		return protocol.ContainerDetails{}, fmt.Errorf("container %s not found", id)
	}
	r := rows[0]
	detail := protocol.ContainerDetails{ID: r.ID, Name: strings.TrimPrefix(r.Name, "/"), Image: r.Config.Image, Status: r.State.Status, Running: r.State.Running, ExitCode: r.State.ExitCode, OOMKilled: r.State.OOMKilled, Error: r.State.Error, RestartCount: r.RestartCount, Labels: r.Config.Labels}
	if r.State.Health != nil {
		detail.Health = r.State.Health.Status
	}
	for network := range r.NetworkSettings.Networks {
		detail.Networks = append(detail.Networks, network)
	}
	sort.Strings(detail.Networks)
	for port := range r.NetworkSettings.Ports {
		detail.Ports = append(detail.Ports, port)
	}
	sort.Strings(detail.Ports)
	for _, mount := range r.Mounts {
		if mount.Name != "" {
			detail.Mounts = append(detail.Mounts, protocol.Mount{Source: mount.Name, Target: mount.Destination, ReadOnly: !mount.RW})
		}
	}
	if includeLogs {
		logs, _ := d.command(ctx, "logs", "--tail", "30", id).CombinedOutput()
		if len(logs) > 16384 {
			logs = logs[len(logs)-16384:]
		}
		detail.RecentLogs = string(logs)
	}
	return detail, nil
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
	return d.ContainerLogsTail(ctx, id, follow, 0)
}

func (d *DockerClient) ContainerLogsTail(ctx context.Context, id string, follow bool, tail int) (io.ReadCloser, error) {
	args := []string{"logs"}
	if tail > 0 {
		args = append(args, "--tail", strconv.Itoa(tail))
	}
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
