package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/jonace-mpelule/okestra/internal/version"
)

const releases = "https://github.com/jonace-mpelule/okestra/releases"

var tagPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

type Release struct {
	Tag         string
	Archive     string
	Binary      []byte
	archiveData []byte
}

func Fetch(ctx context.Context, role string) (Release, error) { return fetch(ctx, role, releases) }

func fetch(ctx context.Context, role, base string) (Release, error) {
	if role != "okestra" && role != "okestra-service" {
		return Release{}, errors.New("invalid upgrade role")
	}
	if role == "okestra-service" && runtime.GOOS != "linux" {
		return Release{}, errors.New("server upgrade requires Linux")
	}
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		return Release{}, errors.New("unsupported operating system")
	}
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		return Release{}, errors.New("unsupported architecture")
	}
	client := &http.Client{Timeout: 60 * time.Second}
	get := func(target string, limit int64) ([]byte, string, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			return nil, "", err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, "", err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, "", fmt.Errorf("release request failed: HTTP %d", resp.StatusCode)
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
		if err != nil {
			return nil, "", err
		}
		if int64(len(data)) > limit {
			return nil, "", errors.New("release asset is too large")
		}
		return data, resp.Request.URL.String(), nil
	}
	_, latestURL, err := get(base+"/latest", 2<<20)
	if err != nil {
		return Release{}, err
	}
	const marker = "/tag/"
	idx := strings.LastIndex(latestURL, marker)
	if idx < 0 {
		return Release{}, fmt.Errorf("unexpected latest release URL: %s", latestURL)
	}
	tag := latestURL[idx+len(marker):]
	if !tagPattern.MatchString(tag) {
		return Release{}, fmt.Errorf("invalid release tag %q", tag)
	}
	platform := runtime.GOOS
	if role == "okestra-service" {
		platform = "linux"
	}
	archive := fmt.Sprintf("%s_%s_%s_%s.tar.gz", role, strings.TrimPrefix(tag, "v"), platform, runtime.GOARCH)
	baseAsset := base + "/download/" + tag + "/"
	archiveData, _, err := get(baseAsset+archive, 100<<20)
	if err != nil {
		return Release{}, err
	}
	sums, _, err := get(baseAsset+"SHA256SUMS", 1<<20)
	if err != nil {
		return Release{}, err
	}
	want := ""
	for _, line := range strings.Split(string(sums), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == archive {
			want = fields[0]
			break
		}
	}
	if len(want) != 64 {
		return Release{}, fmt.Errorf("checksum not published for %s", archive)
	}
	actual := sha256.Sum256(archiveData)
	if !strings.EqualFold(hex.EncodeToString(actual[:]), want) {
		return Release{}, errors.New("release SHA-256 mismatch")
	}
	binary, err := extractBinary(archiveData, role)
	if err != nil {
		return Release{}, err
	}
	return Release{Tag: tag, Archive: archive, Binary: binary, archiveData: archiveData}, nil
}

func extractBinary(data []byte, name string) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	tr := tar.NewReader(zr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if filepath.Base(hdr.Name) != name {
			continue
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			return nil, errors.New("release binary is not a regular file")
		}
		if hdr.Size < 1 || hdr.Size > 100<<20 {
			return nil, errors.New("invalid release binary size")
		}
		binary, err := io.ReadAll(io.LimitReader(tr, 100<<20+1))
		if err != nil {
			return nil, err
		}
		if int64(len(binary)) != hdr.Size {
			return nil, errors.New("truncated release binary")
		}
		return binary, nil
	}
	return nil, fmt.Errorf("%s not found in release archive", name)
}

