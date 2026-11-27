import XCTest
@testable import V2rayMKit

final class ModuleUpdateTests: XCTestCase {
    func testRepairUpdateNoticeUsesExistingProgressStatus() {
        let same = ModuleUpdateProgress(coreType: "Xray", phase: "completed", isComplete: true, success: true,
                                        detail: "已安装同版本修复版，无需更新")
        XCTAssertEqual(same.phaseLabel, "已安装同版本修复版，无需更新")
        let newer = ModuleUpdateProgress(coreType: "Xray", phase: "failed", isComplete: true,
                                         detail: "发现上游新版本 26.10.22，尚未通过原生 TUN 兼容验证，已保留当前修复版。")
        XCTAssertEqual(newer.phaseLabel, "等待验证后再替换内核")
    }
    func testWaitingPhasePreservesCandidateForSingleAndBatchUpdates() {
        for batch in [false, true] {
            let progress = ModuleUpdateProgress(coreType: "Xray", phase: "awaiting-validation", isComplete: true,
                                                version: "v26.10.22", detail: "Compatibility review pending", batch: batch)
            XCTAssertTrue(progress.awaitingCompatibilityValidation)
            XCTAssertEqual(progress.phaseLabel, "等待验证后再替换内核")
            XCTAssertEqual(progress.version, "v26.10.22")
        }
    }
    func testByteProgressIsClampedAndUnknownLengthStaysIndeterminate() {
        func fraction(_ bytes: Int64, _ total: Int64?) -> Double? {
            ModuleUpdateProgress(phase: "downloading", downloadedBytes: bytes, totalBytes: total).downloadFraction
        }
        XCTAssertEqual(fraction(50, 100), 0.5)
        XCTAssertEqual(fraction(150, 100), 1)
        XCTAssertNil(fraction(50, nil))
    }
    func testGeoProgressCountsBothFilesAndKeepsCompletedWorkForUnknownLength() {
        func fraction(_ files: Int, _ bytes: Int64, _ total: Int64?) -> Double? {
            ModuleUpdateProgress(phase: "downloading", downloadedBytes: bytes, totalBytes: total,
                                 completedFiles: files, totalFiles: 2).downloadFraction
        }
        XCTAssertNil(fraction(0, 0, nil))
        XCTAssertEqual(fraction(0, 90, 100), 0.45)
        XCTAssertEqual(fraction(1, 0, nil), 0.5)
        XCTAssertEqual(fraction(1, 10, 100), 0.55)
        XCTAssertEqual(fraction(2, 0, nil), 1)
    }
    func testGeoDownloadLabelsTrackBytesWhenServerOmitsSize() {
        func label(_ bytes: Int64, phase: String = "downloading") -> String {
            ModuleUpdateProgress(phase: phase, downloadedBytes: bytes, completedFiles: 1, totalFiles: 2).phaseLabel
        }
        XCTAssertTrue(label(1_000_000).hasPrefix("下载 2/2"))
        XCTAssertNotEqual(label(1_000_000), label(2_000_000))
        XCTAssertEqual(label(0, phase: "waiting-to-apply"), "等待应用规则")
    }
    func testOnlyGeoDataCanBeUpdatedSeparately() throws {
        let original = SettingsValue.object(["CheckUpdateItem": .object([
            "SelectedCoreTypes": .array([.string("Xray"), .string("GeoFiles")]),
            "UpdateViaProxy": .bool(true)
        ])])
        let settings = NativeGeoUpdatePreferences.settings(original)
        XCTAssertEqual(settings["geoFilesSelected"], .bool(true))
        XCTAssertEqual(settings["useProxy"], .bool(true))
        XCTAssertEqual(settings["targets"], .array([]))
        let disabled = try NativeGeoUpdatePreferences.applying(.object(["selectedCoreTypes": .array([])]), to: original)
        XCTAssertEqual(disabled["CheckUpdateItem"]["SelectedCoreTypes"], .array([.string("Xray")]))
        XCTAssertThrowsError(try NativeGeoUpdatePreferences.applying(.object([
            "selectedCoreTypes": .array([.string("Xray")])
        ]), to: original))
    }
    func testTypedGeoAPIRequiresRunningHostAndRetainsTerminalProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = NativeRuntimeHost(dataDirectory: directory, mayContactHelper: false, automaticMaintenance: false)
        func assertStopped(_ api: any NativeAPI) async throws {
            do { _ = try await api.geoUpdateProgress(); XCTFail("Stopped host returned progress") }
            catch let error as ClientFailure { XCTAssertEqual(error.code, "backend_exited") }
            do { try await api.submitGeoUpdate(useProxy: false); XCTFail("Stopped host accepted work") }
            catch let error as ClientFailure { XCTAssertEqual(error.code, "backend_exited") }
        }
        try await assertStopped(host)
        let api = try await host.startClient()
        let initial = try await api.geoUpdateProgress()
        XCTAssertNil(initial)
        let store = NativeConfigurationStore(dataDirectory: directory)
        var settings = try await store.readSettings()
        settings["ConstItem"]["GeoSourceUrl"] = .string("file:///offline-fixture/{0}.dat")
        try await store.writeSettings(settings)
        try await api.submitGeoUpdate(useProxy: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var progress = try await api.geoUpdateProgress()
        while progress?.isComplete != true && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            progress = try await api.geoUpdateProgress()
        }
        XCTAssertEqual(progress, ModuleUpdateProgress(phase: "failed", isComplete: true, detail: "geo_source_invalid"))
        let nextRead = try await api.geoUpdateProgress()
        XCTAssertEqual(nextRead, progress)
        try await host.stop()
        try await assertStopped(api)
    }
}
