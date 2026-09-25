package client

import "testing"

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
