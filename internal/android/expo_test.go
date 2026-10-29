package android

import (
	"bytes"

	"encoding/json"
	"fmt"
	"github.com/gorilla/websocket"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const expoJSON = `{"dependencies":{"expo":"~54.0.0","expo-dev-client":"~6.0.0","react-native":"0.81.0"},"packageManager":"npm@10.0.0"}`

func TestExpoValidationAndLockfiles(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"dependencies":{"expo":"54"}}`), 0600)
	if _, e := validateExpoPackage(dir); e == nil {
		t.Fatal("accepted project without development client")
	}
	_ = os.WriteFile(filepath.Join(dir, "package.json"), []byte(expoJSON), 0600)
	pkg, e := validateExpoPackage(dir)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, _, e := expoInstall(dir, ExpoOptions{}, pkg); e == nil {
		t.Fatal("accepted unlocked dependencies")
	}
	_ = os.WriteFile(filepath.Join(dir, "package-lock.json"), []byte("{}"), 0600)
	manager, args, _, e := expoInstall(dir, ExpoOptions{}, pkg)
	if e != nil || manager != "npm" || !strings.Contains(strings.Join(args, " "), "--include=dev") {
		t.Fatalf("%s %v %v", manager, args, e)
	}
	for _, opts := range []ExpoOptions{{Port: 80}, {PackageManager: "arbitrary"}, {Environment: map[string]string{"PATH": "/bad"}}, {Environment: map[string]string{"NODE_OPTIONS": "--eval"}}} {
		if e := opts.Validate(); e == nil {
			t.Fatal("invalid options", opts)
		}
	}
	for _, p := range []string{"app.config.ts", "app.json", "package.json", "bun.lock", "android/app/build.gradle", "plugins/with-custom.ts"} {
		if !ExpoRebuildFile(p) {
			t.Fatal("missing rebuild trigger", p)
		}
	}
	if ExpoRebuildFile("App.tsx") {
		t.Fatal("JS source must use Fast Refresh")
	}
}
func TestExpoBuildMetroReloadSyncAndStop(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OKESTRA_ANDROID_ENABLED", "1")
	commands := filepath.Join(dir, "commands")
	marker := filepath.Join(dir, "metro-started")
	node := filepath.Join(dir, "node")
	npm := filepath.Join(dir, "npm")
	adb := filepath.Join(dir, "adb")
	write := func(path, body string) {
		t.Helper()
		if e := os.WriteFile(path, []byte(body), 0700); e != nil {
			t.Fatal(e)
		}
	}
	write(node, fmt.Sprintf("#!/bin/sh\nprintf 'node %%s\\n' \"$*\" >> '%s'\ncase \"$2\" in start) touch '%s'; while :; do sleep 1; done;; esac\n", commands, marker))
	write(npm, fmt.Sprintf("#!/bin/sh\nprintf 'npm %%s\\n' \"$*\" >> '%s'\nmkdir -p node_modules/expo/bin\necho stub > node_modules/expo/bin/cli\n", commands))
	write(adb, fmt.Sprintf("#!/bin/sh\nprintf 'adb %%s\\n' \"$*\" >> '%s'\n", commands))
	t.Setenv("OKESTRA_NODE_BIN", node)
	t.Setenv("OKESTRA_NPM_BIN", npm)
	t.Setenv("OKESTRA_ADB_BIN", adb)
	m := New(dir)
	defer m.Close()
	m.device = &process{}
	m.mu.Lock()
	e := m.launch(m.device, "", "sh", "-c", "sleep 40")
	m.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	files := map[string]string{"package.json": expoJSON, "package-lock.json": "{}", "App.tsx": "old"}
	if e = m.SyncProject("expo-app", "expo", bytes.NewReader(archive(t, files))); e != nil {
		t.Fatal(e)
	}
	reserved, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	reserved.Close()
	if e = m.RunExpo("expo-app", ExpoOptions{Port: port}); e != nil {
		t.Fatal(e)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, e = os.Stat(marker); e == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal(m.Logs("expo-app"))
		}
		time.Sleep(10 * time.Millisecond)
	}
	var reloads atomic.Int32
	var menus atomic.Int32
	listener, e := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if e != nil {
		t.Fatal(e)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/status":
			fmt.Fprint(w, "packager-status:running")
		case "/message":
			if r.Header.Get("Origin") != fmt.Sprintf("http://127.0.0.1:%d", port) {
				t.Error("incorrect command origin")
			}
			conn, e := (&websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}).Upgrade(w, r, nil)
			if e != nil {
				t.Error(e)
				return
			}
			defer conn.Close()
			for {
				var message map[string]json.RawMessage
				if e = conn.ReadJSON(&message); e != nil {
					return
				}
				if string(message["version"]) != "2" {
					t.Error("incorrect Metro protocol")
				}
				switch string(message["method"]) {
				case `"getpeers"`:
					_ = conn.WriteJSON(map[string]any{"version": 2, "id": "okestra-peers", "result": map[string]string{"app": "role=client"}})
				case `"reload"`:
					reloads.Add(1)
				case `"devMenu"`:
					menus.Add(1)
				}
			}
		default:
			http.NotFound(w, r)
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	for {
		m.mu.Lock()
		state := m.sessions["expo-app"].state
		m.mu.Unlock()
		if state == "running" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal(state, m.Logs("expo-app"))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e = m.Reload("expo-app", false); e != nil {
		t.Fatal(e)
	}
	for reloads.Load() != 1 {
		if time.Now().After(deadline) {
			t.Fatal("reload not delivered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if e = m.DevMenu("expo-app"); e != nil {
		t.Fatal(e)
	}
	for menus.Load() != 1 {
		if time.Now().After(deadline) {
			t.Fatal("dev menu not delivered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	bad := ExpoOptions{Port: 80}
	if e = m.Restart("expo-app", &bad); e == nil {
		t.Fatal("accepted invalid rebuild options")
	}
	m.mu.Lock()
	stillRunning := m.sessions["expo-app"].state
	m.mu.Unlock()
	if stillRunning != "running" {
		t.Fatal("invalid rebuild stopped healthy session")
	}
	files["App.tsx"] = "new"
	if e = m.SyncProject("expo-app", "expo", bytes.NewReader(archive(t, files))); e != nil {
		t.Fatal(e)
	}
	m.mu.Lock()
	state := m.sessions["expo-app"].state
	m.mu.Unlock()
	if state != "running" {
		t.Fatal("JS edit interrupted Metro:", state)
	}
	files["app.json"] = `{"expo":{"name":"test"}}`
	if e = m.SyncProject("expo-app", "expo", bytes.NewReader(archive(t, files))); e != nil {
		t.Fatal(e)
	}
	m.mu.Lock()
	state = m.sessions["expo-app"].state
	m.mu.Unlock()
	if state != "needs_rebuild" {
		t.Fatal("native config not detected", state)
	}
	if e = m.Reload("expo-app", false); e == nil {
		t.Fatal("reloaded stale native client")
	}
	if e = m.Stop("device"); e == nil {
		t.Fatal("stopped device with Expo running")
	}
	server.Close()
	if e = m.Restart("expo-app", nil); e != nil {
		t.Fatal(e)
	}
	deadline = time.Now().Add(5 * time.Second)
	for {
		b, _ := os.ReadFile(commands)
		if strings.Count(string(b), "start --dev-client --localhost") >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("rebuild did not restart Metro", m.Logs("expo-app"))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e = m.Stop("expo-app"); e != nil {
		t.Fatal(e)
	}
	log, e := os.ReadFile(commands)
	if e != nil {
		t.Fatal(e)
	}
	if strings.Count(string(log), "npm ci --include=dev") != 1 {
		t.Fatal("unchanged locked dependencies were unnecessarily reinstalled", string(log))
	}
	for _, flag := range []string{"npm ci --include=dev", "prebuild --platform android --no-install --clean", "run:android --device emulator-5554 --no-bundler", "start --dev-client --localhost", "reverse --remove"} {
		if !strings.Contains(string(log), flag) {
			t.Errorf("missing %q in %s", flag, log)
		}
	}
}
func TestExpoStopDuringDependencyInstallation(t *testing.T) {
	dir := t.TempDir()
	m := New(dir)
	defer m.Close()
	t.Setenv("OKESTRA_NODE_BIN", "/bin/sh")
	npm := filepath.Join(dir, "npm")
	_ = os.WriteFile(npm, []byte("#!/bin/sh\nexec sleep 30\n"), 0700)
	t.Setenv("OKESTRA_NPM_BIN", npm)
	m.device = &process{}
	m.mu.Lock()
	e := m.launch(m.device, "", "sh", "-c", "sleep 30")
	m.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	if e = m.SyncProject("app", "expo", bytes.NewReader(archive(t, map[string]string{"package.json": expoJSON, "package-lock.json": "{}"}))); e != nil {
		t.Fatal(e)
	}
	if e = m.RunExpo("app", ExpoOptions{Port: 18087}); e != nil {
		t.Fatal(e)
	}
	if e = m.Stop("app"); e != nil {
		t.Fatal(e)
	}
	m.mu.Lock()
	state := m.sessions["app"].state
	m.mu.Unlock()
	if state != "stopped" {
		t.Fatal(state)
	}
}
