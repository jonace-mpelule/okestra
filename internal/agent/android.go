package agent

import (
	"context"
	"encoding/json"
	"fmt"
	androidruntime "github.com/jonace-mpelule/okestra/internal/android"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func (s *Server) handleAndroid(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/android/")
	if path == "status" && r.Method == http.MethodGet {
		writeJSON(w, 200, s.android.Status(r.Context()))
		return
	}
	if !s.android.Enabled() {
		writeError(w, 503, "android_disabled", "set OKESTRA_ANDROID_ENABLED=1 on the server")
		return
	}
	if path == "profiles" || strings.HasPrefix(path, "profiles/") {
		if path == "profiles" && r.Method == http.MethodGet {
			profiles, err := s.android.Profiles(r.Context())
			if err != nil {
				writeError(w, 400, "profiles_error", err.Error())
				return
			}
			writeJSON(w, 200, profiles)
			return
		}
		var req androidruntime.ProfileRequest
		if r.Method != http.MethodPost && r.Method != http.MethodPut {
			writeError(w, 405, "method_not_allowed", "GET, POST or PUT required")
			return
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&req); err != nil {
			writeError(w, 400, "invalid_request", err.Error())
			return
		}
		var p androidruntime.DeviceProfile
		var err error
		if path == "profiles" && r.Method == http.MethodPost {
			p, err = s.android.CreateProfile(r.Context(), req)
		} else if strings.HasPrefix(path, "profiles/") && r.Method == http.MethodPut {
			p, err = s.android.SaveProfile(r.Context(), strings.TrimPrefix(path, "profiles/"), req)
		} else {
			writeError(w, 405, "method_not_allowed", "unsupported profile operation")
			return
		}
		if err != nil {
			writeError(w, 400, "profiles_error", err.Error())
			return
		}
		writeJSON(w, 200, p)
		return
	}
	if path == "adb/ws" && r.Method == http.MethodGet {
		if !s.android.DeviceActive() {
			writeError(w, 409, "device_stopped", "start the managed device first")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		tcp, e := (&net.Dialer{}).DialContext(ctx, "tcp", "127.0.0.1:5555")
		if e != nil {
			writeError(w, 502, "adb_unavailable", e.Error())
			return
		}
		defer tcp.Close()
		ws, e := s.upgrader.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer ws.Close()
		ws.SetReadLimit(1024 * 1024)
		done := make(chan error, 2)
		go pumpNetToWS(ws, tcp, done)
		go pumpWSToNet(ws, tcp, done)
		<-done
		return
	}
	parts := strings.Split(path, "/")
	if len(parts) != 2 {
		writeError(w, 404, "not_found", "unknown Android operation")
		return
	}
	name, action := parts[0], parts[1]
	if name != "device" && action != "stop" && action != "logs" && !androidruntime.DevelopmentEnabled() {
		writeError(w, 410, "development_archived", "Remote Flutter and Expo workflows are archived; use local development tools with the remote ADB device.")
		return
	}
	if action == "logs" && r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]string{"output": s.android.Logs(name)})
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, 405, "method_not_allowed", "POST required")
		return
	}
	var e error
	switch action {
	case "sync":
		e = s.android.SyncProject(name, androidFramework(r.URL.Query().Get("framework")), http.MaxBytesReader(w, r.Body, 256*1024*1024))
	case "start":
		var req struct {
			Profile   string                     `json:"profile"`
			AVD       string                     `json:"avd"`
			Target    string                     `json:"target"`
			Framework string                     `json:"framework"`
			Expo      androidruntime.ExpoOptions `json:"expo"`
		}
		if e = json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&req); e == nil {
			if name == "device" {
				if req.Profile != "" {
					e = s.android.StartProfile(r.Context(), req.Profile)
				} else {
					e = s.android.StartDevice(r.Context(), req.AVD)
				}
			} else {
				e = s.android.RunProject(name, req.Target, req.Framework, req.Expo)
			}
		}
	case "stop":
		e = s.android.Stop(name)
	case "reload":
		e = s.android.Reload(name, false)
	case "restart":
		var req struct {
			Expo *androidruntime.ExpoOptions `json:"expo"`
		}
		if r.Body != nil {
			e = json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&req)
			if e == io.EOF {
				e = nil
			}
		}
		if e == nil {
			e = s.android.Restart(name, req.Expo)
		}
	case "dev-menu":
		e = s.android.DevMenu(name)
	default:
		e = fmt.Errorf("unknown Android operation: %s", action)
	}
	if e != nil {
		writeError(w, 400, "android_error", e.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func androidFramework(value string) string {
	if value == "" {
		return "flutter"
	}
	return value
}
