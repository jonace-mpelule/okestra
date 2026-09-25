package client

import (
	"context"
	"github.com/gorilla/websocket"
	"github.com/jonace-mpelule/okestra/internal/protocol"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPortForwardRenewsReservationAfterServiceRestart(t *testing.T) {
	created := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/port-forwards":
			created++
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"id":"new"}`))
		case "/v1/port-forwards/old/ws":
			http.NotFound(w, r)
		case "/v1/port-forwards/new/ws":
			conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
			if err == nil {
				conn.Close()
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	f := &PortForward{api: NewAPI(protocol.AgentProfile{URL: server.URL}), id: "old", req: protocol.PortForwardRequest{ContainerID: "app", LocalPort: 8080, RemotePort: 80}}
	conn, err := f.dial(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if f.id != "new" || created != 1 {
		t.Fatalf("reservation = %s, created = %d", f.id, created)
	}
}

func TestWebSocketURLPreservesQuery(t *testing.T) {
	tests := []struct {
		base string
		path string
		want string
	}{
		{
			base: "http://100.101.102.103:8088",
			path: "/v1/containers/urbanman/logs/ws?follow=1",
			want: "ws://100.101.102.103:8088/v1/containers/urbanman/logs/ws?follow=1",
		},
		{
			base: "https://example.test",
			path: "/v1/operations/build/ws",
			want: "wss://example.test/v1/operations/build/ws",
		},
	}
	for _, tt := range tests {
		if got := wsURL(tt.base, tt.path); got != tt.want {
			t.Errorf("wsURL(%q, %q) = %q, want %q", tt.base, tt.path, got, tt.want)
		}
	}
}
