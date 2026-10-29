package android

import (
	"archive/tar"
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func archive(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for p, s := range files {
		if e := w.WriteHeader(&tar.Header{Name: p, Typeflag: tar.TypeReg, Mode: 0755, Size: int64(len(s))}); e != nil {
			t.Fatal(e)
		}
		_, _ = w.Write([]byte(s))
	}
	_ = w.Close()
	return b.Bytes()
}
func TestSyncConfinesUploadsAndPreservesGenerated(t *testing.T) {
	m := New(t.TempDir())
	initial := archive(t, map[string]string{"pubspec.yaml": "name: sample", "lib/main.dart": "old", "lib/remove.dart": "remove", "android/gradlew": "script"})
	if e := m.Sync("sample", bytes.NewReader(initial)); e != nil {
		t.Fatal(e)
	}
	root := filepath.Join(m.root, "sample", "source")
	_ = os.MkdirAll(filepath.Join(root, "build"), 0700)
	_ = os.WriteFile(filepath.Join(root, "build", "cached"), []byte("keep"), 0600)
	next := archive(t, map[string]string{"pubspec.yaml": "name: sample", "lib/main.dart": "new"})
	if e := m.Sync("sample", bytes.NewReader(next)); e != nil {
		t.Fatal(e)
	}
	if b, e := os.ReadFile(filepath.Join(root, "lib/main.dart")); e != nil || string(b) != "new" {
		t.Fatalf("%s %v", b, e)
	}
	if _, e := os.Stat(filepath.Join(root, "lib/remove.dart")); !os.IsNotExist(e) {
		t.Fatalf("deleted file remains: %v", e)
	}
	if _, e := os.Stat(filepath.Join(root, "build/cached")); e != nil {
		t.Fatal("lost generated file", e)
	}
	for _, bad := range []string{"../escape", "/tmp/escape", "lib/../../escape", ".git/config", ".dart_tool/foo"} {
		if e := m.Sync("sample", bytes.NewReader(archive(t, map[string]string{"pubspec.yaml": "x", bad: "bad"}))); e == nil {
			t.Fatal("accepted", bad)
		}
	}
	if e := m.Sync("../escape", bytes.NewReader(initial)); e == nil {
		t.Fatal("workspace traversal")
	}
	outside := t.TempDir()
	_ = os.Symlink(outside, filepath.Join(root, "external"))
	if e := m.Sync("sample", bytes.NewReader(archive(t, map[string]string{"pubspec.yaml": "x", "external/escape": "bad"}))); e == nil {
		t.Fatal("symlink escaped")
	}
}
func TestFlutterSessionReloadAndShutdown(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_ENABLED", "1")
	dir := t.TempDir()
	flutter := filepath.Join(dir, "flutter")
	script := "#!/bin/sh\nprintf '%s\\n' '[{\"event\":\"app.start\",\"params\":{\"appId\":\"test-app\"}}]' '[{\"event\":\"app.started\"}]'\nwhile IFS= read -r line; do printf '%s\\n' \"$line\"; done\n"
	if e := os.WriteFile(flutter, []byte(script), 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("OKESTRA_FLUTTER_BIN", flutter)
	m := New(dir)
	defer m.Close()
	m.device = &process{cmd: nil, state: "stopped"}
	// A separate harmless process represents a supervised device without requiring Android.
	m.mu.Lock()
	if e := m.launch(m.device, "", "sh", "-c", "sleep 30"); e != nil {
		t.Fatal(e)
	}
	m.mu.Unlock()
	if e := m.Sync("app", bytes.NewReader(archive(t, map[string]string{"pubspec.yaml": "name: app", "lib/main.dart": "void main() {}"}))); e != nil {
		t.Fatal(e)
	}
	if e := m.Run("app", ""); e != nil {
		t.Fatal(e)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		m.mu.Lock()
		ready := m.sessions["app"].appID != ""
		m.mu.Unlock()
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no Flutter app.start event")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e := m.Reload("app", false); e != nil {
		t.Fatal(e)
	}
	if e := m.Stop("device"); e == nil {
		t.Fatal("stopped device with active app")
	}
	for !strings.Contains(m.Logs("app"), "app.restart") {
		if time.Now().After(deadline) {
			t.Fatal("no reload command")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e := m.Stop("app"); e != nil {
		t.Fatal(e)
	}
	if e := m.Stop("device"); e != nil {
		t.Fatal(e)
	}
	if s := m.Status(context.Background()); s.Sessions["app"] != "failed" && s.Sessions["app"] != "stopped" {
		t.Fatal(s)
	}
}

func TestSyncFileDirectoryTransitions(t *testing.T) {
	m := New(t.TempDir())
	for _, files := range []map[string]string{
		{"pubspec.yaml": "name: test", "lib/item": "file"},
		{"pubspec.yaml": "name: test", "lib/item/child": "child"},
		{"pubspec.yaml": "name: test", "lib/item": "file again"},
	} {
		if e := m.Sync("test", bytes.NewReader(archive(t, files))); e != nil {
			t.Fatal(e)
		}
	}
}
