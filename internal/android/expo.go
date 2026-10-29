package android

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gorilla/websocket"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ExpoOptions describes development builds only; Expo Go is never a launch target.
type ExpoOptions struct {
	PackageManager string            `json:"package_manager,omitempty"`
	Port           int               `json:"port,omitempty"`
	Environment    map[string]string `json:"environment,omitempty"`
}

func (o ExpoOptions) Validate() error {
	if o.PackageManager != "" && o.PackageManager != "npm" && o.PackageManager != "pnpm" && o.PackageManager != "yarn" && o.PackageManager != "bun" {
		return errors.New("expo.package_manager must be npm, pnpm, yarn or bun")
	}
	if o.Port != 0 && (o.Port < 1024 || o.Port > 65535) {
		return errors.New("expo.port must be between 1024 and 65535")
	}
	if len(o.Environment) > 128 {
		return errors.New("Expo environment exceeds 128 keys")
	}
	total := 0
	for k, v := range o.Environment {
		total += len(k) + len(v)
		if total > 48*1024 {
			return errors.New("Expo launch environment exceeds 48 KiB")
		}
		if !envName.MatchString(k) || len(v) > 32768 {
			return errors.New("invalid Expo environment")
		}
		if k == "PATH" || k == "HOME" || k == "CI" || k == "NODE_ENV" || k == "NODE_OPTIONS" || strings.HasPrefix(k, "ADB") || strings.HasPrefix(k, "ANDROID") || strings.HasPrefix(k, "EXPO_PACKAGER") || k == "REACT_NATIVE_PACKAGER_HOSTNAME" || k == "RCT_METRO_PORT" {
			return fmt.Errorf("environment key %s is managed by Okestra", k)
		}
	}
	return nil
}

var envName = regexpEnv()

