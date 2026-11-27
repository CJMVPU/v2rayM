package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func processLookup(core, directory string) {
	_, e := os.Stat(directory)
	require(os.IsNotExist(e), "Use a new output directory")
	check(os.MkdirAll(directory, 0700))
	target := udpPeer()
	defer target.Close()
	reserved := udpPeer()
	dest := reserved.LocalAddr().(*net.UDPAddr)
	reserved.Close()
	p := filepath.Join(directory, "config.json")
	writeJSON(p, obj{"log": obj{"loglevel": "debug", "access": filepath.Join(directory, "access.log"), "error": filepath.Join(directory, "error.log")},
		"inbounds":  []obj{{"listen": "127.0.0.1", "port": dest.Port, "protocol": "dokodemo-door", "tag": "test", "settings": obj{"address": "127.0.0.1", "port": target.LocalAddr().(*net.UDPAddr).Port, "network": "udp"}}},
		"outbounds": []obj{{"tag": "direct", "protocol": "freedom"}, {"tag": "self-block", "protocol": "blackhole"}},
		"routing":   obj{"rules": []obj{{"type": "field", "process": []string{"xray/", "self/"}, "outboundTag": "self-block"}, {"type": "field", "network": "udp", "outboundTag": "direct"}}}})
	binary, e := os.ReadFile(core)
	check(e)
	report := obj{"version": strings.Split(call(core, "version"), "\n")[0], "sha256": fmt.Sprintf("%x", sha256.Sum256(binary)), "loopback_only": true, "tun_started": false, "network_configuration_writes": 0}
	log, e := os.Create(filepath.Join(directory, "console.log"))
	check(e)
	defer log.Close()
	cmd := exec.Command(core, "run", "-c", p)
	cmd.Stdout = log
	cmd.Stderr = log
	check(cmd.Start())
	func() {
		defer func() {
			cmd.Process.Signal(syscall.SIGCONT)
			cmd.Process.Signal(syscall.SIGTERM)
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				cmd.Process.Kill()
				<-done
			}
			report["child_exited"] = cmd.ProcessState != nil
		}()
		live := udpPeer()
		defer live.Close()
		ready := false
		for i := 0; i < 50; i++ {
			live.WriteToUDP([]byte("live"), dest)
			target.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			b := make([]byte, 64)
			n, a, e := target.ReadFromUDP(b)
			if e != nil {
				continue
			}
			if string(b[:n]) == "live" {
				target.WriteToUDP([]byte("echo"), a)
				r, _ := readUDP(live)
				require(bytes.Equal(r, []byte("echo")), "bad live echo")
				ready = true
				break
			}
		}
		require(ready, "live UDP forwarding unavailable")
		report["live_udp_echo"] = true
		check(cmd.Process.Signal(syscall.SIGSTOP))
		pending := map[string]bool{}
		for i := 0; i < 20; i++ {
			key := fmt.Sprintf("closed-%02d", i)
			pending[key] = true
			client := udpPeer()
			_, e := client.WriteToUDP([]byte(key), dest)
			client.Close()
			check(e)
		}
		check(cmd.Process.Signal(syscall.SIGCONT))
		for len(pending) > 0 {
			data, _ := readUDP(target)
			delete(pending, string(data))
		}
		report["closed_socket_packets_received"] = 20
	}()
	errors, warnings := []string{}, []string{}
	debug := 0
	for _, l := range strings.Split(readFile(filepath.Join(directory, "error.log")), "\n") {
		if strings.Contains(l, "[Error]") {
			errors = append(errors, l)
		}
		if strings.Contains(l, "[Warning]") {
			warnings = append(warnings, l)
		}
		if strings.Contains(l, "[Debug]") && strings.Contains(l, "Process owner unavailable") {
			debug++
		}
	}
	report["errors"], report["warnings"], report["owner_unavailable_debug_count"] = errors, warnings, debug
	writeJSON(filepath.Join(directory, "result.json"), report)
	fmt.Println(jsonText(report))
}
