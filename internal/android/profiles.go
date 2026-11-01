package android

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type DeviceProfile struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	AVD      string `json:"avd"`
	Hardware string `json:"hardware"`
	Cores    int    `json:"cores"`
	MemoryMB int    `json:"memory_mb"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}
type ProfileRequest struct {
	Name     string `json:"name"`
	Hardware string `json:"hardware"`
	Cores    int    `json:"cores"`
	MemoryMB int    `json:"memory_mb"`
}

var avdName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$`)

func validAVD(name string) bool { return avdName.MatchString(name) && !strings.Contains(name, "..") }
func (r ProfileRequest) validate() error {
	if len(strings.TrimSpace(r.Name)) == 0 || len(r.Name) > 80 || strings.ContainsAny(r.Name, "\n\r\x00") {
		return errors.New("profile name must be 1–80 characters on one line")
	}
	if r.Cores < 1 || r.Cores > 8 {
		return errors.New("choose 1–8 CPU cores")
	}
	if r.MemoryMB < 1536 || r.MemoryMB > 8192 || r.MemoryMB%256 != 0 {
		return errors.New("RAM must be 1536–8192 MiB in 256 MiB steps")
	}
	return nil
}
func profileID(avd string) string {
	sum := sha256.Sum256([]byte(avd))
	return "avd-" + hex.EncodeToString(sum[:8])
}
func (m *Manager) readProfiles() ([]DeviceProfile, error) {
	b, err := os.ReadFile(filepath.Join(m.root, "device-profiles.json"))
	if os.IsNotExist(err) {
		return []DeviceProfile{}, nil
	}
	if err != nil {
		return nil, err
	}
	var profiles []DeviceProfile
	if err = json.Unmarshal(b, &profiles); err != nil {
		return nil, fmt.Errorf("read device profiles: %w", err)
	}
	seen := map[string]bool{}
	for _, p := range profiles {
		if !validAVD(p.AVD) || p.ID != profileID(p.AVD) || seen[p.ID] {
			return nil, errors.New("invalid saved device profile identity")
		}
		if err := (ProfileRequest{Name: p.Name, Cores: p.Cores, MemoryMB: p.MemoryMB}).validate(); err != nil {
			return nil, fmt.Errorf("invalid saved device profile: %w", err)
		}
		seen[p.ID] = true
	}
	return profiles, nil
}
func (m *Manager) writeProfiles(profiles []DeviceProfile) error {
	if err := os.MkdirAll(m.root, 0700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(profiles, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(m.root, "profiles-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), filepath.Join(m.root, "device-profiles.json"))
}
func avdHome() string {
	if dir := os.Getenv("ANDROID_AVD_HOME"); dir != "" {
		return dir
	}
	if dir := os.Getenv("ANDROID_USER_HOME"); dir != "" {
		return filepath.Join(dir, "avd")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".android", "avd")
}
func importedProfile(avd string) DeviceProfile {
	p := DeviceProfile{ID: profileID(avd), Name: avd, AVD: avd, Hardware: "generic", Cores: 2, MemoryMB: 2048}
	if !validAVD(avd) {
		return p
	}
	path := filepath.Join(avdHome(), avd+".avd", "config.ini")
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return p
	}
	base, err := filepath.EvalSymlinks(avdHome())
	if err != nil {
		return p
	}
	rel, err := filepath.Rel(base, real)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return p
	}
	b, err := os.ReadFile(real)
	if err != nil || len(b) > 65536 {
		return p
	}
	for _, line := range strings.Split(string(b), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		n, _ := strconv.Atoi(value)
		switch key {
		case "hw.device.name":
			p.Hardware = value
		case "hw.lcd.width":
			p.Width = n
		case "hw.lcd.height":
			p.Height = n
		case "hw.cpu.ncore":
			if n >= 1 && n <= 8 {
				p.Cores = n
			}
		case "hw.ramSize":
			if n >= 1536 && n <= 8192 {
				p.MemoryMB = n - n%256
			}
		}
	}
	return p
}
func (m *Manager) profilesForAVDs(avds []string) ([]DeviceProfile, error) {
	m.profilesMu.Lock()
	defer m.profilesMu.Unlock()
	saved, err := m.readProfiles()
	if err != nil {
		return nil, err
	}
	result := []DeviceProfile{}
	for _, avd := range avds {
		if !validAVD(avd) {
			continue
		}
		p := importedProfile(avd)
		for _, stored := range saved {
			if stored.AVD == avd {
				p = stored
				break
			}
		}
		result = append(result, p)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}
func (m *Manager) Profiles(ctx context.Context) ([]DeviceProfile, error) {
	if !m.enabled {
		return nil, errors.New("Android is disabled")
	}
	list, err := output(ctx, "emulator", "-list-avds")
	if err != nil {
		return nil, fmt.Errorf("list installed emulators: %w", err)
	}
	return m.profilesForAVDs(strings.Fields(list))
}
func (m *Manager) SaveProfile(ctx context.Context, id string, r ProfileRequest) (DeviceProfile, error) {
	if err := r.validate(); err != nil {
		return DeviceProfile{}, err
	}
	profiles, err := m.Profiles(ctx)
	if err != nil {
		return DeviceProfile{}, err
	}
	var p DeviceProfile
	found := false
	for _, item := range profiles {
		if item.ID == id {
			p = item
			found = true
			break
		}
	}
	if !found {
		return p, errors.New("device profile not found")
	}
	m.profilesMu.Lock()
	defer m.profilesMu.Unlock()
	m.mu.Lock()
	running := active(m.device) && m.deviceAVD == p.AVD
	m.mu.Unlock()
	if running {
		return p, errors.New("stop this emulator before editing its profile")
	}
	saved, err := m.readProfiles()
	if err != nil {
		return p, err
	}
	p.Name = strings.TrimSpace(r.Name)
	p.Cores = r.Cores
	p.MemoryMB = r.MemoryMB
	replaced := false
	for i, item := range saved {
		if item.ID == id {
			saved[i] = p
			replaced = true
			break
		}
	}
	if !replaced {
		saved = append(saved, p)
	}
	if err = m.writeProfiles(saved); err != nil {
		return p, err
	}
	return p, nil
}
func (m *Manager) CreateProfile(ctx context.Context, r ProfileRequest) (DeviceProfile, error) {
	if !m.enabled {
		return DeviceProfile{}, errors.New("Android is disabled")
	}
	if err := r.validate(); err != nil {
		return DeviceProfile{}, err
	}
	if r.Hardware != "pixel_7" && r.Hardware != "pixel_9" {
		return DeviceProfile{}, errors.New("choose Pixel 7 or Pixel 9")
	}
	m.profilesMu.Lock()
	defer m.profilesMu.Unlock()
	m.mu.Lock()
	running := active(m.device)
	m.mu.Unlock()
	if running {
		return DeviceProfile{}, errors.New("stop the current emulator before creating a profile")
	}
	saved, err := m.readProfiles()
	if err != nil {
		return DeviceProfile{}, err
	}
	if len(saved) >= 24 {
		return DeviceProfile{}, errors.New("device profile limit reached (24)")
	}
	var nonce [6]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return DeviceProfile{}, err
	}
	avd := "okestra-" + r.Hardware + "-" + hex.EncodeToString(nonce[:])
	sdk := os.Getenv("ANDROID_HOME")
	if sdk == "" {
		sdk = os.Getenv("ANDROID_SDK_ROOT")
	}
	if sdk == "" {
		return DeviceProfile{}, errors.New("ANDROID_HOME is not configured")
	}
	image := "system-images;android-35;google_apis;x86_64"
	if _, err = os.Stat(filepath.Join(sdk, "system-images/android-35/google_apis/x86_64/package.xml")); err != nil {
		return DeviceProfile{}, errors.New("install the Android 35 Google APIs x86_64 system image before creating a device")
	}
	provisionCtx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	cmd := exec.CommandContext(provisionCtx, filepath.Join(sdk, "cmdline-tools/latest/bin/avdmanager"), "create", "avd", "--name", avd, "--package", image, "--device", r.Hardware)
	cmd.Stdin = strings.NewReader("no\n")
	if b, err := cmd.CombinedOutput(); err != nil {
		return DeviceProfile{}, fmt.Errorf("create device: %s: %w", strings.TrimSpace(string(b)), err)
	}
	p := importedProfile(avd)
	p.Name = strings.TrimSpace(r.Name)
	p.Cores = r.Cores
	p.MemoryMB = r.MemoryMB
	p.Hardware = r.Hardware
	saved = append(saved, p)
	if err = m.writeProfiles(saved); err != nil {
		return p, fmt.Errorf("AVD created but profile could not be saved: %w", err)
	}
	return p, nil
}
func (m *Manager) StartProfile(ctx context.Context, id string) error {
	profiles, err := m.Profiles(ctx)
	if err != nil {
		return err
	}
	for _, p := range profiles {
		if p.ID == id {
			return m.startDevice(ctx, p.AVD, p.Cores, p.MemoryMB, p.ID)
		}
	}
	return errors.New("device profile not found")
}
