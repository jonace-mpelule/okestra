package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
)

func archiveForTest(t *testing.T, name string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	gz := gzip.NewWriter(&buffer)
	tarWriter := tar.NewWriter(gz)
	payload := []byte("verified-binary")
	if err := tarWriter.WriteHeader(&tar.Header{Name: "./" + name, Mode: 0o755, Size: int64(len(payload))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func TestFetchVerifiesChecksumAndExtractsBinary(t *testing.T) {
	archive := archiveForTest(t, "okestra")
	sum := sha256.Sum256(archive)
	name := fmt.Sprintf("okestra_1.2.3_%s_%s.tar.gz", runtime.GOOS, runtime.GOARCH)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/releases/latest":
			http.Redirect(w, r, "/releases/tag/v1.2.3", http.StatusFound)
		case r.URL.Path == "/releases/tag/v1.2.3":
			w.Write([]byte("latest"))
		case strings.HasSuffix(r.URL.Path, "/"+name):
			w.Write(archive)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
			fmt.Fprintf(w, "%s  %s\n", hex.EncodeToString(sum[:]), name)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	got, err := fetch(context.Background(), "okestra", server.URL+"/releases")
	if err != nil {
		t.Fatal(err)
	}
	if got.Tag != "v1.2.3" || string(got.Binary) != "verified-binary" {
		t.Fatalf("release = %#v", got)
	}
}

func TestFetchRejectsChecksumMismatch(t *testing.T) {
	archive := archiveForTest(t, "okestra")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/releases/latest":
			http.Redirect(w, r, "/releases/tag/v1.2.3", http.StatusFound)
		case r.URL.Path == "/releases/tag/v1.2.3":
			w.Write([]byte("latest"))
		case strings.HasSuffix(r.URL.Path, "SHA256SUMS"):
			fmt.Fprintf(w, "%064x  okestra_1.2.3_%s_%s.tar.gz\n", 0, runtime.GOOS, runtime.GOARCH)
		default:
			w.Write(archive)
		}
	}))
	defer server.Close()
	if _, err := fetch(context.Background(), "okestra", server.URL+"/releases"); err == nil || !strings.Contains(err.Error(), "mismatch") {
		t.Fatalf("wanted checksum error, got %v", err)
	}
}
