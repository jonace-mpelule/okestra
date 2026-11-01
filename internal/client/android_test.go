package client

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"github.com/gorilla/websocket"
	"github.com/jonace-mpelule/okestra/internal/protocol"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAndroidSourceExcludesSecretsAndGeneratedFiles(t *testing.T) {
	dir := t.TempDir()
	for _, p := range []string{"pubspec.yaml", "lib/main.dart", ".env", "android/local.properties", "android/key.jks", "build/large", ".git/config", ".dart_tool/package_config.json"} {
		if e := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(filepath.Join(dir, p), []byte("test"), 0600); e != nil {
			t.Fatal(e)
		}
	}
	b, digest, e := androidSource(dir)
	if e != nil {
		t.Fatal(e)
	}
	_, again, e := androidSource(dir)
	if e != nil || again != digest {
		t.Fatal("unstable digest", e)
	}
	r := tar.NewReader(bytes.NewReader(b))
	found := map[string]bool{}
	for {
		h, e := r.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		found[h.Name] = true
	}
	if len(found) != 2 || !found["pubspec.yaml"] || !found["lib/main.dart"] {
		t.Fatal(found)
	}
}
func TestAndroidOnlyManifestAndPathValidation(t *testing.T) {
	for _, path := range []string{".", "mobile"} {
		p := Project{Name: "app", Android: &AndroidProject{Path: path}}
		if _, e := p.validate(); e != nil {
			t.Fatal(e)
		}
	}
	for _, path := range []string{"../other", "/tmp/other", ""} {
		p := Project{Name: "app", Android: &AndroidProject{Path: path}}
		if _, e := p.validate(); e == nil {
			t.Fatal("accepted", path)
		}
	}
}

