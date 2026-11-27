package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func portBlock() int {
	for attempt := 0; attempt < 100; attempt++ {
		port := 20000 + rand.IntN(25000)
		var held []io.Closer
		for n := 0; n < 6; n++ {
			l, e := net.Listen("tcp4", endpoint(port+n))
			if e != nil {
				break
			}
			held = append(held, l)
			u, e := net.ListenPacket("udp4", endpoint(port+n))
			if e != nil {
				break
			}
			held = append(held, u)
		}
		for _, s := range held {
			s.Close()
		}
		if len(held) == 12 {
			return port
		}
	}
	check(fmt.Errorf("cannot reserve loopback port block"))
	return 0
}
func checkerRun(timeout time.Duration, args ...string) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, args[0], args[1:]...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	check(c.Run())
}
func baseSettings(app string, inbound int) obj {
	s := decode(readFile(filepath.Join(app, "Contents/Resources/V2rayMNative_V2rayMKit.bundle/Contents/Resources/RuntimeDefaults/settings.json")))
	in := s["Inbound"].([]any)[0].(obj)
	in["LocalPort"] = inbound
	in["AllowLANConn"] = false
	return s
}
func noConfigLeft(root string) {
	files, e := filepath.Glob(filepath.Join(root, "guiTemps/xray/*/config.json"))
	check(e)
	require(len(files) == 0, "runtime configuration survived shutdown")
}

// Keep one CONNECT socket open across both starts. An HTTP client that silently
// reconnects could otherwise hide an interrupted stream.
func checkCoreContinuity(h *host, inbound, target int) {
	conn, err := net.DialTimeout("tcp4", endpoint(inbound), 5*time.Second)
	check(err)
	defer conn.Close()
	check(conn.SetDeadline(time.Now().Add(30 * time.Second)))
	address := fmt.Sprintf("native-check.invalid:%d", target)
	_, err = fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", address, address)
	check(err)
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
	check(err)
	require(response.StatusCode == 200, "CONNECT failed: %s", response.Status)
	probe := func() {
		_, err := fmt.Fprintf(conn, "GET /traffic HTTP/1.1\r\nHost: %s\r\n\r\n", address)
		check(err)
		reply, err := http.ReadResponse(reader, nil)
		check(err)
		defer reply.Body.Close()
		body, err := io.ReadAll(reply.Body)
		check(err)
		require(reply.StatusCode == 200 && string(body) == "v2rayM-local-traffic-ok", "live stream probe failed")
	}
	command := func(name string) {
		h.send(name)
		select {
		case reply := <-h.lines:
			require(reply == name+" ok", "%s returned %q", name, reply)
		case <-time.After(10 * time.Second):
			check(fmt.Errorf("%s timed out", name))
		}
	}
	probe()
	for range 2 {
		command("start")
		probe()
	}
	command("restart")
}

