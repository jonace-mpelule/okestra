package client

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

// Project is intentionally smaller than Compose: it declares only what
// Okestra can manage safely across a private connection.
type Project struct {
	Name     string                    `json:"name"`
	Services map[string]ProjectService `json:"services"`
}

type ProjectService struct {
	Image       string                `json:"image,omitempty"`
	Build       *ProjectBuild         `json:"build,omitempty"`
	Command     []string              `json:"command,omitempty"`
	WorkingDir  string                `json:"working_dir,omitempty"`
	EnvFile     string                `json:"env_file,omitempty"`
	Environment map[string]string     `json:"environment,omitempty"`
	Ports       []string              `json:"ports,omitempty"`
	Volumes     []string              `json:"volumes,omitempty"`
	DependsOn   []string              `json:"depends_on,omitempty"`
	Restart     string                `json:"restart,omitempty"`
	Health      *protocol.HealthCheck `json:"health,omitempty"`
}

type ProjectBuild struct {
	Context    string            `json:"context"`
	Dockerfile string            `json:"dockerfile,omitempty"`
	Args       map[string]string `json:"args,omitempty"`
}

var projectName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

func loadProject(path string) (Project, string, []string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return Project{}, "", nil, err
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return Project{}, "", nil, err
	}
	var project Project
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&project); err != nil {
		return Project{}, "", nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return Project{}, "", nil, errors.New("unexpected content after project manifest")
	}
	order, err := project.validate()
	return project, filepath.Dir(abs), order, err
}

func (p Project) validate() ([]string, error) {
	if !projectName.MatchString(p.Name) || len(p.Name) > 48 {
		return nil, errors.New("project name must be lowercase letters, digits, hyphens and at most 48 characters")
	}
	if len(p.Services) == 0 {
		return nil, errors.New("project must contain at least one service")
	}
	if len(p.Services) > 32 {
		return nil, errors.New("project exceeds 32 services")
	}
	localPorts := map[int]string{}
	for name, svc := range p.Services {
		if !projectName.MatchString(name) || len(name) > 48 {
			return nil, fmt.Errorf("invalid service name %q", name)
		}
		if svc.Image == "" && svc.Build == nil {
			return nil, fmt.Errorf("service %s needs image or build", name)
		}
		if svc.Build != nil && svc.Build.Context == "" {
			return nil, fmt.Errorf("service %s build needs a context", name)
		}
		ports, err := parsePortMappings(svc.Ports)
		if err != nil {
			return nil, fmt.Errorf("service %s: %w", name, err)
		}
		for _, mapping := range ports {
			if prior, exists := localPorts[mapping.LocalPort]; exists {
				return nil, fmt.Errorf("local port %d is declared by both %s and %s", mapping.LocalPort, prior, name)
			}
			localPorts[mapping.LocalPort] = name
		}
		if _, err := p.runRequest(name, svc, ""); err != nil {
			return nil, err
		}
		for _, dep := range svc.DependsOn {
			if _, ok := p.Services[dep]; !ok {
				return nil, fmt.Errorf("service %s depends on unknown service %s", name, dep)
			}
		}
	}
	keys := make([]string, 0, len(p.Services))
	for name := range p.Services {
		keys = append(keys, name)
	}
	sort.Strings(keys)
	states := map[string]int{}
	order := make([]string, 0, len(keys))
	var visit func(string) error
	visit = func(name string) error {
		if states[name] == 1 {
			return fmt.Errorf("dependency cycle at %s", name)
		}
		if states[name] == 2 {
			return nil
		}
		states[name] = 1
		for _, dep := range p.Services[name].DependsOn {
			if err := visit(dep); err != nil {
				return err
			}
		}
		states[name] = 2
		order = append(order, name)
		return nil
	}
	for _, name := range keys {
		if err := visit(name); err != nil {
			return nil, err
		}
	}
	return order, nil
}

func (p Project) networkName() string                 { return "okestra-" + p.Name }
func (p Project) containerName(service string) string { return "okestra-" + p.Name + "-" + service }
func (p Project) volumeName(volume string) string     { return "okestra-" + p.Name + "-" + volume }

