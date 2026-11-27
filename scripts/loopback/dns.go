package main

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"time"
)

func tcpListener(handler func(net.Conn)) net.Listener {
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	check(e)
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); c.SetDeadline(time.Now().Add(12 * time.Second)); handler(c) }()
		}
	}()
	return l
}
func tcpMessage(c net.Conn) ([]byte, error) {
	h, e := exact(c, 2)
	if e != nil {
		return nil, e
	}
	return exact(c, int(be.Uint16(h)))
}
func prefix(b []byte) []byte { return append(u16(len(b)), b...) }
func question(packet []byte) (string, int, int) {
	if len(packet) < 12 {
		return "", 0, 0
	}
	var labels []string
	i := 12
	for i < len(packet) && packet[i] != 0 {
		n := int(packet[i])
		i++
		if i+n > len(packet) {
			return "", 0, 0
		}
		labels = append(labels, string(packet[i:i+n]))
		i += n
	}
	if i+5 > len(packet) {
		return "", 0, 0
	}
	return strings.Join(labels, "."), int(be.Uint16(packet[i+1:])), i + 5
}
func dnsQuery(name string, kind int) []byte {
	q := hexBytes("000001000001000000000000")
	_, e := rand.Read(q[:2])
	check(e)
	for _, l := range strings.Split(name, ".") {
		q = append(q, byte(len(l)))
		q = append(q, l...)
	}
	q = append(q, 0)
	q = append(q, u16(kind)...)
	return append(q, 0, 1)
}
func seedDNS(dir string, peerPort int) {
	config := filepath.Join(dir, "guiConfigs")
	check(os.Mkdir(config, 0700))
	rules := []obj{{"domain": []string{"domain:proxy.invalid"}, "outboundTag": "proxy"}, {"domain": []string{"geosite:lab"}, "outboundTag": "direct"}, {"ip": []string{"::/0"}, "outboundTag": "direct"}}
	sql(filepath.Join(config, "guiNDB.db"), fmt.Sprintf("CREATE TABLE ProfileItem(IndexId TEXT PRIMARY KEY, ConfigType INT, Remarks TEXT, Address TEXT, Port INT); CREATE TABLE RoutingItem(Id TEXT,Remarks TEXT,RuleSet TEXT,IsActive INT); CREATE TABLE DNSItem(CoreType INT); CREATE TABLE FullConfigTemplateItem(CoreType INT); CREATE TABLE SubItem(Id TEXT,PrevProfile TEXT,NextProfile TEXT); INSERT INTO ProfileItem VALUES('node',4,'Local SOCKS','127.0.0.1',%d); INSERT INTO RoutingItem VALUES('fixture','Fixture',%s,1);", peerPort, quoteSQL(jsonText(rules))))
	field := func(tag byte, b []byte) []byte { return append([]byte{tag, byte(len(b))}, b...) }
	region := field(10, []byte("LAB"))
	domain := append([]byte{8, 2}, field(18, []byte("regional.invalid"))...)
	check(os.WriteFile(filepath.Join(dir, "geosite.dat"), field(10, append(region, field(18, domain)...)), 0600))
	cidr := append(field(10, []byte{192, 0, 2, 0}), 16, 24)
	check(os.WriteFile(filepath.Join(dir, "geoip.dat"), field(10, append(region, field(18, cidr)...)), 0600))
}

type observation struct {
	role string
	at   time.Time
}

