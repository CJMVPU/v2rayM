//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/app/observatory"
	"github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/features/extension"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/infra/conf"
	"google.golang.org/protobuf/proto"
)

// Each job owns its candidates and observations. Detour-only outbounds remain
// accessible by exact tag but do not participate in primary selection.
type groupProbe struct {
	candidates   []string
	strategy     router.BalancingStrategy
	healthAction string
	url          string
	once         sync.Once
	report       observatory.ObservationResult
}

func (g *groupProbe) Type() interface{}                                     { return extension.ObservatoryType() }
func (g *groupProbe) Start() error                                          { return nil }
func (g *groupProbe) Close() error                                          { return nil }
func (g *groupProbe) GetObservation(context.Context) (proto.Message, error) { return &g.report, nil }

func newGroupProbe(ctx context.Context, document string, handlers map[string]outbound.Handler, prefix string) (*groupProbe, error) {
	var config struct {
		Routing  struct{ Balancers []conf.BalancingRule }
		ProbeURL string
	}
	if err := json.Unmarshal([]byte(document), &config); err != nil {
		return nil, err
	}
	if len(config.Routing.Balancers) == 0 {
		return nil, nil
	}
	if len(config.Routing.Balancers) != 1 {
		return nil, fmt.Errorf("invalid diagnostic group")
	}
	rule, err := config.Routing.Balancers[0].Build()
	if err != nil {
		return nil, err
	}
	if len(rule.OutboundSelector) != 1 || rule.OutboundSelector[0] != prefix+"proxy" || rule.FallbackTag != "" {
		return nil, fmt.Errorf("invalid diagnostic group selector")
	}
	group := &groupProbe{url: config.ProbeURL}
	for tag := range handlers {
		if strings.HasPrefix(tag, rule.OutboundSelector[0]) {
			group.candidates = append(group.candidates, tag)
		}
	}
	if len(group.candidates) == 0 {
		return nil, fmt.Errorf("diagnostic group has no candidates")
	}
	sort.Strings(group.candidates)
	group.strategy, err = rule.DiagnosticStrategy(ctx, group)
	if err != nil {
		return nil, err
	}
	switch rule.Strategy {
	case "leastload":
		group.healthAction = "health-load"
	case "leastping":
		group.healthAction = "health-ping"
	}
	return group, nil
}

func (g *groupProbe) observe(p *diagnostic) {
	if g.healthAction == "" {
		return
	}
	results := make([]*observatory.OutboundStatus, len(g.candidates))
	indices := make(chan int)
	var workers sync.WaitGroup
	for range min(8, len(results)) {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := range indices {
				tag := g.candidates[i]
				result, err := p.httpProbe(probeRequest{Action: g.healthAction, URL: g.url}, tag)
				ms := int64(result.Delay)
				row := &observatory.OutboundStatus{OutboundTag: tag, Alive: err == nil, Delay: ms}
				if g.healthAction == "health-load" {
					ns := int64(time.Duration(ms) * time.Millisecond)
					row.HealthPing = &observatory.HealthPingMeasurementResult{All: 1, Average: ns, Min: ns, Max: ns}
					if err != nil {
						row.HealthPing.Fail = 1
					}
				}
				results[i] = row
			}
		}()
	}
	for i := range g.candidates {
		select {
		case indices <- i:
		case <-p.ctx.Done():
			close(indices)
			workers.Wait()
			return
		}
	}
	close(indices)
	workers.Wait()
	g.report.Status = results
}