func (p Project) runRequest(name string, svc ProjectService, base string) (protocol.RunRequest, error) {
	ports, err := parsePortMappings(svc.Ports)
	if err != nil {
		return protocol.RunRequest{}, err
	}
	env := map[string]string{}
	if base != "" && svc.EnvFile != "" {
		path, err := localProjectPath(base, svc.EnvFile)
		if err != nil {
			return protocol.RunRequest{}, err
		}
		env, err = readEnvFile(path)
		if err != nil {
			return protocol.RunRequest{}, fmt.Errorf("service %s env_file: %w", name, err)
		}
	}
	for k, v := range svc.Environment {
		env[k] = v
	}
	mounts := make([]protocol.Mount, 0, len(svc.Volumes))
	for _, raw := range svc.Volumes {
		parts := strings.Split(raw, ":")
		if len(parts) < 2 || len(parts) > 3 || !projectName.MatchString(parts[0]) || len(parts[0]) > 48 || !strings.HasPrefix(parts[1], "/") {
			return protocol.RunRequest{}, fmt.Errorf("invalid volume mapping %q", raw)
		}
		if len(parts) == 3 && parts[2] != "ro" {
			return protocol.RunRequest{}, fmt.Errorf("invalid volume mode in %q", raw)
		}
		mounts = append(mounts, protocol.Mount{Source: p.volumeName(parts[0]), Target: parts[1], ReadOnly: len(parts) == 3})
	}
	image := svc.Image
	if image == "" {
		image = "okestra-" + p.Name + "-" + name + ":local"
	}
	req := protocol.RunRequest{Image: image, Name: p.containerName(name), Command: svc.Command, Env: env, WorkingDir: svc.WorkingDir, AutoForward: ports, Network: p.networkName(), NetworkAlias: name, Mounts: mounts, Restart: svc.Restart, Health: svc.Health, Labels: map[string]string{"dev.okestra.project": p.Name, "dev.okestra.service": name, "dev.okestra.ports": strings.Join(svc.Ports, ",")}}
	if req.Restart == "" {
		req.Restart = "unless-stopped"
	}
	if err := req.Validate(); err != nil {
		return protocol.RunRequest{}, fmt.Errorf("service %s: %w", name, err)
	}
	return req, nil
}

func localProjectPath(base, path string) (string, error) {
	if filepath.IsAbs(path) {
		return "", fmt.Errorf("project path %q must be relative", path)
	}
	joined := filepath.Join(base, path)
	rel, err := filepath.Rel(base, joined)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("project path %q escapes the project directory", path)
	}
	realBase, err := filepath.EvalSymlinks(base)
	if err != nil {
		return "", err
	}
	realPath, err := filepath.EvalSymlinks(joined)
	if err != nil {
		return "", err
	}
	rel, err = filepath.Rel(realBase, realPath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("project path %q escapes the project directory via symlink", path)
	}
	return realPath, nil
}

func runProjectInit(args []string, stdout, stderr io.Writer) int {
	if len(args) != 0 {
		fmt.Fprintln(stderr, "usage: okestra project init")
		return 1
	}
	const file = "okestra.json"
	if _, err := os.Stat(file); err == nil {
		fmt.Fprintln(stderr, "okestra.json already exists")
		return 1
	} else if !os.IsNotExist(err) {
		fmt.Fprintln(stderr, err)
		return 1
	}
	name := filepath.Base(mustGetwd())
	name = strings.ToLower(name)
	name = regexp.MustCompile(`[^a-z0-9-]+`).ReplaceAllString(name, "-")
	name = strings.Trim(name, "-")
	if len(name) > 48 {
		name = strings.TrimRight(name[:48], "-")
	}
	if name == "" {
		name = "my-project"
	}
	project := Project{Name: name, Services: map[string]ProjectService{"app": {Build: &ProjectBuild{Context: "."}, Ports: []string{"8080:8080"}}}}
	data, _ := json.MarshalIndent(project, "", "  ")
	data = append(data, '\n')
	if err := os.WriteFile(file, data, 0o644); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintln(stdout, "created okestra.json; edit image/build and ports, then run okestra up")
	return 0
}

func mustGetwd() string { dir, _ := os.Getwd(); return dir }