func regexpEnv() *regexp.Regexp { return regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`) }

type expoPackage struct {
	Dependencies    map[string]string `json:"dependencies"`
	DevDependencies map[string]string `json:"devDependencies"`
	PackageManager  string            `json:"packageManager"`
}

func validateExpoPackage(dir string) (expoPackage, error) {
	var p expoPackage
	b, e := os.ReadFile(filepath.Join(dir, "package.json"))
	if e != nil {
		return p, e
	}
	if e = json.Unmarshal(b, &p); e != nil {
		return p, fmt.Errorf("package.json: %w", e)
	}
	for _, name := range []string{"expo", "expo-dev-client", "react-native"} {
		if p.Dependencies[name] == "" && p.DevDependencies[name] == "" {
			return p, fmt.Errorf("Expo development builds require %s in package.json; add expo-dev-client locally with expo install before syncing", name)
		}
	}
	return p, nil
}
func expoInstall(dir string, opts ExpoOptions, pkg expoPackage) (string, []string, string, error) {
	locks := map[string]string{"package-lock.json": "npm", "npm-shrinkwrap.json": "npm", "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "bun.lock": "bun", "bun.lockb": "bun"}
	found := map[string]string{}
	for file, manager := range locks {
		if _, e := os.Stat(filepath.Join(dir, file)); e == nil {
			found[manager] = file
		}
	}
	manager := opts.PackageManager
	if manager == "" {
		if len(found) != 1 {
			return "", nil, "", errors.New("include exactly one package-manager lockfile or set expo.package_manager")
		}
		for k := range found {
			manager = k
		}
	}
	lock := found[manager]
	if lock == "" {
		return "", nil, "", fmt.Errorf("include a committed %s lockfile for reproducible dependency installation", manager)
	}
	if pkg.PackageManager != "" && strings.Split(pkg.PackageManager, "@")[0] != manager {
		return "", nil, "", errors.New("expo.package_manager conflicts with package.json packageManager")
	}
	args := []string{"install", "--frozen-lockfile"}
	if manager == "npm" {
		args = []string{"ci", "--include=dev", "--no-audit", "--no-fund"}
	}
	if manager == "yarn" {
		major := "1"
		if parts := strings.Split(pkg.PackageManager, "@"); len(parts) == 2 {
			major = strings.Split(parts[1], ".")[0]
		}
		if major != "1" {
			args = []string{"install", "--immutable"}
		}
	}
	return manager, args, lock, nil
}
func (m *Manager) RunProject(name, target, framework string, opts ExpoOptions) error {
	switch framework {
	case "", "flutter":
		return m.Run(name, target)
	case "expo":
		return m.RunExpo(name, opts)
	default:
		return errors.New("framework must be flutter or expo (development builds)")
	}
}
func (m *Manager) RunExpo(name string, opts ExpoOptions) error {
	if !Name.MatchString(name) || name == "device" {
		return errors.New("invalid workspace name")
	}
	if e := opts.Validate(); e != nil {
		return e
	}
	if opts.Port == 0 {
		opts.Port = 8081
	}
	dir := filepath.Join(m.root, name, "source")
	pkg, e := validateExpoPackage(dir)
	if e != nil {
		return e
	}
	manager, args, lock, e := expoInstall(dir, opts, pkg)
	if e != nil {
		return e
	}
	for _, bin := range []string{"node", manager} {
		if _, e := exec.LookPath(tool(bin)); e != nil {
			return fmt.Errorf("server needs %s; rerun Android setup or install the project's package manager for the service account", bin)
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if !active(m.device) {
		return errors.New("start the managed emulator first")
	}
	for n, p := range m.sessions {
		if active(p) {
			return fmt.Errorf("device in use by workspace %s; stop its session first", n)
		}
	}
	listener, e := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(opts.Port)))
	if e != nil {
		return fmt.Errorf("Metro port is occupied: %w", e)
	}
	listener.Close()
	// Copy launch environment; handlers may reuse their request object after return.
	env := map[string]string{}
	for k, v := range opts.Environment {
		env[k] = v
	}
	opts.Environment = env
	ctx, cancel := context.WithCancel(context.Background())
	p := &process{kind: "expo", state: "installing", cancel: cancel, done: make(chan struct{}), expo: opts}
	m.sessions[name] = p
	go m.expoJob(ctx, cancel, p, name, dir, manager, args, lock)
	return nil
}
func (m *Manager) appendLog(p *process, b []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p.log = append(p.log, b...)
	if len(p.log) > 128*1024 {
		p.log = append([]byte(nil), p.log[len(p.log)-128*1024:]...)
	}
}

type expoLog struct {
	m *Manager
	p *process
}

func (w expoLog) Write(b []byte) (int, error) { w.m.appendLog(w.p, b); return len(b), nil }
func expoEnvironment(opts ExpoOptions) []string {
	values := map[string]string{}
	for _, v := range os.Environ() {
		k, value, ok := strings.Cut(v, "=")
		if ok {
			values[k] = value
		}
	}
	for k, v := range opts.Environment {
		values[k] = v
	}
	values["CI"] = "1"
	values["NODE_ENV"] = "development"
	values["EXPO_NO_TELEMETRY"] = "1"
	delete(values, "EXPO_OFFLINE")
	values["ANDROID_SERIAL"] = "emulator-5554"
	delete(values, "ADB_SERVER_SOCKET")
	delete(values, "EXPO_PACKAGER_PROXY_URL")
	delete(values, "REACT_NATIVE_PACKAGER_HOSTNAME")
	delete(values, "RCT_METRO_PORT")
	delete(values, "NODE_OPTIONS")
	path := filepath.Dir(tool("node")) + string(os.PathListSeparator) + values["PATH"]
	if sdk := values["ANDROID_HOME"]; sdk != "" {
		path = filepath.Join(sdk, "platform-tools") + string(os.PathListSeparator) + path
	}
	values["PATH"] = path
	var env []string
	for k, v := range values {
		env = append(env, k+"="+v)
	}
	return env
}
func (m *Manager) expoStep(ctx context.Context, p *process, dir, phase, name string, args ...string) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	if phase == "installing" || phase == "building" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 60*time.Minute)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, tool(name), args...)
	cmd.Dir = dir
	cmd.Env = expoEnvironment(p.expo)
	if phase == "starting" && name == "node" {
		cmd.Env = append(cmd.Env, "EXPO_OFFLINE=1")
	}
	cmd.SysProcAttr = processAttributes()
	cmd.Stdout = expoLog{m, p}
	cmd.Stderr = cmd.Stdout
	cmd.WaitDelay = 3 * time.Second
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			killProcess(cmd)
		}
		return nil
	}
	m.mu.Lock()
	if ctx.Err() != nil {
		m.mu.Unlock()
		return ctx.Err()
	}
	p.state = phase
	p.cmd = cmd
	e := cmd.Start()
	m.mu.Unlock()
	if e != nil {
		return e
	}
	e = cmd.Wait()
	m.mu.Lock()
	p.cmd = nil
	m.mu.Unlock()
	return e
}
func dependencyFingerprint(dir, lock string) string {
	h := sha256.New()
	if path, e := exec.LookPath(tool("node")); e == nil {
		if stat, e := os.Stat(path); e == nil {
			_, _ = fmt.Fprintf(h, "node:%s:%d:%d", path, stat.Size(), stat.ModTime().UnixNano())
		}
	}
	for _, folder := range []string{"patches", "modules"} {
		_ = filepath.WalkDir(filepath.Join(dir, folder), func(path string, d os.DirEntry, e error) error {
			if e == nil && !d.IsDir() {
				if b, e := os.ReadFile(path); e == nil {
					_, _ = io.WriteString(h, path)
					_, _ = h.Write(b)
				}
			}
			return nil
		})
	}
	for _, path := range []string{"package.json", lock, ".npmrc", ".yarnrc.yml"} {
		b, e := os.ReadFile(filepath.Join(dir, path))
		if e == nil {
			_, _ = io.WriteString(h, path+"\x00")
			_, _ = h.Write(b)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}
func (m *Manager) expoJob(ctx context.Context, cancel context.CancelFunc, p *process, name, dir, manager string, args []string, lock string) {
	var jobErr error
	defer func() {
		cancel()
		_ = m.removeReverse(p.expo.Port)
		m.mu.Lock()
		if p.state == "stopping" {
			p.state = "stopped"
		} else {
			p.state = "failed"
			p.log = append(p.log, []byte(fmt.Sprintf("\nExpo session ended: %v\n", jobErr))...)
		}
		close(p.done)
		m.mu.Unlock()
	}()
	fail := func(e error) bool {
		if e != nil {
			jobErr = e
			return true
		}
		return false
	}
	stamp := filepath.Join(m.root, name, "expo-dependencies")
	fingerprint := dependencyFingerprint(dir, lock)
	old, _ := os.ReadFile(stamp)
	cli := filepath.Join(dir, "node_modules", "expo", "bin", "cli")
	if _, e := os.Stat(cli); e != nil || string(old) != fingerprint {
		m.appendLog(p, []byte("Installing locked Expo dependencies…\n"))
		if fail(m.expoStep(ctx, p, dir, "installing", manager, args...)) {
			return
		}
		if fail(os.WriteFile(stamp, []byte(fingerprint), 0600)) {
			return
		}
	}
	if _, e := os.Stat(cli); e != nil {
		jobErr = errors.New("Expo CLI not found after install; use a node_modules linker and install expo in this workspace")
		return
	}
	var files map[string]bool
	b, _ := os.ReadFile(filepath.Join(m.root, name, "files.json"))
	_ = json.Unmarshal(b, &files)
	native := false
	for file := range files {
		if strings.HasPrefix(file, "android/") {
			native = true
		}
	}
	if !native {
		m.appendLog(p, []byte("Generating Android from Expo configuration…\n"))
		if fail(m.expoStep(ctx, p, dir, "building", "node", cli, "prebuild", "--platform", "android", "--no-install", "--clean")) {
			return
		}
	}
	port := strconv.Itoa(p.expo.Port)
	m.appendLog(p, []byte("Building and installing the Expo development client…\n"))
	if fail(m.expoStep(ctx, p, dir, "building", "node", cli, "run:android", "--device", "emulator-5554", "--no-bundler", "--port", port)) {
		return
	}
	if fail(m.expoStep(ctx, p, dir, "starting", "adb", "-s", "emulator-5554", "reverse", "tcp:"+port, "tcp:"+port)) {
		return
	}
	m.appendLog(p, []byte("Starting private Metro for the installed development build…\n"))
	go m.waitForMetro(ctx, cancel, p)
	jobErr = m.expoStep(ctx, p, dir, "starting", "node", cli, "start", "--dev-client", "--localhost", "--port", port, "--android")
}

var metroClient = &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}

func (m *Manager) waitForMetro(ctx context.Context, cancel context.CancelFunc, p *process) {
	deadline := time.NewTimer(120 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			m.appendLog(p, []byte("Metro did not become ready within 120 seconds.\n"))
			cancel()
			return
		case <-ticker.C:
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/status", p.expo.Port), nil)
			resp, e := metroClient.Do(req)
			if e != nil {
				continue
			}
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			if resp.StatusCode == 200 && strings.Contains(string(b), "packager-status:running") {
				m.mu.Lock()
				if p.state == "starting" {
					p.state = "running"
				}
				m.mu.Unlock()
				return
			}
		}
	}
}
func (m *Manager) removeReverse(port int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, e := output(ctx, "adb", "-s", "emulator-5554", "reverse", "--remove", "tcp:"+strconv.Itoa(port))
	return e
}
func (m *Manager) Restart(name string, opts *ExpoOptions) error {
	m.mu.Lock()
	p := m.sessions[name]
	isExpo := p != nil && p.kind == "expo"
	saved := ExpoOptions{}
	if isExpo {
		saved = p.expo
	}
	m.mu.Unlock()
	if !isExpo {
		return m.Reload(name, true)
	}
	if opts != nil {
		if e := opts.Validate(); e != nil {
			return e
		}
		saved = *opts
	}
	if e := m.Stop(name); e != nil {
		return e
	}
	return m.RunExpo(name, saved)
}
func (m *Manager) DevMenu(name string) error {
	m.mu.Lock()
	p := m.sessions[name]
	ready := active(p) && p.kind == "expo" && p.state == "running"
	port := 0
	if p != nil {
		port = p.expo.Port
	}
	m.mu.Unlock()
	if !ready {
		return errors.New("Expo development build is not running")
	}
	return metroCommand(port, "devMenu")
}

// Use Expo's version-2 command socket; an HTTP /reload endpoint is not assumed.
func metroCommand(port int, method string) error {
	if method != "reload" && method != "devMenu" {
		return errors.New("unsupported Metro command")
	}
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dialer := websocket.Dialer{HandshakeTimeout: 3 * time.Second}
	conn, _, e := dialer.DialContext(ctx, fmt.Sprintf("ws://127.0.0.1:%d/message", port), http.Header{"Origin": []string{base}})
	if e != nil {
		return fmt.Errorf("connect Metro command socket: %w", e)
	}
	defer conn.Close()
	conn.SetReadLimit(64 * 1024)
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_ = conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if e = conn.WriteJSON(map[string]any{"version": 2, "method": "getpeers", "target": "server", "id": "okestra-peers"}); e != nil {
		return e
	}
	for {
		var response struct {
			ID      any            `json:"id"`
			Result  map[string]any `json:"result"`
			Version int            `json:"version"`
		}
		if e = conn.ReadJSON(&response); e != nil {
			return fmt.Errorf("Metro command handshake: %w", e)
		}
		if response.ID == "okestra-peers" {
			if response.Version != 2 {
				return errors.New("unsupported Expo command-socket protocol")
			}
			if len(response.Result) == 0 {
				return errors.New("no app is connected to Metro yet; wait for the development build to load")
			}
			break
		}
	}
	return conn.WriteJSON(map[string]any{"version": 2, "method": method, "params": map[string]any{}})
}

// ExpoRebuildFile identifies native/dependency/config changes that cannot use Fast Refresh.
func ExpoRebuildFile(path string) bool {
	if strings.HasPrefix(path, "android/") || strings.HasPrefix(path, "plugins/") || strings.HasPrefix(path, "patches/") || strings.HasPrefix(path, "modules/") {
		return true
	}
	switch path {
	case "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "app.json", "app.config.js", "app.config.ts", "app.config.mjs", "app.config.cjs", "babel.config.js", "babel.config.cjs", "metro.config.js", "metro.config.cjs", ".npmrc", ".yarnrc.yml":
		return true
	}
	return false
}
