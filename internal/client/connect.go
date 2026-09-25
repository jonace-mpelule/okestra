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
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

type forwardStatus struct {
	Project  string   `json:"project"`
	Endpoint string   `json:"endpoint"`
	Ports    []string `json:"ports"`
	PID      int      `json:"pid"`
}

func forwardDir() string                  { return filepath.Join(filepath.Dir(DefaultConfigPath()), "forwards") }
func forwardSocket(project string) string { return filepath.Join(forwardDir(), project+".sock") }

func runConnect(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("connect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	fs.StringVar(&file, "f", "okestra.json", "project manifest")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra connect [-f okestra.json]")
		return 1
	}
	p, _, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	portCount := 0
	for _, svc := range p.Services {
		portCount += len(svc.Ports)
	}
	if portCount == 0 {
		fmt.Fprintln(stderr, "project has no ports to connect")
		return 1
	}
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	status, err := api.Status(ctx)
	if err != nil || status.ProtocolVersion != protocol.ProtocolVersion {
		fmt.Fprintln(stderr, "service unavailable or incompatible; upgrade service first")
		return 1
	}
	if old, err := queryForward(forwardSocket(p.Name), "status"); err == nil {
		if old.Endpoint != profile.URL {
			fmt.Fprintf(stderr, "project %s is already connected to %s; disconnect before switching servers\n", p.Name, old.Endpoint)
			return 1
		}
		if sameForwardPorts(old.Ports, projectForwardPorts(p, order)) {
			fmt.Fprintf(stdout, "already connected: %s (%s)\n", p.Name, old.Endpoint)
			return 0
		}
		oldLocals := map[int]bool{}
		for _, mapping := range old.Ports {
			left, _, ok := strings.Cut(mapping, " ->")
			if !ok {
				continue
			}
			port, err := strconv.Atoi(strings.TrimPrefix(left, "localhost:"))
			if err == nil {
				oldLocals[port] = true
			}
		}
		var checked [][]net.Listener
		for _, name := range order {
			if len(p.Services[name].Ports) == 0 {
				continue
			}
			detail, err := api.InspectContainer(ctx, p.containerName(name))
			if err != nil || !detail.Running {
				for _, group := range checked {
					closeListeners(group)
				}
				fmt.Fprintf(stderr, "service %s is not running; run okestra up before refreshing ports\n", name)
				return 1
			}
			for _, raw := range p.Services[name].Ports {
				mappings, _ := parsePortMappings([]string{raw})
				port := mappings[0].LocalPort
				if oldLocals[port] {
					continue
				}
				group, err := listenLoopbackPort(port)
				if err != nil {
					for _, g := range checked {
						closeListeners(g)
					}
					fmt.Fprintf(stderr, "local port %d is occupied: %v\n", port, err)
					return 1
				}
				checked = append(checked, group)
			}
		}
		for _, group := range checked {
			closeListeners(group)
		}
		if _, err := queryForward(forwardSocket(p.Name), "shutdown"); err != nil {
			fmt.Fprintf(stderr, "reload forward: %v\n", err)
			return 1
		}
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Lstat(forwardSocket(p.Name)); os.IsNotExist(err) {
				break
			}
			select {
			case <-ctx.Done():
				return 1
			case <-time.After(100 * time.Millisecond):
			}
		}
		if _, err := os.Lstat(forwardSocket(p.Name)); err == nil {
			fmt.Fprintln(stderr, "old forward did not close; try okestra disconnect")
			return 1
		}
	}
	if err := os.MkdirAll(forwardDir(), 0o700); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	// A stale socket may remain after a crash, but an active socket is never removed.
	if _, err := os.Lstat(forwardSocket(p.Name)); err == nil {
		if err := os.Remove(forwardSocket(p.Name)); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	abs, err := filepath.Abs(file)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	logPath := filepath.Join(forwardDir(), p.Name+".log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer logFile.Close()
	child := exec.Command(exe, "__forward", "-f", abs)
	child.Stdout = logFile
	child.Stderr = logFile
	child.Stdin = nil
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		fmt.Fprintf(stderr, "start forward: %v\n", err)
		return 1
	}
	_ = child.Process.Release()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		status, err := queryForward(forwardSocket(p.Name), "status")
		if err == nil {
			if status.Endpoint != profile.URL {
				_, _ = queryForward(forwardSocket(p.Name), "shutdown")
				fmt.Fprintln(stderr, "another server owns this project's forward; disconnect it first")
				return 1
			}
			fmt.Fprintf(stdout, "connected %s to %s (PID %d)\n", p.Name, status.Endpoint, status.PID)
			for _, port := range status.Ports {
				fmt.Fprintf(stdout, "%s\n", port)
			}
			return 0
		}
		select {
		case <-ctx.Done():
			return 1
		case <-time.After(100 * time.Millisecond):
		}
	}
	fmt.Fprintf(stderr, "forward did not start; inspect %s\n", logPath)
	return 1
}

