package protocol

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var dockerName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

func (r BuildRequest) Validate() error {
	if strings.TrimSpace(r.Tag) == "" {
		return errors.New("tag is required")
	}
	return nil
}

func (r RunRequest) Validate() error {
	if strings.TrimSpace(r.Image) == "" {
		return errors.New("image is required")
	}
	for _, pf := range r.AutoForward {
		if err := validatePortMapping(pf); err != nil {
			return err
		}
	}
	for _, name := range []string{r.Name, r.Network, r.NetworkAlias} {
		if name != "" && !dockerName.MatchString(name) {
			return fmt.Errorf("invalid Docker name %q", name)
		}
	}
	if r.Restart != "" && r.Restart != "no" && r.Restart != "always" && r.Restart != "unless-stopped" && r.Restart != "on-failure" {
		return fmt.Errorf("invalid restart policy %q", r.Restart)
	}
	for _, mount := range r.Mounts {
		if !dockerName.MatchString(mount.Source) || !strings.HasPrefix(mount.Target, "/") || strings.ContainsAny(mount.Target, ",\r\n") {
			return fmt.Errorf("invalid volume mount %q:%q", mount.Source, mount.Target)
		}
	}
	for key := range r.Labels {
		if strings.TrimSpace(key) == "" || strings.ContainsAny(key, "\r\n") {
			return fmt.Errorf("invalid label key %q", key)
		}
	}
	if r.Health != nil {
		if strings.TrimSpace(r.Health.Command) == "" || r.Health.IntervalSeconds < 0 || r.Health.Retries < 0 {
			return errors.New("invalid health check")
		}
	}
	return nil
}

func (r PortForwardRequest) Validate() error {
	if strings.TrimSpace(r.ContainerID) == "" {
		return errors.New("container_id is required")
	}
	return validatePortMapping(PortMapping{LocalPort: r.LocalPort, RemotePort: r.RemotePort})
}

func (r ExecRequest) Validate() error {
	if len(r.Command) == 0 {
		return errors.New("command is required")
	}
	return nil
}

func validatePortMapping(pm PortMapping) error {
	if pm.LocalPort < 1 || pm.LocalPort > 65535 {
		return fmt.Errorf("invalid local port: %d", pm.LocalPort)
	}
	if pm.RemotePort < 1 || pm.RemotePort > 65535 {
		return fmt.Errorf("invalid remote port: %d", pm.RemotePort)
	}
	return nil
}
