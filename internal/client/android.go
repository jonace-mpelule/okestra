package client

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	androidruntime "github.com/jonace-mpelule/okestra/internal/android"
)

type AndroidProject struct {
	Path      string                      `json:"path"`
	AVD       string                      `json:"avd"`
	Target    string                      `json:"target,omitempty"`
	Framework string                      `json:"framework,omitempty"`
	Expo      *androidruntime.ExpoOptions `json:"expo,omitempty"`
	EnvFile   string                      `json:"env_file,omitempty"`
}

func (a *AndroidProject) framework() string {
	if a.Framework == "" {
		return "flutter"
	}
	return a.Framework
}
func (a *AndroidProject) validate() error {
	if a.framework() != "flutter" && a.framework() != "expo" {
		return errors.New("android.framework must be flutter or expo")
	}
	if a.framework() == "expo" {
		if a.Target != "" {
			return errors.New("android.target applies only to Flutter")
		}
		if a.Expo != nil {
			if e := a.Expo.Validate(); e != nil {
				return e
			}
		}
	} else if a.Expo != nil || a.EnvFile != "" {
		return errors.New("expo options and android.env_file require framework expo")
	}
	if a.EnvFile != "" && (filepath.IsAbs(a.EnvFile) || a.EnvFile == ".." || strings.HasPrefix(filepath.Clean(a.EnvFile), "../")) {
		return errors.New("android.env_file must be inside Android project source")
	}
	if a.Path == "" || filepath.IsAbs(a.Path) || a.Path == ".." || strings.HasPrefix(filepath.Clean(a.Path), "../") {
		return errors.New("android.path must be inside the project folder")
	}
	return nil
}
func localTool(name string) string {
	if path, e := exec.LookPath(name); e == nil {
		return path
	}
	home, _ := os.UserHomeDir()
	paths := []string{filepath.Join(home, "Library/Application Support/Okestra/platform-tools", name), "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name, filepath.Join(home, "Library/Android/sdk/platform-tools", name)}
	for _, p := range paths {
		if st, e := os.Stat(p); e == nil && st.Mode()&0111 != 0 {
			return p
		}
	}
	return name
}
func localCommand(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, localTool(name), args...)
	for _, v := range os.Environ() {
		if !strings.HasPrefix(v, "ADB_SERVER_SOCKET=") && !strings.HasPrefix(v, "ANDROID_SERIAL=") && !strings.HasPrefix(v, "ADB=") {
			cmd.Env = append(cmd.Env, v)
		}
	}
	cmd.Env = append(cmd.Env, "ADB="+localTool("adb"))
	return cmd
}
func (a *API) androidAction(ctx context.Context, name, action string, payload any) error {
	return a.postJSON(ctx, "/v1/android/"+name+"/"+action, payload, &struct {
		OK bool `json:"ok"`
	}{})
}
func (a *API) androidSync(ctx context.Context, name string, source []byte) error {
	return a.androidSyncFramework(ctx, name, "flutter", source)
}
func (a *API) androidSyncFramework(ctx context.Context, name, framework string, source []byte) error {
	req, e := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+"/v1/android/"+name+"/sync?framework="+url.QueryEscape(framework), bytes.NewReader(source))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/x-tar")
	resp, e := a.do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return decodeAPIError(resp)
	}
	return nil
}
func androidSocket(api *API, kind string) string {
	sum := sha256.Sum256([]byte(api.baseURL + "/" + kind))
	return filepath.Join(filepath.Dir(DefaultConfigPath()), "android", hex.EncodeToString(sum[:8])+".sock")
}
func androidProject(file string) (Project, string, error) {
	p, base, _, e := loadProject(file)
	if e != nil {
		return p, "", e
	}
	if p.Android == nil {
		return p, "", errors.New("add android.path and android.avd to okestra.json")
	}
	root, e := filepath.EvalSymlinks(filepath.Join(base, p.Android.Path))
	if e != nil {
		return p, "", e
	}
	realBase, e := filepath.EvalSymlinks(base)
	if e != nil {
		return p, "", e
	}
	rel, e := filepath.Rel(realBase, root)
	if e != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return p, "", errors.New("Android source resolves outside project folder")
	}
	return p, root, nil
}
func runAndroid(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stdout, "Usage: okestra android <init|doctor|status|start|device-stop|device-logs|connect|disconnect|view|sync|run|reload|restart|stop|logs|watch|unwatch|watch-logs|dev-menu> [-f okestra.json] [--avd NAME] [--framework flutter|expo] [--json]")
		return 0
	}
	action := args[0]
	if action == "active-profile" {
		if _, e := cfg.ActiveProfile(); e != nil {
			fmt.Fprintln(stderr, e)
			return 1
		}
		fmt.Fprintln(stdout, cfg.ActiveAgent)
		return 0
	}
	if action == "adb-path" {
		path, e := exec.LookPath(localTool("adb"))
		if e != nil {
			fmt.Fprintln(stderr, "Install Android platform tools with setup-android-mac.sh")
			return 1
		}
		fmt.Fprintln(stdout, path)
		return 0
	}
	fs := flag.NewFlagSet("android "+action, flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("f", "okestra.json", "project manifest")
	avd := fs.String("avd", "", "installed server AVD")
	framework := fs.String("framework", "flutter", "flutter or expo (development builds only)")
	asJSON := fs.Bool("json", false, "structured output")
	profile := fs.String("profile", "", "server profile")
	if fs.Parse(args[1:]) != nil || fs.NArg() != 0 {
		return 1
	}
	fail := func(e error) int { fmt.Fprintln(stderr, "Android:", e); return 1 }
	if action == "init" {
		if *avd == "" {
			return fail(errors.New("specify --avd with an installed server device name"))
		}
		name := strings.ToLower(filepath.Base(mustAbs(".")))
		if !projectName.MatchString(name) || name == "device" {
			return fail(errors.New("use a folder name with lowercase letters, digits and hyphens; device is reserved"))
		}
		android := &AndroidProject{Path: ".", AVD: *avd, Framework: *framework}
		if *framework == "expo" {
			android.Expo = &androidruntime.ExpoOptions{Port: 8081}
		}
		if e := android.validate(); e != nil {
			return fail(e)
		}
		if *framework == "expo" {
			if e := validateLocalExpo("."); e != nil {
				return fail(e)
			}
		}
		b, _ := json.MarshalIndent(Project{Name: name, Android: android}, "", "  ")
		f, e := os.OpenFile(*file, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
		if e != nil {
			return fail(e)
		}
		_, e = f.Write(append(b, '\n'))
		f.Close()
		if e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Created", *file)
		return 0
	}
	if *profile != "" {
		copy := *cfg
		copy.ActiveAgent = *profile
		cfg = &copy
	}
	_, api, ok := activeAPI(cfg, stderr)
	if !ok {
		return 1
	}
	reqCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	switch action {
	case "status", "doctor":
		var s androidruntime.Status
		if e := api.getJSON(reqCtx, "/v1/android/status", &s); e != nil {
			return fail(e)
		}
		conn, _ := queryForward(androidSocket(api, "connect"), "status")
		if *asJSON {
			_ = json.NewEncoder(stdout).Encode(struct {
				androidruntime.Status
				LocalSerial string `json:"local_serial"`
			}{s, strings.Join(conn.Ports, "")})
			return 0
		}
		fmt.Fprintf(stdout, "Android enabled: %t\nDevice: %s\nAvailable AVDs: %s\n", s.Enabled, s.Device, strings.Join(s.AVDs, ", "))
		for _, k := range []string{"flutter", "adb", "emulator", "java", "node", "npm", "kvm"} {
			fmt.Fprintf(stdout, "%s: %s\n", k, s.Checks[k])
		}
		for n, v := range s.Sessions {
			fmt.Fprintf(stdout, "%s: %s\n", n, v)
		}
		if len(conn.Ports) > 0 {
			fmt.Fprintln(stdout, "Local ADB device:", conn.Ports[0])
		}
		for _, n := range []string{"adb"} {
			if _, e := exec.LookPath(localTool(n)); e != nil {
				fmt.Fprintln(stdout, "Mac", n, ": missing")
			} else {
				fmt.Fprintln(stdout, "Mac", n, ":", localTool(n))
			}
		}
		return 0
	case "connect":
		return androidDetach(ctx, cfg, api, "connect", *file, stdout, stderr)
	case "disconnect":
		_, e := queryForward(androidSocket(api, "connect"), "shutdown")
		if e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Device disconnected from this computer.")
		return 0
	case "__connect":
		return androidConnectDaemon(ctx, api, stderr)
	case "view":
		if runtime.GOOS != "darwin" {
			return fail(errors.New("Okestra Device requires macOS; use view-scrcpy on Linux"))
		}
		p, _, e := androidProject(*file)
		if e != nil {
			return fail(e)
		}
		_ = p
		app := findDeviceApp()
		if app == "" {
			return fail(errors.New("install Okestra Device.app beside Okestra Menu.app, or build it with make device"))
		}
		params := url.Values{"project": []string{filepath.Dir(mustAbs(*file))}, "profile": []string{cfg.ActiveAgent}}
		cmd := exec.CommandContext(reqCtx, "/usr/bin/open", "-a", app, "okestra-device://open?"+params.Encode())
		if b, e := cmd.CombinedOutput(); e != nil {
			return fail(fmt.Errorf("open device app: %s: %w", b, e))
		}
		fmt.Fprintln(stdout, "Opened Okestra Device.")
		return 0
	case "view-scrcpy":
		if code := androidDetach(ctx, cfg, api, "connect", *file, stdout, stderr); code != 0 {
			return code
		}
		st, e := queryForward(androidSocket(api, "connect"), "status")
		if e != nil || len(st.Ports) != 1 {
			return fail(errors.New("no local device connection"))
		}
		path, e := exec.LookPath(localTool("scrcpy"))
		if e != nil {
			return fail(errors.New("install the Mac viewer: brew install scrcpy"))
		}
		dir := filepath.Dir(androidSocket(api, "connect"))
		logFile, e := os.OpenFile(filepath.Join(dir, "viewer.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if e != nil {
			return fail(e)
		}
		defer logFile.Close()
		cmd := localCommand(context.Background(), path, "--serial", st.Ports[0], "--force-adb-forward", "--no-audio", "--max-size=1280", "--max-fps=30", "--video-bit-rate=4M", "--window-title=Okestra Android")
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if e = cmd.Start(); e != nil {
			return fail(e)
		}
		_ = cmd.Process.Release()
		fmt.Fprintln(stdout, "Opened device viewer. Output:", logFile.Name())
		return 0
	case "start":
		if *avd == "" {
			p, _, e := androidProject(*file)
			if e != nil {
				return fail(e)
			}
			*avd = p.Android.AVD
		}
		if e := api.androidAction(reqCtx, "device", "start", map[string]string{"avd": *avd}); e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Emulator starting. Check android status until ready, then open the viewer.")
		return 0
	}
	p, root, e := androidProject(*file)
	if e != nil {
		return fail(e)
	}
	switch action {
	case "sync", "run", "reload", "restart":
		if p.Android.framework() == "expo" {
			if e := validateLocalExpo(root); e != nil {
				return fail(e)
			}
		}
		request, e := androidRunRequest(p.Android, root)
		if e != nil {
			return fail(e)
		}
		source, _, e := androidSource(root)
		if e != nil {
			return fail(e)
		}
		if e = api.androidSyncFramework(reqCtx, p.Name, p.Android.framework(), source); e != nil {
			return fail(e)
		}
		if action != "sync" {
			remoteAction := action
			if action == "run" {
				remoteAction = "start"
			}
			if e = api.androidAction(reqCtx, p.Name, remoteAction, request); e != nil {
				return fail(e)
			}
		}
		fmt.Fprintln(stdout, "Source synchronized;", action, "accepted. Inspect android logs for build or reload results.")
		return 0
	case "dev-menu":
		if p.Android.framework() != "expo" {
			return fail(errors.New("development menu applies only to Expo"))
		}
		if e := api.androidAction(reqCtx, p.Name, "dev-menu", nil); e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Opened Expo development menu.")
		return 0
	case "stop":
		if e = api.androidAction(reqCtx, p.Name, "stop", nil); e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "App session stopped.")
		return 0
	case "device-stop":
		if e = api.androidAction(reqCtx, "device", "stop", nil); e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Device stopped.")
		return 0
	case "logs", "device-logs":
		name := p.Name
		if action == "device-logs" {
			name = "device"
		}
		var logs struct {
			Output string `json:"output"`
		}
		if e = api.getJSON(reqCtx, "/v1/android/"+name+"/logs", &logs); e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, logs.Output)
		return 0
	case "watch-logs":
		path := strings.TrimSuffix(androidSocket(api, "watch-"+p.Name), ".sock") + ".log"
		b, e := os.ReadFile(path)
		if e != nil {
			return fail(e)
		}
		if len(b) > 128*1024 {
			b = b[len(b)-128*1024:]
		}
		fmt.Fprintln(stdout, string(b))
		return 0
	case "watch":
		return androidDetach(ctx, cfg, api, "watch-"+p.Name, *file, stdout, stderr)
	case "unwatch":
		_, e = queryForward(androidSocket(api, "watch-"+p.Name), "shutdown")
		if e != nil {
			return fail(e)
		}
		fmt.Fprintln(stdout, "Automatic sync stopped.")
		return 0
	case "__watch":
		return androidWatch(ctx, api, p, root, stderr)
	default:
		return fail(fmt.Errorf("unknown action %q (run okestra android for help)", action))
	}
}
func mustAbs(path string) string { p, _ := filepath.Abs(path); return p }
func androidDetach(ctx context.Context, cfg *Config, api *API, kind, file string, out, errOut io.Writer) int {
	socket := androidSocket(api, kind)
	if st, e := queryForward(socket, "status"); e == nil {
		fmt.Fprintln(out, "Already active:", kind, strings.Join(st.Ports, ", "))
		return 0
	}
	if e := os.MkdirAll(filepath.Dir(socket), 0700); e != nil {
		fmt.Fprintln(errOut, e)
		return 1
	}
	exe, e := os.Executable()
	if e != nil {
		fmt.Fprintln(errOut, e)
		return 1
	}
	action := "__connect"
	if strings.HasPrefix(kind, "watch-") {
		action = "__watch"
	}
	logFile, e := os.OpenFile(strings.TrimSuffix(socket, ".sock")+".log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		fmt.Fprintln(errOut, e)
		return 1
	}
	defer logFile.Close()
	cmd := exec.Command(exe, "android", action, "-f", mustAbs(file), "--profile", cfg.ActiveAgent)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if e = cmd.Start(); e != nil {
		fmt.Fprintln(errOut, e)
		return 1
	}
	_ = cmd.Process.Release()
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); {
		if st, e := queryForward(socket, "status"); e == nil {
			fmt.Fprintln(out, "Started:", kind, strings.Join(st.Ports, ", "))
			return 0
		}
		select {
		case <-ctx.Done():
			return 1
		case <-time.After(200 * time.Millisecond):
		}
	}
	fmt.Fprintln(errOut, "Background task did not start; inspect", logFile.Name())
	return 1
}

