package android

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func profileFixture(t *testing.T) (*Manager, string) {
	t.Helper()
	root := t.TempDir()
	sdk := filepath.Join(root, "sdk")
	home := filepath.Join(root, "avd")
	t.Setenv("OKESTRA_ANDROID_ENABLED", "1")
	t.Setenv("ANDROID_HOME", sdk)
	t.Setenv("ANDROID_AVD_HOME", home)
	t.Setenv("OKESTRA_ANDROID_GPU", "swiftshader")
	write := func(name, contents string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(name), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(contents), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(home, "existing.avd/config.ini"), "hw.device.name=pixel_7\nhw.cpu.ncore=2\nhw.ramSize=2048\nhw.lcd.width=1080\nhw.lcd.height=2400\n")
	write(filepath.Join(sdk, "system-images/android-35/google_apis/x86_64/package.xml"), "<package/>")
	// The fake tools follow the same executable boundary as the real Android SDK.
	write(filepath.Join(sdk, "emulator/emulator"), "#!/bin/sh\nif [ \"$1\" = -list-avds ]; then\n for p in \"$ANDROID_AVD_HOME\"/*.avd; do n=${p##*/}; echo \"${n%.avd}\"; done\nelse\n printf '%s\\n' \"$@\" > \"$ANDROID_HOME/launch-args\"\n exec /bin/sleep 60\nfi\n")
	write(filepath.Join(sdk, "platform-tools/adb"), "#!/bin/sh\necho 1\n")
	write(filepath.Join(sdk, "cmdline-tools/latest/bin/avdmanager"), "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ANDROID_HOME/create-args\"\n[ \"$1\" = create ] && [ \"$2\" = avd ] && [ \"$3\" = --name ] || exit 2\n/bin/mkdir -p \"$ANDROID_AVD_HOME/$4.avd\"\nprintf 'hw.device.name=%s\\nhw.lcd.width=1080\\nhw.lcd.height=2424\\n' \"${8}\" > \"$ANDROID_AVD_HOME/$4.avd/config.ini\"\n")
	m := New(root)
	t.Cleanup(m.Close)
	return m, sdk
}
func TestProfileImportAndPersistence(t *testing.T) {
	m, _ := profileFixture(t)
	ctx := context.Background()
	profiles, err := m.Profiles(ctx)
	if err != nil || len(profiles) != 1 {
		t.Fatalf("%v %v", profiles, err)
	}
	original := profiles[0]
	if original.Hardware != "pixel_7" || original.Width != 1080 || original.Height != 2400 {
		t.Fatal(original)
	}
	saved, err := m.SaveProfile(ctx, original.ID, ProfileRequest{Name: "Daily Pixel", Cores: 4, MemoryMB: 3072})
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := New(filepath.Dir(m.root)).Profiles(ctx)
	if err != nil || len(reloaded) != 1 || reloaded[0] != saved {
		t.Fatalf("%v %v", reloaded, err)
	}
	if saved.ID != original.ID || saved.AVD != original.AVD || saved.Hardware != original.Hardware {
		t.Fatal("editing replaced the device")
	}
	st, err := os.Stat(filepath.Join(m.root, "device-profiles.json"))
	if err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("unsafe profile file: %v %v", st, err)
	}
	for _, req := range []ProfileRequest{{Name: "", Cores: 2, MemoryMB: 2048}, {Name: "x", Cores: 0, MemoryMB: 2048}, {Name: "x", Cores: 9, MemoryMB: 2048}, {Name: "x", Cores: 2, MemoryMB: 2050}, {Name: "x\ny", Cores: 2, MemoryMB: 2048}} {
		if _, err := m.SaveProfile(ctx, original.ID, req); err == nil {
			t.Fatalf("accepted %+v", req)
		}
	}
}
func TestProfileCreationAndLaunchUseSavedResources(t *testing.T) {
	m, sdk := profileFixture(t)
	ctx := context.Background()
	p, err := m.CreateProfile(ctx, ProfileRequest{Name: "Larger Pixel", Hardware: "pixel_9", Cores: 4, MemoryMB: 4096})
	if err != nil {
		t.Fatal(err)
	}
	if p.ID == "" || p.AVD == "existing" || p.Width != 1080 || p.Height != 2424 {
		t.Fatal(p)
	}
	args, _ := os.ReadFile(filepath.Join(sdk, "create-args"))
	if strings.Contains(string(args), "--force") || !strings.Contains(string(args), "--device\npixel_9") {
		t.Fatalf("unsafe create args: %s", args)
	}
	marker := filepath.Join(avdHome(), "existing.avd/userdata-test")
	if err := os.WriteFile(marker, []byte("installed apps"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = m.StartProfile(ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	var launched []byte
	for time.Now().Before(deadline) {
		launched, err = os.ReadFile(filepath.Join(sdk, "launch-args"))
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(string(launched), "-cores\n4\n-memory\n4096") || strings.Contains(string(launched), "-wipe-data") {
		t.Fatalf("incorrect resource args: %s", launched)
	}
	if err = m.StartProfile(ctx, p.ID); err != nil {
		t.Fatal("idempotent start", err)
	}
	if err = m.StartProfile(ctx, profileID("existing")); err == nil {
		t.Fatal("switched an active emulator")
	}
	if _, err = m.SaveProfile(ctx, p.ID, ProfileRequest{Name: "edit", Cores: 2, MemoryMB: 2048}); err == nil {
		t.Fatal("edited active device")
	}
	if _, err = m.CreateProfile(ctx, ProfileRequest{Name: "other", Hardware: "pixel_7", Cores: 2, MemoryMB: 2048}); err == nil {
		t.Fatal("created device while emulator active")
	}
	if _, err = os.Stat(marker); err != nil {
		t.Fatal("lost existing device data", err)
	}
	if err = m.Stop("device"); err != nil {
		t.Fatal(err)
	}
	if _, err = m.SaveProfile(ctx, p.ID, ProfileRequest{Name: "edit", Cores: 2, MemoryMB: 2048}); err != nil {
		t.Fatal(err)
	}
}
func TestProfilesRejectUnsafeHardwareAndEscapedConfig(t *testing.T) {
	m, sdk := profileFixture(t)
	for _, hardware := range []string{"pixel_7;echo x", "../escape", "tablet"} {
		if _, err := m.CreateProfile(context.Background(), ProfileRequest{Name: "x", Hardware: hardware, Cores: 2, MemoryMB: 2048}); err == nil {
			t.Fatal("accepted", hardware)
		}
	}
	outside := filepath.Join(t.TempDir(), "config.ini")
	if err := os.WriteFile(outside, []byte("hw.lcd.width=9999"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(avdHome(), "escape.avd"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(avdHome(), "escape.avd/config.ini")); err != nil {
		t.Fatal(err)
	}
	if p := importedProfile("escape"); p.Width != 0 {
		t.Fatal("read escaped AVD config")
	}
	if err := os.Remove(filepath.Join(sdk, "system-images/android-35/google_apis/x86_64/package.xml")); err != nil {
		t.Fatal(err)
	}
	if _, err := m.CreateProfile(context.Background(), ProfileRequest{Name: "x", Hardware: "pixel_7", Cores: 2, MemoryMB: 2048}); err == nil {
		t.Fatal("accepted missing system image")
	}
}
func TestStatusOmitsArchivedToolchains(t *testing.T) {
	m, _ := profileFixture(t)
	t.Setenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED", "")
	s := m.Status(context.Background())
	for _, tool := range []string{"flutter", "node", "npm"} {
		if _, ok := s.Checks[tool]; ok {
			t.Fatal("requires archived tool", tool)
		}
	}
	if s.DevelopmentEnabled {
		t.Fatal("development default enabled")
	}
}