func runProjectUp(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("up", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	var rebuild, recreate bool
	var onlyService string
	fs.StringVar(&file, "f", "okestra.json", "project manifest")
	fs.BoolVar(&rebuild, "build", false, "rebuild local images")
	fs.BoolVar(&recreate, "recreate", false, "replace existing containers")
	fs.StringVar(&onlyService, "service", "", "operate on one service")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra up [-f okestra.json] [--build] [--recreate]")
		return 1
	}
	project, base, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	if onlyService != "" {
		if _, exists := project.Services[onlyService]; !exists {
			fmt.Fprintf(stderr, "unknown service %s\n", onlyService)
			return 1
		}
		order = []string{onlyService}
	}
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if status, err := api.Status(ctx); err != nil || status.ProtocolVersion != protocol.ProtocolVersion {
		fmt.Fprintln(stderr, "service protocol is incompatible or unreachable; upgrade the service first")
		return 1
	}
	// Reserve every local port before any remote mutation. The listeners are
	// released after preflight; persistent ownership is handled by connect.
	var reserved []netListenerGroup
	defer func() {
		for _, g := range reserved {
			closeListeners(g)
		}
	}()
	seen := map[int]bool{}
	connected, connectedErr := queryForward(forwardSocket(project.Name), "status")
	if connectedErr == nil && connected.Endpoint != profile.URL {
		fmt.Fprintf(stderr, "project %s is connected to a different server; disconnect it before switching\n", project.Name)
		return 1
	}
	for _, name := range order {
		for _, raw := range project.Services[name].Ports {
			ports, _ := parsePortMappings([]string{raw})
			port := ports[0].LocalPort
			if seen[port] {
				fmt.Fprintf(stderr, "local port %d is declared twice\n", port)
				return 1
			}
			seen[port] = true
			if connectedErr == nil {
				owned := false
				for _, item := range connected.Ports {
					if strings.HasPrefix(item, fmt.Sprintf("localhost:%d ->", port)) {
						owned = true
						break
					}
				}
				if owned {
					continue
				}
			}
			group, err := listenLoopbackPort(port)
			if err != nil {
				fmt.Fprintf(stderr, "local port %d is occupied: %v\n", port, err)
				return 1
			}
			reserved = append(reserved, group)
		}
	}
	prepared := make(map[string]protocol.RunRequest, len(order))
	for _, name := range order {
		svc := project.Services[name]
		req, err := project.runRequest(name, svc, base)
		if err != nil {
			fmt.Fprintf(stderr, "project: %v\n", err)
			return 1
		}
		prepared[name] = req
		if svc.Build != nil {
			contextDir, err := localProjectPath(base, svc.Build.Context)
			if err != nil {
				fmt.Fprintf(stderr, "build %s: %v\n", name, err)
				return 1
			}
			dockerfile := svc.Build.Dockerfile
			if dockerfile == "" {
				dockerfile = "Dockerfile"
			}
			if err := validateBuildContext(contextDir, dockerfile); err != nil {
				fmt.Fprintf(stderr, "build %s: %v\n", name, err)
				return 1
			}
		}
	}
	existing, err := api.ListContainers(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "containers: %v\n", err)
		return 1
	}
	byName := map[string]protocol.ContainerSummary{}
	for _, item := range existing {
		byName[item.Name] = item
	}
	for _, name := range order {
		req := prepared[name]
		if _, found := byName[req.Name]; !found {
			continue
		}
		detail, err := api.InspectContainer(ctx, req.Name)
		if err != nil {
			fmt.Fprintf(stderr, "inspect %s: %v\n", name, err)
			return 1
		}
		if detail.Labels["dev.okestra.project"] != project.Name || detail.Labels["dev.okestra.service"] != name {
			fmt.Fprintf(stderr, "container %s exists but is not owned by this Okestra project\n", req.Name)
			return 1
		}
	}
	if err := api.EnsureNetwork(ctx, project.networkName()); err != nil {
		fmt.Fprintf(stderr, "network: %v\n", err)
		return 1
	}
	for _, name := range order {
		svc := project.Services[name]
		req := prepared[name]
		for _, mount := range req.Mounts {
			if err := api.EnsureVolume(ctx, mount.Source); err != nil {
				fmt.Fprintf(stderr, "volume %s: %v\n", mount.Source, err)
				return 1
			}
		}
		if old, found := byName[req.Name]; found && !rebuild && !recreate {
			if strings.HasPrefix(old.Status, "Up") {
				if svc.Health != nil {
					if err := waitProjectService(ctx, api, req.Name, true, false); err != nil {
						fmt.Fprintf(stderr, "%s: %v\n", name, err)
						return 1
					}
				}
				fmt.Fprintf(stdout, "%s: already running\n", name)
				continue
			}
			if err := api.StartContainer(ctx, req.Name); err != nil {
				fmt.Fprintf(stderr, "start %s: %v\n", name, err)
				return 1
			}
			fmt.Fprintf(stdout, "%s: started\n", name)
			if err := waitProjectService(ctx, api, req.Name, svc.Health != nil, false); err != nil {
				fmt.Fprintf(stderr, "%s: %v. Run: okestra why %s\n", name, err, req.Name)
				return 1
			}
			continue
		}
		if svc.Build != nil {
			contextDir, err := localProjectPath(base, svc.Build.Context)
			if err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
			dockerfile := svc.Build.Dockerfile
			if dockerfile == "" {
				dockerfile = "Dockerfile"
			}
			reader, err := OpenBuildContext(contextDir, dockerfile)
			if err != nil {
				fmt.Fprintf(stderr, "build %s: %v\n", name, err)
				return 1
			}
			opID, err := api.Build(ctx, protocol.BuildRequest{Tag: req.Image, Dockerfile: dockerfile, BuildArgs: svc.Build.Args}, reader)
			reader.Close()
			if err != nil {
				fmt.Fprintf(stderr, "build %s: %v\n", name, err)
				return 1
			}
			fmt.Fprintf(stdout, "building %s...\n", name)
			if err := api.StreamOperation(ctx, opID, func(env protocol.StreamEnvelope) error {
				if len(env.Data) > 0 {
					_, _ = stdout.Write(env.Data)
				}
				if env.Type == "error" {
					return errors.New(env.Message)
				}
				return nil
			}); err != nil {
				fmt.Fprintf(stderr, "build %s: %v\n", name, err)
				return 1
			}
		}
		if _, found := byName[req.Name]; found {
			if strings.HasPrefix(byName[req.Name].Status, "Up") {
				if err := api.StopContainer(ctx, req.Name); err != nil {
					fmt.Fprintf(stderr, "stop %s: %v\n", name, err)
					return 1
				}
			}
			if err := api.RemoveContainer(ctx, req.Name); err != nil {
				fmt.Fprintf(stderr, "replace %s: %v\n", name, err)
				return 1
			}
		}
		if _, err := api.RunContainer(ctx, req); err != nil {
			fmt.Fprintf(stderr, "run %s: %v\n", name, err)
			return 1
		}
		fmt.Fprintf(stdout, "%s: created\n", name)
		// Docker run -d can succeed before an application crashes. Surface that
		// state here rather than suggesting that a dead service is ready.
		if err := waitProjectService(ctx, api, req.Name, svc.Health != nil, true); err != nil {
			fmt.Fprintf(stderr, "%s: %v. Run: okestra why %s\n", name, err, req.Name)
			return 1
		}
	}
	allOrder, _ := project.validate()
	if connectedErr == nil && sameForwardPorts(connected.Ports, projectForwardPorts(project, allOrder)) {
		fmt.Fprintf(stdout, "project %s is up; local forwards are active.\n", project.Name)
	} else {
		fmt.Fprintf(stdout, "project %s is up. Run `okestra connect` to expose or refresh its local ports.\n", project.Name)
	}
	return 0
}

