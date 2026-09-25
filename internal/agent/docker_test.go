package agent

import "testing"

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
