//go:build darwin

package agent

import (
	"errors"
	"os/exec"
)

func newTTYCommandConn(*exec.Cmd) (ExecStream, error) {
	return nil, errors.New("interactive exec requires the Linux service")
}
