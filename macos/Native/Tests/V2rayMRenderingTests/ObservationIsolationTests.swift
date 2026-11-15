import XCTest
import Combine
import V2rayMKit
@testable import V2rayM

@MainActor final class ObservationIsolationTests: XCTestCase {
    func testTrafficAndFreshnessDoNotInvalidateRootButRuntimeChangesDo() throws {
        let model = AppModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        var state = try JSONDecoder().decode(RuntimeStatus.self, from: Data("""
        {"coreRunning":true,"xrayAvailable":true,"runtimeState":"running",
         "traffic":{"proxyUp":1,"proxyDown":2,"directUp":0,"directDown":0}}
        """.utf8))
        model.status = state
        XCTAssertEqual(changes, 1)
        state.traffic?.proxyUp = 20
        model.status = state
        model.lastStatusRefresh = Date()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.telemetry.status?.traffic?.proxyUp, 20)
        state.runtimeState = "stopped"
        model.status = state
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(subscription) {}
    }
    func testUnchangedTrendDoesNotPublishAgain() throws {
        let telemetry = RuntimeTelemetry()
        let state = try JSONDecoder().decode(RuntimeStatus.self, from: Data("""
        {"coreRunning":false,"xrayAvailable":true,"runtimeState":"stopped"}
        """.utf8))
        var changes = 0
        let subscription = telemetry.objectWillChange.sink { changes += 1 }
        telemetry.record(state, now: Date(timeIntervalSince1970: 1000))
        telemetry.record(state, now: Date(timeIntervalSince1970: 1002))
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(subscription) {}
    }
    func testDraftRetainsHiddenFields() {
        var draft = ParameterSettingsDraft()
        draft.settings = .object(["unexposed": .string("keep"), "app": .object([:])])
        draft.settings["application"] = draft.settings["app"]
        draft.settings["application"]["enableStatistics"] = .bool(true)
        XCTAssertEqual(draft.settings["unexposed"], .string("keep"))
    }
}
