//go:build darwin && !ios

package router

import (
	stderrors "errors"
	stdnet "net"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	routing_session "github.com/xtls/xray-core/features/routing/session"
)

type processTestLog struct{ messages []*log.GeneralMessage }

func (h *processTestLog) Handle(m log.Message) {
	if g, ok := m.(*log.GeneralMessage); ok {
		h.messages = append(h.messages, g)
	}
}

func TestV2rayMProcessDiagnosticPolicy(t *testing.T) {
	sink := &processTestLog{}
	log.RegisterHandler(sink)
	defer log.RegisterHandler(log.NewLogger(log.CreateStdoutLogWriter()))
	processLookupMisses = processLookupMissWindow{}
	defer func() { processLookupMisses = processLookupMissWindow{} }()
	for i := 0; i < 100; i++ {
		logProcessLookupFailure(errors.New("closed UDP").Base(net.ErrProcessNotFound))
	}
	warnings, failures := 0, 0
	for _, m := range sink.messages {
		if m.Severity == log.Severity_Warning {
			warnings++
		}
		if m.Severity == log.Severity_Error {
			failures++
		}
	}
	if warnings != 1 || failures != 0 {
		t.Fatalf("warnings=%d errors=%d", warnings, failures)
	}
	for _, err := range []error{stderrors.New("failed to list processes: permission denied"), stderrors.New("could not get process path"), stderrors.New("ambiguous process match")} {
		logProcessLookupFailure(err)
		if sink.messages[len(sink.messages)-1].Severity != log.Severity_Error {
			t.Fatalf("lost actual error: %v", err)
		}
	}
	before := len(sink.messages)
	logProcessLookupFailure(net.ErrNotLocal)
	if len(sink.messages) != before {
		t.Fatal("nonlocal lookup should not log")
	}
}

func TestV2rayMProcessMissAggregation(t *testing.T) {
	var window processLookupMissWindow
	start := time.Unix(100, 0)
	if window.record(start) != 1 {
		t.Fatal("first miss must remain visible")
	}
	for i := 0; i < 9; i++ {
		if window.record(start.Add(time.Second)) != 0 {
			t.Fatal("unbounded warning")
		}
	}
	if got := window.record(start.Add(time.Minute)); got != 10 {
		t.Fatalf("lost aggregate: %d", got)
	}
}

func TestV2rayMProcessRoutingAfterSocketClose(t *testing.T) {
	sock, err := stdnet.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sock.Close()
	port := sock.LocalAddr().(*stdnet.UDPAddr).Port
	ctx := &routing_session.Context{
		Inbound:  &session.Inbound{Source: net.UDPDestination(net.LocalHostIP, net.Port(port))},
		Outbound: &session.Outbound{Target: net.UDPDestination(net.LocalHostIP, 443)},
	}
	matcher := NewProcessNameMatcher([]string{"self/", "xray/"})
	if !matcher.Apply(ctx) {
		t.Fatal("live own socket must match self rule")
	}
	sock.Close()
	if matcher.Apply(ctx) {
		t.Fatal("closed socket must not be attributed to self")
	}
	// A process miss must allow subsequent non-process rules to be considered.
	fallback := NewNetworkMatcher([]net.Network{net.Network_UDP})
	if !fallback.Apply(ctx) {
		t.Fatal("UDP fallback stopped matching")
	}
}
