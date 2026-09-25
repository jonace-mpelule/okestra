package agent

import (
	"github.com/jonace-mpelule/okestra/internal/protocol"
	"reflect"
	"testing"
)

func TestRunContainerArgsIncludesProjectIsolationAndHealth(t *testing.T) {
	got := runContainerArgs(protocol.RunRequest{Image: "demo:dev", Name: "okestra-demo-app", Network: "okestra-demo", NetworkAlias: "app", Restart: "unless-stopped", Mounts: []protocol.Mount{{Source: "okestra-demo-data", Target: "/data", ReadOnly: true}}, Labels: map[string]string{"dev.okestra.project": "demo"}, Health: &protocol.HealthCheck{Command: "wget -q -O- http://127.0.0.1:8080/health", IntervalSeconds: 5, Retries: 3}})
	want := []string{"run", "-d", "--name", "okestra-demo-app", "--network", "okestra-demo", "--network-alias", "app", "--restart", "unless-stopped", "--health-cmd", "wget -q -O- http://127.0.0.1:8080/health", "--health-interval", "5s", "--health-retries", "3", "--mount", "type=volume,source=okestra-demo-data,target=/data,readonly", "--label", "dev.okestra.project=demo", "demo:dev"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args = %#v\nwant %#v", got, want)
	}
}

func TestParseSizeBytes(t *testing.T) {
	tests := map[string]int64{
		"72.8MB":  72_800_000,
		"1.5 GiB": 1_610_612_736,
		"500B":    500,
	}
	for raw, want := range tests {
		if got := parseSizeBytes(raw); got != want {
			t.Errorf("parseSizeBytes(%q) = %d, want %d", raw, got, want)
		}
	}
}
