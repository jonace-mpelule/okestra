package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
)

func macArchive(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tr := tar.NewWriter(gz)
	for path, value := range files {
		if e := tr.WriteHeader(&tar.Header{Name: path, Typeflag: tar.TypeReg, Mode: 0755, Size: int64(len(value))}); e != nil {
			t.Fatal(e)
		}
		_, _ = tr.Write([]byte(value))
	}
	_ = tr.Close()
	_ = gz.Close()
	return b.Bytes()
}
func TestMacBundleExtractionPreservesDeviceResources(t *testing.T) {
	files := map[string]string{"Okestra Menu.app/Contents/Info.plist": "plist", "Okestra Menu.app/Contents/MacOS/OkestraMenu": "binary", "Okestra Menu.app/Contents/Helpers/okestra": "cli", "Okestra Device.app/Contents/Info.plist": "plist", "Okestra Device.app/Contents/MacOS/OkestraDevice": "binary", "Okestra Device.app/Contents/Helpers/okestra": "cli", "Okestra Device.app/Contents/Resources/scrcpy-server-3.3.4.jar": "jar", "Okestra Device.app/Contents/_CodeSignature/CodeResources": "signature"}
	dir := t.TempDir()
	names, e := extractMacApps(macArchive(t, files), dir)
	if e != nil {
		t.Fatal(e)
	}
	if len(names) != 2 {
		t.Fatal(names)
	}
	for p, want := range files {
		b, e := os.ReadFile(filepath.Join(dir, p))
		if e != nil || string(b) != want {
			t.Fatalf("%s: %q %v", p, b, e)
		}
	}
	for _, bad := range []string{"Okestra Device.app/Contents/../../escape", "Okestra Menu.app/Contents/a/../escape", "Okestra Device.app/Contents/a\\escape"} {
		files[bad] = "unsafe"
		if _, e := extractMacApps(macArchive(t, files), t.TempDir()); e == nil {
			t.Fatal("accepted", bad)
		}
		delete(files, bad)
	}
	delete(files, "Okestra Device.app/Contents/Helpers/okestra")
	if _, e := extractMacApps(macArchive(t, files), t.TempDir()); e == nil {
		t.Fatal("accepted incomplete device bundle")
	}
}
