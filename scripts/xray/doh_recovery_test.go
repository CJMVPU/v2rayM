package dns

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"testing"
	"time"
)

// The first HTTP/2 connection accepts streams and PINGs but never replies to
// DNS POSTs. Only a new connection can succeed; the resolver instance stays live.
func TestV2rayMDoHRecoversOnFreshConnection(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var first string
	server := &http.Server{Protocols: new(http.Protocols), Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		io.Copy(w, r.Body)
	})}
	server.Protocols.SetUnencryptedHTTP2(true)
	go server.Serve(listener)
	defer server.Close()
	endpoint, err := url.Parse("https://" + listener.Addr().String() + "/dns-query")
	if err != nil {
		t.Fatal(err)
	}
	resolver := NewDoHNameServer(endpoint, nil, true, false, false, 0, nil)
	original := resolver.httpClient
	query := func(timeout time.Duration) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		return resolver.dohHTTPSContext(ctx, []byte("fixture"))
	}
	for i := 0; i < 2; i++ {
		if _, err := query(250 * time.Millisecond); !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("attempt %d: %v", i, err)
		}
		if i == 0 && resolver.httpClient != original {
			t.Fatal("one timeout retired the resolver pool")
		}
	}
	result, err := query(2 * time.Second)
	if err != nil || string(result) != "fixture" {
		t.Fatalf("new connection: %q %v", result, err)
	}
	resolver.httpClient.CloseIdleConnections()
}

func TestV2rayMDoHIgnoresOverlappingAndObsoleteFailures(t *testing.T) {
	endpoint, _ := url.Parse("https://127.0.0.1/dns-query")
	r := NewDoHNameServer(endpoint, nil, true, false, false, 0, nil)
	first := r.httpClient
	batch := time.Now()
	r.recordExchange(first, batch, context.DeadlineExceeded)
	r.recordExchange(first, batch, context.DeadlineExceeded)
	if first != r.httpClient {
		t.Fatal("concurrent failures retired pool")
	}
	r.recordExchange(first, time.Now(), nil)
	r.recordExchange(first, time.Now(), context.Canceled)
	r.recordExchange(first, time.Now(), context.DeadlineExceeded)
	if first != r.httpClient {
		t.Fatal("success or cancellation counted as failure")
	}
	r.recordExchange(first, time.Now(), context.DeadlineExceeded)
	second := r.httpClient
	if first == second {
		t.Fatal("separate timeouts did not renew pool")
	}
	r.recordExchange(second, time.Now(), context.DeadlineExceeded)
	r.recordExchange(first, time.Now(), nil)
	r.recordExchange(second, time.Now(), context.DeadlineExceeded)
	if second == r.httpClient {
		t.Fatal("obsolete success changed current pool state")
	}
}
