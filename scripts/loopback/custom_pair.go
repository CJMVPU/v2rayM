package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

func customPair(root, tool, library string) {
	h := startHost([]string{tool, "serve-core-test", library}, nil, nil)
	defer h.close()
	command := func(action string, args ...string) obj {
		h.send(jsonText(obj{"action": action, "args": args}))
		return h.receive(15*time.Second, "")
	}
	ok := func(action string, args ...string) {
		r := command(action, args...)
		require(r["result"] == nil, "%s: %v", action, r)
	}
	var lock sync.Mutex
	var hits []string
	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lock.Lock()
		hits = append(hits, r.URL.Path)
		lock.Unlock()
		switch r.URL.Path {
		case "/ping":
		case "/ip":
			fmt.Fprint(w, jsonText(obj{"ip": "127.0.0.1"}))
		case "/download":
			fmt.Fprint(w, strings.Repeat("x", 16384))
		default:
			http.NotFound(w, r)
		}
	}))
	defer fast.Close()
	for i := 0; i < 4; i++ {
		key := fmt.Sprintf("f468d922-92a2-46fd-971b-%012d", i)
		ok("open", key, jsonText(obj{"outbounds": []obj{{"tag": key + "/proxy", "protocol": "freedom"}}}), root)
		lock.Lock()
		hits = nil
		lock.Unlock()
		answer := decode(command("measure", key, jsonText(obj{"action": "realping", "url": fast.URL + "/ping", "ipURL": fast.URL + "/ip", "downloadURL": fast.URL + "/download", "timeout": 1}))["result"].(string))
		require(answer["delay"].(float64) >= 1 && answer["speed"].(float64) > 0 && answer["ipInfo"].(obj)["ip"] == "127.0.0.1", "bad probe: %v", answer)
		lock.Lock()
		requests := strings.Join(hits, " ")
		lock.Unlock()
		require(strings.Contains(requests, "/ip") && strings.Contains(requests, "/download"), "missing probe requests: %s", requests)
		ok("close", key)
	}
	v4, e := net.Listen("tcp4", "127.0.0.1:0")
	check(e)
	target := v4.Addr().(*net.TCPAddr).Port
	v6, e := net.Listen("tcp6", fmt.Sprintf("[::1]:%d", target))
	check(e)
	for _, ln := range []net.Listener{v4, v6} {
		server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, ln.Addr().(*net.TCPAddr).IP.String()) })}
		go server.Serve(ln)
		defer server.Close()
	}
	ports := []int{freePort(), freePort()}
	tags := []string{"proxy-test", "source-proxy-Fixture", "direct"}
	ips := []string{"127.0.0.1", "::1"}
	logs := []string{filepath.Join(root, "frontend.log"), filepath.Join(root, "custom.log")}
	doc := func(i int) obj {
		return obj{"env": obj{"V2RAYM_FIXTURE_PORT": strconv.Itoa(ports[i]), "xray.cone.disabled": strconv.FormatBool(i == 1)},
			"log":       obj{"access": logs[i], "error": filepath.Join(root, fmt.Sprintf("%d-errors.log", i)), "loglevel": "debug"},
			"dns":       obj{"hosts": obj{"scope.invalid": ips[i]}, "servers": []string{"localhost"}},
			"inbounds":  []obj{{"tag": "entry", "protocol": "http", "listen": "127.0.0.1", "port": "env:V2RAYM_FIXTURE_PORT"}},
			"outbounds": []obj{{"tag": "first", "protocol": "blackhole"}, {"tag": "proxy", "protocol": "freedom", "settings": obj{"domainStrategy": []string{"ForceIPv4", "ForceIPv6"}[i]}}},
			"routing":   obj{"domainStrategy": []string{"AsIs", "IPIfNonMatch"}[i], "rules": []obj{{"type": "field", "inboundTag": []string{"entry"}, "outboundTag": "proxy"}}}}
	}
	begin := func(a, b obj, expect bool) {
		r := command("start", jsonText(a), jsonText(b), root)
		require((r["result"] == nil) == expect, "unexpected graph start: %v", r)
	}
	get := func(i int, want string) {
		body, e := getHTTP(fmt.Sprintf("http://scope.invalid:%d/", target), "http://"+endpoint(ports[i]))
		check(e)
		require(body == want, "graph %d returned %q, want %q", i, body, want)
	}
	messages := func() []string {
		var lines []string
		if raw := command("logs")["result"]; raw != nil {
			check(json.Unmarshal([]byte(raw.(string)), &lines))
		}
		return lines
	}
	accepted := func(lines []string) int {
		n := 0
		for _, v := range lines {
			if strings.Contains(v, "accepted") && strings.Contains(v, "scope.invalid") {
				n++
			}
		}
		return n
	}
	counters := func(size int, valid bool, expected []float64) {
		r := command("traffic", strconv.Itoa(size))
		require((r["ok"] == float64(1)) == valid, "invalid traffic status %v", r)
		if expected != nil {
			require(jsonText(r["counts"]) == jsonText(expected), "traffic mismatch %v vs %v", r, expected)
		}
	}
	counters(4, false, []float64{-1, -1, -1, -1})
	front, custom := doc(0), doc(1)
	bad := doc(1)
	bad["dns"] = obj{"servers": []string{"127.0.0.1:5300"}}
	begin(front, bad, false)
	busy, e := net.Listen("tcp4", endpoint(ports[0]))
	check(e)
	begin(front, custom, false)
	reusable, e := net.Listen("tcp4", endpoint(ports[1]))
	check(e)
	reusable.Close()
	busy.Close()
	for k, v := range map[string]string{"xray.buf.readv": "peer-only", "xray.tun.fd": "9999"} {
		bad = doc(1)
		bad["env"] = obj{k: v}
		begin(front, bad, false)
	}
	metrics := endpoint(freePort())
	front["metrics"] = obj{"listen": metrics}
	for _, g := range []obj{front, custom} {
		g["stats"] = obj{}
		g["policy"] = obj{"system": obj{"statsOutboundUplink": true, "statsOutboundDownlink": true}}
	}
	for _, tag := range tags {
		front["outbounds"].([]obj)[1]["tag"] = tag
		front["routing"].(obj)["rules"].([]obj)[0]["outboundTag"] = tag
		begin(front, custom, true)
		for i, ip := range ips {
			get(i, ip)
			deadline := time.Now().Add(2 * time.Second)
			for {
				b, _ := os.ReadFile(logs[i])
				if strings.Contains(string(b), "scope.invalid") {
					break
				}
				require(time.Now().Before(deadline), "missing log for graph %d", i)
				time.Sleep(20 * time.Millisecond)
			}
			require(accepted(messages()) > 0, "missing native console record")
			if i == 0 {
				b, _ := os.ReadFile(logs[1])
				require(!strings.Contains(string(b), "scope.invalid"), "cross-graph logging")
			}
		}
		body, e := getHTTP("http://"+metrics+"/debug/vars", "")
		check(e)
		values := decode(body)["stats"].(obj)["outbound"].(obj)[tag].(obj)
		up, down := values["uplink"].(float64), values["downlink"].(float64)
		require(up > 0 && down > 0, "missing outbound metrics")
		want := []float64{up, down, 0, 0}
		if tag == "direct" {
			want = []float64{0, 0, up, down}
		}
		counters(4, true, want)
		counters(3, false, want)
		ok("stop")
		counters(4, false, nil)
		for _, p := range logs {
			check(os.Remove(p))
		}
	}
	front = doc(0)
	front["log"].(obj)["loglevel"] = "error"
	custom["log"].(obj)["loglevel"] = "error"
	messages()
	ok("logged", jsonText(front), jsonText(custom), root)
	get(1, ips[1])
	for _, line := range messages() {
		require(!strings.Contains(line, "accepted"), "hidden custom log visible")
	}
	for i := 0; i < 540; i++ {
		get(0, ips[0])
	}
	require(accepted(messages()) == 540, "lost native access records")
	ok("stop")
	const id = "f468d922-92a2-46fd-971b-054fe27024cf"
	for _, network := range []string{"grpc", "xhttp"} {
		stream := obj{"network": network}
		if network == "grpc" {
			stream["grpcSettings"] = obj{"serviceName": "loopback"}
		} else {
			stream["xhttpSettings"] = obj{"path": "/loopback", "mode": "packet-up"}
		}
		a, b := doc(0), doc(1)
		a["outbounds"] = []obj{{"tag": "proxy", "protocol": "vless", "streamSettings": stream, "settings": obj{"vnext": []obj{{"address": "127.0.0.1", "port": ports[1], "users": []obj{{"id": id, "encryption": "none"}}}}}}}
		b["outbounds"].([]obj)[1]["settings"].(obj)["finalRules"] = []obj{{"action": "allow", "network": "tcp", "ip": []string{"::1/128"}, "port": strconv.Itoa(target)}}
		b["inbounds"] = []obj{{"tag": "entry", "protocol": "vless", "listen": "127.0.0.1", "port": ports[1], "streamSettings": stream, "settings": obj{"clients": []obj{{"id": id}}, "decryption": "none"}}}
		for i := 0; i < 2; i++ {
			begin(a, b, true)
			get(0, ips[1])
			ok("stop")
		}
	}
}