func waitProjectService(ctx context.Context, api *API, name string, expectHealth, newContainer bool) error {
	deadline := time.Now().Add(45 * time.Second)
	started := time.Now()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
		detail, err := api.InspectContainer(ctx, name)
		if err != nil {
			return err
		}
		if !detail.Running {
			return fmt.Errorf("exited with code %d", detail.ExitCode)
		}
		if !expectHealth && newContainer && detail.RestartCount > 0 {
			return fmt.Errorf("restarted %d times during startup", detail.RestartCount)
		}
		if !expectHealth && newContainer && time.Since(started) < 2*time.Second {
			continue
		}
		if !expectHealth || detail.Health == "healthy" {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("health check did not pass (status %s)", detail.Health)
		}
	}
}

type netListenerGroup = []net.Listener

func runProjectDown(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("down", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	fs.StringVar(&file, "f", "okestra.json", "project manifest")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra down [-f okestra.json]")
		return 1
	}
	project, _, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	items, err := api.ListContainers(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "containers: %v\n", err)
		return 1
	}
	byName := map[string]bool{}
	for _, item := range items {
		byName[item.Name] = true
	}
	for _, service := range order {
		name := project.containerName(service)
		if !byName[name] {
			continue
		}
		detail, err := api.InspectContainer(ctx, name)
		if err != nil {
			fmt.Fprintf(stderr, "inspect %s: %v\n", name, err)
			return 1
		}
		if detail.Labels["dev.okestra.project"] != project.Name || detail.Labels["dev.okestra.service"] != service {
			fmt.Fprintf(stderr, "container %s is not owned by this project\n", name)
			return 1
		}
	}
	if connected, err := queryForward(forwardSocket(project.Name), "status"); err == nil && connected.Endpoint == profile.URL {
		_, _ = queryForward(forwardSocket(project.Name), "shutdown")
		fmt.Fprintf(stdout, "disconnected %s\n", project.Name)
	}
	for i := len(order) - 1; i >= 0; i-- {
		name := project.containerName(order[i])
		if !byName[name] {
			continue
		}
		detail, err := api.InspectContainer(ctx, name)
		if err != nil {
			fmt.Fprintf(stderr, "inspect %s: %v\n", name, err)
			return 1
		}
		if detail.Labels["dev.okestra.project"] != project.Name || detail.Labels["dev.okestra.service"] != order[i] {
			fmt.Fprintf(stderr, "container %s ownership changed; refusing removal\n", name)
			return 1
		}
		if detail.Running {
			if err := api.StopContainer(ctx, name); err != nil {
				fmt.Fprintf(stderr, "stop %s: %v\n", name, err)
				return 1
			}
		}
		if err := api.RemoveContainer(ctx, name); err != nil {
			fmt.Fprintf(stderr, "remove %s: %v\n", name, err)
			return 1
		}
		fmt.Fprintf(stdout, "removed %s\n", name)
	}
	if err := api.RemoveNetwork(ctx, project.networkName()); err != nil {
		fmt.Fprintf(stderr, "network removal: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "project stopped; named volumes were kept")
	return 0
}

func runProjectPS(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("project ps", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	fs.StringVar(&file, "f", "okestra.json", "project manifest")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra project ps [-f okestra.json]")
		return 1
	}
	project, _, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	items, err := api.ListContainers(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "containers: %v\n", err)
		return 1
	}
	byName := map[string]protocol.ContainerSummary{}
	for _, item := range items {
		byName[item.Name] = item
	}
	for _, name := range order {
		item, ok := byName[project.containerName(name)]
		if !ok {
			fmt.Fprintf(stdout, "%s\tmissing\n", name)
		} else {
			fmt.Fprintf(stdout, "%s\t%s\t%s\n", name, item.Status, item.Image)
		}
	}
	return 0
}