func projectForwardPorts(p Project, order []string) []string {
	var out []string
	for _, name := range order {
		for _, raw := range p.Services[name].Ports {
			ports, _ := parsePortMappings([]string{raw})
			pm := ports[0]
			out = append(out, fmt.Sprintf("localhost:%d -> %s:%d", pm.LocalPort, name, pm.RemotePort))
		}
	}
	return out
}

func sameForwardPorts(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]string(nil), a...)
	b = append([]string(nil), b...)
	sort.Strings(a)
	sort.Strings(b)
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func runDisconnect(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("disconnect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	fs.StringVar(&file, "f", "okestra.json", "project manifest")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra disconnect [-f okestra.json]")
		return 1
	}
	p, _, _, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	if _, err := queryForward(forwardSocket(p.Name), "shutdown"); err != nil {
		fmt.Fprintf(stderr, "not connected: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "disconnected %s\n", p.Name)
	return 0
}

func runConnections(stdout, stderr io.Writer) int {
	files, err := filepath.Glob(filepath.Join(forwardDir(), "*.sock"))
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	for _, file := range files {
		status, err := queryForward(file, "status")
		if err == nil {
			fmt.Fprintf(stdout, "%s\t%s\t%s\n", status.Project, status.Endpoint, strings.Join(status.Ports, ", "))
		}
	}
	return 0
}

func queryForward(socket, command string) (forwardStatus, error) {
	conn, err := net.DialTimeout("unix", socket, 500*time.Millisecond)
	if err != nil {
		return forwardStatus{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	if _, err := io.WriteString(conn, command+"\n"); err != nil {
		return forwardStatus{}, err
	}
	var status forwardStatus
	if err := json.NewDecoder(conn).Decode(&status); err != nil {
		return forwardStatus{}, err
	}
	return status, nil
}

func runForwardDaemon(ctx context.Context, cfg *Config, args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("__forward", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var file string
	fs.StringVar(&file, "f", "", "project manifest")
	if err := fs.Parse(args); err != nil || file == "" {
		return 1
	}
	p, _, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	profile, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	if err := os.MkdirAll(forwardDir(), 0o700); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	socket := forwardSocket(p.Name)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer func() { listener.Close(); os.Remove(socket) }()
	_ = os.Chmod(socket, 0o600)
	forwardCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var forwards []*PortForward
	var groups [][]net.Listener
	defer func() {
		for _, f := range forwards {
			f.Close()
		}
		for _, g := range groups {
			closeListeners(g)
		}
	}()
	var ports []string
	for _, name := range order {
		for _, raw := range p.Services[name].Ports {
			detail, err := api.InspectContainer(forwardCtx, p.containerName(name))
			if err != nil || !detail.Running {
				fmt.Fprintf(stderr, "service %s is not running; run okestra up first\n", name)
				return 1
			}
			mappings, _ := parsePortMappings([]string{raw})
			mapping := mappings[0]
			group, err := listenLoopbackPort(mapping.LocalPort)
			if err != nil {
				fmt.Fprintf(stderr, "port %d: %v\n", mapping.LocalPort, err)
				return 1
			}
			groups = append(groups, group)
			f, err := OpenPortForward(forwardCtx, api, protocol.PortForwardRequest{ContainerID: p.containerName(name), LocalPort: mapping.LocalPort, RemotePort: mapping.RemotePort}, group...)
			if err != nil {
				fmt.Fprintf(stderr, "forward %s: %v\n", name, err)
				return 1
			}
			forwards = append(forwards, f)
			ports = append(ports, fmt.Sprintf("localhost:%d -> %s:%d", mapping.LocalPort, name, mapping.RemotePort))
		}
	}
	status := forwardStatus{Project: p.Name, Endpoint: profile.URL, Ports: ports, PID: os.Getpid()}
	var once sync.Once
	go func() { <-forwardCtx.Done(); listener.Close() }()
	for _, f := range forwards {
		go func(forward *PortForward) {
			err := forward.Serve(forwardCtx)
			if forwardCtx.Err() == nil {
				if err == nil {
					err = errors.New("listener closed unexpectedly")
				}
				fmt.Fprintf(stderr, "forward stopped: %v\n", err)
				once.Do(cancel)
			}
		}(f)
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			if forwardCtx.Err() != nil {
				return 0
			}
			fmt.Fprintln(stderr, err)
			return 1
		}
		go func(c net.Conn) {
			defer c.Close()
			_ = c.SetDeadline(time.Now().Add(2 * time.Second))
			var command string
			_, _ = fmt.Fscanln(c, &command)
			_ = json.NewEncoder(c).Encode(status)
			if command == "shutdown" {
				once.Do(cancel)
			}
		}(conn)
	}
}
