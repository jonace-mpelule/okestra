package client

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

type Config struct {
	ActiveAgent string                           `json:"active_agent"`
	Agents      map[string]protocol.AgentProfile `json:"agents"`
}

func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".okestra/config.json"
	}
	return filepath.Join(home, ".okestra", "config.json")
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &Config{Agents: make(map[string]protocol.AgentProfile)}, nil
	}
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.Agents == nil {
		cfg.Agents = make(map[string]protocol.AgentProfile)
	}
	return &cfg, nil
}

func SaveConfig(path string, cfg *Config) error {
	if cfg.Agents == nil {
		cfg.Agents = make(map[string]protocol.AgentProfile)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "config-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func (c *Config) ActiveProfile() (protocol.AgentProfile, error) {
	if c.ActiveAgent == "" {
		return protocol.AgentProfile{}, errors.New("no active agent configured")
	}
	profile, ok := c.Agents[c.ActiveAgent]
	if !ok {
		return protocol.AgentProfile{}, errors.New("active agent profile not found")
	}
	return profile, nil
}
