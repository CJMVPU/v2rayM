//go:build darwin

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

var bedrockMagic = []byte{0, 255, 255, 0, 254, 254, 254, 254, 253, 253, 253, 253, 18, 52, 86, 120}

func udpPacket(kind string) (string, string, []byte, func([]byte) bool) {
	switch kind {
	case "dns":
		b := []byte("\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x06google\x03com\x00\x00\x01\x00\x01")
		rand.Read(b[:2])
		return "8.8.8.8", "53", b, func(r []byte) bool {
			return len(r) >= 12 && bytes.Equal(b[:2], r[:2]) && r[2]&128 != 0 && r[3]&15 == 0 && binary.BigEndian.Uint16(r[6:8]) > 0
		}
	case "stun":
		b := make([]byte, 20)
		b[1] = 1
		binary.BigEndian.PutUint32(b[4:8], 0x2112a442)
		rand.Read(b[8:])
		return "stun.voztovoice.org", "3478", b, func(r []byte) bool {
			return len(r) >= 20 && r[0] == 1 && (r[1] == 1 || r[1] == 17) && bytes.Equal(r[4:20], b[4:])
		}
	case "mcbe":
		b := make([]byte, 33)
		b[0] = 1
		binary.BigEndian.PutUint64(b[1:9], uint64(time.Now().UnixMilli()))
		copy(b[9:25], bedrockMagic)
		rand.Read(b[25:])
		return "pms.mc-complex.com", "19132", b, func(r []byte) bool {
			if len(r) < 35 || r[0] != 0x1c || !bytes.Equal(r[17:33], bedrockMagic) {
				return false
			}
			end := 35 + int(binary.BigEndian.Uint16(r[33:35]))
			if end > len(r) {
				return false
			}
			fields := strings.Split(string(r[35:end]), ";")
			if len(fields) < 9 {
				return false
			}
			switch fields[8] {
			case "Survival", "Creative", "Adventure", "Spectator":
				return true
			}
			return false
		}
	default:
		b := make([]byte, 48)
		b[0] = 0x23
		return "pool.ntp.org", "123", b, func(r []byte) bool { return len(r) >= 48 && r[0]&7 == 4 }
	}
}

func (p *diagnostic) udpProbe(target string) (probeResult, error) {
	kind, address, _ := strings.Cut(target, ":")
	host, port, packet, valid := udpPacket(strings.ToLower(kind))
	if address != "" {
		if h, n, err := net.SplitHostPort(address); err == nil {
			host, port = h, n
		} else {
			host = strings.Trim(address, "[]")
		}
	}
	dest, err := xnet.ParseDestination("udp:" + net.JoinHostPort(host, port))
	if err != nil || dest.Port == 0 {
		return probeResult{}, fmt.Errorf("invalid UDP target")
	}
	ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
	defer cancel()
	c, err := p.dial(ctx, dest, "")
	if err != nil {
		return probeResult{}, err
	}
	// Xray logical connections have no socket deadline. Interrupt the pipe on timeout.
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer func() {
		if stop() {
			c.Close()
		}
	}()
	result := probeResult{Delay: -1}
	reply := make([]byte, 65535)
	for attempt := 0; attempt < 2; attempt++ {
		t := time.Now()
		if _, err = c.Write(packet); err != nil {
			break
		}
		var n int
		if n, err = c.Read(reply); err != nil {
			break
		}
		if valid(reply[:n]) {
			delay := int(time.Since(t).Milliseconds())
			if result.Delay < 0 || delay < result.Delay {
				result.Delay = delay
			}
		}
	}
	if p.ctx.Err() != nil {
		return result, p.ctx.Err()
	}
	return result, nil
}
