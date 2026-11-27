package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var be = binary.BigEndian

func u16(n int) []byte { return be.AppendUint16(nil, uint16(n)) }
func exact(r io.Reader, n int) ([]byte, error) {
	b := make([]byte, n)
	_, e := io.ReadFull(r, b)
	return b, e
}
func mustRead(r io.Reader, n int) []byte { b, e := exact(r, n); check(e); return b }
func hexBytes(s string) []byte           { b, e := hex.DecodeString(s); check(e); return b }
func udpPeer() *net.UDPConn {
	s, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	check(e)
	return s
}
func readUDP(p *net.UDPConn) ([]byte, *net.UDPAddr) {
	p.SetReadDeadline(time.Now().Add(7 * time.Second))
	b := make([]byte, 65535)
	n, a, e := p.ReadFromUDP(b)
	check(e)
	return b[:n], a
}
func checksum(data []byte) uint16 {
	var c uint32
	for len(data) >= 2 {
		c += uint32(be.Uint16(data))
		data = data[2:]
	}
	if len(data) > 0 {
		c += uint32(data[0]) << 8
	}
	for c>>16 != 0 {
		c = (c & 65535) + (c >> 16)
	}
	return ^uint16(c)
}

type flow struct {
	wire         net.Conn
	v6           bool
	proto        byte
	sport, dport int
	destination  string
}

