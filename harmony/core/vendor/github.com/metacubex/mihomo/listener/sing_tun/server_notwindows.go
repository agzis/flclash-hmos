//go:build !windows

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
	"syscall"
)

func tunNew(options tun.Options) (tun.Tun, error) {
	return tun.New(options)
}

func closeUnclaimedTunFD(fd int) error {
	return syscall.Close(fd)
}
