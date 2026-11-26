import XCTest
@testable import V2rayMKit

final class NativeReleasePolicyTests: XCTestCase {
    func testPreferenceEditsRetainUnknownStoredTargets() throws {
        var config = SettingsValue.object([:])
        config["CheckUpdateItem"]["SelectedCoreTypes"] = .array([.string("future"), .string("Xray")])
        let edit: SettingsValue = .object(["selectedCoreTypes": .array([.string("GeoFiles")]), "preRelease": .bool(true)])
        let changed = try NativeGeoUpdatePreferences.applying(edit, to: config)
        XCTAssertEqual(changed["CheckUpdateItem"]["SelectedCoreTypes"].items.map(\.text), ["future", "Xray", "GeoFiles"])
        XCTAssertTrue(NativeGeoUpdatePreferences.settings(changed)["geoFilesSelected"].flag)
        XCTAssertTrue(NativeGeoUpdatePreferences.settings(changed)["targets"].items.isEmpty)
        XCTAssertThrowsError(try NativeGeoUpdatePreferences.applying(.object(["selectedCoreTypes": .array([.string("unknown")])]), to: config))
    }
}