func (f flow) send(payload []byte, seq, ack uint32, flags byte) {
	src, dst := net.ParseIP("10.9.0.2").To4(), net.ParseIP("192.0.2.10").To4()
	family := syscall.AF_INET
	if f.v6 {
		src, dst = net.ParseIP("fd00:dead::2"), net.ParseIP("2001:db8::1")
		family = syscall.AF_INET6
	}
	if f.destination != "" {
		dst = net.ParseIP(f.destination)
		if !f.v6 {
			dst = dst.To4()
		}
	}
	headerSize, offset := 8, 6
	if f.proto == 6 {
		headerSize, offset = 20, 16
	}
	s := make([]byte, headerSize)
	be.PutUint16(s, uint16(f.sport))
	be.PutUint16(s[2:], uint16(f.dport))
	if f.proto == 6 {
		be.PutUint32(s[4:], seq)
		be.PutUint32(s[8:], ack)
		s[12], s[13], s[14], s[15] = 80, flags, 255, 255
	} else {
		be.PutUint16(s[4:], uint16(headerSize+len(payload)))
	}
	s = append(s, payload...)
	length := len(s)
	pseudo := append(append([]byte(nil), src...), dst...)
	if f.v6 {
		pseudo = be.AppendUint32(pseudo, uint32(length))
		pseudo = append(pseudo, 0, 0, 0, f.proto)
	} else {
		pseudo = append(pseudo, 0, f.proto)
		pseudo = append(pseudo, u16(length)...)
	}
	c := checksum(append(pseudo, s...))
	if c == 0 {
		c = 65535
	}
	be.PutUint16(s[offset:], c)
	var ip []byte
	if f.v6 {
		ip = make([]byte, 8)
		ip[0], ip[6], ip[7] = 96, f.proto, 64
		be.PutUint16(ip[4:], uint16(length))
	} else {
		ip = make([]byte, 12)
		ip[0], ip[8], ip[9] = 69, 64, f.proto
		be.PutUint16(ip[2:], uint16(20+length))
		ip[5] = 1
	}
	ip = append(ip, src...)
	ip = append(ip, dst...)
	if !f.v6 {
		be.PutUint16(ip[10:], checksum(ip))
	}
	frame := be.AppendUint32(nil, uint32(family))
	frame = append(frame, ip...)
	frame = append(frame, s...)
	_, e := f.wire.Write(frame)
	check(e)
}
func (f flow) receive() []byte {
	f.wire.SetReadDeadline(time.Now().Add(5 * time.Second))
	frame := make([]byte, 65535)
	family, version := syscall.AF_INET, byte(4)
	if f.v6 {
		family, version = syscall.AF_INET6, 6
	}
	for {
		n, e := f.wire.Read(frame)
		check(e)
		if n < 24 || be.Uint32(frame[:4]) != uint32(family) {
			continue
		}
		ip := frame[4:n]
		require(ip[0]>>4 == version, "incorrect IP version")
		offset, proto := int(ip[0]&15)*4, ip[9]
		if f.v6 {
			offset, proto = 40, ip[6]
		}
		if proto != f.proto || len(ip) < offset+8 {
			continue
		}
		s := ip[offset:]
		if int(be.Uint16(s)) == f.dport && int(be.Uint16(s[2:])) == f.sport {
			return s
		}
	}
}
func (f flow) exchange(data, tail []byte) []byte {
	var seq uint32 = 101
	f.send(nil, seq, 0, 2)
	syn := f.receive()
	require(syn[13]&18 == 18, "missing SYN ACK")
	ack := be.Uint32(syn[4:]) + 1
	seq++
	f.send(nil, seq, ack, 16)
	f.send(data, seq, ack, 24)
	seq += uint32(len(data))
	var reply []byte
	for !bytes.HasSuffix(reply, tail) {
		s := f.receive()
		p := s[int(s[12]>>4)*4:]
		if len(p) > 0 {
			require(be.Uint32(s[4:]) == ack, "out of sequence")
			reply = append(reply, p...)
			ack += uint32(len(p))
			f.send(nil, seq, ack, 16)
		}
		require(s[13]&5 == 0 || bytes.HasSuffix(reply, tail), "early TCP close")
	}
	f.send(nil, seq, ack, 20)
	return reply
}
func checkFrames(w net.Conn, udp *net.UDPConn, nonce []byte, cycle int) {
	query := hexBytes("6564010000010000000000000367656f07696e76616c69640000010001")
	ip := net.IPv4(192, 0, 2, 42).To4()
	for i, v6 := range []bool{false, true} {
		base := 23100 + 20*cycle + 5*i
		datagram := flow{w, v6, 17, base, 34567, ""}
		payload := append(append([]byte(nil), nonce...), byte(cycle), byte(i))
		datagram.send(payload, 0, 0, 0)
		data, sender := readUDP(udp)
		require(bytes.Equal(data, payload), "UDP forward mismatch")
		_, e := udp.WriteToUDP(append([]byte("reply"), data...), sender)
		check(e)
		require(bytes.Equal(datagram.receive()[8:], append([]byte("reply"), payload...)), "UDP reply mismatch")
		stream := flow{w, v6, 6, base + 1, 80, ""}
		resp := stream.exchange([]byte("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"), nonce)
		parts := bytes.SplitN(resp, []byte("\r\n\r\n"), 2)
		require(len(parts) == 2 && bytes.Equal(parts[1], nonce), "HTTP body mismatch")
		direct := flow{w, v6, 17, base + 4, 53, []string{"192.0.2.53", "2001:db8::53"}[i]}
		direct.send(query, 0, 0, 0)
		data, sender = readUDP(udp)
		require(bytes.Equal(data, query), "direct DNS payload mismatch")
		answer := append([]byte(nil), query...)
		answer[2], answer[3], answer[7] = 129, 128, 1
		answer = append(answer, hexBytes("c00c000100010000003c0004")...)
		answer = append(answer, ip...)
		_, e = udp.WriteToUDP(answer, sender)
		check(e)
		require(bytes.Equal(direct.receive()[8:], answer), "direct DNS reply mismatch")
		dns := flow{w, v6, 17, base + 2, 53, ""}
		dns.send(query, 0, 0, 0)
		answer = dns.receive()[8:]
		require(bytes.Equal(answer[:2], query[:2]) && bytes.HasSuffix(answer, ip), "captured DNS/UDP mismatch")
		tcp := flow{w, v6, 6, base + 3, 53, ""}
		answer = tcp.exchange(append(u16(len(query)), query...), ip)
		require(int(be.Uint16(answer)) == len(answer)-2 && bytes.Equal(answer[2:4], query[:2]), "captured DNS/TCP mismatch")
	}
}
func socksUDP(port int, target *net.UDPConn, data []byte) {
	c, e := net.DialTimeout("tcp4", endpoint(port), 6*time.Second)
	check(e)
	defer c.Close()
	c.SetDeadline(time.Now().Add(6 * time.Second))
	udp := udpPeer()
	defer udp.Close()
	_, e = c.Write([]byte{5, 1, 0})
	check(e)
	require(bytes.Equal(mustRead(c, 2), []byte{5, 0}), "bad SOCKS handshake")
	_, e = c.Write(append([]byte{5, 3, 0, 1, 127, 0, 0, 1}, u16(udp.LocalAddr().(*net.UDPAddr).Port)...))
	check(e)
	h := mustRead(c, 10)
	require(bytes.Equal(h[:4], []byte{5, 0, 0, 1}), "SOCKS UDP association failed")
	frame := append([]byte{0, 0, 0, 1, 127, 0, 0, 1}, u16(target.LocalAddr().(*net.UDPAddr).Port)...)
	frame = append(frame, data...)
	_, e = udp.WriteToUDP(frame, &net.UDPAddr{IP: h[4:8], Port: int(be.Uint16(h[8:]))})
	check(e)
	p, s := readUDP(target)
	require(bytes.Equal(p, data), "SOCKS UDP payload mismatch")
	_, e = target.WriteToUDP(p, s)
	check(e)
	r, _ := readUDP(udp)
	require(bytes.Equal(r, frame), "SOCKS UDP frame mismatch")
}
func fixtureHost(checker, app, dir string) (*host, net.Conn) {
	pair, e := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	check(e)
	child := os.NewFile(uintptr(pair[0]), "child-utun")
	defer child.Close()
	wirefile := os.NewFile(uintptr(pair[1]), "test-utun")
	defer wirefile.Close()
	wire, e := net.FileConn(wirefile)
	check(e)
	return startHost([]string{checker, "--serve-embedded-fixture", app, dir, "3"}, []*os.File{child}, nil), wire
}

