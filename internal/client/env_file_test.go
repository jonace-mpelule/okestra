package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadEnvFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := "# comment\nexport MORGAN=dev\nDATABASE_URL=postgresql://db:5432/urbanman\nACCESS_TOKEN_SECRET='a secret with spaces'\nEMPTY=\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readEnvFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{
		"MORGAN":              "dev",
		"DATABASE_URL":        "postgresql://db:5432/urbanman",
		"ACCESS_TOKEN_SECRET": "a secret with spaces",
		"EMPTY":               "",
	} {
		if got[key] != want {
			t.Errorf("%s = %q, want %q", key, got[key], want)
		}
	}
}

func TestReadEnvFileDoesNotEchoSecretsInErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte("BAD-KEY=private-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := readEnvFile(path)
	if err == nil || strings.Contains(err.Error(), "private-secret") {
		t.Fatalf("expected safe parse error, got %v", err)
	}
}
