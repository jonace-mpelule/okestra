//go:build linux

package agent

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"
)

type ttyCommandConn struct {
	master   *os.File
	cmd      *exec.Cmd
	waitOnce sync.Once
	waitErr  error
}

func newTTYCommandConn(cmd *exec.Cmd) (ExecStream, error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, fmt.Errorf("open pseudo-terminal: %w", err)
	}
	var unlock int32
	if err := ioctlPointer(master.Fd(), syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)); err != nil {
		master.Close()
		return nil, fmt.Errorf("unlock pseudo-terminal: %w", err)
	}
	var number uint32
	if err := ioctlPointer(master.Fd(), syscall.TIOCGPTN, unsafe.Pointer(&number)); err != nil {
		master.Close()
		return nil, fmt.Errorf("find pseudo-terminal: %w", err)
	}
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", number), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return nil, fmt.Errorf("open pseudo-terminal slave: %w", err)
	}
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		slave.Close()
		master.Close()
		return nil, err
	}
	_ = slave.Close()
	return &ttyCommandConn{master: master, cmd: cmd}, nil
}

func ioctlPointer(fd uintptr, request uintptr, value unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(value))
	if errno != 0 {
		return errno
	}
	return nil
}

func (c *ttyCommandConn) Read(p []byte) (int, error) {
	n, err := c.master.Read(p)
	if errors.Is(err, syscall.EIO) || err == io.EOF {
		c.waitOnce.Do(func() { c.waitErr = c.cmd.Wait() })
		if c.waitErr != nil {
			return n, c.waitErr
		}
		return n, io.EOF
	}
	return n, err
}

func (c *ttyCommandConn) Write(p []byte) (int, error) { return c.master.Write(p) }

func (c *ttyCommandConn) CloseInput() error {
	_, err := c.master.Write([]byte{4})
	return err
}

func (c *ttyCommandConn) Close() error { return c.master.Close() }
