//go:build darwin && !ios

package net

import (
	stderrors "errors"
	stdnet "net"
	"os"
	"testing"
)

// Match UDP senders that remain wildcard-bound after sending a datagram.
// Only loopback sockets are used; no TUN, routes, or system DNS are changed.
func TestV2rayMProcessWildcardUDP(t *testing.T) {
	receiver, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	remote := receiver.LocalAddr().(*stdnet.UDPAddr)
	for _, address := range []string{"127.0.0.1:0", "0.0.0.0:0", "[::]:0"} {
		t.Run(address, func(t *testing.T) {
			sender, err := stdnet.ListenPacket("udp", address)
			if err != nil {
				t.Fatal(err)
			}
			defer sender.Close()
			if _, err = sender.WriteTo([]byte("process-owner-test"), remote); err != nil {
				t.Fatal(err)
			}
			local := sender.LocalAddr().(*stdnet.UDPAddr)
			pid, name, path, err := FindProcess("udp", "127.0.0.1", uint16(local.Port), "127.0.0.1", uint16(remote.Port))
			if err != nil {
				t.Fatal(err)
			}
			if pid != os.Getpid() || name == "" || path == "" {
				t.Fatalf("wrong owner: %d %s %s", pid, name, path)
			}
		})
	}
}

// Closing a UDP socket before routing its queued packet leaves no discoverable owner.
func TestV2rayMClosedUDPProcess(t *testing.T) {
	sender, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := sender.LocalAddr().(*stdnet.UDPAddr).Port
	sender.Close()
	_, _, _, err = FindProcess("udp", "127.0.0.1", uint16(port), "127.0.0.1", 443)
	if err == nil || !stderrors.Is(err, ErrProcessNotFound) {
		t.Fatalf("expected an unavailable owner for closed socket, got %v", err)
	}
}
