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

    // Commit selection and rules together. A failed read must leave the previous
    // editable document intact, never associate its rules with another profile.
    func selecting(_ selected: SettingsValue, loadRules: (String) async throws -> [SettingsValue]) async throws -> Self {
        let id = selected["id"].text
        let loadedRules = try await loadRules(id)
        var next = self
        next.route = selected; next.routeID = id; next.rules = loadedRules; next.ruleIndex = 0
        return next
    }
}
