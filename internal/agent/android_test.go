package agent

import (
	"net/http/httptest"
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