func normalHost(root, app, checker string, inbound, peer, target int) {
	data := filepath.Join(root, "host-data")
	folder := filepath.Join(data, "guiConfigs")
	check(os.MkdirAll(folder, 0700))
	s := baseSettings(app, inbound)
	s["IndexId"] = "fixture"
	writeJSON(filepath.Join(folder, "guiNConfig.json"), s)
	rules := jsonText([]obj{{"id": "fixture", "enabled": true, "port": "1-65535", "outboundTag": "proxy"}})
	sql(filepath.Join(folder, "guiNDB.db"), fmt.Sprintf("CREATE TABLE ProfileItem(IndexId varchar PRIMARY KEY,ConfigType int,Remarks varchar,Address varchar,Port int); INSERT INTO ProfileItem VALUES('fixture',4,'Local peer','127.0.0.1',%d); CREATE TABLE RoutingItem(Id varchar PRIMARY KEY,Remarks varchar,RuleSet varchar,IsActive int); INSERT INTO RoutingItem VALUES('route','Fixture',%s,1);", peer, quoteSQL(rules)))
	h := startHost([]string{checker, "--serve-host-fixture", data, "fixture", app}, nil, nil)
	func() {
		defer h.closeWithin(20 * time.Second)
		select {
		case pid := <-h.lines:
			require(pid == strconv.Itoa(h.cmd.Process.Pid), "wrong host identity %s", pid)
			e := exec.Command("/usr/bin/pgrep", "-P", pid, "-x", "xray").Run()
			x, ok := e.(*exec.ExitError)
			require(ok && x.ExitCode() == 1, "unexpected child Xray")
		case <-time.After(30 * time.Second):
			check(fmt.Errorf("native startup timeout"))
		}
		checkCoreContinuity(h, inbound, target)
		body, e := getHTTP(fmt.Sprintf("http://native-check.invalid:%d/traffic", target), "http://"+endpoint(inbound))
		check(e)
		require(body == "v2rayM-local-traffic-ok", "restarted host traffic mismatch")
		fmt.Println("PASS repeated starts preserve an open CONNECT stream and restart forwards on a new session")
	}()
	require(exec.Command("/bin/ps", "-p", strconv.Itoa(h.cmd.Process.Pid)).Run() != nil, "child survived shutdown")
	noConfigLeft(data)
}
func customHost(root, app, checker string, inbound, peer, target, refused int) {
	dir := filepath.Join(root, "custom-data")
	folder := filepath.Join(dir, "guiConfigs")
	check(os.MkdirAll(folder, 0700))
	s := baseSettings(app, inbound)
	internal := portBlock()
	for internal-inbound < 20 && inbound-internal < 20 {
		internal = portBlock()
	}
	base := fmt.Sprintf("http://native-check.invalid:%d", target)
	speed := s["SpeedTestItem"].(obj)
	speed["SpeedPingTestUrl"], speed["SpeedTestUrl"], speed["IPAPIUrl"] = base+"/probe", base+"/download", base+"/ipinfo"
	writeJSON(filepath.Join(folder, "guiNConfig.json"), s)
	writeJSON(filepath.Join(folder, "custom.json"), obj{"dns": obj{"hosts": obj{"legacy-custom.invalid": "127.0.0.1"}, "servers": []string{"localhost"}}, "log": obj{"loglevel": "warning", "access": filepath.Join(dir, "custom-access.log")},
		"inbounds":  []obj{{"tag": "entry", "protocol": "socks", "listen": "127.0.0.1", "port": internal, "settings": obj{"auth": "noauth"}}},
		"outbounds": []obj{{"tag": "again", "protocol": "loopback", "settings": obj{"inboundTag": "second-pass"}}, {"tag": "peer", "protocol": "socks", "settings": obj{"address": "127.0.0.1", "port": peer}}, {"tag": "direct", "protocol": "freedom", "settings": obj{"domainStrategy": "ForceIPv4"}}, {"tag": "deny", "protocol": "blackhole"}},
		"routing":   obj{"domainStrategy": "AsIs", "rules": []obj{{"type": "field", "inboundTag": "unused,other", "outboundTag": "deny"}, {"type": "field", "inboundTag": "entry", "outboundTag": "again"}, {"type": "field", "domain": []string{"full:legacy-custom.invalid"}, "outboundTag": "direct"}, {"type": "field", "network": "tcp", "outboundTag": "peer"}}}})
	db := filepath.Join(folder, "guiNDB.db")
	sql(db, fmt.Sprintf("CREATE TABLE ProfileItem(IndexId varchar PRIMARY KEY,ConfigType int,CoreType int,Address varchar,PreSocksPort int,Port int,ConfigVersion int,ProtoExtra varchar,Remarks varchar); INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,Address,PreSocksPort,Port) VALUES('custom',2,2,'custom.json',%d,0),('probe-good',4,2,'127.0.0.1',NULL,%d),('probe-bad',4,2,'127.0.0.1',NULL,%d); CREATE TABLE ProfileExItem(IndexId varchar PRIMARY KEY,Delay integer,Speed float); INSERT INTO ProfileExItem VALUES('probe-bad',10,234.5); CREATE TABLE RoutingItem(Id varchar PRIMARY KEY,RuleSet varchar,IsActive int); INSERT INTO RoutingItem VALUES('route',%s,1);", internal, peer, refused, quoteSQL(jsonText([]obj{{"enabled": true, "port": "1-65535", "outboundTag": "proxy"}}))))
	for mode, name := range []string{"leastping", "fallback", "random", "rr", "leastload"} {
		first := "probe-bad"
		if mode == 2 || mode == 3 {
			first = "probe-good"
		}
		extra := jsonText(obj{"MultipleLoad": mode, "ChildItems": first + ",probe-good"})
		sql(db, fmt.Sprintf("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,ProtoExtra,Remarks) VALUES('group-%s',101,2,4,%s,'%s')", name, quoteSQL(extra), name))
	}
	checkerRun(50*time.Second, checker, "--check-custom-fixture", app, dir, strconv.Itoa(target), strconv.Itoa(inbound))
	require(strings.TrimSpace(sql(db, "SELECT COUNT(*) FROM ProfileExItem WHERE (IndexId='probe-good' AND Delay>0 AND Speed>0 AND IpInfo='🇯🇵(JP) 192.0.2.7') OR (IndexId='probe-bad' AND Delay=-1 AND Speed=0)")) == "2", "unexpected diagnostic persistence")
	noConfigLeft(dir)
}

