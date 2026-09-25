package client

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestDockerignoreAndBuildContext(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".dockerignore"), []byte("ignored.txt\nnode_modules/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "kept.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("ignore"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "node_modules", "dep.js"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	data, err := CreateBuildContextTar(dir, "Dockerfile")
	if err != nil {
		t.Fatalf("create tar: %v", err)
	}
	tr := tar.NewReader(bytes.NewReader(data))
	var names []string
	for {
		hdr, err := tr.Next()
		if err != nil {
			break
		}
		names = append(names, hdr.Name)
	}
	if contains(names, "ignored.txt") {
		t.Fatalf("expected ignored file to be excluded: %v", names)
	}
	if contains(names, "node_modules/dep.js") {
		t.Fatalf("expected ignored directory to be excluded: %v", names)
	}
	if !contains(names, "kept.txt") || !contains(names, "Dockerfile") {
		t.Fatalf("expected kept files in tar: %v", names)
	}
}

func TestBuildContextAlwaysIncludesDockerfile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".dockerignore"), []byte("Dockerfile\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := CreateBuildContextTar(dir, "Dockerfile")
	if err != nil {
		t.Fatalf("create tar: %v", err)
	}
	tr := tar.NewReader(bytes.NewReader(data))
	for {
		hdr, err := tr.Next()
		if err != nil {
			break
		}
		if hdr.Name == "Dockerfile" {
			return
		}
	}
	t.Fatal("Dockerfile was excluded from the build context")
}

func TestDockerignoreNegation(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".dockerignore"), []byte("generated/**\n!generated/keep.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "generated"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "generated", "drop.txt"), []byte("drop"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "generated", "keep.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := CreateBuildContextTar(dir, "Dockerfile")
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(bytes.NewReader(data))
	var names []string
	for {
		hdr, err := tr.Next()
		if err != nil {
			break
		}
		names = append(names, hdr.Name)
	}
	if contains(names, "generated/drop.txt") || !contains(names, "generated/keep.txt") {
		t.Fatalf("unexpected archive entries: %v", names)
	}
}

func contains(items []string, want string) bool {
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}
