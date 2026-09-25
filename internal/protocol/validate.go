package protocol

import (
	"errors"
	"fmt"
	"strings"
)

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
