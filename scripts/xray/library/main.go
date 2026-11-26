//go:build darwin

// Package main exposes the pinned macOS Xray runtime to the Swift host.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	applog "github.com/xtls/xray-core/app/log"
	"github.com/xtls/xray-core/common/geodata"
	corelog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

var engine struct {
	sync.Mutex
	instance        *core.Instance
	custom          *core.Instance
	routedProxyTags map[string]bool
}

// The native UI polls on its own schedule. Bound the backlog even when its window is closed.
type consoleBuffer struct {
	sync.Mutex
	lines          [10000]string
	first, count   int
	bytes, dropped int
}

var console consoleBuffer

func (b *consoleBuffer) Handle(msg corelog.Message) {
	line := msg.String()
	if len(line) > 16384 {
		line = strings.ToValidUTF8(line[:16360], "") + "… [log entry truncated]"
	}
	b.Lock()
	defer b.Unlock()
	for b.count == len(b.lines) || b.bytes+len(line) > 8_000_000 {
		b.bytes -= len(b.lines[b.first])
		b.lines[b.first] = ""
		b.first = (b.first + 1) % len(b.lines)
		b.count--
		b.dropped++
	}
	b.lines[(b.first+b.count)%len(b.lines)] = line
	b.bytes += len(line)
	b.count++
}

// A message with no graph context cannot be assigned to either legacy log sink.
type unscopedLog struct{}

func (unscopedLog) Handle(corelog.Message)     {}
func (unscopedLog) Severity() corelog.Severity { return corelog.Severity_Unknown }

func init() {
	corelog.RegisterHandler(unscopedLog{})
	if err := applog.RegisterHandlerCreator(applog.LogType_Console, func(applog.LogType, applog.HandlerCreatorOptions) (corelog.Handler, error) {
		return unscopedLog{}, nil
	}); err != nil {
		panic(err)
	}
}

// V2rayMCoreTraffic returns lifetime byte totals from the serving frontend only.
// A legacy second graph forwards the same traffic and must never be counted twice.
//
//export V2rayMCoreTraffic
func V2rayMCoreTraffic(output *C.longlong, capacity C.int) C.int {
	if output == nil || capacity != 4 {
		return 0
	}
	engine.Lock()
	defer engine.Unlock()
	if engine.instance == nil || diagnosticOnly {
		return 0
	}
	manager, ok := engine.instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return 0
	}
	var totals [4]int64
	valid := true
	manager.VisitCounters(func(name string, counter stats.Counter) bool {
		rest, ok := strings.CutPrefix(name, "outbound>>>")
		if !ok {
			return true
		}
		tag, direction, ok := strings.Cut(rest, ">>>traffic>>>")
		if !ok {
			return true
		}
		index := 0
		if tag == "direct" {
			index = 2
		} else if !strings.HasPrefix(tag, "proxy") && !engine.routedProxyTags[tag] {
			return true
		}
		if direction == "downlink" {
			index++
		} else if direction != "uplink" {
			return true
		}
		n := counter.Value()
		if n < 0 || n > math.MaxInt64-totals[index] {
			valid = false
			return false
		}
		totals[index] += n
		return true
	})
	if !valid {
		return 0
	}
	result := unsafe.Slice(output, len(totals))
	for i, n := range totals {
		result[i] = C.longlong(n)
	}
	return 1
}

//export V2rayMCoreDrainLogs
func V2rayMCoreDrainLogs() *C.char {
	console.Lock()
	if console.count == 0 {
		console.Unlock()
		return nil
	}
	lines := make([]string, 0, console.count)
	if console.dropped > 0 {
		lines = append(lines, fmt.Sprintf("[Warning] 日志缓冲区已满，已移除最早的 %d 条记录", console.dropped))
	}
	for i := 0; i < console.count; i++ {
		at := (console.first + i) % len(console.lines)
		lines = append(lines, console.lines[at])
		console.lines[at] = ""
	}
	console.first, console.count, console.bytes, console.dropped = 0, 0, 0, 0
	console.Unlock()
	data, _ := json.Marshal(lines)
	return C.CString(string(data))
}

//export V2rayMCoreVersion
func V2rayMCoreVersion() *C.char {
	return C.CString(strings.Join(core.VersionStatement(), "\n"))
}

//export V2rayMCoreFree
func V2rayMCoreFree(p *C.char) { C.free(unsafe.Pointer(p)) }

// Read a candidate generation without changing the active engine's asset directory
// or populating its global matcher caches. Bound allocations to a single CIDR/domain.
func validateGeo(data []byte, site bool) error {
	if len(data) == 0 {
		return fmt.Errorf("empty Geo file")
	}
	var record proto.Message = &geodata.CIDR{}
	if site {
		record = &geodata.Domain{}
	}
	decode := proto.UnmarshalOptions{DiscardUnknown: true}
	for len(data) > 0 {
		field, typ, n := protowire.ConsumeTag(data)
		if n < 0 || field != 1 || typ != protowire.BytesType {
			return fmt.Errorf("invalid Geo entry")
		}
		entry, length := protowire.ConsumeBytes(data[n:])
		if length < 0 {
			return fmt.Errorf("truncated Geo entry")
		}
		data = data[n+length:]
		// Xray's DAT lookup reads the leading code with a one-byte length.
		if len(entry) < 2 || entry[0] != 0x0a || entry[1] == 0 || entry[1] >= 128 || int(entry[1])+2 > len(entry) {
			return fmt.Errorf("invalid Geo tag")
		}
		entry = entry[2+int(entry[1]):]
		for len(entry) > 0 {
			num, wire, header := protowire.ConsumeTag(entry)
			if header < 0 {
				return fmt.Errorf("invalid Geo record")
			}
			entry = entry[header:]
			if num == 2 {
				if wire != protowire.BytesType {
					return fmt.Errorf("invalid Geo record type")
				}
				payload, size := protowire.ConsumeBytes(entry)
				if size < 0 {
					return fmt.Errorf("truncated Geo record")
				}
				if err := decode.Unmarshal(payload, record); err != nil {
					return err
				}
				entry = entry[size:]
			} else {
				size := protowire.ConsumeFieldValue(num, wire, entry)
				if size < 0 {
					return fmt.Errorf("malformed Geo entry field")
				}
				entry = entry[size:]
			}
		}
	}
	return nil
}

