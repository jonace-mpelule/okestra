package client

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jonace-mpelule/okestra/internal/protocol"
	"github.com/jonace-mpelule/okestra/internal/updater"
	"github.com/jonace-mpelule/okestra/internal/version"
)

func RunCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfgPath := DefaultConfigPath()
	cfg, err := LoadConfig(cfgPath)
	if err != nil {
		fmt.Fprintf(stderr, "load config: %v\n", err)
		return 1
	}

	switch args[0] {
	case "version":
		fmt.Fprintf(stdout, "okestra %s (commit %s, built %s)\n", version.Version, version.Commit, version.Date)
		return 0
	case "upgrade", "update":
		if len(args) > 2 || (len(args) == 2 && args[1] != "--check") {
			fmt.Fprintln(stderr, "usage: okestra upgrade [--check]")
			return 1
		}
		if err := updater.Upgrade(ctx, "okestra", len(args) == 2, stdout); err != nil {
			fmt.Fprintf(stderr, "upgrade: %v\n", err)
			return 1
		}
		return 0
	case "init":
		return runInitCommands(args[1:], stdout, stderr)
	case "agent", "server":
		return runAgentCommands(cfgPath, cfg, args[1:], stdout, stderr)
	case "config":
		if len(args) == 2 && args[1] == "path" {
			fmt.Fprintln(stdout, cfgPath)
			return 0
		}
		fmt.Fprintln(stderr, "usage: okestra config path")
		return 1
	case "status":
		return runStatus(ctx, cfg, stdout, stderr)
	case "doctor":
		return runDoctor(ctx, cfg, stdout, stderr)
	case "project":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: okestra project <init|ps>")
			return 1
		}
		switch args[1] {
		case "init":
			return runProjectInit(args[2:], stdout, stderr)
		case "ps":
			return runProjectPS(ctx, cfg, args[2:], stdout, stderr)
		}
		fmt.Fprintln(stderr, "usage: okestra project <init|ps>")
		return 1
	case "up":
		return runProjectUp(ctx, cfg, args[1:], stdout, stderr)
	case "down":
		return runProjectDown(ctx, cfg, args[1:], stdout, stderr)
	case "connect":
		return runConnect(ctx, cfg, args[1:], stdout, stderr)
	case "disconnect":
		return runDisconnect(args[1:], stdout, stderr)
	case "connections":
		return runConnections(stdout, stderr)
	case "watch":
		return runWatch(ctx, cfg, args[1:], stdout, stderr)
	case "__forward":
		return runForwardDaemon(ctx, cfg, args[1:], stderr)
	case "why":
		return runWhy(ctx, cfg, args[1:], stdout, stderr)
	case "build":
		return runBuild(ctx, cfg, args[1:], stdout, stderr)
	case "run":
		return runRun(ctx, cfg, args[1:], stdout, stderr)
	case "ps":
		return runPS(ctx, cfg, stdout, stderr)
	case "logs":
		return runLogs(ctx, cfg, args[1:], stdout, stderr)
	case "exec":
		return runExec(ctx, cfg, args[1:], stdout, stderr)
	case "stop":
		return runStop(ctx, cfg, args[1:], stdout, stderr)
	case "rm":
		return runRM(ctx, cfg, args[1:], stdout, stderr)
	case "images":
		return runImages(ctx, cfg, stdout, stderr)
	case "rmi":
		return runRMI(ctx, cfg, args[1:], stdout, stderr)
	case "port-forward":
		return runPortForward(ctx, cfg, args[1:], stdout, stderr)
	default:
		printUsage(stderr)
		return 1
	}
}