type xrayPin struct {
	Version     string
	BuildMarker string
}

func reviewedXrayPin() xrayPin {
	root := os.Getenv("V2RAYM_PROJECT_ROOT")
	require(root != "", "Missing project root for Xray verification")
	var inputs struct{ Xray xrayPin }
	check(json.Unmarshal([]byte(readFile(filepath.Join(root, "contracts/macos-build-inputs.json"))), &inputs))
	require(inputs.Xray.Version != "" && inputs.Xray.BuildMarker != "", "Incomplete Xray pin")
	return inputs.Xray
}

func (pin xrayPin) matches(version string) bool {
	fields := strings.Fields(version)
	return len(fields) >= 3 && fields[0] == "Xray" && fields[1] == pin.Version && slices.Contains(fields[2:], pin.BuildMarker)
}

func coreAction(h *host, action string, pin xrayPin) {
	h.send(action)
	reply := h.receive(12*time.Second, "")
	version, _ := reply["version"].(string)
	require(reply["action"] == action && reply["pid"] == float64(h.cmd.Process.Pid) && pin.matches(version), "invalid host reply: %v", reply)
}
func embedded(root, checker, library string) {
	pin := reviewedXrayPin()
	nonce := make([]byte, 24)
	_, e := rand.Read(nonce)
	check(e)
	httpPeer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(nonce) }))
	defer httpPeer.Close()
	udp := udpPeer()
	defer udp.Close()
	bundle := filepath.Join(root, "Fixture.app")
	frameworks := filepath.Join(bundle, "Contents", "Frameworks")
	check(os.MkdirAll(frameworks, 0700))
	call("/bin/cp", library, frameworks)
	port := freePort()
	writeJSON(filepath.Join(root, "proxy.json"), obj{"log": obj{"loglevel": "none"}, "inbounds": []obj{{"listen": "127.0.0.1", "port": port, "protocol": "mixed", "settings": obj{"udp": true}}}, "outbounds": []obj{{"protocol": "freedom", "settings": obj{}}}})
	writeJSON(filepath.Join(root, "tun.json"), obj{"log": obj{"loglevel": "none"}, "inbounds": []obj{{"tag": "tun", "protocol": "tun", "settings": obj{"name": "utun9999", "MTU": 1500}}},
		"dns": obj{"servers": []string{"localhost"}, "hosts": obj{"full:geo.invalid": "192.0.2.42"}}, "outbounds": []obj{{"protocol": "freedom", "tag": "udp", "settings": obj{"redirect": udp.LocalAddr().String()}}, {"protocol": "freedom", "tag": "tcp", "settings": obj{"redirect": httpPeer.Listener.Addr().String()}}, {"protocol": "dns", "tag": "dns"}},
		"routing": obj{"rules": []obj{{"inboundTag": []string{"tun"}, "network": "udp", "ip": []string{"192.0.2.53/32", "2001:db8::53/128"}, "port": "53", "outboundTag": "udp"}, {"inboundTag": []string{"tun"}, "port": "53", "outboundTag": "dns"}, {"network": "tcp", "outboundTag": "tcp"}}}})
	h, wire := fixtureHost(checker, bundle, root)
	defer h.close()
	defer wire.Close()
	for cycle := 0; cycle < 2; cycle++ {
		for _, mode := range []string{"proxy", "tun"} {
			coreAction(h, mode, pin)
			err := exec.Command("/usr/bin/pgrep", "-P", strconv.Itoa(h.cmd.Process.Pid)).Run()
			status, ok := err.(*exec.ExitError)
			require(ok && status.ExitCode() == 1, "unexpected child process")
			if mode == "proxy" {
				for _, p := range []string{"http://", "socks5h://", "connect"} {
					args := []string{"/usr/bin/curl", "-qfsS", "--max-time", "6", "--noproxy", "", "--proxy"}
					if p == "connect" {
						args = append(args, "http://"+endpoint(port), "--proxytunnel")
					} else {
						args = append(args, p+endpoint(port))
					}
					require(call(append(args, httpPeer.URL)...) == string(nonce), "proxy forwarding mismatch")
				}
				socksUDP(port, udp, nonce)
			} else {
				checkFrames(wire, udp, nonce, cycle)
			}
			coreAction(h, "stop", pin)
			if mode == "proxy" {
				c, e := net.DialTimeout("tcp", endpoint(port), time.Second)
				if c != nil {
					c.Close()
				}
				require(e != nil, "listener survived shutdown")
			}
			fmt.Printf("PASS %s cycle %d, PID %d\n", mode, cycle+1, h.cmd.Process.Pid)
		}
	}
}