//export V2rayMCoreValidateGeo
func V2rayMCoreValidateGeo(data *C.uchar, size C.size_t, site C.int) *C.char {
	if data == nil || size == 0 || uint64(size) > uint64(^uint(0)>>1) {
		return C.CString("invalid Geo data")
	}
	if err := validateGeo(unsafe.Slice((*byte)(unsafe.Pointer(data)), int(size)), site != 0); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export V2rayMCoreStart
func V2rayMCoreStart(configuration, assets *C.char, tunnelFD C.int) *C.char {
	return startSession(configuration, nil, assets, tunnelFD, true)
}

//export V2rayMCoreStartPair
func V2rayMCoreStartPair(frontend, custom, assets *C.char) *C.char {
	if custom == nil {
		return C.CString("missing_custom_configuration")
	}
	return startSession(frontend, custom, assets, -1, true)
}

//export V2rayMCoreStartLogged
func V2rayMCoreStartLogged(configuration, custom, assets *C.char, tunnelFD, showLogs C.int) *C.char {
	return startSession(configuration, custom, assets, tunnelFD, showLogs != 0)
}

func startSession(configuration, custom, assets *C.char, tunnelFD C.int, showLogs bool) *C.char {
	engine.Lock()
	defer engine.Unlock()
	if diagnosticOnly {
		finishProbesLocked()
		if err := closeIdleCoreLocked(); err != nil {
			return C.CString(err.Error())
		}
	}
	if engine.instance != nil || engine.custom != nil {
		return C.CString("core_already_running")
	}
	if configuration == nil || assets == nil || !filepath.IsAbs(C.GoString(assets)) {
		return C.CString("invalid_core_input")
	}
	var inner string
	if custom != nil {
		inner = C.GoString(custom)
		if inner == "" {
			return C.CString("empty_custom_configuration")
		}
	}
	if err := start(C.GoString(configuration), C.GoString(assets), int(tunnelFD), inner, showLogs); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// The legacy custom listener and generated frontend can use different DNS,
// routing, observatories and log files. Build both before exposing either one.
func start(document, assets string, tunnelFD int, custom string, showLogs bool) error {
	if err := os.Setenv(platform.AssetLocation, assets); err != nil {
		return err
	}
	fdValue := ""
	if tunnelFD >= 0 {
		fdValue = strconv.Itoa(tunnelFD)
	}
	if err := os.Setenv(platform.TunFdKey, fdValue); err != nil {
		return err
	}
	defer os.Setenv(platform.TunFdKey, "")
	front, err := inspectConfiguration(document)
	if err != nil {
		return err
	}
	var secondary *embeddedConfiguration
	if custom != "" {
		secondary, err = inspectConfiguration(custom)
		if err != nil {
			return err
		}
		if err = compatibleFlags(front, secondary); err != nil {
			return err
		}
	}
	platform.SetEmbeddedFlags(front.flags)
	started := false
	defer func() {
		if !started {
			platform.SetEmbeddedFlags(nil)
			_ = platform.ReloadEnvSettings()
		}
	}()
	if err := platform.ReloadEnvSettings(); err != nil {
		return err
	}
	primary, err := front.build(tunnelFD >= 0, showLogs || secondary != nil)
	if err != nil {
		return err
	}
	var inner *core.Instance
	if custom != "" {
		inner, err = secondary.build(false, showLogs)
		if err == nil {
			err = inner.Start()
		}
	}
	if err == nil {
		err = primary.Start()
	}
	if err != nil {
		closeErr := primary.Close()
		if inner != nil {
			closeErr = errors.Join(closeErr, inner.Close())
		}
		return errors.Join(err, closeErr)
	}
	started = true
	engine.instance, engine.custom = primary, inner
	engine.routedProxyTags = front.routedProxyTags
	return nil
}

//export V2rayMCoreStop
func V2rayMCoreStop() *C.char {
	engine.Lock()
	defer engine.Unlock()
	finishProbesLocked()
	if diagnosticOnly {
		if err := closeIdleCoreLocked(); err != nil {
			return C.CString(err.Error())
		}
	}
	if engine.instance == nil {
		return nil
	}
	err := engine.instance.Close()
	if engine.custom != nil {
		err = errors.Join(err, engine.custom.Close())
	}
	if err != nil {
		return C.CString(err.Error())
	}
	engine.instance, engine.custom = nil, nil
	engine.routedProxyTags = nil
	platform.SetEmbeddedFlags(nil)
	if err := platform.ReloadEnvSettings(); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

func main() {}
