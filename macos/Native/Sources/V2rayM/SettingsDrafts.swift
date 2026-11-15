import SwiftUI
import V2rayMKit

struct ParameterSettingsDraft {
    var settings = SettingsValue.object([:])
    var tunSettings = SettingsValue.object([:])
}
struct DNSSettingsDraft {
    var savedSimpleDNS = SettingsValue.object([:])
    var savedCustomDNS = SettingsValue.object([:])
    var simpleDNS = SettingsValue.object([:])
    var dns = SettingsValue.object([:])
}
struct RoutingSettingsDraft {
    var routes = [SettingsValue]()
    var route = SettingsValue.object([:])
    var rules = [SettingsValue]()
    var routeID = ""
    var ruleIndex = 0
}
