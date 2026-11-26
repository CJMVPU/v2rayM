package splithttp

import (
	"context"
	"crypto/sha256"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/tls"
)

func TestV2rayMXHTTPRecoversWithoutTimingOutEstablishedStream(t *testing.T) {
	var mu sync.Mutex
	var first string
	const headerTimeout = 250 * time.Millisecond
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("expected HTTP/2")
		}
		mu.Lock()
		if first == "" {
			first = r.RemoteAddr
		}
		stalled := first == r.RemoteAddr
		mu.Unlock()
		if stalled {
			<-r.Context().Done()
			return
		}
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		time.Sleep(2 * headerTimeout)
		io.WriteString(w, "recovered")
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	settings := &internet.MemoryStreamConfig{ProtocolName: "splithttp", ProtocolSettings: &Config{Mode: "stream-one"},
		SecurityType: "tls", SecuritySettings: &tls.Config{NextProtocol: []string{"h2"}}}
	pin := sha256.Sum256(server.Certificate().Raw)
	settings.SecuritySettings.(*tls.Config).PinnedPeerCertSha256 = [][]byte{pin[:]}
	dest, _ := xnet.ParseDestination("tcp:" + server.Listener.Addr().String())
	ctx := context.Background()
	client, _ := getHTTPClient(ctx, dest, settings)
	c := client.(*DefaultDialerClient)
	if c.responseHeaderTimeout <= 0 {
		t.Fatal("no header deadline")
	}
	c.responseHeaderTimeout = headerTimeout
	read := func(c DialerClient) (string, error) {
		pr, pw := io.Pipe()
		defer pw.Close()
		rc, _, _, err := c.OpenStream(ctx, server.URL, "", pr, false)
		if err != nil {
			return "", err
		}
		defer rc.Close()
		b, err := io.ReadAll(rc)
		return string(b), err
	}
	if _, err := read(c); err == nil || !c.IsClosed() {
		t.Fatalf("stalled pool was not retired: %v", err)
	}
	next, _ := getHTTPClient(ctx, dest, settings)
	if c == next {
		t.Fatal("stalled client reused")
	}
	next.(*DefaultDialerClient).responseHeaderTimeout = headerTimeout
	if got, err := read(next); err != nil || got != "recovered" {
		t.Fatalf("healthy long stream: %q %v", got, err)
	}
	if next.IsClosed() {
		t.Fatal("closing a healthy stream retired the client")
	}
}

func TestV2rayMXHTTPBoundsTLSHandshake(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	drained := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			defer conn.Close()
			conn.SetReadDeadline(time.Now().Add(20 * time.Second))
			_, err = io.Copy(io.Discard, conn)
		}
		drained <- err
	}()
	dest, _ := xnet.ParseDestination("tcp:" + listener.Addr().String())
	client := createHTTPClient(nil, dest, &internet.MemoryStreamConfig{ProtocolName: "splithttp", ProtocolSettings: &Config{Mode: "stream-one"}, SecurityType: "tls", SecuritySettings: &tls.Config{NextProtocol: []string{"h2"}}})
	rc, _, _, err := client.OpenStream(context.Background(), "https://"+listener.Addr().String(), "", nil, false)
	if err == nil {
		defer rc.Close()
		_, err = io.ReadAll(rc)
	}
	if err == nil || !client.IsClosed() {
		t.Fatalf("TLS stall did not release client: %v", err)
	}
	if err := <-drained; err != nil {
		t.Fatalf("peer did not observe socket closure: %v", err)
	}
}
