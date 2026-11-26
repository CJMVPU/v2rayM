import XCTest
@testable import V2rayMKit

final class ModuleUpdateTests: XCTestCase {
    func testRepairUpdateNoticeUsesExistingProgressStatus() throws {
        let same = try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(#"{"coreType":"Xray","phase":"completed","isComplete":true,"success":true,"batch":false,"detail":"已安装同版本修复版，无需更新"}"#.utf8))
        XCTAssertEqual(same.phaseLabel, "已安装同版本修复版，无需更新")
        let newer = try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(#"{"coreType":"Xray","phase":"failed","isComplete":true,"success":false,"batch":false,"detail":"发现上游新版本 26.10.22，尚未通过原生 TUN 兼容验证，已保留当前修复版。"}"#.utf8))
        XCTAssertEqual(newer.phaseLabel, "等待验证后再替换内核")
    }
    func testWaitingPhasePreservesCandidateForSingleAndBatchUpdates() throws {
        for batch in [false, true] {
            let json = "{\"coreType\":\"Xray\",\"phase\":\"awaiting-validation\",\"isComplete\":true,\"success\":false,\"batch\":\(batch),\"version\":\"v26.10.22\",\"detail\":\"Compatibility review pending\"}"
            let progress = try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(json.utf8))
            XCTAssertTrue(progress.awaitingCompatibilityValidation)
            XCTAssertEqual(progress.phaseLabel, "等待验证后再替换内核")
            XCTAssertEqual(progress.version, "v26.10.22")
        }
    }
    func testByteProgressIsClampedAndUnknownLengthStaysIndeterminate() throws {
        func progress(_ fields: String) throws -> ModuleUpdateProgress {
            try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data("{\"coreType\":\"Xray\",\"phase\":\"downloading\",\"isComplete\":false,\"success\":false,\"batch\":false,\(fields)}".utf8))
        }
        XCTAssertEqual(try progress("\"downloadedBytes\":50,\"totalBytes\":100").downloadFraction, 0.5)
        XCTAssertEqual(try progress("\"downloadedBytes\":150,\"totalBytes\":100").downloadFraction, 1)
        XCTAssertNil(try progress("\"downloadedBytes\":50,\"totalBytes\":null").downloadFraction)
    }
    func testGeoProgressCountsBothFilesAndKeepsCompletedWorkForUnknownLength() throws {
        func fraction(_ files: Int, _ bytes: Int, _ total: String) throws -> Double? {
            let payload = #"{"coreType":"GeoFiles","phase":"downloading","isComplete":false,"success":false,"batch":false,"totalFiles":2,"completedFiles":\#(files),"downloadedBytes":\#(bytes),"totalBytes":\#(total)}"#
            return try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(payload.utf8)).downloadFraction
        }
        XCTAssertNil(try fraction(0, 0, "null"))
        XCTAssertEqual(try fraction(0, 90, "100"), 0.45)
        XCTAssertEqual(try fraction(1, 0, "null"), 0.5)
        XCTAssertEqual(try fraction(1, 10, "100"), 0.55)
        XCTAssertEqual(try fraction(2, 0, "null"), 1)
    }
    func testGeoDownloadLabelsTrackBytesWhenServerOmitsSize() throws {
        func label(_ bytes: Int, phase: String = "downloading") throws -> String {
            let value: [String: Any] = ["coreType": "GeoFiles", "phase": phase, "isComplete": false, "success": false,
                                        "batch": false, "completedFiles": 1, "totalFiles": 2, "downloadedBytes": bytes]
            return try JSONDecoder().decode(ModuleUpdateProgress.self, from: JSONSerialization.data(withJSONObject: value)).phaseLabel
        }
        XCTAssertTrue(try label(1_000_000).hasPrefix("下载 2/2"))
        XCTAssertNotEqual(try label(1_000_000), try label(2_000_000))
        XCTAssertEqual(try label(0, phase: "waiting-to-apply"), "等待应用规则")
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
    func testIndividualButtonsOnlyWaitForTheirOwnModule() {
        XCTAssertEqual(ModuleUpdateScope.allCases.flatMap(\.targets), ["GeoFiles"])
    }
}
