//go:build darwin

package tun

import (
	"context"
	"net"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Socket options only: no TUN, route, DNS or external connection is created.
func TestDarwinOutboundSocketBinding(t *testing.T) {
	iface, err := net.InterfaceByName("lo0")
	if err != nil { t.Fatal(err) }
	for _, tc := range []struct { name string; family, socketType, level, option int }{
		{"udp4", unix.AF_INET, unix.SOCK_DGRAM, unix.IPPROTO_IP, unix.IP_BOUND_IF},
		{"udp6", unix.AF_INET6, unix.SOCK_DGRAM, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF},
		{"tcp4", unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_IP, unix.IP_BOUND_IF},
		{"tcp6", unix.AF_INET6, unix.SOCK_STREAM, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fd, err := unix.Socket(tc.family, tc.socketType, 0)
			if err != nil { t.Fatal(err) }; defer unix.Close(fd)
			if tc.family == unix.AF_INET6 {
				if err := unix.SetsockoptInt(fd, unix.IPPROTO_IPV6, unix.IPV6_V6ONLY, 0); err != nil { t.Fatal(err) }
			}
			if err := setinterface(tc.name, "", uintptr(fd), iface); err != nil { t.Fatal(err) }
			bound, err := unix.GetsockoptInt(fd, tc.level, tc.option)
			if err != nil || bound != iface.Index { t.Fatalf("bound=%d expected=%d err=%v", bound, iface.Index, err) }
			if err := setinterface(tc.name, "", uintptr(fd), &net.Interface{Index: 0x7fffffff}); err == nil {
				t.Fatal("invalid interface must fail; binding errors must not be swallowed")
			}
		})
	}
}

func TestDarwinWildcardUDPBinding(t *testing.T) {
	iface, err := net.InterfaceByName("lo0")
	if err != nil { t.Fatal(err) }
	// Match Xray's wildcard ListenPacket path: Darwin may select a dual-stack socket.
	receiver, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }; defer receiver.Close()
	config := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
		var binding error
		if err := raw.Control(func(fd uintptr) { binding = setinterface(network, address, fd, iface) }); err != nil { return err }
		return binding
	}}
	sender, err := config.ListenPacket(context.Background(), "udp", "0.0.0.0:0")
	if err != nil { t.Fatal(err) }; defer sender.Close()
	_ = receiver.SetDeadline(time.Now().Add(time.Second))
	if _, err := sender.WriteTo([]byte("binding-ok"), receiver.LocalAddr()); err != nil { t.Fatal(err) }
	buffer := make([]byte, 64)
	n, _, err := receiver.ReadFrom(buffer)
	if err != nil || string(buffer[:n]) != "binding-ok" { t.Fatalf("UDP loopback exchange failed: %v", err) }
}
