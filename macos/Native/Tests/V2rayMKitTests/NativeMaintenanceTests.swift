import Foundation
import XCTest
import V2rayMDomain
@testable import V2rayMKit

final class NativeMaintenanceTests: XCTestCase {
    func testLegacyCadenceAndGroupScopedFilesystemCleanup() async throws {
        XCTAssertEqual(MaintenanceAction.due(minute: 1, geoHours: 2), [.subscriptions])
        XCTAssertEqual(MaintenanceAction.due(minute: 60, geoHours: 2), [.subscriptions, .saveState, .cleanFiles])
        XCTAssertEqual(MaintenanceAction.due(minute: 120, geoHours: 2), [.subscriptions, .saveState, .cleanFiles, .geo])
        XCTAssertEqual(MaintenanceAction.due(minute: 1441, geoHours: 0), [.subscriptions])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeRuntimeHost(dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        try await host.start()
        do {
            try await host.saveGeoPreferences(SettingsValue.object([
                "selectedCoreTypes": .array([]), "useProxy": .bool(false)]))
            let store = NativeConfigurationStore(dataDirectory: root)
            var settings = try await store.readSettings()
            settings["GuiItem"]["AutoUpdateInterval"] = .number(0)
            try await store.writeSettings(settings)
            let fm = FileManager.default
            let configs = root.appendingPathComponent("binConfigs")
            try fm.createDirectory(at: configs, withIntermediateDirectories: true)
            for name in ["Test-old.json","config.json","Test-new.json"] {
                let url = configs.appendingPathComponent(name)
                try Data("{}".utf8).write(to: url)
                if name != "Test-new.json" { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path) }
            }
            try fm.createSymbolicLink(at: root.appendingPathComponent("guiTemps"), withDestinationURL: configs)
            await host.runMaintenance(minute: 60)
            XCTAssertFalse(fm.fileExists(atPath: configs.appendingPathComponent("Test-old.json").path))
            XCTAssertTrue(fm.fileExists(atPath: configs.appendingPathComponent("Test-new.json").path))
            XCTAssertTrue(fm.fileExists(atPath: configs.appendingPathComponent("config.json").path))
            try await host.stop()
        } catch { try await host.stop(); throw error }
    }
}
