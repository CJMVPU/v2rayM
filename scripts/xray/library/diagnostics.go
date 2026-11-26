//go:build darwin

package main

import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
)

type privateManager interface {
	AttachProbe(map[string]outbound.Handler) error
	DetachProbe(map[string]outbound.Handler)
}

type diagnostic struct {
	ctx      context.Context
	cancel   context.CancelFunc
	work     sync.WaitGroup
	instance *core.Instance
	manager  privateManager
	handlers map[string]outbound.Handler
	tag      string
	group    *groupProbe
}

// engine.Mutex guards membership and all transitions between serving and diagnostic-only use.
var probes = make(map[string]*diagnostic)
var diagnosticOnly bool

func finishProbesLocked() {
	for id, probe := range probes {
		probe.cancel()
		probe.close()
		delete(probes, id)
	}
}

func (p *diagnostic) close() {
	p.cancel()
	p.work.Wait()
	p.manager.DetachProbe(p.handlers)
	for _, h := range p.handlers {
		h.Close()
	}
}

func closeIdleCoreLocked() error {
	if diagnosticOnly && len(probes) == 0 {
		if err := engine.instance.Close(); err != nil {
			return err
		}
		engine.instance = nil
		diagnosticOnly = false
	}
	return nil
}

func openDiagnostic(id, config, assets string) error {
	engine.Lock()
	defer engine.Unlock()
	if len(id) != 36 || strings.ContainsAny(id, "/\x00") || !filepath.IsAbs(assets) || probes[id] != nil {
		return fmt.Errorf("invalid diagnostic input")
	}
	if engine.instance == nil {
		// The private instance has no listeners. Its default rejects all unrouted traffic.
		if err := start(`{"log":{"loglevel":"none"},"outbounds":[{"protocol":"blackhole"}]}`, assets, -1, "", false); err != nil {
			return err
		}
		diagnosticOnly = true
	}
	ok := false
	defer func() {
		if !ok {
			closeIdleCoreLocked()
		}
	}()
	configuration, err := core.LoadConfig("json", bytes.NewReader([]byte(config)))
	if err != nil {
		return err
	}
	manager, supported := engine.instance.GetFeature(outbound.ManagerType()).(privateManager)
	if !supported || len(configuration.Outbound) == 0 {
		return fmt.Errorf("diagnostic outbound missing")
	}
	handlers := make(map[string]outbound.Handler)
	defer func() {
		if !ok {
			for _, handler := range handlers {
				handler.Close()
			}
		}
	}()
	for _, item := range configuration.Outbound {
		tag := item.Tag
		if !strings.HasPrefix(tag, id+"/") || handlers[tag] != nil {
			return fmt.Errorf("invalid diagnostic tag")
		}
		// Keep transient counters out of the serving profile's statistics.
		item.Tag = ""
		object, err := core.CreateObject(engine.instance, item)
		if err != nil {
			return err
		}
		handler := object.(outbound.Handler)
		handlers[tag] = handler
		if err := handler.Start(); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	group, err := newGroupProbe(ctx, config, handlers, id+"/")
	if err != nil {
		cancel()
		return err
	}
	entry := id + "/proxy"
	if handlers[entry] == nil && group == nil {
		cancel()
		return fmt.Errorf("diagnostic entry missing")
	}
	if err := manager.AttachProbe(handlers); err != nil {
		cancel()
		return err
	}
	probes[id] = &diagnostic{ctx: ctx, cancel: cancel, instance: engine.instance, manager: manager, handlers: handlers, tag: entry, group: group}
	ok = true
	return nil
}

//export V2rayMCoreOpenProbe
func V2rayMCoreOpenProbe(id, configuration, assets *C.char) *C.char {
	if err := openDiagnostic(C.GoString(id), C.GoString(configuration), C.GoString(assets)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export V2rayMCoreCloseProbe
func V2rayMCoreCloseProbe(identifier *C.char) *C.char {
	engine.Lock()
	defer engine.Unlock()
	id := C.GoString(identifier)
	if p := probes[id]; p != nil {
		p.close()
		delete(probes, id)
	}
	if err := closeIdleCoreLocked(); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

type probeRequest struct {
	Action      string
	URL         string
	Timeout     int
	DownloadURL string
	IPURL       string
}

type probeResult struct {
	Delay  int             `json:"delay"`
	Speed  float64         `json:"speed,omitempty"`
	IPInfo json.RawMessage `json:"ipInfo,omitempty"`
}

func (p *diagnostic) dial(ctx context.Context, dest xnet.Destination, fixedTag string) (net.Conn, error) {
	tag := fixedTag
	if tag == "" {
		tag = p.tag
		if p.group != nil {
			tag = p.group.strategy.PickOutbound(p.group.candidates)
		}
	}
	if tag == "" || p.handlers[tag] == nil {
		return nil, fmt.Errorf("no available diagnostic candidate")
	}
	return core.Dial(session.SetForcedOutboundTagToContext(ctx, tag), p.instance, dest)
}

func (p *diagnostic) httpProbe(request probeRequest, fixedTag string) (probeResult, error) {
	timeout := 5 * time.Second
	if request.Action == "download" {
		if request.Timeout <= 0 || request.Timeout > 86400 {
			return probeResult{}, fmt.Errorf("invalid download timeout")
		}
		timeout = time.Duration(request.Timeout) * time.Second
	} else if request.Action != "realping" && request.Action != "ipinfo" && request.Action != "health-load" && request.Action != "health-ping" {
		return probeResult{}, fmt.Errorf("invalid diagnostic action")
	}
	ctx, cancel := context.WithTimeout(p.ctx, timeout)
	defer cancel()
	transport := &http.Transport{DialContext: func(_ context.Context, _, addr string) (net.Conn, error) {
		dest, err := xnet.ParseDestination("tcp:" + addr)
		if err != nil {
			return nil, err
		}
		return p.dial(ctx, dest, fixedTag)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	health := request.Action == "health-load" || request.Action == "health-ping"
	method := http.MethodGet
	if request.Action == "health-load" {
		method = http.MethodHead
	}
	if health {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	result := probeResult{Delay: -1}
	for attempt := 0; attempt < 2; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, request.URL, nil)
		if err != nil {
			return result, err
		}
		started := time.Now()
		r, err := client.Do(req)
		if err != nil {
			return result, err
		}
		if health {
			r.Body.Close()
			result.Delay = max(1, int(time.Since(started).Milliseconds()))
			return result, nil
		}
		if request.Action == "ipinfo" {
			defer r.Body.Close()
			if r.StatusCode < 200 || r.StatusCode >= 300 {
				return result, fmt.Errorf("IP lookup HTTP %d", r.StatusCode)
			}
			const limit = 256 * 1024
			data, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
			if err != nil || len(data) > limit || !json.Valid(data) {
				return result, fmt.Errorf("invalid IP lookup response")
			}
			result.IPInfo = data
			return result, nil
		}
		if request.Action == "download" {
			defer r.Body.Close()
			if r.StatusCode < 200 || r.StatusCode >= 300 {
				return result, fmt.Errorf("download HTTP %d", r.StatusCode)
			}
			var count int64
			window := started
			buf := make([]byte, 64*1024)
			for {
				n, readErr := r.Body.Read(buf)
				count += int64(n)
				elapsed := time.Since(window)
				if elapsed >= time.Second || readErr != nil {
					if elapsed > 0 {
						result.Speed = max(result.Speed, float64(count)/elapsed.Seconds()/1e6)
					}
					count = 0
					window = time.Now()
				}
				if readErr != nil {
					if p.ctx.Err() != nil {
						return result, p.ctx.Err()
					}
					if readErr == io.EOF || (ctx.Err() == context.DeadlineExceeded && result.Speed > 0) {
						return result, nil
					}
					return result, readErr
				}
			}
		}
		_, err = io.Copy(io.Discard, r.Body)
		r.Body.Close()
		if err != nil {
			return result, err
		}
		delay := max(1, int(time.Since(started).Milliseconds()))
		if result.Delay < 0 || delay < result.Delay {
			result.Delay = delay
		}
		if attempt == 0 {
			select {
			case <-ctx.Done():
				return result, ctx.Err()
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
	return result, nil
}

//export V2rayMCoreMeasureProbe
func V2rayMCoreMeasureProbe(identifier, raw *C.char) *C.char {
	engine.Lock()
	p := probes[C.GoString(identifier)]
	if p != nil {
		p.work.Add(1)
	}
	engine.Unlock()
	if p == nil {
		return C.CString(`{"interrupted":true}`)
	}
	defer p.work.Done()
	var request probeRequest
	if json.Unmarshal([]byte(C.GoString(raw)), &request) != nil {
		return nil
	}
	if p.group != nil {
		p.group.once.Do(func() { p.group.observe(p) })
	}
	var result probeResult
	var err error
	if request.Action == "udp" {
		result, err = p.udpProbe(request.URL)
	} else {
		result, err = p.httpProbe(request, "")
	}
	if err == nil && request.Action == "realping" && result.Delay > 0 {
		if request.IPURL != "" && p.ctx.Err() == nil {
			detail, _ := p.httpProbe(probeRequest{Action: "ipinfo", URL: request.IPURL}, "")
			result.IPInfo = detail.IPInfo
		}
		if request.DownloadURL != "" && p.ctx.Err() == nil {
			rate, _ := p.httpProbe(probeRequest{Action: "download", URL: request.DownloadURL, Timeout: request.Timeout}, "")
			result.Speed = rate.Speed
		}
	}
	if p.ctx.Err() != nil {
		return C.CString(`{"interrupted":true}`)
	}
	if err != nil {
		return nil
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil
	}
	return C.CString(string(data))
}
