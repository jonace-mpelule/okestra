// Package android manages one trusted developer's Android emulator and Flutter/Expo development sessions.
package android

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"

	"strings"
	"sync"
	"time"
)

var Name = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,47}$`)

type Status struct {
	Profiles           []DeviceProfile   `json:"profiles"`
	ActiveProfile      string            `json:"active_profile"`
	ActiveAVD          string            `json:"active_avd"`
	DevelopmentEnabled bool              `json:"development_enabled"`
	Enabled            bool              `json:"enabled"`
	Device             string            `json:"device"`
	AVDs               []string          `json:"avds"`
	Checks             map[string]string `json:"checks"`
	Sessions           map[string]string `json:"sessions"`
}
type process struct {
	cmd          *exec.Cmd
	stdin        io.WriteCloser
	state, appID string
	kind         string
	cancel       context.CancelFunc
	expo         ExpoOptions
	log          []byte
	done         chan struct{}
}
type Manager struct {
	profilesMu      sync.Mutex
	deviceAVD       string
	deviceProfileID string
	mu              sync.Mutex
	root            string
	enabled         bool
	device          *process
	sessions        map[string]*process
}

func New(root string) *Manager {
	return &Manager{root: filepath.Join(root, "android"), enabled: os.Getenv("OKESTRA_ANDROID_ENABLED") == "1", sessions: map[string]*process{}}
}

// Graphics acceleration is distinct from KVM CPU acceleration. Keep the compatible
// software default unless the operator explicitly opts into a supported host GPU.
func graphicsMode() (string, error) {
	mode := strings.TrimSpace(os.Getenv("OKESTRA_ANDROID_GPU"))
	if mode == "" {
		mode = "swiftshader"
	}
	switch mode {
	case "swiftshader", "auto", "host", "software", "lavapipe", "swangle":
		return mode, nil
	default:
		return "", fmt.Errorf("unsupported OKESTRA_ANDROID_GPU %q; use swiftshader, auto, host, software, lavapipe or swangle", mode)
	}
}
func (m *Manager) Enabled() bool { return m.enabled }
func DevelopmentEnabled() bool   { return os.Getenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED") == "1" }
func tool(name string) string {
	if name == "avdmanager" {
		if sdk := os.Getenv("ANDROID_HOME"); sdk != "" {
			return filepath.Join(sdk, "cmdline-tools/latest/bin/avdmanager")
		}
	}
	if v := os.Getenv("OKESTRA_" + strings.ToUpper(name) + "_BIN"); v != "" {
		return v
	}
	if name == "adb" || name == "emulator" {
		sdk := os.Getenv("ANDROID_HOME")
		if sdk == "" {
			sdk = os.Getenv("ANDROID_SDK_ROOT")
		}
		if sdk != "" {
			sub := "platform-tools"
			if name == "emulator" {
				sub = "emulator"
			}
			return filepath.Join(sdk, sub, name)
		}
	}
	if name == "node" {
		if p := "/var/lib/okestra/node/bin/node"; fileExists(p) {
			return p
		}
	}
	if name == "npm" || name == "pnpm" || name == "yarn" || name == "bun" {
		if node := tool("node"); filepath.IsAbs(node) {
			if p := filepath.Join(filepath.Dir(node), name); fileExists(p) {
				return p
			}
		}
	}
	return name
}
func fileExists(path string) bool { st, e := os.Stat(path); return e == nil && st.Mode()&0111 != 0 }
func output(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	b, e := exec.CommandContext(ctx, tool(name), args...).CombinedOutput()
	return strings.TrimSpace(string(b)), e
}
func (m *Manager) Status(ctx context.Context) Status {
	s := Status{Profiles: []DeviceProfile{}, DevelopmentEnabled: DevelopmentEnabled(), Enabled: m.enabled, Device: "stopped", Sessions: map[string]string{}, Checks: map[string]string{}, AVDs: []string{}}
	if !m.enabled {
		return s
	}
	tools := []string{"adb", "emulator", "java"}
	if DevelopmentEnabled() {
		tools = append(tools, "flutter", "node", "npm")
	}
	for _, name := range tools {
		path, e := exec.LookPath(tool(name))
		if e != nil {
			s.Checks[name] = "missing: " + e.Error()
		} else {
			s.Checks[name] = path
		}
	}
	if f, e := os.OpenFile("/dev/kvm", os.O_RDWR, 0); e != nil {
		s.Checks["kvm"] = e.Error()
	} else {
		f.Close()
		s.Checks["kvm"] = "ready"
	}
	if mode, err := graphicsMode(); err != nil {
		s.Checks["graphics"] = err.Error()
	} else {
		s.Checks["graphics"] = mode
	}
	if text, e := output(ctx, "emulator", "-list-avds"); e == nil {
		for _, v := range strings.Split(text, "\n") {
			if strings.TrimSpace(v) != "" {
				s.AVDs = append(s.AVDs, strings.TrimSpace(v))
			}
		}
	}
	if profiles, err := m.profilesForAVDs(s.AVDs); err == nil {
		s.Profiles = profiles
	} else {
		s.Checks["profiles"] = err.Error()
	}
	m.mu.Lock()
	s.ActiveAVD = m.deviceAVD
	s.ActiveProfile = m.deviceProfileID
	if m.device != nil {
		s.Device = m.device.state
	}
	for k, p := range m.sessions {
		s.Sessions[k] = p.state
	}
	m.mu.Unlock()
	if s.Device == "running" {
		s.Device = "booting"
		if v, e := output(ctx, "adb", "-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"); e == nil && v == "1" {
			s.Device = "ready"
		}
	}
	return s
}
func (m *Manager) launch(p *process, dir, name string, args ...string) error {
	cmd := exec.Command(tool(name), args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "CI=true", "FLUTTER_SUPPRESS_ANALYTICS=true")
	cmd.SysProcAttr = processAttributes()
	in, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	out, e := cmd.StdoutPipe()
	if e != nil {
		in.Close()
		return e
	}
	cmd.Stderr = cmd.Stdout
	if e = cmd.Start(); e != nil {
		p.state = "failed"
		in.Close()
		return e
	}
	p.cmd = cmd
	p.stdin = in
	p.state = "running"
	p.done = make(chan struct{})
	go func() {
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			m.mu.Lock()
			p.log = append(p.log, line...)
			p.log = append(p.log, '\n')
			if len(p.log) > 128*1024 {
				p.log = append([]byte(nil), p.log[len(p.log)-128*1024:]...)
			}
			var events []struct {
				Event  string `json:"event"`
				Params struct {
					AppID string `json:"appId"`
				} `json:"params"`
			}
			if json.Unmarshal(line, &events) == nil {
				for _, ev := range events {
					if ev.Event == "app.start" {
						p.appID = ev.Params.AppID
						p.state = "building"
					}
					if ev.Event == "app.started" {
						p.state = "running"
					}
				}
			}
			m.mu.Unlock()
		}
		scanErr := scanner.Err()
		if scanErr != nil {
			killProcess(cmd)
		}
		e := cmd.Wait()
		in.Close()
		m.mu.Lock()
		if p.state == "stopping" {
			p.state = "stopped"
		} else if e != nil || scanErr != nil {
			p.state = "failed"
			p.log = append(p.log, []byte(fmt.Sprintf("\nProcess ended: %v; output: %v\n", e, scanErr))...)
		} else {
			p.state = "stopped"
		}
		close(p.done)
		m.mu.Unlock()
	}()
	return nil
}
func active(p *process) bool {
	return p != nil && (p.cmd != nil || p.cancel != nil) && p.state != "failed" && p.state != "stopped"
}
func (m *Manager) StartDevice(ctx context.Context, avd string) error {
	return m.startDevice(ctx, avd, 0, 0, profileID(avd))
}
func (m *Manager) startDevice(ctx context.Context, avd string, cores, memory int, id string) error {
	if !validAVD(avd) {
		return errors.New("invalid AVD name")
	}
	if !m.enabled {
		return errors.New("enable Android with OKESTRA_ANDROID_ENABLED=1")
	}
	mode, err := graphicsMode()
	if err != nil {
		return err
	}
	available, e := output(ctx, "emulator", "-list-avds")
	if e != nil {
		return fmt.Errorf("list devices: %s: %w", available, e)
	}
	found := false
	for _, v := range strings.Split(available, "\n") {
		if v == avd && avd != "" {
			found = true
		}
	}
	if !found {
		return errors.New("choose an installed AVD from android status")
	}
	// Serialize provisioning, profile edits and device launch. Reload resource
	// settings here so an edit between profile lookup and launch is respected.
	m.profilesMu.Lock()
	defer m.profilesMu.Unlock()
	if cores > 0 {
		saved, err := m.readProfiles()
		if err != nil {
			return err
		}
		for _, p := range saved {
			if p.ID == id {
				cores, memory = p.Cores, p.MemoryMB
				break
			}
		}
	}
	// Never take over an emulator owned by another application.
	m.mu.Lock()
	defer m.mu.Unlock()
	if active(m.device) {
		if m.deviceAVD != avd || (m.deviceProfileID != "" && m.deviceProfileID != id) {
			return errors.New("stop the current emulator before starting another device profile")
		}
		return nil
	}
	for _, port := range []string{"5554", "5555"} {
		l, e := net.Listen("tcp4", "127.0.0.1:"+port)
		if e != nil {
			return fmt.Errorf("emulator port %s is already in use: %w", port, e)
		}
		l.Close()
	}
	if text, e := output(ctx, "adb", "start-server"); e != nil {
		return fmt.Errorf("start ADB: %s: %w", text, e)
	}
	m.device = &process{}
	args := []string{"-avd", avd, "-port", "5554", "-no-window", "-skip-adb-auth", "-no-audio", "-no-boot-anim", "-gpu", mode, "-no-snapshot-save"}
	if cores > 0 {
		args = append(args, "-cores", fmt.Sprint(cores), "-memory", fmt.Sprint(memory))
	}
	if err := m.launch(m.device, "", "emulator", args...); err != nil {
		return err
	}
	m.deviceAVD = avd
	m.deviceProfileID = id
	return nil
}
func (m *Manager) Stop(name string) error {
	m.mu.Lock()
	p := m.sessions[name]
	if name == "device" {
		p = m.device
		for _, v := range m.sessions {
			if active(v) {
				m.mu.Unlock()
				return errors.New("stop app sessions before stopping the device")
			}
		}
	}
	if !active(p) {
		m.mu.Unlock()
		return nil
	}
	if p.cancel != nil {
		p.state = "stopping"
		p.cancel()
		done := p.done
		m.mu.Unlock()
		select {
		case <-done:
			return nil
		case <-time.After(15 * time.Second):
			return errors.New("Expo stop timed out; inspect server logs")
		}
	}
	cmd := p.cmd
	p.state = "stopping"
	done := p.done
	m.mu.Unlock()
	_ = cmd.Process.Signal(os.Interrupt)
	select {
	case <-done:
		return nil
	case <-time.After(5 * time.Second):
		killProcess(cmd)
		<-done
		return nil
	}
}
func (m *Manager) Close() {
	m.mu.Lock()
	var names []string
	for name := range m.sessions {
		names = append(names, name)
	}
	m.mu.Unlock()
	for _, n := range names {
		_ = m.Stop(n)
	}
	_ = m.Stop("device")
}
func (m *Manager) Run(name, target string) error {
	if !Name.MatchString(name) || name == "device" {
		return errors.New("invalid workspace name")
	}
	if target == "" {
		target = "lib/main.dart"
	}
	if !safePath(target) {
		return errors.New("invalid entrypoint")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if !active(m.device) {
		return errors.New("start the managed emulator first")
	}
	if active(m.sessions[name]) {
		return errors.New("session already running; use reload or stop")
	}
	dir := filepath.Join(m.root, name, "source")
	if _, e := os.Stat(filepath.Join(dir, "pubspec.yaml")); e != nil {
		return errors.New("sync the Flutter project first")
	}
	for other, session := range m.sessions {
		if other != name && active(session) {
			return fmt.Errorf("device in use by workspace %s", other)
		}
	}
	p := &process{kind: "flutter"}
	m.sessions[name] = p
	e := m.launch(p, dir, "flutter", "run", "--machine", "-d", "emulator-5554", "--target", target)
	if e == nil {
		p.state = "building"
	}
	return e
}
func (m *Manager) Reload(name string, full bool) error {
	m.mu.Lock()
	p := m.sessions[name]
	if p != nil && p.kind == "expo" {
		ready := active(p) && p.state == "running"
		port := p.expo.Port
		m.mu.Unlock()
		if !ready {
			return errors.New("Metro is not ready or the app needs a rebuild; inspect logs")
		}
		if full {
			return m.Restart(name, nil)
		}
		return metroCommand(port, "reload")
	}
	m.mu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	p = m.sessions[name]
	if !active(p) || p.appID == "" {
		return errors.New("Flutter app is not ready; inspect logs")
	}
	b, _ := json.Marshal(map[string]any{"id": time.Now().UnixNano(), "method": "app.restart", "params": map[string]any{"appId": p.appID, "fullRestart": full, "pause": false}})
	if pipe, ok := p.stdin.(*os.File); ok {
		_ = pipe.SetWriteDeadline(time.Now().Add(3 * time.Second))
		defer pipe.SetWriteDeadline(time.Time{})
	}
	_, e := p.stdin.Write(append(b, '\n'))
	return e
}
func (m *Manager) Logs(name string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	p := m.sessions[name]
	if name == "device" {
		p = m.device
	}
	if p == nil {
		return "No session output yet."
	}
	return string(p.log)
}
func (m *Manager) DeviceActive() bool { m.mu.Lock(); defer m.mu.Unlock(); return active(m.device) }
func safePath(p string) bool {
	return p != "" && p != "." && !strings.Contains(p, "\\") && !filepath.IsAbs(p) && filepath.Clean(p) == p && p != ".." && !strings.HasPrefix(p, "../")
}

// Sync accepts bounded regular files only, stages before applying, and preserves generated files.
func (m *Manager) Sync(name string, src io.Reader) error { return m.SyncProject(name, "flutter", src) }
func (m *Manager) SyncProject(name, framework string, src io.Reader) error {
	if framework != "flutter" && framework != "expo" {
		return errors.New("unknown Android framework")
	}
	if !Name.MatchString(name) || name == "device" {
		return errors.New("invalid workspace name")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if p := m.sessions[name]; framework == "expo" && active(p) && (p.state == "installing" || p.state == "building" || p.state == "starting" || p.state == "stopping") {
		return errors.New("wait for the Expo build to finish before syncing more source")
	}
	if p := m.sessions[name]; active(p) && p.kind != "" && p.kind != framework {
		return errors.New("stop the current session before switching frameworks")
	}
	root := filepath.Join(m.root, name)
	if e := os.MkdirAll(root, 0700); e != nil {
		return e
	}
	stage, e := os.MkdirTemp(root, "upload-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(stage)
	tr := tar.NewReader(io.LimitReader(src, 256*1024*1024+1))
	files := map[string]bool{}
	var total int64
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
		if !safePath(h.Name) || h.Typeflag != tar.TypeReg || files[h.Name] {
			return errors.New("archive must contain unique safe regular file paths")
		}
		if len(files) >= 20000 || h.Size < 0 || h.Size > 32*1024*1024 {
			return errors.New("source archive exceeds file limits")
		}
		total += h.Size
		if total > 200*1024*1024 {
			return errors.New("source archive exceeds 200 MiB")
		}
		for _, part := range strings.Split(h.Name, "/") {
			if part == ".git" || part == ".dart_tool" || part == "build" || part == ".okestra" || part == "node_modules" || part == ".expo" {
				return errors.New("archive includes generated or private paths")
			}
		}
		path := filepath.Join(stage, h.Name)
		if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
			return e
		}
		f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600|os.FileMode(h.Mode&0111))
		if e != nil {
			return e
		}
		_, e = io.CopyN(f, tr, h.Size)
		ce := f.Close()
		if e != nil {
			return e
		}
		if ce != nil {
			return ce
		}
		files[h.Name] = true
	}
	if framework == "expo" {
		if _, e := validateExpoPackage(stage); e != nil {
			return e
		}
	} else if !files["pubspec.yaml"] {
		return errors.New("source must contain pubspec.yaml")
	}
	dest := filepath.Join(root, "source")
	if e = os.MkdirAll(dest, 0700); e != nil {
		return e
	}
	// os.Root prevents generated symlinks escaping the workspace during subsequent uploads.
	confined, e := os.OpenRoot(dest)
	if e != nil {
		return e
	}
	defer confined.Close()
	var previous map[string]bool
	b, _ := os.ReadFile(filepath.Join(root, "files.json"))
	_ = json.Unmarshal(b, &previous)
	needsRebuild := false
	if framework == "expo" {
		for path := range files {
			if ExpoRebuildFile(path) {
				old, _ := confined.ReadFile(path)
				next, _ := os.ReadFile(filepath.Join(stage, path))
				if !bytes.Equal(old, next) {
					needsRebuild = true
				}
			}
		}
		for path := range previous {
			if !files[path] && ExpoRebuildFile(path) {
				needsRebuild = true
			}
		}
	}
	for path := range previous {
		if !files[path] && safePath(path) {
			if e = confined.Remove(path); e != nil && !os.IsNotExist(e) {
				return e
			}
			for parent := filepath.Dir(path); parent != "."; parent = filepath.Dir(parent) {
				if e = confined.Remove(parent); e != nil {
					break
				}
			}
		}
	}

	for path := range files {
		if e = confined.MkdirAll(filepath.Dir(path), 0700); e != nil {
			return e
		}
		b, e := os.ReadFile(filepath.Join(stage, path))
		if e != nil {
			return e
		}
		info, e := os.Stat(filepath.Join(stage, path))
		if e != nil {
			return e
		}
		if st, err := confined.Lstat(path); err == nil && !st.Mode().IsRegular() {
			return errors.New("source destination is not a regular file")
		}
		if current, err := confined.ReadFile(path); err == nil && bytes.Equal(current, b) {
			if e = confined.Chmod(path, info.Mode().Perm()); e != nil {
				return e
			}
			continue
		}
		temp := path + ".okestra-upload-" + rand.Text()
		if e = confined.WriteFile(temp, b, info.Mode().Perm()); e != nil {
			return e
		}
		if e = confined.Rename(temp, path); e != nil {
			return e
		}
	}

	b, _ = json.Marshal(files)
	tmp := filepath.Join(root, "files.json.tmp")
	if e = os.WriteFile(tmp, b, 0600); e != nil {
		return e
	}
	if e = os.Rename(tmp, filepath.Join(root, "files.json")); e != nil {
		return e
	}
	if needsRebuild {
		if p := m.sessions[name]; active(p) && p.kind == "expo" {
			p.state = "needs_rebuild"
			p.log = append(p.log, []byte("\nNative/dependency configuration changed. Rebuild the Expo development client.\n")...)
		}
	}
	return nil
}
