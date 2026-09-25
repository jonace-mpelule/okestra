package client

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

func TestSaveLoadConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	cfg := &Config{
		ActiveAgent: "dev",
		Agents: map[string]protocol.AgentProfile{
			"dev": {Name: "dev", URL: "http://127.0.0.1:8088", Token: "secret"},
		},
	}
	if err := SaveConfig(path, cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
	got, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if got.ActiveAgent != "dev" {
		t.Fatalf("active agent = %q", got.ActiveAgent)
	}
	if got.Agents["dev"].URL != "http://127.0.0.1:8088" {
		t.Fatalf("agent URL = %q", got.Agents["dev"].URL)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("config mode = %o, want 600", info.Mode().Perm())
	}
}
