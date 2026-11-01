package android

import (
	"context"
	"strings"
	"testing"
)

func TestGraphicsModeDefaultsAndValidation(t *testing.T) {
	for _, mode := range []string{"", "swiftshader", "host", "auto", "software", "lavapipe", "swangle"} {
		t.Setenv("OKESTRA_ANDROID_GPU", mode)
		got, err := graphicsMode()
		want := mode
		if want == "" {
			want = "swiftshader"
		}
		if err != nil || got != want {
			t.Fatalf("mode %q: got %q, %v", mode, got, err)
		}
	}
	for _, bad := range []string{"arbitrary", "host -extra-arg", "host;echo test"} {
		t.Setenv("OKESTRA_ANDROID_GPU", bad)
		if _, err := graphicsMode(); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}
func TestBadGraphicsModeFailsBeforeInvokingEmulator(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_ENABLED", "1")
	t.Setenv("OKESTRA_ANDROID_GPU", "invalid")
	t.Setenv("OKESTRA_EMULATOR_BIN", "/must-not-be-executed")
	manager := New(t.TempDir())
	err := manager.StartDevice(context.Background(), "okestra-pixel")
	if err == nil || !strings.Contains(err.Error(), "OKESTRA_ANDROID_GPU") {
		t.Fatalf("got %v", err)
	}
	if manager.device != nil {
		t.Fatal("created process for invalid configuration")
	}
}
