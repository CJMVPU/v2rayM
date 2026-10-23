import XCTest
@testable import V2rayMKit

final class ModuleUpdateTests: XCTestCase {
    func testRepairUpdateNoticeUsesExistingProgressStatus() throws {
        let same = try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(#"{"coreType":"Xray","phase":"completed","isComplete":true,"success":true,"batch":false,"detail":"已安装同版本修复版，无需更新"}"#.utf8))
        XCTAssertEqual(same.phaseLabel, "已安装同版本修复版，无需更新")
        let newer = try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data(#"{"coreType":"Xray","phase":"failed","isComplete":true,"success":false,"batch":false,"detail":"发现上游新版本 26.10.22，尚未通过原生 TUN 兼容验证，已保留当前修复版。"}"#.utf8))
        XCTAssertEqual(newer.phaseLabel, "等待兼容验证")
    }
    func testByteProgressIsClampedAndUnknownLengthStaysIndeterminate() throws {
        func progress(_ fields: String) throws -> ModuleUpdateProgress {
            try JSONDecoder().decode(ModuleUpdateProgress.self, from: Data("{\"coreType\":\"Xray\",\"phase\":\"downloading\",\"isComplete\":false,\"success\":false,\"batch\":false,\(fields)}".utf8))
        }
        XCTAssertEqual(try progress("\"downloadedBytes\":50,\"totalBytes\":100").downloadFraction, 0.5)
        XCTAssertEqual(try progress("\"downloadedBytes\":150,\"totalBytes\":100").downloadFraction, 1)
        XCTAssertNil(try progress("\"downloadedBytes\":50,\"totalBytes\":null").downloadFraction)
    }
    func testAllModulesAlwaysEnableNativePrereleasesAndExcludeTheBackend() throws {
        let settings = try JSONDecoder().decode(ModuleUpdateSettings.self, from: Data(#"{"targets":[{"coreType":"Xray","canInstall":true},{"coreType":"mihomo","canInstall":true},{"coreType":"sing_box","canInstall":true},{"coreType":"v2rayN.WebAPI","canInstall":true},{"coreType":"hysteria2","canInstall":false}],"preRelease":false,"useProxy":true,"checkPreReleaseCoreTypes":["sing_box"]}"#.utf8))
        XCTAssertEqual(Set(settings.nativeTargets), Set(["Xray", "GeoFiles"]))
        XCTAssertEqual(Set(settings.input.checkPreReleaseCoreTypes ?? []), Set(["Xray"]))
        XCTAssertTrue(settings.input.preRelease)
        XCTAssertTrue(settings.input.useProxy)
    }
    func testIndividualButtonsOnlyWaitForTheirOwnModule() {
        XCTAssertEqual(ModuleUpdateScope.xray.targets, ["Xray"])
        XCTAssertFalse(ModuleUpdateScope.all.targets.contains("sing_box"))
        XCTAssertEqual(ModuleUpdateScope.geo.targets, ["GeoFiles"])
        XCTAssertEqual(ModuleUpdateScope.all.targets.count, 2)
    }
}
