//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	applog "github.com/xtls/xray-core/app/log"
	"strings"

	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/infra/conf/serial"
)

type embeddedConfiguration struct {
	document        string
	variables       map[string]string
	flags           map[string]string
	routedProxyTags map[string]bool
	cone            bool
	strict          bool
}

// Inspect before constructing or starting any handlers. The host owns the asset
// store and the TUN descriptor. Ordinary env: references belong to the document.
func inspectConfiguration(document string) (*embeddedConfiguration, error) {
	var metadata struct{ Env map[string]string }
	if err := json.Unmarshal([]byte(document), &metadata); err != nil {
		return nil, err
	}
	result := &embeddedConfiguration{document: document, variables: metadata.Env, flags: make(map[string]string),
		cone: platform.NewEnvFlag(platform.UseCone).GetValue(func() string { return "" }) != "true", strict: serial.UseStrictJSON}
	for _, key := range []string{platform.AssetLocation, platform.TunFdKey, platform.ConfigLocation, platform.ConfdirLocation,
		platform.UseCone, platform.UseStrictJSON, platform.UseReadV, platform.UseFreedomSplice, platform.UseVmessPadding, platform.BufferSize,
		platform.XUDPLog, platform.XUDPBaseKey, platform.BrowserDialerAddress, platform.CertLocation} {
		value, present := metadata.Env[key]
		if alias, ok := metadata.Env[platform.NormalizeEnvName(key)]; ok {
			if present && alias != value {
				return nil, fmt.Errorf("conflicting aliases for %s", key)
			}
			value, present = alias, true
		}
		if !present {
			continue
		}
		switch key {
		case platform.AssetLocation, platform.TunFdKey, platform.ConfigLocation, platform.ConfdirLocation:
			return nil, fmt.Errorf("embedded host owns %s", key)
		case platform.UseCone:
			result.cone = value != "true"
		case platform.UseStrictJSON:
			result.strict = value == "true"
		default:
			result.flags[key] = value
		}
	}
	return result, nil
}

func (s *embeddedConfiguration) build(expectsTunnel, showLogs bool) (*core.Instance, error) {
	// Both the serving and diagnostic paths hold engine.Mutex when building.
	conf.SetEmbeddedVariables(s.variables)
	defer conf.SetEmbeddedVariables(nil)
	decode := serial.DecodeJSONConfig
	if s.strict {
		decode = serial.DecodeJSONConfigStrict
	}
	raw, err := decode(strings.NewReader(s.document))
	if err != nil {
		return nil, err
	}
	raw.Env = nil
	config, err := raw.Build()
	if err != nil {
		return nil, err
	}
	// A named native exit is "<id>-proxy-<name>". Internal chain hops also
	// contain that substring. Count only tags addressed by a rule or selector.
	if routing := raw.RouterConfig; routing != nil {
		s.routedProxyTags = make(map[string]bool)
		for _, rule := range routing.RuleList {
			var target struct{ OutboundTag string }
			if json.Unmarshal(rule, &target) == nil && strings.Contains(target.OutboundTag, "-proxy-") {
				s.routedProxyTags[target.OutboundTag] = true
			}
		}
		for _, balancer := range routing.Balancers {
			for _, selector := range balancer.Selectors {
				if !strings.Contains(selector, "-proxy-") {
					continue
				}
				for _, outbound := range raw.OutboundConfigs {
					if strings.HasPrefix(outbound.Tag, selector) {
						s.routedProxyTags[outbound.Tag] = true
					}
				}
			}
		}
	}
	tunnels := 0
	for _, inbound := range config.Inbound {
		if inbound.GetProxySettings().GetType() == "xray.proxy.tun.Config" {
			tunnels++
		}
	}
	if tunnels > 1 || (tunnels == 1) != expectsTunnel {
		return nil, fmt.Errorf("tunnel_descriptor_mismatch")
	}
	ctx := context.Background()
	if showLogs {
		ctx = applog.WithObserver(ctx, &console)
	}
	return core.NewScoped(ctx, config, s.cone)
}

func compatibleFlags(front, inner *embeddedConfiguration) error {
	for _, flags := range []map[string]string{front.flags, inner.flags} {
		for key := range flags {
			inherited := platform.NewEnvFlag(key).GetValue(func() string { return "" })
			a, ok := front.flags[key]
			if !ok {
				a = inherited
			}
			b, ok := inner.flags[key]
			if !ok {
				b = inherited
			}
			if a != b {
				return fmt.Errorf("legacy configs require different Xray runtime values for %s", key)
			}
		}
	}
	return nil
}
