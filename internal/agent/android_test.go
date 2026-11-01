package agent

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAndroidRoutesRequireAuthenticationAndOptIn(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_ENABLED", "")
	s := NewServer("", "secret", t.TempDir(), nil)
	for _, tc := range []struct {
		path, method, token string
		code                int
	}{{"status", "GET", "", 401}, {"device/start", "POST", "", 401}, {"status", "GET", "secret", 200}, {"adb/ws", "GET", "secret", 503}, {"device/start", "POST", "secret", 503}} {
		r := httptest.NewRequest(tc.method, "/v1/android/"+tc.path, nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
	}
}

func TestDeviceProfilesAreAuthenticatedAndProjectActionsArchived(t *testing.T) {
	t.Setenv("OKESTRA_ANDROID_ENABLED", "1")
	t.Setenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED", "")
	s := NewServer("", "secret", t.TempDir(), nil)
	for _, tc := range []struct {
		path, method, token, body string
		code                      int
	}{
		{"profiles", "GET", "", "", 401},
		{"profiles", "POST", "", `{}`, 401},
		{"profiles/device", "PUT", "", `{}`, 401},
		{"sample/start", "POST", "secret", `{}`, 410},
		{"sample/sync", "POST", "secret", ``, 410},
		{"sample/reload", "POST", "secret", `{}`, 410},
		{"sample/stop", "POST", "secret", `{}`, 200},
		{"profiles", "DELETE", "secret", ``, 405},
		{"profiles", "POST", "secret", `{"name":"bad","cores":99}`, 400},
		{"profiles", "POST", "secret", `invalid JSON`, 400},
	} {
		r := httptest.NewRequest(tc.method, "/v1/android/"+tc.path, strings.NewReader(tc.body))
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
	}
	t.Setenv("OKESTRA_ANDROID_DEVELOPMENT_ENABLED", "1")
	r := httptest.NewRequest("POST", "/v1/android/sample/reload", strings.NewReader(`{}`))
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	if w.Code != 400 || strings.Contains(w.Body.String(), "development_archived") {
		t.Fatal("legacy opt-in ignored", w.Code, w.Body.String())
	}
}
