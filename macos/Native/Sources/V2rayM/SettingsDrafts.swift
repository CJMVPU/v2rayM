import SwiftUI
import V2rayMKit

private extension SettingsValue {
    mutating func removeEmptyLines(in keys: [String]) {
        for key in keys {
            if case .array(let rows) = self[key] {
                self[key] = .array(rows.filter { $0 != .string("") })
            }
        }
    }
}

struct ParameterSettingsDraft {
    var settings = SettingsValue.object([:])
    var tunSettings = SettingsValue.object([:])

    var submission: SettingsValue {
        var body = settings
        body["nativeTun"] = tunSettings
        body["nativeTun"].removeEmptyLines(in: ["routeExcludeAddress"])
        body["core"].removeEmptyLines(in: ["fragmentLengths", "fragmentDelays"])
        return body
    }
}
struct DNSSettingsDraft {
    var remotePresets = [String]()
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

    var savePath: String { "/api/settings/routing-profiles" + (routeID.isEmpty ? "" : "/" + routeID) }
    var saveMethod: String { routeID.isEmpty ? "POST" : "PUT" }
    func submission() throws -> SettingsValue {
        var body = route
        let rows = rules.map { original in
            var rule = original
            rule.removeEmptyLines(in: ["domain", "ip", "protocol", "inboundTag"])
            return rule
        }
        body["ruleSet"] = .string(try SettingsValue.array(rows).json())
        return body
    }
    mutating func acceptSaved(_ response: SettingsValue) throws {
        let id = response["routingId"].text
        guard !id.isEmpty else { throw ClientFailure("response_missing") }
        routeID = id; route["id"] = .string(id)
    }

    // Commit selection and rules together. A failed read must leave the previous
    // editable document intact, never associate its rules with another profile.
    func selecting(_ selected: SettingsValue, loadRules: (String) async throws -> [SettingsValue]) async throws -> Self {
        let id = selected["id"].text
        let loadedRules = try await loadRules(id)
        var next = self
        next.route = selected; next.routeID = id; next.rules = loadedRules; next.ruleIndex = 0
        return next
    }

    func refreshing(routes: [SettingsValue], preferActive: Bool, loadRules: (String) async throws -> [SettingsValue]) async throws -> Self {
        var next = self
        next.routes = routes
        let previous = preferActive ? nil : routes.first { $0["id"].text == routeID }
        guard let selected = previous ?? routes.first(where: { $0["isActive"].flag }) ?? routes.first else {
            return Self(route: RoutingDraft.newProfile())
        }
        return try await next.selecting(selected, loadRules: loadRules)
    }
}