// Upgrade replaces the binary only after release verification. A server
// upgrade rolls back the old binary if systemd fails to activate the service.
func Upgrade(ctx context.Context, role string, checkOnly bool, out io.Writer) error {
	release, err := Fetch(ctx, role)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "installed: %s\nlatest: %s\n", version.Version, release.Tag)
	if version.Version == strings.TrimPrefix(release.Tag, "v") {
		fmt.Fprintln(out, "already up to date")
		return nil
	}
	if checkOnly {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if strings.Contains(filepath.ToSlash(exe), ".app/Contents/Helpers/") {
		return errors.New("upgrade using the installed terminal CLI; bundled helpers are updated with the whole app")
	}
	if filepath.Base(exe) != role {
		return fmt.Errorf("run the installed %s binary to upgrade (currently %s)", role, exe)
	}
	if role == "okestra-service" && os.Geteuid() != 0 {
		return errors.New("run sudo okestra-service upgrade on the server")
	}
	tmp, err := os.CreateTemp("", "okestra-upgrade-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(release.Binary); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	backup, err := os.CreateTemp("", "okestra-backup-*")
	if err != nil {
		return err
	}
	defer os.Remove(backup.Name())
	old, err := os.Open(exe)
	if err != nil {
		backup.Close()
		return err
	}
	if _, err := io.Copy(backup, old); err != nil {
		old.Close()
		backup.Close()
		return err
	}
	old.Close()
	if err := backup.Chmod(0o755); err != nil {
		backup.Close()
		return err
	}
	backup.Close()
	install := func(runCtx context.Context, source string) error {
		stage := exe + ".new"
		args := []string{"install", "-m", "0755", source, stage}
		useSudo := os.Geteuid() != 0 && !canWrite(filepath.Dir(exe))
		cmd := exec.CommandContext(runCtx, "install", args[1:]...)
		if useSudo {
			cmd = exec.CommandContext(runCtx, "sudo", args...)
		}
		cmd.Stdin = os.Stdin
		cmd.Stdout = out
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return err
		}
		move := exec.CommandContext(runCtx, "mv", stage, exe)
		if useSudo {
			move = exec.CommandContext(runCtx, "sudo", "mv", stage, exe)
		}
		move.Stdin = os.Stdin
		move.Stdout = out
		move.Stderr = os.Stderr
		return move.Run()
	}
	if err := install(ctx, tmp.Name()); err != nil {
		return err
	}
	if role == "okestra-service" {
		restore := func(cause error) error {
			restoreCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			if err := install(restoreCtx, backup.Name()); err != nil {
				return fmt.Errorf("%v; rollback failed: %w", cause, err)
			}
			if err := exec.CommandContext(restoreCtx, "systemctl", "restart", "okestra-service").Run(); err != nil {
				return fmt.Errorf("%v; old binary restored but service restart failed: %w", cause, err)
			}
			return fmt.Errorf("%v; previous binary restored", cause)
		}
		if err := exec.CommandContext(ctx, "systemctl", "restart", "okestra-service").Run(); err != nil {
			return restore(fmt.Errorf("service restart failed: %w", err))
		}
		select {
		case <-ctx.Done():
			return restore(ctx.Err())
		case <-time.After(2 * time.Second):
		}
		if err := exec.CommandContext(ctx, "systemctl", "is-active", "--quiet", "okestra-service").Run(); err != nil {
			return restore(errors.New("service inactive after upgrade"))
		}
	}
	if role == "okestra" && runtime.GOOS == "darwin" {
		if err := installMenuApp(release.archiveData); err != nil {
			return fmt.Errorf("CLI upgraded, but Mac app update failed: %w", err)
		}
	}
	fmt.Fprintf(out, "upgraded %s to %s\n", role, release.Tag)
	return nil
}

// extractMacApps preserves complete signed bundles, including the matching CLI and capture component.
func extractMacApps(archive []byte, dir string) ([]string, error) {
	zr, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	tr := tar.NewReader(zr)
	seen := map[string]bool{}
	apps := map[string]bool{}
	var total int64
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		path := strings.TrimPrefix(header.Name, "./")
		app, relative, found := strings.Cut(path, "/")
		if !found || (app != "Okestra Menu.app" && app != "Okestra Device.app") {
			continue
		}
		if header.Typeflag == tar.TypeDir {
			continue
		}
		if header.Typeflag != tar.TypeReg || !strings.HasPrefix(relative, "Contents/") || filepath.ToSlash(filepath.Clean(relative)) != relative || strings.Contains(relative, "\\") || seen[path] {
			return nil, errors.New("invalid or duplicate Mac app archive entry")
		}
		total += header.Size
		if header.Size < 0 || header.Size > 50<<20 || total > 150<<20 || len(seen) > 300 {
			return nil, errors.New("Mac app archive exceeds size limits")
		}
		target := filepath.Join(dir, app, relative)
		if err = os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return nil, err
		}
		mode := os.FileMode(0644)
		if strings.HasPrefix(relative, "Contents/MacOS/") || strings.HasPrefix(relative, "Contents/Helpers/") {
			mode = 0755
		}
		f, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			return nil, err
		}
		_, err = io.CopyN(f, tr, header.Size)
		closeErr := f.Close()
		if err != nil {
			return nil, err
		}
		if closeErr != nil {
			return nil, closeErr
		}
		seen[path] = true
		apps[app] = true
	}
	var result []string
	for _, app := range []string{"Okestra Menu.app", "Okestra Device.app"} {
		if !apps[app] {
			continue
		}
		executable := "OkestraMenu"
		if app == "Okestra Device.app" {
			executable = "OkestraDevice"
		}
		if !seen[app+"/Contents/Info.plist"] || !seen[app+"/Contents/MacOS/"+executable] {
			return nil, fmt.Errorf("incomplete %s in release", app)
		}
		if app == "Okestra Device.app" && (!seen[app+"/Contents/Helpers/okestra"] || !seen[app+"/Contents/Resources/scrcpy-server-3.3.4.jar"]) {
			return nil, errors.New("incomplete device capture bundle")
		}
		result = append(result, app)
	}
	return result, nil
}
func installMenuApp(archive []byte) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	apps := filepath.Join(home, "Applications")
	if err = os.MkdirAll(apps, 0755); err != nil {
		return err
	}
	stage, err := os.MkdirTemp(apps, ".okestra-update-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	names, err := extractMacApps(archive, stage)
	if err != nil {
		return err
	}
	for _, name := range names {
		target := filepath.Join(apps, name)
		backup := filepath.Join(stage, name+".previous")
		hadOld := false
		if _, err = os.Lstat(target); err == nil {
			if err = os.Rename(target, backup); err != nil {
				return err
			}
			hadOld = true
		} else if !os.IsNotExist(err) {
			return err
		}
		if err = os.Rename(filepath.Join(stage, name), target); err != nil {
			if hadOld {
				_ = os.Rename(backup, target)
			}
			return err
		}
	}
	return nil
}

func canWrite(dir string) bool {
	f, err := os.CreateTemp(dir, ".okestra-write-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return true
}