func TestAndroidADBBridgeAndControlShutdown(t *testing.T) {
	dir, e := os.MkdirTemp("/tmp", "okestra-adb-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("HOME", dir)
	t.Setenv("PATH", dir)
	fake := filepath.Join(dir, "adb")
	if e := os.WriteFile(fake, []byte("#!/bin/sh\ncase \"$1\" in connect) echo connected;; disconnect) exit 0;; -s) echo device;; esac\n"), 0700); e != nil {
		t.Fatal(e)
	}
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer bridge-secret" {
			http.Error(w, "unauthorized", 401)
			return
		}
		if r.URL.Path == "/v1/android/status" {
			_, _ = io.WriteString(w, `{"enabled":true,"device":"ready"}`)
			return
		}
		conn, e := upgrader.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer conn.Close()
		for {
			kind, b, e := conn.ReadMessage()
			if e != nil {
				return
			}
			if e = conn.WriteMessage(kind, b); e != nil {
				return
			}
		}
	}))
	defer server.Close()
	api := NewAPI(protocol.AgentProfile{URL: server.URL, Token: "bridge-secret"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan int, 1)
	var output bytes.Buffer
	go func() { done <- androidConnectDaemon(ctx, api, &output) }()
	var status forwardStatus
	deadline := time.Now().Add(5 * time.Second)
	for {
		var e error
		status, e = queryForward(androidSocket(api, "connect"), "status")
		if e == nil {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			<-done
			t.Fatal("bridge never became ready", output.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(status.Ports) != 1 {
		t.Fatal(status)
	}
	for i := 0; i < 2; i++ {
		c, e := net.DialTimeout("tcp", status.Ports[0], time.Second)
		if e != nil {
			t.Fatal(e)
		}
		_ = c.SetDeadline(time.Now().Add(2 * time.Second))
		_, _ = io.WriteString(c, "ADB bytes")
		b := make([]byte, 9)
		_, e = io.ReadFull(c, b)
		c.Close()
		if e != nil || string(b) != "ADB bytes" {
			t.Fatalf("bridge: %q %v", b, e)
		}
	}
	if _, e := queryForward(androidSocket(api, "connect"), "shutdown"); e != nil {
		t.Fatal(e)
	}
	select {
	case code := <-done:
		if code != 0 {
			t.Fatal(output.String())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("bridge did not stop")
	}
}

func TestExpoRunSendsPrivateEnvironmentAndFramework(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED", "1")
	dir := t.TempDir()
	pkg := `{"dependencies":{"expo":"54","expo-dev-client":"6","react-native":"0.81"}}`
	for path, value := range map[string]string{"package.json": pkg, "package-lock.json": "{}", ".env": "EXPO_PUBLIC_API_URL=https://example.test\nNPM_TOKEN=private-test-token\n"} {
		if e := os.WriteFile(filepath.Join(dir, path), []byte(value), 0600); e != nil {
			t.Fatal(e)
		}
	}
	manifest := filepath.Join(dir, "okestra.json")
	config := `{"name":"expo-app","android":{"framework":"expo","path":".","avd":"test","env_file":".env","expo":{"port":18081,"environment":{"EXPO_PUBLIC_API_URL":"https://override.test"}}}}`
	if e := os.WriteFile(manifest, []byte(config), 0600); e != nil {
		t.Fatal(e)
	}
	var synced, started bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/android/expo-app/sync":
			synced = true
			if r.URL.Query().Get("framework") != "expo" {
				t.Error("wrong framework")
			}
			archive := tar.NewReader(r.Body)
			found := false
			for {
				header, e := archive.Next()
				if e == io.EOF {
					break
				}
				if e != nil {
					t.Error(e)
					break
				}
				if header.Name == "package.json" {
					found = true
				}
				if header.Name == ".env" {
					t.Error("secret file included in source")
				}
			}
			if !found {
				t.Error("package source missing")
			}
		case "/v1/android/expo-app/start":
			started = true
			var payload struct {
				Framework string `json:"framework"`
				Expo      struct {
					Environment map[string]string `json:"environment"`
					Port        int               `json:"port"`
				} `json:"expo"`
			}
			if e := json.NewDecoder(r.Body).Decode(&payload); e != nil {
				t.Error(e)
			}
			if payload.Framework != "expo" || payload.Expo.Port != 18081 || payload.Expo.Environment["NPM_TOKEN"] != "private-test-token" || payload.Expo.Environment["EXPO_PUBLIC_API_URL"] != "https://override.test" {
				t.Error("incorrect launch configuration")
			}
		default:
			t.Error("unexpected request", r.URL.Path)
		}
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "test", Agents: map[string]protocol.AgentProfile{"test": {Name: "test", URL: server.URL, Token: "test-token"}}}
	var out, errOut bytes.Buffer
	if code := runAndroid(context.Background(), cfg, []string{"run", "-f", manifest}, &out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if !synced || !started {
		t.Fatal("incomplete run workflow")
	}
	if strings.Contains(out.String()+errOut.String(), "private-test-token") {
		t.Fatal("launch secret printed")
	}
}
func TestExpoNativeChangesAndFrameworkValidation(t *testing.T) {
	for _, framework := range []string{"expo-go", "react-native", "unknown"} {
		if e := (&AndroidProject{Path: ".", Framework: framework}).validate(); e == nil {
			t.Fatal("accepted unsupported framework", framework)
		}
	}
	for _, framework := range []string{"flutter", "expo", ""} {
		if e := (&AndroidProject{Path: ".", Framework: framework}).validate(); e != nil {
			t.Fatal(e)
		}
	}
}

func TestDeviceCommandsDoNotRequireProject(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED", "")
	requested := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer secret-device-token" {
			t.Error("missing authentication")
		}
		requested = append(requested, r.URL.Path)
		switch r.URL.Path {
		case "/v1/android/profiles":
			io.WriteString(w, `[{"id":"saved","name":"Pixel","avd":"pixel_7","hardware":"pixel_7","cores":2,"memory_mb":2048,"width":1080,"height":2400}]`)
		case "/v1/android/device/start":
			var body struct {
				Profile string `json:"profile"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			if body.Profile != "saved" {
				t.Error("wrong selected profile", body)
			}
			io.WriteString(w, `{"ok":true}`)
		case "/v1/android/device/stop":
			io.WriteString(w, `{"ok":true}`)
		case "/v1/android/device/logs":
			io.WriteString(w, `{"output":"device logs"}`)
		default:
			t.Error("unexpected endpoint", r.URL.Path)
		}
	}))
	defer server.Close()
	cfg := &Config{ActiveAgent: "test", Agents: map[string]protocol.AgentProfile{"test": {Name: "test", URL: server.URL, Token: "secret-device-token"}}}
	// A nonexistent manifest guarantees these actions cannot accidentally load one.
	for _, action := range [][]string{{"profiles", "--json"}, {"start", "--device", "saved"}, {"device-stop"}, {"device-logs"}} {
		var out, errOut bytes.Buffer
		args := append(action, "-f", filepath.Join(t.TempDir(), "missing.json"))
		if code := runAndroid(context.Background(), cfg, args, &out, &errOut); code != 0 {
			t.Fatalf("%v: %s", action, errOut.String())
		}
	}
	count := len(requested)
	for _, action := range []string{"run", "sync", "reload", "restart", "watch", "init", "dev-menu"} {
		var out, errOut bytes.Buffer
		if code := runAndroid(context.Background(), cfg, []string{action}, &out, &errOut); code != 1 || !strings.Contains(errOut.String(), "archived") {
			t.Fatalf("%s: %d %s", action, code, errOut.String())
		}
	}
	if len(requested) != count {
		t.Fatal("archived commands contacted server")
	}
	var out, errOut bytes.Buffer
	if code := runAndroid(context.Background(), cfg, []string{"servers"}, &out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if strings.Contains(out.String(), "secret-device-token") || strings.Contains(out.String(), server.URL) {
		t.Fatal("server inventory exposed credentials or URLs")
	}
}