func runWhy(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: okestra why <container>")
		return 1
	}
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	d, err := api.InspectContainerWithLogs(ctx, args[0])
	if err != nil {
		fmt.Fprintf(stderr, "inspect: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "container: %s\nimage: %s\nstate: %s\nexit_code: %d\nrestarts: %d\n", d.Name, d.Image, d.Status, d.ExitCode, d.RestartCount)
	if d.Health != "" {
		fmt.Fprintf(stdout, "health: %s\n", d.Health)
	}
	if d.Error != "" {
		fmt.Fprintf(stdout, "docker_error: %s\n", d.Error)
	}
	if len(d.Networks) > 0 {
		fmt.Fprintf(stdout, "networks: %s\n", strings.Join(d.Networks, ", "))
	}
	if len(d.Ports) > 0 {
		fmt.Fprintf(stdout, "container_ports: %s\n", strings.Join(d.Ports, ", "))
	}
	if ports := d.Labels["dev.okestra.ports"]; ports != "" {
		fmt.Fprintf(stdout, "local_forward_mappings: %s\n", ports)
		if project := d.Labels["dev.okestra.project"]; project != "" {
			if status, err := queryForward(forwardSocket(project), "status"); err == nil {
				fmt.Fprintf(stdout, "local_forward: active (%s)\n", status.Endpoint)
			} else {
				fmt.Fprintln(stdout, "local_forward: not connected; run okestra connect from the project directory")
			}
		}
	}
	if d.OOMKilled {
		fmt.Fprintln(stdout, "hint: Docker killed the process for exceeding available memory.")
	}
	if !d.Running && d.ExitCode != 0 {
		fmt.Fprintln(stdout, "hint: the application exited. Check required environment variables and the logs below.")
	}
	logsLower := strings.ToLower(d.RecentLogs)
	if strings.Contains(logsLower, "econnrefused") || strings.Contains(logsLower, "connection refused") {
		fmt.Fprintln(stdout, "hint: a dependency refused a connection; verify its service health and use its project DNS name.")
	}
	if strings.Contains(logsLower, "enotfound") || strings.Contains(logsLower, "name or service not known") {
		fmt.Fprintln(stdout, "hint: DNS lookup failed; sibling services resolve by their service names on the project network.")
	}
	if d.Running && d.Health == "unhealthy" {
		fmt.Fprintln(stdout, "hint: the process is running, but its health check is failing.")
	}
	if d.RecentLogs != "" {
		fmt.Fprintln(stdout, "recent logs:")
		fmt.Fprint(stdout, d.RecentLogs)
		if !strings.HasSuffix(d.RecentLogs, "\n") {
			fmt.Fprintln(stdout)
		}
	}
	return 0
}
