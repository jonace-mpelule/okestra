package protocol

import "time"

const (
	ProtocolVersion       = 2
	ExecFailureCloseCode  = 4000
	ExecStdinClosedMarker = "stdin_closed"
)

type ServiceProfile struct {
	Name               string            `json:"name"`
	URL                string            `json:"url"`
	Token              string            `json:"token"`
	DefaultWorkspace   string            `json:"default_workspace,omitempty"`
	NamedPortForwards  map[string]string `json:"named_port_forwards,omitempty"`
	InsecureSkipVerify bool              `json:"insecure_skip_verify,omitempty"`
}

type AgentProfile = ServiceProfile

type BuildRequest struct {
	Tag        string            `json:"tag"`
	ContextDir string            `json:"context_dir,omitempty"`
	Dockerfile string            `json:"dockerfile,omitempty"`
	BuildArgs  map[string]string `json:"build_args,omitempty"`
}

type RunRequest struct {
	Image       string            `json:"image"`
	Name        string            `json:"name,omitempty"`
	Command     []string          `json:"command,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	WorkingDir  string            `json:"working_dir,omitempty"`
	AutoForward []PortMapping     `json:"auto_forward,omitempty"`
}

type PortForwardRequest struct {
	ContainerID string `json:"container_id"`
	LocalPort   int    `json:"local_port"`
	RemotePort  int    `json:"remote_port"`
}

type ExecRequest struct {
	Command []string `json:"command"`
	TTY     bool     `json:"tty"`
	Stdin   bool     `json:"stdin"`
	Stdout  bool     `json:"stdout"`
	Stderr  bool     `json:"stderr"`
}

type OperationStatus struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	State     string    `json:"state"`
	Message   string    `json:"message,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type StreamEnvelope struct {
	OperationID string    `json:"operation_id,omitempty"`
	Stream      string    `json:"stream"`
	Type        string    `json:"type"`
	Data        []byte    `json:"data,omitempty"`
	Message     string    `json:"message,omitempty"`
	Timestamp   time.Time `json:"timestamp"`
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type BuildAccepted struct {
	OperationID string `json:"operation_id"`
}

type ExecCreated struct {
	ExecID string `json:"exec_id"`
}

type ContainerSummary struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Image   string   `json:"image"`
	Status  string   `json:"status"`
	Command string   `json:"command"`
	Ports   []string `json:"ports,omitempty"`
}

type ImageSummary struct {
	ID      string   `json:"id"`
	Tags    []string `json:"tags,omitempty"`
	Size    int64    `json:"size"`
	Created int64    `json:"created"`
}

type RunResult struct {
	ContainerID string        `json:"container_id"`
	Forwards    []PortMapping `json:"forwards,omitempty"`
}

type PortMapping struct {
	LocalPort  int `json:"local_port"`
	RemotePort int `json:"remote_port"`
}

type ServiceStatus struct {
	ServiceHealthy   bool              `json:"service_healthy"`
	DockerHealthy    bool              `json:"docker_healthy"`
	Version          string            `json:"version,omitempty"`
	ProtocolVersion  int               `json:"protocol_version"`
	ActiveOperations []OperationStatus `json:"active_operations,omitempty"`
	ActiveTunnels    []TunnelSession   `json:"active_tunnels,omitempty"`
}

type TunnelSession struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Target    string    `json:"target,omitempty"`
	State     string    `json:"state"`
	CreatedAt time.Time `json:"created_at"`
}

type OperationEvent struct {
	OperationID string    `json:"operation_id"`
	State       string    `json:"state"`
	Message     string    `json:"message,omitempty"`
	Timestamp   time.Time `json:"timestamp"`
}

type DoctorCheck struct {
	Name    string `json:"name"`
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

type DoctorReport struct {
	Endpoint string        `json:"endpoint"`
	OK       bool          `json:"ok"`
	Checks   []DoctorCheck `json:"checks"`
}
