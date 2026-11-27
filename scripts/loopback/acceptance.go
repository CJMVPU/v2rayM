package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type networkSnapshot struct {
	Interfaces             []string   `json:"interfaces"`
	TestRoute              []string   `json:"testRoute"`
	GatewayAndTunnelRoutes [][]string `json:"gatewayAndTunnelRoutes"`
	DNSServers             []string   `json:"dnsServers"`
	Proxy                  string     `json:"proxy"`
}

func captureNetwork() networkSnapshot {
	s := networkSnapshot{Interfaces: strings.Fields(call("/sbin/ifconfig", "-l")), Proxy: call("/usr/sbin/scutil", "--proxy")}
	for _, line := range strings.Split(call("/sbin/route", "-n", "get", "1.1.1.1"), "\n") {
		v := strings.TrimSpace(line)
		if strings.HasPrefix(v, "interface:") || strings.HasPrefix(v, "gateway:") {
			s.TestRoute = append(s.TestRoute, v)
		}
	}
	for _, family := range []string{"inet", "inet6"} {
		for _, line := range strings.Split(call("/usr/sbin/netstat", "-rn", "-f", family), "\n") {
			f := strings.Fields(line)
			if len(f) >= 4 && (strings.Contains(f[2], "G") || strings.HasPrefix(f[3], "utun")) && !strings.Contains(f[2], "W") {
				s.GatewayAndTunnelRoutes = append(s.GatewayAndTunnelRoutes, f[:4])
			}
		}
	}
	sort.Slice(s.GatewayAndTunnelRoutes, func(i, j int) bool {
		return strings.Join(s.GatewayAndTunnelRoutes[i], " ") < strings.Join(s.GatewayAndTunnelRoutes[j], " ")
	})
	for _, m := range regexp.MustCompile("nameserver\\[\\d+\\]\\s*:\\s*(\\S+)").FindAllStringSubmatch(call("/usr/sbin/scutil", "--dns"), -1) {
		s.DNSServers = append(s.DNSServers, m[1])
	}
	return s
}
func otherTunnel(s networkSnapshot) bool {
	if strings.Contains(strings.Join(s.TestRoute, " "), "utun") {
		return true
	}
	for _, row := range s.GatewayAndTunnelRoutes {
		dst := strings.ToLower(row[0])
		if strings.HasPrefix(row[3], "utun") && (dst == "default" || strings.Contains(dst, "/") && !strings.HasPrefix(dst, "fe80") && !strings.HasPrefix(dst, "ff") && !strings.HasPrefix(dst, "169.254") && !strings.HasPrefix(dst, "224.")) {
			return true
		}
	}
	return false
}
func requireIdle(s networkSnapshot) {
	require(!otherTunnel(s), "已有其他 TUN 管理系统路由")
	require(!strings.Contains(call("/usr/sbin/scutil", "--nc", "list"), "(Connected)"), "已有其他 VPN 连接")
	require(!regexp.MustCompile("\\b(?:HTTP|HTTPS|SOCKS|ProxyAutoConfig|ProxyAutoDiscovery)Enable\\s*:\\s*1\\b").MatchString(s.Proxy), "系统代理仍开启")
	for _, p := range strings.Split(call("/bin/ps", "-axo", "comm="), "\n") {
		switch strings.ToLower(filepath.Base(strings.TrimSpace(p))) {
		case "xray", "sing-box", "mihomo":
			check(fmt.Errorf("检测到运行中的代理内核"))
		}
	}
}
func restoration(before, after networkSnapshot) (obj, bool) {
	known := map[string]bool{}
	for _, name := range before.Interfaces {
		known[name] = true
	}
	added := []string{}
	for _, name := range after.Interfaces {
		if !known[name] {
			added = append(added, name)
		}
	}
	result := obj{"testRouteRestored": reflect.DeepEqual(before.TestRoute, after.TestRoute), "gatewayAndTunnelRoutesRestored": reflect.DeepEqual(before.GatewayAndTunnelRoutes, after.GatewayAndTunnelRoutes), "dnsServersRestored": reflect.DeepEqual(before.DNSServers, after.DNSServers), "systemProxyUnchanged": before.Proxy == after.Proxy}
	ok := len(added) == 0
	for _, v := range result {
		ok = ok && v.(bool)
	}
	result["newInterfacesRemaining"] = added
	return result, ok
}
func copyAcceptanceConfig(source, dest string) obj {
	original, e := filepath.EvalSymlinks(filepath.Join(source, "guiConfigs"))
	check(e)
	copy := filepath.Join(dest, "guiConfigs")
	check(os.Mkdir(copy, 0700))
	settings := decode(readFile(filepath.Join(original, "guiNConfig.json")))
	id, _ := settings["IndexId"].(string)
	require(id != "", "源配置未选中节点")
	settings["TunModeItem"].(obj)["EnableTun"] = false
	in := settings["Inbound"].([]any)[0].(obj)
	in["LocalPort"] = freePort()
	in["SecondLocalPortEnabled"] = false
	in["AllowLANConn"] = false
	writeJSON(filepath.Join(copy, "guiNConfig.json"), settings)
	db := filepath.Join(copy, "guiNDB.db")
	// The source connection is read-only. SQLite online backup includes committed WAL pages.
	cmd := exec.Command("/usr/bin/sqlite3", "-readonly", filepath.Join(original, "guiNDB.db"), ".backup guiNDB.db")
	cmd.Dir = copy
	cmd.Stderr = os.Stderr
	check(cmd.Run())
	out := call("/usr/bin/sqlite3", "-json", db, "SELECT DISTINCT Address FROM ProfileItem WHERE ConfigType IN (2,13) AND Address IS NOT NULL AND Address != ''")
	var rows []map[string]string
	if strings.TrimSpace(out) != "" {
		check(json.Unmarshal([]byte(out), &rows))
	}
	for _, row := range rows {
		address := row["Address"]
		hash := sha256.Sum256([]byte(address))
		local := "profile-" + hex.EncodeToString(hash[:]) + ".json"
		path := address
		if !filepath.IsAbs(path) {
			path = filepath.Join(original, address)
		}
		real, e := filepath.EvalSymlinks(path)
		if e == nil && strings.HasPrefix(real, original+string(os.PathSeparator)) {
			info, e := os.Stat(real)
			if e == nil && info.Mode().IsRegular() {
				b, e := os.ReadFile(real)
				check(e)
				check(os.WriteFile(filepath.Join(copy, local), b, 0600))
			}
		}
		sql(db, "UPDATE ProfileItem SET Address="+quoteSQL(local)+" WHERE ConfigType IN (2,13) AND Address="+quoteSQL(address))
	}
	return settings
}
func handled(f func()) (err error) {
	defer func() {
		if v := recover(); v != nil {
			err = fmt.Errorf("%v", v)
			if failure, ok := v.(failure); ok {
				err = failure.err
			}
		}
	}()
	f()
	return nil
}
func acceptance(args []string) {
	home, e := os.UserHomeDir()
	check(e)
	flags := flag.NewFlagSet("tun-acceptance", flag.ContinueOnError)
	app := flags.String("app", "/Applications/v2rayM.app", "Signed application")
	source := flags.String("source-data", filepath.Join(home, "Library/Application Support/v2rayM"), "Source data")
	result := flags.String("result-dir", "", "Report directory")
	version := flags.String("expect-app-version", "", "Expected app version")
	marker := flags.String("expect-xray-marker", "", "Expected Xray build")
	var offline bool
	flags.BoolVar(&offline, "check-only", false, "Offline preflight")
	flags.BoolVar(&offline, "preflight-only", false, "Offline preflight")
	check(flags.Parse(args))
	require(os.Geteuid() != 0, "请使用普通用户运行")
	if !offline {
		var tty syscall.Termios
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, os.Stdin.Fd(), syscall.TIOCGETA, uintptr(unsafe.Pointer(&tty)))
		require(errno == 0, "真实 TUN 验收需要本地交互终端")
	}
	syscall.Umask(0077)
	if *result == "" {
		root := os.Getenv("V2RAYM_PROJECT_ROOT")
		require(root != "", "Set V2RAYM_PROJECT_ROOT or --result-dir")
		*result = filepath.Join(root, "artifacts/macos-tun-tests")
	}
	check(os.MkdirAll(*result, 0700))
	dir, e := os.MkdirTemp(*result, time.Now().Format("20060102-150405-"))
	check(e)
	reportPath := filepath.Join(dir, "result.json")
	mode, latest := "real-tun", "latest.txt"
	if offline {
		mode, latest = "check-only", "latest-check-only.txt"
	}
	check(os.WriteFile(filepath.Join(*result, latest), []byte(reportPath+"\n"), 0600))
	fmt.Println("验收结果将写入", reportPath)
	report := obj{"app": *app, "mode": mode, "tunAttempted": false}
	save := func() { writeJSON(reportPath+".pending", report); check(os.Rename(reportPath+".pending", reportPath)) }
	var h *host
	var directory string
	var before networkSnapshot
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(quit)
	var watchdog *time.Timer
	await := func(timeout time.Duration) any {
		var timer <-chan time.Time
		if timeout > 0 {
			clock := time.NewTimer(timeout)
			defer clock.Stop()
			timer = clock.C
		}
		for {
			select {
			case <-quit:
				check(fmt.Errorf("验收已取消"))
			case <-timer:
				check(fmt.Errorf("验收响应超时"))
			case line, ok := <-h.lines:
				require(ok, "验收宿主已退出")
				if !strings.HasPrefix(line, "V2M-CHECK ") {
					continue
				}
				var value any
				check(json.Unmarshal([]byte(strings.TrimPrefix(line, "V2M-CHECK ")), &value))
				if m, ok := value.(obj); ok && m["error"] != nil {
					check(fmt.Errorf("%v", m["error"]))
				}
				return value
			}
		}
	}
	ask := func(name string) any { h.send(name); return await(40 * time.Second) }
	err := handled(func() {
		call("/usr/bin/codesign", "--verify", "--deep", "--strict", *app)
		contents := filepath.Join(*app, "Contents")
		info := decode(call("/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(contents, "Info.plist")))
		require(info["CFBundleIdentifier"] == "io.github.CJMVPU.v2rayM" && info["V2rayMTunAcceptanceProtocol"] == float64(1), "应用不支持 TUN 验收")
		actual := info["CFBundleShortVersionString"].(string)
		require(actual == info["CFBundleVersion"] && (*version == "" || actual == *version), "应用版本不匹配")
		for _, p := range []string{"MacOS/V2rayM", "MacOS/V2rayMHelper", "Frameworks/libV2rayMXray.dylib", "Library/LaunchDaemons/io.github.CJMVPU.v2rayM.tun-helper.plist"} {
			f, e := os.Stat(filepath.Join(contents, p))
			check(e)
			require(f.Mode().IsRegular(), "缺少组件 %s", p)
		}
		pin := decode(readFile(filepath.Join(contents, "Resources/Xray/library-build.json")))["inputs"].(obj)
		require(*marker == "" || pin["buildMarker"] == *marker, "Xray 修复标记不匹配")
		report["appVersion"], report["xrayVersion"], report["buildMarker"] = actual, pin["version"], pin["buildMarker"]
		hostArgs := []string{filepath.Join(contents, "MacOS/V2rayM"), "--tun-acceptance"}
		timeout := 40 * time.Second
		if !offline {
			fmt.Println("将临时接管系统路由和 DNS，请先关闭其他 VPN 和系统代理。")
			before = captureNetwork()
			requireIdle(before)
			hostArgs = append(hostArgs, "--allow-tun")
			timeout = 0
		}
		env := []string{}
		for _, v := range os.Environ() {
			if !strings.HasPrefix(v, "V2RAY") && !strings.HasPrefix(v, "DYLD_") && !strings.HasPrefix(v, "XRAY_") {
				env = append(env, v)
			}
		}
		h = startHost(hostArgs, nil, env)
		path := await(timeout).(obj)["directory"].(string)
		tmp, e := filepath.EvalSymlinks(os.TempDir())
		check(e)
		real, e := filepath.EvalSymlinks(path)
		check(e)
		s, e := os.Stat(real)
		check(e)
		require(filepath.Dir(real) == tmp && strings.HasPrefix(filepath.Base(real), "v2raym-acceptance-") && s.IsDir() && s.Sys().(*syscall.Stat_t).Uid == uint32(os.Getuid()) && s.Mode().Perm() == 0700, "验收临时目录归属不正确")
		directory = real
		var config obj
		if !offline {
			config = copyAcceptanceConfig(*source, directory)
		}
		pid := float64(h.cmd.Process.Pid)
		opened := ask("open").(obj)
		current := ask("status").(obj)
		require(opened["pid"] == pid && current["coreRunning"] == false && current["xrayAvailable"] == true, "宿主初始状态不符")
		report["hostPID"] = pid
		if offline {
			ask("logs")
			require(ask("helper").(obj)["helperCode"] == "helper_isolated", "预检助手未隔离")
			return
		}
		helper := ask("helper").(obj)
		require(helper["helperAvailable"] == true && helper["coreSource"] == "embedded-xray", "签名助手未就绪")
		report["before"] = before
		report["tunAttempted"] = true
		save()
		watchdog = time.AfterFunc(120*time.Second, func() { h.cmd.Process.Signal(syscall.SIGTERM) })
		for _, cycle := range []string{"start", "restart"} {
			requireIdle(captureNetwork())
			ask("start-tun")
			state, tun := ask("status").(obj), ask("helper").(obj)
			require(state["coreRunning"] == true && reflect.DeepEqual(state["coreProcessIds"], []any{pid}) && tun["tunnelForwardingPID"] == pid && reflect.DeepEqual(tun["privilegedCoreProcessIds"], []any{}) && reflect.DeepEqual(tun["supportedCores"], []any{"xray"}) && tun["runtimeState"] == "running", "TUN 转发身份不符")
			s := captureNetwork()
			gw, _ := config["TunModeItem"].(obj)["IPv4Address"].(string)
			if gw == "" {
				gw = "172.18.0.1/30"
			}
			gw = strings.Split(gw, "/")[0]
			found := false
			for _, d := range s.DNSServers {
				found = found || d == gw
			}
			require(found && strings.Contains(strings.Join(s.TestRoute, " "), "utun"), "TUN 路由或 DNS 不符")
			entry := obj{"corePID": pid, "network": s}
			report[cycle] = entry
			requests := []obj{}
			for _, u := range []string{"https://www.google.com/generate_204", "https://www.cloudflare.com/cdn-cgi/trace"} {
				code := strings.TrimSpace(call("/usr/bin/curl", "-q", "-sS", "--noproxy", "*", "--max-time", "10", "-o", "/dev/null", "-w", "%{http_code}", u))
				requests = append(requests, obj{"url": u, "http": code, "code": 0})
				entry["requests"] = requests
				require(code == "200" || code == "204", "TUN HTTPS 验证失败")
			}
			writeJSON(filepath.Join(dir, "core-logs.json"), ask("logs"))
			ask("stop")
			require(ask("status").(obj)["coreRunning"] == false, "内核停止未确认")
			save()
		}
	})
	if err != nil {
		report["failure"] = err.Error()
	}
	if watchdog != nil {
		watchdog.Stop()
	}
	if h != nil {
		if err := handled(func() { h.closeWithin(25 * time.Second) }); err != nil {
			report["cleanupError"] = err.Error()
		}
		if directory != "" {
			if e := os.RemoveAll(directory); e != nil {
				report["cleanupError"] = e.Error()
			}
		}
	}
	if report["tunAttempted"] == true {
		if err := handled(func() {
			for i := 0; i < 12; i++ {
				r, ok := restoration(before, captureNetwork())
				report["restoration"] = r
				if ok {
					return
				}
				time.Sleep(time.Second)
			}
			check(fmt.Errorf("系统网络尚未恢复到测试前基线"))
		}); err != nil {
			report["recoveryError"] = err.Error()
		}
	}
	passed := report["failure"] == nil && report["cleanupError"] == nil && report["recoveryError"] == nil
	report["passed"] = passed
	save()
	require(passed, "验收失败：%v %v %v", report["failure"], report["cleanupError"], report["recoveryError"])
}
