// Offline verification peers. Every listener belongs to this process and binds a loopback IP.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

type obj = map[string]any
type failure struct{ err error }

func check(err error) {
	if err != nil {
		panic(failure{err})
	}
}
func require(ok bool, format string, args ...any) {
	if !ok {
		check(fmt.Errorf(format, args...))
	}
}
func jsonText(value any) string    { b, e := json.Marshal(value); check(e); return string(b) }
func decode(text string) obj       { var v obj; check(json.Unmarshal([]byte(text), &v)); return v }
func readFile(path string) string  { b, e := os.ReadFile(path); check(e); return string(b) }
func writeJSON(path string, v any) { check(os.WriteFile(path, []byte(jsonText(v)), 0600)) }
func call(args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Stderr = os.Stderr
	data, err := cmd.Output()
	check(err)
	return string(data)
}
func freePort() int {
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	check(e)
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
func endpoint(port int) string { return fmt.Sprintf("127.0.0.1:%d", port) }
func getHTTP(target, proxy string) (string, error) {
	transport := &http.Transport{DisableKeepAlives: true}
	if proxy != "" {
		u, e := url.Parse(proxy)
		if e != nil {
			return "", e
		}
		transport.Proxy = http.ProxyURL(u)
	}
	client := &http.Client{Timeout: 6 * time.Second, Transport: transport}
	resp, e := client.Get(target)
	if e != nil {
		return "", e
	}
	defer resp.Body.Close()
	body, e := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("%s: %s", target, resp.Status)
	}
	return string(body), e
}

type host struct {
	cmd   *exec.Cmd
	in    io.WriteCloser
	lines chan string
	done  chan error
}

func startHost(args []string, extra []*os.File, env []string) *host {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = extra
	cmd.Env = env
	out, e := cmd.StdoutPipe()
	check(e)
	in, e := cmd.StdinPipe()
	check(e)
	h := &host{cmd: cmd, in: in, lines: make(chan string, 64), done: make(chan error, 1)}
	check(cmd.Start())
	go func() {
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 65536), 16<<20)
		for scanner.Scan() {
			h.lines <- scanner.Text()
		}
		close(h.lines)
		h.done <- cmd.Wait()
	}()
	return h
}
func (h *host) send(line string) { _, e := io.WriteString(h.in, line+"\n"); check(e) }
func (h *host) receive(timeout time.Duration, prefix string) obj {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		select {
		case line, ok := <-h.lines:
			require(ok, "fixture exited before reply")
			if strings.HasPrefix(line, prefix) {
				return decode(strings.TrimPrefix(line, prefix))
			}
		case <-deadline.C:
			check(errors.New("fixture reply timeout"))
		}
	}
}
func (h *host) close() { h.closeWithin(12 * time.Second) }

func (h *host) closeWithin(timeout time.Duration) {
	// A host can finish logging after the last reply. Drain its pipe through EOF
	// so the scanner and cmd.Wait also complete on the timed-out kill path.
	go func() {
		for range h.lines {
		}
	}()
	h.in.Close()
	select {
	case e := <-h.done:
		check(e)
	case <-time.After(timeout):
		h.cmd.Process.Kill()
		<-h.done
		check(errors.New("fixture shutdown timed out"))
	}
}
func sql(db string, statement string) string {
	cmd := exec.Command("/usr/bin/sqlite3", "-batch", "-bail", db)
	cmd.Stdin = strings.NewReader(statement)
	var buf bytes.Buffer
	cmd.Stderr = &buf
	result, e := cmd.Output()
	if e != nil {
		check(fmt.Errorf("sqlite fixture: %w: %s", e, buf.String()))
	}
	return string(result)
}
func quoteSQL(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
func run(args []string) {
	require(len(args) > 0, "Missing loopback operation")
	root, e := os.MkdirTemp("", "v2raym-loopback-")
	check(e)
	defer os.RemoveAll(root)
	switch args[0] {
	case "dns":
		require(len(args) == 3, "Expected app and checker")
		dnsSmoke(root, args[1], args[2])
	case "process-lookup":
		flags := flag.NewFlagSet("process-lookup", flag.ContinueOnError)
		core := flags.String("core", "", "Standalone Xray verification executable")
		out := flags.String("output", "", "New report directory")
		check(flags.Parse(args[1:]))
		require(*core != "" && *out != "" && flags.NArg() == 0, "Expected --core path --output directory")
		processLookup(*core, *out)
	case "tun-acceptance":
		acceptance(args[1:])
	case "active-groups":
		require(len(args) == 3, "Expected app and checker")
		for _, k := range []int{101, 102} {
			activeGroup(root, args[1], args[2], k)
		}
	case "product":
		require(len(args) == 3 || len(args) == 4 && args[3] == "--host-fixture-only", "Expected app, checker and optional --host-fixture-only")
		productSmoke(root, args[1], args[2], len(args) == 4)
	case "embedded":
		require(len(args) == 3, "Expected checker and library")
		embedded(root, args[1], args[2])
	case "custom-pair":
		require(len(args) == 3, "Expected project tool and library")
		customPair(root, args[1], args[2])
	default:
		check(fmt.Errorf("Unknown loopback operation: %s", args[0]))
	}
	fmt.Println("PASS", args[0])
}
func main() {
	defer func() {
		if v := recover(); v != nil {
			if e, ok := v.(failure); ok {
				fmt.Fprintln(os.Stderr, e.err)
				os.Exit(1)
			}
			panic(v)
		}
	}()
	run(os.Args[1:])
}