func changedBackup(input []byte, port int) ([]byte, error) {
	archive, e := zip.NewReader(bytes.NewReader(input), int64(len(input)))
	if e != nil {
		return nil, e
	}
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	for _, f := range archive.File {
		reader, e := f.Open()
		if e != nil {
			return nil, e
		}
		data, e := io.ReadAll(reader)
		reader.Close()
		if e != nil {
			return nil, e
		}
		if strings.HasSuffix(f.Name, "/guiNConfig.json") {
			s := decode(string(data))
			s["Inbound"].([]any)[0].(obj)["LocalPort"] = port
			data = []byte(jsonText(s))
		}
		dst, e := w.CreateHeader(&f.FileHeader)
		if e != nil {
			return nil, e
		}
		if _, e = dst.Write(data); e != nil {
			return nil, e
		}
	}
	if e = w.Close(); e != nil {
		return nil, e
	}
	return out.Bytes(), nil
}
func productSmoke(root, app, checker string, hostOnly bool) {
	for _, kind := range []int{101, 102} {
		activeGroup(root, app, checker, kind)
	}
	var mu sync.Mutex
	var visits []string
	var downloads, backupReads int
	files := map[string][]byte{}
	httpPeer := httptest.NewUnstartedServer(nil)
	target := httpPeer.Listener.Addr().(*net.TCPAddr).Port
	socks := tcpListener(func(c net.Conn) {
		name, port, ok := socksRequest(c)
		if !ok {
			return
		}
		if port != target || name != "native-check.invalid" && name != "127.0.0.1" {
			c.Write(hexBytes("05020001000000000000"))
			return
		}
		remote, e := net.DialTimeout("tcp4", endpoint(target), 5*time.Second)
		if e != nil {
			return
		}
		defer remote.Close()
		mu.Lock()
		visits = append(visits, name)
		mu.Unlock()
		c.Write(append(hexBytes("050000017f000001"), u16(port)...))
		go func() { io.Copy(remote, c); remote.(*net.TCPConn).CloseWrite() }()
		io.Copy(c, remote)
	})
	defer socks.Close()
	peer := socks.Addr().(*net.TCPAddr).Port
	hold := func(start, release string, timeout time.Duration) {
		dir := filepath.Join(root, "geo-data")
		check(os.WriteFile(filepath.Join(dir, start), nil, 0600))
		end := time.Now().Add(timeout)
		for time.Now().Before(end) {
			if _, e := os.Stat(filepath.Join(dir, release)); e == nil {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	dat := func(name string) []byte {
		b, e := os.ReadFile(filepath.Join(app, "Contents/Resources/Backend/bin", name))
		check(e)
		return b
	}
	httpPeer.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if strings.HasPrefix(path, "/dav/") {
			user, pass, auth := r.BasicAuth()
			if !auth || user != "fixture" || pass != "local-only" || !strings.HasPrefix(path, "/dav/fixture") {
				http.Error(w, "denied", 403)
				return
			}
			mu.Lock()
			defer mu.Unlock()
			switch r.Method {
			case "MKCOL":
				w.WriteHeader(405)
			case "PUT":
				b, e := io.ReadAll(r.Body)
				if e != nil {
					http.Error(w, "body", 400)
					return
				}
				files[path] = b
				w.WriteHeader(201)
			case "DELETE":
				delete(files, path)
				w.WriteHeader(204)
			case "GET":
				b, ok := files[path]
				if !ok {
					http.NotFound(w, r)
					return
				}
				if path == "/dav/fixture/backup.zip" {
					backupReads++
					if backupReads == 2 {
						var e error
						b, e = changedBackup(b, target)
						if e != nil {
							http.Error(w, "zip", 500)
							return
						}
					}
				}
				w.Header().Set("Content-Length", strconv.Itoa(len(b)))
				w.Write(b)
			default:
				w.WriteHeader(405)
			}
			return
		}
		if r.Method == "HEAD" {
			if path == "/probe" {
				w.WriteHeader(204)
			} else {
				http.NotFound(w, r)
			}
			return
		}
		data := []byte("v2rayM-local-traffic-ok")
		switch path {
		case "/subscription":
			data = []byte(fmt.Sprintf("socks://127.0.0.1:%d#Subscription%%20fixture", peer))
		case "/probe":
			time.Sleep(15 * time.Millisecond)
		case "/ipinfo":
			data = []byte(jsonText(obj{"clientIp": "192.0.2.7", "location": obj{"country_code": "JP"}}))
		case "/download":
			data = make([]byte, 256<<10)
		case "/hold-routes":
			hold("fixture-route-start", "fixture-route-release", 20*time.Second)
			data = []byte(jsonText(obj{"version": "fixture", "routingItems": []obj{}}))
		case "/dat/geoip.dat", "/dat/geosite.dat":
			mu.Lock()
			downloads++
			count := downloads
			mu.Unlock()
			name := filepath.Base(path)
			data = dat(name)
			if count == 3 {
				hold("fixture-busy-geo-start", "fixture-busy-geo-release", 20*time.Second)
			}
			if count == 9 {
				hold("fixture-geo-started", "fixture-geo-release", 15*time.Second)
			}
			switch {
			case count >= 5 && count <= 6:
				data = append(data, 10, 5, 10, 1, 88, 18)
			case count >= 7 && count <= 8:
				n, k := binary.Uvarint(data[1:])
				if k <= 0 || 1+k+int(n) > len(data) {
					http.Error(w, "invalid DAT", 500)
					return
				}
				data = data[:1+k+int(n)]
			case name == "geoip.dat":
				data = append(data, []byte("\x0a\x09\x0a\x07FIXTURE")...)
			}
		}
		if strings.HasPrefix(path, "/regional/") {
			parts := strings.Split(strings.TrimPrefix(path, "/regional/"), "/")
			if len(parts) != 2 {
				http.NotFound(w, r)
				return
			}
			region, name := parts[0], parts[1]
			switch name {
			case "geoip.dat", "geosite.dat":
				data = dat(name)
			case "simple_dns.json":
				data = []byte(jsonText(obj{"DirectDNS": "127.0.0.1", "RemoteDNS": "127.0.0.1", "Hosts": "fixture.example 127.0.0.1"}))
			case "v2ray.json":
				data = []byte(jsonText(obj{"UseSystemHosts": false}))
			case "template.json":
				data = []byte(jsonText(obj{"version": region, "routingItems": []obj{{"remarks": "loopback", "url": fmt.Sprintf("http://127.0.0.1:%d/regional/%s/rules.json", target, region)}}}))
			case "rules.json":
				rules := []obj{{"enabled": true, "port": "1-65535", "outboundTag": "proxy"}}
				if region == "iran" {
					rules = append([]obj{{"enabled": true, "ip": []string{"geoip:v2raym-nonexistent-fixture"}, "outboundTag": "block"}}, rules...)
				}
				data = []byte(jsonText(rules))
			}
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Write(data)
	})
	httpPeer.Start()
	defer httpPeer.Close()
	inbound := portBlock()
	normalHost(root, app, checker, inbound, peer, target)
	mu.Lock()
	hostVisits := append([]string(nil), visits...)
	visits = nil
	mu.Unlock()
	require(len(hostVisits) == 2 && hostVisits[0] == "native-check.invalid" && hostVisits[1] == "native-check.invalid",
		"expected one upstream connection before restart and one after: %v", hostVisits)
	if hostOnly {
		return
	}
	// Bound UDP/TCP test listeners use only the loopback interface.
	// Reserve the deliberately failing diagnostic port without listening on it.
	func() {
		fd, e := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
		check(e)
		defer syscall.Close(fd)
		check(syscall.Bind(fd, &syscall.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}))
		addr, e := syscall.Getsockname(fd)
		check(e)
		customHost(root, app, checker, inbound, peer, target, addr.(*syscall.SockaddrInet4).Port)
	}()
	checkerRun(180*time.Second, checker, app, filepath.Join(root, "data"), strconv.Itoa(target), strconv.Itoa(inbound), strconv.Itoa(peer))
	mu.Lock()
	n := len(visits)
	mu.Unlock()
	require(n >= 2, "expected traffic from both selected nodes")
	fixture := filepath.Join(root, "geo-fixture.app")
	for _, name := range []string{"Contents/Frameworks/libV2rayMXray.dylib", "Contents/Resources/Backend/bin/geoip.dat", "Contents/Resources/Backend/bin/geosite.dat"} {
		dest := filepath.Join(fixture, name)
		check(os.MkdirAll(filepath.Dir(dest), 0700))
		check(os.Symlink(filepath.Join(app, name), dest))
	}
	checkerRun(120*time.Second, checker, "--check-geo-fixture", fixture, filepath.Join(root, "geo-data"), strconv.Itoa(target), strconv.Itoa(inbound), strconv.Itoa(peer))
}
