package protocol

import "testing"

func TestBuildRequestValidate(t *testing.T) {
	if err := (BuildRequest{}).Validate(); err == nil {
		t.Fatal("expected tag validation error")
	}
	if err := (BuildRequest{Tag: "app:latest"}).Validate(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestPortForwardRequestValidate(t *testing.T) {
	err := (PortForwardRequest{ContainerID: "abc", LocalPort: 0, RemotePort: 8080}).Validate()
	if err == nil {
		t.Fatal("expected port validation error")
	}
}
