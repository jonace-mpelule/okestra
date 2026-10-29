package android

import (
	"os/exec"
	"syscall"
)

func processAttributes() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setpgid: true} }
func killProcess(cmd *exec.Cmd)               { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