func runInitCommands(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "service" {
		fmt.Fprintln(stderr, "usage: okestra init service [--addr addr] [--data-dir dir] [--token token]")
		return 1
	}
	fs := flag.NewFlagSet("init service", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var addr, dataDir, token string
	fs.StringVar(&addr, "addr", "127.0.0.1:8088", "service listen address")
	fs.StringVar(&dataDir, "data-dir", "/var/lib/okestra", "service data directory")
	fs.StringVar(&token, "token", "", "bootstrap token")
	if err := fs.Parse(args[1:]); err != nil {
		return 1
	}
	if token == "" {
		token = randomToken()
	}
	fmt.Fprintln(stdout, "# Okestra service bootstrap")
	fmt.Fprintf(stdout, "export OKESTRA_SERVICE_ADDR=%s\n", addr)
	fmt.Fprintf(stdout, "export OKESTRA_SERVICE_WORKDIR=%s\n", dataDir)
	fmt.Fprintf(stdout, "export OKESTRA_SERVICE_TOKEN=%s\n", token)
	fmt.Fprintln(stdout, "go run ./cmd/okestra-service")
	return 0
}

func runAgentCommands(cfgPath string, cfg *Config, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: okestra server <add|use|list|remove>")
		return 1
	}
	switch args[0] {
	case "add":
		fs := flag.NewFlagSet("agent add", flag.ContinueOnError)
		fs.SetOutput(stderr)
		var name, endpoint, token, workspace string
		var insecureSkipVerify bool
		fs.StringVar(&name, "name", "", "profile name")
		fs.StringVar(&endpoint, "url", "", "Okestra endpoint URL")
		fs.StringVar(&token, "token", "", "service access token")
		fs.StringVar(&workspace, "workspace", "", "default remote workspace root")
		fs.BoolVar(&insecureSkipVerify, "insecure-skip-verify", false, "allow a self-signed HTTPS certificate")
		if err := fs.Parse(args[1:]); err != nil {
			return 1
		}
		if token == "" {
			token = os.Getenv("OKESTRA_TOKEN")
		}
		if name == "" || endpoint == "" || token == "" {
			fmt.Fprintln(stderr, "--name, --url and --token are required (token may also use OKESTRA_TOKEN)")
			return 1
		}
		endpoint, err := validateEndpointURL(endpoint)
		if err != nil {
			fmt.Fprintf(stderr, "invalid server URL: %v\n", err)
			return 1
		}
		if len(token) < 32 {
			fmt.Fprintln(stderr, "token must be at least 32 characters")
			return 1
		}
		cfg.Agents[name] = protocol.AgentProfile{Name: name, URL: endpoint, Token: token, DefaultWorkspace: workspace, InsecureSkipVerify: insecureSkipVerify}
		if cfg.ActiveAgent == "" {
			cfg.ActiveAgent = name
		}
		if err := SaveConfig(cfgPath, cfg); err != nil {
			fmt.Fprintf(stderr, "save config: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "added server %s (%s)\n", name, endpoint)
		if strings.HasPrefix(endpoint, "http://") {
			fmt.Fprintln(stderr, "warning: HTTP is appropriate only when the underlying private network is encrypted or otherwise trusted")
		}
		return 0
	case "use":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: okestra agent use <name>")
			return 1
		}
		if _, ok := cfg.Agents[args[1]]; !ok {
			fmt.Fprintf(stderr, "agent %s not found\n", args[1])
			return 1
		}
		cfg.ActiveAgent = args[1]
		if err := SaveConfig(cfgPath, cfg); err != nil {
			fmt.Fprintf(stderr, "save config: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "active agent set to %s\n", args[1])
		return 0
	case "list":
		for name, agent := range cfg.Agents {
			active := ""
			if cfg.ActiveAgent == name {
				active = " *"
			}
			fmt.Fprintf(stdout, "%s\t%s%s\n", name, agent.URL, active)
		}
		return 0
	case "remove":
		if len(args) != 2 {
			fmt.Fprintln(stderr, "usage: okestra server remove <name>")
			return 1
		}
		if _, ok := cfg.Agents[args[1]]; !ok {
			fmt.Fprintf(stderr, "server %s not found\n", args[1])
			return 1
		}
		delete(cfg.Agents, args[1])
		if cfg.ActiveAgent == args[1] {
			cfg.ActiveAgent = ""
		}
		if err := SaveConfig(cfgPath, cfg); err != nil {
			fmt.Fprintf(stderr, "save config: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "removed server %s\n", args[1])
		return 0
	default:
		fmt.Fprintln(stderr, "usage: okestra server <add|use|list|remove>")
		return 1
	}
}

func runStatus(ctx context.Context, cfg *Config, stdout, stderr io.Writer) int {
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	status, err := api.Status(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "status: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "endpoint: %s\n", profile.URL)
	fmt.Fprintf(stdout, "service_healthy: %t\n", status.ServiceHealthy)
	fmt.Fprintf(stdout, "docker_healthy: %t\n", status.DockerHealthy)
	fmt.Fprintf(stdout, "service_version: %s\n", status.Version)
	fmt.Fprintf(stdout, "protocol_version: %d\n", status.ProtocolVersion)
	fmt.Fprintf(stdout, "active_operations: %d\n", len(status.ActiveOperations))
	fmt.Fprintf(stdout, "active_tunnels: %d\n", len(status.ActiveTunnels))
	return 0
}

func runDoctor(ctx context.Context, cfg *Config, stdout, stderr io.Writer) int {
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	report := protocol.DoctorReport{Endpoint: profile.URL}
	check := func(name string, err error) {
		item := protocol.DoctorCheck{Name: name, OK: err == nil}
		if err != nil {
			item.Message = err.Error()
		}
		report.Checks = append(report.Checks, item)
	}

	check("endpoint_reachable", api.Health(ctx))
	status, err := api.Status(ctx)
	check("auth_and_status", err)
	if err == nil {
		check("protocol_compatible", boolErr(status.ProtocolVersion == protocol.ProtocolVersion, fmt.Sprintf("service protocol %d, CLI protocol %d", status.ProtocolVersion, protocol.ProtocolVersion)))
		check("service_healthy", boolErr(status.ServiceHealthy, "service unhealthy"))
		check("docker_healthy", boolErr(status.DockerHealthy, "docker unhealthy"))
	}
	check("build_upload_and_stream", verifyDoctorBuild(ctx, api))
	check("tunnel_path", VerifySelfTestTunnel(ctx, api))

	report.OK = true
	for _, item := range report.Checks {
		if !item.OK {
			report.OK = false
			break
		}
	}
	for _, item := range report.Checks {
		state := "ok"
		if !item.OK {
			state = "fail"
		}
		if item.Message != "" {
			fmt.Fprintf(stdout, "%s\t%s\t%s\n", item.Name, state, item.Message)
		} else {
			fmt.Fprintf(stdout, "%s\t%s\n", item.Name, state)
		}
	}
	if !report.OK {
		fmt.Fprintf(stderr, "doctor: service at %s is not usable yet\n", profile.URL)
		return 1
	}
	fmt.Fprintf(stdout, "doctor\tok\t%s\n", profile.URL)
	return 0
}

func runBuild(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	_ = profile
	fs := flag.NewFlagSet("build", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var tag, dockerfile string
	var buildArgs multiFlag
	fs.StringVar(&tag, "t", "", "image tag")
	fs.StringVar(&dockerfile, "f", "Dockerfile", "dockerfile path relative to context")
	fs.Var(&buildArgs, "build-arg", "build argument KEY=VALUE (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	contextDir := "."
	if fs.NArg() > 0 {
		contextDir = fs.Arg(0)
	}
	if tag == "" {
		fmt.Fprintln(stderr, "-t is required")
		return 1
	}
	parsedBuildArgs, err := parseKeyValues(buildArgs)
	if err != nil {
		fmt.Fprintf(stderr, "build args: %v\n", err)
		return 1
	}
	tarData, err := OpenBuildContext(contextDir, dockerfile)
	if err != nil {
		fmt.Fprintf(stderr, "build context: %v\n", err)
		return 1
	}
	defer tarData.Close()
	opID, err := api.Build(ctx, protocol.BuildRequest{Tag: tag, Dockerfile: dockerfile, ContextDir: contextDir, BuildArgs: parsedBuildArgs}, tarData)
	if err != nil {
		fmt.Fprintf(stderr, "remote build: %v\n", err)
		return 1
	}
	err = api.StreamOperation(ctx, opID, func(env protocol.StreamEnvelope) error {
		if len(env.Data) > 0 {
			_, _ = stdout.Write(env.Data)
		}
		if env.Type == "error" {
			return errors.New(env.Message)
		}
		return nil
	})
	if err != nil {
		fmt.Fprintf(stderr, "stream build: %v\n", err)
		return 1
	}
	return 0
}

func runRun(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var name, workingDir, envFile string
	var forwards, environment multiFlag
	fs.StringVar(&name, "name", "", "container name")
	fs.StringVar(&workingDir, "workdir", "", "container working directory")
	fs.StringVar(&envFile, "env-file", "", "local KEY=VALUE file for container environment")
	fs.Var(&forwards, "p", "port forward local:remote")
	fs.Var(&environment, "env", "environment variable KEY=VALUE (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() < 1 {
		fmt.Fprintln(stderr, "usage: okestra run [--name name] [-p local:remote] [--env-file path] <image> [cmd...]")
		return 1
	}
	image := fs.Arg(0)
	cmd := fs.Args()[1:]
	pms, err := parsePortMappings([]string(forwards))
	if err != nil {
		fmt.Fprintf(stderr, "parse ports: %v\n", err)
		return 1
	}
	env, err := readEnvFile(envFile)
	if err != nil {
		fmt.Fprintf(stderr, "environment file: %v\n", err)
		return 1
	}
	overrides, err := parseKeyValues(environment)
	if err != nil {
		fmt.Fprintf(stderr, "environment: %v\n", err)
		return 1
	}
	for key, value := range overrides {
		env[key] = value
	}
	listeners := make([][]net.Listener, 0, len(pms))
	defer func() {
		for _, group := range listeners {
			closeListeners(group)
		}
	}()
	for _, pm := range pms {
		group, err := listenLoopbackPort(pm.LocalPort)
		if err != nil {
			fmt.Fprintf(stderr, "local port %d: %v\n", pm.LocalPort, err)
			return 1
		}
		listeners = append(listeners, group)
	}
	result, err := api.RunContainer(ctx, protocol.RunRequest{
		Image:       image,
		Name:        name,
		Command:     cmd,
		Env:         env,
		WorkingDir:  workingDir,
		AutoForward: pms,
	})
	if err != nil {
		fmt.Fprintf(stderr, "run container: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "container: %s\n", result.ContainerID)
	// docker run -d can return successfully even when the process exits immediately.
	// Check after a short startup window before advertising a usable local port.
	select {
	case <-ctx.Done():
		return 0
	case <-time.After(time.Second):
	}
	if stopped, exitCode, err := reportStoppedContainer(ctx, api, result.ContainerID, name, stderr); err != nil {
		fmt.Fprintf(stderr, "could not confirm container status: %v\n", err)
		return 1
	} else if stopped {
		return exitCode
	}
	forwardCtx, cancelForwards := context.WithCancel(ctx)
	defer cancelForwards()
	activeForwards := make([]*PortForward, 0, len(pms))
	defer func() {
		for _, forward := range activeForwards {
			forward.Close()
		}
	}()
	for i, pm := range pms {
		forward, err := OpenPortForward(forwardCtx, api, protocol.PortForwardRequest{
			ContainerID: result.ContainerID,
			LocalPort:   pm.LocalPort,
			RemotePort:  pm.RemotePort,
		}, listeners[i]...)
		if err != nil {
			fmt.Fprintf(stderr, "port forwarding setup: %v\n", err)
			return 1
		}
		activeForwards = append(activeForwards, forward)
		fmt.Fprintf(stdout, "forwarding localhost:%d -> %s:%d\n", pm.LocalPort, result.ContainerID, pm.RemotePort)
	}
	if len(pms) == 0 {
		fmt.Fprintln(stdout, "no local port forward requested; use -p LOCAL:CONTAINER to open localhost")
	}
	if len(pms) > 0 {
		forwardErrors := make(chan error, len(activeForwards))
		statusTicker := time.NewTicker(2 * time.Second)
		defer statusTicker.Stop()
		for _, forward := range activeForwards {
			go func(f *PortForward) { forwardErrors <- f.Serve(forwardCtx) }(forward)
		}
		for {
			select {
			case <-ctx.Done():
				return 0
			case err := <-forwardErrors:
				if ctx.Err() == nil {
					cancelForwards()
					fmt.Fprintf(stderr, "port forwarding stopped: %v\n", err)
					return 1
				}
			case <-statusTicker.C:
				stopped, exitCode, err := reportStoppedContainer(ctx, api, result.ContainerID, name, stderr)
				if err != nil {
					if ctx.Err() != nil {
						return 0
					}
					fmt.Fprintf(stderr, "could not check container status: %v\n", err)
					return 1
				}
				if stopped {
					return exitCode
				}
			}
		}
	}
	return 0
}

func reportStoppedContainer(ctx context.Context, api *API, id, name string, stderr io.Writer) (bool, int, error) {
	items, err := api.ListContainers(ctx)
	if err != nil {
		return false, 0, err
	}
	label := name
	if label == "" {
		label = shortID(id)
	}
	for _, item := range items {
		if item.ID != id && (item.ID == "" || !strings.HasPrefix(id, item.ID)) && (name == "" || item.Name != name) {
			continue
		}
		if strings.HasPrefix(item.Status, "Up") {
			return false, 0, nil
		}
		if strings.HasPrefix(item.Status, "Exited (0)") {
			fmt.Fprintf(stderr, "container %s finished (%s). View output: okestra logs %s\n", label, item.Status, label)
			return true, 0, nil
		}
		fmt.Fprintf(stderr, "container %s is not running (%s). Check startup output: okestra logs %s\n", label, item.Status, label)
		return true, 1, nil
	}
	fmt.Fprintf(stderr, "container %s is no longer listed. Check startup output: okestra logs %s\n", label, label)
	return true, 1, nil
}

func runPS(ctx context.Context, cfg *Config, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	items, err := api.ListContainers(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "list containers: %v\n", err)
		return 1
	}
	for _, item := range items {
		fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", shortID(item.ID), item.Name, item.Image, item.Status)
	}
	return 0
}

func runLogs(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var follow bool
	var tail int
	fs.BoolVar(&follow, "f", false, "follow")
	fs.IntVar(&tail, "tail", 0, "show only the last N lines")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: okestra logs [-f] [--tail N] <container>")
		return 1
	}
	if tail < 0 || tail > 10000 {
		fmt.Fprintln(stderr, "--tail must be between 0 and 10000")
		return 1
	}
	err := api.StreamLogsTail(ctx, fs.Arg(0), follow, tail, func(env protocol.StreamEnvelope) error {
		if len(env.Data) > 0 {
			_, _ = stdout.Write(env.Data)
		}
		if env.Type == "error" {
			return errors.New(env.Message)
		}
		return nil
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return 0
		}
		fmt.Fprintf(stderr, "logs: %v\n", err)
		return 1
	}
	return 0
}

func runExec(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var tty bool
	fs.BoolVar(&tty, "it", false, "allocate tty and stdin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() < 2 {
		fmt.Fprintln(stderr, "usage: okestra exec [-it] <container> <command...>")
		return 1
	}
	containerID := fs.Arg(0)
	command := fs.Args()[1:]
	execID, err := api.CreateExec(ctx, containerID, protocol.ExecRequest{
		Command: command,
		TTY:     tty,
		Stdin:   tty,
		Stdout:  true,
		Stderr:  !tty,
	})
	if err != nil {
		fmt.Fprintf(stderr, "exec create: %v\n", err)
		return 1
	}
	if tty {
		restore, err := makeTerminalRaw(os.Stdin)
		if err == nil {
			defer restore()
		}
	}
	var stdin io.Reader
	if tty {
		stdin = os.Stdin
	}
	err = api.AttachExec(ctx, containerID, execID, &ExecIO{
		Stdin:  stdin,
		Stdout: stdout,
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return 0
		}
		fmt.Fprintf(stderr, "exec attach: %v\n", err)
		return 1
	}
	return 0
}

func runStop(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: okestra stop <container>")
		return 1
	}
	if err := api.StopContainer(ctx, args[0]); err != nil {
		fmt.Fprintf(stderr, "stop: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "stopped")
	return 0
}

func runRM(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: okestra rm <container>")
		return 1
	}
	if err := api.RemoveContainer(ctx, args[0]); err != nil {
		fmt.Fprintf(stderr, "rm: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "removed")
	return 0
}

func runImages(ctx context.Context, cfg *Config, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	items, err := api.ListImages(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "images: %v\n", err)
		return 1
	}
	for _, item := range items {
		fmt.Fprintf(stdout, "%s\t%s\t%d\n", shortID(item.ID), strings.Join(item.Tags, ","), item.Size)
	}
	return 0
}

func runRMI(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: okestra rmi <image>")
		return 1
	}
	if err := api.RemoveImage(ctx, args[0]); err != nil {
		fmt.Fprintf(stderr, "rmi: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "removed")
	return 0
}

func runPortForward(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if len(args) != 2 {
		fmt.Fprintln(stderr, "usage: okestra port-forward <container> <local>:<remote>")
		return 1
	}
	mappings, err := parsePortMappings([]string{args[1]})
	if err != nil {
		fmt.Fprintf(stderr, "parse ports: %v\n", err)
		return 1
	}
	req := protocol.PortForwardRequest{
		ContainerID: args[0],
		LocalPort:   mappings[0].LocalPort,
		RemotePort:  mappings[0].RemotePort,
	}
	fmt.Fprintf(stdout, "forwarding 127.0.0.1:%d -> %s:%d\n", req.LocalPort, req.ContainerID, req.RemotePort)
	if err := StartPortForward(ctx, api, req); err != nil {
		fmt.Fprintf(stderr, "port-forward: %v\n", err)
		return 1
	}
	return 0
}

func activeAPI(cfg *Config, stderr io.Writer) (protocol.AgentProfile, *API, bool) {
	profile, err := cfg.ActiveProfile()
	if err != nil {
		fmt.Fprintf(stderr, "active agent: %v\n", err)
		return protocol.AgentProfile{}, nil, false
	}
	return profile, NewAPI(profile), true
}

func parsePortMappings(items []string) ([]protocol.PortMapping, error) {
	out := make([]protocol.PortMapping, 0, len(items))
	for _, item := range items {
		parts := strings.Split(item, ":")
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid mapping %q", item)
		}
		localPort, err := strconv.Atoi(parts[0])
		if err != nil {
			return nil, err
		}
		remotePort, err := strconv.Atoi(parts[1])
		if err != nil {
			return nil, err
		}
		if localPort < 1 || localPort > 65535 || remotePort < 1 || remotePort > 65535 {
			return nil, fmt.Errorf("invalid mapping %q: ports must be between 1 and 65535", item)
		}
		out = append(out, protocol.PortMapping{LocalPort: localPort, RemotePort: remotePort})
	}
	return out, nil
}

func parseKeyValues(items []string) (map[string]string, error) {
	out := make(map[string]string, len(items))
	for _, item := range items {
		key, value, ok := strings.Cut(item, "=")
		if !ok || strings.TrimSpace(key) == "" {
			return nil, fmt.Errorf("invalid KEY=VALUE %q", item)
		}
		out[key] = value
	}
	return out, nil
}

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(value string) error {
	*m = append(*m, value)
	return nil
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "okestra commands:")
	fmt.Fprintln(w, "  version")
	fmt.Fprintln(w, "  upgrade [--check]")
	fmt.Fprintln(w, "  init service [--addr addr] [--data-dir dir] [--token token]")
	fmt.Fprintln(w, "  server add --name <name> --url <url> --token <token>")
	fmt.Fprintln(w, "  server use <name>")
	fmt.Fprintln(w, "  server list")
	fmt.Fprintln(w, "  server remove <name>")
	fmt.Fprintln(w, "  config path")
	fmt.Fprintln(w, "  status")
	fmt.Fprintln(w, "  doctor")
	fmt.Fprintln(w, "  project init | project ps")
	fmt.Fprintln(w, "  up [--build] [--recreate] | down")
	fmt.Fprintln(w, "  connect | disconnect | connections")
	fmt.Fprintln(w, "  watch [--service name]")
	fmt.Fprintln(w, "  why <container>")
	fmt.Fprintln(w, "  build -t <tag> [--build-arg KEY=VALUE] [context]")
	fmt.Fprintln(w, "  run [--name name] [-p local:remote] [--env-file path] [--env KEY=VALUE] <image> [cmd...]")
	fmt.Fprintln(w, "  ps")
	fmt.Fprintln(w, "  logs [-f] [--tail N] <container>")
	fmt.Fprintln(w, "  exec [-it] <container> <command...>")
	fmt.Fprintln(w, "  stop <container>")
	fmt.Fprintln(w, "  rm <container>")
	fmt.Fprintln(w, "  images")
	fmt.Fprintln(w, "  rmi <image>")
	fmt.Fprintln(w, "  port-forward <container> <local>:<remote>")
}

func validateEndpointURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", errors.New("scheme must be http or https")
	}
	if u.Host == "" {
		return "", errors.New("host is required")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", errors.New("URL must not contain credentials, a path, query, or fragment")
	}
	u.Path = ""
	return strings.TrimRight(u.String(), "/"), nil
}

func verifyDoctorBuild(ctx context.Context, api *API) error {
	payload, err := createDoctorBuildContextTar()
	if err != nil {
		return err
	}
	tag := "okestra-doctor:" + shortID(randomToken())
	opID, err := api.Build(ctx, protocol.BuildRequest{Tag: tag, Dockerfile: "Dockerfile"}, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = api.RemoveImage(cleanupCtx, tag)
	}()
	seen := false
	err = api.StreamOperation(ctx, opID, func(env protocol.StreamEnvelope) error {
		if len(env.Data) > 0 {
			seen = true
		}
		if env.Type == "error" {
			return errors.New(env.Message)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if !seen {
		return errors.New("no build stream data received")
	}
	return nil
}

func createDoctorBuildContextTar() ([]byte, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	content := []byte("FROM scratch\nLABEL org.okestra.doctor=true\n")
	hdr := &tar.Header{Name: "Dockerfile", Mode: 0o644, Size: int64(len(content))}
	if err := tw.WriteHeader(hdr); err != nil {
		return nil, err
	}
	if _, err := tw.Write(content); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func randomToken() string {
	var b [32]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func boolErr(ok bool, msg string) error {
	if ok {
		return nil
	}
	return errors.New(msg)
}