type androidListener struct {
	net.Listener
	lock *os.File
	once sync.Once
}

func (l *androidListener) Close() error {
	var e error
	l.once.Do(func() {
		e = l.Listener.Close()
		_ = os.Remove(l.Addr().String())
		_ = syscall.Flock(int(l.lock.Fd()), syscall.LOCK_UN)
		_ = l.lock.Close()
	})
	return e
}
func androidControl(ctx context.Context, socket string, status forwardStatus, cancel context.CancelFunc) (net.Listener, error) {
	if e := os.MkdirAll(filepath.Dir(socket), 0700); e != nil {
		return nil, e
	}
	lock, e := os.OpenFile(strings.TrimSuffix(socket, ".sock")+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		lock.Close()
		return nil, errors.New("another Android task already owns this connection")
	}
	_ = os.Remove(socket)
	raw, e := net.Listen("unix", socket)
	if e != nil {
		lock.Close()
		return nil, e
	}
	listener := &androidListener{Listener: raw, lock: lock}
	_ = os.Chmod(socket, 0600)
	go func() { <-ctx.Done(); listener.Close() }()
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(2 * time.Second))
				var command string
				_, _ = fmt.Fscanln(c, &command)
				_ = json.NewEncoder(c).Encode(status)
				if command == "shutdown" {
					cancel()
				}
			}()
		}
	}()
	return listener, nil
}
func androidConnectDaemon(parent context.Context, api *API, errOut io.Writer) int {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	fail := func(e error) int { fmt.Fprintln(errOut, e); return 1 }
	if _, e := exec.LookPath(localTool("adb")); e != nil {
		return fail(errors.New("install local ADB: brew install --cask android-platform-tools"))
	}
	var remote androidruntime.Status
	checkCtx, checkCancel := context.WithTimeout(ctx, 20*time.Second)
	defer checkCancel()
	if e := api.getJSON(checkCtx, "/v1/android/status", &remote); e != nil {
		return fail(e)
	}
	if remote.Device != "ready" {
		return fail(errors.New("server device not ready; inspect android status and device-logs"))
	}
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return fail(e)
	}
	defer listener.Close()
	serial := listener.Addr().String()
	go func() { <-ctx.Done(); listener.Close() }()
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				header := http.Header{"Authorization": []string{"Bearer " + api.token}}
				ws, _, e := api.webSocketDialer().DialContext(ctx, wsURL(api.baseURL, "/v1/android/adb/ws"), header)
				if e != nil {
					return
				}
				defer ws.Close()
				done := make(chan struct{})
				defer close(done)
				go closeWebSocketOnCancel(ctx, ws, done)
				bridgeConnToWebsocket(c, ws)
			}(c)
		}
	}()
	connect := func() error {
		cctx, stop := context.WithTimeout(ctx, 10*time.Second)
		defer stop()
		text, e := localCommand(cctx, "adb", "connect", serial).CombinedOutput()
		if e != nil || !strings.Contains(string(text), "connected") {
			return fmt.Errorf("ADB connect: %s: %v", text, e)
		}
		state, e := localCommand(cctx, "adb", "-s", serial, "get-state").CombinedOutput()
		if e != nil || strings.TrimSpace(string(state)) != "device" {
			return fmt.Errorf("ADB device not authorized or offline: %s: %v", state, e)
		}
		if data, err := localCommand(cctx, "adb", "-s", serial, "shell", "true").CombinedOutput(); err != nil {
			return fmt.Errorf("ADB device is unresponsive: %s: %w", data, err)
		}
		return nil
	}
	if e = connect(); e != nil {
		return fail(e)
	}
	defer func() {
		cctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_ = localCommand(cctx, "adb", "disconnect", serial).Run()
	}()
	socket := androidSocket(api, "connect")
	ctl, e := androidControl(ctx, socket, forwardStatus{Endpoint: api.baseURL, Ports: []string{serial}, PID: os.Getpid()}, cancel)
	if e != nil {
		return fail(e)
	}
	defer ctl.Close()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0
		case <-ticker.C:
			if e = connect(); e != nil {
				fmt.Fprintln(errOut, e)
				retryCtx, stop := context.WithTimeout(ctx, 3*time.Second)
				_ = localCommand(retryCtx, "adb", "disconnect", serial).Run()
				stop()
			}
		}
	}
}
func androidSource(root string) ([]byte, string, error) {
	var buf bytes.Buffer
	hash := sha256.New()
	tw := tar.NewWriter(io.MultiWriter(&buf, hash))
	var total int64
	count := 0
	ignore, e := LoadDockerignore(root)
	if e != nil && !os.IsNotExist(e) {
		return nil, "", e
	}
	e = filepath.WalkDir(root, func(path string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		rel, e := filepath.Rel(root, path)
		if e != nil {
			return e
		}
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		excluded := false
		for _, part := range strings.Split(rel, "/") {
			if part == ".git" || part == ".dart_tool" || part == "build" || part == ".okestra" || part == ".gradle" || part == ".idea" || part == ".expo" || part == "dist" || part == "Pods" || part == ".symlinks" || part == "node_modules" || part == ".DS_Store" || strings.HasPrefix(part, ".env") || strings.HasSuffix(part, ".jks") || strings.HasSuffix(part, ".keystore") {
				excluded = true
			}
		}
		if rel == "android/local.properties" || rel == ".flutter-plugins-dependencies" {
			excluded = true
		}
		if excluded {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if ignore.ShouldIgnore(rel, d.IsDir()) {
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, e := d.Info()
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		count++
		total += info.Size()
		if count > 20000 || info.Size() > 32*1024*1024 || total > 200*1024*1024 {
			return errors.New("project exceeds source limits; add .dockerignore rules")
		}
		h, e := tar.FileInfoHeader(info, "")
		if e != nil {
			return e
		}
		h.Name = rel
		h.ModTime = time.Time{}
		h.AccessTime = time.Time{}
		h.ChangeTime = time.Time{}
		if e = tw.WriteHeader(h); e != nil {
			return e
		}
		f, e := os.Open(path)
		if e != nil {
			return e
		}
		defer f.Close()
		_, e = io.Copy(tw, f)
		return e
	})
	if e != nil {
		return nil, "", e
	}
	if e = tw.Close(); e != nil {
		return nil, "", e
	}
	return buf.Bytes(), hex.EncodeToString(hash.Sum(nil)), nil
}
func androidWatch(parent context.Context, api *API, p Project, root string, errOut io.Writer) int {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	socket := androidSocket(api, "watch-"+p.Name)
	ctl, e := androidControl(ctx, socket, forwardStatus{Project: p.Name, Endpoint: api.baseURL, PID: os.Getpid()}, cancel)
	if e != nil {
		fmt.Fprintln(errOut, e)
		return 1
	}
	defer ctl.Close()
	last, native := "", ""
	rebuildNeeded := false
	needsReload := false
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		source, digest, e := androidSource(root)
		envDigest := ""
		if p.Android.framework() == "expo" {
			request, err := androidRunRequest(p.Android, root)
			if err != nil {
				e = err
			} else {
				b, _ := json.Marshal(request)
				sum := sha256.Sum256(b)
				envDigest = hex.EncodeToString(sum[:])
				digest += envDigest
			}
		}
		reqCtx, stop := context.WithTimeout(ctx, 60*time.Second)
		if e == nil && digest != last {
			nextNative := androidNativeDigest(source)
			if p.Android.framework() == "expo" {
				nextNative = expoNativeDigest(source) + envDigest
			}
			e = api.androidSyncFramework(reqCtx, p.Name, p.Android.framework(), source)
			if e == nil {
				if native != "" && nextNative != native {
					fmt.Fprintln(errOut, "Android/dependency files changed: stop sync, stop the app, and run again to rebuild native code.")
					needsReload = false
					rebuildNeeded = true
				} else {
					needsReload = !rebuildNeeded && p.Android.framework() != "expo"
				}
				last, native = digest, nextNative
			}
		}
		if e == nil && needsReload {
			e = api.androidAction(reqCtx, p.Name, "reload", nil)
			if e == nil {
				needsReload = false
			}
		}
		stop()
		if e != nil {
			fmt.Fprintln(errOut, time.Now().Format(time.RFC3339), e)
		}
		select {
		case <-ctx.Done():
			return 0
		case <-tick.C:
		}
	}
}

// Changes requiring a full Flutter build rather than a Dart hot reload.
func androidNativeDigest(source []byte) string {
	h := sha256.New()
	r := tar.NewReader(bytes.NewReader(source))
	for {
		head, e := r.Next()
		if e != nil {
			break
		}
		if strings.HasPrefix(head.Name, "android/") || head.Name == "pubspec.yaml" || head.Name == "pubspec.lock" {
			_, _ = io.WriteString(h, head.Name+"\x00")
			_, _ = io.Copy(h, r)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

func findDeviceApp() string {
	home, _ := os.UserHomeDir()
	exe, _ := os.Executable()
	cwd, _ := os.Getwd()
	for _, path := range []string{filepath.Join(filepath.Dir(exe), "../../../Okestra Device.app"), filepath.Join(home, "Applications/Okestra Device.app"), "/Applications/Okestra Device.app", filepath.Join(filepath.Dir(exe), "../dist/Okestra Device.app"), filepath.Join(cwd, "dist/Okestra Device.app")} {
		path = filepath.Clean(path)
		if st, e := os.Stat(filepath.Join(path, "Contents/MacOS/OkestraDevice")); e == nil && st.Mode()&0111 != 0 {
			return path
		}
	}
	return ""
}

func validateLocalExpo(root string) error {
	b, e := os.ReadFile(filepath.Join(root, "package.json"))
	if e != nil {
		return e
	}
	var p struct {
		Dependencies    map[string]string `json:"dependencies"`
		DevDependencies map[string]string `json:"devDependencies"`
	}
	if e = json.Unmarshal(b, &p); e != nil {
		return e
	}
	for _, name := range []string{"expo", "expo-dev-client", "react-native"} {
		if p.Dependencies[name] == "" && p.DevDependencies[name] == "" {
			return fmt.Errorf("Expo development-build support requires %s in package.json", name)
		}
	}
	return nil
}
func androidRunRequest(a *AndroidProject, root string) (map[string]any, error) {
	out := map[string]any{"framework": a.framework(), "target": a.Target}
	if a.framework() != "expo" {
		return out, nil
	}
	opts := androidruntime.ExpoOptions{}
	if a.Expo != nil {
		opts = *a.Expo
	}
	env := map[string]string{}
	if a.EnvFile != "" {
		path, e := filepath.EvalSymlinks(filepath.Join(root, a.EnvFile))
		if e != nil {
			return nil, e
		}
		base, e := filepath.EvalSymlinks(root)
		if e != nil {
			return nil, e
		}
		rel, e := filepath.Rel(base, path)
		if e != nil || rel == ".." || strings.HasPrefix(rel, "../") {
			return nil, errors.New("Expo env_file resolves outside source folder")
		}
		env, e = readEnvFile(path)
		if e != nil {
			return nil, e
		}
	}
	for k, v := range opts.Environment {
		env[k] = v
	}
	opts.Environment = env
	if e := opts.Validate(); e != nil {
		return nil, e
	}
	out["expo"] = opts
	if b, e := json.Marshal(out); e != nil || len(b) > 60*1024 {
		return nil, errors.New("encoded Expo launch configuration exceeds 60 KiB")
	}
	return out, nil
}
func expoNativeDigest(source []byte) string {
	h := sha256.New()
	r := tar.NewReader(bytes.NewReader(source))
	for {
		head, e := r.Next()
		if e != nil {
			break
		}
		if androidruntime.ExpoRebuildFile(head.Name) {
			_, _ = io.WriteString(h, head.Name+"\x00")
			_, _ = io.Copy(h, r)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}
