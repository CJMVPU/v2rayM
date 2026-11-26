import Foundation

enum NativeGeoUpdatePreferences {
    static func settings(_ config: SettingsValue) -> SettingsValue {
        let prefs = config["CheckUpdateItem"]
        let selected = prefs["SelectedCoreTypes"]
        return .object(["targets": .array([]), "geoFilesSelected": .bool(selected == .null || selected.items.contains(.string("GeoFiles"))),
                        "preRelease": .bool(false), "useProxy": .bool(prefs["UpdateViaProxy"].flag), "checkPreReleaseCoreTypes": .array([])])
    }

    static func applying(_ input: SettingsValue, to original: SettingsValue) throws -> SettingsValue {
        guard case .array(let selected) = input["selectedCoreTypes"], selected.allSatisfy({ $0 == .string("GeoFiles") }) else {
            throw ClientFailure("core_update_settings_invalid")
        }
        var result = original
        let retained = original["CheckUpdateItem"]["SelectedCoreTypes"].items.filter { $0 != .string("GeoFiles") }
        result["CheckUpdateItem"]["SelectedCoreTypes"] = .array(retained + (selected.isEmpty ? [] : [.string("GeoFiles")]))
        result["CheckUpdateItem"]["UpdateViaProxy"] = .bool(input["useProxy"].flag)
        return result
    }
}