func dnsSmoke(root, app, checker string) {
	pin := reviewedXrayPin()
	var lock sync.Mutex
	events := map[string][]observation{}
	record := func(name, role string) {
		lock.Lock()
		events[name] = append(events[name], observation{role, time.Now()})
		lock.Unlock()
	}
	done := make(chan struct{})
	defer close(done)
	peers := map[string]int{}
	for _, role := range []string{"direct", "remote"} {
		server := tcpListener(func(c net.Conn) {
			packet, e := tcpMessage(c)
			if e != nil {
				return
			}
			name, kind, end := question(packet)
			if end == 0 {
				return
			}
			record(name, role)
			scenario := strings.Split(name, ".")[0]
			if role == "direct" && scenario == "timeout" {
				select {
				case <-done:
				case <-time.After(8 * time.Second):
				}
				return
			}
			if role == "direct" && scenario == "hit" {
				time.Sleep(120 * time.Millisecond)
			}
			ip := "192.0.2.11"
			if scenario == "mismatch" {
				ip = "198.51.100.11"
			}
			if role == "remote" {
				ip = "203.0.113.22"
			}
			raw := net.ParseIP(ip).To4()
			if kind == 28 {
				if role == "direct" {
					raw = net.ParseIP("2001:db8::11")
				} else {
					raw = net.ParseIP("2001:db8::22")
				}
			}
			answer := append(append([]byte(nil), packet[:2]...), hexBytes("81800001000100000000")...)
			answer = append(answer, packet[12:end]...)
			answer = append(answer, 192, 12)
			answer = append(answer, u16(kind)...)
			answer = append(answer, 0, 1, 0, 0, 0, 1)
			answer = append(answer, u16(len(raw))...)
			answer = append(answer, raw...)
			c.Write(prefix(answer))
		})
		defer server.Close()
		peers[role] = server.Addr().(*net.TCPAddr).Port
	}
	socks := tcpListener(func(c net.Conn) {
		h, e := exact(c, 2)
		if e != nil || h[0] != 5 {
			return
		}
		if _, e = exact(c, int(h[1])); e != nil {
			return
		}
		c.Write([]byte{5, 0})
		h, e = exact(c, 10)
		if e != nil || !bytes.Equal(h[:8], []byte{5, 1, 0, 1, 127, 0, 0, 1}) {
			return
		}
		p := int(be.Uint16(h[8:]))
		if p != peers["remote"] && p != peers["direct"] {
			return
		}
		peer, e := net.DialTimeout("tcp4", endpoint(p), 8*time.Second)
		if e != nil {
			return
		}
		defer peer.Close()
		peer.SetDeadline(time.Now().Add(8 * time.Second))
		c.Write(hexBytes("050000017f0000010000"))
		packet, e := tcpMessage(c)
		if e != nil {
			return
		}
		name, _, _ := question(packet)
		record(name, "socks")
		peer.Write(prefix(packet))
		answer, e := tcpMessage(peer)
		if e == nil {
			c.Write(prefix(answer))
		}
	})
	defer socks.Close()
	seedDNS(root, socks.Addr().(*net.TCPAddr).Port)
	settings := decode(readFile(filepath.Join(app, "Contents/Resources/V2rayMNative_V2rayMKit.bundle/Contents/Resources/RuntimeDefaults/settings.json")))
	udp := udpPeer()
	port := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()
	inbound := settings["Inbound"].([]any)[0].(obj)
	inbound["LocalPort"] = freePort()
	inbound["AllowLANConn"] = false
	dns := settings["SimpleDNSItem"].(obj)
	for k, v := range (obj{"DirectDNS": "tcp://" + endpoint(peers["direct"]), "RemoteDNS": "tcp://" + endpoint(peers["remote"]), "DirectExpectedIPs": "geoip:lab", "BootstrapDNS": "127.0.0.1", "AddCommonHosts": false, "UseSystemHosts": false}) {
		dns[k] = v
	}
	h, wire := fixtureHost(checker, app, root)
	defer h.close()
	defer wire.Close()
	for flag, parallel := range []bool{false, true} {
		dns["ParallelQuery"] = parallel
		writeJSON(filepath.Join(root, "guiConfigs/guiNConfig.json"), settings)
		var previous any
		for _, mode := range []string{"proxy", "tun"} {
			gen := "--generate-client"
			if mode == "tun" {
				gen = "--generate-tun-client"
			}
			conf := decode(call(checker, gen, root, "node"))
			if mode == "proxy" {
				previous = conf["dns"]
				conf["inbounds"] = append(conf["inbounds"].([]any), obj{"tag": "fixture-dns", "listen": "127.0.0.1", "port": port, "protocol": "dokodemo-door", "settings": obj{"address": "127.0.0.1", "port": 53, "network": "udp"}})
				conf["outbounds"] = append(conf["outbounds"].([]any), obj{"tag": "fixture-dns-out", "protocol": "dns"})
				routing := conf["routing"].(obj)
				routing["rules"] = append([]any{obj{"inboundTag": []string{"fixture-dns"}, "outboundTag": "fixture-dns-out"}}, routing["rules"].([]any)...)
			} else {
				require(reflect.DeepEqual(previous, conf["dns"]), "generated resolver policy differs between ordinary and TUN")
				for _, v := range conf["inbounds"].([]any) {
					in := v.(obj)
					if in["protocol"] == "tun" {
						s := in["settings"].(obj)
						for _, key := range []string{"autoOutboundsInterface", "autoSystemRoutingTable", "gateway", "dns"} {
							delete(s, key)
						}
					}
				}
			}
			writeJSON(filepath.Join(root, mode+".json"), conf)
			coreAction(h, mode, pin)
			for i, test := range []struct {
				name, zone, ip string
				kind           int
			}{{"hit", "regional", "192.0.2.11", 1}, {"mismatch", "regional", "203.0.113.22", 1}, {"timeout", "regional", "203.0.113.22", 1}, {"only", "proxy", "203.0.113.22", 1}, {"default", "unmatched", "2001:db8::11", 28}} {
				name := fmt.Sprintf("%s.%s%d.%s.invalid", test.name, mode, flag, test.zone)
				packet := dnsQuery(name, test.kind)
				var answer []byte
				if mode == "tun" {
					f := flow{wire, false, 17, 26300 + i, 53, ""}
					f.send(packet, 0, 0, 0)
					answer = f.receive()[8:]
				} else {
					client, e := net.DialTimeout("udp4", endpoint(port), time.Second)
					check(e)
					client.SetDeadline(time.Now().Add(7 * time.Second))
					_, e = client.Write(packet)
					check(e)
					buf := make([]byte, 65535)
					n, e := client.Read(buf)
					client.Close()
					check(e)
					answer = buf[:n]
				}
				ip := net.ParseIP(test.ip)
				if test.kind == 1 {
					ip = ip.To4()
				}
				lock.Lock()
				seen := append([]observation(nil), events[name]...)
				lock.Unlock()
				require(len(answer) >= 12 && bytes.Equal(answer[:2], packet[:2]) && be.Uint16(answer[6:]) == 1 && bytes.HasSuffix(answer, ip), "%s wrong DNS answer %x; %v", name, answer, seen)
				roles := map[string]bool{}
				var socksTime time.Time
				for _, v := range seen {
					roles[v.role] = true
					if v.role == "socks" {
						socksTime = v.at
					}
				}
				expected := map[string]bool{}
				if test.name != "only" {
					expected["direct"] = true
				}
				remote := test.name == "mismatch" || test.name == "timeout" || test.name == "only" || (parallel && test.name == "hit")
				if remote {
					expected["socks"], expected["remote"] = true, true
				}
				require(reflect.DeepEqual(roles, expected), "%s: wrong resolver path %v", name, seen)
				if remote && !parallel && test.name != "only" {
					require(seen[0].role == "direct", "serial fallback out of order")
				}
				if !parallel && test.name == "timeout" {
					require(socksTime.Sub(seen[0].at) >= 3*time.Second, "premature resolver timeout")
				}
				fmt.Printf("PASS %s %s\n", name, test.ip)
			}
			coreAction(h, "stop", pin)
		}
	}
}
